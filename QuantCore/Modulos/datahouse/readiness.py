"""Gate de prontidao do DataHouse.

Garante que TODOS os dados estejam atualizados ANTES de gerar o
sentimento diario (risk_sentiment_daily.csv) que os robos (MQL5) leem
nas operacoes (Risk_On / Risk_Off).

Fluxo (CLI):
    python -m Modulos.datahouse.readiness             so verifica (exit 0 pronto / 1 nao)
    python -m Modulos.datahouse.readiness --ensure      coleta o critical/stale e revalida
    python -m Modulos.datahouse.readiness --daily      sync -> so entao gera o CSV do sentimento
"""
import argparse
import os
import subprocess
import sys
from datetime import datetime, timedelta

ENGINE_VENV_PYTHON = r"C:\ALXQuant\QuantCore\.venv\Scripts\python.exe"
CLI_COLLECTOR = r"C:\ALXQuant\QuantCore\Modulos\datahouse\cli_collector.py"
RISK_ENGINE = r"C:\ALXQuant\QuantCore\Modulos\risk_sentiment\engine.py"


def readiness_report() -> dict:
    """Relatorio consolidado de pronta de TODOS os ativos + tasks."""
    from .engine import query_update_schedule
    from .scheduler import validate_all_tasks

    asset_rows = [r for r in query_update_schedule() if r.get("enabled", True)]
    tasks = validate_all_tasks()

    fresh = {"ok": 0, "stale": 0, "critical": 0}
    critical_assets = []
    stale_assets = []
    for r in asset_rows:
        st = r.get("status", "ok")
        if st == "no_data":
            # Serie catalogada mas NUNCA coletada: trata como problema para o
            # --ensure tentar buscar (antes caia em 'ok' e nunca era buscada).
            critical_assets.append(r)
            fresh["critical"] += 1
        elif st == "critical":
            critical_assets.append(r)
            fresh["critical"] += 1
        elif st == "stale":
            stale_assets.append(r)
            fresh["stale"] += 1
        else:
            fresh["ok"] += 1

    task_problems = [t for t in tasks if t.get("problem")]
    missing = [t for t in tasks if t.get("state") == "not_present"]
    failed = [t for t in tasks if t.get("state") == "failed"]
    never = [t for t in tasks if t.get("state") == "never"]

    problems = []
    if critical_assets:
        problems.append(
            f"{len(critical_assets)} ativo(s) CRITICAL: "
            + ", ".join(
                f"{r['symbol']} ({r.get('asset_class')}, {round(r.get('age_hours') or 0)}h)"
                for r in critical_assets
            )
)
    if missing:
        problems.append(f"{len(missing)} task(s) AUSENTE: " + ", ".join(t["task"] for t in missing))
    if failed:
        problems.append(f"{len(failed)} task(s) FALHA(exit!=0): " + ", ".join(t["task"] for t in failed))
    if never:
        problems.append(f"{len(never)} task(s) nunca rodou: " + ", ".join(t["task"] for t in never))

    if critical_assets:
        overall = "critical"
    elif fresh["stale"] or never:
        overall = "warning"
    else:
        overall = "ok"

    # Pronto = sem nada criticamente velho e sem task quebrada/ausente.
    # 'stale' (fonte publica com lag natural: series mensais/trimestrais)
    # vira WARNING, alerta, mas nao bloqueia o relatorio diario.
    blocked = bool(critical_assets)
    return {
        "ready": not blocked,
        "blocked": blocked,
        "overall": overall,
        "assets": fresh,
        "critical": critical_assets,
        "stale": stale_assets,
        "critical_count": len(critical_assets),
        "tasks_total": len(tasks),
        "tasks_healthy": len(tasks) - len(task_problems),
        "tasks_problematic": len(task_problems),
        "problems": problems,
        "checked_at": datetime.now().isoformat(),
    }


# --------------------------------------------------------------------- #
#  sync: coleta o que esta critical/stale
# --------------------------------------------------------------------- #
def _run(cmd, timeout=180):
    r = subprocess.run(cmd, capture_output=True, timeout=timeout)
    print(f"[CMD] exit={r.returncode} :: {' '.join(cmd)}")
    return r.returncode


