"""Build histórico do RiskSentimentEngine.

Baixa todas as séries FRED + Yahoo desde 2019 e salva em:
    data/datasets/risk_sentiment_daily.csv

Uso:
    python data/build_risk_sentiment_dataset.py
"""
import sys
import os
sys.path.insert(0, r"C:\ALXQuant")

import time
import warnings
warnings.filterwarnings("ignore")

import pandas as pd
import yfinance as yf
from fredapi import Fred
from config import config

_FRED_SERIES = {
    "vix": "VIXCLS",
    "eur_usd": "DEXUSEU",
    "jpy_usd": "DEXJPUS",
    "usd_index": "DTWEXBGS",
    "yield_2y": "DGS2",
    "yield_10y": "DGS10",
    "yield_curve": "T10Y2Y",
    "fed_funds": "FEDFUNDS",
    "sofr": "SOFR",
    "hy_spread": "BAMLH0A0HYM2",
    "ig_spread": "BAMLC0A0CM",
    "fed_balance": "WALCL",
    "reverse_repo": "RRPONTSYD",
    "cpi": "CPIAUCSL",
    "core_pce": "PCEPILFE",
    "oil_wti": "DCOILWTICO",
    "cny_usd": "DEXCHUS",
}

_YAHOO_SYMBOLS = {
    "spy": "SPY",
    "qqq": "QQQ",
    "btc": "BTC-USD",
    "gld": "GLD",
    "uso": "USO",
    "aud_usd": "AUDUSD=X",
    "eur_jpy": "EURJPY=X",
}

# Fallback Yahoo symbols para séries FRED descontinuadas ou atrasadas
_YAHOO_FALLBACK = {
    "eur_usd_fb":  "EURUSD=X",
    "jpy_usd_fb":  "JPY=X",
    "usd_index_fb":"DX-Y.NYB",
    "vix_fb":      "^VIX",
}

OUTPUT = r"C:\ALXQuant\data\mql5\risk_sentiment_daily.csv"


def fetch_fred(fred: Fred, series_id: str, name: str, start: str) -> pd.Series:
    """Fetch FRED series, return pd.Series with name."""
    try:
        data = fred.get_series(series_id, observation_start=start)
        s = pd.Series(data.values, index=pd.to_datetime(data.index), name=name)
        s = s.resample("D").last().ffill()
        return s
    except Exception as e:
        print(f"  FRED {name} ({series_id}): erro - {e}")
        return pd.Series(dtype=float, name=name)


def fetch_yahoo(symbol: str, name: str, start: str) -> pd.Series:
    """Fetch Yahoo series (close), return pd.Series with name."""
    try:
        df = yf.download(symbol, start=start, progress=False, auto_adjust=True)
        if df.empty:
            return pd.Series(dtype=float, name=name)
        s = df["Close"].squeeze()
        if isinstance(s, pd.DataFrame):
            s = s.iloc[:, 0]
        s.name = name
        s = s.resample("D").last().ffill()
        return s
    except Exception as e:
        print(f"  Yahoo {name} ({symbol}): erro - {e}")
        return pd.Series(dtype=float, name=name)


