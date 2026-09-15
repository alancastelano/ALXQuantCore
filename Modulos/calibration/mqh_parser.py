"""MacroRegimeEngine.mqh parser - extracts calibratable parameters.

Uses regex to extract input parameters, SAssetProfile fields,
BuildDefaultProfile() assignments, and classification thresholds
from the MQL5 source code.
"""

from __future__ import annotations
import re
import logging
from pathlib import Path
from typing import List, Optional

from .schemas import ParameterEntry

logger = logging.getLogger(__name__)

# ── Regex patterns ─────────────────────────────────────────────────────────────

# input TYPE NAME = VALUE;
RE_INPUT = re.compile(
    r'input\s+(\w+)\s+(\w+)\s*=\s*([^;]+);',
    re.MULTILINE,
)

# Struct fields inside SAssetProfile: TYPE field;
RE_STRUCT_FIELD = re.compile(
    r'^\s+(\w+)\s+(\w+)\s*;',
    re.MULTILINE,
)

# Assignments in BuildDefaultProfile(): field = value;
RE_ASSIGNMENT = re.compile(
    r'(\w+)\s*=\s*([^;]+);',
    re.MULTILINE,
)

# Numeric literals in classification methods
RE_NUMERIC = re.compile(r'\b(\d+\.?\d*)\b')


def _parse_value(val_str: str):
    """Parse a MQL5 value string to Python."""
    val_str = val_str.strip()
    if val_str.lower() == "true":
        return True
    if val_str.lower() == "false":
        return False
    if val_str.startswith('"') and val_str.endswith('"'):
        return val_str[1:-1]
    try:
        if "." in val_str:
            return float(val_str)
        return int(val_str)
    except ValueError:
        return val_str


def _extract_section(source: str, start_pattern: str, brace_depth: int = 1) -> str:
    """Extract a code section between braces starting from a pattern match."""
    match = re.search(start_pattern, source, re.MULTILINE)
    if not match:
        return ""

    start = match.end()
    depth = 0
    in_section = False
    for i in range(start, len(source)):
        if source[i] == "{":
            depth += 1
            in_section = True
        elif source[i] == "}":
            depth -= 1
            if in_section and depth < brace_depth:
                return source[start:i]
    return source[start:start + 5000]


