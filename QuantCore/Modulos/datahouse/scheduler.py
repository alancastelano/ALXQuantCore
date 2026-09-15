"""Scheduler Windows para operações automatizadas de coleta e validação de dados.

Gerencia tasks do Windows Task Scheduler (schtasks) para pipelines:
- Coleta incremental OHLC (MT5)
- Risk Sentiment (macro)
- Validação de saúde dos dados

Funções:
    get_schedules()               - agenda atual (JSON)
    register_windows_tasks()      - cria tasks no Windows
    unregister_windows_tasks()    - remove tasks
    validate_all_tasks()          - status das tasks
    get_windows_task_status()     - status de uma task
    update_last_run()             - registra última execução
"""
import csv
import io
import json
import os
import subprocess
from datetime import datetime, timedelta
from typing import Any, Optional

APP_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DATA_DIR = os.path.join(APP_ROOT, "data")
SCHEDULES_PATH = os.path.join(DATA_DIR, "schedules.json")
LOG_DIR = os.path.join(DATA_DIR, "logs")

_PYTHON = os.path.join(APP_ROOT, ".venv", "Scripts", "python.exe")
if not os.path.exists(_PYTHON):
    _PYTHON = "python"
# pythonw.exe -> nao abre janela de console / nao rouba foco das outras janelas.
_PYTHONW = os.path.join(APP_ROOT, ".venv", "Scripts", "pythonw.exe")
if not os.path.exists(_PYTHONW):
    _PYTHONW = _PYTHON
_COLLECTOR = os.path.join(APP_ROOT, "Modulos", "datahouse", "cli_collector.py")
_RISK_ENGINE = os.path.join(APP_ROOT, "Modulos", "risk_sentiment", "engine.py")

_COLLECT_ALL = os.path.join(APP_ROOT, "Modulos", "datahouse", "collect_all.py")


def build_collect_all_command(logfile: str) -> str:
    return f'"{_PYTHONW}" "{_COLLECT_ALL}" --log "{logfile}"'


