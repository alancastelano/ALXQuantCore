"""Servidor FastAPI autonomo do ALX Account Monitor.

Porta propria (default 8400), desacoplado do serve.py do ALXQuantCore.
Serve a GUI de static/ e expoe:

    POST /api/v1/accounts/telemetry      (EA auth)
    POST /api/v1/accounts/heartbeat      (EA auth)
    POST /api/v1/accounts/events         (EA auth)
    GET  /api/v1/accounts                (GUI session)
    GET  /api/v1/accounts/{id}           (GUI session)
    GET  /api/v1/accounts/{id}/positions (GUI session)
    GET  /api/v1/accounts/{id}/performance (GUI session)
    GET  /api/v1/accounts/{id}/quality     (GUI session)
    GET  /api/v1/accounts/{id}/symbols     (GUI session)
    GET  /api/v1/accounts/{id}/winners-losers (GUI session)
    GET  /api/v1/accounts/{id}/calendar    (GUI session)
    GET  /api/v1/analytics/symbols         (GUI session)
    GET  /api/v1/analytics/calendar        (GUI session)
    GET  /api/v1/dashboard/summary         (GUI session)
    WS   /ws

Auth EA: header X-API-Key + body {account_id, timestamp, nonce}
Auth GUI: Authorization: Bearer <session_token>
"""
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Header, WebSocket, WebSocketDisconnect, HTTPException, Depends, Request
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel, Field

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from . import auth, db, keys_store, telemetry, ws
from .config import config, STATIC_DIR, __version__
from .performance import (dashboard_summary, equity_curve, trade_statistics,
                          symbol_summary, winners_losers, daily_calendar,
                          global_symbol_summary, global_daily_calendar,
                          advanced_summary, monthly_performance_grid,
                          duration_analysis, overall_metrics)
from . import gui_auth
from . import telegram_alert


app = FastAPI(title="ALX Account Monitor", version=__version__)


# --- Helper: resposta HTTP que o WinINet/MQL5 WebRequest entende ---------------
# WinINet (usado internamente pelo MQL5) falha com Transfer-Encoding: chunked
# e com keep-alive. Forcar Connection: close + Content-Length resolve o bug 1003.
def _ea_response(data: dict, status_code: int = 200) -> Response:
    body = json.dumps(data, separators=(",", ":"))
    return Response(
        content=body,
        status_code=status_code,
        media_type="application/json",
        headers={
            "Connection": "close",
            "Content-Length": str(len(body.encode("utf-8"))),
            "Cache-Control": "no-store",
        },
    )


# --- Startup: garantir usuario admin -----------------------------------

@app.on_event("startup")
async def _startup():
    gui_auth.ensure_admin_user()


# --- Pydantic models --------------------------------------------------

class TelemetryBody(BaseModel):
    account_id: str
    timestamp: float = Field(default_factory=time.time)
    nonce: Optional[str] = None
    login: Optional[int] = None
    broker: Optional[str] = None
    server: Optional[str] = None
    currency: Optional[str] = None
    balance: Optional[float] = None
    equity: Optional[float] = None
    margin: Optional[float] = None
    free_margin: Optional[float] = None
    margin_level: Optional[float] = None
    profit: Optional[float] = None
    credit: Optional[float] = None
    leverage: Optional[int] = None
    pnl_day: Optional[float] = None
    pnl_week: Optional[float] = None
    pnl_month: Optional[float] = None
    terminal_build: Optional[int] = None
    terminal_ping_ms: Optional[int] = None
    terminal_connected: Optional[bool] = None
    terminal_name: Optional[str] = None
    vps_info: Optional[str] = None
    quality: Optional[dict] = None
    positions: list = Field(default_factory=list)
    orders: list = Field(default_factory=list)
    deals: list = Field(default_factory=list)


class EventBody(BaseModel):
    account_id: str
    event: str
    event_id: Optional[int] = None
    timestamp: float = Field(default_factory=time.time)
    nonce: Optional[str] = None
    position: dict = Field(default_factory=dict)


class LoginBody(BaseModel):
    username: str
    password: str


class CreateUserBody(BaseModel):
    username: str
    password: str
    role: str = "user"


class UpdateRoleBody(BaseModel):
    role: str


class ResetPasswordBody(BaseModel):
    password: str


class TelegramConfigBody(BaseModel):
    bot_token: str = ""
    chat_id: str = ""
    enabled: bool = False
    alert_offline: bool = True
    alert_drawdown: bool = True
    dd_threshold_pct: float = 10.0


class TelegramTestBody(BaseModel):
    message: str = "Test from ALX Account Monitor"


# --- EA Auth helper ---------------------------------------------------

def _authorize_ea(api_key: Optional[str], account_id: str, timestamp: Optional[float], nonce: Optional[str]) -> auth.AuthResult:
    res = auth.authenticate(api_key, account_id, timestamp, nonce)
    if not res.ok:
        raise HTTPException(status_code=res.status_code, detail=res.message)
    return res


