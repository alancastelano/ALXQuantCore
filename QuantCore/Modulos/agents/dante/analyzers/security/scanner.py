import re
from pathlib import Path

from ...config import config

_SECRET_PATTERNS = [
    {
        "rule_id": "SEC-01",
        "severity": "critical",
        "category": "hardcoded_secret",
        "pattern": re.compile(
            r"""(?:api[_-]?key|apikey|secret|password|token)\s*=\s*['"]([a-zA-Z0-9_\-]{16,})['"]""",
            re.IGNORECASE,
        ),
        "message": "Hardcoded API key or secret detected",
    },
    {
        "rule_id": "SEC-02",
        "severity": "high",
        "category": "env_exposure",
        "pattern": re.compile(
            r"""(?:open|read|load).*\.env""",
            re.IGNORECASE,
        ),
        "message": "Direct .env file read; use a config loader instead",
    },
    {
        "rule_id": "SEC-03",
        "severity": "high",
        "category": "credential_leak",
        "pattern": re.compile(
            r"""https?://[^:]+:[^@]+@""",
            re.IGNORECASE,
        ),
        "message": "HTTP URL contains embedded credentials",
    },
    {
        "rule_id": "SEC-04",
        "severity": "medium",
        "category": "encoded_secret",
        "pattern": re.compile(
            r"""(?:base64|b64)\s*[\(=].*[A-Za-z0-9+/]{40,}""",
            re.IGNORECASE,
        ),
        "message": "Possible base64-encoded secret",
    },
    {
        "rule_id": "SEC-05",
        "severity": "critical",
        "category": "private_key",
        "pattern": re.compile(
            r"""-----BEGIN\s+(RSA\s+)?PRIVATE\s+KEY-----""",
            re.IGNORECASE,
        ),
        "message": "Private key material found in source",
    },
    {
        "rule_id": "SEC-06",
        "severity": "high",
        "category": "hardcoded_secret",
        "pattern": re.compile(
            r"""(?:AWS_SECRET_ACCESS_SECRET|AWS_SECRET_KEY)\s*=\s*['"]([a-zA-Z0-9/+=]{40,})['"]""",
            re.IGNORECASE,
        ),
        "message": "Hardcoded AWS secret key detected",
    },
    {
        "rule_id": "SEC-07",
        "severity": "medium",
        "category": "hardcoded_secret",
        "pattern": re.compile(
            r"""(?:connection_string|conn_str|dsn)\s*=\s*['"]\w+://.*:(.+)@""",
            re.IGNORECASE,
        ),
        "message": "Connection string with embedded password detected",
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
        for rule in _SECRET_PATTERNS:
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