def _load() -> list[dict[str, Any]]:
    if not os.path.exists(SCHEDULES_PATH):
        return []
    with open(SCHEDULES_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def _save(schedules: list[dict[str, Any]]):
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(SCHEDULES_PATH, "w", encoding="utf-8") as f:
        json.dump(schedules, f, indent=2, ensure_ascii=False)


def _stagger_slot(index: int, total: int, start_hour: int = 0, step_hours: int = 2, minute: int = 55) -> str:
    """Distribui horarios unicos evitando topo da hora (:00) para nao colidir com tasks
    horarias (ex.: crypto) e diminuir risco de lock de escrita no DuckDB (1 writer/arquivo)."""
    minute = minute % 60
    if minute == 0:
        minute = 55
    hour_of_day = (start_hour + index * step_hours) % 24
    return f"{hour_of_day:02d}:{minute:02d}"


def build_ohlc_command(symbol: str, timeframe: str, logfile: str) -> str:
    return (f'"{_PYTHONW}" "{_COLLECTOR}" --symbol {symbol} --tf {timeframe} '
            f'--log "{logfile}"')


def build_risk_command(logfile: str) -> str:
    return f'"{_PYTHONW}" "{_RISK_ENGINE}" --log "{logfile}"'


def build_health_command(logfile: str) -> str:
    health_script = os.path.join(APP_ROOT, "Modulos", "datahouse", "health.py")
    return (f'"{_PYTHONW}" "{health_script}" --notify '
            f'--log "{logfile}"')


def build_validate_command(logfile: str) -> str:
    validate_script = os.path.join(APP_ROOT, "Modulos", "datahouse", "validate_cli.py")
    return (f'"{_PYTHONW}" "{validate_script}" '
            f'--log "{logfile}"')


def build_ensure_command(logfile: str) -> str:
    ensure_script = os.path.join(APP_ROOT, "Modulos", "datahouse", "ensure_tasks.py")
    return (f'"{_PYTHONW}" "{ensure_script}" '
            f'--log "{logfile}"')


def build_news_command(logfile: str) -> str:
    news_script = os.path.join(APP_ROOT, "Modulos", "news", "ff_calendar.py")
    return (f'"{_PYTHONW}" "{news_script}" --fetch '
            f'--log "{logfile}"')


DEFAULT_SCHEDULES: list[dict[str, Any]] = [
    # Orquestrador unico: cobre OHLC (MT5+yfinance) + MACRO (FRED) + RISK.
    # Roda como SYSTEM (independente do servidor GUI) apos registro como admin.
    dict(domain="Collect", label="CollectAll", task="ALX-DataHouse-CollectAll",
         freq="hourly", at=":05",
         command=build_collect_all_command(os.path.join(LOG_DIR, "collect_all.log"))),
    # Saude e validacao: essenciais — sempre registradas, nao dependem do DB.
    dict(domain="Health", label="Health", task="ALX-DataHouse-Health",
         freq="hourly", at="02:20",
         command=build_health_command(os.path.join(LOG_DIR, "health.log"))),
    dict(domain="Validate", label="Validate", task="ALX-DataHouse-Validate",
         freq="daily", at="03:40",
         command=build_validate_command(os.path.join(LOG_DIR, "validate.log"))),
    # ForexFactory Calendar: coleta semanal do calendario economico (segunda-feira).
    dict(domain="News", label="FFCalendar", task="ALX-News-FFCalendar",
         freq="weekly", at="00:10", weekday="MON",
         command=build_news_command(os.path.join(LOG_DIR, "news_ffcalendar.log"))),
]


def catalog_schedules() -> list[dict[str, Any]]:
    """Tarefas dinamicas derivadas do catalogo (reservado para uso futuro).

    Health e Validate agora estao em DEFAULT_SCHEDULES (sempre registradas).
    """
    return []


def get_schedules() -> list[dict[str, Any]]:
    """Retorna as tasks registradas; preserva last_run historico do schedules.json."""
    saved = _load()
    meta = {s["task"]: s for s in saved}
    base = DEFAULT_SCHEDULES + catalog_schedules()
    if not base:
        base = saved or DEFAULT_SCHEDULES
    for s in base:
        m = meta.get(s["task"], {})
        s["last_run"] = m.get("last_run")
        s["last_status"] = m.get("last_status")
        s["last_detail"] = m.get("last_detail")
    _save(base)
    return base


def update_last_run(task_name: str, status: str = "ok", detail: str = ""):
    schedules = get_schedules()
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    for s in schedules:
        if s["task"] == task_name:
            s["last_run"] = now
            s["last_status"] = status
            s["last_detail"] = detail
            break
    _save(schedules)


_KEEP_TASKS = {"ALX-DataHouse-CollectAll", "ALX-DataHouse-Health", "ALX-DataHouse-Validate"}


def _list_all_task_names() -> list[str]:
    try:
        r = subprocess.run("schtasks /query /fo csv /nh", shell=True,
                           capture_output=True, text=True, timeout=30)
    except Exception:
        return []
    if r.returncode != 0 or not r.stdout:
        return []
    import csv as _csv
    names: list[str] = []
    for row in _csv.reader(r.stdout.splitlines()):
        if not row:
            continue
        name = row[0].lstrip("\\").strip()
        if name.startswith("ALX-DataHouse-") or name.startswith("ALXQuant-"):
            names.append(name)
    return names


def _cleanup_legacy_tasks(log_callback=None):
    """Remove tasks antigas (OHLC por simbolo, Macro/Risk separados) para nao
    duplicar coleta apos a consolidacao no orquestrador unico."""
    for name in _list_all_task_names():
        if name in _KEEP_TASKS:
            continue
        try:
            rr = subprocess.run(f'schtasks /delete /tn "{name}" /f', shell=True,
                                capture_output=True, text=True, timeout=30)
            if log_callback:
                log_callback(f"Legacy task removida: {name} (rc={rr.returncode})")
        except Exception as e:
            if log_callback:
                log_callback(f"Falha ao remover legacy {name}: {e}")


def task_exists(name: str) -> bool:
    """Retorna True se a task existe no Windows Task Scheduler."""
    try:
        r = subprocess.run(f'schtasks /query /tn "{name}"', shell=True,
                           capture_output=True, text=True, timeout=15)
        return r.returncode == 0
    except Exception:
        return False


def register_windows_tasks(log_callback=None, run_as: str = "SYSTEM") -> list[str]:
    """Cria/atualiza as tasks do Windows para coleta.

    Args:
        log_callback: callback de logging.
        run_as: 'SYSTEM' (nao depende de usuario logado; ideal VPS 24/7)
                ou nome de usuario (ex: 'DESKTOP-X\\User'). Para SYSTEM nao
                e preciso senha; para usuario e preciso /rp (ver register_windows_tasks_full).
    """
    _cleanup_legacy_tasks(log_callback)
    schedules = get_schedules()
    messages = []
    for s in schedules:
        task_name = s["task"]
        command = s["command"]
        freq = s["freq"]
        at = s.get("at", "18:00")

        if log_callback:
            log_callback(f"Registering {task_name}...")

        auth = ""
        if run_as.upper() == "SYSTEM":
            auth = ' /RU SYSTEM'
        else:
            auth = f' /RU "{run_as}" /RP ""'

        if freq == "daily":
            sch = f'schtasks /create /tn "{task_name}" /tr "{command}" /sc daily /st {at} /f{auth}'
        elif freq == "weekly":
            parts = at.split()
            day = parts[0] if len(parts) == 2 else "SAT"
            time = parts[1] if len(parts) == 2 else "09:00"
            sch = f'schtasks /create /tn "{task_name}" /tr "{command}" /sc weekly /d {day} /st {time} /f{auth}'
        elif freq == "hourly":
            # horaria: roda a cada hora de hora em hora (nao usa /ri no /sc hourly)
            sch = f'schtasks /create /tn "{task_name}" /tr "{command}" /sc hourly /f{auth}'
        elif freq == "monthly":
            parts = at.split()
            day = parts[0] if parts else "1"
            time = parts[1] if len(parts) >= 2 else "08:00"
            sch = f'schtasks /create /tn "{task_name}" /tr "{command}" /sc monthly /d {day} /st {time} /f'
        else:
            msg = f"{task_name}: unknown frequency '{freq}'"
            messages.append(msg)
            if log_callback:
                log_callback(f"ERROR: {msg}")
            continue

        try:
            r = subprocess.run(sch, shell=True, capture_output=True, text=True, timeout=30)
            if r.returncode == 0:
                messages.append(f"OK: {task_name}")
                if log_callback:
                    log_callback(f"OK: {task_name} registered")
            else:
                err = (r.stderr or "").strip()
                msg = f"{task_name} -> {err}"
                if any(k in err.lower() for k in ("denied", "access", "negado")):
                    msg = (f"{task_name}: ACESSO NEGADO ao criar task no Windows Task "
                           f"Scheduler. Registre como ADMINISTRADOR: rode o servidor como "
                           f"admin ou execute 'python -m Modulos.datahouse.ensure_tasks "
                           f"--register' num prompt elevado (UAC).")
                messages.append(f"ERROR: {msg}")
                if log_callback:
                    log_callback(f"ERROR: {msg}")
        except Exception as e:
            msg = f"{task_name} -> {e}"
            messages.append(f"EXCEPTION: {msg}")
            if log_callback:
                log_callback(f"EXCEPTION: {msg}")

    if log_callback:
        log_callback(f"All tasks processed ({len(schedules)} total)")
    return messages


def unregister_windows_tasks(log_callback=None) -> list[str]:
    schedules = get_schedules()
    messages = []
    for s in schedules:
        task_name = s["task"]
        if log_callback:
            log_callback(f"Removing {task_name}...")
        try:
            r = subprocess.run(f'schtasks /delete /tn "{task_name}" /f', shell=True, capture_output=True, text=True, timeout=30)
            if r.returncode == 0:
                messages.append(f"Removed: {task_name}")
                if log_callback:
                    log_callback(f"Removed: {task_name}")
            else:
                msg = f"Failed to remove {task_name}: {r.stderr.strip()}"
                messages.append(f"ERROR: {msg}")
                if log_callback:
                    log_callback(f"ERROR: {msg}")
        except Exception as e:
            msg = f"Failed to remove {task_name}: {e}"
            messages.append(f"EXCEPTION: {msg}")
            if log_callback:
                log_callback(f"EXCEPTION: {msg}")
    if log_callback:
        log_callback(f"All removals processed ({len(schedules)} total)")
    return messages


BOOTSTRAP_TASK = "ALX-DataHouse-Bootstrap"


def bootstrap_command() -> str:
    """Comando executado pela task de bootstrap (ONSTART, /RU SYSTEM).

    Reinstala as tasks ALX-DataHouse-* automaticamente na inicializacao do
    sistema, sem depender do GUI ou de usuario logado.
    """
    return build_ensure_command(os.path.join(LOG_DIR, "ensure_tasks.log"))


def install_bootstrap_task(log_callback=None) -> str:
    """Registra a task de bootstrap no Windows (trigger 'At startup', SYSTEM).

    Executa uma unica vez (ou quando o bootstrap tiver sido removido). Depois
    disso, toda inicializacao do Windows reinstala as tasks que faltarem.
    """
    cmd = bootstrap_command()
    sch = (f'schtasks /create /tn "{BOOTSTRAP_TASK}" /tr "{cmd}" '
           f'/sc onstart /ru SYSTEM /f')
    if log_callback:
        log_callback(f"Installing bootstrap task {BOOTSTRAP_TASK}...")
    try:
        r = subprocess.run(sch, shell=True, capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            msg = f"OK: {BOOTSTRAP_TASK} registered (At startup, SYSTEM)"
            if log_callback:
                log_callback(msg)
            return msg
        msg = f"ERROR: {BOOTSTRAP_TASK} -> {r.stderr.strip()}"
        if log_callback:
            log_callback(msg)
        return msg
    except Exception as e:
        msg = f"EXCEPTION: {BOOTSTRAP_TASK} -> {e}"
        if log_callback:
            log_callback(msg)
        return msg


def uninstall_bootstrap_task(log_callback=None) -> str:
    """Remove a task de bootstrap do Windows."""
    if log_callback:
        log_callback(f"Removing {BOOTSTRAP_TASK}...")
    try:
        r = subprocess.run(f'schtasks /delete /tn "{BOOTSTRAP_TASK}" /f', shell=True, capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            msg = f"Removed: {BOOTSTRAP_TASK}"
            if log_callback:
                log_callback(msg)
            return msg
        msg = f"Failed to remove {BOOTSTRAP_TASK}: {r.stderr.strip()}"
        if log_callback:
            log_callback(msg)
        return msg
    except Exception as e:
        msg = f"Failed to remove {BOOTSTRAP_TASK}: {e}"
        if log_callback:
            log_callback(msg)
        return msg


def _find_header(headers: list[str], candidates: list[str]) -> Optional[str]:
    hl = [h.lower().replace("-", " ").replace("_", " ") for h in headers]
    for cand in candidates:
        cl = cand.lower().replace("-", " ").replace("_", " ")
        if cl in hl:
            idx = hl.index(cl)
            return headers[idx]
        for i, h in enumerate(hl):
            if cl in h or h in cl:
                return headers[i]
    return None


def get_windows_task_status(task_name: str) -> dict[str, Optional[str]]:
    try:
        r = subprocess.run(f'schtasks /query /tn "{task_name}" /v /fo csv', shell=True, capture_output=True, text=False, timeout=15)
        if r.returncode != 0:
            err = (r.stderr or b"").decode("cp850", errors="replace").lower()
            denied = ("acesso negado" in err or "access is denied" in err or "zugriff verweigert" in err)
            src = err or (r.stdout or b"").decode("cp850", errors="replace").lower()
            denied = denied or "acesso negado" in src or "access is denied" in src
            if denied:
                return dict(status="restricted", last_result=None, next_run=None, last_run=None)
            return dict(status="not_found", last_result=None, next_run=None, last_run=None)

        raw = r.stdout.decode("cp850", errors="replace")
        reader = csv.reader(io.StringIO(raw))
        rows = list(reader)
        if len(rows) < 2:
            return dict(status="not_found", last_result=None, next_run=None, last_run=None)

        headers = [h.strip() for h in rows[0]]
        values = [v.strip() for v in rows[1]]
        info = dict(zip(headers, values))

        last_run_candidates = ["Last Run", "Ultima Execucao", "Ultima Execuçãção", "Horário da última execução", "Horario da ultima execucao", "Letzte Ausführung", "Dernière exécution"]
        last_result_candidates = ["Last Result", "Ultimo Resultado", "Último Resultado", "Último resultado", "Letztes Ergebnis", "Dernier résultat"]
        next_run_candidates = ["Next Run", "Proxima Execucao", "Próxima Execução", "Hora da próxima execução", "Hora da proxima execucao", "Nächste Ausführung", "Prochaine exécution"]
        status_candidates = ["Status", "Estado", "Statut"]

        h_last_run = _find_header(headers, last_run_candidates)
        h_last_result = _find_header(headers, last_result_candidates)
        h_next_run = _find_header(headers, next_run_candidates)
        h_status = _find_header(headers, status_candidates)

        status_val = info.get(h_status, "unknown") if h_status else "unknown"
        if status_val.lower() in ("ready", "pronto", "prêt", "bereit"):
            status_val = "Ready"

        return dict(
            status=status_val,
            last_result=info.get(h_last_result) if h_last_result else None,
            next_run=info.get(h_next_run) if h_next_run else None,
            last_run=info.get(h_last_run) if h_last_run else None,
        )
    except Exception:
        return dict(status="error", last_result=None, next_run=None, last_run=None)


def interpret_last_result(code) -> tuple[str, bool]:
    """Interpreta o 'Last Result' (Windows) em (label, healthy).

    labels: 'ok' | 'never' | 'failed'.
    healthy False para 'never' (task ainda nao executou) e 'failed' (saida != 0).
    """
    if code is None:
        return "never", False
    c = str(code).strip()
    if c == "":
        return "never", False
    normalized = c.lower().replace("0x", "")
    never_codes = {"41303", "267011", "41302", "41300", "41301"}
    if normalized in never_codes:
        return "never", False
    try:
        if int(c) == 0:
            return "ok", True
    except ValueError:
        pass
    return "failed", False


def validate_all_tasks() -> list[dict[str, Any]]:
    schedules = get_schedules()
    results = []
    for s in schedules:
        wt = get_windows_task_status(s["task"])
        last_result = wt.get("last_result")
        label, healthy = interpret_last_result(last_result)
        restricted = wt["status"] == "restricted"
        # restricted = task existe mas nao podemos ler o resultado (ex.: rodou como SYSTEM
        # e estamos num processo sem privilegios). Nao confundir com 'healthy': reportar
        # como indeterminado e problem=True para que o monitor (health) nao de falso positivo.
        state = ("restricted" if restricted else
                 ("not_present" if wt["status"] in ("not_found", "error") else
                  ("healthy" if healthy else label)))
        exists = True if restricted else wt["status"] not in ("not_found", "error")
        healthy = False if restricted else healthy
        results.append(dict(
            task=s["task"],
            domain=s["domain"],
            label=s.get("label", ""),
            windows_status=wt["status"],
            last_run=wt.get("last_run") or "--",
            last_result=last_result or "--",
            next_run=wt.get("next_run") or "--",
            exists=exists,
            healthy=healthy,
            problem=not healthy,
            state=state,
        ))
    return results
