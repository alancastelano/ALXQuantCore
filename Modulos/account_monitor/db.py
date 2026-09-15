"""DuckDB (banco separado) do Account Monitor.

Banco proprio: data/account_monitor.duckdb — NAO usa o ALXQuantCore.duckdb.

Estado atual (upsert por heartbeat):
    accounts_current, positions_current, orders_current

Historico (append):
    account_snapshots, position_events, deal_events,
    performance_daily, performance_weekly, performance_monthly
"""
import os
import time
from typing import Optional

import duckdb

from .config import DB_PATH


def get_connection(read_only: bool = False, retries: int = 5, retry_delay: float = 0.5) -> duckdb.DuckDBPyConnection:
    """Abre conexao ao DuckDB proprio do Account Monitor, com retry p/ locks."""
    if not os.path.exists(DB_PATH):
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        conn = duckdb.connect(str(DB_PATH))
        init_schema(conn)
        conn.close()
    last_err: Optional[Exception] = None
    for attempt in range(retries):
        try:
            conn = duckdb.connect(str(DB_PATH), read_only=read_only)
            if not read_only:
                _migrate(conn)
            return conn
        except Exception as e:
            msg = str(e).lower()
            is_lock = any(k in msg for k in ("already in use", "sendo usado", "io error",
                                             "different configuration", "configuracao", "configuração"))
            if is_lock and attempt < retries - 1:
                last_err = e
                time.sleep(retry_delay * (attempt + 1))
            else:
                raise
    raise last_err  # type: ignore