def _upsert_macro_batch(conn, symbol: str, dates: list[str], vals: list[float], now_str: str) -> int:
    """Upsert a batch of (date, value) pairs for a macro symbol into macro_series.

    Faz DELETE em lote (1 SQL) + INSERT em lote via executemany (1 chamada),
    em vez de 2 SQLs por linha (que gerava ~4000 statements por ciclo).
    """
    if not dates:
        return 0
    placeholders = ",".join("?" * len(dates))
    conn.execute(
        f"DELETE FROM macro_series WHERE symbol=? AND date IN ({placeholders})",
        [symbol] + list(dates),
    )
    rows = [(symbol, d, v, now_str) for d, v in zip(dates, vals)]
    conn.executemany(
        "INSERT INTO macro_series (symbol,date,value,updated_at) VALUES (?,?,?,?)",
        rows,
    )
    return len(rows)


def refresh_macro_assets(assets):
    """Baixa (FRED/Yahoo/BCB) e faz upsert em macro_series para os ativos criticals/velhos.

    Verifica freshness por ativo: se a ultima atualizacao esta dentro do
    min_freshness_hours, SKIPPA a coleta para evitar downloads repetidos.
    Baixa tudo primeiro (rede) e so entao abre UMA conexao write para os upserts,
    evitando abrir/fechar dezenas de conexoes (lock contention no DuckDB).
    """
    from config import config
    from fredapi import Fred

    from Modulos.datahouse.collector import get_connection

    _YAHOO_MAP = {"VIX": "^VIX", "DXY": "DX-Y.NYB"}

    fred = Fred(api_key=config.fred.api_key)
    now_str = datetime.now().strftime("%Y-%m-%d %H:%M")
    total = 0
    skipped = 0

    # --- Fase 1: baixa tudo (rede) para memoria; segura lock somente durante o upsert ---
    staged = []  # list[(symbol, collector, dates, vals)]
    for a in assets:
        symbol = a.get("symbol")
        collector = (a.get("collector") or "").upper()
        code = a.get("fred_code") or _YAHOO_MAP.get(symbol) or symbol

        # Freshness check: skip if data is recent enough
        min_fresh_h = a.get("min_freshness_hours") or 24
        last_epoch = a.get("last_epoch")
        if last_epoch:
            age_h = (datetime.now().timestamp() - last_epoch) / 3600.0
            if age_h < min_fresh_h * 0.8:
                skipped += 1
                continue

        try:
            if collector == "BCB":
                import urllib.request, json as _json
                bcb_id = a.get("fred_code") or code
                # Seed amplo p/ series mensais com lag (ex.: PNAD ~2.5 meses):
                # janela de 60d em DB fresco nao alcanca a ultima obs e o BCB devolve 404.
                seed_days = 400 if not last_epoch else 60
                start = (datetime.now() - timedelta(days=seed_days)).strftime("%d/%m/%Y")
                end = datetime.now().strftime("%d/%m/%Y")
                if last_epoch:
                    start = max(datetime.now() - timedelta(days=60),
                                datetime.fromtimestamp(last_epoch) - timedelta(days=2)).strftime("%d/%m/%Y")
                url = f"https://api.bcb.gov.br/dados/serie/bcdata.sgs.{bcb_id}/dados?formato=json&dataInicial={start}&dataFinal={end}"
                req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "Mozilla/5.0"})
                with urllib.request.urlopen(req, timeout=30) as resp:
                    raw = _json.loads(resp.read().decode("utf-8"))
                dados = raw if isinstance(raw, list) else raw.get("dados") or []
                if not dados:
                    print(f"[MACRO] BCB vazio: {symbol} (sgs={bcb_id})")
                    continue
                dates, vals = [], []
                for item in dados:
                    d = item.get("data", "")
                    v = item.get("valor")
                    if d and v is not None:
                        parts = d.split("/")
                        if len(parts) == 3:
                            d = f"{parts[2]}-{parts[1]}-{parts[0]}"
                        dates.append(d)
                        vals.append(float(v.replace(",", ".")))
                if not dates:
                    print(f"[MACRO] BCB sem vals: {symbol}")
                    continue
                staged.append((symbol, "BCB", dates, vals))
            elif collector == "YAHOO":
                import yfinance as yf
                df = yf.download(code, period="1y", progress=False, auto_adjust=True)
                if df is None or df.empty:
                    print(f"[MACRO] Yahoo vazio: {symbol}")
                    continue
                s = df["Close"].squeeze()
                s.index = s.index.tz_localize(None) if s.index.tz is not None else s.index
                s = s.dropna()
                if s.empty:
                    print(f"[MACRO] sem dados novos: {symbol}")
                    continue
                date_col = list(s.index.strftime("%Y-%m-%d"))
                vals_list = [float(v) for v in s.values]
                staged.append((symbol, "Yahoo", date_col, vals_list))
            else:
                seed_days = 400 if not last_epoch else 60
                start = (datetime.now() - timedelta(days=seed_days)).strftime("%Y-%m-%d")
                if last_epoch:
                    start = max(datetime.now() - timedelta(days=60),
                                datetime.fromtimestamp(last_epoch) - timedelta(days=2)).strftime("%Y-%m-%d")
                s = fred.get_series(code, observation_start=start)
                s = s.dropna()
                if s.empty:
                    print(f"[MACRO] sem dados novos: {symbol}")
                    continue
                date_col = list(s.index.strftime("%Y-%m-%d"))
                vals_list = [float(v) for v in s.values]
                staged.append((symbol, "FRED", date_col, vals_list))
        except Exception as e:
            print(f"[MACRO] ERRO {symbol} ({collector} {code}): {e}")

    # --- Fase 2: unica conexao write para todos os upserts ---
    if staged:
        conn = None
        try:
            conn = get_connection(read_only=False)
            for symbol, coll, dates, vals in staged:
                n = _upsert_macro_batch(conn, symbol, dates, vals, now_str)
                total += n
                print(f"[MACRO] {coll} upsert {symbol}: {n} obs (ate {dates[-1]})")
            conn.commit()
        except Exception as e:
            print(f"[MACRO] ERRO upsert: {e}")
        finally:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass

    print(f"[MACRO] total {total} inseridos, {skipped} skipped (fresh)")
    return total


