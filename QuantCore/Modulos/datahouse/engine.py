"""Engine do DataHouse - Status do banco e utilitários de domínio.

Responsável por expor o status consolidado dos domínios de dados
(OHLC, Macro, Calendar, Risk) diretamente do DuckDB.

Funções:
    get_db_status()      - status consolidado por domínio
    get_ohlc_pairs()     - pares (symbol, timeframe) disponíveis
    get_all_symbols()    - lista de símbolos OHLC
    get_all_timeframes() - lista de timeframes OHLC
"""
from datetime import datetime, timezone
from typing import Any

from .collector import get_connection


# ─────────────────────────────────────────────────────────────────────
# Universe catalog: unica fonte de verdade para o datahouse
# Encapsula macro (FRED/YAHOO) + universo OHLC (MT5) em macro_catalog.
# ─────────────────────────────────────────────────────────────────────

# Colunas extras da macro_catalog quando operada como catalog de universo.
CATALOG_EXTRA_COLUMNS = [
    ("category_type", "VARCHAR"),   # fx | commodity | index | crypto | macro
    ("collector",     "VARCHAR"),   # MT5 | FRED | YAHOO
    ("target_table",  "VARCHAR"),   # ohlc_prices | macro_series
    ("timeframe",     "VARCHAR"),   # M5 para OHLC, NULL para macro
    ("enabled",       "BOOLEAN"),
    ("min_freshness_hours", "INTEGER"),
]

# Frescor minimo (horas) por frequencia declarada (cadencia).
FRESHNESS_BY_FREQUENCY = {
    "hourly": 2, "daily": 24, "weekly": 168,
    "monthly": 720, "quarterly": 2200,
}

# Override de freshness para series FRED com lag conhecido de publicacao.
# Sem isso, daily=24h -> critical em 72h, mas FRED oil/gas publica com 3-5 dias.
FRED_LAG_OVERRIDE = {
    "DCOILBRENTEU": 120, "DCOILWTICO": 120, "DHHNGSP": 120,
    "KCRORO": 96, "KCROROE": 96, "KCROROG": 96, "KCROROL": 96, "KCROROS": 96,
    "SOFR": 96, "DGS30": 96,
}

# Matriz oficial KCRORO (Kansas City Fed / FRED) - referencia do risk sentiment.
# Cabecalho (KCRORO) + 4 subindices oficiais (equities/gold-USO/liquidity/spreads).
# Coletados via FRED (daily) para monitoramento de frescor no gate de prontidao.
KCRORO_ASSETS = [
    dict(symbol="KCRORO",  name="RORO Index (headline)",    category="risk", hyfreq="daily", fred_code="KCRORO"),
    dict(symbol="KCROROE",  name="RORO Equities",           category="risk", hyfreq="daily", fred_code="KCROROE"),
    dict(symbol="KCROROG",  name="RORO Gold & USD",         category="risk", hyfreq="daily", fred_code="KCROROG"),
    dict(symbol="KCROROL",  name="RORO Liquidity",          category="risk", hyfreq="daily", fred_code="KCROROL"),
    dict(symbol="KCROROS",  name="RORO Spreads",            category="risk", hyfreq="daily", fred_code="KCROROS"),
]

