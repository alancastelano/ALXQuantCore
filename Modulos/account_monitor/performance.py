"""Calculo de P&L (daily/weekly/monthly) e drawdown.

Metodologia:
    - Today = deals fechados hoje + profit flutuante (posicoes abertas)
    - Week  = deals fechados na semana (seg-dom UTC)
    - Month = deals fechados no mes
    - DD Day   = max drawdown intra-day (peak-to-trough dentro do dia)
    - DD Total = max drawdown all-time (peak-to-trough lifetime)
    - Depositos/retiradas/creditos NAO contam como P&L.
    - Janelas definidas em UTC.
"""
from datetime import datetime, timezone

import duckdb


def _start_of_day_ts(dt: datetime) -> float:
    return datetime(dt.year, dt.month, dt.day, tzinfo=timezone.utc).timestamp()


def _start_of_week_ts(dt: datetime) -> float:
    day = dt.weekday()  # Monday=0
    return datetime(dt.year, dt.month, dt.day, tzinfo=timezone.utc).timestamp() - day * 86400


def _start_of_month_ts(dt: datetime) -> float:
    return datetime(dt.year, dt.month, 1, tzinfo=timezone.utc).timestamp()


def _pnl_deals(conn: duckdb.DuckDBPyConnection, account_id: str, since_ts: float) -> float:
    """Soma profit+swap+commission de deals fechados desde since_ts."""
    row = conn.execute("""
        SELECT COALESCE(SUM(profit + swap + commission), 0.0)
        FROM deal_events
        WHERE account_id=? AND close_time >= ?
    """, [account_id, since_ts]).fetchone()
    return float(row[0]) if row else 0.0


def _pnl_floating(conn: duckdb.DuckDBPyConnection, account_id: str) -> float:
    """Profit flutuante das posicoes abertas (realizado + unrealizado)."""
    row = conn.execute(
        "SELECT COALESCE(SUM(profit), 0.0) FROM positions_current WHERE account_id=?",
        [account_id],
    ).fetchone()
    return float(row[0]) if row else 0.0


def _compute_dd_from_snapshots(rows: list) -> float:
    """Computa max drawdown percentual a partir de uma lista de equities ordenadas por ts.

    Retorna o pior DD% (0.0 = sem drawdown).
    """
    if not rows:
        return 0.0
    peak = rows[0][0] or 0.0
    dd = 0.0
    for (eq,) in rows:
        if eq is None:
            continue
        if eq > peak:
            peak = eq
        if peak > 0:
            dd = max(dd, (peak - eq) / peak * 100.0)
    return dd


def _compute_dd_overall(conn: duckdb.DuckDBPyConnection, account_id: str) -> float:
    """Max drawdown all-time (lifetime peak → pior trough)."""
    rows = conn.execute(
        "SELECT equity FROM account_snapshots WHERE account_id=? ORDER BY ts",
        [account_id],
    ).fetchall()
    return _compute_dd_from_snapshots(rows)


def _compute_dd_today(conn: duckdb.DuckDBPyConnection, account_id: str) -> float:
    """Max drawdown intra-day (peak dentro do dia → pior trough do dia)."""
    today_start = _start_of_day_ts(datetime.now(timezone.utc))
    rows = conn.execute(
        "SELECT equity FROM account_snapshots WHERE account_id=? AND ts >= ? ORDER BY ts",
        [account_id, today_start],
    ).fetchall()
    return _compute_dd_from_snapshots(rows)


def performance_for(conn: duckdb.DuckDBPyConnection, account_id: str) -> dict:
    """Computa P&L e drawdown para uma conta.

    Returns:
        daily:   deals fechados hoje + profit flutuante
        weekly:  deals fechados na semana (fechados apenas)
        monthly: deals fechados no mes (fechados apenas)
        drawdown_today:  max DD intra-day
        drawdown_pct:    max DD all-time
    """
    now = datetime.now(timezone.utc)

    # P&L — fechados
    daily_closed = _pnl_deals(conn, account_id, _start_of_day_ts(now))
    weekly = _pnl_deals(conn, account_id, _start_of_week_ts(now))
    monthly = _pnl_deals(conn, account_id, _start_of_month_ts(now))

    # P&L — flutuante
    floating = _pnl_floating(conn, account_id)

    # Today = fechados + flutuante
    daily = daily_closed + floating

    # Drawdown
    dd_today = _compute_dd_today(conn, account_id)
    dd_overall = _compute_dd_overall(conn, account_id)

    return {
        "daily": daily,
        "weekly": weekly,
        "monthly": monthly,
        "drawdown_today": round(dd_today, 2),
        "drawdown_pct": round(dd_overall, 2),
    }


