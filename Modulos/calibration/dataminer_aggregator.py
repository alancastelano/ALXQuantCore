"""DataMiner CSV aggregator - deterministic statistics without LLM.

Reads DataMiner CSV output and computes per-bucket statistics for
regime analysis, Hurst bucket analysis, semantic flag analysis, etc.

Supports multiple CSV schemas (detected automatically).
"""

from __future__ import annotations
import csv
import math
import logging
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from scipy import stats as sp_stats

from .schemas import BucketStats, DataminerSummary

logger = logging.getLogger(__name__)

# ── Column mappings for different schemas ──────────────────────────────────────
# Current CSV (91 columns, no version header)
SCHEMA_91 = {
    "trade_id": 0, "ticket": 1, "magic": 2, "symbol": 3, "direction": 4,
    "entry_time": 5, "entry_price": 6, "volume": 7, "spread_at_entry": 8,
    "hurst": 9, "r2": 10, "strength": 11, "slope": 12, "slope_normalized": 13,
    "direction_score": 14, "momentum_state": 15, "atr": 16,
    "distance_vwap": 17, "distance_vwap_atr": 18,
    "spread_anomaly": 19, "relative_volume": 20,
    "liquidity_state": 21, "volatility_burst": 22,
    "trending": 23, "mean_reverting": 24, "bullish": 25, "bearish": 26,
    "high_vol": 27, "low_vol": 28, "strong_momentum": 29,
    "possible_reversal": 30, "liquidity_safe": 31,
    "chaos_regime": 32, "trend_following_habitat": 33,
    "breakout_habitat": 34, "mean_reversion_habitat": 35,
    "regime_name": 36,
    "entry_sl": 37, "entry_tp": 38,
    "risk_score": 39, "risk_direction": 40, "lot_multiplier": 41,
    "vix": 42, "dxy": 43, "sp500": 44, "yield_2y": 45, "yield_10y": 46,
    "vix_pct": 47, "dxy_pct": 48, "sp500_pct": 49,
    "yield_2y_pct": 50, "yield_10y_pct": 51,
    "yield_curve": 52, "is_high_vix": 53, "macro_profile": 54,
    "session_name": 55,
    "entry_hour": 56, "entry_minute": 57, "day_of_week": 58,
    "week_of_month": 59, "month": 60, "quarter": 61,
    "bid": 62, "ask": 63, "spread_at_exit": 64,
    "point_value": 65, "tick_value": 66, "tick_size": 67, "contract_size": 68,
    "balance": 69, "equity": 70, "free_margin": 71, "margin_level": 72,
    "dd_absolute": 73, "dd_relative": 74, "open_positions": 75,
    "close_m5": 76, "close_m15": 77, "close_h1": 78, "close_h4": 79, "close_d1": 80,
    "return_m5": 81, "return_m15": 82, "return_h1": 83, "return_h4": 84, "return_d1": 85,
    "mfe_points": 86, "mae_points": 87,
    "exit_time": 88, "exit_price": 89,
    "gross_profit": 90, "net_profit": 91, "commission": 92, "swap": 93,
    "duration_minutes": 94, "duration_bars": 95,
    "initial_risk": 96, "result_r": 97, "result_percent": 98,
    "profit_factor": 99, "mfe_r": 100, "mae_r": 101, "capture_ratio": 102,
    "exit_reason": 103, "trade_outcome": 104, "catastrophic": 105, "regime_at_exit": 106,
}

# Default Hurst bucket edges
DEFAULT_HURST_EDGES = [0.0, 0.43, 0.47, 0.50, 0.53, 0.57, 0.60, 0.68, 1.0]

# Semantic flag columns (binary 0/1)
SEMANTIC_FLAGS = [
    "trending", "mean_reverting", "bullish", "bearish",
    "high_vol", "low_vol", "strong_momentum", "possible_reversal",
    "liquidity_safe", "chaos_regime",
    "trend_following_habitat", "breakout_habitat", "mean_reversion_habitat",
]


def _safe_float(val: str) -> Optional[float]:
    """Convert string to float, returning None for empty/invalid values."""
    if not val or val.strip() == "":
        return None
    try:
        return float(val)
    except (ValueError, TypeError):
        return None


