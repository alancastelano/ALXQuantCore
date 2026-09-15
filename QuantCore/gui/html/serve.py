"""
ALXQUANT Terminal â€” FastAPI Backend
====================================
Serves the Bloomberg-style dashboard with live data from DuckDB,
Risk Sentiment Engine, and Windows Task Scheduler.

Run:
    python -m gui.html.serve
    # or
    cd gui/html && uvicorn serve:app --reload --port 8000
"""
import sys
import os
import re
import json
import subprocess
import shutil
import time
import asyncio
import threading as _threading
from collections import deque
from datetime import datetime
from pathlib import Path

# Ensure project root is on sys.path
PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
REPO_ROOT = PROJECT_ROOT.parent  # repo root: data/, MQL5/, .env live here
sys.path.insert(0, str(PROJECT_ROOT))

import config
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Body
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from dotenv import load_dotenv
import uvicorn

load_dotenv(REPO_ROOT / ".env", override=True)


# â”€â”€ Execution Log Buffer â”€â”€
_log_buffer: deque = deque(maxlen=5000)
_log_lock = _threading.Lock()
_log_id = 0


def _push_log(level: str, message: str):
    global _log_id
    ts = datetime.now().strftime("%H:%M:%S")
    with _log_lock:
        _log_id += 1
        _log_buffer.append({"id": _log_id, "ts": ts, "level": level, "message": message})


# â”€â”€ Subprocess streaming helper â”€â”€
def _run_subprocess_stream(args, label, cwd=None, timeout=300):
    """Run subprocess with Popen, streaming stdout/stderr to _push_log line-by-line."""
    _push_log("INFO", f"{label}: starting...")
    env = os.environ.copy()
    env["PYTHONUTF8"] = "1"
    proc = subprocess.Popen(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        cwd=cwd or PROJECT_ROOT,
        env=env,
    )
    stdout_lines = []
    stderr_lines = []

    def _reader(stream, level, lines):
        for line in iter(stream.readline, ''):
            line = line.rstrip('\n\r')
            if line:
                lines.append(line)
                _push_log(level, f"{label}: {line}")
        stream.close()

    t1 = _threading.Thread(target=_reader, args=(proc.stdout, "INFO", stdout_lines))
    t2 = _threading.Thread(target=_reader, args=(proc.stderr, "ERROR", stderr_lines))
    t1.start()
    t2.start()

    t1.join(timeout=timeout)
    t2.join(timeout=timeout)

    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        _push_log("ERROR", f"{label}: TIMEOUT after {timeout}s")
        return {"ok": False, "code": -1,
                "stdout": "\n".join(stdout_lines), "stderr": "\n".join(stderr_lines)}

    ok = proc.returncode == 0
    _push_log("INFO" if ok else "ERROR",
              f"{label}: {'OK' if ok else 'FAIL (code ' + str(proc.returncode) + ')'}")
    return {"ok": ok, "code": proc.returncode,
            "stdout": "\n".join(stdout_lines), "stderr": "\n".join(stderr_lines)}


# â”€â”€ Startup: ensure indexes â”€â”€
def _ensure_indexes():
    from Modulos.datahouse.collector import get_connection
    try:
        conn = get_connection()
        conn.execute("CREATE INDEX IF NOT EXISTS idx_macro_series_sym_date ON macro_series(symbol, date)")
        conn.close()
        _push_log("INFO", "Startup: macro_series index OK")
    except Exception as ex:
        _push_log("WARNING", f"Startup: index creation error â€” {ex}")


@asynccontextmanager
async def lifespan(app: FastAPI):
    _ensure_indexes()
    _threading.Thread(target=_warm_macro_cache, daemon=True).start()
    yield


def _warm_macro_cache():
    """Pre-load macro-state cache on server startup so first request is instant."""
    try:
        from Modulos.datahouse.collector import get_connection
        conn = get_connection()
        try:
            t0 = time.time()
            data = _build_macro_state_payload(conn)
            _MACRO_STATE_CACHE["data"] = data
            _MACRO_STATE_CACHE["ts"] = time.time()
            print(f"[warmup] macro-state cache ready in {time.time()-t0:.1f}s")
        finally:
            conn.close()
    except Exception as e:
        print(f"[warmup] FAILED: {e}")


app = FastAPI(title="ALXQUANT Terminal API", version="10.3.3", lifespan=lifespan)

HERE = Path(__file__).parent

# â”€â”€ Static files (CSS, JS) â”€â”€
app.mount("/css", StaticFiles(directory=str(HERE / "css")), name="css")
app.mount("/js", StaticFiles(directory=str(HERE / "js")), name="js")
app.mount("/brand", StaticFiles(directory=str(REPO_ROOT / "data" / "image")), name="brand")


@app.get("/api/logs")
async def get_logs(since: int = 0):
    """Return log entries since a given id."""
    with _log_lock:
        entries = [e for e in _log_buffer if e["id"] > since]
    return {"entries": entries, "now": _log_id}


@app.get("/api/logs/tail")
async def get_logs_tail(n: int = 50):
    """Return last N log entries."""
    with _log_lock:
        entries = list(_log_buffer)[-n:]
    return {"entries": entries, "now": _log_id}


@app.get("/")
async def index():
    return FileResponse(str(HERE / "dashboard.html"))


# â”€â”€ API Endpoints â”€â”€

@app.get("/api/status")
async def get_status():
    """DB domains status (OHLC, Macro, Calendar, Risk)."""
    try:
        from Modulos.datahouse.engine import get_db_status
        data = get_db_status()
        summary = data.get("summary", {})
        total_rows = sum(d.get("rows", 0) for d in data.get("domains", []))
        summary["total_rows"] = total_rows
        return {"domains": data.get("domains", []), "summary": summary}
    except Exception as e:
        return {"domains": [], "summary": {"total": 0, "ok": 0, "stale": 0, "critical": 0, "total_rows": 0}, "error": str(e)}


@app.get("/api/symbols")
async def get_symbols():
    """All OHLC symbols with last candle info."""
    try:
        from Modulos.datahouse.engine import get_all_symbols, get_all_timeframes
        from Modulos.datahouse.collector import get_last_timestamp
        from datetime import datetime, timezone

        symbols = get_all_symbols()
        tfs = get_all_timeframes()
        result = []
        for sym in symbols:
            for tf in tfs:
                ts = get_last_timestamp(sym, tf)
                row = {"symbol": sym, "timeframe": tf}
                if ts:
                    dt = datetime.fromtimestamp(ts, tz=timezone.utc)
                    age_h = (datetime.now(timezone.utc) - dt).total_seconds() / 3600
                    row["last_close"] = _get_last_close(sym, tf)
                    row["last_ts"] = dt.isoformat()
                    row["age_hours"] = round(age_h, 1)
                result.append(row)
        return result
    except Exception as e:
        return []


# ── Check FAQs (mesas proprietárias) ──
CHECKFAQS_SCAN_RUNNING = False
_CHECKFAQS_SCAN_LOCK = _threading.Lock()


@app.get("/api/checkfaqs")
async def get_checkfaqs():
    """Resumo das mesas proprietárias monitoradas (estado de prop_monitor_data.json)."""
    from Modulos.CheckFAQs import check_faqs
    path = Path(check_faqs.DATA_FILE)
    firms = []
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            data = {}
        for name, pages in (data or {}).items():
            if not isinstance(pages, dict):
                continue
            page_list = []
            any_changed = False
            for key, p in (pages or {}).items():
                changed = bool(p.get("changed"))
                if changed:
                    any_changed = True
                page_list.append({
                    "key": key,
                    "type": p.get("type", ""),
                    "url": p.get("url", ""),
                    "last_checked": p.get("last_checked", ""),
                    "last_changed": p.get("last_changed", ""),
                    "changed": changed,
                })
            firms.append({"name": name, "any_changed": any_changed, "pages": page_list})
    return {"scanning": CHECKFAQS_SCAN_RUNNING, "firms": firms}


@app.get("/api/checkfaqs/firm")
async def get_checkfaqs_firm(name: str = ""):
    """Detalhe de uma mesa (texto anterior/atual) para o modal ANTES/DEPOIS."""
    from Modulos.CheckFAQs import check_faqs
    path = Path(check_faqs.DATA_FILE)
    if not path.exists():
        return {"name": name, "pages": []}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        data = {}
    pages = (data or {}).get(name, {})
    out = []
    for key, p in (pages or {}).items():
        out.append({
            "key": key,
            "type": p.get("type", ""),
            "url": p.get("url", ""),
            "previous_text": p.get("previous_text", ""),
            "text": p.get("text", ""),
            "prices": p.get("prices", []),
            "previous_prices": p.get("previous_prices", []),
            "discounts": p.get("discounts", []),
            "previous_discounts": p.get("previous_discounts", []),
            "changed": bool(p.get("changed")),
        })
    return {"name": name, "pages": out}


@app.get("/api/checkfaqs/run")
async def run_checkfaqs():
    """Dispara o scan (Playwright) em thread de fundo; retorna imediatamente."""
    global CHECKFAQS_SCAN_RUNNING
    with _CHECKFAQS_SCAN_LOCK:
        if CHECKFAQS_SCAN_RUNNING:
            return {"ok": False, "status": "running"}
        CHECKFAQS_SCAN_RUNNING = True

    def _worker():
        global CHECKFAQS_SCAN_RUNNING
        try:
            from Modulos.CheckFAQs import check_faqs
            check_faqs.main()
        except Exception as exc:  # noqa: BLE001
            _push_log("ERROR", f"CheckFAQs scan falhou: {exc}")
        finally:
            with _CHECKFAQS_SCAN_LOCK:
                CHECKFAQS_SCAN_RUNNING = False

    t = _threading.Thread(target=_worker, daemon=True)
    t.start()
    return {"ok": True, "status": "started"}


@app.post("/api/checkfaqs/add")
async def add_checkfaqs_firm(payload: dict = Body(...)):
    """Cadastra uma nova mesa (prop firm) via UI, sem editar o código."""
    from Modulos.CheckFAQs import check_faqs
    name = (payload.get("name") or "").strip()
    home = (payload.get("home") or "").strip()
    if not name or not home:
        return {"ok": False, "message": "nome e url obrigatorios"}
    ok, msg = check_faqs.add_user_firm(name, home)
    return {"ok": ok, "message": msg}


@app.delete("/api/checkfaqs/firm")
async def delete_checkfaqs_firm(payload: dict = Body(...)):
    """Remove uma mesa cadastrada pelo usuário do arquivo de cadastro."""
    from Modulos.CheckFAQs import check_faqs
    name = (payload.get("name") or "").strip()
    if not name:
        return {"ok": False, "message": "nome obrigatorio"}
    data = check_faqs.load_json(check_faqs.USER_FIRMS_FILE)
    firms = data.get("firms", [])
    new_firms = [f for f in firms if f.get("name") != name]
    if len(new_firms) == len(firms):
        return {"ok": False, "message": "mesa nao encontrada no cadastro do usuario"}
    data["firms"] = new_firms
    check_faqs.save_json(check_faqs.USER_FIRMS_FILE, data)
    return {"ok": True, "message": "mesa removida"}