def equity_curve(conn: duckdb.DuckDBPyConnection, account_id: str) -> list[dict]:
    """Retorna serie temporal de equity para o grafico.

    Returns:
        [{"time": "2026-09-01", "value": 10000}, ...]
    """
    rows = conn.execute(
        "SELECT ts, equity FROM account_snapshots WHERE account_id=? ORDER BY ts",
        [account_id],
    ).fetchall()
    if not rows:
        return []
    result = []
    for ts, eq in rows:
        if eq is None:
            continue
        dt = datetime.fromtimestamp(ts, tz=timezone.utc)
        result.append({"time": dt.strftime("%Y-%m-%d"), "value": round(eq, 2)})
    return result


def trade_statistics(conn: duckdb.DuckDBPyConnection, account_id: str) -> dict:
    """Computa estatisticas de trading a partir dos deal_events.

    Returns:
        total_trades, win_rate, profit_factor, expectancy,
        avg_win, avg_loss, best_trade, worst_trade,
        total_profit, total_loss, avg_rr (risk/reward ratio)
    """
    rows = conn.execute("""
        SELECT profit + swap + commission AS net
        FROM deal_events
        WHERE account_id=?
        ORDER BY close_time
    """, [account_id]).fetchall()

    if not rows:
        return {
            "total_trades": 0, "win_rate": 0, "profit_factor": 0,
            "expectancy": 0, "avg_win": 0, "avg_loss": 0,
            "best_trade": 0, "worst_trade": 0,
            "total_profit": 0, "total_loss": 0, "avg_rr": 0,
        }

    nets = [float(r[0]) for r in rows if r[0] is not None]
    wins = [n for n in nets if n > 0]
    losses = [n for n in nets if n < 0]

    total = len(nets)
    win_count = len(wins)
    win_rate = (win_count / total * 100) if total > 0 else 0

    total_profit = sum(wins)
    total_loss = abs(sum(losses))
    profit_factor = (total_profit / total_loss) if total_loss > 0 else (999.0 if total_profit > 0 else 0)

    avg_win = (total_profit / win_count) if win_count > 0 else 0
    avg_loss = (total_loss / len(losses)) if losses else 0

    expectancy = (win_rate / 100 * avg_win) - ((1 - win_rate / 100) * avg_loss)

    avg_rr = (avg_win / avg_loss) if avg_loss > 0 else 0

    return {
        "total_trades": total,
        "win_rate": round(win_rate, 1),
        "profit_factor": round(profit_factor, 2),
        "expectancy": round(expectancy, 2),
        "avg_win": round(avg_win, 2),
        "avg_loss": round(avg_loss, 2),
        "best_trade": round(max(nets), 2) if nets else 0,
        "worst_trade": round(min(nets), 2) if nets else 0,
        "total_profit": round(total_profit, 2),
        "total_loss": round(total_loss, 2),
        "avg_rr": round(avg_rr, 2),
    }


def dashboard_summary() -> dict:
    """Cards agregados: total accounts, online/offline, equity, P&L totais, DD."""
    from . import db
    conn = db.get_connection(read_only=True)
    try:
        rows = conn.execute(
            "SELECT account_id, equity, status, last_seen_ts, pnl_week, pnl_month FROM accounts_current"
        ).fetchall()
    finally:
        conn.close()

    total = len(rows)
    online = sum(1 for r in rows if r[2] == "ONLINE")
    offline = sum(1 for r in rows if r[2] == "OFFLINE")
    warning = total - online - offline
    total_equity = sum((r[1] or 0.0) for r in rows)

    pnl_d = pnl_w = pnl_m = 0.0
    conn = db.get_connection(read_only=True)
    try:
        for r in rows:
            perf = performance_for(conn, r[0])
            pnl_d += perf["daily"]
            # Usar valores do EA (gravados em accounts_current)
            pnl_w += r[4] or 0.0
            pnl_m += r[5] or 0.0
    finally:
        conn.close()

    return {
        "total_accounts": total,
        "online": online,
        "warning": warning,
        "offline": offline,
        "total_equity": total_equity,
        "total_pnl_today": pnl_d,
        "total_pnl_week": pnl_w,
        "total_pnl_month": pnl_m,
    }