def _one_sample_t_test(values: List[float]) -> Tuple[float, bool]:
    """One-sample t-test against mean=0. Returns (p_value, significant_at_005)."""
    if len(values) < 2:
        return 1.0, False
    result = sp_stats.ttest_1samp(values, 0.0)
    p = float(result.pvalue)
    return p, (p < 0.05 and np_mean(values) > 0)


def np_mean(values: List[float]) -> float:
    """Simple mean without numpy dependency."""
    if not values:
        return 0.0
    return sum(values) / len(values)


def _compute_bucket_stats(
    trades: List[Dict[str, str]],
    min_sample: int,
    label: str = "",
    regime_name: str = "",
) -> BucketStats:
    """Compute statistics for a group of trades."""
    n = len(trades)
    if n == 0:
        return BucketStats(
            n=0, insufficient_sample=True,
            bucket_label=label, regime_name=regime_name,
        )

    result_r_vals = []
    capture_vals = []
    wins = 0
    catastrophic = 0

    for t in trades:
        r = _safe_float(t.get("result_r", ""))
        if r is not None:
            result_r_vals.append(r)
        c = _safe_float(t.get("capture_ratio", ""))
        if c is not None:
            capture_vals.append(c)
        if t.get("trade_outcome", "").strip().upper() == "WIN":
            wins += 1
        if t.get("catastrophic", "").strip() == "1":
            catastrophic += 1

    if n < min_sample:
        return BucketStats(
            n=n, insufficient_sample=True,
            bucket_label=label, regime_name=regime_name,
        )

    expectancy = np_mean(result_r_vals) if result_r_vals else None
    std = (sum((x - np_mean(result_r_vals)) ** 2 for x in result_r_vals) / max(len(result_r_vals) - 1, 1)) ** 0.5 if len(result_r_vals) > 1 else None
    win_rate = wins / n if n > 0 else None
    capture_mean = np_mean(capture_vals) if capture_vals else None
    cat_pct = catastrophic / n if n > 0 else None

    p_value = 1.0
    significant = False
    if result_r_vals and len(result_r_vals) >= 2:
        t_stat, p_value_raw = sp_stats.ttest_1samp(result_r_vals, 0.0)
        p_value = float(p_value_raw)
        significant = p_value < 0.05 and (expectancy or 0) > 0

    return BucketStats(
        n=n,
        insufficient_sample=False,
        expectancy_r=round(expectancy, 4) if expectancy is not None else None,
        std_r=round(std, 4) if std is not None else None,
        win_rate=round(win_rate, 4) if win_rate is not None else None,
        capture_ratio_mean=round(capture_mean, 4) if capture_mean is not None else None,
        p_value=round(p_value, 6),
        significant_5pct=significant,
        catastrophic_pct=round(cat_pct, 4) if cat_pct is not None else None,
        bucket_label=label,
        regime_name=regime_name,
    )


def _get_hurst_bucket(hurst_val: float, edges: List[float]) -> str:
    """Return the bucket label for a Hurst value."""
    for i in range(len(edges) - 1):
        if edges[i] <= hurst_val < edges[i + 1]:
            return f"{edges[i]:.2f}-{edges[i + 1]:.2f}"
    return f"{edges[-2]:.2f}-{edges[-1]:.2f}"


