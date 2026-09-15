"""DANTE — AI Code Auditor for ALXQuant.

Usage:
    python -m dante.main scan [--target DIR] [--llm] [--clear]
    python -m dante.main report
    python -m dante.main stats
"""

import argparse
import sys
from pathlib import Path


def cmd_scan(args):
    """Run the scan → analyze → report pipeline."""
    from .config import DanteConfig, config
    from .core.orchestrator import run_scan
    from .core.knowledge import KnowledgeBase

    cfg = config
    if args.target:
        cfg.scan.target_dir = Path(args.target)

    if args.clear:
        kb = KnowledgeBase()
        kb.clear_session()
        kb.close()
        print("Sessao anterior limpa.")

    print(f"DANTE v0.1 — AI Code Auditor")
    print(f"Target: {cfg.scan.target_dir}")
    print(f"LLM: {'habilitado' if args.llm else 'desabilitado'}")
    print()

    result = run_scan(cfg=cfg, use_llm=args.llm)
    print()
    print(f"Relatorio: {result['report_path']}")


def cmd_report(args):
    """Show the latest report."""
    from .config import config
    report_dir = config.report.output_dir
    reports = sorted(report_dir.glob("dante-report-*.md"), reverse=True)
    if not reports:
        print("Nenhum relatorio encontrado. Execute 'dante scan' primeiro.")
        return
    latest = reports[0]
    print(latest.read_text(encoding="utf-8"))


def cmd_stats(args):
    """Show knowledge base stats."""
    from .core.knowledge import KnowledgeBase
    kb = KnowledgeBase()
    stats = kb.get_stats()
    kb.close()
    print(f"Arquivos indexados: {stats['files']}")
    print(f"Total findings: {stats['findings']}")
    if stats["by_severity"]:
        print("Por severidade:")
        for sev, count in sorted(stats["by_severity"].items()):
            print(f"  {sev}: {count}")


def main():
    parser = argparse.ArgumentParser(
        prog="dante",
        description="DANTE — AI Code Auditor for ALXQuant",
    )
    sub = parser.add_subparsers(dest="command", help="Comandos disponiveis")

    scan_parser = sub.add_parser("scan", help="Analise completa do codebase")
    scan_parser.add_argument("--target", "-t", help="Diretorio alvo (default: ALXQuant root)")
    scan_parser.add_argument("--llm", action="store_true", help="Habilitar analise LLM")
    scan_parser.add_argument("--clear", action="store_true", help="Limpar sessao anterior")
    scan_parser.set_defaults(func=cmd_scan)

    report_parser = sub.add_parser("report", help="Exibir relatorio mais recente")
    report_parser.set_defaults(func=cmd_report)

    stats_parser = sub.add_parser("stats", help="Estatisticas da knowledge base")
    stats_parser.set_defaults(func=cmd_stats)

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    args.func(args)


if __name__ == "__main__":
    main()
