"""CLI de validacao continua do DataHouse.

Roda as checagens de integridade e freshness de todos os dominios e grava
o resultado em JSON (data/logs/validate.log). Usado pela task diaria
ALX-DataHouse-Validate.

Usage:
    python -m Modulos.datahouse.validate_cli
    pythonw Modulos\\datahouse\\validate_cli.py --log data\\logs\\validate.log
"""
import argparse
import json
import os
import sys
from datetime import datetime

APP_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_LOG = os.path.normpath(os.path.join(APP_ROOT, "..", "data", "logs", "validate.log"))

sys.path.insert(0, APP_ROOT)
try:
    from .validator import check_domain_freshness, validate_integrity
    from .scheduler import validate_all_tasks
except ImportError:
    from Modulos.datahouse.validator import check_domain_freshness, validate_integrity
    from Modulos.datahouse.scheduler import validate_all_tasks


def _compact_integrity(report: dict) -> dict:
    """Resume validate_integrity() por simbolo sem despejar gap_details gigantes."""
    out = {}
    for key, info in report.items():
        out[key] = dict(
            gaps=info["gaps"],
            duplicates=info["duplicates"],
            future_data=info["future_data"],
            status=info["status"],
        )
    return out


def run_validation() -> dict:
    fresh = check_domain_freshness()
    integrity = _compact_integrity(validate_integrity())
    tasks = validate_all_tasks()

    task_problems = [t for t in tasks if t.get("problem")]
    issues = []
    for dom in fresh.get("domains", []):
        if dom.get("status") == "critical":
            issues.append(f"{dom.get('domain')}: CRITICAL ({dom.get('age_hours', '?')}h)")
    for key, info in integrity.items():
        if info["status"] == "issues":
            issues.append(f"OHLC {key}: gaps={info['gaps']} dup={info['duplicates']} future={info['future_data']}")
    for t in task_problems:
        issues.append(f"task {t['task']}: {t['state']}")

    overall = "ok"
    if fresh.get("domains") and any(d.get("status") == "critical" for d in fresh["domains"]):
        overall = "critical"
    if any(i["status"] == "issues" for i in integrity.values()):
        overall = "critical" if overall != "critical" else overall
    if task_problems and overall == "ok":
        overall = "warning"

    return dict(
        checked_at=datetime.now().isoformat(),
        overall=overall,
        domains=fresh,
        integrity=integrity,
        tasks_total=len(tasks),
        tasks_healthy=len(tasks) - len(task_problems),
        tasks_problematic=len(task_problems),
        issues=issues,
    )


def _redirect_when_windowless(log_path: str):
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
    parser = argparse.ArgumentParser(description="Validacao continua do DataHouse")
    parser.add_argument("--log", default=DEFAULT_LOG, help="Append result to JSON log file")
    args = parser.parse_args()

    _redirect_when_windowless(args.log)
    print(f"=== validate {datetime.now().isoformat()} ===")
    result = run_validation()
    print(f"OVERALL: {result['overall']}")
    print(f"DOMAINS: {json.dumps(result['domains'], ensure_ascii=False, default=str)}")
    print(f"TASKS  : {result['tasks_healthy']}/{result['tasks_total']} healthy")
    for i in result["issues"][:20]:
        print(f"  - {i}")
    _write_log(args.log, result)
    sys.exit(0 if result["overall"] != "critical" else 1)


if __name__ == "__main__":
    main()
