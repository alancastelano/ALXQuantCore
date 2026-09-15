"""Macro Registry — central mapping of economies -> dimensions -> indicators.

Read-only specification layer. The raw indicator values live in the DATAHOUSE
(`macro_series` / `macro_catalog`, the single source of truth). `catalog_spec()`
declares which FRED series each economy/dimension needs so the datahouse can register
and collect them; `economic_state` reads `macro_series` (read_only) to compute.

Design rules (from the project spec):
  * No invented data. If `series_id` is None the indicator is reported MISSING.
  * Each economy has its own weights / targets / directions (no copy-paste of USA).
  * `direction`: +1 = higher raw value is *better* for the economy;
                -1 = higher raw value is *worse*; 0 = neutral / mixed.
"""

from __future__ import annotations

# economy label -> 2-letter code used in macro_catalog.country
ECONOMY_CODE = {
    "USA": "US",
    "EURO AREA": "EU",
    "JAPAN": "JP",
    "CHINA": "CN",
    "BRAZIL": "BR",
}
CODE_ECONOMY = {v: k for k, v in ECONOMY_CODE.items()}

# Configurable inflation targets (fraction, e.g. 0.02 = 2%)
INFLATION_TARGETS = {
    "USA": 0.02,
    "EURO AREA": 0.02,
    "JAPAN": 0.02,
    "CHINA": 0.03,
    "BRAZIL": 0.035,
}

# Configurable dimension weights per economy (initial, documented as parameters).
MACRO_WEIGHTS = {
    "USA":       {"growth": 0.25, "labor": 0.20, "inflation": 0.20, "financial_conditions": 0.20, "recession": 0.15},
    "EURO AREA": {"growth": 0.25, "labor": 0.20, "inflation": 0.20, "financial_conditions": 0.20, "recession": 0.15},
    "JAPAN":     {"growth": 0.25, "labor": 0.20, "inflation": 0.20, "financial_conditions": 0.20, "recession": 0.15},
    "CHINA":     {"growth": 0.30, "labor": 0.15, "inflation": 0.20, "financial_conditions": 0.15, "recession": 0.20},
    "BRAZIL":    {"growth": 0.25, "labor": 0.15, "inflation": 0.25, "financial_conditions": 0.20, "recession": 0.15},
}

# Global aggregate weights per economy (importance in the global state).
GLOBAL_WEIGHTS = {
    "USA": 0.40,
    "EURO AREA": 0.25,
    "CHINA": 0.20,
    "JAPAN": 0.10,
    "BRAZIL": 0.05,
}