def _get_last_close(symbol: str, tf: str):
    from Modulos.datahouse.collector import get_connection
    with get_connection() as conn:
        r = conn.execute(
            "SELECT close FROM ohlc_prices WHERE symbol=? AND timeframe=? ORDER BY time DESC LIMIT 1",
            [symbol, tf]
        ).fetchone()
        return float(r[0]) if r else None


@app.get("/api/ohlc/{symbol}/{tf}")
async def get_ohlc(symbol: str, tf: str, limit: int = 60):
    """OHLC candles for chart."""
    try:
        from Modulos.datahouse.collector import get_connection
        with get_connection() as conn:
            rows = conn.execute(
                "SELECT time, open, high, low, close, tick_volume FROM ohlc_prices "
                "WHERE symbol=? AND timeframe=? ORDER BY time DESC LIMIT ?",
                [symbol, tf, limit]
            ).fetchall()
            return [
                {"time": r[0], "open": float(r[1]), "high": float(r[2]),
                 "low": float(r[3]), "close": float(r[4]), "tick_volume": r[5]}
                for r in reversed(rows)
            ]
    except Exception as e:
        return []


def _calc_change(curr, prev):
    """Return (abs_change, pct_change) or (None, None)."""
    if curr is None or prev is None or prev == 0:
        return None, None
    return round(curr - prev, 2), round((curr - prev) / prev * 100, 2)


@app.get("/api/risk")
async def get_risk():
    """Latest Risk Sentiment values with daily change."""
    from Modulos.datahouse.collector import get_connection
    conn = None
    try:
        conn = get_connection()
        row = conn.execute("""
            SELECT date, risk_label, signal_strength, roro_score,
                   vix, dxy, yield_10y,
                   (SELECT vix FROM v_risk_sentiment v2 WHERE v2.date < v.date AND v2.vix IS NOT NULL ORDER BY v2.date DESC LIMIT 1) AS vix_prev,
                   (SELECT dxy FROM v_risk_sentiment v2 WHERE v2.date < v.date AND v2.dxy IS NOT NULL ORDER BY v2.date DESC LIMIT 1) AS dxy_prev,
                   (SELECT yield_10y FROM v_risk_sentiment v2 WHERE v2.date < v.date AND v2.yield_10y IS NOT NULL ORDER BY v2.date DESC LIMIT 1) AS yield_10y_prev
            FROM v_risk_sentiment v
            ORDER BY date DESC LIMIT 1
        """).fetchone()
        if not row:
            return {}

        (date, risk_label, signal_strength, roro_score,
         vix, dxy, yield_10y,
         vix_prev, dxy_prev, yield_10y_prev) = row

        curr_map = {"vix": vix, "dxy": dxy, "yield_10y": yield_10y}
        prev_map = {"vix": vix_prev, "dxy": dxy_prev, "yield_10y": yield_10y_prev}

        result = {
            "date": date,
            "risk_label": risk_label,
            "roro_score": float(roro_score) if roro_score else 0,
            "signal_strength": signal_strength or "low",
        }

        for k in ("vix", "dxy", "yield_10y"):
            c = float(curr_map[k]) if curr_map[k] else None
            p = float(prev_map[k]) if prev_map[k] else None
            chg, chg_pct = _calc_change(c, p)
            result[k] = c
            if chg is not None:
                result[f"{k}_chg"] = chg
                result[f"{k}_chg_pct"] = chg_pct

        # SPY / GLD — fetch latest two rows per symbol from macro_series
        extra = conn.execute("""
            WITH ranked AS (
                SELECT symbol, value, date,
                       ROW_NUMBER() OVER (PARTITION BY symbol ORDER BY date DESC) AS rn
                FROM macro_series
                WHERE symbol IN ('SPY','GLD')
            )
            SELECT a.symbol, a.value, b.value AS prev_value
            FROM ranked a
            LEFT JOIN ranked b ON a.symbol = b.symbol AND b.rn = 2
            WHERE a.rn = 1
        """).fetchall()
        for sym, val, prev_val in extra:
            c = float(val) if val else None
            p = float(prev_val) if prev_val else None
            chg, chg_pct = _calc_change(c, p)
            key = "equity_sp" if sym == "SPY" else "gold"
            result[key] = c
            if chg is not None:
                result[f"{key}_chg"] = chg
                result[f"{key}_chg_pct"] = chg_pct

        # RORO derivados (engine -> macro_series como RORO_*)
        roro_map = {
            'roro_kcroro_z': 'RORO_RORO_KCORO_Z',
            'roro_pca': 'RORO_RORO_PCA',
            'roro_v4': 'RORO_RORO_V4',
            'roro_credit': 'RORO_RORO_CREDIT',
            'roro_equity_vol': 'RORO_RORO_EQUITY_VOL',
            'roro_funding': 'RORO_RORO_FUNDING',
            'roro_fx_gold': 'RORO_RORO_FX_GOLD',
            'global_risk_score': 'RORO_GLOBAL_RISK_SCORE',
        }
        sym_list = list(roro_map.values())
        if sym_list:
            placeholders = ", ".join("'" + s.replace("'", "''") + "'" for s in sym_list)
            roro_rows = conn.execute(f"""
                SELECT symbol, value FROM (
                    SELECT symbol, value,
                           ROW_NUMBER() OVER (PARTITION BY symbol ORDER BY date DESC) AS rn
                    FROM macro_series WHERE symbol IN ({placeholders})
                ) WHERE rn = 1
            """).fetchall()
            for sym, val in roro_rows:
                for key, s in roro_map.items():
                    if s == sym and val is not None:
                        result[key] = float(val)

        # credit_hy / yield_2y / yield_2y_prev de macro_series
        extra2 = conn.execute("""
            WITH ranked AS (
                SELECT symbol, value, date,
                       ROW_NUMBER() OVER (PARTITION BY symbol ORDER BY date DESC) AS rn
                FROM macro_series
                WHERE symbol IN ('BAMLH0A0HYM2','DGS2')
            )
            SELECT a.symbol, a.value, b.value AS prev_value
            FROM ranked a
            LEFT JOIN ranked b ON a.symbol = b.symbol AND b.rn = 2
            WHERE a.rn = 1
        """).fetchall()
        for sym, val, prev_val in extra2:
            if sym == 'BAMLH0A0HYM2':
                if val is not None:
                    result['credit_hy'] = float(val)
            elif sym == 'DGS2':
                c = float(val) if val else None
                result['yield_2y'] = c
                p = float(prev_val) if prev_val else None
                chg, chg_pct = _calc_change(c, p)
                if chg is not None:
                    result['yield_2y_prev'] = p
                    result['yield_2y_chg'] = chg
                    result['yield_2y_chg_pct'] = chg_pct

        # equity_intl (EFA) de macro_series
        ei = conn.execute(
            "SELECT value FROM macro_series WHERE symbol = 'EFA' ORDER BY date DESC LIMIT 1"
        ).fetchone()
        if ei and ei[0] is not None:
            result['equity_intl'] = float(ei[0])

        return result
    except Exception as e:
        print(f"[api/risk] ERROR: {e}")
        return {}
    finally:
        try:
            conn.close()
        except Exception:
            pass


@app.get("/api/schedules")
async def get_schedules():
    """Windows Task Scheduler status."""
    try:
        from Modulos.datahouse.scheduler import validate_all_tasks
        return validate_all_tasks()
    except Exception as e:
        return []


@app.get("/api/schedules/register")
async def register_tasks():
    """Registra as tasks do Windows Task Scheduler e atualiza os dados imediatamente.

    Se o registro for bem-sucedido, a task ALX-DataHouse-CollectAll passará a rodar
    SYSTEM a cada hora, atualizando OHLC (com yfinance fallback), MACRO (FRED) e RISK.
    Se falhar (sem admin), a coleta interna é acionada imediatamente para atualizar
    os dados enquanto o servidor estiver rodando.

    Returns:
        messages: lista de mensagens (sucesso/erro do registro + status da coleta)
    """
    from Modulos.datahouse.scheduler import register_windows_tasks
    # 1. Tenta registrar as tasks Windows (pode falhar com acesso negado)
    messages = register_windows_tasks(log_callback=lambda m: _push_log("SCHED", m))
    # 2. Dispara coleta interna de OHLC+MACRO+RISK (funciona com ou sem registro admin)
    _run_collect_all_internal()
    # 3. Monta resposta combinada
    ok = any("OK" in m for m in messages)
    friendly = []
    for m in messages:
        if "ACESSO NEGADO" in m:
            friendly.append(f"⚠ {m} • Reinicie o servidor como admin para registrar tasks definitivas")
        else:
            friendly.append(m)
    return {"messages": friendly, "collect_all_ran": True, "admin_required": not ok}


@app.get("/api/schedules/remove")
async def remove_tasks():
    """Remove all tasks from Windows Task Scheduler."""
    from Modulos.datahouse.scheduler import unregister_windows_tasks
    _push_log("INFO", "Scheduler: removing all tasks...")
    messages = unregister_windows_tasks(log_callback=lambda msg: _push_log("SCHED", msg))
    _push_log("INFO", f"Scheduler: {len(messages)} tasks removed")
    return {"messages": messages}


@app.get("/api/schedules/run-now")
async def run_collect_now():
    """Forca a coleta imediata (OHLC+MACRO+RISK) via orquestrador, sem depender
    do registro de task Windows. Util para testar/desatravar dados ja."""
    _run_collect_all_internal()
    return {"ok": True, "message": "CollectAll disparado"}


@app.get("/api/macro")
async def get_macro():
    """All macro_catalog indicators with latest value from macro_series."""
    try:
        from Modulos.datahouse.collector import get_connection
        with get_connection() as conn:
            rows = conn.execute("""
                SELECT mc.symbol, ms.value, ms.date, ms.updated_at,
                       mc.name, mc.country, mc.category, mc.unit, mc.description, mc.source
                FROM macro_catalog mc
                LEFT JOIN macro_series ms ON ms.symbol = mc.symbol
                    AND ms.date = (SELECT MAX(ms2.date) FROM macro_series ms2 WHERE ms2.symbol = mc.symbol)
                ORDER BY mc.category, mc.name
            """).fetchall()
            return [{"symbol": r[0], "value": float(r[1]) if r[1] else None,
                     "date": r[2], "updated_at": r[3], "name": r[4], "country": r[5],
                "category": r[6], "unit": r[7], "description": r[8], "source": r[9]} for r in rows]
    except Exception as e:
        return []


