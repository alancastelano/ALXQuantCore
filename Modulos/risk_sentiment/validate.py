"""validate.py — validação do sinal oficial (KCRORO) e do modelo RORO v4.

Fundido de validation.py (ancoragem oficial) + validate_v4.py (correlações v4)
em 2026-08-29. Expõe validate_official() e validate_v4_model(); main() roda ambos.
"""
import sys
import os
import warnings

import numpy as np
import pandas as pd
from fredapi import Fred
from config import config

from Modulos.risk_sentiment.engine import (
    build_roro_v4, ModelRefit, fetch_resilient, flattened_factors,
    MODEL_EST_END, classify_v4, roro_sentiment, transform_component,
    check_signal_contract,
)

warnings.filterwarnings("ignore")
sys.path.insert(0, r"C:\ALXQuant")

FRED = Fred(api_key=config.fred.api_key)

# ---- Metas oficiais (KC Fed RORO, em sigma) ----
ANCHORS = {
    "2008-09-15": -3.3,  # Lehman
    "2011-08-08": -3.0,  # downgrade EUA / crate
    "2015-08-24": -1.6,  # China deval / Taper tantrum residual
    "2018-02-05": -1.3,  # VIX spike
    "2020-03-16": -3.7,  # COVID
    "2022-03-07": -1.5,  # inicio tightening
    "2022-09-26": -2.0,  # gilt crisis
    "2023-03-13": -2.1,  # SVB
}
MONTH_PEAKS = {  # mes (YYYY-MM) -> nivel esperado (sigma)
    "2008-10": -3.0, "2011-08": -2.9, "2020-03": -3.5,
    "2022-09": -1.8, "2023-03": -2.0, "2015-08": -1.5,
}
EVENT_WIN = 3  # dias ao redor do evento
TOL = 0.6      # tolerancia (sigma) para ancoras pontuais
MIN_CORR = 0.5  # correlacao minima v4 x KCRORO
TOL_PEAK = 0.8  # tolerancia para picos mensais


# ===================== validação OFICIAL (KCRORO) =====================
def load_kcroro(start="2005-01-01"):
    return fetch_resilient("kcroro", start, FRED)


def check_anchors(kc):
    fails = []
    for d, target in ANCHORS.items():
        d0 = pd.Timestamp(d)
        win = kc[(kc.index >= d0 - pd.Timedelta(days=EVENT_WIN)) &
                 (kc.index <= d0 + pd.Timedelta(days=EVENT_WIN))]
        if win.empty:
            fails.append((d, None, target, "sem dado"))
            continue
        val = win.min() if target < 0 else win.max()
        if abs(val - target) > TOL:
            fails.append((d, round(float(val), 2), target, "fora da tolerancia"))
    for m, target in MONTH_PEAKS.items():
        m0 = pd.Timestamp(m + "-01")
        win = kc[(kc.index >= m0) & (kc.index <= m0 + pd.offsets.MonthEnd(0))]
        if win.empty:
            fails.append((m, None, target, "mes sem dado"))
            continue
        val = win.min()
        if abs(val - target) > TOL_PEAK:
            fails.append((m, round(float(val), 2), target, "pico mensal fora"))
    return fails


def validate_official():
    print("[VALIDATE-OFFICIAL] Carregando KCRORO...")
    kc = load_kcroro()
    print(f"[VALIDATE-OFFICIAL] {len(kc)} obs de {kc.index.min().date()} a {kc.index.max().date()}")
    fails = check_anchors(kc)
    if fails:
        print(f"[VALIDATE-OFFICIAL] {len(fails)} ancoras FALHARAM:")
        for f in fails:
            print("   ", f)
    else:
        print("[VALIDATE-OFFICIAL] OK: todas as ancoras batem.")
    return len(fails)


# ===================== validação MODELO v4 (RORO PCA) =====================
def load_levels(start="2005-01-01"):
    out = {}
    for key in flattened_factors():
        try:
            s = fetch_resilient(key, start, FRED)
            if s is not None and not s.empty:
                out[key] = s
        except Exception as e:
            print(f"[V4] fator {key} indisponivel: {e}")
    return pd.concat(out, axis=1).sort_index()


def align(v4_z, kc):
    kc2 = kc.reindex(v4_z.index)
    kc2 = kc2.interpolate().ffill().bfill()
    return kc2


def anchor_signal(v4, kc):
    corr = v4["roro_v4"].corr(kc)
    print(f"[V4] corr(roro_v4, KCRORO) = {corr:.3f}  (min={MIN_CORR})")
    worst = 0.0
    for d, target in ANCHORS.items():
        d0 = pd.Timestamp(d)
        win = v4[(v4.index >= d0 - pd.Timedelta(days=EVENT_WIN)) &
                 (v4.index <= d0 + pd.Timedelta(days=EVENT_WIN))]
        if win.empty:
            continue
        val = win["roro_v4"].min() if target < 0 else win["roro_v4"].max()
        worst = max(worst, abs(val - target))
    print(f"[V4] maior desvio em ancoras = {worst:.2f} sigma (tol={TOL})")
    return corr >= MIN_CORR and worst <= TOL


def validate_v4_model():
    print("[VALIDATE-V4] Carregando fatores v4...")
    levels = load_levels()
    print(f"[VALIDATE-V4] {levels.shape[1]} fatores, {len(levels)} dias")
    v4 = build_roro_v4(levels)
    kc = load_kcroro()
    kc = align(v4["roro_v4"], kc)
    ok = anchor_signal(v4, kc)
    print(f"[VALIDATE-V4] {'OK' if ok else 'FALHOU'}")
    return ok


def main():
    n_fail = validate_official()
    ok_v4 = validate_v4_model()
    if n_fail == 0 and ok_v4:
        print("\n[MAIN] Tudo OK.")
        sys.exit(0)
    else:
        print(f"\n[MAIN] Falhas: oficial={n_fail}, v4_ok={ok_v4}")
        sys.exit(1)


if __name__ == "__main__":
    main()
