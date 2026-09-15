#!/usr/bin/env python3
"""
ForexFactory Calendar Collector.

Downloads the weekly economic calendar from ForexFactory's free JSON API
and stores events in DuckDB calendar_events table.

Strategy: 1 request per week (thisweek.json only). The JSON already covers
Mon-Fri of the current week. No need for nextweek or frequent fetches.
"""

import argparse
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone, timedelta

import requests

logger = logging.getLogger(__name__)

FF_URL_THISWEEK = "https://nfs.faireconomy.media/ff_calendar_thisweek.json"

REQUEST_TIMEOUT = 15  # seconds


# ---------------------------------------------------------------------------
# Collector
# ---------------------------------------------------------------------------

def _fetch_json(url: str) -> list[dict] | None:
    """Fetch JSON from ForexFactory. Single attempt, no retries to avoid blocks."""
    try:
        resp = requests.get(url, timeout=REQUEST_TIMEOUT)
        resp.raise_for_status()
        data = resp.json()
        if isinstance(data, list):
            return data
        logger.warning("Unexpected JSON structure from %s", url)
        return None
    except Exception as exc:
        logger.error("Failed to fetch %s: %s", url, exc)
        return None


def _parse_impact(raw: str) -> str:
    mapping = {"high": "HIGH", "medium": "MEDIUM", "low": "LOW",
               "holiday": "HOLIDAY", "speaker": "SPEAKER"}
    return mapping.get(raw.strip().lower(), raw.strip().upper() or "LOW")


def _parse_value(raw: str | None) -> float | None:
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


def _parse_date_to_epoch(date_str: str) -> int | None:
    try:
        return int(datetime.fromisoformat(date_str).timestamp())
    except (ValueError, TypeError):
        return None


def normalize_events(raw_events: list[dict]) -> list[dict]:
    rows = []
    for ev in raw_events:
        epoch = _parse_date_to_epoch(ev.get("date", ""))
        if epoch is None:
            continue
        rows.append({
            "event_time": epoch,
            "event_name": (ev.get("title") or "").strip(),
            "impact": _parse_impact(ev.get("impact", "")),
            "currency": (ev.get("country") or "").strip().upper(),
            "actual": _parse_value(ev.get("actual")),
            "forecast": _parse_value(ev.get("forecast")),
            "previous": _parse_value(ev.get("previous")),
        })
    return rows


def fetch_thisweek() -> list[dict] | None:
    """Fetch this week's calendar (single request)."""
    raw = _fetch_json(FF_URL_THISWEEK)
    if raw is None:
        return None
    return normalize_events(raw)


def should_fetch() -> bool:
    """Check if we need to fetch: only if no data for the current week exists."""
    from Modulos.news.calendar_store import _get_connection
    try:
        conn = _get_connection(read_only=True)
        # Check if we have any events for the current ISO week
        now = datetime.now()
        week_start = now - timedelta(days=now.weekday())
        week_start_ts = int(week_start.replace(hour=0, minute=0, second=0).timestamp())
        row = conn.execute(
            "SELECT COUNT(*) FROM calendar_events WHERE event_time >= ?",
            [week_start_ts]
        ).fetchone()
        conn.close()
        count = row[0] if row else 0
        logger.info("Current week events in DB: %d", count)
        return count < 5  # Less than 5 events = needs fetch
    except Exception as exc:
        logger.warning("Freshness check failed: %s", exc)
        return True  # On error, try to fetch


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="ForexFactory Calendar Collector")
    parser.add_argument("--fetch", action="store_true", help="Fetch and store calendar")
    parser.add_argument("--force", action="store_true", help="Force fetch even if data exists")
    parser.add_argument("--log", type=str, default=None, help="Log to file (optional)")
    args = parser.parse_args()

    log_handlers = [logging.StreamHandler()]
    if args.log:
        os.makedirs(os.path.dirname(args.log), exist_ok=True)
        log_handlers.append(logging.FileHandler(args.log, encoding="utf-8"))
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        handlers=log_handlers,
    )

    if not args.fetch:
        parser.print_help()
        return

    if not args.force and not should_fetch():
        logger.info("Data is fresh, skipping fetch")
        return

    logger.info("Fetching ForexFactory calendar (thisweek)...")
    rows = fetch_thisweek()
    if not rows:
        logger.error("No events fetched")
        sys.exit(1)

    logger.info("Fetched %d events", len(rows))

    # Verify: check dates are UTC, log summary
    from datetime import datetime, timezone
    if rows:
        min_ts = min(r["event_time"] for r in rows)
        max_ts = max(r["event_time"] for r in rows)
        min_dt = datetime.fromtimestamp(min_ts, tz=timezone.utc)
        max_dt = datetime.fromtimestamp(max_ts, tz=timezone.utc)
        logger.info("Date range: %s to %s (UTC)", min_dt.strftime("%Y-%m-%d %H:%M"), max_dt.strftime("%Y-%m-%d %H:%M"))

        # Impact summary
        impacts = {}
        for r in rows:
            imp = r["impact"]
            impacts[imp] = impacts.get(imp, 0) + 1
        logger.info("Impact breakdown: %s", impacts)

        # High-impact events
        high = [r for r in rows if r["impact"] == "HIGH"]
        if high:
            logger.info("High-impact events:")
            for r in high:
                dt = datetime.fromtimestamp(r["event_time"], tz=timezone.utc)
                logger.info("  %s | %s | %s", dt.strftime("%Y-%m-%d %H:%M"), r["currency"], r["event_name"])

    from Modulos.news.calendar_store import upsert_events
    result = upsert_events(rows)
    logger.info("Upsert: inserted=%d, updated=%d, unchanged=%d",
                result["inserted"], result["updated"], result["unchanged"])


if __name__ == "__main__":
    main()