# Universo de ativos OHLC (MT5) que precisa de atualizacao periodica.
# category_type: forex | commodity | index | crypto
OHLC_ASSETS = [
    dict(symbol="XAUUSD", name="Gold vs USD",    description="XAU/USD M5 via MT5",  category="commodity", country="US", cadence="daily",  timeframe="M5"),
    dict(symbol="EURUSD", name="Euro vs USD",    description="EUR/USD M5 via MT5",  category="forex",      country="EU", cadence="daily",  timeframe="M5"),
    dict(symbol="USDJPY", name="USD vs Yen",     description="USD/JPY M5 via MT5",  category="forex",      country="JP", cadence="daily",  timeframe="M5"),
    dict(symbol="GBPJPY", name="Pound vs Yen",   description="GBP/JPY M5 via MT5",  category="forex",      country="JP", cadence="daily",  timeframe="M5"),
    dict(symbol="AUDJPY", name="Aussie vs Yen",  description="AUD/JPY M5 via MT5",  category="forex",      country="JP", cadence="daily",  timeframe="M5"),
    dict(symbol="EURGBP", name="Euro vs Pound",  description="EUR/GBP M5 via MT5",  category="forex",      country="EU", cadence="daily",  timeframe="M5"),
    dict(symbol="US30",   name="Dow Jones",      description="US30 M5 via MT5",     category="index",      country="US", cadence="daily",  timeframe="M5"),
    dict(symbol="US500",  name="S&P 500",        description="US500 M5 via MT5",    category="index",      country="US", cadence="daily",  timeframe="M5"),
    dict(symbol="US100",  name="Nasdaq 100",     description="US100 M5 via MT5",    category="index",      country="US", cadence="daily",  timeframe="M5"),
    dict(symbol="HK50",   name="Hang Seng 50",   description="HK50 M5 via MT5",     category="index",      country="HK", cadence="daily",  timeframe="M5"),
    dict(symbol="BTCUSD", name="Bitcoin vs USD", description="BTC/USD M5 via MT5",  category="crypto",     country="--", cadence="hourly", timeframe="M5"),
]


def _conn_write():
    """Conexao de escrita ao DuckDB (1 escrita por vez por arquivo)."""
    from .collector import get_connection as _gc
    return _gc(read_only=False)


def _has_column(conn, table: str, col: str) -> bool:
    rows = conn.execute(f'PRAGMA table_info("{table}")').fetchall()
    return any(r[1] == col for r in rows)


def _add_catalog_columns(conn):
    for name, ctype in CATALOG_EXTRA_COLUMNS:
        if not _has_column(conn, "macro_catalog", name):
            conn.execute(f'ALTER TABLE macro_catalog ADD COLUMN "{name}" {ctype}')


def _backfill_existing_assets(conn):
    """Popula campos novos nas series macro existentes (FRED/YAHOO) de modo idempotente.

    IMPORTANTE: NUNCA force enabled=TRUE aqui. Series descontinuadas sao marcadas
    enabled=FALSE no catalogo; re-habilitar cegamente faz o gate volta-las p/ CRITICAL.
    """
    conn.execute("""
        UPDATE macro_catalog
        SET category_type = 'macro',
            collector     = source,
            target_table  = 'macro_series',
            enabled       = COALESCE(enabled, TRUE),
            min_freshness_hours = CASE
                WHEN symbol = 'DCOILBRENTEU' THEN 120
                WHEN symbol = 'DCOILWTICO' THEN 120
                WHEN symbol = 'DHHNGSP' THEN 120
                WHEN symbol IN ('KCRORO','KCROROE','KCROROG','KCROROL','KCROROS') THEN 96
                WHEN symbol = 'SOFR' THEN 96
                WHEN symbol = 'DGS30' THEN 96
                ELSE CASE lower(frequency)
                    WHEN 'hourly' THEN 2 WHEN 'daily' THEN 24
                    WHEN 'weekly' THEN 168 WHEN 'monthly' THEN 720
                    WHEN 'quarterly' THEN 2200 ELSE 24 END
            END
        WHERE symbol IN (SELECT DISTINCT symbol FROM macro_series)
    """)


def _upsert_ohlc_assets(conn):
    """Garante a presen a das 11 linhas OHLC no catalog (idempotente)."""
    for a in OHLC_ASSETS:
        fresh = FRESHNESS_BY_FREQUENCY.get(a["cadence"], FRESHNESS_BY_FREQUENCY["daily"])
        conn.execute("""
            INSERT INTO macro_catalog (symbol, name, category, subcategory, country,
                                       frequency, source, unit, description, fred_code,
                                       category_type, collector, target_table, timeframe,
                                       enabled, min_freshness_hours)
            SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, TRUE, ?
            WHERE NOT EXISTS (
                SELECT 1 FROM macro_catalog
                WHERE symbol = ? AND collector = 'MT5'
            )
        """, (
            a["symbol"], a["name"], a["category"], "market", a["country"],
            a["cadence"], "MT5", "price", a["description"], None,
            a["category"], "MT5", "ohlc_prices", a["timeframe"], fresh,
            a["symbol"],
        ))


