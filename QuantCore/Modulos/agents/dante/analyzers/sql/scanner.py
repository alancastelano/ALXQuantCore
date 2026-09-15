from pathlib import Path
import re

from ...config import config


def scan_sql_files(target_dir: str) -> list[Path]:
    target = Path(target_dir)
    if not target.exists():
        return []
    return sorted(target.rglob("*.sql"))


def read_file(path: Path) -> list[str]:
    for enc in ("utf-8", "latin-1", "cp1252"):
        try:
            return path.read_text(encoding=enc).splitlines()
        except (UnicodeDecodeError, UnicodeError):
            continue
    return []


def analyze_file(file_path: Path) -> dict:
    lines = read_file(file_path)
    findings = []
    queries = []

    for i, line in enumerate(lines, 1):
        stripped = line.strip().rstrip(";").upper()

        if stripped.startswith("SELECT"):
            queries.append(line.strip())
            if "SELECT *" in stripped:
                findings.append({
                    "rule": "SELECT_STAR",
                    "severity": "medium",
                    "line": i,
                    "message": "SELECT * detected; select only needed columns",
                })
            if "FROM" in stripped and "LIMIT" not in stripped and "TOP " not in stripped:
                findings.append({
                    "rule": "NO_LIMIT",
                    "severity": "medium",
                    "line": i,
                    "message": "SELECT without LIMIT; may return unbounded rows",
                })

        elif stripped.startswith("UPDATE"):
            queries.append(line.strip())
            if "WHERE" not in stripped:
                findings.append({
                    "rule": "UPDATE_NO_WHERE",
                    "severity": "critical",
                    "line": i,
                    "message": "UPDATE without WHERE clause; risks modifying all rows",
                })

        elif stripped.startswith("DELETE"):
            queries.append(line.strip())
            if "WHERE" not in stripped:
                findings.append({
                    "rule": "DELETE_NO_WHERE",
                    "severity": "critical",
                    "line": i,
                    "message": "DELETE without WHERE clause; risks deleting all rows",
                })

        elif stripped.startswith("INSERT"):
            queries.append(line.strip())
            if "VALUES" in stripped and "(" in stripped:
                insert_match = re.match(r"INSERT\s+INTO\s+\S+\s+VALUES", stripped)
                if insert_match:
                    findings.append({
                        "rule": "INSERT_NO_COLUMNS",
                        "severity": "medium",
                        "line": i,
                        "message": "INSERT without explicit column list; fragile on schema change",
                    })

        if "WHERE" in stripped:
            where_match = re.search(r"WHERE\s+(.+)", stripped, re.IGNORECASE)
            if where_match:
                clause = where_match.group(1)
                eq_match = re.search(r"=\s*['\"]?\w+['\"]?", clause)
                if eq_match:
                    val = eq_match.group(0).split("=", 1)[1].strip().strip("'\"")
                    if val.isdigit() or re.fullmatch(r"[a-fA-F0-9\-]{16,}", val):
                        findings.append({
                            "rule": "HARDCODED_WHERE",
                            "severity": "high",
                            "line": i,
                            "message": "Hardcoded value in WHERE clause",
                        })

        if "JOIN" in stripped and " ON " not in stripped:
            findings.append({
                "rule": "JOIN_NO_ON",
                "severity": "high",
                "line": i,
                "message": "JOIN without ON clause",
            })

    return {
        "file_path": str(file_path),
        "findings": findings,
        "queries": queries,
        "line_count": len(lines),
    }
