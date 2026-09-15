"""Coleta incremental de OHLC via MetaTrader 5 com sincronização para DuckDB.

Pipeline:
    1. Conecta ao MT5 (initialize) com credenciais de .env
    2. Baixa rates via copy_rates_range em chunks de CHUNK_DAYS
    3. Insere em ohlc_prices (DuckDB) sem duplicar timestamps existentes

Usage (CLI):
    python -m Modulos.datahouse.cli_collector --symbol XAUUSD --tf M5
"""
import os
import sys
import time as _time
from datetime import datetime, timedelta, timezone
from typing import Optional

import duckdb
import MetaTrader5 as mt5
import pandas as pd
from dotenv import load_dotenv
import os
from pathlib import Path

# Use centralized config
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
import config

load_dotenv(config.PROJECT_ROOT / ".env", override=True)

DB_PATH = config.DB_PATH

MT5_PATH = config.config.mt5.path
MT5_ACCOUNT = config.config.mt5.account
MT5_PASSWORD = config.config.mt5.password
MT5_SERVER = config.config.mt5.server

TIMEFRAME_MAP = {
    "M1": mt5.TIMEFRAME_M1, "M5": mt5.TIMEFRAME_M5, "M15": mt5.TIMEFRAME_M15,
    "M30": mt5.TIMEFRAME_M30, "H1": mt5.TIMEFRAME_H1, "H4": mt5.TIMEFRAME_H4,
    "D1": mt5.TIMEFRAME_D1,
}

CHUNK_DAYS = 60

# Diretórios de runtime exigidos (data/* é gitignored: clones frescos não os têm).
# Espelha o layout documentado em ARCHITECTURE.md (Camada de Dados).
REQUIRED_DATA_DIRS = ("logs", "mql5", "image", "cache", "state")


def ensure_data_dirs() -> Path:
    """Cria os subdiretórios de data/ se ausentes. Idempotente."""
    data_dir = config.PROJECT_ROOT / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    for sub in REQUIRED_DATA_DIRS:
        (data_dir / sub).mkdir(parents=True, exist_ok=True)
    return data_dir


OHLC_DDL = """
CREATE TABLE IF NOT EXISTS ohlc_prices (
  symbol VARCHAR,
  timeframe VARCHAR,
  time BIGINT,
  open DOUBLE,
  high DOUBLE,
  low DOUBLE,
  close DOUBLE,
  tick_volume BIGINT,
  spread INTEGER,
  real_volume BIGINT
)
"""

OHLC_INDEX_DDL = """
CREATE UNIQUE INDEX IF NOT EXISTS idx_ohlc_sym_tf_time
ON ohlc_prices(symbol, timeframe, time)
"""

MACRO_DDL = """
CREATE TABLE IF NOT EXISTS macro_series (
  symbol VARCHAR,
  date VARCHAR,
  value DOUBLE,
  updated_at VARCHAR
)
"""

MACRO_INDEX_DDL = """
CREATE INDEX IF NOT EXISTS idx_macro_sym_date
ON macro_series(symbol, date)
"""

RISK_DDL = """
CREATE TABLE IF NOT EXISTS risk_labels (
  date VARCHAR,
  risk_label VARCHAR,
  roro_score DOUBLE,
  signal_strength VARCHAR DEFAULT 'low'
)
"""

RISK_INDEX_DDL = """
CREATE INDEX IF NOT EXISTS idx_risk_date
ON risk_labels(date)
"""

# Espelha as colunas usadas pelos INSERTs/UPDATEs de engine.py
# (_upsert_macro_economy_assets, _upsert_ohlc_assets, _upsert_kcroro_assets)
# + CATALOG_EXTRA_COLUMNS. Base para ensure_universe_catalog() semear a view.
CATALOG_DDL = """
CREATE TABLE IF NOT EXISTS macro_catalog (
  symbol VARCHAR,
  name VARCHAR,
  category VARCHAR,
  subcategory VARCHAR,
  country VARCHAR,
  frequency VARCHAR,
  source VARCHAR,
  unit VARCHAR,
  description VARCHAR,
  fred_code VARCHAR,
  category_type VARCHAR,
  collector VARCHAR,
  target_table VARCHAR,
  timeframe VARCHAR,
  enabled BOOLEAN,
  min_freshness_hours INTEGER
)
"""