# --- GUI Auth helper --------------------------------------------------

def _require_session(request: Request) -> gui_auth.Session:
    """Exige sessao valida (GUI auth). Extrai token do header Authorization."""
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing or invalid authorization header")
    token = auth_header[7:]  # remove "Bearer "
    sess = gui_auth.validate_session(token)
    if not sess:
        raise HTTPException(status_code=401, detail="invalid or expired session")
    return sess


def _require_admin(request: Request) -> gui_auth.Session:
    """Exige sessao de admin."""
    sess = _require_session(request)
    if sess.role != "admin":
        raise HTTPException(status_code=403, detail="admin role required")
    return sess


# --- EA Endpoints (X-API-Key auth) ------------------------------------

@app.post("/api/v1/accounts/heartbeat")
async def heartbeat(body: TelemetryBody, x_api_key: Optional[str] = Header(default=None)):
    try:
        res = _authorize_ea(x_api_key, body.account_id, body.timestamp, body.nonce)
        payload = body.model_dump()
        try:
            out = telemetry.ingest_telemetry(payload)
        except Exception as e:
            import traceback
            traceback.print_exc()
            out = {"account_id": body.account_id, "positions": 0, "deals": 0, "changed": False, "error": str(e)}
        try:
            await ws.broadcast("account_update", {"account_id": body.account_id})
        except Exception:
            pass
        if res.issued_key:
            out["issued_api_key"] = res.issued_key
        return _ea_response({"ok": True, **out})
    except HTTPException:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/accounts/telemetry")
async def telemetry_endpoint(body: TelemetryBody, x_api_key: Optional[str] = Header(default=None)):
    try:
        res = _authorize_ea(x_api_key, body.account_id, body.timestamp, body.nonce)
        payload = body.model_dump()
        try:
            out = telemetry.ingest_telemetry(payload)
        except Exception as e:
            import traceback
            traceback.print_exc()
            out = {"account_id": body.account_id, "positions": 0, "deals": 0, "changed": False, "error": str(e)}
        try:
            await ws.broadcast("account_update", {"account_id": body.account_id, "positions": out.get("positions", 0)})
        except Exception:
            pass
        if res.issued_key:
            out["issued_api_key"] = res.issued_key
        return _ea_response({"ok": True, **out})
    except HTTPException:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/accounts/events")
async def events(body: EventBody, x_api_key: Optional[str] = Header(default=None)):
    res = _authorize_ea(x_api_key, body.account_id, body.timestamp, body.nonce)
    out = telemetry.ingest_event(body.model_dump())
    await ws.broadcast("position_update", {"account_id": body.account_id, "event": body.event,
                                           "position": body.position})
    if res.issued_key:
        out["issued_api_key"] = res.issued_key
    return _ea_response({"ok": True, **out})


# --- GUI Endpoints (session auth) -------------------------------------

@app.get("/api/v1/accounts")
async def accounts(sess: gui_auth.Session = Depends(_require_session)):
    return telemetry.get_accounts_summary()


@app.get("/api/v1/accounts/{account_id}")
async def account_detail(account_id: str, sess: gui_auth.Session = Depends(_require_session)):
    d = telemetry.get_account_detail(account_id)
    if not d:
        raise HTTPException(status_code=404, detail="account not found")
    # Adicionar equity curve e statistics
    conn = db.get_connection(read_only=True)
    try:
        d["equity_curve"] = equity_curve(conn, account_id)
        d["statistics"] = trade_statistics(conn, account_id)
    finally:
        conn.close()
    return d


@app.get("/api/v1/accounts/{account_id}/positions")
async def account_positions(account_id: str, sess: gui_auth.Session = Depends(_require_session)):
    d = telemetry.get_account_detail(account_id)
    if not d:
        raise HTTPException(status_code=404, detail="account not found")
    return {"account_id": account_id, "positions": d["positions"]}


@app.get("/api/v1/accounts/{account_id}/performance")
async def account_performance(account_id: str, sess: gui_auth.Session = Depends(_require_session)):
    d = telemetry.get_account_detail(account_id)
    if not d:
        raise HTTPException(status_code=404, detail="account not found")
    return {"account_id": account_id, "performance": d["performance"],
            "snapshots": d["snapshots"]}


