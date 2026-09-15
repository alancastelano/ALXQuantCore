"""Git utilities for DANTE — branch, diff, commit info."""

import subprocess
from pathlib import Path
from typing import Optional


def run_git(args: list[str], cwd: Optional[Path] = None) -> Optional[str]:
    try:
        result = subprocess.run(
            ["git"] + args,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        return None
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None


def get_branch(cwd: Optional[Path] = None) -> str:
    return run_git(["rev-parse", "--abbrev-ref", "HEAD"], cwd) or "unknown"


def get_commit_hash(cwd: Optional[Path] = None) -> str:
    return run_git(["rev-parse", "--short", "HEAD"], cwd) or "unknown"


def get_diff(target: str = "HEAD", cwd: Optional[Path] = None) -> str:
    return run_git(["diff", target, "--name-only"], cwd) or ""


def get_diff_files(cwd: Optional[Path] = None) -> list[str]:
    diff = get_diff("HEAD", cwd)
    if not diff:
        return []
    return [f for f in diff.split("\n") if f.strip()]


def is_git_repo(path: Optional[Path] = None) -> bool:
    return run_git(["rev-parse", "--is-inside-work-tree"], path) == "true"