def collect_ohlc(assets):
    """Coleta OHLC via MT5 (cli_collector) para simbolos criticos/ale."""
    collected = 0
    for a in assets:
        sym = a.get("symbol")
        tf = a.get("timeframe") or "M5"
        code = _run([ENGINE_VENV_PYTHON, CLI_COLLECTOR, "--symbol", sym, "--tf", tf, "--log",
                     rf"C:\ALXQuant\data\logs\{sym}_{tf}.log"], timeout=180)
        if code == 0:
            collected += 1
        else:
            print(f"[OHLC] falha MT5 para {sym} (exit {code}) - terminal precisa estar logado")
    return collected


def ensure_fresh(max_iter=2):
    """Tenta atualizar os ativos critical/stale ate ficar pronto.

    Evita re-coletar series macro que ja foram baixadas nesta sessao:
    mantem um set de symbols_ja_coletados e so re-colleta se ainda estao
    critical (nao apenas stale).
    """
    status = "critical"
    collected_macro: set[str] = set()
    for i in range(1, max_iter + 1):
        rep = readiness_report()
        if rep["ready"]:
            status = "ok"
            break
        print(f"[ensure] iter {i}: critical={rep['critical_count']}, stale={rep['assets']['stale']}")
        if not rep["critical"] and not rep["stale"]:
            status = rep["overall"]
            break
        price, macro = _critical_stale_by_class(rep["critical"] + rep["stale"])
        # Evita re-baixar series mensais/trimestrais so por estarem 'stale'
        # (lag natural). Critico/no_data ainda e coletado normalmente.
        macro = [a for a in macro if _macro_needs_collect(a)]
        # Only collect macro assets not already collected this session
        new_macro = [a for a in macro if a.get("symbol") not in collected_macro]
        if new_macro:
            refresh_macro_assets(new_macro)
            collected_macro.update(a.get("symbol") for a in new_macro)
        collect_ohlc(price)
        status = rep["overall"]
    final = readiness_report()
    final["ensure_result"] = status
    final["ensure_attempts"] = max_iter
    return final


