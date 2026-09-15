"""Auto-registro das tasks do Windows na inicializacao do sistema.

Garante autonomia 24/5 do DataHouse sem depender do GUI:

- Verifica se todas as tasks ALX-DataHouse-* existem no Windows Task Scheduler.
- Se qualquer task faltar, chama register_windows_tasks() para reinstalar.
- Loga o resultado em data/logs/ensure_tasks.log.

A task ALX-DataHouse-Bootstrap (trigger ONSTART, /RU SYSTEM) executa este
script em toda inicializacao do Windows, antes do login, reinstalando
automaticamente qualquer task de coleta/validacao que tenha sumido.

Uso:
    python -m Modulos.datahouse.ensure_tasks
    pythonw Modulos\\datahouse\\ensure_tasks.py --log data\\logs\\ensure_tasks.log
"""
import argparse
import json
import os
import sys
from datetime import datetime

APP_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_LOG = os.path.join(APP_ROOT, "data", "logs", "ensure_tasks.log")

sys.path.insert(0, APP_ROOT)
try:
    from .scheduler import get_schedules, get_windows_task_status, register_windows_tasks
except ImportError:
    from Modulos.datahouse.scheduler import get_schedules, get_windows_task_status, register_windows_tasks


def ensure_tasks_installed(log_callback=None) -> dict:
    """Verifica as tasks ALX-DataHouse-* e reinstala as que faltarem.

    Returns:
        dict: checked_at, total, missing, registered (msgs se houve registro).
    """
    schedules = get_schedules()
    task_names = [s["task"] for s in schedules]
    missing = []
    for tn in task_names:
        st = get_windows_task_status(tn)
        if st["status"] in ("not_found", "error"):
            missing.append(tn)
            if log_callback:
                log_callback(f"MISSING: {tn} ({st['status']})")
        elif log_callback:
            log_callback(f"OK: {tn}")

    result = dict(
        checked_at=datetime.now().isoformat(),
        total=len(task_names),
        missing=missing,
        registered=[],
    )
    if missing:
        if log_callback:
            log_callback(f"{len(missing)} task(s) ausente(s) — reinstalando...")
        result["registered"] = register_windows_tasks(log_callback=log_callback)
    else:
        if log_callback:
            log_callback(f"Todas as {len(task_names)} tasks presentes.")
    return result


def _redirect_when_windowless(log_path: str):
    """Sob pythonw.exe nao ha console (sys.stdout/stderr = None). Redireciona
    stdout/stderr para o arquivo de log para que erros/prints fiquem visiveis."""
    if not log_path:
        return
    if getattr(sys, "stdout", None) is None or getattr(sys, "stderr", None) is None:
        try:
            os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
            f = open(log_path, "a", encoding="utf-8", buffering=1)
            sys.stdout = f
            sys.stderr = f
        except Exception:
            pass


def _write_log(log_path: str, result: dict):
    if not log_path:
        return
    try:
        os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(result, ensure_ascii=False, default=str) + "\n")
    except Exception:
        pass


def main():
    parser = argparse.ArgumentParser(description="Verifica e reinstala tasks ALX-DataHouse-*")
    parser.add_argument("--log", default=DEFAULT_LOG, help="Append result to JSON log file")
    parser.add_argument("--register", action="store_true",
                        help="Force re-register all tasks (requires admin)")
    args = parser.parse_args()

    _redirect_when_windowless(args.log)
    print(f"=== ensure_tasks {datetime.now().isoformat()} ===")
    if args.register:
        from Modulos.datahouse.scheduler import register_windows_tasks
        result = dict(checked_at=datetime.now().isoformat(), total=0, missing=[],
                      registered=register_windows_tasks(log_callback=lambda m: print(m)))
    else:
        result = ensure_tasks_installed(log_callback=lambda m: print(m))
    missing = result.get("missing", [])
    _write_log(args.log, result)
    print(f"RESULT: total={result['total']} missing={len(missing)} "
          f"registered={len(result.get('registered', []))}")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
