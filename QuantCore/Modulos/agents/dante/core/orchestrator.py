"""DANTE Orchestrator — scan → index → analyze → report pipeline."""

import hashlib
import time
from pathlib import Path
from typing import Optional

from ..config import config, DanteConfig, get_exclude_folders
from .knowledge import KnowledgeBase
from .git_utils import get_branch, get_commit_hash, is_git_repo


def _hash_file(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def _detect_language(path: Path) -> str:
    ext = path.suffix.lower()
    return {
        ".mq5": "mql5",
        ".mqh": "mql5",
        ".py": "python",
        ".sql": "sql",
    }.get(ext, "unknown")


def run_scan(cfg: Optional[DanteConfig] = None, use_llm: bool = False) -> dict:
    """Execute the full DANTE pipeline."""
    if cfg is None:
        cfg = config

    start = time.time()
    kb = KnowledgeBase()

    from ..analyzers.mql5.scanner import scan_mql5_files, analyze_file as analyze_mql5
    from ..analyzers.python.scanner import scan_python_files, analyze_file as analyze_python
    from ..analyzers.security.scanner import scan_file as scan_security
    from ..analyzers.performance.scanner import scan_file as scan_performance
    from ..analyzers.sql.scanner import scan_sql_files, analyze_file as analyze_sql

    all_findings = []
    files_analyzed = 0

    def analyze_path(fp: Path, language: str, analyzer, extra_scanners=()) -> None:
        nonlocal files_analyzed
        file_hash = _hash_file(fp)
        if kb.file_exists(str(fp), file_hash):
            findings = kb.get_findings(str(fp))
            for scanner in extra_scanners:
                findings.extend(scanner(fp))
            if extra_scanners:
                kb.replace_findings_for_file(str(fp), findings)
            all_findings.extend(findings)
            return
        result = analyzer(fp)
        findings = result["findings"] if isinstance(result, dict) else result
        for scanner in extra_scanners:
            findings.extend(scanner(fp))
        for finding in findings:
            finding["file_path"] = str(fp)
            finding.setdefault("rule_id", finding.get("rule", "UNKNOWN"))
            finding.setdefault("category", "scanner")
            finding.setdefault("source", "tool")
        kb.replace_findings_for_file(str(fp), findings)
        all_findings.extend(findings)
        kb.upsert_file(str(fp), language, fp.stat().st_size, file_hash)
        files_analyzed += 1

    mql5_files = scan_mql5_files(cfg.scan.target_dir)
    py_files = scan_python_files(cfg.scan.target_dir)
    sql_files = scan_sql_files(str(cfg.scan.target_dir))

    exclude_folders = get_exclude_folders()
    if exclude_folders:
        def _is_excluded(fp: Path) -> bool:
            parts = fp.parts
            return any(ef in parts for ef in exclude_folders)
        mql5_files = [f for f in mql5_files if not _is_excluded(f)]
        py_files = [f for f in py_files if not _is_excluded(f)]
        sql_files = [f for f in sql_files if not _is_excluded(f)]
        print(f"  [SCAN] Excluidas {len(exclude_folders)} pastas do usuario")

    print(f"  [SCAN] {len(mql5_files)} arquivos MQL5 encontrados")
    for fp in mql5_files:
        analyze_path(fp, "mql5", analyze_mql5)

    print(f"  [SCAN] {len(py_files)} arquivos Python encontrados")
    for fp in py_files:
        analyze_path(fp, "python", analyze_python,
                     extra_scanners=(scan_security, scan_performance))

    print(f"  [SCAN] {len(sql_files)} arquivos SQL encontrados")
    for fp in sql_files:
        analyze_path(fp, "sql", analyze_sql)

    current_paths = {str(fp) for fp in (*mql5_files, *py_files, *sql_files)}
    kb.remove_missing_files(current_paths)

    print(f"  [ANALYZE] {files_analyzed} arquivos analisados, {len(all_findings)} findings")

    kb.add_findings_batch(all_findings)

    if use_llm:
        print(f"  [LLM] Analise LLM habilitada...")
        all_findings = _run_llm_analysis(cfg, kb, all_findings)

    git_branch = get_branch(cfg.scan.target_dir) if is_git_repo(cfg.scan.target_dir) else ""
    git_commit = get_commit_hash(cfg.scan.target_dir) if is_git_repo(cfg.scan.target_dir) else ""

    from ..reports.markdown import generate_report
    report_path = generate_report(
        findings=all_findings,
        stats=kb.get_stats(),
        files_analyzed=files_analyzed,
        output_dir=cfg.report.output_dir,
        git_branch=git_branch,
        git_commit=git_commit,
    )

    elapsed = time.time() - start
    stats = kb.get_stats()
    kb.close()

    print(f"  [REPORT] {report_path}")
    print(f"  [DONE] {elapsed:.1f}s | {stats['files']} files | {stats['findings']} findings")

    return {
        "report_path": str(report_path),
        "stats": stats,
        "elapsed": elapsed,
        "files_analyzed": files_analyzed,
    }


def _run_llm_analysis(cfg: DanteConfig, kb: KnowledgeBase,
                      tool_findings: list[dict]) -> list[dict]:
    """Run LLM analysis on files with existing tool findings."""
    try:
        from ..llm.openai_provider import OpenAIProvider
        from ..reports.validator import validate_llm_findings

        llm = OpenAIProvider(
            model=cfg.llm.model,
            api_key=cfg.llm.api_key,
            base_url=cfg.llm.base_url,
            temperature=cfg.llm.temperature,
            max_tokens=cfg.llm.max_tokens,
        )
        if not llm.health_check():
            print("  [LLM] Health check failed — pulando analise LLM")
            return tool_findings

        files_with_findings = set(f["file_path"] for f in tool_findings)
        llm_findings = []

        for file_path in files_with_findings:
            fp = Path(file_path)
            if not fp.exists():
                continue
            lines = fp.read_text(encoding="utf-8", errors="ignore").splitlines()
            code = "\n".join(lines[:200])
            lang = _detect_language(fp)

            resp = llm.analyze_code(code, lang, context=f"File: {file_path}")
            validated = validate_llm_findings(code, resp.content, lang)
            for v in validated:
                v["file_path"] = file_path
            llm_findings.extend(validated)

        print(f"  [LLM] {len(llm_findings)} findings LLM validados")
        return tool_findings + llm_findings

    except ImportError:
        print("  [LLM] litellm nao instalado — pulando")
        return tool_findings
    except Exception as e:
        print(f"  [LLM] Erro: {e} — pulando")
        return tool_findings
