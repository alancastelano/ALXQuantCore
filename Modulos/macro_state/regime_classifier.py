"""Economic regime classification + data-quality validation (deterministic)."""

from __future__ import annotations

# max acceptable age (hours) before a series is considered stale, by frequency
_FREQ_STALE_HOURS = {"D": 72, "W": 240, "M": 720, "Q": 1800, "A": 4000}


def validate(conn, economy: str, registry) -> dict:
    """Per-economy data quality: MISSING / STALE / OK counts + coverage."""
    from datetime import datetime
    now = datetime.utcnow()
    present = registry.available_indicators(economy)
    total = sum(len(registry.get_indicators(economy, d)) for d in registry.DIMENSIONS)
    ok = stale = missing = 0
    per = {}
    for dim, ind in present:
        sid = ind["series_id"]
        row = conn.execute(
            "SELECT MAX(date) FROM macro_series WHERE symbol = ?", [sid]
        ).fetchone()
        last = row[0] if row else None
        if not last:
            missing += 1
            per[sid] = "MISSING"
            continue
        try:
            ld = datetime.fromisoformat(last)
        except Exception:
            ld = None
        age_h = (now - ld).total_seconds() / 3600.0 if ld else 1e9
        thr = _FREQ_STALE_HOURS.get(ind["freq"], 720)
        if age_h > thr:
            stale += 1
            per[sid] = "STALE"
        else:
            ok += 1
            per[sid] = "OK"

    # indicators whose series_id is None are also MISSING
    missing += total - len(present)
    coverage = (ok / total) if total else 0.0

    if total == 0 or ok == 0:
        status = "NO DATA"
    elif stale and ok == 0:
        status = "STALE"
    elif coverage < 0.5 or stale:
        status = "PARTIAL"
    else:
        status = "OK"

    return {
        "status": status,
        "coverage": round(coverage, 3),
        "freshness": round(_compute_freshness(per), 3),
        "ok": ok,
        "stale": stale,
        "missing": missing,
        "total": total,
        "per_symbol": per,
    }


def _compute_freshness(per_symbol: dict) -> float:
    """Data freshness [0.0, 1.0]: OK=1.0, STALE=0.5, MISSING=0.0."""
    if not per_symbol:
        return 0.0
    vals = {"OK": 1.0, "STALE": 0.5, "MISSING": 0.0}
    scores = [vals.get(v, 0.0) for v in per_symbol.values()]
    return sum(scores) / len(scores) if scores else 0.0


def classify(dim_results: dict) -> str:
    """Rule-based regime from the 5 dimension scores (-1..1).

    dim_results: {dimension: (score, state, detail)}
    """
    def sc(d):
        v = dim_results.get(d, (None, "", {}))[0]
        return v if v is not None else 0.0

    growth = sc("growth")
    labor = sc("labor")
    infl = sc("inflation")
    fin = sc("financial_conditions")
    rec = sc("recession")

    if rec <= -0.33 or (dim_results.get("recession", (None, "", {}))[1] in ("Recession Risk",)):
        return "CONTRACTION"
    if growth < -0.10 and fin < -0.10:
        return "SLOWDOWN"
    if growth > 0.10 and infl > 0.10 and fin <= 0.10:
        return "LATE CYCLE"
    if growth > 0.10 and fin > 0.10:
        return "EXPANSION"
    if growth >= -0.10 and growth <= 0.10:
        return "MID-CYCLE"
    return "NEUTRAL"


def classify_with_confidence(dim_results: dict) -> tuple[str, int | None]:
    """Regime classification with confidence score (0-100).

    Confidence is heuristic: based on the distance of the growth score
    to the nearest regime boundary. Far from boundaries = high confidence.
    Returns (regime, confidence_pct) or (regime, None) if insufficient data.
    """
    regime = classify(dim_results)
    growth = (dim_results.get("growth") or (None, "", {}))[0]
    if growth is None:
        return regime, None

    # Regime boundaries on the growth score axis
    _BOUNDARIES = [-0.33, -0.10, 0.10, 0.33]
    distances = [abs(growth - b) for b in _BOUNDARIES]
    min_dist = min(distances) if distances else 0.0
    # Scale: 0.0 → 0%, 0.20+ → 100%
    confidence = min(100, int(min_dist / 0.20 * 100))
    return regime, confidence


def compute_momentum_simple(dim_results: dict) -> str | None:
    """Momentum simplificado: resume o viés das dimensões atuais.

    Baseado em quantas dimensões estão positivas vs negativas.
    Honesto: não compara com dados históricos (que não existem).
    Returns: "IMPROVING" | "STABLE" | "WEAKENING" | None
    """
    positive = 0
    negative = 0
    for dim in ("growth", "labor", "inflation", "financial_conditions", "recession"):
        score = (dim_results.get(dim) or (None, "", {}))[0]
        if score is None:
            continue
        if score > 0.10:
            positive += 1
        elif score < -0.10:
            negative += 1

    total = positive + negative
    if total == 0:
        return None
    if positive > negative + 1:
        return "IMPROVING"
    if negative > positive + 1:
        return "WEAKENING"
    return "STABLE"


def compute_stability(dim_results: dict, regime: str) -> str | None:
    """Regime stability: quão estável é o regime atual.

    Baseado na distância do score de growth ao boundary do regime.
    Longe do boundary = HIGH stability, perto = LOW.
    Returns: "HIGH" | "MEDIUM" | "LOW" | None
    """
    growth = (dim_results.get("growth") or (None, "", {}))[0]
    if growth is None:
        return None

    # Regime boundary on the growth axis
    _REGIME_BOUNDARY = {
        "CONTRACTION": -0.33, "SLOWDOWN": -0.10,
        "MID-CYCLE": 0.10, "EXPANSION": 0.33,
        "LATE CYCLE": 0.33, "NEUTRAL": 0.0,
    }
    boundary = _REGIME_BOUNDARY.get(regime, 0.0)
    dist = abs(growth - boundary)
    if dist > 0.15:
        return "HIGH"
    if dist > 0.05:
        return "MEDIUM"
    return "LOW"