@app.get("/api/v1/accounts/{account_id}/quality")
async def account_quality(account_id: str, sess: gui_auth.Session = Depends(_require_session)):
    conn = db.get_connection(read_only=True)
    try:
        rows = conn.execute("""
            SELECT magic, symbol, avg_spread, max_spread, avg_slippage, max_slippage,
                   avg_latency_ms, max_latency_ms, success_rate, total_requests,
                   success_count, reject_count, requote_count, timeout_count,
                   broker_score, is_toxic, ts
            FROM broker_quality
            WHERE account_id=?
            ORDER BY ts DESC
        """, [account_id]).fetchall()
        result = []
        for r in rows:
            result.append({
                "magic": r[0], "symbol": r[1],
                "avg_spread": r[2], "max_spread": r[3],
                "avg_slippage": r[4], "max_slippage": r[5],
                "avg_latency_ms": r[6], "max_latency_ms": r[7],
                "success_rate": r[8], "total_requests": r[9],
                "success_count": r[10], "reject_count": r[11],
                "requote_count": r[12], "timeout_count": r[13],
                "broker_score": r[14], "is_toxic": r[15],
                "ts": r[16],
            })
        # Latest quality per symbol (deduplicated)
        latest = {}
        for q in result:
            key = q["symbol"]
            if key not in latest:
                latest[key] = q
        return {"quality": list(latest.values())}
    finally:
        conn.close()


@app.get("/api/v1/accounts/{account_id}/symbols")
async def account_symbols(account_id: str, sess: gui_auth.Session = Depends(_require_session)):
    conn = db.get_connection(read_only=True)
    try:
        return {"symbols": symbol_summary(conn, account_id)}
    finally:
        conn.close()


@app.get("/api/v1/accounts/{account_id}/winners-losers")
async def account_winners_losers(account_id: str, sess: gui_auth.Session = Depends(_require_session)):
    conn = db.get_connection(read_only=True)
    try:
        return winners_losers(conn, account_id)
    finally:
        conn.close()


@app.get("/api/v1/accounts/{account_id}/calendar")
async def account_calendar(account_id: str, year: int = None, month: int = None,
                           sess: gui_auth.Session = Depends(_require_session)):
    now = datetime.now(timezone.utc)
    y = year or now.year
    m = month or now.month
    conn = db.get_connection(read_only=True)
    try:
        return {"year": y, "month": m, "days": daily_calendar(conn, account_id, y, m)}
    finally:
        conn.close()


@app.get("/api/v1/accounts/{account_id}/advanced-summary")
async def account_advanced_summary(account_id: str,
                                   sess: gui_auth.Session = Depends(_require_session)):
    conn = db.get_connection(read_only=True)
    try:
        return {
            "summary": advanced_summary(conn, account_id),
            "monthly_grid": monthly_performance_grid(conn, account_id),
            "duration": duration_analysis(conn, account_id),
            "overall": overall_metrics(conn, account_id),
        }
    finally:
        conn.close()


@app.get("/api/v1/analytics/symbols")
async def analytics_symbols(sess: gui_auth.Session = Depends(_require_session)):
    conn = db.get_connection(read_only=True)
    try:
        return {"symbols": global_symbol_summary(conn)}
    finally:
        conn.close()


@app.get("/api/v1/analytics/calendar")
async def analytics_calendar(year: int = None, month: int = None,
                             sess: gui_auth.Session = Depends(_require_session)):
    now = datetime.now(timezone.utc)
    y = year or now.year
    m = month or now.month
    conn = db.get_connection(read_only=True)
    try:
        return {"year": y, "month": m, "days": global_daily_calendar(conn, y, m)}
    finally:
        conn.close()


@app.get("/api/v1/dashboard/summary")
async def summary(sess: gui_auth.Session = Depends(_require_session)):
    return dashboard_summary()


@app.get("/api/v1/version")
async def version():
    return {"version": __version__, "name": "ALX Account Monitor"}


# --- Auth Endpoints ---------------------------------------------------

@app.post("/api/v1/auth/login")
async def login(body: LoginBody, request: Request):
    ip = request.client.host if request.client else ""
    result = gui_auth.login(body.username, body.password, ip)
    if "error" in result:
        status = 429 if result["error"] == "rate limit exceeded" else 401
        return JSONResponse(status_code=status, content=result)
    return result


@app.post("/api/v1/auth/logout")
async def logout(sess: gui_auth.Session = Depends(_require_session)):
    gui_auth.logout(sess.token)
    return {"ok": True}


@app.get("/api/v1/auth/me")
async def auth_me(sess: gui_auth.Session = Depends(_require_session)):
    return {"user_id": sess.user_id, "username": sess.username, "role": sess.role}


# --- Admin Endpoints (admin only) -------------------------------------

@app.get("/api/v1/admin/users")
async def list_users(sess: gui_auth.Session = Depends(_require_admin)):
    return {"users": gui_auth.list_users()}


@app.post("/api/v1/admin/users")
async def create_user(body: CreateUserBody, sess: gui_auth.Session = Depends(_require_admin)):
    if body.role not in ("admin", "user"):
        raise HTTPException(status_code=400, detail="role must be 'admin' or 'user'")
    if len(body.password) < 6:
        raise HTTPException(status_code=400, detail="password must be at least 6 characters")
    result = gui_auth.create_user(body.username, body.password, body.role)
    if "error" in result:
        raise HTTPException(status_code=409, detail=result["error"])
    return result