def _upsert_kcroro_assets(conn):
    """Garante a presenca dos 5 ativos KCRORO (FRED, daily) no catalog (idempotente)."""
    fresh = FRESHNESS_BY_FREQUENCY.get("daily", 24)
    for a in KCRORO_ASSETS:
        conn.execute("""
            INSERT INTO macro_catalog (symbol, name, category, subcategory, country,
                                       frequency, source, unit, description, fred_code,
                                       category_type, collector, target_table, timeframe,
                                       enabled, min_freshness_hours)
            SELECT ?, ?, ?, 'market', ?, ?, 'FRED', 'index', ?, ?, 'macro', 'FRED',
                   'macro_series', NULL, TRUE, ?
            WHERE NOT EXISTS (
                SELECT 1 FROM macro_catalog
                WHERE symbol = ? AND collector = 'FRED'
            )
        """, (
            a["symbol"], a["name"], a["category"], "--", a["hyfreq"],
            a["description"] if "description" in a else (a["name"] + " (KC Fed)"),
            a["fred_code"], fresh, a["symbol"],
        ))


def _upsert_macro_economy_assets(conn):
    """Garante as series macro das 5 economias no catalog (idempotente).

    O spec vem do macro_state (Modulos.macro_state.registry.catalog_spec): o
    macro_state declara o que precisa; o datahouse eh quem escreve/coleta.

    Mantem a catalogacao atualizada mesmo quando uma serie ja existe com
    enabled=False ou metadados antigos.
    """
    from Modulos.macro_state.registry import catalog_spec
    freq_key = {"D": "daily", "W": "weekly", "M": "monthly", "Q": "quarterly", "A": "quarterly"}
    for a in catalog_spec():
        fk = freq_key.get((a.get("frequency") or "M").upper(), "monthly")
        fresh = FRESHNESS_BY_FREQUENCY.get(fk, 720)
        collector = (a.get("source") or "FRED").upper()
        if collector not in ("FRED", "YAHOO", "BCB"):
            collector = "FRED"
        row_exists = conn.execute(
            "SELECT 1 FROM macro_catalog WHERE symbol = ? AND collector = ? LIMIT 1",
            [a["symbol"], collector],
        ).fetchone()
        if row_exists:
            conn.execute(
                """
                UPDATE macro_catalog
                SET name = ?, category = ?, subcategory = ?, country = ?,
                    frequency = ?, source = ?, unit = ?, description = ?, fred_code = ?,
                    category_type = 'macro', collector = ?, target_table = 'macro_series',
                    timeframe = NULL, enabled = TRUE, min_freshness_hours = ?
                WHERE symbol = ? AND collector = ?
                """,
                [a["name"], a["category"], a["subcategory"], a["country"],
                 a["frequency"], a["source"], a["unit"], a["description"], a.get("fred_code") or a.get("series_id"),
                 collector, fresh, a["symbol"], collector],
            )
            continue

        conn.execute(
            """
            INSERT INTO macro_catalog (symbol, name, category, subcategory, country,
                                       frequency, source, unit, description, fred_code,
                                       category_type, collector, target_table, timeframe,
                                       enabled, min_freshness_hours)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'macro', ?, 'macro_series', NULL, TRUE, ?)
            """,
            [a["symbol"], a["name"], a["category"], a["subcategory"], a["country"],
             a["frequency"], a["source"], a["unit"], a["description"], a.get("fred_code") or a.get("series_id"),
             collector, fresh],
        )