def parse_mqh(mqh_path: str | Path) -> List[ParameterEntry]:
    """Parse MacroRegimeEngine.mqh and extract calibratable parameters.

    Args:
        mqh_path: Path to the .mqh file.

    Returns:
        List of ParameterEntry with all calibratable parameters.
    """
    mqh_path = Path(mqh_path)
    if not mqh_path.exists():
        raise FileNotFoundError(f"MQH file not found: {mqh_path}")

    source = mqh_path.read_text(encoding="utf-8", errors="replace")
    params: List[ParameterEntry] = []
    seen = set()

    # ── 1. Input parameters ────────────────────────────────────────────────────
    for m in RE_INPUT.finditer(source):
        type_name, param_name, val_str = m.group(1), m.group(2), m.group(3)
        line = source[:m.start()].count("\n") + 1
        value = _parse_value(val_str)

        # Determine if calibratable (skip booleans that are master switches)
        calibratable = True
        desc = ""
        if param_name == "InpMacroRegime":
            calibratable = False
            desc = "Master switch to enable/disable regime engine"
        elif param_name == "InpSpreadAnomaly":
            calibratable = False
            desc = "Enable/disable spread anomaly filter"
        elif param_name == "InpRelativeVolume":
            calibratable = False
            desc = "Enable/disable relative volume filter"
        elif param_name == "InpRegimeTimeframe":
            calibratable = False
            desc = "Timeframe for regime calculations"
        else:
            desc = f"Input parameter: {param_name}"

        if param_name not in seen:
            params.append(ParameterEntry(
                param=param_name,
                current_value=value,
                value_type=type_name,
                location="input",
                line=line,
                description=desc,
                calibratable=calibratable,
            ))
            seen.add(param_name)

    # ── 2. SAssetProfile struct fields ─────────────────────────────────────────
    struct_section = _extract_section(source, r"struct\s+SAssetProfile")
    for m in RE_STRUCT_FIELD.finditer(struct_section):
        type_name, field_name = m.group(1), m.group(2)
        if field_name in ("asset_class", "class_name") or field_name in seen:
            continue
        line = source[:m.start()].count("\n") + 1
        params.append(ParameterEntry(
            param=field_name,
            current_value=None,  # Will be set by BuildDefaultProfile
            value_type=type_name,
            location="SAssetProfile",
            line=line,
            description=f"Asset profile field: {field_name}",
            calibratable=True,
        ))
        seen.add(field_name)

    # ── 3. BuildDefaultProfile() assignments ───────────────────────────────────
    build_section = _extract_section(source, r"SAssetProfile\s+CMacroRegimeEngine::BuildDefaultProfile")
    # Match both "field = value;" and "p.field = value;" (struct prefix)
    re_assignment_extended = re.compile(
        r'(?:p\.|m_profile\.|profile\.)?(\w+)\s*=\s*([^;]+);',
        re.MULTILINE,
    )
    for m in re_assignment_extended.finditer(build_section):
        field_name, val_str = m.group(1), m.group(2)
        if field_name in ("asset_class", "class_name", "return"):
            continue
        value = _parse_value(val_str)

        # Update existing param or create new
        found = False
        for p in params:
            if p.param == field_name and p.location == "SAssetProfile":
                p.current_value = value
                p.location = "BuildDefaultProfile()"
                found = True
                break
        if not found and field_name not in seen:
            params.append(ParameterEntry(
                param=field_name,
                current_value=value,
                value_type="double",
                location="BuildDefaultProfile()",
                description=f"Profile default: {field_name}",
                calibratable=True,
            ))
            seen.add(field_name)

    # ── 4. Hardcoded thresholds in classification methods ──────────────────────
    methods_to_scan = {
        "IsTrendFollowingRegime": "Classification: trend following",
        "IsMeanReversionRegime": "Classification: mean reversion",
        "IsBreakoutRegime": "Classification: breakout",
        "IsChaosRegime": "Classification: chaos",
        "GetRegimeScore": "Scoring: regime score",
        "CalcMomentumStateRaw": "Scoring: momentum state",
        "GetLiquidityState": "Classification: liquidity state",
        "isLowVol": "Classification: low volatility",
    }

    for method_name, desc in methods_to_scan.items():
        section = _extract_section(source, rf"(?:bool|double|int)\s+CMacroRegimeEngine::{method_name}")
        if not section:
            continue

        for m in RE_NUMERIC.finditer(section):
            val = _parse_value(m.group(1))
            if isinstance(val, (int, float)) and 0 < abs(val) < 100:
                param_name = f"{method_name}_const_{m.group(1)}"
                if param_name not in seen:
                    line = source[:m.start()].count("\n") + 1
                    params.append(ParameterEntry(
                        param=param_name,
                        current_value=val,
                        value_type="constant",
                        location=f"{method_name}()",
                        line=line,
                        description=f"Hardcoded constant in {desc}",
                        calibratable=True,
                    ))
                    seen.add(param_name)

    # ── 5. Per-asset-class overrides ───────────────────────────────────────────
    # Find symbol matching blocks (METAL, CRYPTO, INDEX)
    asset_overrides = {
        "XAU": "METAL", "GOLD": "METAL",
        "BTC": "CRYPTO", "ETH": "CRYPTO",
        "SP500": "INDEX", "NAS": "INDEX",
    }

    for symbol_match, class_name in asset_overrides.items():
        pattern = re.compile(
            rf'(?:StringFind|Contains).*"{symbol_match}".*?\n(.*?)(?=\n\s*(?:else|return|//|$))',
            re.DOTALL,
        )
        block_match = pattern.search(build_section)
        if block_match:
            block = block_match.group(1)
            for m in RE_ASSIGNMENT.finditer(block):
                field_name, val_str = m.group(1), m.group(2)
                if field_name in ("asset_class", "class_name"):
                    continue
                value = _parse_value(val_str)
                override_param = f"{class_name}_{field_name}"
                if override_param not in seen:
                    params.append(ParameterEntry(
                        param=override_param,
                        current_value=value,
                        value_type="double",
                        location=f"BuildDefaultProfile() [{class_name}]",
                        description=f"Override for {class_name}: {field_name}",
                        calibratable=True,
                    ))
                    seen.add(override_param)

    logger.info(f"Parsed {len(params)} parameters from {mqh_path.name}")
    return params


def get_classification_logic(mqh_path: str | Path) -> str:
    """Extract the classification methods source code for LLM context.

    Returns the relevant methods as a string for prompt injection.
    """
    mqh_path = Path(mqh_path)
    source = mqh_path.read_text(encoding="utf-8", errors="replace")

    methods = []
    for method in [
        "IsChaosRegime", "IsTrendFollowingRegime",
        "IsMeanReversionRegime", "IsBreakoutRegime",
        "GetRegimeScore", "ClassifyRegime",
        "isTrending", "isMeanReverting",
    ]:
        section = _extract_section(
            source, rf"(?:bool|double|ENUM_REGIME_STATE)\s+CMacroRegimeEngine::{method}"
        )
        if section:
            methods.append(f"// ── {method}() ──\n{method}() {{{section}}}")

    return "\n\n".join(methods)