def init_db(db_path=None) -> str:
    """Garante arquivo + schema do DuckDB (cria se ausente). Idempotente.

    Cobre clones frescos e o fluxo 'recoleta do zero': o coletor nunca
    mais falha por tabela ou diretório inexistente.
    """
    ensure_data_dirs()
    target = Path(db_path) if db_path else Path(DB_PATH)
    target.parent.mkdir(parents=True, exist_ok=True)
    conn = duckdb.connect(str(target))
    try:
        conn.execute(OHLC_DDL)
        conn.execute(OHLC_INDEX_DDL)
        conn.execute(MACRO_DDL)
        conn.execute(MACRO_INDEX_DDL)
        conn.execute(RISK_DDL)
        conn.execute(RISK_INDEX_DDL)
        conn.execute(CATALOG_DDL)
        conn.commit()
    finally:
        conn.close()
    # Semeia catalogo (OHLC+KCRORO+macro) + view v_update_schedule — somente
    # no DB oficial (ensure abre a propria conexao no DB_PATH padrao).
    # Lazy para evitar ciclo de import; nossa conexao ja fechou (sem lock).
    if Path(target) == Path(DB_PATH):
        from Modulos.datahouse.engine import ensure_universe_catalog
        ensure_universe_catalog()
    return str(target)

# Canal de simbolos internos (canonicos no DB) -> simbolo do broker MT5.
MT5_SYMBOL_ALIAS = {
    "US100": "NAS100",
}


def canonical_mt5_symbol(symbol: str) -> str:
    """Retorna o nome do simbolo tal como existe no broker MT5.

    O DB guarda o simbolo canonico (ex: US100); o broker fornece um nome
    diferente (ex: NAS100). Nada muda se nao ha alias.
    """
    return MT5_SYMBOL_ALIAS.get(symbol, symbol)


# Canal de simbolos canonicos -> ticker yfinance (fallback quando MT5 indisponivel).
# Permite coletar OHLC mesmo sem a sessao do MT5 (ex.: task SYSTEM agendada).
YFINANCE_SYMBOL_ALIAS = {
    "XAUUSD": "GC=F", "XAGUSD": "SI=F", "WTI": "CL=F", "BRENT": "BZ=F",
    "NATGAS": "NG=F", "US500": "ES=F", "US30": "YM=F", "NAS100": "NQ=F",
    "GER40": "DAX=F", "UK100": "FTSE=F", "JPN225": "N225=F",
    "BTCUSD": "BTC-USD", "ETHUSD": "ETH-USD",
    "EURUSD": "EURUSD=X", "USDJPY": "USDJPY=X", "GBPUSD": "GBPUSD=X",
}

YF_INTERVAL_MAP = {
    "M1": "1m", "M5": "5m", "M15": "15m", "M30": "30m",
    "H1": "1h", "H4": "4h", "D1": "1d",
}


def _fetch_range_yfinance(symbol: str, tf_name: str, from_dt: datetime, to_dt: datetime):
    """Fallback de OHLC via yfinance (sem MT5).

    Retorna DataFrame com colunas time, open, high, low, close, tick_volume,
    ou None se indisponivel. Janela intraday do yfinance e limitada (~7d p/ 5m),
    entao preenche apenas o trecho recente quando usado como fallback.
    """
    try:
        import yfinance as yf
    except Exception:
        return None
    ticker = YFINANCE_SYMBOL_ALIAS.get(symbol, symbol)
    interval = YF_INTERVAL_MAP.get(tf_name)
    if interval is None:
        return None
    try:
        df = yf.download(
            ticker, start=from_dt, end=to_dt, interval=interval,
            progress=False, auto_adjust=False, actions=False,
        )
    except Exception as e:
        print(f"[yfinance] {symbol} download falhou: {e}")
        return None
    if df is None or len(df) == 0:
        return None
    if isinstance(df.columns, pd.MultiIndex):
        df = df.droplevel(1, axis=1)
    df.columns = [str(c).strip().lower() for c in df.columns]
    out = pd.DataFrame()
    out["time"] = df.index.to_pydatetime()
    out["open"] = df.get("open").astype(float).values
    out["high"] = df.get("high").astype(float).values
    out["low"] = df.get("low").astype(float).values
    out["close"] = df.get("close").astype(float).values
    vol = df.get("volume")
    out["tick_volume"] = (vol.astype("int64").values if vol is not None else 0)
    out.drop_duplicates(subset="time", keep="first", inplace=True)
    out.sort_values("time", inplace=True)
    out.reset_index(drop=True, inplace=True)
    return out


