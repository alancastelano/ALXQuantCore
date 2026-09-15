#!/usr/bin/env python3
"""
ALXQuant Release Tool
Enforces 10-step release flow with Git tags.
Usage:
  python tools/release.py --bump minor --message "Release v10.4.0"
  python tools/release.py --bump patch --dry-run
  python tools/release.py --version 10.5.0-rc.1 --message "RC"
"""

import argparse
import json
import subprocess
import sys
import re
from datetime import datetime, timezone
from pathlib import Path
from datetime import datetime
from typing import List, Tuple, Optional


ROOT = Path(__file__).parent.parent
VERSION_FILE = ROOT / "VERSION"
MANIFEST_FILE = ROOT / "manifest.json"
CHANGELOG_MQL = ROOT / "CHANGELOG_MQL.md"
CHANGELOG_PY = ROOT / "CHANGELOG_PYTHON.md"
README_FILE = ROOT / "README.md"


class ReleaseError(Exception):
    pass


def run_cmd(cmd: List[str], check: bool = True, capture: bool = True) -> subprocess.CompletedProcess:
    """Run command, return CompletedProcess."""
    result = subprocess.run(cmd, cwd=ROOT, capture_output=capture, text=True)
    if check and result.returncode != 0:
        raise ReleaseError(f"Command failed: {' '.join(cmd)}\n{result.stderr}")
    return result


def get_git_status() -> str:
    result = run_cmd(["git", "status", "--porcelain"])
    return result.stdout.strip()


def get_current_version() -> str:
    if VERSION_FILE.exists():
        return VERSION_FILE.read_text(encoding='utf-8').strip()
    return "0.0.0"


def parse_version(v: str) -> Tuple[int, int, int, str]:
    """Parse version string, return (major, minor, patch, suffix)."""
    # Handle v prefix
    v = v.lstrip('v')
    # Split version and suffix
    match = re.match(r'^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$', v)
    if not match:
        raise ReleaseError(f"Invalid version format: {v}")
    major, minor, patch = int(match.group(1)), int(match.group(2)), int(match.group(3))
    suffix = match.group(4) or ""
    return major, minor, patch, suffix


def format_version(major: int, minor: int, patch: int, suffix: str = "") -> str:
    v = f"{major}.{minor}.{patch}"
    if suffix:
        v += f"-{suffix}"
    return v


def bump_version(current: str, bump_type: str, suffix: str = "") -> str:
    major, minor, patch, _ = parse_version(current)
    if bump_type == "major":
        major += 1
        minor = 0
        patch = 0
    elif bump_type == "minor":
        minor += 1
        patch = 0
    elif bump_type == "patch":
        patch += 1
    else:
        raise ReleaseError(f"Invalid bump type: {bump_type}")
    return format_version(major, minor, patch, suffix)


def tag_exists(tag: str) -> bool:
    result = run_cmd(["git", "tag", "-l", tag], check=False)
    return tag in result.stdout


def validate_tag(tag: str, expected_commit: str) -> bool:
    result = run_cmd(["git", "rev-parse", tag], check=False)
    return result.returncode == 0 and result.stdout.strip() == expected_commit


def update_version_file(version: str) -> None:
    VERSION_FILE.write_text(version + "\n", encoding='utf-8')
    print(f"Updated {VERSION_FILE}: {version}")


