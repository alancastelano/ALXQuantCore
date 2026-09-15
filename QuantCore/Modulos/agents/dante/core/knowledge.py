"""DANTE Knowledge Base — DuckDB storage for files, findings, summaries."""

import hashlib
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import duckdb

from ..config import DATA_DIR


class KnowledgeBase:
    """Manages DANTE's persistent knowledge store."""

    def __init__(self, db_path: Optional[Path] = None):
        if db_path is None:
            db_path = DATA_DIR / "dante.duckdb"
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self.db_path = db_path
        self.conn = duckdb.connect(str(db_path))
        self._init_schema()

    def _init_schema(self):
        self.conn.execute("""
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY,
                language TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                hash TEXT NOT NULL,
                indexed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        """)
        self.conn.execute("""
            CREATE SEQUENCE IF NOT EXISTS findings_seq START 1
        """)
        self.conn.execute("""
            CREATE TABLE IF NOT EXISTS findings (
                id INTEGER DEFAULT nextval('findings_seq'),
                file_path TEXT NOT NULL,
                line INTEGER,
                rule_id TEXT NOT NULL,
                severity TEXT NOT NULL,
                message TEXT NOT NULL,
                category TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'tool',
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        """)
        self.conn.execute("""
            CREATE TABLE IF NOT EXISTS summaries (
                file_path TEXT PRIMARY KEY,
                summary TEXT NOT NULL,
                generated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        """)

    def file_exists(self, file_path: str, file_hash: str) -> bool:
        result = self.conn.execute(
            "SELECT hash FROM files WHERE path = ?", [file_path]
        ).fetchone()
        if result is None:
            return False
        return result[0] == file_hash

    def upsert_file(self, file_path: str, language: str, size_bytes: int, file_hash: str):
        self.conn.execute("""
            INSERT INTO files (path, language, size_bytes, hash, indexed_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (path) DO UPDATE SET
                size_bytes = excluded.size_bytes,
                hash = excluded.hash,
                indexed_at = excluded.indexed_at
        """, [file_path, language, size_bytes, file_hash,
              datetime.now(timezone.utc).isoformat()])

    def add_finding(self, file_path: str, line: Optional[int], rule_id: str,
                    severity: str, message: str, category: str, source: str = "tool"):
        self.conn.execute("""
            INSERT INTO findings (file_path, line, rule_id, severity, message, category, source, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, [file_path, line, rule_id, severity, message, category, source,
              datetime.now(timezone.utc).isoformat()])

    def add_findings_batch(self, findings: list[dict]):
        if not findings:
            return
        now = datetime.now(timezone.utc).isoformat()
        rows = [
            (f["file_path"], f.get("line"), f["rule_id"], f["severity"],
             f["message"], f["category"], f.get("source", "tool"), now)
            for f in findings
        ]
        self.conn.executemany("""
            INSERT INTO findings (file_path, line, rule_id, severity, message, category, source, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, rows)

    def replace_findings_for_file(self, file_path: str, findings: list[dict]):
        """Replace findings for one file so removed issues do not persist."""
        self.conn.execute("DELETE FROM findings WHERE file_path = ?", [file_path])
        self.add_findings_batch(findings)

    def remove_missing_files(self, current_paths: set[str]):
        """Remove indexed files and findings no longer present in the target."""
        rows = self.conn.execute("SELECT path FROM files").fetchall()
        for (file_path,) in rows:
            if file_path not in current_paths:
                self.conn.execute("DELETE FROM findings WHERE file_path = ?", [file_path])
                self.conn.execute("DELETE FROM summaries WHERE file_path = ?", [file_path])
                self.conn.execute("DELETE FROM files WHERE path = ?", [file_path])

    def upsert_summary(self, file_path: str, summary: str):
        self.conn.execute("""
            INSERT INTO summaries (file_path, summary, generated_at)
            VALUES (?, ?, ?)
            ON CONFLICT (file_path) DO UPDATE SET
                summary = excluded.summary,
                generated_at = excluded.generated_at
        """, [file_path, summary, datetime.now(timezone.utc).isoformat()])

    def get_findings(self, file_path: Optional[str] = None,
                     severity: Optional[str] = None) -> list[dict]:
        query = "SELECT file_path, line, rule_id, severity, message, category, source FROM findings WHERE 1=1"
        params = []
        if file_path:
            query += " AND file_path = ?"
            params.append(file_path)
        if severity:
            query += " AND severity = ?"
            params.append(severity)
        query += " ORDER BY file_path, line"
        rows = self.conn.execute(query, params).fetchall()
        return [
            {"file_path": r[0], "line": r[1], "rule_id": r[2], "severity": r[3],
             "message": r[4], "category": r[5], "source": r[6]}
            for r in rows
        ]

    def get_stats(self) -> dict:
        files = self.conn.execute("SELECT COUNT(*) FROM files").fetchone()[0]
        findings = self.conn.execute("SELECT COUNT(*) FROM findings").fetchone()[0]
        by_severity = {}
        rows = self.conn.execute(
            "SELECT severity, COUNT(*) FROM findings GROUP BY severity"
        ).fetchall()
        for sev, count in rows:
            by_severity[sev] = count
        return {"files": files, "findings": findings, "by_severity": by_severity}

    def clear_session(self):
        self.conn.execute("DELETE FROM findings")
        self.conn.execute("DELETE FROM summaries")
        self.conn.execute("DELETE FROM files")

    def close(self):
        self.conn.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