_MACRO_STATE_CACHE = {"ts": 0.0, "data": None, "ttl": 3600.0}


def _build_macro_state_payload(conn):
    from Modulos.macro_state import economic_state
    snap = economic_state.get_state(conn)
    econ = {}
    for economy, st in snap["economies"].items():
        dims = st["dimensions"] or {}
        rec_meta = (dims.get("recession") or (None, "", {}))[2]
        rec_prob = rec_meta.get("prob") if isinstance(rec_meta, dict) else None
        ph_sc, ph_st, _ = st.get("phillips") or (None, None, {})
        dq = st.get("data_quality") or {}
        econ[economy] = {
            "regime": st.get("regime"),
            "regime_confidence": st.get("regime_confidence"),
            "momentum": st.get("momentum"),
            "stability": st.get("stability"),
            "score": st.get("score"),
            "dimensions": {d: {"score": (v[0] if v else None), "state": (v[1] if v else None)}
                            for d, v in dims.items()},
            "contributions": st.get("contributions"),
            "phillips_score": ph_sc,
            "phillips_state": ph_st,
            "recession_prob": rec_prob,
            "data_quality": dq.get("status"),
            "coverage": dq.get("coverage"),
            "freshness": dq.get("freshness"),
        }
    g = snap.get("global") or {}
    g_dims = g.get("dimensions") or {}
    global_block = {
        "regime": g.get("regime"),
        "regime_confidence": g.get("regime_confidence"),
        "momentum": g.get("momentum"),
        "stability": g.get("stability"),
        "score": g.get("score"),
        "contributions": g.get("contributions"),
        "dimensions": {d: {"score": (v[0] if v else None), "state": (v[1] if v else None)}
                        for d, v in g_dims.items()},
    }
    return {"generated_at": snap.get("computed_at"), "global": global_block, "economies": econ}


@app.get("/api/macro-state")
async def get_macro_state():
    """Global Macro Economic State — computado on-the-fly a partir do macro_series do datahouse.

    Read-only: le o DB central (ALXQuantCore.duckdb) via get_connection().
    Nunca escreve (logo nao trava o servidor). Cache em memoria (~300s) para nao recomputar
    a cada request.
    """
    cache = _MACRO_STATE_CACHE
    now = time.time()
    if cache["data"] is not None and (now - cache["ts"]) < cache["ttl"]:
        return cache["data"]
    from Modulos.datahouse.collector import get_connection
    try:
        conn = get_connection()
    except Exception as e:
        return {"generated_at": None, "note": "datahouse DB indisponivel", "error": str(e)}
    try:
        data = _build_macro_state_payload(conn)
    except Exception as e:
        return {"generated_at": None, "note": "falha ao computar macro-state", "error": str(e)}
    finally:
        conn.close()
    cache["data"] = data
    cache["ts"] = now
    return data


@app.get("/api/macro-state/global")
async def get_macro_state_global():
    full = await get_macro_state()
    return {"generated_at": full.get("generated_at"), "global": full.get("global")}


@app.get("/api/macro-state/{economy}")
async def get_macro_state_economy(economy: str):
    full = await get_macro_state()
    economies = full.get("economies", {})
    return {"generated_at": full.get("generated_at"),
            "economy": economies.get(economy.upper(), economies.get(economy))}


@app.get("/api/health")
async def get_health():
    """Unified data freshness health check across ALL domains."""
    try:
        from Modulos.datahouse.validator import check_domain_freshness
        result = check_domain_freshness()
        return JSONResponse(content=result, status_code=200)
    except Exception as e:
        return JSONResponse(content={"overall": "error", "error": str(e), "domains": [], "summary": {"ok": 0, "stale": 0, "critical": 0, "total": 0}}, status_code=200)


@app.get("/api/health/pending")
async def health_pending():
    """Count of items needing repair per domain."""
    try:
        from Modulos.datahouse.validator import count_pending_repairs
        return count_pending_repairs()
    except Exception as e:
        return {"total": 0, "domains": {}, "error": str(e)}


@app.post("/api/health/repair")
async def repair_all():
    """Trigger data collection for all stale/critical domains."""
    from Modulos.datahouse.validator import repair_domain
    _push_log("INFO", "Repair: starting ALL domains...")
    result = repair_domain("all")
    _push_log("INFO", f"Repair: completed â€” {result}")
    return result


@app.get("/api/health/repair/status")
async def repair_status():
    """Poll current async repair progress."""
    from Modulos.datahouse.validator import get_repair_status
    return get_repair_status()


@app.post("/api/health/repair/{domain}")
async def repair_domain_ep(domain: str):
    """Trigger data collection for a specific domain."""
    from Modulos.datahouse.validator import repair_domain
    _push_log("INFO", f"Repair: starting {domain}...")
    result = repair_domain(domain)
    _push_log("INFO", f"Repair: {domain} completed â€” {result}")
    return result


@app.get("/api/strategy-tester/prepare")
async def strategy_tester_prepare(symbol: str = "XAUUSD", tf: str = "M5"):
    """Run asset_dna generator to produce asset_profile JSON for Strategy Tester."""
    script = os.path.join(PROJECT_ROOT, "Modulos", "asset_dna", "asset_dna_full.py")
    if not os.path.exists(script):
        return {"ok": False, "error": f"Script not found: {script}"}
    try:
        result = await asyncio.to_thread(
            _run_subprocess_stream,
            [sys.executable, script, "--symbol", symbol, "--tf", tf, "--skip-pdf", "--skip-institutional"],
            f"ST ({symbol} {tf})",
            timeout=120,
        )
        return result
    except Exception as ex:
        _push_log("ERROR", f"StrategyTester: {ex}")
        return {"ok": False, "error": str(ex)}


@app.get("/api/asset-dna/profile/{symbol}")
async def asset_dna_profile(symbol: str, tf: str = "M5"):
    """Load existing Asset DNA JSON profile and return in dashboard-friendly shape."""
    profile_path = REPO_ROOT / "data" / "mql5" / f"asset_profile_{symbol}_{tf}.json"
    if not profile_path.exists():
        raise HTTPException(status_code=404, detail=f"No profile for {symbol} {tf}")
    import json as _json
    raw = _json.loads(profile_path.read_text(encoding="utf-8"))
    meta = raw.get("meta", {})
    regime_raw = raw.get("dominant_regime", "N/A")
    trading = raw.get("ea_trading_parameters", {})
    sl_mult = trading.get("sl_atr_multiplier", {}).get(regime_raw, 1.0)
    tp_mult = trading.get("tp_atr_multiplier", {}).get(regime_raw, 2.0)
    atr = raw.get("atr_mean", 0)
    return {
        "metadata": meta,
        "regime_analysis": {
            "dominant_regime": regime_raw,
            "hurst_exponent": raw.get("hurst_mean"),
            "adx_value": raw.get("adx_mean"),
            "confidence_r2": None,
            "atr_value": atr,
        },
        "ea_trading_parameters": {
            **trading,
            "atr_value": atr,
            "sl_pips": round(atr * sl_mult / 0.01, 1) if atr else None,
            "tp_pips": round(atr * tp_mult / 0.01, 1) if atr else None,
        },
        "scores": {
            "trend_following": raw.get("trend_following_score"),
            "mean_reversion": raw.get("mean_reversion_score"),
            "breakout": raw.get("breakout_score"),
            "stability": raw.get("stability_score"),
        },
        "raw": raw,
    }


@app.get("/api/asset-dna/run")
async def asset_dna_run(
    symbol: str = "XAUUSD",
    tf: str = "M5",
    years: int = 5,
    skip_pdf: bool = False,
    skip_institutional: bool = False,
):
    """Run asset_dna full profiler to generate report + JSON profile."""
    script = os.path.join(PROJECT_ROOT, "Modulos", "asset_dna", "asset_dna_full.py")
    if not os.path.exists(script):
        return {"ok": False, "error": f"Script not found: {script}"}
    # Limpa cache stale que pode causar IndexError no profiler
    cache_dir = os.path.join(PROJECT_ROOT, "data", "cache", "asset_dna")
    if os.path.isdir(cache_dir):
        shutil.rmtree(cache_dir)
        _push_log("INFO", f"AssetDNA: cache limpo ({cache_dir})")
    args = [sys.executable, script, "--symbol", symbol, "--tf", tf, "--years", str(years)]
    if skip_pdf:
        args.append("--skip-pdf")
    if skip_institutional:
        args.append("--skip-institutional")
    try:
        result = await asyncio.to_thread(
            _run_subprocess_stream,
            args,
            f"AssetDNA ({symbol})",
            timeout=600,
        )
        return result
    except Exception as ex:
        _push_log("ERROR", f"AssetDNA: {ex}")
        return {"ok": False, "error": str(ex)}


@app.get("/api/asset-dna/json/{symbol}")
async def asset_dna_json(symbol: str, tf: str = "M5"):
    """Serve Asset DNA JSON profile inline (no download header)."""
    json_path = REPO_ROOT / "data" / "mql5" / f"asset_profile_{symbol}_{tf}.json"
    if not json_path.exists():
        raise HTTPException(status_code=404, detail=f"JSON not found for {symbol} {tf}")
    import json as _json
    import math
    with open(json_path, "r", encoding="utf-8") as f:
        raw = f.read()
    data = _json.loads(raw, parse_constant=lambda v: None if v == "NaN" else float(v))

    def _sanitize(obj):
        if isinstance(obj, float) and (math.isnan(obj) or math.isinf(obj)):
            return None
        if isinstance(obj, dict):
            return {k: _sanitize(v) for k, v in obj.items()}
        if isinstance(obj, list):
            return [_sanitize(v) for v in obj]
        return obj

    return _sanitize(data)


@app.get("/api/asset-dna/pdf/{symbol}")
async def asset_dna_pdf(symbol: str, tf: str = "M5"):
    """Serve the generated Asset DNA PDF report."""
    pdf_path = REPO_ROOT / "data" / "mql5" / f"asset_dna_{symbol}_{tf}.pdf"
    if not pdf_path.exists():
        raise HTTPException(status_code=404, detail=f"PDF not found for {symbol} {tf}")
    return FileResponse(
        str(pdf_path),
        media_type="application/pdf",
    )