def symbol_summary(conn: duckdb.DuckDBPyConnection, account_id: str) -> list[dict]:
    """Performance por ativo (Myfxbook Summary style).

    Retorna lista de dicts com: symbol, trades, longs, shorts, wins, losses,
    profit, win_pct, total_win, total_loss.
    """
    rows = conn.execute("""
        SELECT symbol,
               COUNT(*) as total_trades,
               SUM(CASE WHEN type='BUY' THEN 1 ELSE 0 END) as longs,
               SUM(CASE WHEN type='SELL' THEN 1 ELSE 0 END) as shorts,
               SUM(CASE WHEN (profit+swap+commission) > 0 THEN 1 ELSE 0 END) as wins,
               SUM(CASE WHEN (profit+swap+commission) <= 0 THEN 1 ELSE 0 END) as losses,
               COALESCE(SUM(profit+swap+commission), 0) as total_profit,
               COALESCE(SUM(CASE WHEN (profit+swap+commission) > 0 THEN profit+swap+commission ELSE 0 END), 0) as total_win,
               COALESCE(SUM(CASE WHEN (profit+swap+commission) <= 0 THEN ABS(profit+swap+commission) ELSE 0 END), 0) as total_loss
        FROM deal_events
        WHERE account_id=?
        GROUP BY symbol
        ORDER BY total_profit DESC
    """, [account_id]).fetchall()

    return [{
        "symbol": r[0], "trades": r[1], "longs": r[2], "shorts": r[3],
        "wins": r[4], "losses": r[5], "profit": round(r[6], 2),
        "win_pct": round(r[4] / r[1] * 100, 1) if r[1] > 0 else 0,
        "total_win": round(r[7], 2), "total_loss": round(r[8], 2),
    } for r in rows]


def winners_losers(conn: duckdb.DuckDBPyConnection, account_id: str) -> dict:
    """Dados para grafico Winners vs Losers.

    Retorna: win_count, loss_count, win_profit, loss_profit,
    long_wins, long_losses, short_wins, short_losses.
    """
    row = conn.execute("""
        SELECT
            COALESCE(SUM(CASE WHEN profit+swap+commission > 0 THEN 1 ELSE 0 END), 0) as win_count,
            COALESCE(SUM(CASE WHEN profit+swap+commission <= 0 THEN 1 ELSE 0 END), 0) as loss_count,
            COALESCE(SUM(CASE WHEN profit+swap+commission > 0 THEN profit+swap+commission ELSE 0 END), 0) as win_profit,
            COALESCE(SUM(CASE WHEN profit+swap+commission <= 0 THEN ABS(profit+swap+commission) ELSE 0 END), 0) as loss_profit,
            COALESCE(SUM(CASE WHEN type='BUY' AND profit+swap+commission > 0 THEN 1 ELSE 0 END), 0) as long_wins,
            COALESCE(SUM(CASE WHEN type='BUY' AND profit+swap+commission <= 0 THEN 1 ELSE 0 END), 0) as long_losses,
            COALESCE(SUM(CASE WHEN type='SELL' AND profit+swap+commission > 0 THEN 1 ELSE 0 END), 0) as short_wins,
            COALESCE(SUM(CASE WHEN type='SELL' AND profit+swap+commission <= 0 THEN 1 ELSE 0 END), 0) as short_losses,
            COALESCE(SUM(CASE WHEN type='BUY' THEN profit+swap+commission ELSE 0 END), 0) as long_profit,
            COALESCE(SUM(CASE WHEN type='SELL' THEN profit+swap+commission ELSE 0 END), 0) as short_profit
        FROM deal_events
        WHERE account_id=?
    """, [account_id]).fetchone()

    return {
        "win_count": row[0], "loss_count": row[1],
        "win_profit": round(row[2], 2), "loss_profit": round(row[3], 2),
        "long_wins": row[4], "long_losses": row[5],
        "short_wins": row[6], "short_losses": row[7],
        "long_profit": round(row[8], 2), "short_profit": round(row[9], 2),
    }


