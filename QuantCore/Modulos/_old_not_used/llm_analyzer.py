"""
LLM Analyzer for ALXQuant Alpha Research Reports
Uses litellm to send structured data to any OpenAI-compatible API.
"""

import os
import json
import logging
from dotenv import load_dotenv

load_dotenv(r'C:\ALXQuant\.env', override=True)
logger = logging.getLogger(__name__)

# Optional dependency
try:
    import litellm
    LITELLM_AVAILABLE = True
except ImportError:
    LITELLM_AVAILABLE = False


PROVIDER_API_KEYS = {
    'groq': 'GROQ_API_KEY',
    'openrouter': 'OPENROUTER_API_KEY',
    'gemini': 'GEMINI_API_KEY',
    'openai': 'OPENAI_API_KEY',
    'anthropic': 'ANTHROPIC_API_KEY',
    'dashscope': 'DASHSCOPE_API_KEY',
}

PROVIDER_DEFAULT_URLS = {
    'groq': 'https://api.groq.com/openai/v1',
    'openrouter': 'https://openrouter.ai/api/v1',
    'dashscope': 'https://dashscope.aliyuncs.com/compatible-mode/v1',
}


class LLMAnalyzer:
    """Sends structured trade data to an LLM for deeper analysis."""

    def __init__(self, model=None, api_key=None, base_url=None):
        self.model = model or os.getenv('LLM_MODEL', 'gpt-4o-mini')
        self.api_key = api_key or os.getenv('LLM_API_KEY', '')
        self.base_url = base_url or os.getenv('LLM_BASE_URL', '')
        self.enabled = LITELLM_AVAILABLE and bool(self.api_key)
        if not self.enabled:
            reason = 'litellm not installed' if not LITELLM_AVAILABLE else 'no API key'
            logger.info(f"LLM desabilitado: {reason}")

    def _set_provider_env(self):
        """Seta a env var padronizada do provedor no os.environ."""
        model_lower = self.model.lower()
        for prefix, env_var in PROVIDER_API_KEYS.items():
            if prefix in model_lower:
                if self.api_key:
                    os.environ[env_var] = self.api_key
                if not self.base_url and prefix in PROVIDER_DEFAULT_URLS:
                    self.base_url = PROVIDER_DEFAULT_URLS[prefix]
                logger.info(f"Provider detectado: {prefix} → {env_var}={self.api_key[:8]}...")
                break

    def _call_llm(self, system_prompt, user_prompt, max_tokens=2000):
        """Generic LLM call via litellm."""
        if not self.enabled:
            return None

        self._set_provider_env()

        kwargs = {
            'model': self.model,
            'messages': [
                {'role': 'system', 'content': system_prompt},
                {'role': 'user', 'content': user_prompt}
            ],
            'max_tokens': max_tokens,
            'temperature': 0.3,
        }
        if self.api_key:
            kwargs['api_key'] = self.api_key
        if self.base_url:
            kwargs['api_base'] = self.base_url

        try:
            response = litellm.completion(**kwargs)
            return response.choices[0].message.content
        except Exception as e:
            logger.warning(f"LLM call failed: {e}")
            return None

    def analyze_catastrophe(self, analyzer):
        """Generate catastrophe analysis from structured QuantAnalyzer data."""
        if not self.enabled:
            return None

        r = analyzer.results
        cat = r.get('catastrophe', {})
        basic = r.get('basic', {})
        tail = r.get('tail_risk', {})

        # Build structured data for the prompt
        numeric = cat.get('numeric', {})
        top_feats = sorted(numeric.items(), key=lambda x: abs(x[1].get('cohens_d', 0)),
                           reverse=True)[:10]

        feat_lines = []
        for feat, vals in top_feats:
            feat_lines.append(
                f"- {feat}: media_piores={vals.get('media_bad', 0):.3f}, "
                f"media_resto={vals.get('media_rest', 0):.3f}, "
                f"cohens_d={vals.get('cohens_d', 0):.3f}, "
                f"p_value={vals.get('p_value', 1):.4f}"
            )

        bvw = cat.get('best_vs_worst', {})
        filter_lines = []
        for feat, vals in bvw.items():
            if vals.get('significant') and abs(vals.get('cohens_d', 0)) > 0.5:
                filter_lines.append(
                    f"- {feat}: threshold={vals.get('valor_filtro', 'N/A')}, "
                    f"perdas_evitadas={vals.get('losses_evitados', 0)}, "
                    f"cohens_d={vals.get('cohens_d', 0):.2f}"
                )

        system_prompt = """You are a senior quantitative analyst specializing in systematic trading.
Analyze the catastrophic trade data provided and produce a professional diagnosis in Brazilian Portuguese.
Be direct, technical, and actionable. Avoid generic advice. Focus on what the data actually shows."""

        user_prompt = f"""ANALISE DE TRADES CATASTROFICOS (piores 10% vs restante)

Ativo: {analyzer.symbol}
Total de trades: {analyzer.n}
Win Rate: {basic.get('win_rate', 0):.1f}%
Avg R: {basic.get('avg_r', 0):.3f}R
Max Drawdown: {tail.get('max_dd_pct', 0):.1f}%

TOP FATORES DIFERENCIADORES (Cohen's d | p-value):
{chr(10).join(feat_lines) if feat_lines else 'Nenhum fator significativo encontrado.'}

FILTROS SUGERIDOS:
{chr(10).join(filter_lines) if filter_lines else 'Nenhum filtro sugerido.'}

INSTRUCOES:
Produza uma analise EM PORTUGUES com:
1. Diagnostico das causas raiz das perdas severas (seja especifico sobre quais features importam)
2. Confiabilidade dos filtros baseada em Cohen's d e p-value
3. Recomendacoes especificas de filtros a implementar no código MQL5
4. Riscos de overfitting (especialmente com apenas {analyzer.n} trades)
5. Proximos passos sugeridos (backtest, validacao out-of-sample)

Seja conciso: maximo 4 paragrafos.
"""

        return self._call_llm(system_prompt, user_prompt, max_tokens=2000)

    def analyze_general(self, section_name, data_summary):
        """Generic section analysis. Placeholder for future use."""
        if not self.enabled:
            return None
        system_prompt = "You are a senior quant analyst. Provide concise analysis in Brazilian Portuguese."
        user_prompt = f"Section: {section_name}\nData: {json.dumps(data_summary, default=str, indent=2)}\n\nProvide a brief professional analysis (2-3 paragraphs in Portuguese):"
        return self._call_llm(system_prompt, user_prompt, max_tokens=1500)
