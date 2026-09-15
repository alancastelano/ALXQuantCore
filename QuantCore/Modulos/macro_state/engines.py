"""Deterministic dimension engines for the Global Macro Economic State.

Each engine takes the (already transformed) indicator Series for an economy and
returns (score, state, detail). Scores are in [-1, 1] where +1 == benign / strong
and -1 == stressed / weak. No ML is used; every step is transparent.
"""

from __future__ import annotations

import math
import numpy as np
import pandas as pd

from . import normalization as N

# window per frequency for the rolling z-score
_FREQ_WINDOW = {"D": 504, "W": 104, "M": 36, "Q": 12, "A": 10}


def _win(freq: str) -> int:
    return _FREQ_WINDOW.get(freq, 36)


def _latest(series: pd.Series):
    s = series.dropna()
    return float(s.iloc[-1]) if len(s) else None


def _norm_latest(series: pd.Series, freq: str):
    """Rolling z-score of the latest observation vs trailing window (or None)."""
    s = series.dropna()
    if len(s) < 5:
        return None
    win = _win(freq)
    if len(s) >= max(30, win // 2):
        z = N.rolling_zscore(s, window=win, min_periods=30)
    else:
        z = N.expanding_zscore(s, min_periods=5)
    z = z.dropna()
    return float(z.iloc[-1]) if len(z) else None


def _state_generic(score, bands):
    """bands: list of (threshold, label) sorted ascending; fallback last."""
    if score is None:
        return "MISSING"
    for thr, label in bands:
        if score < thr:
            return label
    return bands[-1][1]


_GROWTH_BANDS = [(-0.33, "Contraction"), (-0.10, "Slowdown"), (0.10, "Mid-Cycle"),
                 (0.33, "Early Expansion"), (2.0, "Expansion")]
_LABOR_BANDS = [(-0.33, "Weak"), (-0.10, "Softening"), (0.10, "Neutral"),
                (0.33, "Improving"), (2.0, "Strong")]
_INFL_BANDS = [(-0.33, "Deflationary/Slack"), (-0.10, "Below Target"), (0.10, "On Target"),
               (0.33, "Above Target"), (2.0, "Hot")]
_FIN_BANDS = [(-0.33, "Stress"), (-0.10, "Tightening"), (0.10, "Neutral"),
              (0.33, "Easing"), (2.0, "Accommodative")]
_RECESSION_BANDS = [(-0.33, "Recession Risk"), (-0.10, "Deteriorating"), (0.10, "Normal"),
                    (2.0, "Healthy")]


def _aggregate(series_by_name: dict, meta_by_name: dict):
    """Mean of oriented component z-scores. Returns (score, n_components, comp)."""
    comps = {}
    vals = []
    for name, s in series_by_name.items():
        meta = meta_by_name.get(name, {})
        z = _norm_latest(s, meta.get("freq", "M"))
        if z is None:
            comps[name] = None
            continue
        oriented = meta.get("direction", 1) * z
        comps[name] = round(oriented, 4)
        # direction 0 => neutral / mixed, excluded from the aggregate
        if meta.get("direction", 1) != 0:
            vals.append(oriented)
    if not vals:
        return None, 0, comps
    return float(np.mean(vals)), len(vals), comps


def growth_engine(series_by_name: dict, meta_by_name: dict):
    score, n, comps = _aggregate(series_by_name, meta_by_name)
    return score, _state_generic(score, _GROWTH_BANDS), {"n": n, "components": comps}


def labor_engine(series_by_name: dict, meta_by_name: dict):
    score, n, comps = _aggregate(series_by_name, meta_by_name)
    return score, _state_generic(score, _LABOR_BANDS), {"n": n, "components": comps}


def inflation_engine(series_by_name: dict, meta_by_name: dict, target: float = 0.02):
    """Inflation stability: penalize deviation from the (configurable) target."""
    comps = {}
    scores = []
    for name, s in series_by_name.items():
        latest = _latest(s)
        if latest is None:
            comps[name] = None
            continue
        gap = (latest / 100.0) - target  # series is in %, target in fraction
        # above target => negative (bad); below target => mildly negative (deflation risk)
        if gap >= 0:
            sc = -math.tanh(gap / 0.02)
        else:
            sc = -math.tanh(-gap / 0.04) * 0.5
        comps[name] = round(float(sc), 4)
        scores.append(sc)
    if not scores:
        return None, "MISSING", {"components": comps}
    score = float(np.mean(scores))
    return score, _state_generic(score, _INFL_BANDS), {"components": comps}


def financial_conditions_engine(series_by_name: dict, meta_by_name: dict):
    score, n, comps = _aggregate(series_by_name, meta_by_name)
    return score, _state_generic(score, _FIN_BANDS), {"n": n, "components": comps}


def recession_engine(series_by_name: dict, meta_by_name: dict):
    """Recession probability 0..1 from transparent signals; score = 1 - 2*prob.

    Supports both US (T10Y2Y, HY_SPREAD, UNRATE, PAYEMS, INDPRO) and
    Brazil (IBC_BR, UNEMPLOYMENT) series names.
    """
    signals = {}
    weights = {}

    # Yield curve (inverted => risk) - US only
    if "T10Y2Y" in series_by_name:
        v = _latest(series_by_name["T10Y2Y"])
        if v is not None:
            p = max(0.0, min(1.0, -v / 0.01))
            signals["curve"] = p
            weights["curve"] = 0.30
    # High-yield spread - US only
    if "HY_SPREAD" in series_by_name:
        v = _latest(series_by_name["HY_SPREAD"])
        if v is not None:
            p = max(0.0, min(1.0, (v - 2.0) / 5.0))
            signals["hy_spread"] = p
            weights["hy_spread"] = 0.20
    # Unemployment (Sahm rule for US, level for Brazil)
    unrate_key = "UNRATE" if "UNRATE" in series_by_name else "UNEMPLOYMENT"
    if unrate_key in series_by_name:
        s = series_by_name[unrate_key].dropna()
        if unrate_key == "UNRATE" and len(s) >= 13:
            last3 = s.iloc[-3:].mean()
            min12 = s.iloc[-12:].min() if len(s) >= 12 else s.min()
            sahmed = last3 - min12
            p = max(0.0, min(1.0, sahmed / 0.5))
            signals["sahm"] = p
            weights["sahm"] = 0.25
        elif len(s) > 0:
            latest = float(s.iloc[-1])
            p = max(0.0, min(1.0, latest / 15.0))
            signals["unemployment"] = p
            weights["unemployment"] = 0.40
    # Payrolls YoY decline - US only
    if "PAYEMS" in series_by_name:
        v = _latest(series_by_name["PAYEMS"])
        if v is not None:
            p = max(0.0, min(1.0, -v / 1.0))
            signals["payrolls"] = p
            weights["payrolls"] = 0.15
    # Industrial production YoY (INDPRO for US, IBC_BR for Brazil)
    ip_key = "INDPRO" if "INDPRO" in series_by_name else "IBC_BR"
    if ip_key in series_by_name:
        v = _latest(series_by_name[ip_key])
        if v is not None:
            p = max(0.0, min(1.0, -v / 2.0))
            signals["ip"] = p
            weights["ip"] = 0.10

    if not signals:
        return None, "MISSING", {"components": signals}
    wsum = sum(weights.values())
    prob = sum(signals[k] * (weights[k] / wsum) for k in signals)
    score = 1.0 - 2.0 * prob
    state = "Recession Risk" if prob >= 0.6 else ("Warning" if prob >= 0.4 else "Normal")
    return score, state, {"prob": round(prob, 4), "components": signals}


def phillips_engine(series_by_name: dict, meta_by_name: dict, target: float = 0.02):
    """Dynamic inflation-pressure (slack) gauge from labor tightness + inflation gap."""
    comps = {}
    slack = None
    infl = None
    if "UNRATE" in series_by_name:
        z = _norm_latest(series_by_name["UNRATE"], meta_by_name.get("UNRATE", {}).get("freq", "M"))
        if z is not None:
            slack = -z  # low unemployment => positive slack pressure
            comps["labor_slack"] = round(float(slack), 4)
    infl_series = series_by_name["CPI"] if "CPI" in series_by_name else series_by_name.get("CORE_CPI")
    if infl_series is not None:
        latest = _latest(infl_series)
        if latest is not None:
            gap = (latest / 100.0) - target
            infl = math.tanh(gap / 0.02)
            comps["inflation_gap"] = round(float(infl), 4)
    if slack is None and infl is None:
        return None, "MISSING", {"components": comps}
    if slack is None:
        pressure = infl
    elif infl is None:
        pressure = slack
    else:
        pressure = 0.6 * slack + 0.4 * infl
    score = -math.tanh(pressure)
    state = "Rising Pressure" if score < -0.1 else ("Cooling" if score > 0.1 else "Balanced")
    return score, state, {"components": comps}
