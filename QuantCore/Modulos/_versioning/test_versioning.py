"""Tests for ALXQuant versioning module."""

import pytest
from Modulos._versioning import (
    Version,
    parse_version,
    parse_range,
    check_range,
    Constraint,
    CompatibilityChecker,
    IncompatibleVersionError,
)


class TestVersionParsing:
    def test_parse_basic(self):
        v = parse_version("10.3.0")
        assert v == Version(10, 3, 0)

    def test_parse_with_prerelease(self):
        v = parse_version("10.3.0-rc.1")
        assert v == Version(10, 3, 0)

    def test_parse_invalid(self):
        with pytest.raises(ValueError):
            parse_version("10.3")
        with pytest.raises(ValueError):
            parse_version("not.a.version")

    def test_version_comparison(self):
        assert Version(10, 0, 0) < Version(10, 1, 0)
        assert Version(10, 1, 0) < Version(11, 0, 0)
        assert Version(10, 0, 1) > Version(10, 0, 0)
        assert Version(10, 0, 0) == Version(10, 0, 0)
        assert Version(10, 0, 0) <= Version(10, 0, 0)
        assert Version(10, 0, 0) >= Version(10, 0, 0)


class TestRangeParsing:
    def test_parse_single_constraint(self):
        constraints = parse_range(">=10.0.0")
        assert len(constraints) == 1
        assert constraints[0].op == ">="
        assert constraints[0].version == Version(10, 0, 0)

    def test_parse_multiple_constraints(self):
        constraints = parse_range(">=10.0.0,<11.0.0")
        assert len(constraints) == 2
        assert constraints[0].op == ">="
        assert constraints[1].op == "<"

    def test_parse_operators(self):
        for op in [">=", ">", "<=", "<", "==", "!="]:
            c = parse_range(f"{op}1.2.3")[0]
            assert c.op == op

    def test_constraint_check(self):
        c = Constraint(">=", Version(10, 0, 0))
        assert c.check(Version(10, 0, 0))
        assert c.check(Version(10, 1, 0))
        assert not c.check(Version(9, 9, 9))

        c = Constraint("<", Version(11, 0, 0))
        assert c.check(Version(10, 5, 0))
        assert not c.check(Version(11, 0, 0))
        assert not c.check(Version(11, 0, 1))


class TestCheckRange:
    def test_satisfies_range(self):
        ok, failed = check_range(Version(10, 3, 0), ">=10.0.0,<11.0.0")
        assert ok
        assert failed == []

    def test_fails_min(self):
        ok, failed = check_range(Version(9, 9, 9), ">=10.0.0,<11.0.0")
        assert not ok
        assert ">=10.0.0" in failed

    def test_fails_max(self):
        ok, failed = check_range(Version(11, 0, 0), ">=10.0.0,<11.0.0")
        assert not ok
        assert "<11.0.0" in failed

    def test_exact_match(self):
        ok, failed = check_range(Version(10, 0, 0), "==10.0.0")
        assert ok
        ok, failed = check_range(Version(10, 0, 1), "==10.0.0")
        assert not ok


class TestCompatibilityChecker:
    def setup_method(self):
        self.checker = CompatibilityChecker()

    def test_platform_version(self):
        v = self.checker.get_platform_version()
        assert v == Version(10, 3, 0)

    def test_component_versions(self):
        # Check a few known components
        assert self.checker.get_component_version("mql5:Execution") == Version(10, 0, 1)
        assert self.checker.get_component_version("mql5:MacroRegimeEngine") == Version(10, 1, 0)
        assert self.checker.get_component_version("python:asset_dna") == Version(10, 0, 0)
        assert self.checker.get_component_version("python:datahouse") == Version(10, 2, 0)

    def test_component_requires(self):
        requires = self.checker.get_component_requires("mql5:Execution")
        assert "mql5:MacroRegimeEngine" in requires
        assert requires["mql5:MacroRegimeEngine"] == ">=10.0.0,<11.0.0"

    def test_check_all_components(self):
        results = self.checker.check_all()
        # All should pass since manifest is self-consistent
        assert all(results.values()), f"Failed components: {[k for k, v in results.items() if not v]}"

    def test_contract_validation(self):
        # format_version 10000 = 10.0.0 equivalent
        assert self.checker.validate_contract("policy_bin", 10000, 10000)
        with pytest.raises(IncompatibleVersionError):
            self.checker.validate_contract("policy_bin", 10000, 9999)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])