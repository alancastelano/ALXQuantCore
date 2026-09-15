"""Monitor consolidado de saude do DataHouse.

Responsavel por responder a pergunta central do datahouse:
"todos os dados estao sendo atualizados? ha algum problema critico?"

Combina:
    - freshness por ativo (v_update_schedule: ok/stale/critical)
    - tarefas do Windows (validate_all_tasks: healthy/never/failed/missing)

Funcoes:
    health_report()     - relatorio consolidado (dict)
    main()              - CLI; sai com codigo != 0 se critical; --notify envia alerta
"""
import argparse
import os
import sys
from datetime import datetime

sys.path.insert(0, r"C:\ALXQuant")


def health_report() -> dict:
    """Relatorio unificado de prontidao do datahouse."""
    from Modulos.datahouse.engine import query_update_schedule
    from Modulos.datahouse.scheduler import validate_all_tasks

    asset_rows = query_update_schedule()
    tasks = validate_all_tasks()

    fresh = {"ok": 0, "stale": 0, "critical": 0, "no_data": 0}
    for r in asset_rows:
        st = r.get("status", "ok")
        fresh[st if st in fresh else "ok"] += 1

    critical_assets = [r for r in asset_rows if r.get("status") == "critical"]
    stale_assets = [r for r in asset_rows if r.get("status") == "stale"]

    task_problems = [t for t in tasks if t.get("problem")]
    missing = [t for t in tasks if t.get("state") == "not_present"]
    failed = [t for t in tasks if t.get("state") == "failed"]
    never = [t for t in tasks if t.get("state") == "never"]

    problems: list[str] = []
    if critical_assets:
        problems.append(f"{len(critical_assets)} ativo(s) CRITICAL: "
                        + ", ".join(f"{r['symbol']} ({r.get('status')})" for r in critical_assets))
    if missing:
        problems.append(f"{len(missing)} task(s) AUSENTE: " + ", ".join(t["task"] for t in missing))
    if failed:
        problems.append(f"{len(failed)} task(s) com FALHA (exit!=0): " + ", ".join(t["task"] for t in failed))
    if never:
        problems.append(f"{len(never)} task(s) nunca rodou: " + ", ".join(t["task"] for t in never))

    if critical_assets or failed or missing:
        overall = "critical"
    elif stale_assets or never:
        overall = "warning"
    else:
        overall = "ok"

    return {
        "overall": overall,
        "assets": fresh,
        "tasks_total": len(tasks),
        "tasks_healthy": len(tasks) - len(task_problems),
        "tasks_problematic": len(task_problems),
        "problems": problems,
        "checked_at": datetime.now().isoformat(),
    }


def _print_report(report: dict):
    print("=" * 60)
    print("DATAHOUSE HEALTH")
    print("=" * 60)
    print(f"OVERALL       : {report['overall'].upper()}")
    print(f"ASSETS        : ok={report['assets']['ok']} stale={report['assets']['stale']} "
          f"critical={report['assets']['critical']}")
    print(f"TASKS         : {report['tasks_healthy']}/{report['tasks_total']} healthy "
          f"({report['tasks_problematic']} problematic)")
    if report["problems"]:
        print("CRITICAL ITEMS:")
        for p in report["problems"]:
            print(f"  - {p}")
    else:
        print("No critical items.")


def main():
    parser = argparse.ArgumentParser(description="Datahouse health checker")
    parser.add_argument("--notify", action="store_true",
                        help="Send alert via ALXQUANT_ALERT_WEBHOOK when critical")
    parser.add_argument("--log", default="",
                        help="Append result line to JSON log file (also captures prints under pythonw)")
    args = parser.parse_args()

    if args.log and (sys.stdout is None or sys.stderr is None):
        try:
            import json as _json
            os.makedirs(os.path.dirname(args.log) or ".", exist_ok=True)
            _f = open(args.log, "a", encoding="utf-8", buffering=1)
            sys.stdout = _f
            sys.stderr = _f
        except Exception:
            pass

    report = health_report()
    _print_report(report)

    if report["overall"] != "ok" and args.notify:
        try:
            from Modulos.risk_sentiment.engine import send_alert
            body = f"[ALXQuant DataHouse] {report['overall'].upper()}: " + " | ".join(report["problems"])
            send_alert(body)
            print("[ALERT] sent.")
        except Exception as e:
            print(f"[ALERT] send failed: {e}")

    if args.log:
        try:
            import json as _json
            with open(args.log, "a", encoding="utf-8") as f:
                f.write(_json.dumps(report, ensure_ascii=False) + "\n")
        except Exception:
            pass

    sys.exit(1 if report["overall"] == "critical" else 0)


if __name__ == "__main__":
    main()