def update_manifest_version(version: str) -> None:
    with open(MANIFEST_FILE, 'r', encoding='utf-8') as f:
        manifest = json.load(f)
    manifest['platform'] = version
    manifest['generated_at'] = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
    with open(MANIFEST_FILE, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    print(f"Updated {MANIFEST_FILE}: platform = {version}")

    # Regenerate Version.mqh
    run_cmd([sys.executable, "tools/gen_version_header.py"])


def prompt_changelog_entry(version: str, bump_type: str) -> str:
    """Generate changelog template for manual editing."""
    date = datetime.now().strftime("%Y-%m-%d")
    time_str = datetime.now().strftime("%H:%M")
    type_map = {"major": "MAJOR", "minor": "MINOR", "patch": "PATCH"}
    return f"""Version: {version}
Date: {date}
Time: {time_str}

Type: {type_map.get(bump_type, bump_type.upper())}

Files:
* (list modified files)

Description:
* (what changed)

Reason:
* (why)

Rollback:
* (git commit hash to rollback to)

---
"""


def prepend_changelog(changelog_path: Path, entry: str) -> None:
    """Prepend entry to changelog file."""
    if changelog_path.exists():
        content = changelog_path.read_text(encoding='utf-8')
    else:
        content = ""
    changelog_path.write_text(entry + "\n" + content, encoding='utf-8')
    print(f"Updated {changelog_path}")


def create_release_commit(version: str, message: str) -> str:
    run_cmd(["git", "add", "VERSION", "manifest.json", "MQL5/MQL5/Include/ALXQuantCore/Version.mqh",
             "CHANGELOG_MQL.md", "CHANGELOG_PYTHON.md", "README.md"])
    commit_msg = f"release: {version}\n\n{message}"
    result = run_cmd(["git", "commit", "-m", commit_msg])
    # Get commit hash
    result = run_cmd(["git", "rev-parse", "HEAD"])
    return result.stdout.strip()


def create_git_tag(tag: str, commit: str, message: str) -> None:
    run_cmd(["git", "tag", "-a", tag, "-m", f"Release {tag}\n\n{message}", commit])
    print(f"Created tag: {tag}")


def validate_git_tag(tag: str, commit: str) -> None:
    if not validate_tag(tag, commit):
        raise ReleaseError(f"Tag validation failed: {tag} does not point to {commit}")
    print(f"Validated tag: {tag} -> {commit}")


def main():
    parser = argparse.ArgumentParser(description="ALXQuant Release Tool")
    parser.add_argument("--bump", choices=["major", "minor", "patch"], help="Bump type")
    parser.add_argument("--version", help="Explicit version (overrides --bump)")
    parser.add_argument("--suffix", default="", help="Pre-release suffix (dev.N, rc.N, etc.)")
    parser.add_argument("--message", default="", help="Release message")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be done")
    args = parser.parse_args()

    # Step 1: Validate Git status
    print("=== Step 1: Validate Git status ===")
    status = get_git_status()
    if status and not args.dry_run:
        raise ReleaseError(f"Working tree not clean:\n{status}\nCommit or stash changes first.")
    print("Git status: clean" if not status else "Git status: has changes (dry-run)")

    # Step 2: Determine new version
    current = get_current_version()
    print(f"Current version: {current}")

    if args.version:
        new_version = args.version
    elif args.bump:
        new_version = bump_version(current, args.bump, args.suffix)
    else:
        raise ReleaseError("Must specify --bump or --version")

    print(f"New version: {new_version}")
    tag = f"v{new_version}"

    # Step 3: Check tag doesn't exist
    if tag_exists(tag):
        raise ReleaseError(f"Tag {tag} already exists. Use different version or delete tag first.")
    print(f"Tag {tag} available")

    if args.dry_run:
        print("\n=== DRY RUN COMPLETE ===")
        print(f"Would create version: {new_version}")
        print(f"Would create tag: {tag}")
        return 0

    # Step 4: Update VERSION file
    print("\n=== Step 4: Update VERSION ===")
    update_version_file(new_version)

    # Step 5: Update manifest
    print("\n=== Step 5: Update manifest ===")
    update_manifest_version(new_version)

    # Step 6: Update changelogs
    print("\n=== Step 6: Update changelogs ===")
    entry = prompt_changelog_entry(new_version, args.bump or "minor")
    print(f"Changelog entry template (edit {CHANGELOG_MQL} and {CHANGELOG_PY}):")
    print(entry)
    # Auto-prepend template to both changelogs
    prepend_changelog(CHANGELOG_MQL, entry)
    prepend_changelog(CHANGELOG_PY, entry)

    # Step 7: Run tests (placeholder)
    print("\n=== Step 7: Run tests ===")
    print("Running pytest...")
    result = run_cmd([sys.executable, "-m", "pytest", "Modulos/_versioning", "-v"], check=False)
    if result.returncode != 0:
        print("WARNING: Tests failed or not found. Continuing...")

    # Step 8: Create release commit
    print("\n=== Step 8: Create release commit ===")
    commit_msg = args.message or f"Release {new_version}"
    commit_hash = create_release_commit(new_version, commit_msg)
    print(f"Release commit: {commit_hash}")

    # Step 9: Create Git tag
    print("\n=== Step 9: Create Git tag ===")
    create_git_tag(tag, commit_hash, commit_msg)

    # Step 10: Validate tag
    print("\n=== Step 10: Validate Git tag ===")
    validate_git_tag(tag, commit_hash)

    print(f"\n=== RELEASE COMPLETE ===")
    print(f"Version: {new_version}")
    print(f"Tag: {tag}")
    print(f"Commit: {commit_hash}")
    print(f"Next: git push origin {tag}")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ReleaseError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nAborted.", file=sys.stderr)
        sys.exit(130)