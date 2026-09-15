"""
DuckDB persistence for ForexFactory calendar events.

Uses the existing calendar_events table in ALXQuantCore.duckdb.
Handles upserts (INSERT OR REPLACE) keyed on (event_time, event_name, currency).
"""

import logging
import os
import time
from typing import Any

import duckdb

logger = logging.getLogger(__name__)

DB_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "data", "ALXQuantCore.duckdb")


def _get_connection(read_only: bool = False, retries: int = 5, retry_delay: float = 0.5) -> duckdb.DuckDBPyConnection:
    """Open DuckDB with retry for Windows file locks."""
    if not os.path.exists(DB_PATH):
        raise FileNotFoundError(f"Database not found: {DB_PATH}")
    last_err = None
    for attempt in range(retries):
        try:
            return duckdb.connect(DB_PATH, read_only=read_only)
        except Exception as e:
            msg = str(e).lower()
            is_lock = any(k in msg for k in ("already in use", "sendo usado", "io error",
                                               "different configuration", "configuração"))
            if is_lock and attempt < retries - 1:
                last_err = e
                time.sleep(retry_delay * (attempt + 1))
            else:
                raise
    raise last_err


def store_events(rows: list[dict]) -> int:
    """
    Insert calendar events into DuckDB (delete + insert for dedup).

    Use this for full CSV imports where you want to replace all data.
    For weekly FF fetches, use upsert_events() instead.
    """
    if not rows:
        return 0

    conn = _get_connection()
    try:
        try:
            conn.execute("CREATE SEQUENCE IF NOT EXISTS calendar_events_id_seq START 1")
        except Exception:
            pass

        conn.execute("""
            CREATE TABLE IF NOT EXISTS calendar_events (
                id BIGINT DEFAULT nextval('calendar_events_id_seq'),
                event_time BIGINT,
                event_name VARCHAR,
                impact VARCHAR,
                currency VARCHAR,
                actual DOUBLE,
                previous DOUBLE,
                forecast DOUBLE
            )
        """)

        inserted = 0
        for row in rows:
            try:
                conn.execute("""
                    DELETE FROM calendar_events
                    WHERE event_time = ? AND event_name = ? AND currency = ?
                """, [row["event_time"], row["event_name"], row["currency"]])

                conn.execute("""
                    INSERT INTO calendar_events (event_time, event_name, impact, currency, actual, previous, forecast)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [
                    row["event_time"], row["event_name"], row["impact"], row["currency"],
                    row.get("actual"), row.get("previous"), row.get("forecast"),
                ])
                inserted += 1
            except Exception as e:
                logger.warning("Failed to insert event %s: %s", row.get("event_name"), e)

        return inserted
    finally:
        conn.close()


def upsert_events(rows: list[dict]) -> dict:
    """
    Smart merge: insert new events, update existing ones.

    ForexFactory has PRIORITY over MQL5 CSV data.
    Rules for existing events (matched by event_time + event_name + currency):
    - forecast: update if FF provides a non-NULL value
    - previous: update if FF provides a non-NULL value
    - actual: update if FF provides a non-NULL value
    - impact: always update to FF value

    Returns dict with counts: {inserted, updated, unchanged}.
    """
    if not rows:
        return {"inserted": 0, "updated": 0, "unchanged": 0}

    conn = _get_connection()
    try:
        try:
            conn.execute("CREATE SEQUENCE IF NOT EXISTS calendar_events_id_seq START 1")
        except Exception:
            pass

        conn.execute("""
            CREATE TABLE IF NOT EXISTS calendar_events (
                id BIGINT DEFAULT nextval('calendar_events_id_seq'),
                event_time BIGINT,
                event_name VARCHAR,
                impact VARCHAR,
                currency VARCHAR,
                actual DOUBLE,
                previous DOUBLE,
                forecast DOUBLE
            )
        """)

        inserted = 0
        updated = 0
        unchanged = 0

        for row in rows:
            try:
                # Check if event already exists
                existing = conn.execute("""
                    SELECT id, actual, forecast, previous, impact
                    FROM calendar_events
                    WHERE event_time = ? AND event_name = ? AND currency = ?
                    LIMIT 1
                """, [row["event_time"], row["event_name"], row["currency"]]).fetchone()

                if existing is None:
                    # New event -> INSERT
                    conn.execute("""
                        INSERT INTO calendar_events (event_time, event_name, impact, currency, actual, previous, forecast)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [
                        row["event_time"], row["event_name"], row["impact"], row["currency"],
                        row.get("actual"), row.get("previous"), row.get("forecast"),
                    ])
                    inserted += 1
                else:
                    # Existing event -> FF has priority, update all non-NULL values
                    _id, cur_actual, cur_forecast, cur_previous, cur_impact = existing
                    new_forecast = row.get("forecast")
                    new_previous = row.get("previous")
                    new_actual = row.get("actual")
                    new_impact = row.get("impact")

                    # FF has priority: update if new value is not NULL
                    upd_forecast = new_forecast if new_forecast is not None else cur_forecast
                    upd_previous = new_previous if new_previous is not None else cur_previous
                    upd_actual = new_actual if new_actual is not None else cur_actual
                    upd_impact = new_impact if new_impact else cur_impact

                    # Check if anything changed
                    if (upd_forecast != cur_forecast or upd_previous != cur_previous
                            or upd_actual != cur_actual or upd_impact != cur_impact):
                        conn.execute("""
                            UPDATE calendar_events
                            SET forecast = ?, previous = ?, actual = ?, impact = ?
                            WHERE event_time = ? AND event_name = ? AND currency = ?
                        """, [upd_forecast, upd_previous, upd_actual, upd_impact,
                              row["event_time"], row["event_name"], row["currency"]])
                        updated += 1
                    else:
                        unchanged += 1

            except Exception as e:
                logger.warning("Failed to upsert event %s: %s", row.get("event_name"), e)

        return {"inserted": inserted, "updated": updated, "unchanged": unchanged}
    finally:
        conn.close()


