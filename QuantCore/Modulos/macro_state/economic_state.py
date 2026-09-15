"""Orchestrator: build the Global Macro Economic State from stored indicators.

Reads raw series from `macro_series`, transforms + normalizes them, runs the
deterministic dimension engines, classifies the regime, validates data quality and
aggregates a global state. Pure computation — no I/O side effects except reads.
"""

from __future__ import annotations

from datetime import datetime

import numpy as np
import pandas as pd

from . import registry, engines, regime_classifier
from . import normalization as N

DIMENSIONS = registry.DIMENSIONS


def _batch_load(conn) -> dict[str, pd.Series]:
    """Load ALL needed macro_series in a single query, return {symbol: Series}."""
    needed = set()
    for economy in registry.list_economies():
        for dim in DIMENSIONS:
            for ind in registry.get_indicators(economy, dim):
                sid = ind.get("series_id")
                if sid:
                    needed.add(sid)
    if not needed:
        return {}
    placeholders = ",".join(f"'{s}'" for s in needed)
    # CAST date to VARCHAR avoids slow per-row pd.to_datetime() in Python
    rows = conn.execute(
        f"SELECT symbol, CAST(date AS VARCHAR), value FROM macro_series "
        f"WHERE symbol IN ({placeholders}) ORDER BY symbol, date"
    ).fetchall()
    by_sym: dict[str, list[tuple]] = {}
    for sym, d, v in rows:
        by_sym.setdefault(sym, []).append((d, v))
    cache: dict[str, pd.Series] = {}
    for sym, pairs in by_sym.items():
        dates = [p[0] for p in pairs]
        vals = [float(p[1]) for p in pairs]
        # Vectorized: convert all dates at once, then build Series
        dt_idx = pd.to_datetime(dates, format="mixed")
        s = pd.Series(vals, index=dt_idx).sort_index().dropna()
        if len(s) > 0:
            cache[sym] = s
    return cache


def _load_series(conn, symbol: str, _cache: dict | None = None) -> pd.Series | None:
    if _cache is not None and symbol in _cache:
        return _cache[symbol]
    rows = conn.execute(
        "SELECT date, value FROM macro_series WHERE symbol = ? ORDER BY date", [symbol]
    ).fetchall()
    if not rows:
        return None
    idx, vals = [], []
    for d, v in rows:
        try:
            idx.append(pd.to_datetime(d))
            vals.append(float(v))
        except Exception:
            continue
    if not idx:
        return None
    s = pd.Series(vals, index=pd.DatetimeIndex(idx)).sort_index()
    return s.dropna()


def _transform(series: pd.Series, ind: dict) -> pd.Series:
    s = series.astype(float)
    freq = ind.get("freq", "M")
    t = ind.get("transform", "level")
    if t == "level":
        return s
    if t == "yoy":
        periods = {"D": 252, "W": 52, "M": 12, "Q": 4, "A": 1}.get(freq, 12)
        return s.pct_change(periods) * 100.0
    if t == "mom":
        periods = {"D": 21, "W": 1, "M": 1, "Q": 1}.get(freq, 1)
        return s.pct_change(periods) * 100.0
    if t == "qoq":
        return N.qoq_annualized(s, periods_per_year=4)
    return s


