"""LLM base client — abstract interface for code analysis."""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Optional


@dataclass
class LLMResponse:
    content: str
    model: str
    tokens_used: int = 0
    finish_reason: str = ""


class LLMClient(ABC):
    """Abstract LLM client for DANTE code analysis."""

    @abstractmethod
    def analyze_code(self, code: str, language: str, context: str = "") -> LLMResponse:
        """Analyze code and return findings as structured text."""
        ...

    @abstractmethod
    def summarize(self, code: str, language: str) -> str:
        """Generate a brief code summary."""
        ...

    @abstractmethod
    def suggest_fix(self, code: str, finding: str, language: str) -> str:
        """Suggest a fix for a specific finding."""
        ...

    @abstractmethod
    def health_check(self) -> bool:
        """Check if LLM provider is available."""
        ...
