"""Calibration agent - LLM-powered analysis with multi-provider fallback.

Assembles the prompt from dataminer summary, Asset DNA context,
and MQH parameter table, then calls an LLM via litellm with
automatic provider fallback.
"""

from __future__ import annotations
import json
import logging
import os
import re
from datetime import datetime, timezone
from typing import Optional

from .schemas import (
    CalibrationOutput,
    Suggestion,
    Divergence,
    InsufficientEvidence,
)

logger = logging.getLogger(__name__)

# ── LLM Provider Fallback Chain ───────────────────────────────────────────────
# Each provider is tried in order; first success wins.
PROVIDER_CHAIN = [
    {"env": "LLM_API_KEY", "model_env": "LLM_MODEL", "name": "LLM_MODEL env"},
    {"env": "GROQ_API_KEY", "model": "groq/openai/gpt-oss-120b", "name": "Groq"},
    {"env": "GEMINI_API_KEY", "model": "gemini/gemini-2.5-flash-lite", "name": "Gemini"},
    {"env": "NVIDIA_API_KEY", "model": "nvidia_nim/meta/llama-3.1-8b-instruct", "name": "NVIDIA NIM"},
    {"env": "OPENAI_API_KEY", "model": "openai/gpt-4o-mini", "name": "OpenAI"},
    {"env": "OPENROUTER_API_KEY", "model": "openrouter/anthropic/claude-3-haiku", "name": "OpenRouter"},
]


def _call_llm(
    system_prompt: str,
    user_prompt: str,
    max_tokens: int = 4096,
    temperature: float = 0.2,
) -> tuple[str, str]:
    """Call LLM via litellm with automatic provider fallback.

    Returns:
        (response_text, provider_name)

    Raises:
        RuntimeError if all providers fail.
    """
    try:
        import litellm
    except ImportError:
        raise RuntimeError("litellm not installed. Run: pip install litellm")

    errors = []

    for provider in PROVIDER_CHAIN:
        api_key = os.getenv(provider.get("env", ""), "")
        if not api_key:
            continue

        model = provider.get("model", "")
        if not model and "model_env" in provider:
            model = os.getenv(provider["model_env"], "")
        if not model:
            continue

        try:
            logger.info(f"Trying LLM provider: {provider['name']} ({model})")
            response = litellm.completion(
                model=model,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
                api_key=api_key,
                max_tokens=max_tokens,
                temperature=temperature,
                stop=["```", "\n\n\n"],
            )
            result = response.choices[0].message.content
            logger.info(f"LLM success with {provider['name']}")
            return result, provider["name"]
        except Exception as e:
            error_msg = f"{provider['name']}: {type(e).__name__}: {e}"
            logger.warning(f"LLM failed: {error_msg}")
            errors.append(error_msg)
            continue

    raise RuntimeError(f"All LLM providers failed:\n" + "\n".join(errors))


def _try_repair_truncated_json(text: str) -> dict | None:
    """Attempt to repair truncated JSON by closing unclosed structures.

    Handles: truncated strings, unclosed arrays, unclosed objects.
    Tries multiple closing orders since nesting can vary.
    """
    text = text.rstrip().rstrip(",")
    # Ensure we start from a valid JSON root
    first_brace = text.find("{")
    if first_brace == -1:
        return None
    text = text[first_brace:]

    # Pass 1: If string is open (odd number of unescaped quotes), close it
    in_string = False
    escape = False
    for ch in text:
        if escape:
            escape = False
            continue
        if ch == "\\":
            escape = True
            continue
        if ch == '"':
            in_string = not in_string
    if in_string:
        text += '"'

    # Remove trailing comma if any
    text = text.rstrip().rstrip(",")

    # Pass 2: Count brackets and braces (outside strings)
    brace_depth = 0
    bracket_depth = 0
    in_string = False
    escape = False
    for ch in text:
        if escape:
            escape = False
            continue
        if ch == "\\":
            escape = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if ch == "[":
            bracket_depth += 1
        elif ch == "]":
            bracket_depth = max(0, bracket_depth - 1)
        elif ch == "{":
            brace_depth += 1
        elif ch == "}":
            brace_depth = max(0, brace_depth - 1)

    if brace_depth == 0 and bracket_depth == 0:
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return None

    # Pass 3: Try multiple closing orders
    # The nesting is typically: { ... [ { ... } ] ... }
    # So we may need: } ] } or ] } } or } } ] etc.
    candidates = []
    # Order A: brackets first, then braces
    candidates.append(text + "]" * bracket_depth + "}" * brace_depth)
    # Order B: braces first, then brackets, then remaining braces
    if bracket_depth > 0 and brace_depth > 1:
        candidates.append(text + "}" + "]" * bracket_depth + "}" * (brace_depth - 1))
    # Order C: one brace, bracket, remaining braces
    if bracket_depth > 0 and brace_depth > 0:
        candidates.append(text + "}" * brace_depth + "]" * bracket_depth)
    # Order D: interleaved (close innermost first)
    if bracket_depth > 0 and brace_depth > 0:
        # Try: brace, bracket, brace(s)
        candidates.append(text + "}" + "]" * bracket_depth + "}" * brace_depth)

    for candidate in candidates:
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            continue

    return None