@app.get("/api/asset-dna/download/{symbol}")
async def asset_dna_download(symbol: str, tf: str = "M5", type: str = "json"):
    """Download Asset DNA profile as JSON or PDF."""
    if type == "pdf":
        pdf_path = REPO_ROOT / "data" / "mql5" / f"asset_dna_{symbol}_{tf}.pdf"
        if not pdf_path.exists():
            raise HTTPException(status_code=404, detail=f"PDF not found for {symbol} {tf}")
        return FileResponse(
            str(pdf_path),
            media_type="application/pdf",
            filename=f"asset_dna_{symbol}_{tf}.pdf",
        )
    else:
        json_path = REPO_ROOT / "data" / "mql5" / f"asset_profile_{symbol}_{tf}.json"
        if not json_path.exists():
            raise HTTPException(status_code=404, detail=f"JSON not found for {symbol} {tf}")
        return FileResponse(
            str(json_path),
            media_type="application/json",
            filename=f"asset_profile_{symbol}_{tf}.json",
        )


@app.delete("/api/asset-dna/delete/{symbol}")
async def asset_dna_delete(symbol: str, tf: str = "M5", type: str = "json"):
    """Delete an Asset DNA report file."""
    if type == "pdf":
        file_path = REPO_ROOT / "data" / "mql5" / f"asset_dna_{symbol}_{tf}.pdf"
    else:
        file_path = REPO_ROOT / "data" / "mql5" / f"asset_profile_{symbol}_{tf}.json"
    if not file_path.exists():
        raise HTTPException(status_code=404, detail=f"File not found: {file_path.name}")
    file_path.unlink()
    _push_log("INFO", f"AssetDNA: deletado {file_path.name}")
    return {"ok": True, "deleted": file_path.name}


@app.get("/api/asset-dna/list")
async def asset_dna_list():
    """List available Asset DNA reports in data/mql5/ + overlay TXT files."""
    report_dir = REPO_ROOT / "data" / "mql5"
    overlay_dir = REPO_ROOT / "MQL5" / "MQL5" / "Files"
    files = {"pdf": [], "json": [], "txt": []}
    if report_dir.exists():
        for f in sorted(report_dir.glob("asset_dna_*.pdf")):
            stat = f.stat()
            files["pdf"].append({
                "name": f.name,
                "symbol": f.stem.replace("asset_dna_", "").rsplit("_", 1)[0],
                "size_kb": round(stat.st_size / 1024, 1),
                "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
            })
        for f in sorted(report_dir.glob("asset_profile_*.json")):
            stat = f.stat()
            files["json"].append({
                "name": f.name,
                "symbol": f.stem.replace("asset_profile_", "").rsplit("_", 1)[0],
                "size_kb": round(stat.st_size / 1024, 1),
                "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
            })
    if overlay_dir.exists():
        for f in sorted(overlay_dir.glob("macro_overlay_*.txt")):
            stat = f.stat()
            sym = f.stem.replace("macro_overlay_", "")
            files["txt"].append({
                "name": f.name,
                "symbol": sym,
                "size_kb": round(stat.st_size / 1024, 1),
                "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
            })
    return files


@app.get("/api/macro-overlay/run")
async def macro_overlay_run(symbol: str = "XAUUSD", tf: str = "M5"):
    """Run macro_overlay.py to generate KEY=VALUE + JSON for EA."""
    script = os.path.join(PROJECT_ROOT, "Modulos", "macro_state", "macro_overlay.py")
    if not os.path.exists(script):
        return {"ok": False, "error": f"Script not found: {script}"}
    args = [sys.executable, script, symbol, tf]
    try:
        result = await asyncio.to_thread(
            _run_subprocess_stream,
            args,
            f"MacroOverlay ({symbol})",
            timeout=60,
        )
        return result
    except Exception as ex:
        _push_log("ERROR", f"MacroOverlay: {ex}")
        return {"ok": False, "error": str(ex)}


@app.get("/api/macro-overlay/status/{symbol}")
async def macro_overlay_status(symbol: str, tf: str = "M5"):
    """Read existing macro overlay JSON and return status."""
    import json as _json
    import math
    json_path = REPO_ROOT / "MQL5" / "MQL5" / "Files" / f"macro_overlay_{symbol}.json"
    txt_path = REPO_ROOT / "MQL5" / "MQL5" / "Files" / f"macro_overlay_{symbol}.txt"
    if not json_path.exists():
        return {"ok": False, "error": "Overlay not generated yet", "has_txt": txt_path.exists()}
    try:
        with open(json_path, "r", encoding="utf-8") as f:
            raw = f.read()
        data = _json.loads(raw, parse_constant=lambda v: None if v == "NaN" else float(v))
        def _sanitize(obj):
            if isinstance(obj, float) and (math.isnan(obj) or math.isinf(obj)):
                return None
            if isinstance(obj, dict):
                return {k: _sanitize(v) for k, v in obj.items()}
            if isinstance(obj, list):
                return [_sanitize(v) for v in obj]
            return obj
        return {"ok": True, "data": _sanitize(data)}
    except Exception as ex:
        return {"ok": False, "error": str(ex)}


@app.get("/api/macro-overlay/json/{symbol}")
async def macro_overlay_json(symbol: str):
    """Serve macro overlay JSON inline."""
    import json as _json
    import math
    json_path = REPO_ROOT / "MQL5" / "MQL5" / "Files" / f"macro_overlay_{symbol}.json"
    if not json_path.exists():
        raise HTTPException(status_code=404, detail=f"Overlay JSON not found for {symbol}")
    with open(json_path, "r", encoding="utf-8") as f:
        raw = f.read()
    data = _json.loads(raw, parse_constant=lambda v: None if v == "NaN" else float(v))
    def _sanitize(obj):
        if isinstance(obj, float) and (math.isnan(obj) or math.isinf(obj)):
            return None
        if isinstance(obj, dict):
            return {k: _sanitize(v) for k, v in obj.items()}
        if isinstance(obj, list):
            return [_sanitize(v) for v in obj]
        return obj
    return _sanitize(data)


@app.delete("/api/macro-overlay/delete/{symbol}")
async def macro_overlay_delete(symbol: str):
    """Delete macro overlay files (TXT + JSON)."""
    txt_path = REPO_ROOT / "MQL5" / "MQL5" / "Files" / f"macro_overlay_{symbol}.txt"
    json_path = REPO_ROOT / "MQL5" / "MQL5" / "Files" / f"macro_overlay_{symbol}.json"
    deleted = []
    for p in [txt_path, json_path]:
        if p.exists():
            p.unlink()
            deleted.append(p.name)
    if not deleted:
        raise HTTPException(status_code=404, detail=f"No overlay files found for {symbol}")
    _push_log("INFO", f"MacroOverlay: deletado {', '.join(deleted)}")
    return {"ok": True, "deleted": deleted}


@app.post("/api/settings/overlay")
async def save_overlay_settings(data: dict = Body(...)):
    """Save overlay auto-run setting to data/overlay_settings.json."""
    settings_path = REPO_ROOT / "data" / "overlay_settings.json"
    import json as _json
    current = {}
    if settings_path.exists():
        try:
            current = _json.loads(settings_path.read_text(encoding="utf-8"))
        except Exception:
            pass
    current.update(data)
    settings_path.write_text(_json.dumps(current, indent=2, ensure_ascii=False), encoding="utf-8")
    _push_log("INFO", f"Overlay settings saved: {current}")
    return {"ok": True, "settings": current}


@app.get("/api/settings/overlay")
async def get_overlay_settings():
    """Get overlay auto-run setting."""
    settings_path = REPO_ROOT / "data" / "overlay_settings.json"
    import json as _json
    if not settings_path.exists():
        return {"auto_run": True}
    try:
        return _json.loads(settings_path.read_text(encoding="utf-8"))
    except Exception:
        return {"auto_run": True}


# DataMiner CSVs are written by the EA to data/ (effective InpDataMinerPath),
# but older samples may also live in data/mql5/. Scan both and prefer the newest.
MINER_DIRS = [REPO_ROOT / "data", REPO_ROOT / "data" / "mql5"]


def _iter_newest_miner(glob_pattern):
    seen = {}
    for d in MINER_DIRS:
        if not d.exists():
            continue
        for f in d.glob(glob_pattern):
            prev = seen.get(f.name)
            if prev is None or f.stat().st_mtime > prev.stat().st_mtime:
                seen[f.name] = f
    return list(seen.values())


def _resolve_in_miner_dirs(name):
    best = None
    for d in MINER_DIRS:
        p = d / name
        if p.exists() and (best is None or p.stat().st_mtime > best.stat().st_mtime):
            best = p
    return best


def _csv_symbols(f):
    """Return the set of symbols found in a miner CSV (skips a leading #SCHEMA_VERSION line)."""
    syms = set()
    try:
        with open(f, "r", encoding="utf-8", errors="replace") as fh:
            first = fh.readline()
            if first.lstrip().startswith("#"):
                first = fh.readline()
            header = first.split(";")
            try:
                idx = [c.strip().upper() for c in header].index("SYMBOL")
            except ValueError:
                return syms
            for line in fh:
                fields = line.split(";")
                if len(fields) > idx:
                    s = fields[idx].strip().upper()
                    if s:
                        syms.add(s)
    except Exception:
        pass
    return syms


def _resolve_miner_csv_for_symbol(symbol):
    """Pick the newest miner CSV matching `symbol` across MINER_DIRS (filename first, then Symbol column)."""
    sym = symbol.upper()
    candidates = []
    for d in MINER_DIRS:
        if d.exists():
            candidates.extend(d.glob("*miner*.csv"))
    if not candidates:
        return None
    matches = [f for f in candidates if sym in f.stem.upper()]
    if not matches:
        for f in candidates:
            if sym in _csv_symbols(f):
                matches.append(f)
    if not matches:
        return None
    matches.sort(key=lambda x: x.stat().st_mtime, reverse=True)
    return matches[0]


@app.get("/api/dataminer/list")
async def dataminer_list():
    """List available miner CSV files and generated PDF reports (data/ and data/mql5/)."""
    files = []
    pdfs = []
    for f in _iter_newest_miner("*miner*.csv"):
        stat = f.stat()
        files.append({
            "name": f.name,
            "size_kb": round(stat.st_size / 1024, 1),
            "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
        })
    for f in _iter_newest_miner("miner_report_*.pdf"):
        stat = f.stat()
        base = f.stem.replace("miner_report_", "")
        symbol = base
        generated_at = None
        sidecar = f.with_suffix(".json")
        if sidecar.exists():
            try:
                with open(sidecar, "r", encoding="utf-8") as _sf:
                    _meta = _json_module().load(_sf)
                symbol = _meta.get("symbol", base)
                generated_at = _meta.get("generated_at")
            except Exception:
                pass
        pdfs.append({
            "name": f.name,
            "symbol": symbol,
            "size_kb": round(stat.st_size / 1024, 1),
            "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
            "generated_at": generated_at,
        })
    files.sort(key=lambda x: x["modified"], reverse=True)
    pdfs.sort(key=lambda x: x["modified"], reverse=True)
    return {"files": files, "pdfs": pdfs}