def get_events(
    currency: str | None = None,
    impact: str | None = None,
    impacts: list[str] | None = None,
    days: int | None = None,
    search: str | None = None,
    limit: int = 200,
) -> list[dict[str, Any]]:
    """
    Query calendar_events with optional filters.

    Returns list of dicts ordered by event_time ascending.
    """
    conn = _get_connection(read_only=True)
    try:
        conditions = []
        params: list[Any] = []

        now_ts = int(time.time())

        if days is not None and days > 0:
            future_ts = now_ts + days * 86400
            conditions.append("event_time >= ?")
            params.append(now_ts)
            conditions.append("event_time <= ?")
            params.append(future_ts)

        if currency:
            conditions.append("UPPER(currency) = UPPER(?)")
            params.append(currency)

        if impacts:
            placeholders = ", ".join(["?"] * len(impacts))
            conditions.append(f"UPPER(impact) IN ({placeholders})")
            params.extend([i.upper() for i in impacts])
        elif impact:
            conditions.append("UPPER(impact) = UPPER(?)")
            params.append(impact)

        if search:
            conditions.append("LOWER(event_name) LIKE LOWER(?)")
            params.append(f"%{search}%")

        where = ""
        if conditions:
            where = "WHERE " + " AND ".join(conditions)

        query = f"""
            SELECT id, event_time, event_name, impact, currency,
                   actual, previous, forecast
            FROM calendar_events
            {where}
            ORDER BY event_time ASC
            LIMIT ?
        """
        params.append(limit)

        result = conn.execute(query, params).fetchall()
        cols = ["id", "event_time", "event_name", "impact", "currency",
                "actual", "previous", "forecast"]
        return [dict(zip(cols, row)) for row in result]
    finally:
        conn.close()


def get_news_stats() -> dict:
    """Return summary statistics for the calendar_events table."""
    conn = _get_connection(read_only=True)
    try:
        total = conn.execute("SELECT COUNT(*) FROM calendar_events").fetchone()[0]

        # Future events only
        now_ts = int(time.time())
        upcoming = conn.execute(
            "SELECT COUNT(*) FROM calendar_events WHERE event_time >= ?", [now_ts]
        ).fetchone()[0]

        # By impact
        impact_rows = conn.execute("""
            SELECT impact, COUNT(*) as cnt
            FROM calendar_events
            WHERE event_time >= ?
            GROUP BY impact
            ORDER BY cnt DESC
        """, [now_ts]).fetchall()
        by_impact = {row[0]: row[1] for row in impact_rows}

        # By currency (top 15)
        currency_rows = conn.execute("""
            SELECT currency, COUNT(*) as cnt
            FROM calendar_events
            WHERE event_time >= ?
            GROUP BY currency
            ORDER BY cnt DESC
            LIMIT 15
        """, [now_ts]).fetchall()
        by_currency = {row[0]: row[1] for row in currency_rows}

        # Last fetch time (most recent event_time)
        max_ts = conn.execute(
            "SELECT MAX(event_time) FROM calendar_events"
        ).fetchone()[0]

        return {
            "total": total,
            "upcoming": upcoming,
            "by_impact": by_impact,
            "by_currency": by_currency,
            "last_event_timestamp": max_ts,
        }
    finally:
        conn.close()