def daily_calendar(conn: duckdb.DuckDBPyConnection, account_id: str,
                   year: int, month: int) -> list[dict]:
    """Dados diarios para view de calendario.

    Retorna lista de dicts com: day (YYYY-MM-DD), trades, losses, pnl.
    """
    start_dt = datetime(year, month, 1, tzinfo=timezone.utc)
    start_ts = start_dt.timestamp()
    if month == 12:
        end_dt = datetime(year + 1, 1, 1, tzinfo=timezone.utc)
    else:
        end_dt = datetime(year, month + 1, 1, tzinfo=timezone.utc)
    end_ts = end_dt.timestamp()

    rows = conn.execute("""
        SELECT DATE(close_time) as day,
               COUNT(*) as trades,
               COALESCE(SUM(CASE WHEN profit+swap+commission <= 0 THEN 1 ELSE 0 END), 0) as losses,
               COALESCE(SUM(profit+swap+commission), 0) as pnl
        FROM deal_events
        WHERE account_id=? AND close_time >= ? AND close_time < ?
        GROUP BY day
        ORDER BY day
    """, [account_id, start_ts, end_ts]).fetchall()

    return [{"day": str(r[0]), "trades": r[1], "losses": r[2],
             "pnl": round(r[3], 2)} for r in rows]


# ---------------------------------------------------------------------------
# Global analytics (todas as contas)
# ---------------------------------------------------------------------------

def global_symbol_summary(conn: duckdb.DuckDBPyConnection) -> list[dict]:
    """Summary por ativo agregando todas as contas monitoradas."""
    rows = conn.execute("""
        SELECT symbol,
               COUNT(DISTINCT account_id) as accounts,
               COUNT(*) as total_trades,
               SUM(CASE WHEN type='BUY' THEN 1 ELSE 0 END) as longs,
               SUM(CASE WHEN type='SELL' THEN 1 ELSE 0 END) as shorts,
               SUM(CASE WHEN (profit+swap+commission) > 0 THEN 1 ELSE 0 END) as wins,
               SUM(CASE WHEN (profit+swap+commission) <= 0 THEN 1 ELSE 0 END) as losses,
               COALESCE(SUM(profit+swap+commission), 0) as total_profit,
               COALESCE(SUM(CASE WHEN (profit+swap+commission) > 0 THEN profit+swap+commission ELSE 0 END), 0) as total_win,
               COALESCE(SUM(CASE WHEN (profit+swap+commission) <= 0 THEN ABS(profit+swap+commission) ELSE 0 END), 0) as total_loss
        FROM deal_events
        GROUP BY symbol
        ORDER BY total_profit DESC
    """).fetchall()

    return [{
        "symbol": r[0], "accounts": r[1], "trades": r[2], "longs": r[3],
        "shorts": r[4], "wins": r[5], "losses": r[6], "profit": round(r[7], 2),
        "win_pct": round(r[5] / r[2] * 100, 1) if r[2] > 0 else 0,
        "total_win": round(r[8], 2), "total_loss": round(r[9], 2),
    } for r in rows]


def global_daily_calendar(conn: duckdb.DuckDBPyConnection,
                          year: int, month: int) -> list[dict]:
    """Dados diarios para calendario global (todas as contas)."""
    start_dt = datetime(year, month, 1, tzinfo=timezone.utc)
    start_ts = start_dt.timestamp()
    if month == 12:
        end_dt = datetime(year + 1, 1, 1, tzinfo=timezone.utc)
    else:
        end_dt = datetime(year, month + 1, 1, tzinfo=timezone.utc)
    end_ts = end_dt.timestamp()

    rows = conn.execute("""
        SELECT DATE(close_time) as day,
               COUNT(*) as trades,
               COALESCE(SUM(CASE WHEN profit+swap+commission <= 0 THEN 1 ELSE 0 END), 0) as losses,
               COALESCE(SUM(profit+swap+commission), 0) as pnl
        FROM deal_events
        WHERE close_time >= ? AND close_time < ?
        GROUP BY day
        ORDER BY day
    """, [start_ts, end_ts]).fetchall()

    return [{"day": str(r[0]), "trades": r[1], "losses": r[2],
             "pnl": round(r[3], 2)} for r in rows]


# ---------------------------------------------------------------------------
# Advanced Summary (Myfxbook-style per-symbol x per-period matrix)
# ---------------------------------------------------------------------------

