"""DANTE Python rule tests."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from dante.analyzers.python.scanner import analyze_file, read_file, extract_functions, extract_imports
from dante.analyzers.python.rules import ALL_PYTHON_RULES

FIXTURE_DIR = Path(__file__).parent / "fixtures"
PY_FIXTURE = FIXTURE_DIR / "vulnerable.py"


class TestPythonScanner:
    def test_read_file(self):
        lines = read_file(PY_FIXTURE)
        assert len(lines) > 0

    def test_extract_functions(self):
        lines = read_file(PY_FIXTURE)
        funcs = extract_functions(lines)
        func_names = [f["name"] for f in funcs]
        assert "calculate_average" in func_names
        assert "process_data" in func_names

    def test_extract_imports(self):
        lines = read_file(PY_FIXTURE)
        imports = extract_imports(lines)
        assert len(imports) > 0

    def test_analyze_file(self):
        result = analyze_file(PY_FIXTURE)
        assert result["file_path"] == str(PY_FIXTURE)
        assert len(result["findings"]) > 0


class TestPythonRules:
    def test_all_rules_have_ids(self):
        for rule in ALL_PYTHON_RULES:
            assert rule.rule_id.startswith("PY-")
            assert rule.name
            assert rule.severity in ("critical", "high", "medium", "low", "info")

    def test_bare_except(self):
        code = [
            "try:",
            "    x = 1",
            "except:",
            "    pass",
        ]
        rule = next(r for r in ALL_PYTHON_RULES if r.rule_id == "PY-7.1")
        findings = rule.check(code, "/test.py")
        assert len(findings) > 0

    def test_mutable_default(self):
        code = [
            "def f(x=[]):",
            "    x.append(1)",
        ]
        rule = next(r for r in ALL_PYTHON_RULES if r.rule_id == "PY-7.2")
        findings = rule.check(code, "/test.py")
        assert len(findings) > 0

    def test_none_comparison(self):
        code = [
            "if x == None:",
            "    pass",
        ]
        rule = next(r for r in ALL_PYTHON_RULES if r.rule_id == "PY-7.3")
        findings = rule.check(code, "/test.py")
        assert len(findings) > 0

    def test_string_concat_loop(self):
        code = [
            "for i in range(10):",
            "    s = s + str(i)",
        ]
        rule = next(r for r in ALL_PYTHON_RULES if r.rule_id == "PY-7.4")
        findings = rule.check(code, "/test.py")
        assert len(findings) > 0

    def test_missing_super_init(self):
        code = [
            "class Foo(Base):",
            "    def __init__(self):",
            "        self.x = 1",
        ]
        rule = next(r for r in ALL_PYTHON_RULES if r.rule_id == "PY-7.6")
        findings = rule.check(code, "/test.py")
        assert len(findings) > 0

    def test_unreachable_code(self):
        code = [
            "def f():",
            "    return True",
            "    print('dead')",
        ]
        rule = next(r for r in ALL_PYTHON_RULES if r.rule_id == "PY-7.7")
        findings = rule.check(code, "/test.py")
        assert len(findings) > 0

    def test_fixture_has_findings(self):
        result = analyze_file(PY_FIXTURE)
        rule_ids = [f["rule_id"] for f in result["findings"]]
        assert "PY-7.1" in rule_ids or "PY-7.2" in rule_ids or "PY-7.3" in rule_ids
