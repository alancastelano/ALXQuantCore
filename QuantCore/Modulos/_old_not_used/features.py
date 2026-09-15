"""
Feature mapping for EAQuant_IA_v1 MLP (15->12->3).
Matches FeatureExtractor.mqh normalization bounds.
"""

NN_INPUTS = 15
NN_HIDDEN = 12
NN_OUTPUTS = 3

FEATURE_COLS = [
    # (csv_column, raw_min, raw_max, description)
    ("Hurst",             0.0,   1.0,   "Hurst exponent"),
    ("Confidence_R2",     0.0,   1.0,   "DFA confidence R^2"),
    ("MomentumState",    -2.0,   2.0,   "Momentum state"),
    ("VIX_Level",         0.0,  50.0,   "VIX close price"),
    ("SpreadAnomaly",     0.0,  10.0,   "Spread anomaly z-score"),
    ("RiskScore",        -3.0,   3.0,   "RiskOn score"),
    ("DXY_ZScore",       -3.0,   3.0,   "DXY z-score"),
    ("MR_ZScore",        -5.0,   5.0,   "Mean reversion z-score"),
    ("ATR_Price",         0.0,   0.1,   "ATR / entry price"),
    ("CurrentDrawdownPercent", 0.0, 0.5, "Drawdown from peak"),
    ("DayOfWeek",         0.0,   6.0,   "Day of week (0=Sun)"),
    ("EntryHour",         0.0,  23.0,   "Hour of day"),
    ("StrategyID",        0.0,   1.0,   "Strategy ID (always 1)"),
    ("Session",           0.0,   2.0,   "Session (0=Asia 1=London 2=NY)"),
    ("FreeMarginRatio",   0.0,   1.0,   "Free margin / balance"),
]


def extract_features(row):
    """Extract raw feature vector from a CSV row dict.
    Returns list of 15 float values.
    """
    feats = []
    for col, mn, mx, _desc in FEATURE_COLS:
        raw = float(row.get(col, 0.0))
        feats.append(raw)
    return feats


def normalize(feats):
    """Min-max normalize features to [0, 1] using FeatureExtractor bounds."""
    norm = []
    for i, (val, (_, mn, mx, _)) in enumerate(zip(feats, FEATURE_COLS)):
        rng = mx - mn
        if rng > 0:
            n = (val - mn) / rng
        else:
            n = 0.0
        norm.append(max(0.0, min(1.0, n)))
    return norm


def denormalize(norm_feats):
    """Reverse normalization (for debugging)."""
    raw = []
    for i, (n, (_, mn, mx, _)) in enumerate(zip(norm_feats, FEATURE_COLS)):
        rng = mx - mn
        raw.append(n * rng + mn)
    return raw


def compute_target(row):
    """Compute training targets from trade outcome.
    Returns [direction_bias, confidence, sizing_mult].

    Targets are derived from ResultR (R multiple):
    - target[0]: direction bias, scaled by R strength
    - target[1]: confidence, proportional to |R|
    - target[2]: sizing multiplier, proportional to |R|
    """
    direction = row.get("Direction", "BUY")
    net_profit = float(row.get("NetProfit", 0.0))
    result_r = float(row.get("ResultR", 0.0))

    dir_sign = 1.0 if direction == "BUY" else -1.0
    abs_r = abs(result_r)

    # target[0]: direction bias (same as online: direction if win, 0 if loss)
    t0 = dir_sign * (1.0 if net_profit > 0 else 0.0)

    # target[1]: confidence (same structure as online: proportional to |R|)
    # R = 0  → 0.0, R = 3  → 1.0, capped at 1.0
    t1 = min(abs_r / 3.0, 1.0)

    # target[2]: sizing multiplier
    t2 = 1.0 if net_profit > 0 else 0.5

    return [t0, t1, t2]
