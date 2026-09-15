"""CLI para coleta incremental OHLC via MetaTrader 5.

Usage:
    python -m Modulos.datahouse.cli_collector --symbol XAUUSD --tf M5
    python -m Modulos.datahouse.cli_collector --symbol XAUUSD --tf M5 --days 60
"""
import argparse
import json
import os
import sys
from datetime import datetime

sys.path.insert(0, r"C:\ALXQuant")
try:
    from .collector import incremental_update, smart_update, full_update
except ImportError:
    from Modulos.datahouse.collector import incremental_update, smart_update, full_update


def _write_log(log_path: str, result: dict):
    if not log_path:
        return
    try:
        os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
        record = dict(
            ts=datetime.now().isoformat(),
            exit_code=0 if result.get("ok", False) else 1,
            **result,
        )
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
    except Exception:
        pass


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


def _install_crash_hook(log_path: str):
    def hook(exc_type, exc_value, exc_tb):
        import traceback as _tb
        lines = _tb.format_exception(exc_type, exc_value, exc_tb)
        if log_path:
            try:
                with open(log_path, "a", encoding="utf-8") as f:
                    f.write(json.dumps(dict(ts=datetime.now().isoformat(), ok=False,
                                            crash="".join(lines)),
                                       ensure_ascii=False, default=str) + "\n")
            except Exception:
                pass
        sys.__excepthook__(exc_type, exc_value, exc_tb)
    sys.excepthook = hook


def main():
    parser = argparse.ArgumentParser(description="ALXQuant MT5 OHLC collector")
    parser.add_argument("--symbol", required=True, help="Symbol (ex: XAUUSD)")
    parser.add_argument("--tf", required=True, help="Timeframe (ex: M5, H1, D1)")
    parser.add_argument("--mode", choices=["incremental", "smart", "full"], default="incremental")
    parser.add_argument("--days", type=int, default=30, help="Days back for incremental")
    parser.add_argument("--years", type=int, default=10, help="Years back for full")
    parser.add_argument("--json", action="store_true", help="Output JSON")
    parser.add_argument("--log", default="", help="Append result to JSON log file")
    args = parser.parse_args()

    _redirect_when_windowless(args.log)
    _install_crash_hook(args.log)

    if args.mode == "full":
        result = full_update(args.symbol, args.tf, years=args.years)
    elif args.mode == "smart":
        result = smart_update(args.symbol, args.tf, inc_days=args.days)
    else:
        result = incremental_update(args.symbol, args.tf, days_back=args.days)

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2, default=str))
    else:
        for k, v in result.items():
            print(f"{k}: {v}")

    failed = not result.get("ok", False)
    if failed:
        err = result.get("error", result.get("message", "collection failed"))
        print(f"ERROR: {err}", file=sys.stderr)
        result = dict(result, error=err, ok=False)

    _write_log(args.log, result)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
