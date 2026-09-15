"""Sistema de alertas Telegram para ALX Account Monitor.

Envia alertas quando:
    - Conta muda de status (ONLINE->WARNING ou WARNING->OFFLINE)
    - Drawdown excede threshold configuravel

Config salva no DuckDB (telegram_config).
Historico em alert_history.
"""
import logging
from datetime import datetime, timezone
from typing import Optional

import httpx

from . import db

logger = logging.getLogger(__name__)

_TELEGRAM_API = "https://api.telegram.org"


def get_config() -> dict:
    """Retorna a config do Telegram (singleton row). Cria row vazia se nao existir."""
    conn = db.get_connection(read_only=True)
    try:
        row = conn.execute(
            "SELECT id, bot_token, chat_id, enabled, alert_offline, alert_drawdown, "
            "dd_threshold_pct, updated_at FROM telegram_config WHERE id=1"
        ).fetchone()
        if row:
            return {
                "id": row[0], "bot_token": row[1] or "", "chat_id": row[2] or "",
                "enabled": bool(row[3]), "alert_offline": bool(row[4]),
                "alert_drawdown": bool(row[5]), "dd_threshold_pct": row[6] or 10.0,
                "updated_at": str(row[7]) if row[7] else None,
            }
    finally:
        conn.close()
    return {
        "id": None, "bot_token": "", "chat_id": "", "enabled": False,
        "alert_offline": True, "alert_drawdown": True, "dd_threshold_pct": 10.0,
        "updated_at": None,
    }


def save_config(bot_token: str, chat_id: str, enabled: bool,
                alert_offline: bool, alert_drawdown: bool,
                dd_threshold_pct: float) -> dict:
    """Upsert da config do Telegram."""
    conn = db.get_connection(read_only=False)
    try:
        existing = conn.execute(
            "SELECT id FROM telegram_config WHERE id=1"
        ).fetchone()
        if existing:
            conn.execute("""
                UPDATE telegram_config
                SET bot_token=?, chat_id=?, enabled=?, alert_offline=?,
                    alert_drawdown=?, dd_threshold_pct=?, updated_at=CURRENT_TIMESTAMP
                WHERE id=1
            """, [bot_token, chat_id, enabled, alert_offline, alert_drawdown, dd_threshold_pct])
        else:
            conn.execute("""
                INSERT INTO telegram_config
                (id, bot_token, chat_id, enabled, alert_offline, alert_drawdown, dd_threshold_pct)
                VALUES (1, ?, ?, ?, ?, ?, ?)
            """, [bot_token, chat_id, enabled, alert_offline, alert_drawdown, dd_threshold_pct])
        conn.commit()
    finally:
        conn.close()
    return get_config()


def send_telegram(message: str, bot_token: str = "", chat_id: str = "") -> bool:
    """Envia mensagem via Telegram API. Retorna True se enviou com sucesso."""
    cfg = get_config()
    token = bot_token or cfg.get("bot_token", "")
    cid = chat_id or cfg.get("chat_id", "")
    if not token or not cid:
        logger.warning("telegram_alert: token ou chat_id nao configurado")
        return False
    url = f"{_TELEGRAM_API}/bot{token}/sendMessage"
    try:
        with httpx.Client(timeout=10) as client:
            resp = client.post(url, json={
                "chat_id": cid,
                "text": message,
                "parse_mode": "HTML",
            })
            if resp.status_code == 200:
                return True
            logger.warning("telegram_alert: Telegram API %d: %s", resp.status_code, resp.text[:200])
            return False
    except Exception as e:
        logger.error("telegram_alert: falha ao enviar: %s", e)
        return False


def save_alert(account_id: str, alert_type: str, message: str) -> None:
    """Salva alerta no historico."""
    conn = db.get_connection(read_only=False)
    try:
        conn.execute("""
            INSERT INTO alert_history (account_id, alert_type, message)
            VALUES (?, ?, ?)
        """, [account_id, alert_type, message])
        conn.commit()
    finally:
        conn.close()


