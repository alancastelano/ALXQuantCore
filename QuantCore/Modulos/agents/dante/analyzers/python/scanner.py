from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ...config import config


def scan_python_files(target_dir: Path) -> list[Path]:
    exclude_dirs = set(config.scan.exclude_dirs)
    results: list[Path] = []

    for root, dirs, files in target_dir.walk():
        dirs[:] = [
            d for d in dirs
            if d not in exclude_dirs and not d.startswith(".")
        ]
        for f in files:
            path = root / f
            if (f.endswith(".py") and
                    path.stat().st_size <= config.scan.max_file_size_kb * 1024):
                results.append(path)

    return sorted(results)


def read_file(path: Path) -> list[str]:
    for encoding in ("utf-8", "utf-8-sig", "latin-1", "cp1252"):
        try:
            return path.read_text(encoding=encoding).splitlines()
        except (UnicodeDecodeError, UnicodeError):
            continue
    return path.read_text(errors="replace").splitlines()


def extract_imports(lines: list[str]) -> list[str]:
    imports: list[str] = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#"):
            continue

        if re.match(r"^from\s+[\w.]+\s+import\s+", stripped):
            imports.append(stripped)
        elif re.match(r"^import\s+[\w.\s,]+", stripped):
            imports.append(stripped)
    return imports


def extract_classes(lines: list[str]) -> list[dict[str, Any]]:
    classes: list[dict[str, Any]] = []
    for i, line in enumerate(lines, 1):
        match = re.match(r"class\s+(\w+)", line.lstrip())
        if match:
            classes.append({"name": match.group(1), "line": i})
    return classes


def extract_functions(lines: list[str]) -> list[dict[str, Any]]:
    functions: list[dict[str, Any]] = []
    pattern = re.compile(r"def\s+(\w+)\s*\(([^)]*)\)(?:\s*->\s*\S+)?\s*:")
    for i, line in enumerate(lines, 1):
        match = pattern.search(line)
        if match:
            params_raw = match.group(2)
            params = [p.strip().split(":")[0].split("=")[0].strip()
                      for p in params_raw.split(",") if p.strip()]
            functions.append({
                "name": match.group(1),
                "params": params,
                "line": i,
            })
    return functions


def analyze_file(file_path: Path) -> dict[str, Any]:
    from .rules import ALL_PYTHON_RULES

    lines = read_file(file_path)
    findings: list[dict[str, Any]] = []

    for rule in ALL_PYTHON_RULES:
        findings.extend(rule.check(lines, str(file_path)))

    return {
        "file_path": str(file_path),
        "findings": findings,
        "functions": extract_functions(lines),
        "classes": extract_classes(lines),
        "imports": extract_imports(lines),
        "line_count": len(lines),
    }
