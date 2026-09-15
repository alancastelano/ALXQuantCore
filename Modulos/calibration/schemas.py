"""Pydantic models for the calibration agent input/output."""

from __future__ import annotations
from typing import Any, Dict, List, Literal, Optional
from pydantic import BaseModel, Field


class BucketStats(BaseModel):
    """Statistics for a single data bucket (regime, Hurst range, etc.)."""
    n: int
    insufficient_sample: bool = False
    expectancy_r: Optional[float] = None
    std_r: Optional[float] = None
    win_rate: Optional[float] = None
    capture_ratio_mean: Optional[float] = None
    p_value: Optional[float] = None
    significant_5pct: Optional[bool] = None
    catastrophic_pct: Optional[float] = None
    regime_name: Optional[str] = None
    bucket_label: Optional[str] = None


class DataminerSummary(BaseModel):
    """Deterministic summary of DataMiner CSV (no LLM)."""
    symbol: str
    total_trades: int
    date_range: List[str] = Field(default_factory=list)
    schema_detected: str
    by_regime: Dict[str, BucketStats] = Field(default_factory=dict)
    by_hurst_bucket: Dict[str, BucketStats] = Field(default_factory=dict)
    by_semantic_flag: Dict[str, BucketStats] = Field(default_factory=dict)
    by_session: Dict[str, BucketStats] = Field(default_factory=dict)
    warnings: List[str] = Field(default_factory=list)


class AssetDNAContext(BaseModel):
    """Trimmed fields from asset_profile JSON for calibration."""
    symbol: str
    timeframe: str
    regime_profile: Optional[Dict[str, Any]] = None
    regime_thresholds: Optional[Dict[str, float]] = None
    dfa_recommendation: Optional[Dict[str, Any]] = None
    strategy_fit: Optional[Dict[str, float]] = None
    hmm_model: Optional[Dict[str, Any]] = None
    transition_matrix: Optional[Dict[str, float]] = None
    pbo: Optional[Dict[str, float]] = None
    stability: Optional[Dict[str, float]] = None
    statistical_significance: Optional[Dict[str, Any]] = None


class ParameterEntry(BaseModel):
    """A single calibratable parameter from MacroRegimeEngine.mqh."""
    param: str
    current_value: Any
    value_type: str = "float"
    location: str
    line: int = 0
    description: str = ""
    calibratable: bool = True


class Suggestion(BaseModel):
    """A single calibration suggestion from the LLM."""
    param: str
    location: str
    current_value: str
    suggested_value: str
    tipo: Literal["ajuste_dentro_da_amostra", "extrapolacao_teorica"]
    confidence: Literal["low", "medium", "high"]
    based_on_dataminer_bucket: Optional[str] = None
    based_on_dataminer_stats: Optional[Dict[str, Any]] = None
    based_on_asset_dna_field: Optional[str] = None
    reasoning: str


class Divergence(BaseModel):
    """A divergence between asset_dna and dataminer findings."""
    topic: str
    asset_dna_says: str
    dataminer_says: str
    recommendation: str


class InsufficientEvidence(BaseModel):
    """A parameter that cannot be calibrated due to lack of data."""
    param: str
    reason: str


class CalibrationOutput(BaseModel):
    """Full output of the calibration agent."""
    meta: Dict[str, Any]
    suggestions: List[Suggestion] = Field(default_factory=list)
    divergences: List[Divergence] = Field(default_factory=list)
    insufficient_evidence: List[InsufficientEvidence] = Field(default_factory=list)