def _create_update_schedule_view(conn):
    conn.execute("""
        CREATE OR REPLACE VIEW v_update_schedule AS
        WITH last_ohlc AS (
            SELECT symbol, timeframe, MAX(time) AS last_epoch
            FROM ohlc_prices GROUP BY symbol, timeframe
        ),
        last_macro AS (
            SELECT symbol,
                   CAST(EXTRACT(EPOCH FROM strptime(MAX(date), '%Y-%m-%d')) AS BIGINT) AS last_epoch
            FROM macro_series GROUP BY symbol
        )
        SELECT
            c.symbol,
            c.name,
            c.category_type AS asset_class,
            c.frequency      AS cadence,
            c.collector      AS collector,
            c.target_table   AS target_table,
            c.timeframe      AS timeframe,
            c.enabled        AS enabled,
            c.min_freshness_hours AS min_freshness_hours,
            COALESCE(o.last_epoch, m.last_epoch) AS last_epoch,
            CAST((EXTRACT(EPOCH FROM CURRENT_TIMESTAMP)
                  - COALESCE(o.last_epoch, m.last_epoch)) / 3600.0 AS DOUBLE) AS age_hours,
            CASE
                WHEN COALESCE(o.last_epoch, m.last_epoch) IS NULL THEN 'no_data'
                WHEN (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) - COALESCE(o.last_epoch, m.last_epoch)) / 3600.0 < c.min_freshness_hours THEN 'ok'
                WHEN (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) - COALESCE(o.last_epoch, m.last_epoch)) / 3600.0 < c.min_freshness_hours * CASE lower(c.frequency)
                    WHEN 'hourly' THEN 3 WHEN 'daily' THEN 3
                    WHEN 'weekly' THEN 4 WHEN 'monthly' THEN 6
                    WHEN 'quarterly' THEN 4 ELSE 3 END THEN 'stale'
                ELSE 'critical'
            END AS status
        FROM macro_catalog c
        LEFT JOIN last_ohlc  o ON c.target_table = 'ohlc_prices' AND o.symbol = c.symbol AND o.timeframe = c.timeframe
        LEFT JOIN last_macro m ON c.target_table = 'macro_series' AND m.symbol = c.symbol
        WHERE c.enabled = TRUE
    """)


def ensure_universe_catalog() -> dict:
    """Idempotente: garante colunas, backfill macro e OHLCs + view v_update_schedule.

    Returns:
        dict com contagem (rows_in_catalog, ohlc_rows, macros_rows) e view status.
    """
    conn = _conn_write()
    try:
        _add_catalog_columns(conn)
        _backfill_existing_assets(conn)
        _upsert_ohlc_assets(conn)
        _upsert_kcroro_assets(conn)
        _upsert_macro_economy_assets(conn)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_cat_symbol ON macro_catalog(symbol)")
        _create_update_schedule_view(conn)
        conn.commit()
        total = conn.execute("SELECT COUNT(*) FROM macro_catalog").fetchone()[0]
        ohlc = conn.execute("SELECT COUNT(*) FROM macro_catalog WHERE target_table='ohlc_prices'").fetchone()[0]
        macro = total - ohlc
        return dict(ok=True, rows_catalog=total, ohlc_assets=ohlc, macro_assets=macro)
    except Exception as e:
        return dict(ok=False, error=str(e))
    finally:
        conn.close()


def query_update_schedule() -> list[dict]:
    """Retorna a 'fonte unica (v_update_schedule) que o agendador consome."""
    with get_connection() as conn:
        rows = conn.execute("""
            SELECT symbol, asset_class, cadence, collector, target_table, timeframe,
                   enabled, min_freshness_hours, last_epoch, age_hours, status
            FROM v_update_schedule ORDER BY status, symbol
        """
        ).fetchall()
        cols = [d[0] for d in conn.description]
        return [dict(zip(cols, r)) for r in rows]


def _hours_since(ts: int) -> float:
    return (datetime.now(timezone.utc) - datetime.fromtimestamp(ts, tz=timezone.utc)).total_seconds() / 3600


def _freshness(hours: float) -> str:
    if hours < 24:     return "ok"
    if hours < 168:    return "stale"
    return "critical"


def _fmt_dt(ts: int) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d") if ts else "--"