_SCHEMA = [
    # --- Estado atual ---
    """
    CREATE TABLE IF NOT EXISTS accounts_current (
        account_id        VARCHAR PRIMARY KEY,
        login             BIGINT,
        broker            VARCHAR,
        server            VARCHAR,
        currency          VARCHAR,
        balance           DOUBLE,
        equity            DOUBLE,
        margin            DOUBLE,
        free_margin       DOUBLE,
        margin_level      DOUBLE,
        profit            DOUBLE,
        credit            DOUBLE,
        leverage          BIGINT,
        last_seen_ts      DOUBLE,
        status            VARCHAR,
        pnl_day           DOUBLE DEFAULT 0.0,
        pnl_week          DOUBLE DEFAULT 0.0,
        pnl_month         DOUBLE DEFAULT 0.0,
        terminal_build    BIGINT DEFAULT 0,
        terminal_ping_ms  BIGINT DEFAULT 0,
        terminal_connected BOOLEAN DEFAULT FALSE,
        terminal_name     VARCHAR DEFAULT '',
        vps_info          VARCHAR DEFAULT ''
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS positions_current (
        ticket        BIGINT PRIMARY KEY,
        account_id    VARCHAR,
        symbol        VARCHAR,
        type          VARCHAR,
        volume        DOUBLE,
        open_price    DOUBLE,
        current_price DOUBLE,
        sl            DOUBLE,
        tp            DOUBLE,
        profit        DOUBLE,
        swap          DOUBLE,
        commission    DOUBLE,
        magic         BIGINT,
        open_time     DOUBLE,
        comment       VARCHAR,
        updated_ts    DOUBLE
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS orders_current (
        ticket     BIGINT PRIMARY KEY,
        account_id VARCHAR,
        symbol     VARCHAR,
        type       VARCHAR,
        volume     DOUBLE,
        price      DOUBLE,
        sl         DOUBLE,
        tp         DOUBLE,
        state      VARCHAR,
        time       DOUBLE
    )
    """,
    # --- Historico ---
    """
    CREATE TABLE IF NOT EXISTS account_snapshots (
        account_id  VARCHAR,
        ts          DOUBLE,
        balance     DOUBLE,
        equity      DOUBLE,
        margin      DOUBLE,
        profit      DOUBLE,
        PRIMARY KEY (account_id, ts)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS position_events (
        id          BIGINT,
        account_id  VARCHAR,
        event       VARCHAR,
        ticket      BIGINT,
        symbol      VARCHAR,
        type        VARCHAR,
        volume      DOUBLE,
        profit      DOUBLE,
        ts          DOUBLE
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS deal_events (
        deal       BIGINT,
        account_id VARCHAR,
        ticket     BIGINT,
        symbol     VARCHAR,
        type       VARCHAR,
        volume     DOUBLE,
        profit     DOUBLE,
        swap       DOUBLE,
        commission DOUBLE,
        close_time DOUBLE
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS performance_daily (
        account_id VARCHAR,
        day        DATE,
        pnl        DOUBLE,
        PRIMARY KEY (account_id, day)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS performance_weekly (
        account_id VARCHAR,
        week       DATE,
        pnl        DOUBLE,
        PRIMARY KEY (account_id, week)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS performance_monthly (
        account_id VARCHAR,
        month      DATE,
        pnl        DOUBLE,
        PRIMARY KEY (account_id, month)
    )
    """,
    # --- Usuarios (auth GUI) ---
    "CREATE SEQUENCE IF NOT EXISTS users_id_seq START 1",
    """
    CREATE TABLE IF NOT EXISTS users (
        id            INTEGER,
        username      VARCHAR UNIQUE NOT NULL,
        password_hash VARCHAR NOT NULL,
        role          VARCHAR DEFAULT 'user',
        created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        last_login    TIMESTAMP,
        active        BOOLEAN DEFAULT TRUE,
        PRIMARY KEY (id)
    )
    """,
    # --- Telegram Alerts ---
    "CREATE SEQUENCE IF NOT EXISTS telegram_config_id_seq START 1",
    """
    CREATE TABLE IF NOT EXISTS telegram_config (
        id               INTEGER PRIMARY KEY DEFAULT nextval('telegram_config_id_seq'),
        bot_token        VARCHAR,
        chat_id          VARCHAR,
        enabled          BOOLEAN DEFAULT FALSE,
        alert_offline    BOOLEAN DEFAULT TRUE,
        alert_drawdown   BOOLEAN DEFAULT TRUE,
        dd_threshold_pct DOUBLE DEFAULT 10.0,
        updated_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
    """,
    "CREATE SEQUENCE IF NOT EXISTS alert_history_id_seq START 1",
    """
    CREATE TABLE IF NOT EXISTS alert_history (
        id         INTEGER PRIMARY KEY DEFAULT nextval('alert_history_id_seq'),
        account_id VARCHAR,
        alert_type VARCHAR,
        message    TEXT,
        sent_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
    """,
    # --- Broker Quality ---
    """
    CREATE TABLE IF NOT EXISTS broker_quality (
        account_id     VARCHAR,
        magic          BIGINT,
        symbol         VARCHAR,
        avg_spread     DOUBLE,
        max_spread     DOUBLE,
        avg_slippage   DOUBLE,
        max_slippage   DOUBLE,
        avg_latency_ms DOUBLE,
        max_latency_ms DOUBLE,
        success_rate   DOUBLE,
        total_requests BIGINT,
        success_count  BIGINT,
        reject_count   BIGINT,
        requote_count  BIGINT,
        timeout_count  BIGINT,
        broker_score   DOUBLE,
        is_toxic       BOOLEAN,
        ts             DOUBLE,
        PRIMARY KEY (account_id, magic, symbol, ts)
    )
    """,
]

_INDEXES = [
    "CREATE INDEX IF NOT EXISTS idx_snap_account ON account_snapshots(account_id, ts)",
    "CREATE INDEX IF NOT EXISTS idx_deal_account ON deal_events(account_id, close_time)",
    "CREATE INDEX IF NOT EXISTS idx_pos_account ON positions_current(account_id)",
    "CREATE INDEX IF NOT EXISTS idx_posev_account ON position_events(account_id, ts)",
    "CREATE INDEX IF NOT EXISTS idx_alert_account ON alert_history(account_id, sent_at)",
    "CREATE INDEX IF NOT EXISTS idx_bq_account ON broker_quality(account_id, symbol, ts)",
]


def init_schema(conn: duckdb.DuckDBPyConnection) -> None:
    """Cria/garante todas as tabelas e indices (idempotente)."""
    for stmt in _SCHEMA:
        _safe_exec(conn, stmt)
    for stmt in _INDEXES:
        _safe_exec(conn, stmt)
    _migrate(conn)