@app.get("/api/dataminer/pdf/{name}")
async def dataminer_pdf(name: str):
    """Serve a generated DataMiner PDF report inline (for modal viewer)."""
    if ".." in name or "/" in name or "\\" in name or not name.startswith("miner_report_"):
        return {"ok": False, "error": "Invalid name"}
    pdf_path = _resolve_in_miner_dirs(name)
    if pdf_path is None or pdf_path.suffix.lower() != ".pdf":
        return {"ok": False, "error": f"PDF not found: {name}"}
    try:
        return FileResponse(str(pdf_path), media_type="application/pdf")
    except Exception as ex:
        return {"ok": False, "error": str(ex)}


@app.delete("/api/dataminer/delete/{name}")
async def dataminer_delete(name: str):
    """Delete a generated DataMiner PDF report (and its sidecar JSON)."""
    if ".." in name or "/" in name or "\\" in name or not name.startswith("miner_report_"):
        return {"ok": False, "error": "Invalid name"}
    pdf_path = _resolve_in_miner_dirs(name)
    if pdf_path is None:
        return {"ok": False, "error": f"PDF not found: {name}"}
    try:
        pdf_path.unlink()
        sidecar = pdf_path.with_suffix(".json")
        if sidecar.exists():
            sidecar.unlink()
        return {"ok": True}
    except Exception as ex:
        return {"ok": False, "error": str(ex)}


@app.get("/api/calibration/run")
async def calibration_run(symbol: str = "XAUUSD", tf: str = "M5"):
    """Run the EA calibration agent for a specific symbol/timeframe."""
    import sys
    sys.path.insert(0, str(PROJECT_ROOT))
    from Modulos.calibration.dataminer_aggregator import aggregate
    from Modulos.calibration.asset_dna_loader import load_asset_dna
    from Modulos.calibration.mqh_parser import parse_mqh
    from Modulos.calibration.strategy_context import (
        get_strategy_context, format_parameter_table,
        format_asset_dna_summary, format_dataminer_summary,
    )
    from Modulos.calibration.calibration_agent import run_calibration


    # Find CSV for this symbol across MINER_DIRS (prefer the newest matching file)
    csv_path = _resolve_miner_csv_for_symbol(symbol)

    if not csv_path:
        return {"ok": False, "error": f"No DataMiner CSV found for {symbol} in {MINER_DIRS}"}

    # Find Asset DNA JSON (optional — calibration can run without it)
    data_dir = REPO_ROOT / "data" / "mql5"
    json_path = data_dir / f"asset_profile_{symbol}_{tf}.json"
    has_dna = json_path.exists()

    # Find MQH file
    mqh_path = REPO_ROOT / "MQL5" / "MQL5" / "Include" / "ALXQuantCore" / "Modules" / "MacroRegimeEngine.mqh"
    if not mqh_path.exists():
        return {"ok": False, "error": f"MacroRegimeEngine.mqh not found: {mqh_path}"}

    try:
        _push_log("INFO", f"Calibration: starting for {symbol} {tf}")

        # Step 1: Aggregate DataMiner
        dataminer_summary = aggregate(csv_path, symbol=symbol, min_sample=30)

        # Step 2: Load Asset DNA (optional)
        asset_dna = None
        if has_dna:
            asset_dna = load_asset_dna(json_path, symbol=symbol, timeframe=tf)

        # Step 3: Parse MQH
        params = parse_mqh(mqh_path)

        # Step 4: Build context
        param_table = format_parameter_table(params)
        dna_summary = format_asset_dna_summary(asset_dna) if asset_dna else "(Asset DNA not available for this symbol)"
        dm_summary = format_dataminer_summary(dataminer_summary)

        strategy_context = get_strategy_context(
            parameter_table=param_table,
            asset_dna_summary=dna_summary,
            dataminer_summary=dm_summary,
        )

        # Step 5: Run LLM (non-blocking via asyncio.to_thread)
        import asyncio
        _push_log("INFO", f"Calibration: calling LLM for {symbol}...")
        output = await asyncio.to_thread(run_calibration, strategy_context=strategy_context, symbol=symbol, timeframe=tf, min_sample=30)

        # Save JSON
        out_json = data_dir / f"calibration_{symbol}_{tf}.json"
        import json as _json
        with open(out_json, "w", encoding="utf-8") as f:
            _json.dump(output.model_dump(), f, indent=2, ensure_ascii=False, default=str)

        _push_log("INFO", f"Calibration: {len(output.suggestions)} suggestions for {symbol}")
        return {"ok": True, "data": output.model_dump()}

    except Exception as ex:
        _push_log("ERROR", f"Calibration: {ex}")
        return {"ok": False, "error": str(ex)}


@app.get("/api/calibration/symbols")
async def calibration_symbols():
    """List all symbols available for calibration (union of CSV + JSON)."""
    import csv as _csv

    # Symbols from CSVs (scan both data/ and data/mql5/, skip leading # comment line)
    csv_symbols = set()
    for d in MINER_DIRS:
        if not d.exists():
            continue
        for f in d.glob("*miner*.csv"):
            csv_symbols.update(_csv_symbols(f))

    # Symbols from Asset DNA JSONs
    json_symbols = set()
    for f in data_dir.glob("asset_profile_*.json"):
        parts = f.stem.replace("asset_profile_", "").rsplit("_", 1)
        if parts:
            json_symbols.add(parts[0].upper())

    return {
        "csv_symbols": sorted(csv_symbols),
        "json_symbols": sorted(json_symbols),
        "all_symbols": sorted(csv_symbols | json_symbols),
    }


