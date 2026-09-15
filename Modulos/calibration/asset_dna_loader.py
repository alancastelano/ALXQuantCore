"""Asset DNA JSON loader - extracts calibration-relevant fields.

Reads asset_profile_{symbol}_{tf}.json and returns a trimmed dict
with only the sections relevant for MacroRegimeEngine calibration.
"""

from __future__ import annotations
import json
import math
import logging
from pathlib import Path
from typing import Any, Dict, Optional

from .schemas import AssetDNAContext

logger = logging.getLogger(__name__)


def _sanitize(obj: Any) -> Any:
    """Convert NaN/Inf to None for JSON safety."""
    if isinstance(obj, float) and (math.isnan(obj) or math.isinf(obj)):
        return None
    if isinstance(obj, dict):
        return {k: _sanitize(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_sanitize(v) for v in obj]
    return obj


def _get_nested(data: Dict, *keys, default=None):
    """Safely navigate nested dicts."""
    current = data
    for k in keys:
        if isinstance(current, dict):
            current = current.get(k, default)
        else:
            return default
    return current


def load_asset_dna(
    json_path: str | Path,
    symbol: str = "",
    timeframe: str = "M5",
) -> AssetDNAContext:
    """Load and trim Asset DNA JSON for calibration context.

    Args:
        json_path: Path to asset_profile JSON.
        symbol: Expected symbol (for validation).
        timeframe: Expected timeframe.

    Returns:
        AssetDNAContext with trimmed fields.
    """
    json_path = Path(json_path)
    if not json_path.exists():
        raise FileNotFoundError(f"Asset DNA JSON not found: {json_path}")

    with open(json_path, "r", encoding="utf-8") as f:
        raw = json.load(f)

    raw = _sanitize(raw)

    # Validate symbol/timeframe if present
    meta = raw.get("meta", {})
    if symbol and meta.get("symbol", "").upper() != symbol.upper():
        logger.warning(
            f"JSON symbol '{meta.get('symbol')}' != requested '{symbol}'"
        )
    if timeframe and meta.get("timeframe", "").upper() != timeframe.upper():
        logger.warning(
            f"JSON timeframe '{meta.get('timeframe')}' != requested '{timeframe}'"
        )

    ctx = AssetDNAContext(
        symbol=meta.get("symbol", symbol),
        timeframe=meta.get("timeframe", timeframe),
        regime_profile=raw.get("regime_profile"),
        regime_thresholds=_get_nested(raw, "mql5_directives", "regime_thresholds"),
        dfa_recommendation=raw.get("dfa_recommendation"),
        strategy_fit=raw.get("strategy_fit"),
        hmm_model=raw.get("hmm_model"),
        transition_matrix=raw.get("transition_matrix"),
        pbo={
            "mean_reversion": raw.get("pbo_mean_reversion", 0),
            "breakout": raw.get("pbo_breakout", 0),
        },
        stability=raw.get("stability"),
        statistical_significance=raw.get("statistical_significance"),
    )

    logger.info(
        f"Loaded Asset DNA for {ctx.symbol} {ctx.timeframe}: "
        f"dominant={ctx.regime_profile.get('dominant') if ctx.regime_profile else 'N/A'}"
    )
    return ctx


def load_asset_dna_raw(json_path: str | Path) -> Dict[str, Any]:
    """Load the full JSON and return sanitized dict (for prompt context)."""
    json_path = Path(json_path)
    if not json_path.exists():
        raise FileNotFoundError(f"Asset DNA JSON not found: {json_path}")

    with open(json_path, "r", encoding="utf-8") as f:
        raw = json.load(f)

    return _sanitize(raw)