def get_connection(read_only: bool = False, retries: int = 5, retry_delay: float = 0.5) -> duckdb.DuckDBPyConnection:
    """Conexão central ao DuckDB do ALXQuant.

    Usa read_only=False por padrao para evitar o erro "different configuration"
    do DuckDB no Windows (nao mistura read_only=True e False no mesmo processo).
    O retry lida com locks temporarios (ex.: risk_sentiment.engine abrindo write).
    """
    import time as _time
    if not os.path.exists(DB_PATH):
        raise FileNotFoundError(f"Database not found: {DB_PATH}")
    last_err = None
    for attempt in range(retries):
        try:
            conn = duckdb.connect(DB_PATH, read_only=read_only)
            if attempt > 0:
                print(f"[DB] Conexão obtida após {attempt} tentativa(s)")
            return conn
        except Exception as e:
            msg = str(e).lower()
            is_lock = ("already in use" in msg or "sendo usado" in msg or "io error" in msg
                       or "different configuration" in msg or "configuração" in msg)
            if is_lock and attempt < retries - 1:
                last_err = e
                _time.sleep(retry_delay * (attempt + 1))
            else:
                raise
    raise last_err


def _connect_mt5() -> bool:
    mt5.shutdown()
    ok = mt5.initialize(login=MT5_ACCOUNT, password=MT5_PASSWORD, server=MT5_SERVER)
    if not ok and MT5_PATH:
        ok = mt5.initialize(path=MT5_PATH, login=MT5_ACCOUNT, password=MT5_PASSWORD, server=MT5_SERVER)
    if not ok:
        print(f"Failed to initialize MT5: {mt5.last_error()}")
        return False
    return True


def _fetch_range(symbol: str, tf_mt5: int, from_dt: datetime, to_dt: datetime) -> Optional[pd.DataFrame]:
    chunks = []
    current_to = to_dt
    current_from = max(from_dt, current_to - timedelta(days=CHUNK_DAYS))
    while current_to > from_dt:
        rates = mt5.copy_rates_range(symbol, tf_mt5, current_from, current_to)
        if rates is not None and len(rates) > 0:
            df = pd.DataFrame(rates)
            df["time"] = pd.to_datetime(df["time"], unit="s")
            chunks.append(df)
        current_to = current_from - timedelta(seconds=1)
        current_from = max(from_dt, current_to - timedelta(days=CHUNK_DAYS))
        _time.sleep(0.3)
    if not chunks:
        return None
    df = pd.concat(chunks, ignore_index=True)
    df.drop_duplicates(subset="time", keep="first", inplace=True)
    df.sort_values("time", inplace=True)
    df.reset_index(drop=True, inplace=True)
    for col in ["open", "high", "low", "close"]:
        if col in df.columns:
            df[col] = df[col].astype(float)
    return df


def _insert_to_duckdb(df: pd.DataFrame, symbol: str, tf_name: str, retries: int = 3) -> dict:
    """Insere sem duplicar. Retry curto para colisoes de lock de escrita do DuckDB."""
    import time as _t
    last_err = None
    for attempt in range(1, retries + 1):
        conn = None
        try:
            conn = get_connection(read_only=False)
            return _insert_conn(conn, df, symbol, tf_name)
        except Exception as e:
            last_err = e
            msg = str(e)
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass
            if "in use" in msg.lower() or "lock" in msg.lower() or "j\u00e1 est\u00e1 sendo usado" in msg:
                if attempt < retries:
                    _t.sleep(2 * attempt)
                    continue
            raise
        finally:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass


def _insert_conn(conn, df: pd.DataFrame, symbol: str, tf_name: str) -> dict:
    df["symbol"] = symbol
    df["timeframe"] = tf_name
    ts_raw = df["time"].astype("int64")
    # Normaliza p/ segundos por magnitude (limites = pontos medios geometricos).
    # pandas 2 -> ns (~1.8e18); pandas 3 to_pydatetime -> us (~1.8e15);
    # APIs web -> ms (~1.8e12); MT5 copy_rates -> s (~1.8e9).
    # O heuristico antigo (>1e15 -> //1e9) corrompia series em us (epoca/1000).
    peak = ts_raw.max()
    if peak > 3.16e16:
        df["time_int"] = ts_raw // 10**9
    elif peak > 3.16e13:
        df["time_int"] = ts_raw // 10**6
    elif peak > 3.16e10:
        df["time_int"] = ts_raw // 10**3
    else:
        df["time_int"] = ts_raw

    cols_insert = ["symbol", "timeframe", "time_int", "open", "high", "low", "close", "tick_volume"]
    extra = []
    if "spread" in df.columns:
        cols_insert.append("spread")
        extra.append("spread")
    if "real_volume" in df.columns:
        cols_insert.append("real_volume")
        extra.append("real_volume")

    df_insert = df[cols_insert].copy()
    time_col = "time_int"

    conn.register("_tmp_insert", df_insert)
    result = conn.execute(f"""
        INSERT INTO ohlc_prices (symbol, timeframe, time, open, high, low, close, tick_volume
                                 {"," + ", ".join(extra) if extra else ""})
        SELECT '{symbol}', '{tf_name}', {time_col}, open, high, low, close, tick_volume
               {", " + ", ".join(extra) if extra else ""}
        FROM _tmp_insert t
        WHERE NOT EXISTS (
            SELECT 1 FROM ohlc_prices o
            WHERE o.symbol = '{symbol}'
              AND o.timeframe = '{tf_name}'
              AND o.time = t.{time_col}
        )
        RETURNING time
    """)
    inserted = len(result.fetchall())
    conn.unregister("_tmp_insert")
    conn.commit()

    total = len(df_insert)
    skipped = total - inserted
    return dict(
        symbol=symbol,
        timeframe=tf_name,
        total=total,
        inserted=inserted,
        skipped=skipped,
        from_date=df["time"].min().isoformat() if not df.empty else None,
        to_date=df["time"].max().isoformat() if not df.empty else None,
    )


def get_last_timestamp(symbol: str, tf_name: str) -> Optional[int]:
    with get_connection() as conn:
        r = conn.execute("""
            SELECT MAX(time) FROM ohlc_prices
            WHERE symbol = ? AND timeframe = ?
        """, [symbol, tf_name]).fetchone()
        return r[0] if r and r[0] else None


def incremental_update(symbol: str, tf_name: str, days_back: int = 30) -> dict:
    last_ts = get_last_timestamp(symbol, tf_name)
    now = datetime.now(timezone.utc)

    if last_ts:
        from_dt = datetime.fromtimestamp(last_ts, tz=timezone.utc) - timedelta(days=1)
    else:
        from_dt = now - timedelta(days=days_back)

    df = None
    src = None
    if _connect_mt5():
        tf_mt5 = TIMEFRAME_MAP.get(tf_name)
        if tf_mt5 is not None:
            print(f"Downloading {symbol} {tf_name} from {from_dt.date()} to {now.date()}")
            df = _fetch_range(canonical_mt5_symbol(symbol), tf_mt5, from_dt, now)
            src = "MT5"
        mt5.shutdown()

    if df is None or df.empty:
        print(f"[fallback] MT5 indisponivel/vazio para {symbol} {tf_name}; tentando yfinance...")
        df = _fetch_range_yfinance(symbol, tf_name, from_dt, now)
        if df is not None and not df.empty:
            src = "yfinance"

    if df is None or df.empty:
        return dict(ok=True, symbol=symbol, timeframe=tf_name, inserted=0,
                     skipped=0, message="No new data (MT5+yfinance)")

    result = _insert_to_duckdb(df, symbol, tf_name)
    result["ok"] = True
    result["source"] = src
    return result


def smart_update(symbol: str, tf_name: str, full_years: int = 10, inc_days: int = 30) -> dict:
    last_ts = get_last_timestamp(symbol, tf_name)
    if last_ts is None:
        return full_update(symbol, tf_name, years=full_years)
    return incremental_update(symbol, tf_name, days_back=inc_days)


def full_update(symbol: str, tf_name: str, years: int = 10) -> dict:
    now = datetime.now(timezone.utc)
    from_dt = now - timedelta(days=years * 365)

    df = None
    src = None
    if _connect_mt5():
        tf_mt5 = TIMEFRAME_MAP.get(tf_name)
        if tf_mt5 is not None:
            print(f"Full download {symbol} {tf_name} {years}y: {from_dt.date()} -> {now.date()}")
            df = _fetch_range(canonical_mt5_symbol(symbol), tf_mt5, from_dt, now)
            src = "MT5"
        mt5.shutdown()

    if df is None or df.empty:
        print(f"[fallback] MT5 indisponivel/vazio para {symbol} {tf_name}; tentando yfinance...")
        df = _fetch_range_yfinance(symbol, tf_name, from_dt, now)
        if df is not None and not df.empty:
            src = "yfinance"

    if df is None or df.empty:
        return dict(ok=False, error="No data returned (MT5+yfinance)")

    result = _insert_to_duckdb(df, symbol, tf_name)
    result["ok"] = True
    result["source"] = src
    return result