def _sanitize_calibration(obj):
    """Recursively convert NaN/Inf to None for JSON-safe serialization."""
    import math
    if isinstance(obj, dict):
        return {k: _sanitize_calibration(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_sanitize_calibration(v) for v in obj]
    if isinstance(obj, float) and (math.isnan(obj) or math.isinf(obj)):
        return None
    return obj


@app.get("/api/calibration/list")
async def calibration_list():
    """List saved calibration reports (one per symbol+tf)."""
    data_dir = REPO_ROOT / "data" / "mql5"
    files = []
    if data_dir.exists():
        for f in sorted(data_dir.glob("calibration_*.json")):
            stat = f.stat()
            parts = f.stem.replace("calibration_", "").rsplit("_", 1)
            symbol = parts[0].upper() if parts else f.stem
            tf = parts[1].upper() if len(parts) > 1 else "M5"
            generated_at = None
            try:
                with open(f, "r", encoding="utf-8") as fh:
                    raw = _sanitize_calibration(_json_module().load(fh))
                generated_at = (raw.get("meta") or {}).get("generated_at")
            except Exception:
                pass
            files.append({
                "name": f.name,
                "symbol": symbol,
                "tf": tf,
                "size_kb": round(stat.st_size / 1024, 1),
                "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
                "generated_at": generated_at,
            })
    return {"files": files}


@app.get("/api/calibration/json/{symbol}")
async def calibration_json(symbol: str, tf: str = "M5"):
    """Return a saved calibration report inline (JSON-safe)."""
    data_dir = REPO_ROOT / "data" / "mql5"
    json_path = data_dir / f"calibration_{symbol}_{tf}.json"
    if not json_path.exists():
        return {"ok": False, "error": f"Calibration report not found: {json_path}"}
    try:
        with open(json_path, "r", encoding="utf-8") as fh:
            raw = _sanitize_calibration(_json_module().load(fh))
        return {"ok": True, "data": raw}
    except Exception as ex:
        return {"ok": False, "error": str(ex)}


@app.delete("/api/calibration/delete/{symbol}")
async def calibration_delete(symbol: str, tf: str = "M5"):
    """Delete a saved calibration report."""
    data_dir = REPO_ROOT / "data" / "mql5"
    json_path = data_dir / f"calibration_{symbol}_{tf}.json"
    if not json_path.exists():
        return {"ok": False, "error": f"Calibration report not found: {json_path}"}
    try:
        json_path.unlink()
        return {"ok": True}
    except Exception as ex:
        return {"ok": False, "error": str(ex)}


# ─── NLP Sentiment (external AI news module) ───
NLP_DB_PATH = REPO_ROOT / "data" / "nlp_sentiment.duckdb"

_nlp_db_manager = None


def _get_nlp_db():
    """Lazily create a single read/write DuckDB manager for the NLP module."""
    global _nlp_db_manager
    if _nlp_db_manager is None:
        from Modulos.nlp_sentiment.nlp_sentiment import DuckDBManager
        _nlp_db_manager = DuckDBManager(str(NLP_DB_PATH))
    return _nlp_db_manager


@app.get("/api/nlp/signals")
async def nlp_signals(window_days: int = 7):
    """Latest sentiment signal per watched asset."""
    try:
        import math
        db = _get_nlp_db()
        wl = db.load_watchlist()
        signals = []
        for _, row in wl.iterrows():
            asset = str(row.get("symbol", "")).upper()
            if not asset:
                continue
            hist = db.get_historical_scores(asset, days=max(1, int(window_days)))
            if hist.empty:
                signals.append({
                    "asset": asset,
                    "raw_score": None,
                    "decayed_score": None,
                    "z_score": None,
                    "news_count": 0,
                    "confidence": 0.0,
                    "timestamp": None,
                    "direction": "neutral",
                })
                continue
            latest = hist.iloc[0]
            decayed = float(latest.get("decayed_score") or 0.0)
            z = latest.get("z_score")
            z = None if z is None or (isinstance(z, float) and math.isnan(z)) else float(z)
            signals.append({
                "asset": asset,
                "raw_score": float(latest.get("raw_score") or 0.0),
                "decayed_score": decayed,
                "z_score": z,
                "news_count": int(latest.get("news_count") or 0),
                "confidence": float(latest.get("confidence") or 0.0),
                "timestamp": str(latest.get("timestamp")) if latest.get("timestamp") is not None else None,
                "direction": "bullish" if decayed > 0.02 else "bearish" if decayed < -0.02 else "neutral",
            })
        return {"ok": True, "signals": signals}
    except Exception as ex:
        return {"ok": False, "error": str(ex)}


@app.get("/api/nlp/history")
async def nlp_history(asset: str, days: int = 7):
    """Time series for the sparkline of one asset."""
    try:
        import math
        db = _get_nlp_db()
        hist = db.get_historical_scores(asset.upper(), days=max(1, int(days)))
        series = []
        for _, row in hist.iterrows():
            ts = row.get("timestamp")
            z = row.get("z_score")
            z = None if z is None or (isinstance(z, float) and math.isnan(z)) else float(z)
            series.append({
                "t": str(ts) if ts is not None else None,
                "decayed_score": float(row.get("decayed_score") or 0.0),
                "z_score": z,
            })
        return {"ok": True, "asset": asset.upper(), "series": series}
    except Exception as ex:
        return {"ok": False, "error": str(ex)}


@app.get("/api/nlp/news")
async def nlp_news(limit: int = 50):
    """Recent classified news with parsed impacts."""
    try:
        import json as _json
        db = _get_nlp_db()
        rows = db.conn.execute(
            """
            SELECT news_id, source, title, url, published_at, impacts, classifier_used
            FROM nlp_classified_news
            ORDER BY published_at DESC
            LIMIT ?
            """,
            [int(limit)],
        ).fetchall()
        cols = [d[0] for d in db.conn.description]
        out = []
        for r in rows:
            rec = dict(zip(cols, r))
            impacts_raw = rec.get("impacts")
            try:
                impacts = _json.loads(impacts_raw) if impacts_raw else []
            except Exception:
                impacts = []
            out.append({
                "news_id": rec.get("news_id"),
                "source": rec.get("source"),
                "title": rec.get("title"),
                "url": rec.get("url"),
                "published_at": str(rec.get("published_at")) if rec.get("published_at") is not None else None,
                "classifier_used": rec.get("classifier_used"),
                "impacts": impacts,
            })
        return {"ok": True, "news": out}
    except Exception as ex:
        return {"ok": False, "error": str(ex)}


@app.get("/api/nlp/watchlist")
async def nlp_watchlist():
    """Symbols currently tracked by the NLP engine."""
    try:
        db = _get_nlp_db()
        wl = db.load_watchlist()
        items = [{"symbol": str(r.get("symbol", "")).upper(), "keywords": r.get("keywords")} for _, r in wl.iterrows() if r.get("symbol")]
        return {"ok": True, "watchlist": items}
    except Exception as ex:
        return {"ok": False, "error": str(ex)}


@app.get("/api/nlp/run")
async def nlp_run():
    """Run a full NLP sentiment cycle (collect -> classify -> score -> normalize)."""
    try:
        import math
        from Modulos.nlp_sentiment.nlp_sentiment import NLPSentimentEngine
        _push_log("INFO", "NLP: starting sentiment cycle...")
        engine = NLPSentimentEngine(str(NLP_DB_PATH))
        signals = await asyncio.to_thread(engine.run_cycle_sync)
        _push_log("INFO", f"NLP: cycle done - {len(signals)} asset(s) scored")
        out = []
        for asset, sig in signals.items():
            raw = float(getattr(sig, "raw_score", 0.0) or 0.0)
            decayed = float(getattr(sig, "decayed_score", 0.0) or 0.0)
            z = float(getattr(sig, "z_score", 0.0) or 0.0)
            conf = float(getattr(sig, "confidence", 0.0) or 0.0)
            # Sanitize NaN/Inf to 0.0 for JSON
            raw = 0.0 if (math.isnan(raw) or math.isinf(raw)) else raw
            decayed = 0.0 if (math.isnan(decayed) or math.isinf(decayed)) else decayed
            z = 0.0 if (math.isnan(z) or math.isinf(z)) else z
            conf = 0.0 if (math.isnan(conf) or math.isinf(conf)) else conf
            out.append({
                "asset": asset,
                "raw_score": raw,
                "decayed_score": decayed,
                "z_score": z,
                "news_count": int(getattr(sig, "news_count", 0) or 0),
                "confidence": conf,
                "timestamp": str(getattr(sig, "timestamp", "")),
                "direction": "bullish" if decayed > 0.02 else "bearish" if decayed < -0.02 else "neutral",
            })
        if not out:
            return {"ok": True, "signals": [], "warning": "Nenhuma noticia coletada - verifique rede/API keys (GEMINI/FINNHUB/ALPHAVANTAGE)"}
        return {"ok": True, "signals": out}
    except Exception as ex:
        _push_log("ERROR", f"NLP: {ex}")
        return {"ok": False, "error": str(ex)}


@app.get("/api/nlp/macro")
async def nlp_macro():
    """Latest macro sentiment per economy (USD/EUR/JPY/CNY)."""
    try:
        from Modulos.nlp_sentiment.nlp_sentiment import load_macro_economies
        db = _get_nlp_db()
        entities = [str(e.get("entity", "")).upper() for e in load_macro_economies() if e.get("entity")]
        scores = db.get_macro_scores(entities, days=30)
        return {"ok": True, "entities": entities, "scores": scores}
    except Exception as ex:
        _push_log("ERROR", f"NLP macro: {ex}")
        return {"ok": False, "error": str(ex)}


@app.get("/api/nlp/macro/history")
async def nlp_macro_history(entity: str = "", days: int = 30):
    """Historical macro sentiment for one economy entity."""
    try:
        db = _get_nlp_db()
        df = db.get_historical_scores(entity.upper(), days)
        history = [
            {
                "timestamp": str(row.get("timestamp", "")),
                "decayed_score": float(row.get("decayed_score", 0.0) or 0.0),
                "news_count": int(row.get("news_count", 0) or 0),
            }
            for _, row in df.iterrows()
        ]
        return {"ok": True, "entity": entity.upper(), "history": history}
    except Exception as ex:
        _push_log("ERROR", f"NLP macro history: {ex}")
        return {"ok": False, "error": str(ex)}


@app.get("/api/nlp/pipeline-runs")
async def nlp_pipeline_runs(limit: int = 20):
    """Recent NLP pipeline run metrics (observability): volume, classifiers, degradation."""
    try:
        db = _get_nlp_db()
        cols = ["timestamp", "duration_ms", "collected_total", "classified_total",
                "per_source", "per_classifier", "macro_total", "degraded"]
        rows = db.conn.execute(
            f"SELECT {', '.join(cols)} FROM nlp_pipeline_runs ORDER BY timestamp DESC LIMIT ?",
            [limit],
        ).fetchall()
        runs = [dict(zip(cols, r)) for r in rows]
        return {"ok": True, "runs": runs}
    except Exception as ex:
        _push_log("ERROR", f"NLP pipeline runs: {ex}")
        return {"ok": False, "error": str(ex)}


def _json_module():
    import json as _j
    return _j


@app.get("/api/dataminer/run")
async def dataminer_run(filename: str):
    """Run alpha_miner analysis on a CSV file and return summary results."""
    if ".." in filename or "/" in filename or "\\" in filename:
        return {"ok": False, "error": "Invalid filename"}
    csv_path = _resolve_in_miner_dirs(filename)
    if csv_path is None or csv_path.suffix.lower() != ".csv":
        return {"ok": False, "error": f"File not found: {filename}"}
    try:
        from Modulos.alpha_miner.alpha_miner import QuantAnalyzer
        import numpy as _np
        import pandas as _pd

        # Read CSV using its own header (EA files start with a #SCHEMA_VERSION comment line)
        df = _pd.read_csv(csv_path, sep=';', encoding='utf-8-sig', comment='#')

        # Convert numeric columns (skip time/string columns)
        skip_cols = {'EntryTime', 'ExitTime', 'Symbol', 'Direction', 'TradeOutcome',
                     'ExitReason', 'RegimeName', 'MacroProfile', 'SessionName',
                     'RegimeAtExit'}
        for col in df.columns:
            if col not in skip_cols:
                df[col] = _pd.to_numeric(df[col], errors='coerce')

        # Convert time columns
        for col in ('EntryTime', 'ExitTime'):
            if col in df.columns:
                df[col] = _pd.to_datetime(df[col], errors='coerce')

        # Filter empty TradeOutcome
        if 'TradeOutcome' in df.columns:
            df = df[df['TradeOutcome'].str.strip() != ''].reset_index(drop=True)

        # Ensure Target_Win exists
        if 'Target_Win' not in df.columns and 'TradeOutcome' in df.columns:
            df['Target_Win'] = (df['TradeOutcome'] == 'WIN').astype(int)

        if len(df) == 0:
            return {"ok": False, "error": "No valid trades after cleaning"}

        a = QuantAnalyzer(df)
        basic = a.results.get("basic", {})
        tail = a.results.get("tail_risk", {})
        boot = a.results.get("bootstrap", {})
        boot_clean = {k: v for k, v in boot.items() if k != "boot_means"}

        pdf_name = None
        try:
            from Modulos.alpha_miner.alpha_miner import run_analysis
            import json as _json
            pdf_name = f"miner_report_{csv_path.stem}.pdf"
            pdf_path = csv_path.parent / pdf_name
            run_analysis(output_path=str(pdf_path), analyzer=a)
            sidecar = csv_path.parent / f"miner_report_{csv_path.stem}.json"
            sidecar_meta = {
                "symbol": (df["Symbol"].iloc[0] if "Symbol" in df.columns and len(df) else getattr(a, "symbol", "N/A")),
                "csv": filename,
                "generated_at": datetime.now().isoformat(),
            }
            with open(sidecar, "w", encoding="utf-8") as _sf:
                _json.dump(sidecar_meta, _sf, indent=2)
            _push_log("INFO", f"DataMiner: PDF report saved {pdf_path}")
        except Exception as pdf_ex:
            _push_log("WARNING", f"DataMiner: PDF generation failed: {pdf_ex}")
            pdf_name = None

        return {
            "ok": True,
            "data": {
                "basic": basic,
                "tail_risk": tail,
                "bootstrap": boot_clean,
                "pdf": pdf_name,
            },
        }
    except Exception as ex:
        _push_log("ERROR", f"DataMiner: {ex}")
        return {"ok": False, "error": str(ex)}


API_KEY_NAMES = [
    "GEMINI_API_KEY",
    "FINNHUB_API_KEY",
    "ALPHAVANTAGE_API_KEY",
    "GROQ_API_KEY",
    "NVIDIA_API_KEY",
    "OPENAI_API_KEY",
    "OPENROUTER_API_KEY",
    "DASHSCOPE_API_KEY",
    "FRED_API_KEY",
    "NASDAQ_DATA_LINK_API_KEY",
    "QUANDL_API_KEY",
    "LLM_API_KEY",
    "LLM_BASE_URL",
    "LLM_MODEL",
]


@app.get("/api/settings")
async def get_settings():
    """Environment configuration (sanitized) with MT5 credentials."""
    from Modulos.datahouse.engine import get_db_status
    from config import config as cfg

    status = get_db_status()
    env_path = REPO_ROOT / ".env"
    mt5_path = os.getenv("MT5_PATH", "").replace("\\", "/")
    mt5_account = os.getenv("MT5_ACCOUNT", "0")
    mt5_server = os.getenv("MT5_SERVER", "")
    mt5_password_set = bool(os.getenv("MT5_PASSWORD", ""))

    return {
        "DB_PATH": str(config.DB_PATH),
        "DB_DOMAINS": str(len(status.get("domains", []))),
        "DB_LAST_CHECK": status.get("summary", {}).get("last_check", "--"),
        "PYTHON_VERSION": sys.version.split()[0],
        "API_VERSION": "5.27.0",
        "MT5_PATH": mt5_path,
        "MT5_ACCOUNT": mt5_account,
        "MT5_SERVER": mt5_server,
        "MT5_PASSWORD_SET": mt5_password_set,
        "ENV_PATH": str(env_path),
        "KEYS": {name: bool(os.getenv(name, "")) for name in API_KEY_NAMES},
    }


@app.post("/api/settings/mt5")
async def save_mt5_settings(data: dict = Body(...)):
    """Update MT5 credentials in .env."""
    try:
        env_path = REPO_ROOT / ".env"
        if not env_path.exists():
            return JSONResponse({"status": "error", "message": ".env file not found"}, status_code=404)

        keys_to_update = ["MT5_PATH", "MT5_ACCOUNT", "MT5_PASSWORD", "MT5_SERVER"]

        lines = env_path.read_text(encoding="utf-8").splitlines(keepends=True)
        updated_keys = set()

        for i, line in enumerate(lines):
            stripped = line.strip()
            for key in keys_to_update:
                if key in data and stripped.startswith(key + "="):
                    val = str(data[key])
                    if key == "MT5_PATH":
                        val = val.replace("\\", "/")
                    new_line = f'{key}="{val}"\n'
                    lines[i] = new_line
                    updated_keys.add(key)
                    break

        for key in keys_to_update:
            if key in data and key not in updated_keys:
                val = str(data[key])
                if key == "MT5_PATH":
                    val = val.replace("\\", "/")
                lines.append(f'{key}="{val}"\n')

        env_path.write_text("".join(lines), encoding="utf-8")
        os.environ.update({k: str(data[k]) for k in keys_to_update if k in data})
        return {"status": "saved", "message": "MT5 credentials updated. Restart terminal for changes to take effect."}
    except Exception as e:
        return JSONResponse({"status": "error", "message": f"Save failed: {e}"}, status_code=500)


@app.post("/api/settings/keys")
async def save_api_keys(data: dict = Body(...)):
    """Update API keys (LLM / news) in .env. Only changed keys are sent."""
    try:
        env_path = REPO_ROOT / ".env"
        if not env_path.exists():
            return JSONResponse({"status": "error", "message": ".env file not found"}, status_code=404)

        keys_to_update = [k for k in API_KEY_NAMES if k in data and data[k] not in (None, "", "********")]

        lines = env_path.read_text(encoding="utf-8").splitlines(keepends=True)
        updated_keys = set()

        for i, line in enumerate(lines):
            stripped = line.strip()
            for key in keys_to_update:
                if stripped.startswith(key + "=") or stripped.startswith(key + " ="):
                    val = str(data[key]).replace("\\", "/")
                    lines[i] = f'{key}="{val}"\n'
                    updated_keys.add(key)
                    break

        for key in keys_to_update:
            if key not in updated_keys:
                val = str(data[key]).replace("\\", "/")
                lines.append(f'{key}="{val}"\n')

        env_path.write_text("".join(lines), encoding="utf-8")
        os.environ.update({k: str(data[k]) for k in keys_to_update})
        return {"status": "saved", "message": f"{len(keys_to_update)} API key(s) updated. Restart server for changes to take effect."}
    except Exception as e:
        return JSONResponse({"status": "error", "message": f"Save failed: {e}"}, status_code=500)


@app.post("/api/settings/mt5/test")
async def test_mt5_connection(data: dict = Body(default=None)):
    """Test MT5 connection (passes all params to initialize)."""
    import MetaTrader5 as mt5

    mt5_path = ((data or {}).get("MT5_PATH") or os.getenv("MT5_PATH", "")).replace("\\", "/")
    mt5_account = int((data or {}).get("MT5_ACCOUNT") or os.getenv("MT5_ACCOUNT", "0"))
    mt5_password = (data or {}).get("MT5_PASSWORD") or os.getenv("MT5_PASSWORD", "")
    mt5_server = (data or {}).get("MT5_SERVER") or os.getenv("MT5_SERVER", "")
    if mt5_password == "********":
        mt5_password = os.getenv("MT5_PASSWORD", "")

    if not mt5_account:
        return {"status": "error", "message": "MT5_ACCOUNT not configured"}

    mt5.shutdown()
    ok = mt5.initialize(login=mt5_account, password=mt5_password, server=mt5_server)
    if not ok and mt5_path:
        ok = mt5.initialize(path=mt5_path, login=mt5_account, password=mt5_password, server=mt5_server)
    if not ok:
        err = mt5.last_error()
        return {"status": "error", "message": f"Connection failed: {err}"}

    info = mt5.account_info()
    mt5.shutdown()

    if not info:
        return {"status": "error", "message": "Connected but failed to get account info"}

    return {
        "status": "ok",
        "message": f"Connected to {info.server} as {info.name} (login: {info.login})",
        "account": info.login,
        "server": info.server,
        "name": info.name,
        "balance": info.balance,
        "equity": info.equity,
        "currency": info.currency,
    }


# â”€â”€ Auto-repair background thread â”€â”€
# Checks data freshness every 5 minutes, monitors Windows tasks every 30 min,
# and auto-triggers repair / re-register as needed.

# --- News (ForexFactory Calendar) ---

NEWS_FETCH_RUNNING = False
_NEWS_FETCH_LOCK = _threading.Lock()


@app.get("/api/news")
async def get_news(
    currency: str = "",
    impact: str = "",
    days: int = 7,
    search: str = "",
    limit: int = 200,
):
    """Lista eventos do calendario ForexFactory com filtros."""
    try:
        from Modulos.news.calendar_store import get_events
        impacts_list = None
        if impact:
            impacts_list = [i.strip() for i in impact.split(",") if i.strip()]
        events = get_events(
            currency=currency or None,
            impacts=impacts_list,
            days=days if days > 0 else None,
            search=search or None,
            limit=min(limit, 500),
        )
        from datetime import datetime as _dt
        for ev in events:
            ts = ev.get("event_time")
            if ts:
                try:
                    ev["date_str"] = _dt.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")
                except Exception:
                    ev["date_str"] = str(ts)
            else:
                ev["date_str"] = ""
        return {"ok": True, "events": events, "count": len(events)}
    except Exception as exc:
        _push_log("ERROR", f"/api/news error: {exc}")
        return {"ok": False, "events": [], "count": 0, "error": str(exc)}


@app.get("/api/news/run")
async def run_news_fetch():
    """Dispara a coleta do ForexFactory em thread de fundo."""
    global NEWS_FETCH_RUNNING
    with _NEWS_FETCH_LOCK:
        if NEWS_FETCH_RUNNING:
            return {"ok": False, "status": "running"}
        NEWS_FETCH_RUNNING = True

    def _worker():
        global NEWS_FETCH_RUNNING
        try:
            from Modulos.news.ff_calendar import fetch_thisweek
            from Modulos.news.calendar_store import upsert_events
            from datetime import datetime as _dt, timezone as _tz
            _push_log("INFO", "News: fetching ForexFactory calendar...")
            rows = fetch_thisweek()
            if rows:
                # Log verification summary
                min_ts = min(r["event_time"] for r in rows)
                max_ts = max(r["event_time"] for r in rows)
                min_dt = _dt.fromtimestamp(min_ts, tz=_tz.utc)
                max_dt = _dt.fromtimestamp(max_ts, tz=_tz.utc)
                _push_log("INFO", f"News: {len(rows)} events, "
                          f"range {min_dt.strftime('%Y-%m-%d %H:%M')} to "
                          f"{max_dt.strftime('%Y-%m-%d %H:%M')} UTC")
                # High-impact count
                high_count = sum(1 for r in rows if r["impact"] == "HIGH")
                _push_log("INFO", f"News: {high_count} high-impact events")
                # Upsert with FF priority
                result = upsert_events(rows)
                _push_log("INFO", f"News: inserted={result['inserted']}, "
                          f"updated={result['updated']}, unchanged={result['unchanged']}")
            else:
                _push_log("WARNING", "News: no events fetched")
        except Exception as exc:
            _push_log("ERROR", f"News fetch failed: {exc}")
        finally:
            with _NEWS_FETCH_LOCK:
                NEWS_FETCH_RUNNING = False

    t = _threading.Thread(target=_worker, daemon=True)
    t.start()
    return {"ok": True, "status": "started"}


@app.get("/api/news/stats")
async def get_news_stats():
    """Estatisticas do calendario (por impacto, moeda, total)."""
    try:
        from Modulos.news.calendar_store import get_news_stats as _get_stats
        return {"ok": True, **_get_stats()}
    except Exception as exc:
        _push_log("ERROR", f"/api/news/stats error: {exc}")
        return {"ok": False, "error": str(exc)}




_collect_all_running = False


def _run_collect_all_internal():
    """Rede de seguranca: roda o orquestrador de coleta dentro do proprio servidor
    quando a task Windows (ALX-DataHouse-CollectAll) ainda nao foi registrada como
    admin. Apos o registro, a task SYSTEM assume a atualizacao de forma independente
    do servidor GUI."""
    global _collect_all_running
    if _collect_all_running:
        return
    try:
        _collect_all_running = True
        _push_log("INFO", "CollectAll interno: atualizando OHLC+MACRO+RISK...")
        from Modulos.datahouse.collect_all import run as _collect_all_run
        rep = _collect_all_run(log_callback=lambda m: _push_log("COLLECT", m))
        _push_log("INFO", f"CollectAll interno: ok={rep.get('ok')} "
                          f"(erros={len(rep.get('errors', []))})")
    except Exception as e:
        _push_log("ERROR", f"CollectAll interno falhou: {e}")
    finally:
        _collect_all_running = False


def _auto_repair_loop():
    import time as _time
    from Modulos.datahouse.validator import get_repair_status
    from Modulos.datahouse.readiness import readiness_report

    cycle = 0
    _last_collect_ts = 0.0
    _COLLECT_MIN_INTERVAL = 1800.0  # 30 min: intervalo minimo entre coletas (antes era 5 min, com execucao dupla)

    while True:
        try:
            _time.sleep(300)  # 5 minutes
            cycle += 1

            # Step 1: Check data freshness
            _push_log("INFO", "Auto-repair: checking data freshness...")
            if _collect_all_running or get_repair_status().get("running"):
                _push_log("INFO", "Auto-repair: collection already running, skipping")
                continue

            rep = readiness_report()
            critical_count = rep.get("critical_count", 0)
            stale_count = rep.get("assets", {}).get("stale", 0)

            if critical_count == 0:
                _push_log(
                    "INFO",
                    f"Auto-repair: critical=0 (stale={stale_count}, lag natural) — no action needed",
                )
            else:
                now = _time.time()
                if now - _last_collect_ts < _COLLECT_MIN_INTERVAL:
                    _push_log(
                        "INFO",
                        f"Auto-repair: critical={critical_count} mas coleta recente — aguardando (throttle 30min)",
                    )
                else:
                    _push_log(
                        "INFO",
                        f"Auto-repair: critical={critical_count} — coletando (OHLC+MACRO+RISK)",
                    )
                    _last_collect_ts = now
                    _run_collect_all_internal()

            # Step 2: Monitor da task de colecao (a cada 6 ciclos ≈ 30 min)
            if cycle % 6 == 0:
                try:
                    from Modulos.datahouse.scheduler import task_exists
                    if task_exists("ALX-DataHouse-CollectAll"):
                        _push_log("INFO",
                                  "Auto-repair: task ALX-DataHouse-CollectAll presente "
                                  "(atualizacao independente do servidor)")
                    else:
                        _push_log(
                            "WARNING",
                            "Auto-repair: task ALX-DataHouse-CollectAll AUSENTE — registre "
                            "como ADMINISTRADOR: 'python -m Modulos.datahouse.ensure_tasks "
                            "--register' (prompt elevado). Rede de seguranca: o servidor "
                            "rodara o CollectAll internamente enquanto nao registrado.",
                        )
                        _run_collect_all_internal()
                except Exception as ex:
                    _push_log("ERROR", f"Auto-repair: task check error — {ex}")

        except Exception as ex:
            _push_log("ERROR", f"Auto-repair: cycle error — {ex}")


# ── DANTE Code Auditor Endpoints ──

@app.get("/api/dante/stats")
async def dante_stats():
    try:
        sys.path.insert(0, str(PROJECT_ROOT / "Modulos" / "agents"))
        from dante.core.knowledge import KnowledgeBase
        kb = KnowledgeBase()
        stats = kb.get_stats()
        kb.close()
        return {"ok": True, **stats}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.get("/api/dante/findings")
async def dante_findings(severity: str = None, file_path: str = None):
    try:
        sys.path.insert(0, str(PROJECT_ROOT / "Modulos" / "agents"))
        from dante.core.knowledge import KnowledgeBase
        kb = KnowledgeBase()
        findings = kb.get_findings(file_path=file_path, severity=severity)
        kb.close()
        return {"ok": True, "findings": findings}
    except Exception as e:
        return {"ok": False, "error": str(e), "findings": []}


@app.get("/api/dante/report")
async def dante_report():
    try:
        report_dir = PROJECT_ROOT / "Modulos" / "agents" / "dante" / "reports"
        reports = sorted(report_dir.glob("dante-report-*.md"), reverse=True)
        if not reports:
            return {"ok": True, "content": "Nenhum relatório encontrado. Execute um scan primeiro.", "path": ""}
        latest = reports[0]
        content = latest.read_text(encoding="utf-8")
        return {"ok": True, "content": content, "path": str(latest)}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/api/dante/scan")
async def dante_scan(body: dict = Body(default={})):
    try:
        sys.path.insert(0, str(PROJECT_ROOT / "Modulos" / "agents"))
        from dante.config import DanteConfig
        from dante.core.orchestrator import run_scan
        cfg = DanteConfig()
        cfg.scan.target_dir = REPO_ROOT
        use_llm = body.get("use_llm", False)
        result = run_scan(cfg=cfg, use_llm=use_llm)
        return {"ok": True, **result}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/api/dante/clear")
async def dante_clear():
    try:
        sys.path.insert(0, str(PROJECT_ROOT / "Modulos" / "agents"))
        from dante.core.knowledge import KnowledgeBase
        kb = KnowledgeBase()
        kb.clear_session()
        kb.close()
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}


