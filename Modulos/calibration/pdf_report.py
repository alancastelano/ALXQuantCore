"""PDF report generator for calibration results.

Generates a professional PDF report with calibration suggestions,
performance tables, and methodology notes using reportlab.
"""

from __future__ import annotations
import os
from datetime import datetime
from pathlib import Path
from typing import Optional

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak,
)

from .schemas import CalibrationOutput


# ── Colors ─────────────────────────────────────────────────────────────────────
ORANGE = colors.HexColor("#ff9800")
DARK_BG = colors.HexColor("#1a1a1a")
LIGHT_GRAY = colors.HexColor("#cccccc")
GREEN = colors.HexColor("#4caf50")
RED = colors.HexColor("#f44336")
YELLOW = colors.HexColor("#ffeb3b")


def _get_styles():
    """Create custom paragraph styles."""
    styles = getSampleStyleSheet()

    styles.add(ParagraphStyle(
        name="TitleOrange",
        parent=styles["Title"],
        textColor=ORANGE,
        fontSize=18,
        spaceAfter=12,
    ))
    styles.add(ParagraphStyle(
        name="SectionHeader",
        parent=styles["Heading2"],
        textColor=ORANGE,
        fontSize=13,
        spaceBefore=16,
        spaceAfter=8,
    ))
    styles.add(ParagraphStyle(
        name="BodySmall",
        parent=styles["BodyText"],
        fontSize=9,
        leading=12,
    ))
    styles.add(ParagraphStyle(
        name="Warning",
        parent=styles["BodyText"],
        textColor=RED,
        fontSize=10,
        leading=13,
    ))
    return styles


def _confidence_color(conf: str) -> colors.Color:
    """Map confidence to color."""
    return {"high": GREEN, "medium": YELLOW, "low": RED}.get(conf, LIGHT_GRAY)


