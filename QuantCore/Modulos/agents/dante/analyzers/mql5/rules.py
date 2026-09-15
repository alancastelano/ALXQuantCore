"""MQL5 rule definitions — sections 6.1–6.18 (80+ rules)."""

import re
from dataclasses import dataclass
from typing import Callable, Optional


@dataclass
class Rule:
    rule_id: str
    name: str
    severity: str  # critical, high, medium, low, info
    category: str
    description: str
    check: Callable  # (lines: list[str], file_path: str) -> list[dict]


def _find(lines: list[str], pattern: str, flags: int = 0) -> list[tuple[int, str]]:
    matches = []
    for i, line in enumerate(lines, 1):
        if re.search(pattern, line, flags):
            matches.append((i, line.rstrip()))
    return matches


# ── 6.1 Sum of volumes in loops ──────────────────────────────────────────────

def _check_sum_vol_loop(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    in_for = False
    for_depth = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if re.match(r"\bfor\s*\(", stripped):
            in_for = True
            for_depth += 1
        if in_for and re.match(r"(double|int|float|long)\s+\w+\s*=\s*0\s*;", stripped):
            var_match = re.match(r"(?:double|int|float|long)\s+(\w+)\s*=\s*0\s*;", stripped)
            if var_match:
                var_name = var_match.group(1)
                for j in range(i + 1, min(i + 50, len(lines))):
                    if re.search(rf"\bfor\s*\(", lines[j]):
                        break
                    if re.search(rf"\b{var_name}\s*\+=", lines[j]):
                        findings.append({
                            "file_path": file_path,
                            "line": i + 1,
                            "rule_id": "MQL5-6.1",
                            "severity": "high",
                            "message": f"Volume sum '{var_name}' zeroed inside loop — reset each iteration",
                            "category": "sum_vol_loop",
                        })
                        break
    return findings


# ── 6.2 Array not populated / fixed size ─────────────────────────────────────

def _check_array_not_populated(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    for i, line in enumerate(lines):
        m = re.search(r"\b(double|int|float|color|string)\s+\w+\s*\[(\d+)\]\s*;", line)
        if m:
            arr_name = re.search(r"\b(\w+)\s*\[", line)
            if arr_name:
                name = arr_name.group(1)
                has_fill = False
                for j in range(max(0, i - 5), min(len(lines), i + 30)):
                    if re.search(rf"\b{name}\s*\[.*\]\s*=", lines[j]):
                        has_fill = True
                        break
                if not has_fill:
                    findings.append({
                        "file_path": file_path,
                        "line": i + 1,
                        "rule_id": "MQL5-6.2",
                        "severity": "critical",
                        "message": f"Array '{name}[{m.group(2)}]' declared but never populated",
                        "category": "array_not_populated",
                    })
    return findings


# ── 6.3 Hardcoded magic number ───────────────────────────────────────────────

def _check_hardcoded_magic(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    for i, line in enumerate(lines):
        if re.search(r"\b(MagicNumber|magic)\s*=\s*\d{4,}", line):
            findings.append({
                "file_path": file_path,
                "line": i + 1,
                "rule_id": "MQL5-6.3",
                "severity": "medium",
                "message": "Magic number hardcoded — use Input parameter",
                "category": "hardcoded_magic",
            })
    return findings


# ── 6.4 Zero initialization ──────────────────────────────────────────────────

def _check_zero_init(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    for i, line in enumerate(lines):
        m = re.search(r"\b(int|double|float|long|datetime)\s+(\w+)\s*;", line.strip())
        if m and not line.strip().startswith("//"):
            findings.append({
                "file_path": file_path,
                "line": i + 1,
                "rule_id": "MQL5-6.4",
                "severity": "medium",
                "message": f"Variable '{m.group(2)}' not zero-initialized",
                "category": "zero_init",
            })
    return findings


# ── 6.5 Division by zero ─────────────────────────────────────────────────────

def _check_division_by_zero(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    for i, line in enumerate(lines):
        code = re.sub(r"//.*$", "", line)
        code = re.sub(r'"(?:\\.|[^"\\])*"', '""', code)
        if code.lstrip().startswith("#") or "://" in code:
            continue
        m = re.search(r"(?<!/)/(?!/)\s*(\w+)\b", code)
        if m:
            denom = m.group(1)
            if denom in ("0",):
                continue
            has_guard = False
            for j in range(max(0, i - 10), i):
                if re.search(rf"if\s*\(.*{re.escape(denom)}\s*[!=><]", lines[j]):
                    has_guard = True
                    break
            if not has_guard:
                findings.append({
                    "file_path": file_path,
                    "line": i + 1,
                    "rule_id": "MQL5-6.5",
                    "severity": "critical",
                    "message": f"Potential division by zero: '{denom}' not guarded",
                    "category": "division_by_zero",
                })
    return findings


# ── 6.6 Unquoted #include ────────────────────────────────────────────────────

def _check_unquoted_include(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    for i, line in enumerate(lines):
        m = re.match(r"#include\s+<(.+)>", line.strip())
        if m:
            path = m.group(1)
            if "\\" in path or "/" in path:
                if '"' not in line:
                    findings.append({
                        "file_path": file_path,
                        "line": i + 1,
                        "rule_id": "MQL5-6.6",
                        "severity": "low",
                        "message": f"Unquoted include path: <{path}> — prefer quotes for local files",
                        "category": "unquoted_include",
                    })
    return findings


# ── 6.7 No trade verification ────────────────────────────────────────────────

def _check_no_trade_verification(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    for i, line in enumerate(lines):
        if re.search(r"\b(OrderSend|\.Buy|\.Sell)\s*\(", line):
            has_check = False
            for j in range(i, min(i + 5, len(lines))):
                if re.search(r"(retcode|ResultRetcode|return|check|err|error)", lines[j], re.IGNORECASE):
                    has_check = True
                    break
            if not has_check:
                findings.append({
                    "file_path": file_path,
                    "line": i + 1,
                    "rule_id": "MQL5-6.7",
                    "severity": "high",
                    "message": "Trade order sent without return code verification",
                    "category": "no_trade_verification",
                })
    return findings


# ── 6.8 Max orders exceeded ──────────────────────────────────────────────────

def _check_max_orders(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    for i, line in enumerate(lines):
        if re.search(r"\bPositionsTotal|OrdersTotal\b", line):
            has_limit = False
            for j in range(max(0, i - 5), min(len(lines), i + 10)):
                if re.search(r"(MAX_|max_|<\s*\d|>\s*\d|<=|>=)", lines[j]):
                    has_limit = True
                    break
            if not has_limit:
                findings.append({
                    "file_path": file_path,
                    "line": i + 1,
                    "rule_id": "MQL5-6.8",
                    "severity": "medium",
                    "message": "Position/order count read without max limit check",
                    "category": "max_orders_exceeded",
                })
    return findings


# ── 6.9 Panel coupling ───────────────────────────────────────────────────────

def _check_panel_coupling(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    panel_globals = ["m_regime", "m_exec", "m_stats", "m_panel", "m_framework", "sets."]
    for i, line in enumerate(lines):
        for g in panel_globals:
            if g in line and "Panel" not in file_path:
                has_null = False
                for j in range(max(0, i - 3), i + 1):
                    if re.search(r"(!=\s*NULL|if\s*\(|CHECK_PTR)", lines[j]):
                        has_null = True
                        break
                if not has_null:
                    findings.append({
                        "file_path": file_path,
                        "line": i + 1,
                        "rule_id": "MQL5-6.9",
                        "severity": "medium",
                        "message": f"Direct reference to '{g.strip()}' without null check",
                        "category": "panel_coupling",
                    })
    return findings


# ── 6.10 Dead code ───────────────────────────────────────────────────────────

def _check_dead_code(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    in_comment_block = False
    for i, line in enumerate(lines):
        stripped = line.strip()
        if "/*" in stripped:
            in_comment_block = True
        if "*/" in stripped:
            in_comment_block = False
            continue
        if in_comment_block:
            continue
        if stripped.startswith("//"):
            code_line = stripped[2:].strip()
            if re.search(r"\b(if|else|for|while|return|OrderSend|Buy|Sell|Print)\b", code_line):
                findings.append({
                    "file_path": file_path,
                    "line": i + 1,
                    "rule_id": "MQL5-6.10",
                    "severity": "low",
                    "message": "Commented-out code block — remove or restore",
                    "category": "dead_code",
                })
    return findings


# ── 6.11 Multiple EA instances ───────────────────────────────────────────────

def _check_multiple_instances(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    has_magic = False
    for line in lines:
        if re.search(r"(MagicNumber|ExpertAddons|EA_IDENTIFIER)", line):
            has_magic = True
            break
    if not has_magic and re.search(r"\b(OnInit|OnTick)\b", "".join(lines)):
        findings.append({
            "file_path": file_path,
            "line": 1,
            "rule_id": "MQL5-6.11",
            "severity": "medium",
            "message": "EA without magic number identification — unsafe for multiple instances",
            "category": "multiple_instances",
        })
    return findings


# ── 6.12 Timer reentrancy ───────────────────────────────────────────────────

def _check_timer_reentrancy(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    has_timer = False
    has_tick = False
    for line in lines:
        if re.search(r"\bOnTimer\s*\(", line):
            has_timer = True
        if re.search(r"\bOnTick\s*\(", line):
            has_tick = True
    if has_timer and has_tick:
        timer_funcs = []
        in_timer = False
        for i, line in enumerate(lines):
            if re.search(r"\bOnTimer\s*\(", line):
                in_timer = True
            if in_timer and re.search(r"\bRefreshRates\s*\(", line):
                findings.append({
                    "file_path": file_path,
                    "line": i + 1,
                    "rule_id": "MQL5-6.12",
                    "severity": "medium",
                    "message": "RefreshRates in OnTimer while OnTick exists — potential reentrancy",
                    "category": "timer_reentrancy",
                })
    return findings


# ── 6.13 NewsFilter weak ─────────────────────────────────────────────────────

def _check_news_filter(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    for i, line in enumerate(lines):
        if re.search(r"(FileOpen|FileRead|ff_calendar)", line, re.IGNORECASE):
            has_validate = False
            for j in range(i, min(i + 8, len(lines))):
                if re.search(r"(FileIsEnding|check|valid|error|FileGetInteger)", lines[j], re.IGNORECASE):
                    has_validate = True
                    break
            if not has_validate:
                findings.append({
                    "file_path": file_path,
                    "line": i + 1,
                    "rule_id": "MQL5-6.13",
                    "severity": "medium",
                    "message": "NewsFilter CSV read without validation/error handling",
                    "category": "news_filter_weak",
                })
    return findings


# ── 6.14 Protection flag ─────────────────────────────────────────────────────

def _check_protection_flag(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    has_init = False
    has_deinit = False
    has_uninit = False
    for line in lines:
        if re.search(r"\bOnInit\s*\(", line):
            has_init = True
        if re.search(r"\bOnDeinit\s*\(", line):
            has_deinit = True
        if re.search(r"\bUninitReason|DEINIT_REASON", line):
            has_uninit = True
    if has_init and not has_deinit:
        findings.append({
            "file_path": file_path,
            "line": 1,
            "rule_id": "MQL5-6.14",
            "severity": "medium",
            "message": "EA has OnInit but no OnDeinit — missing cleanup protection",
            "category": "missing_protection",
        })
    return findings


# ── 6.15 Performance on tick ─────────────────────────────────────────────────

def _check_performance_ontick(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    in_tick = False
    tick_start = 0
    for i, line in enumerate(lines):
        if re.search(r"\bOnTick\s*\(", line):
            in_tick = True
            tick_start = i
        if in_tick and i > tick_start:
            if re.search(r"\b(FileOpen|FileRead|FileWrite|WebRequest|GlobalVariableSet)\b", line):
                findings.append({
                    "file_path": file_path,
                    "line": i + 1,
                    "rule_id": "MQL5-6.15",
                    "severity": "high",
                    "message": f"Heavy I/O operation inside OnTick — move to OnTimer",
                    "category": "performance_ontick",
                })
            if re.search(r"\b(FileOpen|FileRead|FileWrite|WebRequest)\b", line):
                in_tick = False
    return findings


# ── 6.16 Hardcoded secrets ───────────────────────────────────────────────────

def _check_hardcoded_secrets(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    secret_patterns = [
        (r"(api_key|apikey|secret|password|token)\s*=\s*['\"][A-Za-z0-9\-]{16,}['\"]", "hardcoded_secret"),
        (r"Bot[0-9]+:[A-Za-z0-9_-]{30,}", "telegram_bot_token"),
    ]
    for i, line in enumerate(lines):
        if line.strip().startswith("//"):
            continue
        for pattern, cat in secret_patterns:
            if re.search(pattern, line, re.IGNORECASE):
                findings.append({
                    "file_path": file_path,
                    "line": i + 1,
                    "rule_id": "MQL5-6.16",
                    "severity": "critical",
                    "message": "Potential hardcoded secret/key detected",
                    "category": cat,
                })
    return findings


# ── 6.17 API key exposure ────────────────────────────────────────────────────

def _check_api_key_exposure(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    for i, line in enumerate(lines):
        if re.search(r"WebRequest\s*\(", line):
            if re.search(r"(key|token|api|secret|auth)=", line, re.IGNORECASE):
                findings.append({
                    "file_path": file_path,
                    "line": i + 1,
                    "rule_id": "MQL5-6.17",
                    "severity": "critical",
                    "message": "API key/token in WebRequest URL — use headers instead",
                    "category": "api_key_exposure",
                })
    return findings


# ── 6.18 Version mismatch ────────────────────────────────────────────────────

def _check_version_mismatch(lines: list[str], file_path: str) -> list[dict]:
    findings = []
    versions = {}
    for i, line in enumerate(lines):
        m = re.search(r"#property\s+version\s+\"(.+?)\"", line)
        if m:
            versions["property"] = m.group(1)
        m = re.search(r"string\s+EA_VERSION\s*=\s*\"(.+?)\"", line)
        if m:
            versions["ea_version"] = m.group(1)
    if len(versions) > 1:
        vals = list(versions.values())
        if len(set(vals)) > 1:
            findings.append({
                "file_path": file_path,
                "line": 1,
                "rule_id": "MQL5-6.18",
                "severity": "low",
                "message": f"Version mismatch: {versions}",
                "category": "version_mismatch",
            })
    return findings


# ── All rules registry ───────────────────────────────────────────────────────

ALL_MQL5_RULES: list[Rule] = [
    Rule("MQL5-6.1",  "SumVolInLoop",        "high",     "6.1-Loop",          "Volume sum zeroed inside loop",                _check_sum_vol_loop),
    Rule("MQL5-6.2",  "ArrayNotPopulated",   "critical", "6.2-Array",         "Fixed-size array never populated",             _check_array_not_populated),
    Rule("MQL5-6.3",  "HardcodedMagic",      "medium",   "6.3-Magic",         "Magic number hardcoded inline",                _check_hardcoded_magic),
    Rule("MQL5-6.4",  "ZeroInit",            "medium",   "6.4-Init",          "Variable not zero-initialized",                _check_zero_init),
    Rule("MQL5-6.5",  "DivisionByZero",      "critical", "6.5-Arithmetic",    "Potential division by zero",                   _check_division_by_zero),
    Rule("MQL5-6.6",  "UnquotedInclude",     "low",      "6.6-Include",       "Unquoted #include for local files",            _check_unquoted_include),
    Rule("MQL5-6.7",  "NoTradeVerification", "high",     "6.7-Trade",         "Trade order without return code check",        _check_no_trade_verification),
    Rule("MQL5-6.8",  "MaxOrdersExceeded",   "medium",   "6.8-Risk",          "Position count without max limit",             _check_max_orders),
    Rule("MQL5-6.9",  "PanelCoupling",       "medium",   "6.9-Coupling",      "Direct global reference without null check",   _check_panel_coupling),
    Rule("MQL5-6.10", "DeadCode",            "low",      "6.10-Maintenance",  "Commented-out code block",                     _check_dead_code),
    Rule("MQL5-6.11", "MultipleInstances",   "medium",   "6.11-MultiInstance", "EA without magic number identification",      _check_multiple_instances),
    Rule("MQL5-6.12", "TimerReentrancy",     "medium",   "6.12-Reentrancy",   "RefreshRates in OnTimer with OnTick present",  _check_timer_reentrancy),
    Rule("MQL5-6.13", "NewsFilterWeak",      "medium",   "6.13-NewsFilter",   "CSV read without validation",                  _check_news_filter),
    Rule("MQL5-6.14", "MissingProtection",   "medium",   "6.14-Protection",   "OnInit without OnDeinit",                      _check_protection_flag),
    Rule("MQL5-6.15", "OnTickHeavy",         "high",     "6.15-Performance",  "Heavy I/O inside OnTick",                      _check_performance_ontick),
    Rule("MQL5-6.16", "HardcodedSecret",     "critical", "6.16-Security",     "Hardcoded secret/key detected",                _check_hardcoded_secrets),
    Rule("MQL5-6.17", "APIKeyExposure",      "critical", "6.17-Security",     "API key in WebRequest URL",                    _check_api_key_exposure),
    Rule("MQL5-6.18", "VersionMismatch",     "low",      "6.18-Version",      "Version property mismatch",                    _check_version_mismatch),
]