_DANTE_EXCLUDE_FILE = REPO_ROOT / "data" / "dante_exclude_folders.json"


def _load_dante_exclude() -> dict:
    if _DANTE_EXCLUDE_FILE.exists():
        try:
            return json.loads(_DANTE_EXCLUDE_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"exclude_folders": []}


def _save_dante_exclude(data: dict):
    _DANTE_EXCLUDE_FILE.write_text(
        json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8"
    )


@app.get("/api/dante/exclude-folders")
async def dante_get_exclude_folders():
    return _load_dante_exclude()


@app.post("/api/dante/exclude-folders")
async def dante_add_exclude_folder(body: dict = Body(default={})):
    folder = body.get("folder", "").strip()
    if not folder:
        raise HTTPException(400, "Folder path required")
    data = _load_dante_exclude()
    folders = data.setdefault("exclude_folders", [])
    if folder not in folders:
        folders.append(folder)
        _save_dante_exclude(data)
    return {"ok": True, "exclude_folders": folders}


@app.delete("/api/dante/exclude-folders")
async def dante_remove_exclude_folder(body: dict = Body(default={})):
    folder = body.get("folder", "").strip()
    data = _load_dante_exclude()
    folders = data.get("exclude_folders", [])
    if folder in folders:
        folders.remove(folder)
        _save_dante_exclude(data)
    return {"ok": True, "exclude_folders": folders}