# --------------------------------------------------------------------- #
#  geracao do sentimento diario (gateado)
# --------------------------------------------------------------------- #
def generate_daily_sentiment() -> dict:
    """Roda a engine do risk_sentiment (gera risk_sentiment_daily.csv)."""
    r = subprocess.run([ENGINE_VENV_PYTHON, RISK_ENGINE, "--log",
                        r"C:\ALXQuant\data\logs\daily_sentiment.log"],
                       capture_output=True, timeout=600)
    print(f"[DAILY] risk_sentiment exit={r.returncode}")
    return {"ok": r.returncode == 0, "exit": r.returncode}


def _print_report(report: dict):
    print("=" * 60)
    print(f"DATAHOUSE READINESS : {report['overall'].upper()}"
          + (" (PRONTO)" if report.get("ready") else " (BLOQUEADO)"))
    print(f"ASSETS              : ok={report['assets']['ok']} "
          f"stale={report['assets']['stale']} critical={report['assets']['critical']}")
    print(f"TASKS               : {report['tasks_healthy']}/{report['tasks_total']} healthy "
          f"({report['tasks_problematic']} problematic)")
    if report["problems"]:
        print("PROBLEMAS:")
        for p in report["problems"]:
            print(f"  - {p}")
    else:
        print("Nenhum problema.")


def _finish_log(args, report):
    if args.log:
        import json
        os.makedirs(os.path.dirname(args.log) or ".", exist_ok=True)
        with open(args.log, "a", encoding="utf-8") as f:
            f.write(json.dumps(report, ensure_ascii=False) + "\n")


def _critical_stale_by_class(assets):
    price = [a for a in assets if (a.get("collector") or "").upper() == "MT5"]
    macro = [a for a in assets if (a.get("collector") or "").upper() in ("FRED", "YAHOO", "BCB")]
    return price, macro


# Series macro com lag natural de publicacao: re-coletar a cada ciclo de 5 min
# nao traz dado novo (FRED so publica na proxima janela) e queima CPU atoa.
_NATURAL_LAG_CADENCES = {"monthly", "quarterly", "annual"}


def _macro_needs_collect(a: dict) -> bool:
    """True se vale a pena tentar coleta para este ativo macro."""
    st = a.get("status")
    if st in ("critical", "no_data"):
        return True  # truly old ou nunca coletado: sempre tenta
    cad = (a.get("cadence") or "").strip().lower()
    return cad not in _NATURAL_LAG_CADENCES  # stale so se cadencia ativa (daily/weekly/hourly)


def main():
    parser = argparse.ArgumentParser(description="Gate de prontidao DataHouse")
    parser.add_argument("--ensure", action="store_true", help="Atualizar critical/stale antes de avaliar")
    parser.add_argument("--daily", action="store_true",
                        help="Modo diario: sync + so gera o CSV do sentimento se pronto")
    parser.add_argument("--notify", action="store_true", help="Envia alerta ao bloqueado")
    parser.add_argument("--log", default="", help="Grava JSON do resultado")
    args = parser.parse_args()

    if args.daily:
        report = ensure_fresh(max_iter=2)
        if not report.get("ready"):
            print("\n[DAILY] BLOQUEADO: dados nao atualizados. Sentimento NAO gerado.")
        else:
            res = generate_daily_sentiment()
            report["report_generated"] = res
            print(f"[DAILY] sentimento gerado: ok={res['ok']}")
    elif args.ensure:
        report = ensure_fresh(max_iter=2)
    else:
        report = readiness_report()

    _print_report(report)

    if args.log:
        _finish_log(args, report)
    if not report.get("ready") and args.notify:
        try:
            from Modulos.risk_sentiment.engine import send_alert
            body = f"[ALXQuant DataHouse] PRONTIDAO {report['overall'].upper()}: " + " | ".join(report["problems"])
            send_alert(body)
            print("[ALERT] sent.")
        except Exception as e:
            print(f"[ALERT] send failed: {e}")

    sys.exit(0 if report.get("ready") else 1)


if __name__ == "__main__":
    main()
