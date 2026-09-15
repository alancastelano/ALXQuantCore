"""Orquestrador unico de coleta do DataHouse.

Reune OHLC (MT5 + yfinance fallback), MACRO (FRED) e RISK (risk_sentiment)
em um unico ponto de atualizacao, destinado a rodar via Windows Task Scheduler
(perfil SYSTEM) de forma independente do servidor GUI.

O endpoint /api/schedules/register (e ensure_tasks.py) cria uma unica task
ALX-DataHouse-CollectAll que dispara este modulo.

Usage:
    python -m Modulos.datahouse.collect_all
    python -m Modulos.datahouse.collect_all --log data/logs/collect_all.log
"""

import json
import sys
from datetime import datetime


def run(log_callback=None, max_iter: int = 2) -> dict:
    """Executa o refresh completo (OHLC+MACRO) e gera o sentimento diario (RISK).

    Retorna um dicionario com o status agregado e os sub-relatorios.
    """
    def log(msg: str):
        if log_callback:
            log_callback(msg)
        else:
            print(msg)

    report: dict = {"ok": True, "steps": {}, "errors": [], "warnings": []}

    # --- Step 1: OHLC (MT5/yfinance) + MACRO (FRED) via readiness gate ---
    try:
        from Modulos.datahouse.readiness import ensure_fresh
        log("CollectAll: atualizando OHLC + MACRO (readiness.ensure_fresh)...")
        rf = ensure_fresh(max_iter=max_iter)
        report["steps"]["ensure_fresh"] = rf
        ready = bool(rf.get("ready"))
        if not ready:
            problems = rf.get("problems", [])
            report["warnings"].append("ensure_fresh incompleto: " + "; ".join(problems))
            log("CollectAll: ensure_fresh NAO pronto: " + "; ".join(problems))
        else:
            log("CollectAll: ensure_fresh OK")
    except Exception as e:  # nosec - superficie o erro no relatorio
        report["ok"] = False
        report["errors"].append(f"ensure_fresh falhou: {e}")
        log(f"CollectAll: ERRO ensure_fresh: {e}")

    # --- Step 2: RISK (sentimento diario) ---
    try:
        from Modulos.datahouse.readiness import generate_daily_sentiment
        log("CollectAll: gerando sentimento diario (RISK)...")
        res = generate_daily_sentiment()
        report["steps"]["risk"] = res
        if not res.get("ok"):
            report["errors"].append(f"generate_daily_sentiment nao ok: {res}")
            log(f"CollectAll: generate_daily_sentiment NAO ok: {res}")
        else:
            log("CollectAll: RISK OK")
    except Exception as e:  # nosec
        report["ok"] = False
        report["errors"].append(f"generate_daily_sentiment falhou: {e}")
        log(f"CollectAll: ERRO generate_daily_sentiment: {e}")

    report["ok"] = report["ok"] and not report["errors"]
    report["finished_at"] = datetime.now().isoformat()
    return report


def main():
    log_path = ""
    for i, a in enumerate(sys.argv):
        if a == "--log" and i + 1 < len(sys.argv):
            log_path = sys.argv[i + 1]

    report = run()

    if log_path:
        try:
            import os
            os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
            with open(log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps({"ts": datetime.now().isoformat(), **report},
                                   ensure_ascii=False, default=str) + "\n")
        except Exception:
            pass

    print(json.dumps(report, ensure_ascii=False, default=str, indent=2))
    sys.exit(0 if report["ok"] else 1)


if __name__ == "__main__":
    main()
