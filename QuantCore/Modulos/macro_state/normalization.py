"""Normalization helpers for the Global Macro Economic State module.

All transforms are deterministic and transparent (no ML). They operate on
pandas Series and return pandas Series aligned to the same index.
"""

from __future__ import annotations

import numpy as np
import pandas as pd


def rolling_zscore(series: pd.Series, window: int = 252, min_periods: int = 60) -> pd.Series:
    """Rolling z-score over a trailing window (no look-ahead).

    Uses the trailing mean/std; recent points are compared to the historical
    distribution of the preceding `window` observations.
    """
    s = series.astype(float)
    min_periods = min(min_periods, window)
    roll_mean = s.rolling(window, min_periods=min_periods).mean()
    roll_std = s.rolling(window, min_periods=min_periods).std()
    out = (s - roll_mean) / roll_std.replace(0, np.nan)
    return out


def expanding_zscore(series: pd.Series, min_periods: int = 30) -> pd.Series:
    """Expanding z-score from the beginning of the available history."""
    s = series.astype(float)
    m = s.expanding(min_periods=min_periods).mean()
    sd = s.expanding(min_periods=min_periods).std()
    return (s - m) / sd.replace(0, np.nan)


def percentile_rank(series: pd.Series, window: int = 252, min_periods: int = 30) -> pd.Series:
    """Trailing percentile rank in [0, 1] of the latest value vs its window."""
    s = series.astype(float)
    out = s.rolling(window, min_periods=min_periods).apply(
        lambda x: (x[-1] <= x).mean(), raw=True
    )
    return out


def standardize(series: pd.Series) -> pd.Series:
    """Full-sample z-score (only for stable, complete histories)."""
    s = series.astype(float)
    sd = s.std()
    if sd == 0 or np.isnan(sd):
        return pd.Series(np.zeros(len(s)), index=s.index)
    return (s - s.mean()) / sd


def minmax(series: pd.Series, lo: float = 0.0, hi: float = 1.0) -> pd.Series:
    """Min-max scale to [lo, hi] using the observed range of the series."""
    s = series.astype(float)
    mn, mx = s.min(), s.max()
    if mx == mn or np.isnan(mx) or np.isnan(mn):
        return pd.Series(np.full(len(s), (lo + hi) / 2.0), index=s.index)
    return lo + (s - mn) / (mx - mn) * (hi - lo)


def yoy(series: pd.Series) -> pd.Series:
    """Year-over-year percentage change (12-month lookback)."""
    s = series.astype(float)
    return s.pct_change(12) * 100.0


def mom(series: pd.Series, periods: int = 1) -> pd.Series:
    """Month-over-month percentage change."""
    s = series.astype(float)
    return s.pct_change(periods) * 100.0


def qoq_annualized(series: pd.Series, periods_per_year: int = 4) -> pd.Series:
    """Quarter-over-quarter change annualized (for quarterly GDP)."""
    s = series.astype(float)
    return (s.pct_change(1)) * periods_per_year * 100.0


def clip_score(x):
    """Clamp a score to the [-1, 1] display range (0.5 = neutral)."""
    if x is None or (isinstance(x, float) and np.isnan(x)):
        return None
    return float(max(-1.0, min(1.0, x)))
