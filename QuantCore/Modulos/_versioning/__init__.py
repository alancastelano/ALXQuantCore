"""
ALXQuant Python Versioning & Compatibility Checker
Stdlib-only implementation (no external dependencies).
"""

import json
import re
import sys
from pathlib import Path
from typing import Tuple, Dict, List, Optional
from dataclasses import dataclass


@dataclass(frozen=True)
class Version:
    """Semantic version (major, minor, patch)."""
    major: int
    minor: int
    patch: int

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Version):
            return NotImplemented
        return (self.major, self.minor, self.patch) == (other.major, other.minor, other.patch)

    def __lt__(self, other: "Version") -> bool:
        return (self.major, self.minor, self.patch) < (other.major, other.minor, other.patch)

    def __le__(self, other: "Version") -> bool:
        return self == other or self < other

    def __gt__(self, other: "Version") -> bool:
        return not self <= other

    def __ge__(self, other: "Version") -> bool:
        return not self < other


_VERSION_RE = re.compile(r'^(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')


def parse_version(ver_str: str) -> Version:
    """Parse semantic version string (supports pre-release/build suffix)."""
    m = _VERSION_RE.match(ver_str.strip())
    if not m:
        raise ValueError(f"Invalid version format: '{ver_str}' (expected MAJOR.MINOR.PATCH)")
    return Version(int(m.group(1)), int(m.group(2)), int(m.group(3)))


@dataclass(frozen=True)
class Constraint:
    """Single version constraint (op + version)."""
    op: str       # '>=', '>', '<=', '<', '==', '!='
    version: Version

    def check(self, v: Version) -> bool:
        if self.op == '>=':
            return v >= self.version
        if self.op == '>':
            return v > self.version
        if self.op == '<=':
            return v <= self.version
        if self.op == '<':
            return v < self.version
        if self.op == '==':
            return v == self.version
        if self.op == '!=':
            return v != self.version
        raise ValueError(f"Unknown operator: {self.op}")


def parse_range(range_spec: str) -> List[Constraint]:
    """Parse range spec like '>=10.0.0,<11.0.0' into list of constraints."""
    constraints = []
    for part in range_spec.split(','):
        part = part.strip()
        if not part:
            continue
        # Find operator
        if part.startswith('>='):
            op, ver = '>=', part[2:]
        elif part.startswith('<='):
            op, ver = '<=', part[2:]
        elif part.startswith('>'):
            op, ver = '>', part[1:]
        elif part.startswith('<'):
            op, ver = '<', part[1:]
        elif part.startswith('=='):
            op, ver = '==', part[2:]
        elif part.startswith('!='):
            op, ver = '!=', part[2:]
        elif part.startswith('='):
            op, ver = '==', part[1:]
        else:
            op, ver = '==', part
        constraints.append(Constraint(op, parse_version(ver)))
    return constraints


def check_range(version: Version, range_spec: str) -> Tuple[bool, List[str]]:
    """Check if version satisfies range_spec. Returns (ok, failed_constraints)."""
    constraints = parse_range(range_spec)
    failed = []
    for c in constraints:
        if not c.check(version):
            failed.append(f"{c.op}{c.version}")
    return (len(failed) == 0, failed)


class IncompatibleVersionError(Exception):
    """Raised when version compatibility check fails."""
    def __init__(self, component: str, current: Version, required_range: str, failed: List[str]):
        self.component = component
        self.current = current
        self.required_range = required_range
        self.failed = failed
        msg = (
            f"[VERSION] INCOMPATIBLE: {component} v{current} does not satisfy "
            f"required range '{required_range}' — failed: {', '.join(failed)}"
        )
        super().__init__(msg)


class CompatibilityChecker:
    """Validates component versions against manifest.json."""

    def __init__(self, manifest_path: Optional[Path] = None):
        if manifest_path is None:
            # manifest.json is at QuantCore root, not in Modulos/
            manifest_path = Path(__file__).parent.parent.parent / "manifest.json"
        self.manifest_path = manifest_path
        self._manifest = self._load_manifest()

    def _load_manifest(self) -> dict:
        if not self.manifest_path.exists():
            raise FileNotFoundError(f"Manifest not found: {self.manifest_path}")
        with open(self.manifest_path, 'r', encoding='utf-8') as f:
            return json.load(f)

    def get_platform_version(self) -> Version:
        return parse_version(self._manifest['platform'])

    def get_component_version(self, component_name: str) -> Version:
        comp = self._manifest['components'].get(component_name)
        if not comp:
            raise KeyError(f"Component not in manifest: {component_name}")
        return parse_version(comp['version'])

    def get_component_requires(self, component_name: str) -> Dict[str, str]:
        """Return {dep_name: range_spec} for a component."""
        comp = self._manifest['components'].get(component_name)
        if not comp:
            raise KeyError(f"Component not in manifest: {component_name}")
        return comp.get('requires', {})

    def check_component(self, component_name: str, current_version: Optional[str] = None) -> bool:
        """
        Validate a component's current version against its declared requirements.
        If current_version is None, reads from manifest (for self-check).
        Raises IncompatibleVersionError on failure.
        """
        comp = self._manifest['components'].get(component_name)
        if not comp:
            raise KeyError(f"Component not in manifest: {component_name}")

        current = parse_version(current_version) if current_version else parse_version(comp['version'])
        requires = comp.get('requires', {})

        for dep_name, range_spec in requires.items():
            ok, failed = check_range(current, range_spec)
            if not ok:
                raise IncompatibleVersionError(
                    f"{component_name} -> {dep_name}", current, range_spec, failed
                )
        return True

    def check_all(self) -> Dict[str, bool]:
        """Validate all components in manifest. Returns {component: ok}."""
        results = {}
        for name in self._manifest['components']:
            try:
                self.check_component(name)
                results[name] = True
            except IncompatibleVersionError:
                results[name] = False
        return results

    def validate_contract(self, contract_name: str, expected_format: int, actual_format: int) -> bool:
        """Validate binary contract format version."""
        contracts = self._manifest.get('contracts', {})
        if contract_name not in contracts:
            raise KeyError(f"Contract not in manifest: {contract_name}")
        required = contracts[contract_name].get('format_version', expected_format)
        if actual_format != required:
            raise IncompatibleVersionError(
                f"contract:{contract_name}",
                Version(actual_format // 10000, (actual_format // 100) % 100, actual_format % 100),
                f"=={required}",
                [f"format {actual_format} != {required}"]
            )
        return True


# Convenience function for module __init__.py
def check_compat(component_name: str, current_version: str, manifest_path: Optional[Path] = None) -> None:
    """
    Call at module import time to validate compatibility.
    Example in Modulos/asset_dna/__init__.py:
        from Modulos._versioning import check_compat
        check_compat("python:asset_dna", "10.0.0")
    """
    checker = CompatibilityChecker(manifest_path)
    checker.check_component(component_name, current_version)