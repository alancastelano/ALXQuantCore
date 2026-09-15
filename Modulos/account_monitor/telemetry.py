"""Receptor/normalizador de telemetria e persistencia no DuckDB.

Recebe o payload do EA, normaliza e escreve em:
    accounts_current, positions_current, orders_current (upsert)
    account_snapshots, position_events, deal_events (append)

Tambem dispara broadcasts via ws.broadcast quando ha mudanca relevante.
"""
import time
from datetime import datetime, timezone
from typing import Any, Optional

from . import db, ws
from .performance import performance_for
from . import telegram_alert

_STATUS_THRESHOLDS = None


def _now_ts() -> float:
    return time.time()


def _compute_status(last_seen_ts: float) -> str:
    from .config import config
    age = _now_ts() - last_seen_ts
    if age < config.online_warning_sec:
        return "ONLINE"
    if age < config.offline_sec:
        return "WARNING"
    return "OFFLINE"


def _upsert_account(conn, account: dict, last_seen_ts: float) -> bool:
    aid = account["account_id"]
    prev = conn.execute(
        "SELECT balance, equity, margin, margin_level, profit, status FROM accounts_current WHERE account_id=?",
        [aid],
    ).fetchone()
    prev_status = prev[5] if prev else None
    status = _compute_status(last_seen_ts)

    conn.execute("""
        INSERT INTO accounts_current
        (account_id, login, broker, server, currency, balance, equity, margin,
         free_margin, margin_level, profit, credit, leverage, last_seen_ts, status,
         pnl_day, pnl_week, pnl_month, terminal_build, terminal_ping_ms, terminal_connected,
         terminal_name, vps_info)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT (account_id) DO UPDATE SET
            login=excluded.login, broker=excluded.broker, server=excluded.server,
            currency=excluded.currency, balance=excluded.balance, equity=excluded.equity,
            margin=excluded.margin, free_margin=excluded.free_margin,
            margin_level=excluded.margin_level, profit=excluded.profit,
            credit=excluded.credit, leverage=excluded.leverage,
            last_seen_ts=excluded.last_seen_ts, status=excluded.status,
            pnl_day=excluded.pnl_day, pnl_week=excluded.pnl_week, pnl_month=excluded.pnl_month,
            terminal_build=excluded.terminal_build, terminal_ping_ms=excluded.terminal_ping_ms,
            terminal_connected=excluded.terminal_connected, terminal_name=excluded.terminal_name,
            vps_info=excluded.vps_info
    """, [
        aid,
        account.get("login"),
        account.get("broker"),
        account.get("server"),
        account.get("currency"),
        account.get("balance"),
        account.get("equity"),
        account.get("margin"),
        account.get("free_margin"),
        account.get("margin_level"),
        account.get("profit"),
        account.get("credit"),
        account.get("leverage"),
        last_seen_ts,
        status,
        account.get("pnl_day", 0.0),
        account.get("pnl_week", 0.0),
        account.get("pnl_month", 0.0),
        account.get("terminal_build", 0),
        account.get("terminal_ping_ms", 0),
        account.get("terminal_connected", False),
        account.get("terminal_name", ""),
        account.get("vps_info", ""),
    ])

    # snapshot historico (curva de equity)
    conn.execute("""
        INSERT OR REPLACE INTO account_snapshots (account_id, ts, balance, equity, margin, profit)
        VALUES (?,?,?,?,?,?)
    """, [aid, last_seen_ts, account.get("balance"), account.get("equity"),
          account.get("margin"), account.get("profit")])

    # detecta mudanca relevante p/ broadcast
    changed = False
    if not prev:
        changed = True
    else:
        if abs(prev[0] - (account.get("balance") or 0)) > 1e-9:
            changed = True  # balance mudou
        if abs(prev[1] - (account.get("equity") or 0)) > 1e-9:
            changed = True
        if prev[3] != account.get("margin_level"):
            changed = True

    # hook telegram: alerta se status mudou para pior
    telegram_alert.check_status_change(
        aid, prev_status, status,
        balance=account.get("balance") or 0,
        equity=account.get("equity") or 0,
    )

    return changed
    return changed