def _symbol_period_stats(conn: duckdb.DuckDBPyConnection, account_id: str,
                         since_ts: float = 0.0) -> dict:
    """Retorna stats por símbolo para deals fechados desde since_ts."""
    if since_ts > 0:
        rows = conn.execute("""
            SELECT symbol,
                   COUNT(*) as trades,
                   SUM(CASE WHEN (profit+swap+commission) > 0 THEN 1 ELSE 0 END) as wins,
                   COALESCE(SUM(profit+swap+commission), 0) as gain
            FROM deal_events
            WHERE account_id=? AND close_time >= ?
            GROUP BY symbol
        """, [account_id, since_ts]).fetchall()
    else:
        rows = conn.execute("""
            SELECT symbol,
                   COUNT(*) as trades,
                   SUM(CASE WHEN (profit+swap+commission) > 0 THEN 1 ELSE 0 END) as wins,
                   COALESCE(SUM(profit+swap+commission), 0) as gain
            FROM deal_events
            WHERE account_id=?
            GROUP BY symbol
        """, [account_id]).fetchall()

    result = {}
    for r in rows:
        trades = r[1]
        wins = r[2] or 0
        result[r[0]] = {
            "gain": round(float(r[3]), 2),
            "trades": trades,
            "wins": wins,
            "win_pct": round(wins / trades * 100, 1) if trades > 0 else 0,
        }
    return result


def _floating_by_symbol(conn: duckdb.DuckDBPyConnection, account_id: str) -> dict:
    """P&L flutuante por símbolo (posições abertas)."""
    rows = conn.execute("""
        SELECT symbol,
               COUNT(*) as trades,
               COALESCE(SUM(profit), 0) as gain
        FROM positions_current
        WHERE account_id=?
        GROUP BY symbol
    """, [account_id]).fetchall()

    result = {}
    for r in rows:
        result[r[0]] = {
            "gain": round(float(r[2]), 2),
            "trades": r[1],
            "wins": 0,
            "win_pct": 0,
        }
    return result


def advanced_summary(conn: duckdb.DuckDBPyConnection, account_id: str) -> dict:
    """Advanced Summary estilo Myfxbook.

    Retorna matriz de performance por símbolo x período:
    floating (posições abertas), today, week, month, year, all (lifetime).
    """
    now = datetime.now(timezone.utc)
    today_start = _start_of_day_ts(now)
    week_start = _start_of_week_ts(now)
    month_start = _start_of_month_ts(now)
    year_start = datetime(now.year, 1, 1, tzinfo=timezone.utc).timestamp()

    floating = _floating_by_symbol(conn, account_id)
    today = _symbol_period_stats(conn, account_id, today_start)
    week = _symbol_period_stats(conn, account_id, week_start)
    month = _symbol_period_stats(conn, account_id, month_start)
    year = _symbol_period_stats(conn, account_id, year_start)
    all_time = _symbol_period_stats(conn, account_id)

    all_symbols = sorted(set(
        list(floating.keys()) + list(today.keys()) + list(week.keys()) +
        list(month.keys()) + list(year.keys()) + list(all_time.keys())
    ))

    symbols = []
    for sym in all_symbols:
        symbols.append({
            "symbol": sym,
            "floating": floating.get(sym, {"gain": 0, "trades": 0, "wins": 0, "win_pct": 0}),
            "today": today.get(sym, {"gain": 0, "trades": 0, "wins": 0, "win_pct": 0}),
            "week": week.get(sym, {"gain": 0, "trades": 0, "wins": 0, "win_pct": 0}),
            "month": month.get(sym, {"gain": 0, "trades": 0, "wins": 0, "win_pct": 0}),
            "year": year.get(sym, {"gain": 0, "trades": 0, "wins": 0, "win_pct": 0}),
            "all": all_time.get(sym, {"gain": 0, "trades": 0, "wins": 0, "win_pct": 0}),
        })

    return {"symbols": symbols}


# ---------------------------------------------------------------------------
# Monthly Performance Grid (Myfxbook-style year x month matrix)
# ---------------------------------------------------------------------------

def monthly_performance_grid(conn: duckdb.DuckDBPyConnection, account_id: str) -> dict:
    """Grade de performance mensal: linhas=anos, colunas=meses.

    Retorna:
    {
      "years": [
        {
          "year": 2024,
          "months": [2.1, -0.5, 3.2, ...],  // Jan=0, Feb=1, ..., Dec=11
          "total": 12.5
        }, ...
      ]
    }
    """
    rows = conn.execute("""
        SELECT EXTRACT(YEAR FROM TO_TIMESTAMP(close_time)) as yr,
               EXTRACT(MONTH FROM TO_TIMESTAMP(close_time)) as mo,
               COALESCE(SUM(profit+swap+commission), 0) as pnl
        FROM deal_events
        WHERE account_id=?
        GROUP BY yr, mo
        ORDER BY yr, mo
    """, [account_id]).fetchall()

    year_map = {}
    for yr, mo, pnl in rows:
        yr = int(yr)
        mo = int(mo)
        if yr not in year_map:
            year_map[yr] = [0.0] * 12
        year_map[yr][mo - 1] += float(pnl)

    years = []
    for yr in sorted(year_map.keys()):
        months = year_map[yr]
        total = round(sum(months), 2)
        years.append({
            "year": yr,
            "months": [round(m, 2) for m in months],
            "total": total,
        })

    return {"years": years}