def check_status_change(account_id: str, prev_status: Optional[str],
                        new_status: str, balance: float = 0,
                        equity: float = 0) -> None:
    """Verifica se houve mudanca de status e envia alerta."""
    if not prev_status or prev_status == new_status:
        return
    cfg = get_config()
    if not cfg.get("enabled") or not cfg.get("alert_offline"):
        return
    # Só alerta para transicoes para pior: WARNING ou OFFLINE
    if new_status not in ("WARNING", "OFFLINE"):
        return
    # Se ja estava pior, nao alerta (ex: OFFLINE->OFFLINE tratado acima)
    if prev_status == "OFFLINE" and new_status == "WARNING":
        return  # recovery, nao alerta

    icon = "⚠️" if new_status == "WARNING" else "🔴"
    status_text = f"{prev_status} → {new_status}"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    msg = (
        f"{icon} <b>ACCOUNT {new_status}</b>\n"
        f"━━━━━━━━━━━━━━━━━\n"
        f"🏦 <b>Account:</b> <code>{account_id}</code>\n"
        f"📊 <b>Status:</b> {status_text}\n"
        f"💰 <b>Balance:</b> ${balance:,.2f}\n"
        f"💰 <b>Equity:</b> ${equity:,.2f}\n"
        f"⏰ <b>{now}</b>"
    )

    sent = send_telegram(msg)
    if sent:
        save_alert(account_id, new_status.lower(), msg)


def check_drawdown(account_id: str, equity: Optional[float],
                   balance: Optional[float]) -> None:
    """Verifica se drawdown excede threshold e envia alerta."""
    if equity is None or balance is None or balance <= 0:
        return
    cfg = get_config()
    if not cfg.get("enabled") or not cfg.get("alert_drawdown"):
        return

    dd_pct = ((balance - equity) / balance) * 100
    threshold = cfg.get("dd_threshold_pct", 10.0)

    if dd_pct < threshold:
        return

    # Anti-spam: verificar se ja alertou nos ultimos 5 minutos
    conn = db.get_connection(read_only=True)
    try:
        recent = conn.execute("""
            SELECT 1 FROM alert_history
            WHERE account_id=? AND alert_type='drawdown'
            AND sent_at > (CURRENT_TIMESTAMP - INTERVAL '5 minutes')
            LIMIT 1
        """, [account_id]).fetchone()
    finally:
        conn.close()

    if recent:
        return

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    msg = (
        f"🔴 <b>DRAWDOWN ALERT</b>\n"
        f"━━━━━━━━━━━━━━━━━\n"
        f"🏦 <b>Account:</b> <code>{account_id}</code>\n"
        f"📉 <b>Drawdown:</b> {dd_pct:.1f}% (threshold: {threshold:.1f}%)\n"
        f"💰 <b>Balance:</b> ${balance:,.2f}\n"
        f"💰 <b>Equity:</b> ${equity:,.2f}\n"
        f"⏰ <b>{now}</b>"
    )

    sent = send_telegram(msg)
    if sent:
        save_alert(account_id, "drawdown", msg)


def get_alerts(limit: int = 100) -> list:
    """Retorna historico de alertas (mais recente primeiro)."""
    conn = db.get_connection(read_only=True)
    try:
        rows = conn.execute("""
            SELECT id, account_id, alert_type, message, sent_at
            FROM alert_history
            ORDER BY sent_at DESC
            LIMIT ?
        """, [limit]).fetchall()
        return [
            {"id": r[0], "account_id": r[1], "alert_type": r[2],
             "message": r[3], "sent_at": str(r[4]) if r[4] else None}
            for r in rows
        ]
    finally:
        conn.close()


def get_alerts_summary() -> dict:
    """Contadores por tipo de alerta."""
    conn = db.get_connection(read_only=True)
    try:
        rows = conn.execute("""
            SELECT alert_type, COUNT(*) as cnt
            FROM alert_history
            GROUP BY alert_type
        """).fetchall()
        summary = {"total": 0, "offline": 0, "warning": 0, "drawdown": 0}
        for r in rows:
            t = r[0]
            c = r[1]
            summary["total"] += c
            if t in summary:
                summary[t] = c
        return summary
    finally:
        conn.close()
