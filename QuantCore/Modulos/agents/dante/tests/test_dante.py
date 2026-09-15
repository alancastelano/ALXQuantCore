"""DANTE core tests — knowledge base, config, orchestrator."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from dante.config import DanteConfig, config
from dante.core.knowledge import KnowledgeBase
from dante.core.git_utils import is_git_repo, get_branch


class TestConfig:
    def test_config_has_llm(self):
        assert hasattr(config, "llm")

    def test_config_has_scan(self):
        assert hasattr(config, "scan")

    def test_config_has_report(self):
        assert hasattr(config, "report")

    def test_scan_excludes(self):
        assert "__pycache__" in config.scan.exclude_dirs
        assert ".venv" in config.scan.exclude_dirs


class TestKnowledgeBase:
    def setup_method(self):
        self.kb = KnowledgeBase(db_path=Path("test_dante.duckdb"))

    def teardown_method(self):
        self.kb.close()
        p = Path("test_dante.duckdb")
        if p.exists():
            p.unlink()

    def test_init_schema(self):
        stats = self.kb.get_stats()
        assert stats["files"] == 0
        assert stats["findings"] == 0

    def test_upsert_file(self):
        self.kb.upsert_file("/test.py", "python", 100, "abc123")
        assert self.kb.file_exists("/test.py", "abc123")
        assert not self.kb.file_exists("/test.py", "wrong_hash")

    def test_add_finding(self):
        self.kb.upsert_file("/test.py", "python", 100, "abc123")
        self.kb.add_finding("/test.py", 10, "PY-7.1", "high", "Bare except", "bare_except")
        findings = self.kb.get_findings("/test.py")
        assert len(findings) == 1
        assert findings[0]["rule_id"] == "PY-7.1"

    def test_add_findings_batch(self):
        self.kb.upsert_file("/test.py", "python", 100, "abc123")
        batch = [
            {"file_path": "/test.py", "line": i, "rule_id": f"PY-{i}",
             "severity": "low", "message": f"finding {i}", "category": "test"}
            for i in range(5)
        ]
        self.kb.add_findings_batch(batch)
        findings = self.kb.get_findings("/test.py")
        assert len(findings) == 5

    def test_replace_findings_for_file(self):
        self.kb.add_finding("/test.py", 1, "PY-1", "high", "old", "test")
        self.kb.replace_findings_for_file("/test.py", [{
            "file_path": "/test.py", "line": 2, "rule_id": "PY-2",
            "severity": "low", "message": "new", "category": "test",
        }])
        findings = self.kb.get_findings("/test.py")
        assert len(findings) == 1
        assert findings[0]["rule_id"] == "PY-2"

    def test_upsert_summary(self):
        self.kb.upsert_summary("/test.py", "first")
        self.kb.upsert_summary("/test.py", "second")
        row = self.kb.conn.execute(
            "SELECT summary FROM summaries WHERE file_path = ?", ["/test.py"]
        ).fetchone()
        assert row == ("second",)

    def test_clear_session_clears_index(self):
        self.kb.upsert_file("/test.py", "python", 1, "hash")
        self.kb.clear_session()
        assert self.kb.get_stats()["files"] == 0

    def test_clear_session(self):
        self.kb.upsert_file("/test.py", "python", 100, "abc123")
        self.kb.add_finding("/test.py", 1, "PY-7.1", "high", "test", "test")
        self.kb.clear_session()
        findings = self.kb.get_findings()
        assert len(findings) == 0

    def test_get_stats(self):
        self.kb.upsert_file("/a.py", "python", 100, "h1")
        self.kb.upsert_file("/b.py", "python", 200, "h2")
        self.kb.add_finding("/a.py", 1, "PY-7.1", "high", "test", "test")
        self.kb.add_finding("/b.py", 1, "PY-7.2", "critical", "test", "test")
        stats = self.kb.get_stats()
        assert stats["files"] == 2
        assert stats["findings"] == 2
        assert stats["by_severity"]["high"] == 1
        assert stats["by_severity"]["critical"] == 1

    def test_context_manager(self):
        with KnowledgeBase(db_path=Path("test_dante_ctx.duckdb")) as kb:
            stats = kb.get_stats()
            assert stats["files"] == 0
        p = Path("test_dante_ctx.duckdb")
        if p.exists():
            p.unlink()


class TestGitUtils:
    def test_is_git_repo(self):
        result = is_git_repo(Path("C:\\ALXQuant"))
        assert isinstance(result, bool)

    def test_get_branch(self):
        branch = get_branch(Path("C:\\ALXQuant"))
        assert isinstance(branch, str)