def _upsert_positions(conn, account_id: str, positions: list) -> None:
    # remove posicoes antigas desta conta e reinsere (estado atual)
    conn.execute("DELETE FROM positions_current WHERE account_id=?", [account_id])
    ts = _now_ts()
    for p in positions:
        conn.execute("""
            INSERT INTO positions_current
            (ticket, account_id, symbol, type, volume, open_price, current_price,
             sl, tp, profit, swap, commission, magic, open_time, comment, updated_ts)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [
            p.get("ticket"), account_id, p.get("symbol"), p.get("type"),
            p.get("volume"), p.get("open_price"), p.get("current_price"),
            p.get("sl"), p.get("tp"), p.get("profit"), p.get("swap"),
            p.get("commission"), p.get("magic"), p.get("open_time"),
            p.get("comment"), ts,
        ])


def _append_deals(conn, account_id: str, deals: list) -> None:
    for d in deals:
        deal = d.get("deal")
        exists = conn.execute(
            "SELECT 1 FROM deal_events WHERE account_id=? AND deal=? LIMIT 1",
            [account_id, deal],
        ).fetchone()
        if exists:
            continue
        conn.execute("""
            INSERT INTO deal_events
            (deal, account_id, ticket, symbol, type, volume, profit, swap, commission, close_time)
            VALUES (?,?,?,?,?,?,?,?,?,?)
        """, [
            deal, account_id, d.get("ticket"), d.get("symbol"),
            d.get("type"), d.get("volume"), d.get("profit"), d.get("swap"),
            d.get("commission"), d.get("close_time"),
        ])


def _ingest_quality(conn, account_id: str, quality: dict, ts: float) -> None:
    """Salva dados de qualidade de execucao no broker_quality."""
    for key, data in quality.items():
        if not isinstance(data, dict):
            continue
        # key = "{magic}_{symbol}"
        parts = key.split("_", 1)
        try:
            magic = int(parts[0]) if parts else 0
        except ValueError:
            magic = 0
        symbol = parts[1] if len(parts) > 1 else ""
        conn.execute("""
            INSERT OR REPLACE INTO broker_quality
            (account_id, magic, symbol, avg_spread, max_spread, avg_slippage,
             max_slippage, avg_latency_ms, max_latency_ms, success_rate,
             total_requests, success_count, reject_count, requote_count,
             timeout_count, broker_score, is_toxic, ts)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [
            account_id, magic, symbol,
            data.get("avg_spread", 0), data.get("max_spread", 0),
            data.get("avg_slippage", 0), data.get("max_slippage", 0),
            data.get("avg_latency_ms", 0), data.get("max_latency_ms", 0),
            data.get("success_rate", 0), data.get("total_requests", 0),
            data.get("success_count", 0), data.get("reject_count", 0),
            data.get("requote_count", 0), data.get("timeout_count", 0),
            data.get("broker_score", 0), data.get("is_toxic", False), ts,
        ])


def ingest_telemetry(payload: dict) -> dict:
    """Processa um payload completo de telemetry (heartbeat/telemetry).

    payload:
      {account_id, login, broker, server, currency, balance, equity, margin,
       free_margin, margin_level, profit, credit, leverage,
       positions: [...], deals: [...], orders: [...]}
    """
    account_id = payload["account_id"]
    positions = payload.get("positions") or []
    deals = payload.get("deals") or []
    orders = payload.get("orders") or []
    last_seen_ts = _now_ts()

    conn = db.get_connection(read_only=False)
    try:
        changed = _upsert_account(conn, payload, last_seen_ts)
        _upsert_positions(conn, account_id, positions)
        if deals:
            _append_deals(conn, account_id, deals)
        # Quality data from trading EAs
        quality = payload.get("quality") or {}
        if quality:
            _ingest_quality(conn, account_id, quality, last_seen_ts)
        conn.commit()
    finally:
        conn.close()

    # hook telegram: alerta drawdown
    telegram_alert.check_drawdown(
        account_id,
        equity=payload.get("equity"),
        balance=payload.get("balance"),
    )

    # broadcast sempre (estado de conta/posicoes consolidadas mudou)
    # eventos de posicao sao tratados em ingest_event()
    return {"account_id": account_id, "positions": len(positions),
            "deals": len(deals), "changed": changed}


