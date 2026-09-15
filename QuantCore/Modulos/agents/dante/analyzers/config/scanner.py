"""Config scanner — JSON, YAML, .env validation."""

import json
import os
import re
from pathlib import Path

ENV_SECRET_PATTERNS = [
    re.compile(r"(?:api[_-]?key|apikey|secret|password|token|credential)\s*=\s*\S+", re.IGNORECASE),
    re.compile(r"-----BEGIN\s+(RSA\s+)?PRIVATE\s+KEY-----", re.IGNORECASE),
]


def scan_config_files(target_dir: str) -> list[Path]:
    """Find all .json, .yaml, .yml, .env files."""
    target = Path(target_dir)
    if not target.exists():
        return []
    results = []
    for ext in ("*.json", "*.yaml", "*.yml", ".env"):
        if ext == ".env":
            results.extend(target.rglob(".env"))
            results.extend(target.rglob(".env.*"))
        else:
            results.extend(target.rglob(ext))
    ignored = {"node_modules", ".venv", "__pycache__", ".git", "dist", "build"}
    return [p for p in sorted(set(results))
            if not any(ig in p.parts for ig in ignored)]


def analyze_config(file_path: Path) -> list[dict]:
    """Analyze a single config file."""
    findings = []
    suffix = file_path.suffix.lower()
    name = file_path.name.lower()

    try:
        content = file_path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return findings

    if suffix == ".json":
        try:
            json.loads(content)
        except json.JSONDecodeError as e:
            findings.append({
                "file_path": str(file_path),
                "line": e.lineno,
                "rule_id": "CFG-01",
                "severity": "high",
                "message": f"Invalid JSON: {e.msg}",
                "category": "invalid_json",
                "source": "tool",
            })

    if name.startswith(".env"):
        for i, line in enumerate(content.splitlines(), 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            for pattern in ENV_SECRET_PATTERNS:
                if pattern.search(stripped):
                    findings.append({
                        "file_path": str(file_path),
                        "line": i,
                        "rule_id": "CFG-02",
                        "severity": "high",
                        "message": f"Potential secret in .env file",
                        "category": "env_secret",
                        "source": "tool",
                    })
                    break

    if suffix in (".yaml", ".yml"):
        for i, line in enumerate(content.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("---") or stripped.startswith("#") or not stripped:
                continue
            if ":" not in stripped:
                continue

    if suffix in (".json", ".yaml", ".yml", ".env"):
        try:
            mode = os.stat(file_path).st_mode
            if mode & 0o004:
                findings.append({
                    "file_path": str(file_path),
                    "line": None,
                    "rule_id": "CFG-04",
                    "severity": "low",
                    "message": f"Config file is world-readable (mode {oct(mode)[-3:]})",
                    "category": "world_readable",
                    "source": "tool",
                })
        except OSError:
            pass

    return findings
