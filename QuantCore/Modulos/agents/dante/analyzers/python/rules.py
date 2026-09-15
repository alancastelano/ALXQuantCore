from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Callable


@dataclass
class Rule:
    rule_id: str
    name: str
    severity: str
    category: str
    description: str
    check: Callable[[list[str], str], list[dict]] = field(repr=False)


def _bare_except(lines: list[str], file_path: str) -> list[dict]:
    findings: list[dict] = []
    for i, line in enumerate(lines, 1):
        stripped = line.lstrip()
        if re.match(r"except\s*:", stripped):
            findings.append({
                "file_path": file_path,
                "line": i,
                "rule_id": "PY-7.1",
                "severity": "high",
                "message": "Bare except catches all exceptions including SystemExit and KeyboardInterrupt",
                "category": "bare_except",
            })
    return findings


def _mutable_default(lines: list[str], file_path: str) -> list[dict]:
    findings: list[dict] = []
    pattern = re.compile(r"def\s+\w+\s*\([^)]*=\s*(\[\]|\{\})")
    for i, line in enumerate(lines, 1):
        if pattern.search(line):
            findings.append({
                "file_path": file_path,
                "line": i,
                "rule_id": "PY-7.2",
                "severity": "high",
                "message": "Mutable default argument is shared across all calls",
                "category": "mutable_default",
            })
    return findings


def _none_comparison(lines: list[str], file_path: str) -> list[dict]:
    findings: list[dict] = []
    pattern = re.compile(r"==\s*None|!=\s*None")
    for i, line in enumerate(lines, 1):
        if pattern.search(line):
            findings.append({
                "file_path": file_path,
                "line": i,
                "rule_id": "PY-7.3",
                "severity": "medium",
                "message": "Use 'is None' / 'is not None' instead of == / != for None comparison",
                "category": "none_comparison",
            })
    return findings


def _string_concat_loop(lines: list[str], file_path: str) -> list[dict]:
    findings: list[dict] = []
    in_loop = False
    indent_level = 0

    for i, line in enumerate(lines, 1):
        stripped = line.lstrip()
        current_indent = len(line) - len(stripped)

        if re.match(r"(for|while)\s+", stripped):
            in_loop = True
            indent_level = current_indent
        elif in_loop and current_indent <= indent_level and stripped and not stripped.startswith("#"):
            in_loop = False

        if in_loop and "+=" in stripped:
            if "'" in stripped or '"' in stripped or re.search(r"str\(|f\"", stripped):
                findings.append({
                    "file_path": file_path,
                    "line": i,
                    "rule_id": "PY-7.4",
                    "severity": "medium",
                    "message": "String concatenation inside loop; consider using str.join or list append",
                    "category": "string_concat_loop",
                })
        elif in_loop and re.search(r"\w+\s*=\s*\w+\s*\+\s*(?:str\(|f[\"'])", stripped):
            findings.append({
                "file_path": file_path,
                "line": i,
                "rule_id": "PY-7.4",
                "severity": "medium",
                "message": "String concatenation inside loop; consider using str.join or list append",
                "category": "string_concat_loop",
            })
    return findings


def _global_state(lines: list[str], file_path: str) -> list[dict]:
    findings: list[dict] = []
    pattern = re.compile(
        r"^[a-zA-Z_]\w*\s*(?::\s*\w+)?\s*=\s*(\[|\{|set\()"
    )
    for i, line in enumerate(lines, 1):
        stripped = line.lstrip()
        if line and not line[0].isspace() and pattern.match(stripped):
            if not stripped.startswith(("_", "#")):
                findings.append({
                    "file_path": file_path,
                    "line": i,
                    "rule_id": "PY-7.5",
                    "severity": "low",
                    "message": "Mutable module-level variable may cause unintended shared state",
                    "category": "global_state",
                })
    return findings