def generate_pdf(
    output: CalibrationOutput,
    pdf_path: str | Path,
    symbol: str = "",
    timeframe: str = "M5",
) -> Path:
    """Generate a PDF report from calibration output.

    Args:
        output: CalibrationOutput from the agent.
        pdf_path: Where to save the PDF.
        symbol: Asset symbol.
        timeframe: Timeframe.

    Returns:
        Path to the generated PDF.
    """
    pdf_path = Path(pdf_path)
    pdf_path.parent.mkdir(parents=True, exist_ok=True)

    doc = SimpleDocTemplate(
        str(pdf_path),
        pagesize=A4,
        leftMargin=15 * mm,
        rightMargin=15 * mm,
        topMargin=20 * mm,
        bottomMargin=20 * mm,
    )

    styles = _get_styles()
    story = []

    # ── Cover ──────────────────────────────────────────────────────────────────
    story.append(Spacer(1, 40 * mm))
    story.append(Paragraph("EA Calibration Report", styles["TitleOrange"]))
    story.append(Spacer(1, 8 * mm))
    story.append(Paragraph(f"Asset: {symbol} | TF: {timeframe}", styles["Heading3"]))
    story.append(Spacer(1, 4 * mm))

    meta = output.meta
    story.append(Paragraph(
        f"Generated: {meta.get('generated_at', 'N/A')}<br/>"
        f"Trades analyzed: {meta.get('dataminer_trades_analyzed', 'N/A')}<br/>"
        f"LLM Provider: {meta.get('llm_provider', 'N/A')}",
        styles["BodySmall"],
    ))

    if meta.get("warning"):
        story.append(Spacer(1, 4 * mm))
        story.append(Paragraph(f"⚠ {meta['warning']}", styles["Warning"]))

    story.append(PageBreak())

    # ── Executive Summary ──────────────────────────────────────────────────────
    story.append(Paragraph("Resumo Executivo", styles["SectionHeader"]))

    n_sug = len(output.suggestions)
    n_div = len(output.divergences)
    n_insuf = len(output.insufficient_evidence)

    high_conf = sum(1 for s in output.suggestions if s.confidence == "high")
    med_conf = sum(1 for s in output.suggestions if s.confidence == "medium")
    low_conf = sum(1 for s in output.suggestions if s.confidence == "low")

    story.append(Paragraph(
        f"Sugestoes: {n_sug} (high={high_conf}, medium={med_conf}, low={low_conf})<br/>"
        f"Divergencias: {n_div}<br/>"
        f"Evidencia insuficiente: {n_insuf}",
        styles["BodyText"],
    ))
    story.append(Spacer(1, 6 * mm))

    # ── Suggestions Table ──────────────────────────────────────────────────────
    if output.suggestions:
        story.append(Paragraph("Sugestoes de Calibracao", styles["SectionHeader"]))

        header = ["Parametro", "Atual", "Sugerido", "Tipo", "Conf", "Motivo"]
        data = [header]

        for s in output.suggestions:
            tipo_short = "DENTRO" if s.tipo == "ajuste_dentro_da_amostra" else "EXTRAPOL"
            reason_short = s.reasoning[:60] + "..." if len(s.reasoning) > 60 else s.reasoning
            data.append([
                s.param,
                s.current_value,
                s.suggested_value,
                tipo_short,
                s.confidence.upper(),
                reason_short,
            ])

        col_widths = [90, 45, 45, 55, 35, 200]
        table = Table(data, colWidths=col_widths, repeatRows=1)
        table.setStyle(TableStyle([
            ("BACKGROUND", (0, 0), (-1, 0), DARK_BG),
            ("TEXTCOLOR", (0, 0), (-1, 0), ORANGE),
            ("FONTSIZE", (0, 0), (-1, -1), 7),
            ("FONTSIZE", (0, 0), (-1, 0), 8),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("ALIGN", (0, 0), (-1, -1), "LEFT"),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#333")),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.HexColor("#0a0a0a"), colors.HexColor("#111")]),
            ("TOPPADDING", (0, 0), (-1, -1), 3),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ]))

        # Color confidence column
        for i, s in enumerate(output.suggestions, start=1):
            conf_color = _confidence_color(s.confidence)
            table.setStyle(TableStyle([
                ("TEXTCOLOR", (4, i), (4, i), conf_color),
            ]))

        story.append(table)
        story.append(Spacer(1, 8 * mm))

    # ── Divergences ────────────────────────────────────────────────────────────
    if output.divergences:
        story.append(Paragraph("Divergencias (Asset DNA vs DataMiner)", styles["SectionHeader"]))

        for d in output.divergences:
            story.append(Paragraph(
                f"<b>{d.topic}</b><br/>"
                f"Asset DNA: {d.asset_dna_says}<br/>"
                f"DataMiner: {d.dataminer_says}<br/>"
                f"<i>Recomendacao: {d.recommendation}</i>",
                styles["BodySmall"],
            ))
            story.append(Spacer(1, 3 * mm))

    # ── Insufficient Evidence ──────────────────────────────────────────────────
    if output.insufficient_evidence:
        story.append(Paragraph("Evidencia Insuficiente", styles["SectionHeader"]))

        for e in output.insufficient_evidence:
            story.append(Paragraph(
                f"<b>{e.param}</b>: {e.reason}",
                styles["BodySmall"],
            ))
            story.append(Spacer(1, 2 * mm))

    # ── Methodology ────────────────────────────────────────────────────────────
    story.append(PageBreak())
    story.append(Paragraph("Metodologia", styles["SectionHeader"]))
    story.append(Paragraph(
        "Este relatorio foi gerado por um agente de calibracao que cruza tres fontes:<br/><br/>"
        "1. <b>DataMiner CSV</b>: resultados reais de trades (backtest e/ou conta real). "
        "Evidencia ex-post de como o EA realmente se comportou.<br/>"
        "2. <b>Asset DNA JSON</b>: perfil estatistico de 10 anos do ativo. "
        "Evidencia ex-ante do comportamento historico.<br/>"
        "3. <b>MacroRegimeEngine.mqh</b>: codigo MQL5 do classificador de regimes. "
        "Parametros atuais e logica de classificacao.<br/><br/>"
        "<b>Vies de selecao</b>: O CSV do DataMiner so contem trades que JA PASSARAM "
        "pelos filtros atuais. Nao e possivel provar que afrouxar um filtro traria "
        "resultados melhores — isso seria extrapolação teórica. Sugestoes de "
        "afrouxamento sao marcadas como 'extrapolacao_teorica' com confianca reduzida.",
        styles["BodySmall"],
    ))

    # Build PDF
    doc.build(story)
    return pdf_path
