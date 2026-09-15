"""Structure scanner — directory tree, obsolete files, duplicates, naming."""

import hashlib
from pathlib import Path

BACKUP_EXTENSIONS = {".bak", ".old", ".tmp", ".orig", ".swp", ".swo", "~"}
IGNORED_DIRS = {"__pycache__", ".venv", ".git", "node_modules", ".ruff_cache", ".pytest_cache"}


def scan_structure(target_dir: str) -> list[dict]:
    """Scan directory structure for issues."""
    findings = []
    target = Path(target_dir)
    if not target.exists():
        return findings

    seen_hashes: dict[str, list[Path]] = {}

    for root, dirs, files in Path(target_dir).walk():
        dirs[:] = [d for d in dirs if d not in IGNORED_DIRS]

        if not files and not dirs:
            findings.append({
                "file_path": str(root),
                "line": None,
                "rule_id": "STR-01",
                "severity": "low",
                "message": f"Empty directory: {root.relative_to(target)}",
                "category": "empty_dir",
                "source": "tool",
            })

        for fn in files:
            fp = root / fn
            try:
                size = fp.stat().st_size
            except OSError:
                continue

            if size > 1_000_000:
                findings.append({
                    "file_path": str(fp),
                    "line": None,
                    "rule_id": "STR-02",
                    "severity": "medium",
                    "message": f"Large file ({size // 1024}KB): {fp.relative_to(target)}",
                    "category": "large_file",
                    "source": "tool",
                })

            suffix = fp.suffix.lower()
            if suffix in BACKUP_EXTENSIONS or fn.endswith("~"):
                findings.append({
                    "file_path": str(fp),
                    "line": None,
                    "rule_id": "STR-03",
                    "severity": "medium",
                    "message": f"Backup/temporary file: {fp.relative_to(target)}",
                    "category": "backup_file",
                    "source": "tool",
                })

            if not suffix:
                findings.append({
                    "file_path": str(fp),
                    "line": None,
                    "rule_id": "STR-06",
                    "severity": "low",
                    "message": f"File without extension: {fp.relative_to(target)}",
                    "category": "no_extension",
                    "source": "tool",
                })

            if size > 0 and size < 10_000_000:
                try:
                    file_hash = hashlib.sha256(fp.read_bytes()).hexdigest()
                    seen_hashes.setdefault(file_hash, []).append(fp)
                except OSError:
                    pass

    for hash_val, paths in seen_hashes.items():
        if len(paths) > 1:
            rel_paths = [str(p.relative_to(target)) for p in paths]
            findings.append({
                "file_path": rel_paths[0],
                "line": None,
                "rule_id": "STR-04",
                "severity": "medium",
                "message": f"Duplicate files (SHA256 match): {', '.join(rel_paths)}",
                "category": "duplicate_file",
                "source": "tool",
            })

    return findings