# ── Agent Tasks Endpoints ──

_TASKS_FILE = REPO_ROOT / "data" / "agent_tasks.json"


def _load_tasks() -> dict:
    if _TASKS_FILE.exists():
        return json.loads(_TASKS_FILE.read_text(encoding="utf-8"))
    return {"tasks": []}


def _save_tasks(data: dict):
    _TASKS_FILE.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


@app.get("/api/agent-tasks")
async def get_agent_tasks():
    return _load_tasks()


@app.post("/api/agent-tasks")
async def save_agent_tasks(body: dict = Body(default={})):
    _save_tasks(body)
    return {"ok": True}


@app.post("/api/agent-tasks/toggle")
async def toggle_agent_task(body: dict = Body(default={})):
    task_id = body.get("task_id")
    enabled = body.get("enabled", True)
    data = _load_tasks()
    for t in data["tasks"]:
        if t["id"] == task_id:
            t["enabled"] = enabled
            break
    _save_tasks(data)
    return {"ok": True}


@app.post("/api/agent-tasks/update")
async def update_agent_task(body: dict = Body(default={})):
    task_id = body.get("task_id")
    interval = body.get("interval_minutes")
    run_window = body.get("run_window")
    data = _load_tasks()
    for t in data["tasks"]:
        if t["id"] == task_id:
            if interval is not None:
                t["interval_minutes"] = int(interval)
            if run_window is not None:
                t["run_window"] = run_window if run_window else None
            break
    _save_tasks(data)
    return {"ok": True}


@app.post("/api/agent-tasks/run-now")
async def run_agent_task_now(body: dict = Body(default={})):
    task_id = body.get("task_id")
    data = _load_tasks()
    task = next((t for t in data["tasks"] if t["id"] == task_id), None)
    if not task:
        return {"ok": False, "error": "Task not found"}
    task["last_run"] = datetime.now().isoformat()
    _save_tasks(data)
    if task.get("endpoint"):
        _push_log("AGENT", f"Executando tarefa: {task['name']} ({task['agent']})")
        return {"ok": True, "executed": True, "task": task}
    _push_log("AGENT", f"Tarefa registrada: {task['name']} ({task['agent']}) — sem endpoint de execucao")
    return {"ok": True, "executed": False, "task": task}


# ── Agent Status Endpoints ──

_AGENTS_STATUS_FILE = REPO_ROOT / "data" / "agents_status.json"

_AGENTS_INITIAL = {
    "ATLAS":  {"role": "Supervisor Geral / Orquestrador",   "group": "command"},
    "MARCUS": {"role": "Desk Forex",                        "group": "operators"},
    "VICTOR": {"role": "Desk de Indices",                   "group": "operators"},
    "HELIOS": {"role": "Desk de Commodities",               "group": "operators"},
    "ATHENA": {"role": "Desk de Stocks",                    "group": "operators"},
    "HELENA": {"role": "Chief Risk Officer",                "group": "supervisors"},
    "SOPHIA": {"role": "Data Auditor",                      "group": "supervisors"},
    "DANTE":  {"role": "Code Auditor",                      "group": "supervisors", "default_status": "ONLINE"},
    "ARTHUR": {"role": "Process Auditor",                   "group": "supervisors"},
    "NEXUS":  {"role": "Red Team / QA",                     "group": "operators"},
    "CLARA":  {"role": "Reporting / CFO",                   "group": "output"},
}


def _load_agents_status() -> dict:
    if _AGENTS_STATUS_FILE.exists():
        try:
            return json.loads(_AGENTS_STATUS_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"agents": {k: {"heartbeat": None, "errors_today": 0, "status": "STANDBY"}
                       for k in _AGENTS_INITIAL}}


def _save_agents_status(data: dict):
    _AGENTS_STATUS_FILE.write_text(
        json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8"
    )


@app.get("/api/agents/status")
async def get_agents_status():
    data = _load_agents_status()
    result = {}
    for name, info in _AGENTS_INITIAL.items():
        agent_data = data.get("agents", {}).get(name, {})
        heartbeat = agent_data.get("heartbeat")
        status = agent_data.get("status") or info.get("default_status", "STANDBY")
        errors = agent_data.get("errors_today", 0)
        if heartbeat:
            try:
                hb_time = datetime.fromisoformat(heartbeat)
                diff = (datetime.now() - hb_time).total_seconds()
                if diff > 3600:
                    status = "OFFLINE"
                elif diff > 600:
                    status = "STANDBY"
            except Exception:
                pass
        result[name] = {
            "role": info["role"],
            "group": info["group"],
            "heartbeat": heartbeat,
            "errors_today": errors,
            "status": status,
        }
    return {"agents": result}


@app.post("/api/agents/heartbeat")
async def update_agent_heartbeat(body: dict = Body(default={})):
    name = body.get("agent", "").upper()
    if name not in _AGENTS_INITIAL:
        raise HTTPException(400, f"Unknown agent: {name}")
    data = _load_agents_status()
    agents = data.setdefault("agents", {})
    agent = agents.setdefault(name, {})
    agent["heartbeat"] = datetime.now().isoformat()
    agent["status"] = body.get("status", "ONLINE")
    if "errors_today" in body:
        agent["errors_today"] = int(body["errors_today"])
    _save_agents_status(data)
    return {"ok": True}


_threading.Thread(target=_auto_repair_loop, daemon=True).start()

if __name__ == "__main__":
    import socket
    base_port = int(os.getenv("ALXQUANT_PORT", "8000"))
    port = base_port
    for attempt in range(20):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("127.0.0.1", port))
            s.close()
            break
        except OSError:
            port = base_port + 1 + attempt
    print("=" * 50)
    print(f"  ALXQUANT Terminal v5.31.0")
    print(f"  Open browser at http://127.0.0.1:{port}")
    print("=" * 50)
    uvicorn.run("gui.html.serve:app", host="127.0.0.1", port=port, workers=1)

