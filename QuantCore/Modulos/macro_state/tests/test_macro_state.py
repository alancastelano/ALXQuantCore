"""Tests for the Global Macro Economic State module (deterministic, no network)."""

from __future__ import annotations

import sys

import duckdb
import numpy as np
import pandas as pd

from Modulos.macro_state import normalization as N
from Modulos.macro_state import engines, regime_classifier, registry
from Modulos.macro_state import economic_state
from Modulos.datahouse import engine as datahouse_engine
from Modulos.datahouse import validator as datahouse_validator


def _mem():
    con = duckdb.connect(":memory:")
    con.execute("CREATE TABLE macro_series (id BIGINT, symbol VARCHAR, date VARCHAR, value DOUBLE, updated_at VARCHAR)")
    con.execute("""CREATE TABLE macro_catalog (symbol VARCHAR, name VARCHAR, category VARCHAR,
                   subcategory VARCHAR, country VARCHAR, frequency VARCHAR, source VARCHAR, unit VARCHAR,
                   description VARCHAR, fred_code VARCHAR, category_type VARCHAR, collector VARCHAR,
                   target_table VARCHAR, timeframe VARCHAR, enabled BOOLEAN, min_freshness_hours INTEGER)""")
    con.execute("""CREATE TABLE macro_scores (timestamp VARCHAR, economy VARCHAR, dimension VARCHAR,
                   score DOUBLE, state VARCHAR, source_status VARCHAR)""")
    con.execute("""CREATE TABLE macro_regimes (timestamp VARCHAR, economy VARCHAR, growth_score DOUBLE,
                   labor_score DOUBLE, inflation_score DOUBLE, financial_score DOUBLE, recession_score DOUBLE,
                   recession_prob DOUBLE, phillips_score DOUBLE, phillips_state VARCHAR, regime VARCHAR,
                   score DOUBLE, data_quality_status VARCHAR, coverage DOUBLE, global_score DOUBLE)""")
    return con


def _seed(con, symbol, values, start="2020-01-31"):
    dates = pd.date_range(start, periods=len(values), freq="ME").strftime("%Y-%m-%d")
    for d, v in zip(dates, values):
        con.execute("INSERT INTO macro_series VALUES (1, ?, ?, ?, ?)", [symbol, d, float(v), d])


def test_normalization_zscore_monotonic():
    s = pd.Series(np.linspace(0, 10, 60))
    z = N.rolling_zscore(s, window=36, min_periods=20)
    assert not z.dropna().empty
    assert z.dropna().iloc[-1] > 1.5  # last value is far above trailing mean


def test_inflation_engine_on_target():
    # CPI yoy exactly at 2% target -> score ~0 (On Target)
    s = pd.Series([2.0] * 40)
    sc, state, _ = engines.inflation_engine({"CPI": s}, {"CPI": {"freq": "M"}}, target=0.02)
    assert abs(sc) < 0.3
    assert state in ("On Target", "Below Target", "Above Target")


def test_inflation_engine_above_target_is_negative():
    s = pd.Series([2.0] * 30 + [5.0] * 10)
    sc, _, _ = engines.inflation_engine({"CPI": s}, {"CPI": {"freq": "M"}}, target=0.02)
    assert sc < -0.3


def test_recession_engine_missing():
    sc, state, _ = engines.recession_engine({}, {})
    assert sc is None
    assert state == "MISSING"


def test_regime_classify_contraction():
    dims = {"growth": (-0.5, "Contraction", {}), "labor": (-0.2, "Softening", {}),
            "inflation": (0.1, "On Target", {}), "financial_conditions": (-0.4, "Stress", {}),
            "recession": (-0.6, "Recession Risk", {})}
    assert regime_classifier.classify(dims) == "CONTRACTION"


def test_compute_economy_usa_with_data():
    con = _mem()
    # 60 months of data: unemployment falling (good), CPI near target
    unrate = list(np.linspace(6.0, 3.5, 60))
    cpi = [2.0] * 60
    _seed(con, "UNRATE", unrate)
    _seed(con, "CPIAUCSL", cpi)
    # ensure registry knows these (it does by default)
    st = economic_state.compute_economy(con, "USA")
    assert st["dimensions"]["labor"][0] is not None
    assert st["dimensions"]["inflation"][0] is not None
    assert st["regime"]


def test_compute_economy_missing_returns_missing():
    con = _mem()
    st = economic_state.compute_economy(con, "BRAZIL")
    assert st["dimensions"]["inflation"][1] == "MISSING"
    assert st["data_quality"]["status"] in ("NO DATA", "PARTIAL")


def test_datahouse_reenables_expected_macro_symbols():
    con = duckdb.connect(":memory:")
    con.execute("""CREATE TABLE macro_catalog (symbol VARCHAR, name VARCHAR, category VARCHAR,
                   subcategory VARCHAR, country VARCHAR, frequency VARCHAR, source VARCHAR, unit VARCHAR,
                   description VARCHAR, fred_code VARCHAR, category_type VARCHAR, collector VARCHAR,
                   target_table VARCHAR, timeframe VARCHAR, enabled BOOLEAN, min_freshness_hours INTEGER)""")
    con.execute(
        """
        INSERT INTO macro_catalog (symbol, name, category, subcategory, country, frequency, source, unit,
                                  description, fred_code, category_type, collector, target_table, timeframe,
                                  enabled, min_freshness_hours)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            "CPIAUCSL", "CPI", "macro_state", "inflation", "US", "M", "FRED", "%",
            "USA inflation CPI", "CPIAUCSL", "macro", "FRED", "macro_series", None, False, 720,
        ],
    )

    datahouse_engine._upsert_macro_economy_assets(con)

    row = con.execute(
        "SELECT enabled, collector, target_table, min_freshness_hours FROM macro_catalog WHERE symbol = 'CPIAUCSL'"
    ).fetchone()
    assert row[0] is True
    assert row[1] == "FRED"
    assert row[2] == "macro_series"
    assert row[3] == 720


def test_macro_repair_uses_datahouse_readiness():
    macro_cmd = datahouse_validator.REPAIR_COMMANDS["Macro"]
    assert macro_cmd[:3] == [sys.executable, "-m", "Modulos.datahouse.readiness"]
    assert macro_cmd[-1] == "--ensure"
