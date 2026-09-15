#!/usr/bin/env python3
"""
One-time script: Normalize impact CASE in calendar_events table.

Converts all impact values to consistent titlecase format.
Does NOT change any impact category — only fixes casing.
e.g., 'LOW' -> 'Low', 'high' -> 'High', 'HOLIDAY' -> 'Holiday'
"""

import os
import sys
import time

APP_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, APP_ROOT)

DB_PATH = os.path.join(APP_ROOT, "data", "ALXQuantCore.duckdb")

import duckdb


def _get_connection(retries=10, delay=1.0):
    last_err = None
    for attempt in range(retries):
        try:
            return duckdb.connect(DB_PATH, read_only=False)
        except Exception as e:
            msg = str(e).lower()
            is_lock = any(k in msg for k in ("already in use", "sendo usado", "io error"))
            if is_lock and attempt < retries - 1:
                last_err = e
                time.sleep(delay * (attempt + 1))
            else:
                raise
    raise last_err


def normalize_impact():
    """Normalize impact VALUES only (case), never change the category itself."""
    conn = _get_connection()
    try:
        before = conn.execute(
            "SELECT impact, COUNT(*) FROM calendar_events GROUP BY impact ORDER BY COUNT(*) DESC"
        ).fetchall()
        print("BEFORE:")
        for r in before:
            print(f"  {r[0]:30s} : {r[1]}")

        # Only normalize CASE — map each unique value to its titlecase form
        # This preserves every impact category, just fixes inconsistent casing
        case_map = {
            "LOW": "Low",
            "MEDIUM": "Medium",
            "HIGH": "High",
            "HOLIDAY": "Holiday",
            "SPEAKER": "Speaker",
            "low": "Low",
            "medium": "Medium",
            "high": "High",
            "holiday": "Holiday",
            "speaker": "Speaker",
        }

        updated = 0
        for old_val, new_val in case_map.items():
            if old_val == new_val:
                continue
            before_count = conn.execute(
                "SELECT COUNT(*) FROM calendar_events WHERE impact = ?", [old_val]
            ).fetchone()[0]
            if before_count == 0:
                continue
            conn.execute(
                "UPDATE calendar_events SET impact = ? WHERE impact = ?",
                [new_val, old_val]
            )
            print(f"  '{old_val}' -> '{new_val}': {before_count} rows")
            updated += before_count

        after = conn.execute(
            "SELECT impact, COUNT(*) FROM calendar_events GROUP BY impact ORDER BY COUNT(*) DESC"
        ).fetchall()
        print("\nAFTER:")
        for r in after:
            print(f"  {r[0]:30s} : {r[1]}")

        print(f"\nTotal updated: {updated}")
    finally:
        conn.close()


if __name__ == "__main__":
    normalize_impact()