_MIGRATIONS = [
    ("accounts_current", "pnl_day",    "DOUBLE DEFAULT 0.0"),
    ("accounts_current", "pnl_week",   "DOUBLE DEFAULT 0.0"),
    ("accounts_current", "pnl_month",  "DOUBLE DEFAULT 0.0"),
    ("accounts_current", "terminal_build",    "BIGINT DEFAULT 0"),
    ("accounts_current", "terminal_ping_ms",  "BIGINT DEFAULT 0"),
    ("accounts_current", "terminal_connected", "BOOLEAN DEFAULT FALSE"),
    ("accounts_current", "terminal_name",     "VARCHAR DEFAULT ''"),
    ("accounts_current", "vps_info",          "VARCHAR DEFAULT ''"),
]


def _safe_exec(conn: duckdb.DuckDBPyConnection, sql: str) -> bool:
    """Executa SQL isoladamente; faz rollback se falhar, retorna True/False."""
    try:
        conn.execute(sql)
        return True
    except Exception:
        try:
            conn.rollback()
        except Exception:
            pass
        return False


def _migrate(conn: duckdb.DuckDBPyConnection) -> None:
    """Adiciona colunas que possam faltar em DBs existentes (idempotente)."""
    try:
        existing = {r[1] for r in conn.execute("DESCRIBE accounts_current").fetchall()}
    except Exception:
        _safe_exec(conn, "ROLLBACK")
        existing = set()
    for table, col, typedef in _MIGRATIONS:
        if col not in existing:
            _safe_exec(conn, f"ALTER TABLE {table} ADD COLUMN {col} {typedef}")
    # Tabela users
    _safe_exec(conn, "CREATE SEQUENCE IF NOT EXISTS users_id_seq START 1")
    _safe_exec(conn, """
        CREATE TABLE IF NOT EXISTS users (
            id            INTEGER,
            username      VARCHAR UNIQUE NOT NULL,
            password_hash VARCHAR NOT NULL,
            role          VARCHAR DEFAULT 'user',
            created_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            last_login    TIMESTAMP,
            active        BOOLEAN DEFAULT TRUE,
            PRIMARY KEY (id)
        )
    """)
    # Tabelas Telegram
    _safe_exec(conn, "CREATE SEQUENCE IF NOT EXISTS telegram_config_id_seq START 1")
    _safe_exec(conn, """
        CREATE TABLE IF NOT EXISTS telegram_config (
            id               INTEGER PRIMARY KEY DEFAULT nextval('telegram_config_id_seq'),
            bot_token        VARCHAR,
            chat_id          VARCHAR,
            enabled          BOOLEAN DEFAULT FALSE,
            alert_offline    BOOLEAN DEFAULT TRUE,
            alert_drawdown   BOOLEAN DEFAULT TRUE,
            dd_threshold_pct DOUBLE DEFAULT 10.0,
            updated_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    _safe_exec(conn, "CREATE SEQUENCE IF NOT EXISTS alert_history_id_seq START 1")
    _safe_exec(conn, """
        CREATE TABLE IF NOT EXISTS alert_history (
            id         INTEGER PRIMARY KEY DEFAULT nextval('alert_history_id_seq'),
            account_id VARCHAR,
            alert_type VARCHAR,
            message    TEXT,
            sent_at    TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    _safe_exec(conn, "CREATE INDEX IF NOT EXISTS idx_alert_account ON alert_history(account_id, sent_at)")
    # Tabela broker_quality
    _safe_exec(conn, """
        CREATE TABLE IF NOT EXISTS broker_quality (
            account_id     VARCHAR,
            magic          BIGINT,
            symbol         VARCHAR,
            avg_spread     DOUBLE,
            max_spread     DOUBLE,
            avg_slippage   DOUBLE,
            max_slippage   DOUBLE,
            avg_latency_ms DOUBLE,
            max_latency_ms DOUBLE,
            success_rate   DOUBLE,
            total_requests BIGINT,
            success_count  BIGINT,
            reject_count   BIGINT,
            requote_count  BIGINT,
            timeout_count  BIGINT,
            broker_score   DOUBLE,
            is_toxic       BOOLEAN,
            ts             DOUBLE,
            PRIMARY KEY (account_id, magic, symbol, ts)
        )
    """)
    _safe_exec(conn, "CREATE INDEX IF NOT EXISTS idx_bq_account ON broker_quality(account_id, symbol, ts)")