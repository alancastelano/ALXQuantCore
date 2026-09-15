"""Global Macro Economic State module.

Read-only computation layer over the DataHouse. Raw series live in the datahouse
(`macro_series` / `macro_catalog`); `economic_state` reads them (read_only) and
computes scores/regimes. The module never collects or persists data.

Public API:
    from Modulos.macro_state import get_state, compute_global, compute_economy
"""

from __future__ import annotations

from . import registry, engines, economic_state
from .economic_state import get_state, compute_global, compute_economy
from .engine import run

__all__ = [
    "registry", "engines", "economic_state",
    "get_state", "compute_global", "compute_economy", "run",
]
