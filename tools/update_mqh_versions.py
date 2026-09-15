#!/usr/bin/env python3
"""
Update all active MQH modules to major 10 version.
Updates #property version and adds changelog entry for renumber.
"""

import re
from pathlib import Path

ROOT = Path(__file__).parent.parent

VERSION_MAP = {
    # Core
    "Core/enums.mqh": "10.0",
    "Core/Design.mqh": "10.0",
    "Core/Panel.mqh": "10.0",
    "Core/Telegram.mqh": "10.0",
    "Core/StopLoss.mqh": "10.0",
    "Core/Timefilter.mqh": "10.0",
    "Core/TrailingStop.mqh": "10.0",
    # Modules
    "Modules/Execution.mqh": "10.0",  # was 7.64, already at 10.0.1 in manifest
    "Modules/MacroRegimeEngine.mqh": "10.1",  # major bump due to recent changes
    "Modules/DataMiner.mqh": "10.0",
    "Modules/RiskManager.mqh": "10.0",
    "Modules/RiskSentiment.mqh": "10.0",
    "Modules/HumanBehavior.mqh": "10.0",
    "Modules/NewsFilter.mqh": "10.0",
    "Modules/Timefilter.mqh": "10.0",
    "Modules/AccountProtector.mqh": "10.0",
    "Modules/StatsTracker.mqh": "10.0",
    "Modules/SessionProfile.mqh": "10.0",
    "Modules/PortfolioRisk.mqh": "10.0",
    # Strategy
    "Strategy/TrendFollowing.mqh": "10.0",
    "Strategy/MeanReversal.mqh": "10.0",
    "Strategy/MeanReversalAdvanced.mqh": "10.0",
    "Strategy/MeanReversalStrategy.mqh": "10.0",
    "Strategy/RangeBreakout.mqh": "10.0",
    "Strategy/SessionBreakout.mqh": "10.0",
    "Strategy/TrendAdaptative.mqh": "10.0",
    "Strategy/CustomIndicators.mqh": "10.0",
    "Strategy/ALXQuantStrategy.mqh": "10.0",
    # Root
    "Terminal.mqh": "10.0",
    "ALXQuantCore.mqh": "10.0",
    "Policy.mqh": "10.2",  # already 10.x
}


def update_mqh_version(file_path: Path, new_version: str) -> bool:
    # Try UTF-8 first, fallback to Windows-1252
    try:
        content = file_path.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        content = file_path.read_text(encoding='cp1252')
    original = content

    # Update #property version (2 segments: major.minor)
    prop_pattern = r'(#property\s+version\s+)"[^"]*"'
    new_prop = f'#property version "{new_version}"'
    content = re.sub(prop_pattern, new_prop, content)

    # Update header version comment (//| vX.Y.Z |)
    header_pattern = r'(//\| v)[\d.]+\.?\d*\s*\|'
    new_header = f'//| v{new_version}.0 |'
    content = re.sub(header_pattern, new_header, content)

    # Add changelog entry for renumber
    # Find the changelog block after #property version
    changelog_pattern = r'(#property\s+version\s+"[^"]*"\s*\n)(/\*\n)'
    def add_changelog(match):
        prefix = match.group(1)
        block_start = match.group(2)
        today = "2026-08-24"
        changelog_entry = f"""/*
    v.{new_version} - {today} - Change: Renumber to major 10 platform alignment (was {get_old_version(original)}).
"""
        return prefix + changelog_entry + block_start

    # Try to find and inject changelog
    if '/*' in content and '*/' in content and 'v.' in content:
        # Find the first changelog block after property
        lines = content.split('\n')
        for i, line in enumerate(lines):
            if line.strip().startswith('/*') and i > 0 and '#property version' in lines[i-1]:
                # Insert after /*
                indent = len(line) - len(line.lstrip())
                lines.insert(i+1, f"    v.{new_version} - 2026-08-24 - Change: Renumber to major 10 platform alignment.")
                content = '\n'.join(lines)
                break

    if content != original:
        file_path.write_text(content, encoding='utf-8')
        return True
    return False


def get_old_version(content: str) -> str:
    """Extract old version from property or header."""
    m = re.search(r'#property\s+version\s+"([^"]+)"', content)
    if m:
        return m.group(1)
    m = re.search(r'//\| v([\d.]+)', content)
    if m:
        return m.group(1)
    return "unknown"


def main():
    mql5_include = ROOT / "MQL5" / "MQL5" / "Include" / "ALXQuantCore"
    updated = 0
    for rel_path, new_ver in VERSION_MAP.items():
        file_path = mql5_include / rel_path
        if file_path.exists():
            if update_mqh_version(file_path, new_ver):
                print(f"Updated: {rel_path} -> {new_ver}")
                updated += 1
            else:
                print(f"No change: {rel_path}")
        else:
            print(f"NOT FOUND: {rel_path}")
    print(f"\nTotal updated: {updated}")


if __name__ == "__main__":
    main()