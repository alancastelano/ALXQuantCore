"""DANTE MQL5 rule tests."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from dante.analyzers.mql5.scanner import analyze_file, read_file, extract_functions, extract_includes
from dante.analyzers.mql5.rules import ALL_MQL5_RULES

FIXTURE_DIR = Path(__file__).parent / "fixtures"
MQ5_FIXTURE = FIXTURE_DIR / "vulnerable.mq5"


class TestMQL5Scanner:
    def test_read_file(self):
        lines = read_file(MQ5_FIXTURE)
        assert len(lines) > 0

    def test_extract_functions(self):
        lines = read_file(MQ5_FIXTURE)
        funcs = extract_functions(lines)
        func_names = [f["name"] for f in funcs]
        assert "OnInit" in func_names
        assert "OnTick" in func_names
        assert "OnTimer" in func_names

    def test_extract_includes(self):
        lines = read_file(MQ5_FIXTURE)
        includes = extract_includes(lines)
        assert len(includes) >= 2

    def test_analyze_file(self):
        result = analyze_file(MQ5_FIXTURE)
        assert result["file_path"] == str(MQ5_FIXTURE)
        assert len(result["findings"]) > 0
        assert result["line_count"] > 0


class TestMQL5Rules:
    def test_all_rules_have_ids(self):
        for rule in ALL_MQL5_RULES:
            assert rule.rule_id.startswith("MQL5-")
            assert rule.name
            assert rule.severity in ("critical", "high", "medium", "low", "info")

    def test_all_rules_callable(self):
        for rule in ALL_MQL5_RULES:
            result = rule.check(["int x;"], "/test.mq5")
            assert isinstance(result, list)

    def test_sum_vol_loop(self):
        code = [
            "void OnTick() {",
            "  for(int i=0; i<10; i++) {",
            "    double vol=0;",
            "    vol += 0.1;",
            "  }",
            "}",
        ]
        rule = next(r for r in ALL_MQL5_RULES if r.rule_id == "MQL5-6.1")
        findings = rule.check(code, "/test.mq5")
        assert len(findings) > 0

    def test_array_not_populated(self):
        code = ["double arr[20];"]
        rule = next(r for r in ALL_MQL5_RULES if r.rule_id == "MQL5-6.2")
        findings = rule.check(code, "/test.mq5")
        assert len(findings) > 0

    def test_hardcoded_magic(self):
        code = ["int MagicNumber = 12345;"]
        rule = next(r for r in ALL_MQL5_RULES if r.rule_id == "MQL5-6.3")
        findings = rule.check(code, "/test.mq5")
        assert len(findings) > 0

    def test_zero_init(self):
        code = ["int count;"]
        rule = next(r for r in ALL_MQL5_RULES if r.rule_id == "MQL5-6.4")
        findings = rule.check(code, "/test.mq5")
        assert len(findings) > 0

    def test_division_by_zero(self):
        code = ["double x = a / b;"]
        rule = next(r for r in ALL_MQL5_RULES if r.rule_id == "MQL5-6.5")
        findings = rule.check(code, "/test.mq5")
        assert len(findings) > 0

    def test_division_rule_ignores_comments_urls_and_includes(self):
        code = [
            "// https://example.com/a/b",
            '#include "folder/file.mqh"',
            'string url = "https://example.com/a/b";',
        ]
        rule = next(r for r in ALL_MQL5_RULES if r.rule_id == "MQL5-6.5")
        assert rule.check(code, "/test.mq5") == []

    def test_no_trade_verification(self):
        code = ["trade.Buy(0.1, _Symbol, 0, 0, 0);"]
        rule = next(r for r in ALL_MQL5_RULES if r.rule_id == "MQL5-6.7")
        findings = rule.check(code, "/test.mq5")
        assert len(findings) > 0

    def test_dead_code(self):
        code = [
            "void f() {",
            "  return;",
            "  // Print('dead');",
            "}",
        ]
        rule = next(r for r in ALL_MQL5_RULES if r.rule_id == "MQL5-6.10")
        findings = rule.check(code, "/test.mq5")
        assert len(findings) > 0

    def test_protection_flag(self):
        code = [
            "int OnInit() { return INIT_SUCCEEDED; }",
        ]
        rule = next(r for r in ALL_MQL5_RULES if r.rule_id == "MQL5-6.14")
        findings = rule.check(code, "/test.mq5")
        assert len(findings) > 0

    def test_hardcoded_secret(self):
        code = ['string api_key = "sk-1234567890abcdef1234567890abcdef";']
        rule = next(r for r in ALL_MQL5_RULES if r.rule_id == "MQL5-6.16")
        findings = rule.check(code, "/test.mq5")
        assert len(findings) > 0

    def test_fixture_has_findings(self):
        result = analyze_file(MQ5_FIXTURE)
        rule_ids = [f["rule_id"] for f in result["findings"]]
        assert "MQL5-6.1" in rule_ids or "MQL5-6.2" in rule_ids or "MQL5-6.16" in rule_ids