def _missing_super_init(lines: list[str], file_path: str) -> list[dict]:
    findings: list[dict] = []
    class_indent = -1
    class_name = ""
    init_indent = -1
    has_super = False

    for i, line in enumerate(lines, 1):
        stripped = line.lstrip()
        current_indent = len(line) - len(stripped)

        class_match = re.match(r"class\s+(\w+)", stripped)
        if class_match:
            class_indent = current_indent
            class_name = class_match.group(1)
            continue

        if class_indent >= 0 and current_indent > class_indent:
            init_match = re.match(r"def\s+__init__\s*\(", stripped)
            if init_match:
                if init_indent >= 0 and not has_super:
                    findings.append({
                        "file_path": file_path,
                        "line": i,
                        "rule_id": "PY-7.6",
                        "severity": "medium",
                        "message": f"class {class_name}.__init__ missing super().__init__() call",
                        "category": "missing_super_init",
                    })
                init_indent = current_indent
                has_super = False

            if init_indent >= 0 and current_indent > init_indent:
                if "super()" in stripped:
                    has_super = True
        else:
            if init_indent >= 0 and not has_super:
                findings.append({
                    "file_path": file_path,
                    "line": i,
                    "rule_id": "PY-7.6",
                    "severity": "medium",
                    "message": f"class {class_name}.__init__ missing super().__init__() call",
                    "category": "missing_super_init",
                })
            class_indent = -1
            init_indent = -1
            has_super = False

    if init_indent >= 0 and not has_super:
        findings.append({
            "file_path": file_path,
            "line": len(lines),
            "rule_id": "PY-7.6",
            "severity": "medium",
            "message": f"class {class_name}.__init__ missing super().__init__() call",
            "category": "missing_super_init",
        })

    return findings


def _unreachable_code(lines: list[str], file_path: str) -> list[dict]:
    findings: list[dict] = []
    for i in range(len(lines) - 1):
        stripped = lines[i].lstrip()
        if re.match(r"\b(return|break|continue)\b\s+", stripped):
            next_stripped = lines[i + 1].lstrip() if i + 1 < len(lines) else ""
            if next_stripped and not next_stripped.startswith(
                ("return", "break", "continue", "def ", "class ", "except", "finally", "pass")
            ) and not next_stripped.startswith("#"):
                findings.append({
                    "file_path": file_path,
                    "line": i + 2,
                    "rule_id": "PY-7.7",
                    "severity": "low",
                    "message": "Unreachable code after unconditional return/break/continue",
                    "category": "unreachable_code",
                })
    return findings


def _missing_type_hints(lines: list[str], file_path: str) -> list[dict]:
    findings: list[dict] = []
    for i, line in enumerate(lines, 1):
        stripped = line.lstrip()
        func_match = re.match(
            r"def\s+(\w+)\s*\(([^)]*)\)(?:\s*->\s*\S+)?\s*:", stripped
        )
        if func_match:
            name = func_match.group(1)
            params = func_match.group(2)
            has_return_arrow = "->" in stripped.split(":")[0] if ":" in stripped else False

            if not has_return_arrow:
                findings.append({
                    "file_path": file_path,
                    "line": i,
                    "rule_id": "PY-7.8",
                    "severity": "info",
                    "message": f"Function '{name}' missing return type annotation",
                    "category": "missing_type_hints",
                })
                continue

            if params.strip():
                param_parts = [p.strip() for p in params.split(",") if p.strip()]
                for part in param_parts:
                    if "=" in part:
                        part = part.split("=")[0].strip()
                    if ":" not in part and part != "self" and part != "cls":
                        findings.append({
                            "file_path": file_path,
                            "line": i,
                            "rule_id": "PY-7.8",
                            "severity": "info",
                            "message": f"Function '{name}' parameter '{part}' missing type annotation",
                            "category": "missing_type_hints",
                        })
    return findings


ALL_PYTHON_RULES: list[Rule] = [
    Rule("PY-7.1", "BareExcept", "high", "bare_except", "Catches all exceptions without specifying type", _bare_except),
    Rule("PY-7.2", "MutableDefault", "high", "mutable_default", "Mutable default argument shared across calls", _mutable_default),
    Rule("PY-7.3", "NoneComparison", "medium", "none_comparison", "Uses == or != with None instead of is/is not", _none_comparison),
    Rule("PY-7.4", "StringConcatLoop", "medium", "string_concat_loop", "String concatenation inside loop", _string_concat_loop),
    Rule("PY-7.5", "GlobalState", "low", "global_state", "Mutable module-level variable", _global_state),
    Rule("PY-7.6", "MissingSuperInit", "medium", "missing_super_init", "Class __init__ missing super().__init__() call", _missing_super_init),
    Rule("PY-7.7", "UnreachableCode", "low", "unreachable_code", "Code after unconditional return/break/continue", _unreachable_code),
    Rule("PY-7.8", "MissingTypeHints", "info", "missing_type_hints", "Function missing type annotations", _missing_type_hints),
]