def compute_economy(conn, economy: str, _series_cache: dict | None = None) -> dict:
    target = registry.INFLATION_TARGETS.get(economy, 0.02)
    dim_results = {}
    latest_raw = {}
    transformed_cache = {}

    for dim in DIMENSIONS:
        inds = registry.get_indicators(economy, dim)
        series_by_name, meta_by_name = {}, {}
        for ind in inds:
            sid = ind.get("series_id")
            if not sid:
                continue
            raw = _load_series(conn, sid, _cache=_series_cache)
            if raw is None or len(raw) == 0:
                continue
            latest_raw[ind["name"]] = float(raw.dropna().iloc[-1])
            tf = _transform(raw, ind)
            if len(tf.dropna()) == 0:
                continue
            series_by_name[ind["name"]] = tf
            meta_by_name[ind["name"]] = ind
            transformed_cache[ind["name"]] = (tf, ind)

        if not series_by_name:
            dim_results[dim] = (None, "MISSING", {"reason": "no data"})
            continue
        if dim == "growth":
            r = engines.growth_engine(series_by_name, meta_by_name)
        elif dim == "labor":
            r = engines.labor_engine(series_by_name, meta_by_name)
        elif dim == "inflation":
            r = engines.inflation_engine(series_by_name, meta_by_name, target=target)
        elif dim == "financial_conditions":
            r = engines.financial_conditions_engine(series_by_name, meta_by_name)
        elif dim == "recession":
            r = engines.recession_engine(series_by_name, meta_by_name)
        else:
            r = (None, "MISSING", {})
        dim_results[dim] = r

    # Phillips curve (dynamic inflation pressure)
    ph_series, ph_meta = {}, {}
    for nm in ("CPI", "CORE_CPI", "UNRATE"):
        if nm in transformed_cache:
            ph_series[nm] = transformed_cache[nm][0]
            ph_meta[nm] = transformed_cache[nm][1]
    if ph_series:
        ph = engines.phillips_engine(ph_series, ph_meta, target=target)
    else:
        ph = (None, "MISSING", {"reason": "no data"})

    regime, regime_confidence = regime_classifier.classify_with_confidence(dim_results)
    dq = regime_classifier.validate(conn, economy, registry)
    momentum = regime_classifier.compute_momentum_simple(dim_results)
    stability = regime_classifier.compute_stability(dim_results, regime)

    agg, contributions = _aggregate_economy(dim_results, economy)
    return {
        "economy": economy,
        "dimensions": dim_results,
        "phillips": ph,
        "regime": regime,
        "regime_confidence": regime_confidence,
        "momentum": momentum,
        "stability": stability,
        "data_quality": dq,
        "latest_raw": latest_raw,
        "score": agg,
        "contributions": contributions,
        "computed_at": datetime.utcnow().isoformat(),
    }


def _aggregate_economy(dim_results: dict, economy: str):
    weights = registry.MACRO_WEIGHTS.get(economy, {})
    num, den = 0.0, 0.0
    contributions = {}
    for dim, (score, _, _) in dim_results.items():
        w = weights.get(dim, 0.0)
        if score is not None and w:
            num += score * w
            den += w
            contributions[dim] = round(score * w, 4)
    return (float(num / den) if den else None), contributions


def compute_global(conn) -> dict:
    series_cache = _batch_load(conn)
    econ_states = {e: compute_economy(conn, e, _series_cache=series_cache) for e in registry.list_economies()}
    # global dimension scores = weighted avg across economies
    g_dim = {}
    g_weights = registry.GLOBAL_WEIGHTS
    wsum = sum(g_weights.values())
    for dim in DIMENSIONS:
        num, den = 0.0, 0.0
        for e, st in econ_states.items():
            sc = st["dimensions"].get(dim, (None, "", {}))[0]
            w = g_weights.get(e, 0.0)
            if sc is not None and w:
                num += sc * w
                den += w
        g_dim[dim] = (float(num / den), "", {}) if den else (None, "MISSING", {})
    g_phillips = None
    # global regime
    g_regime, g_regime_confidence = regime_classifier.classify_with_confidence(g_dim)
    g_momentum = regime_classifier.compute_momentum_simple(g_dim)
    g_stability = regime_classifier.compute_stability(g_dim, g_regime)
    g_score = None
    g_contributions = {}
    num, den = 0.0, 0.0
    for e, st in econ_states.items():
        if st["score"] is not None:
            w = g_weights.get(e, 0.0)
            num += st["score"] * w
            den += w
            g_contributions[e] = round(st["score"] * w, 4)
    if den:
        g_score = float(num / den)
    return {
        "economies": econ_states,
        "global": {
            "dimensions": g_dim,
            "regime": g_regime,
            "regime_confidence": g_regime_confidence,
            "momentum": g_momentum,
            "stability": g_stability,
            "score": g_score,
            "contributions": g_contributions,
        },
        "computed_at": datetime.utcnow().isoformat(),
    }


def get_state(conn) -> dict:
    """Snapshot for the API. Mirrors compute_global but trims internal detail."""
    return compute_global(conn)