def _extract_json_from_response(text: str) -> dict:
    """Extract JSON from LLM response, handling markdown code blocks and truncation."""
    text = text.strip()

    # Strategy 1: Direct parse — entire text is valid JSON
    if text.startswith("{"):
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            pass

    # Strategy 2: Markdown code block — ```json ... ``` or ``` ... ```
    # Flexible regex: handles optional language tag, optional newlines, trailing text
    for pattern in [
        r"```json\s*\n(.*?)\n\s*```",           # standard: ```json\n...\n```
        r"```json\s*\n(.*?)```",                  # no trailing newline
        r"```json\s*(.*?)```",                    # no newlines at all
        r"```\s*\n(.*?)\n\s*```",                # no language tag
        r"```(.*?)```",                           # bare fences
    ]:
        match = re.search(pattern, text, re.DOTALL)
        if match:
            inner = match.group(1).strip()
            try:
                return json.loads(inner)
            except json.JSONDecodeError:
                pass

    # Strategy 3: First '{' to last '}' — strip surrounding prose
    first_brace = text.find("{")
    last_brace = text.rfind("}")
    if first_brace != -1 and last_brace > first_brace:
        candidate = text[first_brace:last_brace + 1]
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            pass

    # Strategy 4: Partial JSON repair — close unclosed braces/brackets
    repaired = _try_repair_truncated_json(text)
    if repaired is not None:
        logger.warning("JSON was truncated — repaired by closing unclosed structures")
        return repaired

    logger.error(f"All JSON extraction strategies failed. Response preview:\n{text[:800]}")
    raise ValueError(f"Could not extract JSON from LLM response:\n{text[:500]}")


def _validate_and_fix_output(raw: dict, min_sample: int) -> CalibrationOutput:
    """Validate LLM output against schema and apply guardrails."""
    suggestions = []
    for s in raw.get("suggestions", []):
        # Guardrail 1: Must have at least one evidence source
        has_dm = bool(s.get("based_on_dataminer_bucket"))
        has_dna = bool(s.get("based_on_asset_dna_field"))
        if not has_dm and not has_dna:
            logger.warning(
                f"Rejecting suggestion for '{s.get('param')}': no evidence source"
            )
            continue

        # Guardrail 2: Force confidence downgrade if insufficient sample
        confidence = s.get("confidence", "low")
        dm_stats = s.get("based_on_dataminer_stats", {})
        if dm_stats:
            n = int(dm_stats.get("n") or 0)
            sig = bool(dm_stats.get("significant_5pct", False))
            if n < min_sample or not sig:
                if confidence == "high":
                    logger.info(
                        f"Downgrading confidence for '{s.get('param')}': "
                        f"n={n}, significant={sig}"
                    )
                    confidence = "low"

        # Guardrail 3: Validate tipo
        tipo = s.get("tipo", "extrapolacao_teorica")
        if tipo not in ("ajuste_dentro_da_amostra", "extrapolacao_teorica"):
            tipo = "extrapolacao_teorica"

        suggestions.append(Suggestion(
            param=s.get("param", ""),
            location=s.get("location", ""),
            current_value=str(s.get("current_value", "")),
            suggested_value=str(s.get("suggested_value", "")),
            tipo=tipo,
            confidence=confidence,
            based_on_dataminer_bucket=s.get("based_on_dataminer_bucket"),
            based_on_dataminer_stats=s.get("based_on_dataminer_stats"),
            based_on_asset_dna_field=s.get("based_on_asset_dna_field"),
            reasoning=s.get("reasoning", ""),
        ))

    divergences = [
        Divergence(**d) for d in raw.get("divergences", [])
    ]

    insufficient = [
        InsufficientEvidence(**e) for e in raw.get("insufficient_evidence", [])
    ]

    meta = raw.get("meta", {})

    # Guardrail 4: Warn if total trades < 100
    total_trades = int(meta.get("dataminer_trades_analyzed") or 0)
    if total_trades < 100:
        meta["warning"] = (
            f"Amostra pequena ({total_trades} trades). "
            "Todas as sugestoes devem ser tratadas como preliminares."
        )

    return CalibrationOutput(
        meta=meta,
        suggestions=suggestions,
        divergences=divergences,
        insufficient_evidence=insufficient,
    )