def aggregate(
    csv_path: str | Path,
    symbol: str = "",
    min_sample: int = 30,
    hurst_edges: Optional[List[float]] = None,
) -> DataminerSummary:
    """Aggregate DataMiner CSV into statistics per regime/Hurst/flag/session.

    Args:
        csv_path: Path to the DataMiner CSV file.
        symbol: Expected symbol to filter by (e.g. "XAUUSD").
        min_sample: Minimum trades per bucket for statistics.
        hurst_edges: Custom Hurst bucket edges.

    Returns:
        DataminerSummary with all computed statistics.
    """
    csv_path = Path(csv_path)
    if not csv_path.exists():
        raise FileNotFoundError(f"DataMiner CSV not found: {csv_path}")

    if hurst_edges is None:
        hurst_edges = DEFAULT_HURST_EDGES

    # Read CSV
    with open(csv_path, "r", encoding="utf-8", errors="replace") as f:
        raw_lines = f.readlines()

    if not raw_lines:
        raise ValueError(f"Empty CSV: {csv_path}")

    # Detect schema: check first line for version header
    first_line = raw_lines[0].strip()
    schema_version = "91col"
    header_line_idx = 0

    if first_line.startswith("#SCHEMA_VERSION"):
        parts = first_line.split(";")
        for p in parts:
            if p.startswith("#SCHEMA_VERSION="):
                schema_version = p.split("=")[1]
        header_line_idx = 1

    # Parse header
    header = raw_lines[header_line_idx].strip().split(";")
    col_count = len(header)
    logger.info(f"CSV schema: {schema_version}, {col_count} columns")

    if col_count < 90:
        logger.warning(f"CSV has only {col_count} columns, expected >=90. Some fields may be missing.")

    # Use column indices from SCHEMA_91 (name → index)
    col_map = SCHEMA_91

    # Parse data rows
    trades = []
    symbol_filtered = 0
    symbol_mismatch = False
    for line in raw_lines[header_line_idx + 1:]:
        line = line.strip()
        if not line:
            continue
        fields = line.split(";")
        if len(fields) < col_count:
            fields.extend([""] * (col_count - len(fields)))

        row = {}
        for name, idx in col_map.items():
            if idx < len(fields):
                row[name] = fields[idx].strip()
            else:
                row[name] = ""

        # Filter by symbol if specified
        csv_symbol = row.get("symbol", "").upper().strip()
        if symbol and csv_symbol and csv_symbol != symbol.upper():
            symbol_mismatch = True
            symbol_filtered += 1
            continue

        trades.append(row)

    warnings = []
    if symbol_mismatch and symbol_filtered > 0:
        warnings.append(
            f"Symbol mismatch: filtered out {symbol_filtered} trades "
            f"that are not {symbol.upper()}. CSV contains other symbols."
        )

    total = len(trades)
    date_range = ["", ""]
    if trades:
        times = [t.get("entry_time", "") for t in trades if t.get("entry_time")]
        if times:
            date_range = [min(times), max(times)]

    summary = DataminerSummary(
        symbol=symbol or "(unfiltered)",
        total_trades=total,
        date_range=date_range,
        schema_detected=schema_version,
        warnings=warnings,
    )

    if total == 0:
        warnings.append("No trades found after symbol filtering.")
        return summary

    # ── By Regime ──────────────────────────────────────────────────────────────
    regime_groups: Dict[str, List[Dict]] = {}
    for t in trades:
        regime = t.get("regime_name", "UNKNOWN").strip() or "UNKNOWN"
        regime_groups.setdefault(regime, []).append(t)

    for regime, group in sorted(regime_groups.items()):
        summary.by_regime[regime] = _compute_bucket_stats(
            group, min_sample, label=regime, regime_name=regime,
        )

    # ── By Hurst Bucket ────────────────────────────────────────────────────────
    hurst_groups: Dict[str, List[Dict]] = {}
    for t in trades:
        h = _safe_float(t.get("hurst", ""))
        if h is not None:
            bucket = _get_hurst_bucket(h, hurst_edges)
            hurst_groups.setdefault(bucket, []).append(t)
        else:
            hurst_groups.setdefault("no_data", []).append(t)

    for bucket, group in sorted(hurst_groups.items()):
        summary.by_hurst_bucket[bucket] = _compute_bucket_stats(
            group, min_sample, label=bucket,
        )

    # ── By Semantic Flag ───────────────────────────────────────────────────────
    for flag in SEMANTIC_FLAGS:
        if flag not in col_map:
            continue
        flag_1 = [t for t in trades if t.get(flag, "0").strip() == "1"]
        flag_0 = [t for t in trades if t.get(flag, "0").strip() == "0"]

        if flag_1:
            summary.by_semantic_flag[f"{flag}=1"] = _compute_bucket_stats(
                flag_1, min_sample, label=f"{flag}=1",
            )
        if flag_0:
            summary.by_semantic_flag[f"{flag}=0"] = _compute_bucket_stats(
                flag_0, min_sample, label=f"{flag}=0",
            )

    # ── By Session ─────────────────────────────────────────────────────────────
    session_groups: Dict[str, List[Dict]] = {}
    for t in trades:
        session = t.get("session_name", "UNKNOWN").strip() or "UNKNOWN"
        session_groups.setdefault(session, []).append(t)

    for session, group in sorted(session_groups.items()):
        summary.by_session[session] = _compute_bucket_stats(
            group, min_sample, label=session,
        )

    return summary