def main():
    t0 = time.time()
    start_date = "2019-01-01"

    print("Baixando dados historicos do RiskSentimentEngine...")
    print(f"  FRED series: {len(_FRED_SERIES)} (excluindo gold_lbma — serie inexistente)")
    print(f"  Yahoo symbols: {len(_YAHOO_SYMBOLS)} + {len(_YAHOO_FALLBACK)} fallback")

    fred = Fred(api_key=config.fred.api_key)

    # --- FRED ---
    print("\n[FRED]")
    fred_series = []
    for name, sid in _FRED_SERIES.items():
        s = fetch_fred(fred, sid, name, start_date)
        if not s.empty:
            fred_series.append(s)
            print(f"  {name:15s} -> {s.dropna().index[0].date()}..{s.dropna().index[-1].date()}  ({len(s.dropna())} obs)")

    # --- Yahoo (primary + fallback) ---
    print("\n[Yahoo]")
    yahoo_series = []
    _yf_all = {**_YAHOO_SYMBOLS, **_YAHOO_FALLBACK}
    for name, sym in _yf_all.items():
        s = fetch_yahoo(sym, name, start_date)
        if not s.empty:
            yahoo_series.append(s)
            print(f"  {name:15s} -> {s.dropna().index[0].date()}..{s.dropna().index[-1].date()}")

    # --- Merge ---
    print("\nMerge...")
    all_series = fred_series + yahoo_series
    if not all_series:
        print("ERRO: nenhuma serie baixada.")
        return

    df = pd.concat(all_series, axis=1)

    # Forward fill (max 5 dias)
    df = df.ffill(limit=5)

    # ─── Fallback FRED → Yahoo para séries descontinuadas/atrasadas ───
    _FRED_FALLBACK = {
        "eur_usd":  "eur_usd_fb",
        "jpy_usd":  "jpy_usd_fb",
        "usd_index":"usd_index_fb",
        "vix":      "vix_fb",
    }
    for fred_col, yahoo_col in _FRED_FALLBACK.items():
        if fred_col not in df.columns or yahoo_col not in df.columns:
            continue
        tail = df[fred_col].tail(10)
        if tail.isna().sum() > 3:
            df[fred_col] = df[fred_col].fillna(df[yahoo_col])
        df.drop(columns=[yahoo_col], inplace=True)

    # ─── Pre-computa global_risk_score e label para cada linha ───
    print("\nPre-computando risk scores...")

    import numpy as _np

    _history: dict = {}
    _window: int = 30

    def _zscore(key: str, value: float) -> float:
        hist = _history.setdefault(key, [])
        hist.append(value)
        if len(hist) > _window:
            hist.pop(0)
        if len(hist) < 5:
            return 0.0
        m = float(_np.mean(hist))
        s = float(_np.std(hist))
        return (value - m) / s if s > 1e-10 else 0.0

    scores = []
    labels_list = []

    for idx in range(len(df)):
        row = df.iloc[idx].to_dict()

        # 1. EQUITY (25%)
        eq = 0.5
        hy = row.get("hy_spread", 200)
        if hy < 150:
            eq += 0.3
        elif hy > 300:
            eq -= 0.3
        spy_ret = _zscore("spy_return", row.get("spy", 500))
        eq += max(-0.2, min(0.2, spy_ret * 0.1))
        eq_score = 0.25 * max(0.0, min(1.0, eq))

        # 2. FX (15%)
        fx = 0.5
        usd = row.get("usd_index", 120)
        if 100 < usd < 110:
            fx += 0.2
        elif usd > 115:
            fx -= 0.2
        fx_score = 0.15 * max(0.0, min(1.0, fx))

        # 3. RATES (20%)
        rt = 0.5
        yc = row.get("yield_curve", 0)
        if yc > 0.5:
            rt += 0.3
        elif yc < 0:
            rt -= 0.2
        ff = row.get("fed_funds", 5)
        if ff < 3:
            rt += 0.2
        elif ff > 5.5:
            rt -= 0.2
        rt_score = 0.20 * max(0.0, min(1.0, rt))

        # 4. LIQUIDITY (15%)
        liq = 0.5
        rr = row.get("reverse_repo", 0)
        if rr < 100:
            liq += 0.3
        elif rr > 500:
            liq -= 0.2
        liq_score = 0.15 * max(0.0, min(1.0, liq))

        # 5. INFLATION (10%)
        inf = 0.5
        cpi_actual = row.get("cpi", 3)
        if cpi_actual < 3:
            inf += 0.3
        elif cpi_actual > 5:
            inf -= 0.3
        inf_score = 0.10 * max(0.0, min(1.0, inf))

        # 6. RISK APPETITE (15%)
        ra = 0.5
        vix_val = row.get("vix", 15)
        if vix_val < 15:
            ra += 0.3
        elif vix_val > 25:
            ra -= 0.3
        btc_val = row.get("btc", 30000)
        btc_z = _zscore("btc_risk", btc_val)
        ra += max(-0.15, min(0.15, btc_z * 0.05))
        ra_score = 0.15 * max(0.0, min(1.0, ra))

        global_score = float(max(0.0, min(1.0, eq_score + fx_score + rt_score + liq_score + inf_score + ra_score)))
        scores.append(global_score)

        # Label
        if global_score >= 0.7 and vix_val < 18 and yc > 0:
            labels_list.append("RISK_ON")
        elif global_score <= 0.35 or vix_val > 25 or yc < -0.5:
            labels_list.append("RISK_OFF")
        else:
            labels_list.append("NEUTRAL")

    df["global_risk_score"] = scores
    df["risk_label"] = labels_list
    print(f"  Score range: {min(scores):.3f} - {max(scores):.3f}")
    print(f"  Labels: {labels_list.count('RISK_ON')}x ON, {labels_list.count('RISK_OFF')}x OFF, {labels_list.count('NEUTRAL')}x NEUTRAL")

    # Ajusta casas decimais por ativo
    _ROUND = {
        "vix": 2, "eur_usd": 5, "jpy_usd": 5, "usd_index": 3, "cny_usd": 5,
        "yield_2y": 3, "yield_10y": 3, "yield_curve": 3,
        "fed_funds": 2, "sofr": 4,
        "hy_spread": 2, "ig_spread": 2,
        "fed_balance": 0, "reverse_repo": 0,
        "cpi": 2, "core_pce": 2,
        "oil_wti": 2,
        "spy": 2, "qqq": 2, "gld": 2, "uso": 2,
        "btc": 2,
        "aud_usd": 5, "eur_jpy": 5,
        "global_risk_score": 4,
    }
    for col, dec in _ROUND.items():
        if col in df.columns:
            df[col] = df[col].round(dec)

    # Remove linhas totalmente vazias
    df = df.dropna(how="all")

    df.index.name = "date"
    df = df.reset_index()

    # risk_label como segunda coluna
    cols = df.columns.tolist()
    if "risk_label" in cols:
        cols.remove("risk_label")
        cols.insert(1, "risk_label")
        df = df[cols]

    print(f"  Shape: {df.shape}")
    print(f"  Periodo: {df['date'].min()} -> {df['date'].max()}")

    # Save
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    df.to_csv(OUTPUT, index=False)
    print(f"\nSalvo: {OUTPUT}")

    # Copia para Common\Files (usado pelo Strategy Tester)
    COMMON_FILES = r"C:\Users\User\AppData\Roaming\MetaQuotes\Terminal\Common\Files\risk_sentiment_daily.csv"
    try:
        os.makedirs(os.path.dirname(COMMON_FILES), exist_ok=True)
        df.to_csv(COMMON_FILES, index=False)
        print(f"Copiado (tester): {COMMON_FILES}")
    except Exception as e:
        print(f"  Aviso: nao foi possivel copiar para Common Files: {e}")

    print(f"Tempo total: {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
