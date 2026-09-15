"""DANTE configuration."""

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent
ALXQUANT_ROOT = PROJECT_ROOT.parent.parent
DATA_DIR = ALXQUANT_ROOT / "data"

@dataclass
class LLMConfig:
    provider: str = os.getenv("DANTE_LLM_PROVIDER", "openai")
    model: str = os.getenv("DANTE_LLM_MODEL", "gpt-4o-mini")
    api_key: str = os.getenv("OPENAI_API_KEY", "")
    base_url: str = os.getenv("DANTE_LLM_BASE_URL", "")
    temperature: float = 0.1
    max_tokens: int = 4096

@dataclass
class ScanConfig:
    target_dir: Path = field(default_factory=lambda: ALXQUANT_ROOT)
    include_extensions: tuple = (".mq5", ".mqh", ".py", ".sql")
    exclude_dirs: tuple = (
        "__pycache__", ".venv", ".git", "node_modules",
        ".ruff_cache", ".pytest_cache", "build", "dist",
        "__old", "_old_not_used",
    )
    max_file_size_kb: int = 500

@dataclass
class ReportConfig:
    output_dir: Path = field(default_factory=lambda: PROJECT_ROOT / "reports")
    format: str = "markdown"

@dataclass
class DanteConfig:
    llm: LLMConfig = field(default_factory=LLMConfig)
    scan: ScanConfig = field(default_factory=ScanConfig)
    report: ReportConfig = field(default_factory=ReportConfig)


def get_exclude_folders() -> list[str]:
    """Load user-defined exclude folders from data/dante_exclude_folders.json."""
    excl_file = DATA_DIR / "dante_exclude_folders.json"
    if excl_file.exists():
        try:
            data = json.loads(excl_file.read_text(encoding="utf-8"))
            return data.get("exclude_folders", [])
        except Exception:
            pass
    return []


config = DanteConfig()