# ── System Prompt ──────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """Voce e um engenheiro quant senior especializado em trading algoritmico.
Seu trabalho e cruze tres fontes de dados para calibrar os thresholds do MacroRegimeEngine,
um modulo MQL5 que classifica regimes de mercado (TREND, MEAN_REVERSION, BREAKOUT, CHAOS, NEUTRAL).

HIERARQUIA DE EVIDENCIA (sempre seguir esta ordem):
1. DATAMINER (resultados reais de trades) > 2. ASSET DNA (perfil estatistico) > 3. TEORIA

REGRAS OBRIGATORIAS:
- Toda sugestao DEVE citar um bucket exato do dataminer (nome, n, expectancy, p_value)
  OU um campo do asset_dna (nome do campo, valor).
- "Regra de ouro": SUGERIR MUDANCAS E MAIS RESTRITIVO (apertar filtro) ou
  REDISTRIBUIR dentro da faixa ja observada nos dados reais.
- AFROUXAR um filtro so e permitido se o ASSET DNA sustentar explicitamente.
  Nesse caso, marcar como "tipo": "extrapolacao_teorica".
- confidence="low" SEMPRE quando n < 30 ou significant_5pct=false no dataminer.
- Reportar DIVERGENCIAS quando asset_dna e dataminer discordam.
- Responder em JSON ESTRICTO conforme o schema fornecido. NENHUMA prosa fora do JSON.

FORMATO DE RESPOSTA (JSON estrito):
{
  "meta": {
    "symbol": "...",
    "timeframe": "...",
    "generated_at": "ISO8601",
    "dataminer_trades_analyzed": N,
    "dataminer_date_range": ["start", "end"]
  },
  "suggestions": [
    {
      "param": "nome_do_parametro",
      "location": "BuildDefaultProfile()",
      "current_value": "0.53",
      "suggested_value": "0.58",
      "tipo": "ajuste_dentro_da_amostra",
      "confidence": "medium",
      "based_on_dataminer_bucket": "hurst_bucket 0.57-0.60",
      "based_on_dataminer_stats": {"n": 30, "expectancy_R": 0.41, "p_value": 0.03},
      "based_on_asset_dna_field": "mql5_directives.regime_thresholds.hurst_p60",
      "reasoning": "texto curto citando os numeros acima"
    }
  ],
  "divergences": [
    {
      "topic": "threshold de Hurst para trend",
      "asset_dna_says": "...",
      "dataminer_says": "...",
      "recommendation": "qual evidencia priorizar e por que"
    }
  ],
  "insufficient_evidence": [
    {
      "param": "chaos_r2_threshold",
      "reason": "motivo da falta de evidencia"
    }
  ]
}"""


def run_calibration(
    strategy_context: str,
    symbol: str = "",
    timeframe: str = "M5",
    min_sample: int = 30,
    max_tokens: int = 8192,
) -> CalibrationOutput:
    """Run the calibration agent.

    Args:
        strategy_context: Full strategy context (EA + parameters + data).
        symbol: Asset symbol being calibrated (e.g. US30, XAUUSD).
        timeframe: Timeframe being calibrated (e.g. M5).
        min_sample: Minimum trades per bucket for statistics.
        max_tokens: Max tokens for LLM response.

    Returns:
        CalibrationOutput with suggestions, divergences, and insufficient evidence.
    """
    user_prompt = f"""Analise os dados abaixo e proponha ajustes nos parametros do MacroRegimeEngine.

IMPORTANTE: O ativo analisado e {symbol} no timeframe {timeframe}.
Use ESTE SIMBOLO no campo "meta.symbol" e ESTE TIMEFRAME no campo "meta.timeframe".
NAO copie o exemplo do system prompt — use o simbolo e timeframe reais fornecidos acima.

{strategy_context}

Responda em JSON estricto conforme o schema do system prompt."""

    logger.info(f"Calling LLM for calibration analysis ({symbol} {timeframe})...")
    raw_response, provider_name = _call_llm(
        SYSTEM_PROMPT, user_prompt, max_tokens=max_tokens,
    )
    logger.info(f"LLM response received from {provider_name} ({len(raw_response or '')} chars)")

    if not raw_response:
        raise RuntimeError(f"LLM returned empty response from {provider_name}")

    # Extract JSON
    raw_dict = _extract_json_from_response(raw_response)

    # Add provider info to meta
    raw_dict.setdefault("meta", {})["llm_provider"] = provider_name
    raw_dict["meta"]["generated_at"] = datetime.now(timezone.utc).isoformat()

    # Validate and apply guardrails
    output = _validate_and_fix_output(raw_dict, min_sample)

    logger.info(
        f"Calibration complete: {len(output.suggestions)} suggestions, "
        f"{len(output.divergences)} divergences, "
        f"{len(output.insufficient_evidence)} insufficient evidence"
    )
    return output
