"""EA strategy context generator - describes how the EA actually trades.

This module generates a structured text description of the EA's strategy,
including entry conditions, risk management, and how MacroRegimeEngine
is currently used. This context is injected into the LLM prompt so it
can make informed calibration suggestions.
"""

from __future__ import annotations
from typing import Dict, List, Optional


# ── Complete EA strategy description ──────────────────────────────────────────
# This is the authoritative description of how EA QUantFX v10.0.0 operates.

EA_STRATEGY = """
EA: EA QUantFX v10.0.0 — Mean-Reversion por Distancia de Preco
Tipo: Mean-Reversion (PipsStep 28.0 pips, jitter ±50%)
SINAL: Compra se preco caiu >= PipsStep abaixo; Venda se subiu >= PipsStep acima
Modo: 1 trade aberto por vez

GATES (todos obrigatorios): Sem posicao aberta | Nao esta em caos | Horario permitido | Sem bloqueio noticia | Execution ocioso

RISCO: TP= lots*$25 | SL= -0.8% balance | Trailing: breakeven+8pts, trail+25pts | ALXQuant: daily_loss=3%, max_dd=0.9%, profit_target=2.2%

HORARIO: 02:00-19:00 (local), Sem sexta, bloqueio 15min antes do fim

MACROREGIME: Gate atual: !IsChaosRegime(). Nao usa: RegimeScore, RegimeName, TrendFollowing, etc.
"""


def get_strategy_context(
    parameter_table: str = "",
    asset_dna_summary: str = "",
    dataminer_summary: str = "",
) -> str:
    """Build the full strategy context for the LLM prompt."""
    parts = [EA_STRATEGY]

    if parameter_table:
        parts.append(parameter_table)

    if asset_dna_summary:
        parts.append(asset_dna_summary)

    if dataminer_summary:
        parts.append(dataminer_summary)

    return "\n".join(parts)


def format_parameter_table(params: list) -> str:
    """Format ParameterEntry list as a readable table for the prompt."""
    lines = []
    lines.append(f"{'Parametro':<45} {'Valor':<12} {'Tipo':<10} {'Localizacao'}")
    lines.append("-" * 100)

    for p in params:
        if not p.calibratable:
            continue
        val_str = str(p.current_value) if p.current_value is not None else "N/A"
        lines.append(
            f"{p.param:<45} {val_str:<12} {p.value_type:<10} {p.location}"
        )

    return "\n".join(lines)


def format_asset_dna_summary(ctx) -> str:
    """Format AssetDNAContext as a condensed summary for the prompt."""
    if ctx is None:
        return "ASSET DNA: N/A"

    lines = []

    if ctx.regime_profile:
        rp = ctx.regime_profile
        dom = rp.get('dominant', 'N/A')
        h = f"{rp.get('hurst_mean', 0):.4f}" if rp.get('hurst_mean') else "N/A"
        a = f"{rp.get('adx_mean', 0):.1f}" if rp.get('adx_mean') else "N/A"
        dist = rp.get("regime_distribution", {})
        dist_str = ", ".join(f"{r}={p:.0%}" for r, p in sorted(dist.items(), key=lambda x: -x[1]))
        lines.append(f"ASSET DNA: dominante={dom} hurst={h} adx={a} dist=[{dist_str}]")

    if ctx.regime_thresholds:
        th = ", ".join(f"{k}={v:.4f}" if isinstance(v, float) else f"{k}={v}" for k, v in ctx.regime_thresholds.items())
        lines.append(f"Thresholds: {th}")

    if ctx.strategy_fit:
        sf = ", ".join(f"{k}={v:.2f}" for k, v in sorted(ctx.strategy_fit.items(), key=lambda x: -x[1]))
        lines.append(f"Strategy Fit: {sf}")

    if ctx.hmm_model:
        h = ctx.hmm_model
        agr = f" agr={h.get('agreement_adx_hurst', 0):.1f}%" if h.get('agreement_adx_hurst') else ""
        lines.append(f"HMM: {h.get('states', 'N/A')} estados{agr}")

    if ctx.transition_matrix:
        top5 = sorted(ctx.transition_matrix.items(), key=lambda x: -x[1])[:5]
        trans = ", ".join(f"{k}={v:.3f}" for k, v in top5)
        lines.append(f"Transicao top5: {trans}")

    if ctx.pbo:
        lines.append(f"PBO: mr={ctx.pbo.get('mean_reversion', 'N/A')} bk={ctx.pbo.get('breakout', 'N/A')}")

    return "\n".join(lines)


def format_dataminer_summary(summary) -> str:
    """Format DataminerSummary as a readable string for the prompt (condensed)."""
    lines = []
    lines.append(f"DATAMINER: {summary.total_trades} trades, schema={summary.schema_detected}")
    if summary.date_range and summary.date_range[0]:
        lines.append(f"Periodo: {summary.date_range[0]} a {summary.date_range[1]}")

    if summary.warnings:
        for w in summary.warnings:
            lines.append(f"  AVISO: {w}")

    if summary.by_regime:
        lines.append("Por Regime:")
        for regime, stats in sorted(summary.by_regime.items()):
            if stats.insufficient_sample:
                lines.append(f"  {regime}: n={stats.n} (insuficiente)")
            else:
                sig = "*" if stats.significant_5pct else ""
                exp = f"{stats.expectancy_r:.3f}R" if stats.expectancy_r is not None else "N/A"
                wr = f"{stats.win_rate:.0%}" if stats.win_rate is not None else "N/A"
                lines.append(f"  {regime}: n={stats.n} exp={exp} wr={wr} sig={sig}")

    if summary.by_hurst_bucket:
        lines.append("Por Hurst:")
        for bucket, stats in sorted(summary.by_hurst_bucket.items()):
            if stats.insufficient_sample:
                lines.append(f"  {bucket}: n={stats.n} (insuficiente)")
            else:
                sig = "*" if stats.significant_5pct else ""
                exp = f"{stats.expectancy_r:.3f}R" if stats.expectancy_r is not None else "N/A"
                lines.append(f"  {bucket}: n={stats.n} exp={exp} sig={sig}")

    if summary.by_semantic_flag:
        lines.append("Por Flag:")
        for flag, stats in sorted(summary.by_semantic_flag.items()):
            exp = f"{stats.expectancy_r:.3f}R" if stats.expectancy_r is not None else "N/A"
            sig = "*" if stats.significant_5pct else ""
            lines.append(f"  {flag}: n={stats.n} exp={exp} sig={sig}")

    return "\n".join(lines)
