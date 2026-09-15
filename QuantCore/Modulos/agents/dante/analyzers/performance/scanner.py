import re
from pathlib import Path

from ...config import config

_RULES = [
    {
        "rule_id": "PERF-01",
        "severity": "high",
        "category": "file_io_loop",
        "pattern": re.compile(
            r"""(?:for|while)\b.*\b(?:open|Path|read_text|read_csv)\b""",
            re.IGNORECASE,
        ),
        "message": "File open inside a loop; batch I/O instead",
    },
    {
        "rule_id": "PERF-02",
        "severity": "high",
        "category": "duckdb_no_reuse",
        "pattern": re.compile(
            r"""duckdb\.connect\(\)""",
            re.IGNORECASE,
        ),
        "message": "New DuckDB connection per call; reuse a single connection",
    },
    {
        "rule_id": "PERF-03",
        "severity": "medium",
        "category": "dataframe_copy_loop",
        "pattern": re.compile(
            r"""(?:for|while)\b.*\b\.copy\(\)""",
            re.IGNORECASE,
        ),
        "message": "DataFrame .copy() inside a loop; prefer in-place operations",
    },
    {
        "rule_id": "PERF-04",
        "severity": "medium",
        "category": "n_plus_one",
        "pattern": re.compile(
            r"""(?:for|while)\b.*\b(?:execute|query|fetchone|fetchall)\b""",
            re.IGNORECASE,
        ),
        "message": "N+1 query pattern; use batch fetch or JOIN",
    },
    {
        "rule_id": "PERF-05",
        "severity": "low",
        "category": "memory_pressure",
        "pattern": re.compile(
            r"""\.to_numpy\(\)|\.values\.tolist\(\)|\.to_dict\(\)""",
            re.IGNORECASE,
        ),
        "message": "Full DataFrame materialisation; consider chunked processing",
    },
]


def scan_file(file_path: Path) -> list[dict]:
    findings = []
    try:
        for enc in ("utf-8", "latin-1", "cp1252"):
            try:
                lines = file_path.read_text(encoding=enc).splitlines()
                break
            except (UnicodeDecodeError, UnicodeError):
                continue
        else:
            return findings
    except OSError:
        return findings

    for i, line in enumerate(lines, 1):
        for rule in _RULES:
            if rule["pattern"].search(line):
                findings.append({
                    "file_path": str(file_path),
                    "line": i,
                    "rule_id": rule["rule_id"],
                    "severity": rule["severity"],
                    "message": rule["message"],
                    "category": rule["category"],
                })

    return findings