@app.delete("/api/v1/admin/users/{user_id}")
async def delete_user(user_id: int, sess: gui_auth.Session = Depends(_require_admin)):
    # Nao permitir deletar a si mesmo
    if user_id == sess.user_id:
        raise HTTPException(status_code=400, detail="cannot delete your own account")
    ok = gui_auth.delete_user(user_id)
    if not ok:
        raise HTTPException(status_code=404, detail="user not found")
    return {"ok": True}


@app.put("/api/v1/admin/users/{user_id}/role")
async def update_role(user_id: int, body: UpdateRoleBody, sess: gui_auth.Session = Depends(_require_admin)):
    if body.role not in ("admin", "user"):
        raise HTTPException(status_code=400, detail="role must be 'admin' or 'user'")
    ok = gui_auth.update_user_role(user_id, body.role)
    if not ok:
        raise HTTPException(status_code=404, detail="user not found")
    return {"ok": True}


@app.put("/api/v1/admin/users/{user_id}/password")
async def reset_password(user_id: int, body: ResetPasswordBody, sess: gui_auth.Session = Depends(_require_admin)):
    if len(body.password) < 6:
        raise HTTPException(status_code=400, detail="password must be at least 6 characters")
    ok = gui_auth.reset_password(user_id, body.password)
    if not ok:
        raise HTTPException(status_code=404, detail="user not found")
    return {"ok": True}


# --- Telegram Config (Admin auth) --------------------------------------

@app.get("/api/v1/admin/telegram/config")
async def get_telegram_config(sess: gui_auth.Session = Depends(_require_admin)):
    return telegram_alert.get_config()


@app.put("/api/v1/admin/telegram/config")
async def save_telegram_config(body: TelegramConfigBody, sess: gui_auth.Session = Depends(_require_admin)):
    return telegram_alert.save_config(
        bot_token=body.bot_token, chat_id=body.chat_id,
        enabled=body.enabled, alert_offline=body.alert_offline,
        alert_drawdown=body.alert_drawdown, dd_threshold_pct=body.dd_threshold_pct,
    )


@app.post("/api/v1/admin/telegram/test")
async def test_telegram(body: TelegramTestBody, sess: gui_auth.Session = Depends(_require_admin)):
    cfg = telegram_alert.get_config()
    if not cfg.get("bot_token") or not cfg.get("chat_id"):
        raise HTTPException(status_code=400, detail="bot_token and chat_id must be configured")
    sent = telegram_alert.send_telegram(body.message)
    if not sent:
        raise HTTPException(status_code=502, detail="failed to send message via Telegram")
    return {"ok": True, "message": "test message sent"}


# --- Alerts (GUI session auth) -----------------------------------------

@app.get("/api/v1/alerts")
async def get_alerts(sess: gui_auth.Session = Depends(_require_session)):
    return {"alerts": telegram_alert.get_alerts(limit=100)}


@app.get("/api/v1/alerts/summary")
async def get_alerts_summary(sess: gui_auth.Session = Depends(_require_session)):
    return telegram_alert.get_alerts_summary()


# --- Admin Endpoints (GUI session auth) --------------------------------

@app.post("/api/v1/admin/revoke/{account_id}")
async def revoke(account_id: str, sess: gui_auth.Session = Depends(_require_admin)):
    ok = keys_store.revoke(account_id)
    return {"ok": ok}


@app.delete("/api/v1/accounts/{account_id}")
async def delete_account(account_id: str, sess: gui_auth.Session = Depends(_require_admin)):
    conn = db.get_connection(read_only=False)
    try:
        for t in ("positions_current", "account_snapshots", "deal_events", "position_events", "accounts_current"):
            conn.execute(f"DELETE FROM {t} WHERE account_id=?", [account_id])
        conn.commit()
    finally:
        conn.close()
    keys_store.delete_key(account_id)
    return {"ok": True}


# --- WebSocket --------------------------------------------------------

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    await ws.register(websocket)
    try:
        while True:
            await websocket.receive_text()  # heartbeat do cliente
    except WebSocketDisconnect:
        await ws.unregister(websocket)


# --- Static Files -----------------------------------------------------

app.mount("/css", StaticFiles(directory=str(STATIC_DIR / "css")), name="css")
app.mount("/js", StaticFiles(directory=str(STATIC_DIR / "js")), name="js")


@app.get("/")
async def index():
    return FileResponse(str(STATIC_DIR / "index.html"))


def main():
    import uvicorn
    uvicorn.run("Modulos.account_monitor.serve:app", host=config.host, port=config.port)


if __name__ == "__main__":
    main()
