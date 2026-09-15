"""OpenAI/litellm provider for DANTE LLM analysis."""

import os
from typing import Optional

from .base import LLMClient, LLMResponse


class OpenAIProvider(LLMClient):
    """LLM client using litellm for OpenAI-compatible providers."""

    def __init__(self, model: str = "gpt-4o-mini", api_key: str = "",
                 base_url: str = "", temperature: float = 0.1,
                 max_tokens: int = 4096):
        self.model = model
        self.api_key = api_key or os.getenv("OPENAI_API_KEY", "")
        self.base_url = base_url
        self.temperature = temperature
        self.max_tokens = max_tokens
        self._client = None

    def _get_client(self):
        if self._client is None:
            try:
                import litellm
                self._client = litellm
            except ImportError:
                raise ImportError("litellm is required: pip install litellm")
        return self._client

    def _call(self, system_prompt: str, user_prompt: str) -> LLMResponse:
        client = self._get_client()
        response = client.completion(
            model=self.model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            temperature=self.temperature,
            max_tokens=self.max_tokens,
            api_key=self.api_key or None,
            api_base=self.base_url or None,
            timeout=60,
        )
        return LLMResponse(
            content=response.choices[0].message.content,
            model=self.model,
            tokens_used=response.usage.total_tokens if response.usage else 0,
            finish_reason=response.choices[0].finish_reason or "",
        )

    def analyze_code(self, code: str, language: str, context: str = "") -> LLMResponse:
        system = (
            f"You are DANTE, an expert {language} code auditor. "
            "Analyze the code for bugs, security issues, performance problems, "
            "and code quality issues. Return findings as a JSON array with fields: "
            "line (int), rule_id (str), severity (critical|high|medium|low|info), "
            "message (str), category (str). Only return the JSON array, no explanation."
        )
        user = f"```{language}\n{code}\n```"
        if context:
            user = f"Context: {context}\n\n{user}"
        return self._call(system, user)

    def summarize(self, code: str, language: str) -> str:
        system = (
            f"You are DANTE, an expert {language} code analyst. "
            "Write a brief 2-3 sentence summary of what this code does, "
            "its main purpose, and key architectural decisions."
        )
        user = f"```{language}\n{code}\n```"
        resp = self._call(system, user)
        return resp.content

    def suggest_fix(self, code: str, finding: str, language: str) -> str:
        system = (
            f"You are DANTE, an expert {language} developer. "
            "Given a code snippet and a finding, provide a concrete fix "
            "as a code diff or replacement code. Be specific and actionable."
        )
        user = f"Code:\n```{language}\n{code}\n```\n\nFinding: {finding}"
        resp = self._call(system, user)
        return resp.content

    def health_check(self) -> bool:
        try:
            resp = self._call("Reply with 'ok' only.", "test")
            return "ok" in resp.content.lower()
        except Exception:
            return False