# Indicator registry.
# Each entry: name -> dict(source, series_id, freq, unit, direction, transform, target)
# series_id None => indicator not available from current sources => MISSING.
ECONOMY_INDICATORS = {
    "USA": {
        "growth": [
            dict(name="GDP_YOY", source="FRED", series_id="GDPC1", freq="Q", unit="%", direction=1, transform="yoy"),
            dict(name="INDPRO", source="FRED", series_id="INDPRO", freq="M", unit="%", direction=1, transform="yoy"),
            dict(name="RETAIL", source="FRED", series_id="RSAFS", freq="M", unit="%", direction=1, transform="yoy"),
        ],
        "labor": [
            dict(name="UNRATE", source="FRED", series_id="UNRATE", freq="M", unit="%", direction=-1, transform="level"),
            dict(name="PAYEMS", source="FRED", series_id="PAYEMS", freq="M", unit="%", direction=1, transform="yoy"),
            dict(name="ICSA", source="FRED", series_id="ICSA", freq="W", unit="k", direction=-1, transform="yoy"),
            dict(name="JOLTS", source="FRED", series_id="JTSJOL", freq="M", unit="M", direction=1, transform="yoy"),
        ],
        "inflation": [
            dict(name="CPI", source="FRED", series_id="CPIAUCSL", freq="M", unit="%", direction=-1, transform="yoy", target=0.02),
            dict(name="CORE_CPI", source="FRED", series_id="CPILFESL", freq="M", unit="%", direction=-1, transform="yoy", target=0.02),
            dict(name="PCE", source="FRED", series_id="PCEPI", freq="M", unit="%", direction=-1, transform="yoy", target=0.02),
            dict(name="CORE_PCE", source="FRED", series_id="PCEDG", freq="M", unit="%", direction=-1, transform="yoy", target=0.02),
            dict(name="PPI", source="FRED", series_id="PPIACO", freq="M", unit="%", direction=-1, transform="yoy"),
            dict(name="WAGE", source="FRED", series_id="ECIWAG", freq="Q", unit="%", direction=-1, transform="yoy"),
        ],
        "financial_conditions": [
            dict(name="FEDFUNDS", source="FRED", series_id="FEDFUNDS", freq="D", unit="%", direction=-1, transform="level"),
            dict(name="DGS2", source="FRED", series_id="DGS2", freq="D", unit="%", direction=-1, transform="level"),
            dict(name="DGS10", source="FRED", series_id="DGS10", freq="D", unit="%", direction=-1, transform="level"),
            dict(name="T10Y2Y", source="FRED", series_id="T10Y2Y", freq="D", unit="%", direction=-1, transform="level"),
            dict(name="HY_SPREAD", source="FRED", series_id="BAMLH0A0HYM2", freq="D", unit="bp", direction=-1, transform="level"),
            dict(name="VIX", source="FRED", series_id="VIXCLS", freq="D", unit="idx", direction=-1, transform="level"),
            dict(name="DXY", source="FRED", series_id="DTWEXBGS", freq="D", unit="idx", direction=0, transform="level"),
        ],
        "recession": [
            dict(name="UNRATE", source="FRED", series_id="UNRATE", freq="M", unit="%", direction=-1, transform="level"),
            dict(name="PAYEMS", source="FRED", series_id="PAYEMS", freq="M", unit="%", direction=1, transform="yoy"),
            dict(name="INDPRO", source="FRED", series_id="INDPRO", freq="M", unit="%", direction=1, transform="yoy"),
            dict(name="T10Y2Y", source="FRED", series_id="T10Y2Y", freq="D", unit="%", direction=-1, transform="level"),
            dict(name="HY_SPREAD", source="FRED", series_id="BAMLH0A0HYM2", freq="D", unit="bp", direction=-1, transform="level"),
        ],
    },
    "EURO AREA": {
        "growth": [
            dict(name="CPI", source="FRED", series_id="CP0000EZ19M086NEST", freq="M", unit="%", direction=-1, transform="yoy", target=0.02),
        ],
        "labor": [],
        "inflation": [
            dict(name="CPI", source="FRED", series_id="CP0000EZ19M086NEST", freq="M", unit="%", direction=-1, transform="yoy", target=0.02),
        ],
        "financial_conditions": [],
        "recession": [],
    },
    "JAPAN": {
        "growth": [
            dict(name="GDP Deflator", source="FRED", series_id="NGDPDSAIXJPQ", freq="Q", unit="%", direction=-1, transform="yoy", target=0.02),
        ],
        "labor": [
            dict(name="Employment", source="FRED", series_id="JPNCETRILSMEI", freq="M", unit="index", direction=1, transform="diff", target=0),
        ],
        "inflation": [
            dict(name="CPI", source="FRED", series_id="JPNCPIALLMINMEI", freq="M", unit="%", direction=-1, transform="yoy", target=0.02),
        ],
        "financial_conditions": [
            dict(name="10Y Yield", source="FRED", series_id="IRLTLT01JPM156N", freq="M", unit="%", direction=-1, transform="level", target=0),
        ],
        "recession": [],
    },
    "CHINA": {
        "growth": [
            dict(name="CPI", source="FRED", series_id="CHNCPIALLMINMEI", freq="M", unit="%", direction=-1, transform="yoy", target=0.03),
        ],
        "labor": [],
        "inflation": [
            dict(name="CPI", source="FRED", series_id="CHNCPIALLMINMEI", freq="M", unit="%", direction=-1, transform="yoy", target=0.03),
        ],
        "financial_conditions": [],
        "recession": [],
    },
    "BRAZIL": {
        "growth": [
            dict(name="IBC_BR", source="BCB", series_id="IBC_BR", fred_code="28771", freq="M", unit="idx", direction=1, transform="yoy"),
        ],
        "labor": [
            dict(name="UNEMPLOYMENT", source="BCB", series_id="UNEMPLOYMENT", fred_code="24369", freq="M", unit="%", direction=-1, transform="level"),
        ],
        "inflation": [
            dict(name="IPCA", source="BCB", series_id="IPCA", fred_code="433", freq="M", unit="%", direction=-1, transform="level", target=0.035),
        ],
        "financial_conditions": [
            dict(name="SELIC", source="BCB", series_id="SELIC", fred_code="432", freq="D", unit="%", direction=-1, transform="level"),
            dict(name="USDBRL", source="BCB", series_id="USDBRL", fred_code="1", freq="D", unit="BRL", direction=0, transform="level"),
        ],
        "recession": [
            dict(name="IBC_BR", source="BCB", series_id="IBC_BR", fred_code="28771", freq="M", unit="idx", direction=1, transform="yoy"),
            dict(name="UNEMPLOYMENT", source="BCB", series_id="UNEMPLOYMENT", fred_code="24369", freq="M", unit="%", direction=-1, transform="level"),
        ],
    },
}

DIMENSIONS = ["growth", "labor", "inflation", "financial_conditions", "recession"]


def list_economies():
    return list(ECONOMY_INDICATORS.keys())


def get_indicators(economy: str, dimension: str):
    return ECONOMY_INDICATORS.get(economy, {}).get(dimension, [])


def get_indicator(economy: str, indicator_name: str):
    for dim in DIMENSIONS:
        for ind in get_indicators(economy, dim):
            if ind["name"] == indicator_name:
                return ind
    return None


def available_indicators(economy: str):
    """Indicators that have a resolvable series_id (not MISSING)."""
    out = []
    for dim in DIMENSIONS:
        for ind in get_indicators(economy, dim):
            if ind.get("series_id"):
                out.append((dim, ind))
    return out


def catalog_spec():
    """Spec de series macro por economia para o DATAHOUSE registrar em macro_catalog.

    O macro_state NAO escreve no catalog nem coleta dados: apenas declara o que
    precisa. O datahouse (Modulos/datahouse/engine._upsert_macro_economy_assets)
    consome este spec e faz o upsert idempotente em macro_catalog
    (collector='FRED', target_table='macro_series'). As series sao entao coletadas
    pelo pipeline do datahouse (readiness.refresh_macro_assets) e lidas do
    macro_series pelo macro_state em modo read-only.

    series_id == fred_code; symbols sem series_id (ex.: Brasil) ficam de fora
    (macro_state reporta MISSING honesto; collector BCB seria um seguimento do datahouse).
    """
    rows = []
    for economy, dims in ECONOMY_INDICATORS.items():
        country = ECONOMY_CODE.get(economy, "--")
        for dim, inds in dims.items():
            for ind in inds:
                sid = ind.get("series_id")
                if not sid:
                    continue
                rows.append(dict(
                    symbol=sid,
                    name=ind["name"],
                    category="macro_state",
                    subcategory=dim,
                    country=country,
                    frequency=ind["freq"],
                    source=ind["source"],
                    unit=ind["unit"],
                    description=f"{economy} {dim} {ind['name']}",
                    fred_code=sid,
                    target=ind.get("target"),
                ))
    return rows