def ingest_event(payload: dict) -> dict:
    """Processa um evento (POSITION_OPEN/CLOSE/MODIFY, BALANCE_CHANGE, etc.)."""
    account_id = payload["account_id"]
    event = payload.get("event")
    pos = payload.get("position") or {}

    conn = db.get_connection(read_only=False)
    try:
        conn.execute("""
            INSERT INTO position_events (id, account_id, event, ticket, symbol, type, volume, profit, ts)
            VALUES (?,?,?,?,?,?,?,?,?)
        """, [
            payload.get("event_id"),
            account_id,
            event,
            pos.get("ticket"),
            pos.get("symbol"),
            pos.get("type"),
            pos.get("volume"),
            pos.get("profit"),
            _now_ts(),
        ])
        conn.commit()
    finally:
        conn.close()

    return {"account_id": account_id, "event": event}


def _row_to_dict(row, columns):
    """Converte uma tupla DuckDB em dict usando os nomes das colunas."""
    return {col: row[i] for i, col in enumerate(columns)}


def get_accounts_summary() -> dict:
    """Visao consolidada p/ a tabela e cards."""
    conn = db.get_connection(read_only=True)
    try:
        accounts = conn.execute("""
            SELECT account_id, login, broker, server, currency, balance, equity,
                   margin, free_margin, margin_level, profit, credit, leverage,
                   last_seen_ts, status, pnl_day, pnl_week, pnl_month
            FROM accounts_current ORDER BY account_id
        """).fetchall()
        result = []
        for r in accounts:
            d = {
                "account_id": r[0], "login": r[1], "broker": r[2], "server": r[3],
                "currency": r[4], "balance": r[5], "equity": r[6], "margin": r[7],
                "free_margin": r[8], "margin_level": r[9], "profit": r[10],
                "credit": r[11], "leverage": r[12], "last_seen_ts": r[13],
                "status": _compute_status(r[13]),
                "pnl_day": r[15] or 0.0,
                "pnl_week": r[16] or 0.0,
                "pnl_month": r[17] or 0.0,
            }
            d["positions"] = conn.execute(
                "SELECT COUNT(*) FROM positions_current WHERE account_id=?", [r[0]]
            ).fetchone()[0]
            perf = performance_for(conn, r[0])
            d["pnl_today"] = d["pnl_day"] if d["pnl_day"] else perf["daily"]
            d["drawdown_today"] = perf["drawdown_today"]
            d["drawdown_pct"] = perf["drawdown_pct"]
            result.append(d)
        return {"accounts": result}
    finally:
        conn.close()


def get_account_detail(account_id: str) -> Optional[dict]:
    conn = db.get_connection(read_only=True)
    try:
        acct = conn.execute(
            "SELECT * FROM accounts_current WHERE account_id=?", [account_id]
        ).fetchone()
        if not acct:
            return None

        acct_cols = [desc[0] for desc in conn.execute(
            "SELECT * FROM accounts_current WHERE account_id=? LIMIT 0", [account_id]
        ).description]

        pos_cols = [desc[0] for desc in conn.execute(
            "SELECT * FROM positions_current WHERE account_id=? LIMIT 0", [account_id]
        ).description]

        positions = conn.execute(
            "SELECT * FROM positions_current WHERE account_id=?", [account_id]
        ).fetchall()
        snapshots = conn.execute(
            "SELECT ts, equity, balance, margin, profit FROM account_snapshots "
            "WHERE account_id=? ORDER BY ts", [account_id]
        ).fetchall()
        perf = performance_for(conn, account_id)

        # Usar valores do EA (gravados em accounts_current) para day/week/month
        acct_dict = _row_to_dict(acct, acct_cols)
        pnl_day_val = acct_dict.get("pnl_day") or 0.0
        perf["daily"] = pnl_day_val if pnl_day_val else perf["daily"]
        perf["weekly"] = acct_dict.get("pnl_week") or 0.0
        perf["monthly"] = acct_dict.get("pnl_month") or 0.0

        return {
            "account": acct_dict,
            "positions": [_row_to_dict(p, pos_cols) for p in positions],
            "snapshots": snapshots,
            "performance": perf,
        }
    finally:
        conn.close()