def get_db_status() -> dict[str, Any]:
    with get_connection() as conn:
        now = datetime.now(timezone.utc)
        now_ts = int(now.timestamp())

        result = {"domains": [], "summary": {"total": 0, "ok": 0, "stale": 0, "critical": 0}}

        # OHLC
        ohlc_rows = conn.execute("""
            SELECT symbol, timeframe, COUNT(*), MIN(time), MAX(time), MAX(time)-MIN(time)
            FROM ohlc_prices GROUP BY symbol, timeframe ORDER BY symbol, timeframe
        """).fetchall()

        ohlc_children = []
        for r in ohlc_rows:
            sym, tf, n, first_ts, last_ts, range_s = r
            h = _hours_since(last_ts) if last_ts else 999999
            ohlc_children.append(dict(
                symbol=sym, timeframe=tf, rows=n,
                first_date=_fmt_dt(first_ts), last_date=_fmt_dt(last_ts),
                range_days=round(range_s / 86400, 1) if range_s else 0,
                hours_since=round(h, 1), status=_freshness(h),
            ))

        ohlc_total = sum(c["rows"] for c in ohlc_children) if ohlc_children else 0
        ohlc_stale = sum(1 for c in ohlc_children if c["status"] != "ok")
        result["domains"].append(dict(
            domain="OHLC", table="ohlc_prices",
            rows=ohlc_total, children=ohlc_children,
            status="critical" if ohlc_stale == len(ohlc_children) else ("stale" if ohlc_stale > 0 else "ok"),
        ))

        # Macro
        macro_rows = conn.execute("""
            SELECT COUNT(*), MIN(date), MAX(date), COUNT(DISTINCT symbol)
            FROM macro_series
        """).fetchone()
        mc, md_min, md_max, msym = macro_rows
        macro_missing = conn.execute("""
            SELECT COUNT(*) FROM macro_catalog c
            WHERE c.symbol NOT IN (SELECT DISTINCT symbol FROM macro_series)
        """).fetchone()[0]
        macro_h = _hours_since(int(datetime.strptime(md_max, "%Y-%m-%d").timestamp())) if md_max else 999999
        result["domains"].append(dict(
            domain="Macro", table="macro_series", rows=mc or 0,
            first_date=md_min or "--", last_date=md_max or "--",
            indicators=msym or 0, missing_indicators=macro_missing,
            hours_since=round(macro_h, 1), status=_freshness(macro_h),
        ))

        # Calendar
        cal_rows = conn.execute("""
            SELECT COUNT(*), MIN(event_time), MAX(event_time) FROM calendar_events
        """).fetchone()
        cc, cmin, cmax = cal_rows
        cal_h = _hours_since(cmax) if cmax else 999999
        cal_impacts = conn.execute("""
            SELECT impact, COUNT(*) FROM calendar_events GROUP BY impact ORDER BY COUNT(*) DESC
        """).fetchall()
        result["domains"].append(dict(
            domain="Calendar", table="calendar_events", rows=cc or 0,
            first_date=_fmt_dt(cmin) if cmin else "--",
            last_date=_fmt_dt(cmax) if cmax else "--",
            hours_since=round(cal_h, 1), status=_freshness(cal_h),
            impacts={r[0]: r[1] for r in cal_impacts},
        ))

        # Risk
        risk_rows = conn.execute("""
            SELECT COUNT(*), MIN(date), MAX(date) FROM risk_labels
        """).fetchone()
        rc, rmin, rmax = risk_rows
        risk_h = _hours_since(int(datetime.strptime(rmax, "%Y-%m-%d").timestamp())) if rmax else 999999
        risk_labels_dist = conn.execute("""
            SELECT risk_label, COUNT(*) FROM risk_labels GROUP BY risk_label ORDER BY COUNT(*) DESC
        """).fetchall()
        result["domains"].append(dict(
            domain="Risk", table="risk_labels", rows=rc or 0,
            first_date=rmin or "--", last_date=rmax or "--",
            hours_since=round(risk_h, 1), status=_freshness(risk_h),
            labels={r[0]: r[1] for r in risk_labels_dist},
        ))

        # Summary
        for d in result["domains"]:
            s = d["status"]
            result["summary"][s] = result["summary"].get(s, 0) + 1
            result["summary"]["total"] += 1
        result["summary"]["last_check"] = now.isoformat()

        return result


def get_ohlc_pairs() -> list[tuple[str, str]]:
    with get_connection() as conn:
        rows = conn.execute("SELECT DISTINCT symbol, timeframe FROM ohlc_prices ORDER BY symbol, timeframe").fetchall()
        return [(r[0], r[1]) for r in rows]


def get_all_symbols() -> list[str]:
    with get_connection() as conn:
        rows = conn.execute("SELECT DISTINCT symbol FROM ohlc_prices ORDER BY symbol").fetchall()
        return [r[0] for r in rows]


def get_all_timeframes() -> list[str]:
    with get_connection() as conn:
        rows = conn.execute("SELECT DISTINCT timeframe FROM ohlc_prices ORDER BY timeframe").fetchall()
        return [r[0] for r in rows]
