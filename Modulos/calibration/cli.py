"""CLI entry point for the calibration agent.

Usage:
    python -m Modulos.calibration.cli \\
        --symbol XAUUSD \\
        --tf M5 \\
        --asset-dna data/mql5/asset_profile_XAUUSD_M5.json \\
        --dataminer data/mql5/data_miner_xauusd.csv \\
        --mqh MQL5/MQL5/Include/ALXQuantCore/Modules/MacroRegimeEngine.mqh \\
        --out data/mql5/calibration_XAUUSD_M5.json \\
        --pdf data/mql5/calibration_XAUUSD_M5.pdf \\
        --min-sample 30
"""

from __future__ import annotations
import argparse
import json
import logging
import sys
from pathlib import Path

from .dataminer_aggregator import aggregate
from .asset_dna_loader import load_asset_dna
from .mqh_parser import parse_mqh, get_classification_logic
from .strategy_context import (
    get_strategy_context,
    format_parameter_table,
    format_asset_dna_summary,
    format_dataminer_summary,
)
from .calibration_agent import run_calibration
from .pdf_report import generate_pdf

logger = logging.getLogger("calibration")


def _print_summary(output, symbol: str, tf: str):
    """Print a readable summary table to terminal."""
    print()
    print("=" * 80)
    print(f"  CALIBRATION RESULTS: {symbol} {tf}")
    print("=" * 80)

    meta = output.meta
    print(f"  Trades analisados: {meta.get('dataminer_trades_analyzed', 'N/A')}")
    print(f"  Periodo: {meta.get('dataminer_date_range', ['N/A', 'N/A'])}")
    print(f"  Provider LLM: {meta.get('llm_provider', 'N/A')}")

    if meta.get("warning"):
        print(f"  ⚠ {meta['warning']}")

    print()

    if output.suggestions:
        print("  SUGESTOES:")
        print(f"  {'Parametro':<40} {'Atual':<10} {'Sugerido':<10} {'Conf':<8} {'Tipo'}")
        print("  " + "-" * 90)
        for s in output.suggestions:
            tipo = "DENTRO" if s.tipo == "ajuste_dentro_da_amostra" else "EXTRAPOL"
            print(
                f"  {s.param:<40} {s.current_value:<10} {s.suggested_value:<10} "
                f"{s.confidence:<8} {tipo}"
            )
            print(f"    └─ {s.reasoning[:80]}")
    else:
        print("  Nenhuma sugestao gerada.")

    if output.divergences:
        print()
        print("  DIVERGENCIAS:")
        for d in output.divergences:
            print(f"  • {d.topic}")
            print(f"    Asset DNA: {d.asset_dna_says[:60]}")
            print(f"    DataMiner: {d.dataminer_says[:60]}")

    if output.insufficient_evidence:
        print()
        print("  EVIDENCIA INSUFICIENTE:")
        for e in output.insufficient_evidence:
            print(f"  • {e.param}: {e.reason[:70]}")

    print()
    print("=" * 80)


def main():
    """CLI main entry point."""
    parser = argparse.ArgumentParser(
        description="ALXQuant EA Calibration Agent",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--symbol", required=True, help="Asset symbol (e.g. XAUUSD)")
    parser.add_argument("--tf", default="M5", help="Timeframe (default: M5)")
    parser.add_argument("--asset-dna", required=True, help="Path to asset_profile JSON")
    parser.add_argument("--dataminer", required=True, help="Path to DataMiner CSV")
    parser.add_argument("--mqh", required=True, help="Path to MacroRegimeEngine.mqh")
    parser.add_argument("--out", help="Output JSON path")
    parser.add_argument("--pdf", help="Output PDF path")
    parser.add_argument("--min-sample", type=int, default=30, help="Min trades per bucket")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose logging")

    args = parser.parse_args()

    # Setup logging
    level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=level,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        datefmt="%H:%M:%S",
    )

    print(f"\n{'='*60}")
    print(f"  ALXQuant Calibration Agent")
    print(f"  Symbol: {args.symbol} | TF: {args.tf}")
    print(f"{'='*60}\n")

    # Step 1: Aggregate DataMiner CSV
    print("[1/5] Agregando DataMiner CSV...")
    try:
        dataminer_summary = aggregate(
            args.dataminer, symbol=args.symbol, min_sample=args.min_sample,
        )
        print(f"  → {dataminer_summary.total_trades} trades encontrados")
        if dataminer_summary.warnings:
            for w in dataminer_summary.warnings:
                print(f"  ⚠ {w}")
    except Exception as e:
        print(f"  ERRO: {e}")
        sys.exit(1)

    # Step 2: Load Asset DNA JSON
    print("[2/5] Carregando Asset DNA JSON...")
    try:
        asset_dna = load_asset_dna(args.asset_dna, symbol=args.symbol, timeframe=args.tf)
        print(f"  → Regime dominante: {asset_dna.regime_profile.get('dominant', 'N/A') if asset_dna.regime_profile else 'N/A'}")
    except Exception as e:
        print(f"  ERRO: {e}")
        sys.exit(1)

    # Step 3: Parse MQH
    print("[3/5] Parseando MacroRegimeEngine.mqh...")
    try:
        params = parse_mqh(args.mqh)
        calibratable = [p for p in params if p.calibratable]
        print(f"  → {len(calibratable)} parametros calibraveis encontrados")
    except Exception as e:
        print(f"  ERRO: {e}")
        sys.exit(1)

    # Step 4: Build context and run LLM
    print("[4/5] Montando contexto e chamando LLM...")
    param_table = format_parameter_table(params)
    dna_summary = format_asset_dna_summary(asset_dna)
    dm_summary = format_dataminer_summary(dataminer_summary)

    strategy_context = get_strategy_context(
        parameter_table=param_table,
        asset_dna_summary=dna_summary,
        dataminer_summary=dm_summary,
    )

    try:
        output = run_calibration(
            strategy_context=strategy_context,
            symbol=args.symbol,
            timeframe=args.tf,
            min_sample=args.min_sample,
        )
        print(f"  → {len(output.suggestions)} sugestoes geradas")
    except Exception as e:
        print(f"  ERRO no LLM: {e}")
        sys.exit(1)

    # Step 5: Save outputs
    print("[5/5] Salvando resultados...")

    # JSON
    out_path = args.out or f"data/mql5/calibration_{args.symbol}_{args.tf}.json"
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(output.model_dump(), f, indent=2, ensure_ascii=False, default=str)
    print(f"  → JSON: {out_path}")

    # PDF (optional)
    if args.pdf:
        try:
            pdf_path = generate_pdf(output, args.pdf, symbol=args.symbol, timeframe=args.tf)
            print(f"  → PDF: {pdf_path}")
        except Exception as e:
            print(f"  ⚠ PDF generation failed: {e}")

    # Print summary
    _print_summary(output, args.symbol, args.tf)


if __name__ == "__main__":
    main()
