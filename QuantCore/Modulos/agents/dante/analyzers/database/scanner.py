"""Database scanner — DuckDB schema, integrity, and size checks."""

from pathlib import Path

import duckdb


def scan_duckdb_files(target_dir: str) -> list[Path]:
    """Find all .duckdb files under target_dir."""
    target = Path(target_dir)
    if not target.exists():
        return []
    return sorted(target.rglob("*.duckdb"))


def analyze_database(db_path: Path) -> list[dict]:
    """Analyze a single DuckDB database file."""
    findings = []
    try:
        conn = duckdb.connect(str(db_path), read_only=True)
    except Exception as e:
        findings.append({
            "file_path": str(db_path),
            "line": None,
            "rule_id": "DB-06",
            "severity": "high",
            "message": f"Cannot open database: {e}",
            "category": "db_connection",
            "source": "tool",
        })
        return findings

    try:
        tables = conn.execute(
            "SELECT table_name FROM information_schema.tables WHERE table_schema = 'main'"
        ).fetchall()

        db_size_mb = db_path.stat().st_size / (1024 * 1024)
        if db_size_mb > 1024:
            findings.append({
                "file_path": str(db_path),
                "line": None,
                "rule_id": "DB-05",
                "severity": "info",
                "message": f"Database size {db_size_mb:.0f}MB exceeds 1GB",
                "category": "db_size",
                "source": "tool",
            })

        for (table_name,) in tables:
            cols = conn.execute(f"""
                SELECT column_name, data_type, is_nullable
                FROM information_schema.columns
                WHERE table_name = '{table_name}' AND table_schema = 'main'
                ORDER BY ordinal_position
            """).fetchall()

            has_pk = conn.execute(f"""
                SELECT COUNT(*) FROM information_schema.table_constraints
                WHERE table_name = '{table_name}' AND constraint_type = 'PRIMARY KEY'
            """).fetchone()[0]

            if not has_pk and cols:
                findings.append({
                    "file_path": str(db_path),
                    "line": None,
                    "rule_id": "DB-01",
                    "severity": "high",
                    "message": f"Table '{table_name}' has no PRIMARY KEY",
                    "category": "db_no_pk",
                    "source": "tool",
                })

            try:
                row_count = conn.execute(f"SELECT COUNT(*) FROM \"{table_name}\"").fetchone()[0]
                if row_count == 0:
                    findings.append({
                        "file_path": str(db_path),
                        "line": None,
                        "rule_id": "DB-02",
                        "severity": "medium",
                        "message": f"Table '{table_name}' is empty (0 rows)",
                        "category": "db_empty_table",
                        "source": "tool",
                    })
            except Exception:
                pass

            for col_name, col_type, nullable in cols:
                if col_type is None or col_type == "":
                    findings.append({
                        "file_path": str(db_path),
                        "line": None,
                        "rule_id": "DB-03",
                        "severity": "low",
                        "message": f"Column '{table_name}.{col_name}' has no explicit type",
                        "category": "db_no_type",
                        "source": "tool",
                    })

    except Exception as e:
        findings.append({
            "file_path": str(db_path),
            "line": None,
            "rule_id": "DB-07",
            "severity": "medium",
            "message": f"Schema analysis error: {e}",
            "category": "db_schema_error",
            "source": "tool",
        })
    finally:
        conn.close()

    return findings