# ---------------------------------------------------------------------------
# Duration Analysis (distribution of trade holding times)
# ---------------------------------------------------------------------------

def duration_analysis(conn: duckdb.DuckDBPyConnection, account_id: str) -> dict:
    """Distribuição de trades por duração.

    Buckets: <1h, 1-4h, 4h-1d, 1d-7d, >7d

    Retorna:
    {
      "buckets": [
        {"label": "< 1h", "count": 15, "profit": 250.0},
        {"label": "1-4h", "count": 30, "profit": 500.0},
        ...
      ],
      "avg_duration_sec": 12345
    }
    """
    rows = conn.execute("""
        SELECT close_time - open_time as duration,
               profit + swap + commission as net
        FROM deal_events
        WHERE account_id=? AND close_time > 0 AND open_time > 0
    """, [account_id]).fetchall()

    if not rows:
        return {"buckets": [], "avg_duration_sec": 0}

    buckets = [
        {"label": "< 1h", "max_sec": 3600, "count": 0, "profit": 0.0},
        {"label": "1-4h", "max_sec": 14400, "count": 0, "profit": 0.0},
        {"label": "4h-1d", "max_sec": 86400, "count": 0, "profit": 0.0},
        {"label": "1d-7d", "max_sec": 604800, "count": 0, "profit": 0.0},
        {"label": "> 7d", "max_sec": 999999999, "count": 0, "profit": 0.0},
    ]

    total_duration = 0.0
    for dur, net in rows:
        d = float(dur or 0)
        n = float(net or 0)
        total_duration += d
        for b in buckets:
            if d < b["max_sec"]:
                b["count"] += 1
                b["profit"] += n
                break

    avg_dur = total_duration / len(rows) if rows else 0

    return {
        "buckets": [
            {"label": b["label"], "count": b["count"],
             "profit": round(b["profit"], 2)}
            for b in buckets
        ],
        "avg_duration_sec": round(avg_dur),
    }


# ---------------------------------------------------------------------------
# Overall gain metrics (for top-level cards)
# ---------------------------------------------------------------------------

def overall_metrics(conn: duckdb.DuckDBPyConnection, account_id: str) -> dict:
    """Métricas gerais estilo Myfxbook: gain%, abs_gain, daily%, monthly%.

    Retorna:
    {
      "gain_pct": 12.5,
      "abs_gain": 1250.00,
      "daily_pct": 0.5,
      "monthly_pct": 3.2,
      "initial_balance": 10000.0,
      "deposits": 0.0,
      "withdrawals": 0.0,
    }
    """
    row = conn.execute("""
        SELECT balance, equity FROM accounts_current WHERE account_id=?
    """, [account_id]).fetchone()

    if not row:
        return {"gain_pct": 0, "abs_gain": 0, "daily_pct": 0,
                "monthly_pct": 0, "initial_balance": 0, "deposits": 0,
                "withdrawals": 0}

    balance = float(row[0] or 0)
    equity = float(row[1] or 0)

    first_snap = conn.execute("""
        SELECT balance FROM account_snapshots
        WHERE account_id=? ORDER BY ts ASC LIMIT 1
    """, [account_id]).fetchone()

    initial_balance = float(first_snap[0]) if first_snap and first_snap[0] else balance

    profit_closed = conn.execute("""
        SELECT COALESCE(SUM(profit + swap + commission), 0)
        FROM deal_events WHERE account_id=?
    """, [account_id]).fetchone()

    total_profit = float(profit_closed[0] or 0)
    abs_gain = round(total_profit, 2)
    gain_pct = round(total_profit / initial_balance * 100, 2) if initial_balance > 0 else 0

    perf = performance_for(conn, account_id)
    daily_pct = round(perf["daily"] / balance * 100, 2) if balance > 0 else 0
    monthly_pct = round(perf["monthly"] / balance * 100, 2) if balance > 0 else 0

    return {
        "gain_pct": gain_pct,
        "abs_gain": abs_gain,
        "daily_pct": daily_pct,
        "monthly_pct": monthly_pct,
        "initial_balance": initial_balance,
        "deposits": 0.0,
        "withdrawals": 0.0,
    }
