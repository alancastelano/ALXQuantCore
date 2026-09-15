#!/usr/bin/env python3
"""
Import Calendar.csv into DuckDB calendar_events table.

Reads the MQL5 CSV, normalizes impact to titlecase, and replaces all data
in the calendar_events table.
"""

import csv
import os
import sys
import time

APP_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, APP_ROOT)

DB_PATH = os.path.join(APP_ROOT, "data", "ALXQuantCore.duckdb")
CSV_PATH = os.path.join(APP_ROOT, "data", "Calendar.csv")

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


def parse_date_to_epoch(date_str, time_str):
    """Convert 'YYYY.MM.DD' + 'HH:MM' to epoch seconds (UTC)."""
    from datetime import datetime, timezone
    try:
        dt_str = f"{date_str} {time_str}"
        dt = datetime.strptime(dt_str, "%Y.%m.%d %H:%M")
        dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    except (ValueError, TypeError):
        return None


def parse_value(raw):
    """Extract numeric value from strings like '55.2', '7.33M', '205K'."""
    if not raw or not raw.strip():
        return None
    s = raw.strip()
    multiplier = 1.0
    if s.endswith(("M", "m")) and not s.replace(".", "").replace("-", "").isdigit():
        multiplier = 1_000_000; s = s[:-1]
    elif s.endswith(("K", "k")) and not s.replace(".", "").replace("-", "").isdigit():
        multiplier = 1_000; s = s[:-1]
    elif s.endswith(("B", "b")):
        multiplier = 1_000_000_000; s = s[:-1]
    try:
        return float(s) * multiplier
    except ValueError:
        return None


def normalize_impact(raw):
    """Normalize impact to titlecase. Keep original value if not recognized."""
    mapping = {
        "LOW": "Low",
        "MEDIUM": "Medium",
        "HIGH": "High",
        "HOLIDAY/SPEAKER": "Holiday/Speaker",
        "HOLIDAY": "Holiday",
        "SPEAKER": "Speaker",
    }
    return mapping.get(raw.strip().upper(), raw.strip())


def import_csv():
    if not os.path.exists(CSV_PATH):
        print(f"CSV not found: {CSV_PATH}")
        sys.exit(1)

    conn = _get_connection()
    try:
        # Clear existing data
        count_before = conn.execute("SELECT COUNT(*) FROM calendar_events").fetchone()[0]
        print(f"Existing rows: {count_before}")
        conn.execute("DELETE FROM calendar_events")
        print("Cleared calendar_events table")

        # Read CSV
        rows = []
        skipped = 0
        with open(CSV_PATH, "r", encoding="utf-8-sig") as f:
            for i, line in enumerate(f):
                if i < 2:  # skip timezone comment and header
                    continue
                parts = line.strip().split(",")
                if len(parts) < 4:
                    skipped += 1
                    continue

                date_str, time_str, event_name, impact = parts[0], parts[1], parts[2], parts[3]
                actual = parts[4] if len(parts) > 4 else ""
                previous = parts[5] if len(parts) > 5 else ""
                forecast = parts[6] if len(parts) > 6 else ""

                epoch = parse_date_to_epoch(date_str, time_str)
                if epoch is None:
                    skipped += 1
                    continue

                rows.append((
                    epoch,
                    event_name.strip(),
                    normalize_impact(impact),
                    (parts[4] if len(parts) > 4 else "").strip().upper(),  # currency (Pais)
                    parse_value(actual),
                    parse_value(previous),
                    parse_value(forecast),
                ))

        print(f"Parsed {len(rows)} rows, skipped {skipped}")

        # Insert in batches
        batch_size = 5000
        inserted = 0
        for start in range(0, len(rows), batch_size):
            batch = rows[start:start + batch_size]
            conn.executemany("""
                INSERT INTO calendar_events (event_time, event_name, impact, currency, actual, previous, forecast)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, batch)
            inserted += len(batch)
            if inserted % 20000 == 0:
                print(f"  Inserted {inserted}/{len(rows)}...")

        print(f"Total inserted: {inserted}")

        # Show result
        print("\nImpact distribution:")
        for r in conn.execute("SELECT impact, COUNT(*) FROM calendar_events GROUP BY impact ORDER BY COUNT(*) DESC").fetchall():
            print(f"  {r[0]:30s} : {r[1]}")

        total = conn.execute("SELECT COUNT(*) FROM calendar_events").fetchone()[0]
        print(f"\nTotal rows: {total}")

    finally:
        conn.close()


if __name__ == "__main__":
    import_csv()
