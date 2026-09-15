"""MQL5 scanner — file analysis, include graph, function extraction."""

import os
from pathlib import Path
from typing import Optional

from ...config import config
from .rules import ALL_MQL5_RULES, Rule


def scan_mql5_files(target_dir: Optional[Path] = None) -> list[Path]:
    """Discover all .mq5 and .mqh files, excluding configured directories."""
    if target_dir is None:
        target_dir = config.scan.target_dir
    files = []
    for root, dirs, filenames in os.walk(target_dir):
        dirs[:] = [
            d for d in dirs
            if d not in config.scan.exclude_dirs
        ]
        for fn in filenames:
            if fn.endswith((".mq5", ".mqh")):
                fp = Path(root) / fn
                if fp.stat().st_size <= config.scan.max_file_size_kb * 1024:
                    files.append(fp)
    return files


def read_file(path: Path) -> list[str]:
    """Read file lines with encoding fallback."""
    for enc in ("utf-8", "latin-1", "cp1252"):
        try:
            return path.read_text(encoding=enc).splitlines()
        except (UnicodeDecodeError, UnicodeError):
            continue
    return []


def extract_includes(lines: list[str]) -> list[str]:
    """Extract all #include directives and return included paths."""
    includes = []
    for line in lines:
        m = __import__("re").search(r'#include\s+[<"](.+?)[>"]', line)
        if m:
            includes.append(m.group(1))
    return includes


def extract_functions(lines: list[str]) -> list[dict]:
    """Extract function signatures with line numbers."""
    import re
    functions = []
    for i, line in enumerate(lines):
        m = re.match(
            r"(?:void|int|double|float|bool|long|datetime|string|color|enum\s+\w+|struct\s+\w+|class\s+\w+)\s+"
            r"(\w+)\s*\(([^)]*)\)",
            line.strip()
        )
        if m:
            functions.append({
                "name": m.group(1),
                "params": m.group(2).strip(),
                "line": i + 1,
            })
    return functions


def extract_global_vars(lines: list[str]) -> list[dict]:
    """Extract global variable declarations."""
    import re
    globals_found = []
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        m = re.match(
            r"(input|sinput|extern)\s+"
            r"(?:const\s+)?(?:double|int|float|bool|string|color|enum\s+\w+)\s+"
            r"(\w+)\s*(?:=\s*(.+?))?\s*;",
            stripped
        )
        if m:
            globals_found.append({
                "name": m.group(2),
                "default": m.group(3).strip() if m.group(3) else None,
                "line": i + 1,
            })
    return globals_found


def analyze_file(file_path: Path) -> dict:
    """Run all MQL5 rules on a single file."""
    lines = read_file(file_path)
    if not lines:
        return {"file_path": str(file_path), "findings": [], "functions": [], "includes": []}

    findings = []
    for rule in ALL_MQL5_RULES:
        rule_findings = rule.check(lines, str(file_path))
        findings.extend(rule_findings)

    functions = extract_functions(lines)
    includes = extract_includes(lines)
    globals_found = extract_global_vars(lines)

    return {
        "file_path": str(file_path),
        "findings": findings,
        "functions": functions,
        "includes": includes,
        "globals": globals_found,
        "line_count": len(lines),
    }


def build_include_graph(files: list[Path]) -> dict[str, list[str]]:
    """Build a map of file → included files."""
    graph = {}
    for fp in files:
        lines = read_file(fp)
        includes = extract_includes(lines)
        graph[str(fp)] = includes
    return graph
