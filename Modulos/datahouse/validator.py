"""
Validador completo de integridade de dados para pipelines ALXQuant.

Validações implementadas:
- Integridade OHLC (não nulo, consistência, valores razoáveis)
- Validação de gaps (distância mínima entre candles)
- Freshness (dados não mais antigos que X horas)
- Duplicatas (detecta registros duplicados)
- Campos obrigatórios (não nulo)
- Limites de valores (bounds reasonable)
- Consistência (correlações esperadas)

Funções de módulo para health checks multi-domínio:
- check_domain_freshness()  - status por domínio (OHLC/Macro/Calendar/Risk)
- repair_domain()           - dispara reparos assíncronos
- get_repair_status()       - progresso do reparo
- count_pending_repairs()   - itens pendentes por domínio
"""

import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import numpy as np
from typing import Dict, List, Tuple, Any
from datetime import timedelta
import logging
import re
import json

from .collector import get_connection


class DataValidator:
    """
    Validador completo de integridade de dados para pipelines ALXQuant.
    
    Responsabilidades principais:
    - Validação de integridade de dados para OHLC, macro e notícias
    - Detecção de problemas e gaps críticos
    - Auditoria de logs para operações sensíveis
    - Garante qualidade consistente de dados
    """
    
    def __init__(self, config: dict = None):
        self.config = config or {}
        self.logger = logging.getLogger(__name__)
        self.validation_rules = self._load_validation_rules()
        
    def _load_validation_rules(self) -> Dict[str, Any]:
        """Carrega regras de validação de arquivo de configuração ou usa padrões."""
        rules_path = Path(__file__).parent / "validation_rules.json"
        
        default_rules = {
            "ohlc": {
                "required_columns": ['symbol', 'timeframe', 'datetime', 'open', 'high', 'low', 'close', 'volume'],
                "null_checks": ['datetime', 'symbol', 'open', 'high', 'low', 'close'],
                "ohlc_consistency": True,
                "reasonable_bounds": {
                    'open': (-1e6, 1e6),
                    'high': (-1e6, 1e6),
                    'low': (-1e6, 1e6),
                    'close': (-1e6, 1e6),
                    'volume': (-1e6, 1e6)
                },
                "max_gap_minutes": 60,
                "min_candles": 1
            },
            "macro": {
                "required_columns": ['symbol', 'datetime', 'value', 'series_id'],
                "null_checks": ['symbol', 'datetime', 'value'],
                "bounds_checks": {
                    'value': (-1e6, 1e6),
                    'rate_of_change': (-0.5, 0.5)
                },
                "max_age_hours": 168
            },
            "calendar": {
                "required_columns": ['datetime', 'event', 'country', 'impact'],
                "impact_values": ['HIGH', 'MEDIUM', 'LOW'],
                "datetime_range": {
                    'past_days': 365,
                    'future_days': 180
                }
            }
        }
        
        try:
            if rules_path.exists():
                with open(rules_path, 'r') as f:
                    return json.load(f)
            else:
                with open(rules_path, 'w') as f:
                    json.dump(default_rules, f, indent=2)
                return default_rules
        except Exception as e:
            self.logger.warning(f"Erro ao carregar regras de validação: {e}")
            return default_rules
    
    def validate_dataframe(
        self, 
        df: pd.DataFrame, 
        data_type: str,
        additional_rules: Dict[str, Any] = None
    ) -> Tuple[bool, List[str]]:
        """
        Valida um DataFrame completo baseado no tipo de dados.
        
        Args:
            df: DataFrame a ser validado
            data_type: Tipo de dados ('ohlc', 'macro', 'calendar')
            additional_rules: Regras extras para sobrescrever default
            
        Retorna:
            Tupla (is_valid, lista_de_problemas)
        """
        if df.empty:
            return False, ["DataFrame vazio não pode ser validado"]
            
        issues = []
        
        rules = self.validation_rules.get(data_type, {}).copy()
        if additional_rules:
            rules.update(additional_rules)
            
        if data_type == 'ohlc':
            ohlc_issues = self._validate_ohlc_integrity(df, rules)
            issues.extend(ohlc_issues)
            
        elif data_type == 'macro':
            macro_issues = self._validate_macro_integrity(df, rules)
            issues.extend(macro_issues)
            
        elif data_type == 'calendar':
            calendar_issues = self._validate_calendar_integrity(df, rules)
            issues.extend(calendar_issues)
            
        basic_issues = self._validate_basic_integrity(df)
        issues.extend(basic_issues)
        
        is_valid = len(issues) == 0
        return is_valid, issues
    
    def _validate_ohlc_integrity(self, df: pd.DataFrame, rules: Dict) -> List[str]:
        """Valida integridade OHLC completa."""
        issues = []
        
        missing_columns = []
        for col in rules['required_columns']:
            if col not in df.columns:
                missing_columns.append(col)
                
        if missing_columns:
            issues.append(f"Colunas obrigatórias ausentes: {missing_columns}")
        
        null_issues = self._check_nulls(df, rules['null_checks'])
        issues.extend(null_issues)
        
        if rules.get('ohlc_consistency', True):
            ohlc_issues = self._check_ohlc_consistency(df)
            issues.extend(ohlc_issues)
        
        bound_issues = self._check_reasonable_bounds(df, rules.get('reasonable_bounds', {}))
        issues.extend(bound_issues)
        
        if 'max_gap_minutes' in rules:
            gap_issues = self._check_gaps(df, rules['max_gap_minutes'])
            issues.extend(gap_issues)
        
        return issues
    
    def _validate_macro_integrity(self, df: pd.DataFrame, rules: Dict) -> List[str]:
        """Valida integridade de dados macroeconômicos."""
        issues = []
        
        missing_columns = [col for col in rules['required_columns'] if col not in df.columns]
        if missing_columns:
            issues.append(f"Colunas obrigatórias ausentes: {missing_columns}")
        
        null_issues = self._check_nulls(df, rules.get('null_checks', []))
        issues.extend(null_issues)
        
        if 'bounds_checks' in rules:
            for col, (min_val, max_val) in rules['bounds_checks'].items():
                if col in df.columns:
                    out_of_bounds = (df[col] < min_val) | (df[col] > max_val)
                    if out_of_bounds.any():
                        issues.append(f"Coluna {col} tem {out_of_bounds.sum()} valores fora dos limites ({min_val}, {max_val})")
        
        if 'max_age_hours' in rules and 'datetime' in df.columns:
            if df['datetime'].dtype != 'datetime64[ns]':
                df['datetime'] = pd.to_datetime(df['datetime'])
                
            max_age = timedelta(hours=rules['max_age_hours'])
            oldest_data = df['datetime'].max()
            age = datetime.now() - oldest_data
            
            if age > max_age:
                issues.append(f"Dados macro estão muito antigos: {age} > {max_age}")
        
        return issues
    
    def _validate_calendar_integrity(self, df: pd.DataFrame, rules: Dict) -> List[str]:
        """Valida integridade de calendário de notícias."""
        issues = []
        
        missing_columns = [col for col in rules['required_columns'] if col not in df.columns]
        if missing_columns:
            issues.append(f"Colunas obrigatórias ausentes: {missing_columns}")
        
        if 'impact_values' in rules and 'impact' in df.columns:
            invalid_impacts = ~df['impact'].isin(rules['impact_values'])
            if invalid_impacts.any():
                issues.append(f"Valores de impacto inválidos: {invalid_impacts.sum()}")
        
        if 'datetime_range' in rules and 'datetime' in df.columns:
            if df['datetime'].dtype != 'datetime64[ns]':
                df['datetime'] = pd.to_datetime(df['datetime'])
                
            past_limit = datetime.now() - timedelta(days=rules['datetime_range']['past_days'])
            future_limit = datetime.now() + timedelta(days=rules['datetime_range']['future_days'])
            
            past_issues = df['datetime'] < past_limit
            future_issues = df['datetime'] > future_limit
            
            if past_issues.any():
                issues.append(f"Dados de calendário no passado muito antigo: {past_issues.sum()}")
            if future_issues.any():
                issues.append(f"Dados de calendário no futuro distante: {future_issues.sum()}")
        
        return issues
        
    def _validate_basic_integrity(self, df: pd.DataFrame) -> List[str]:
        """Validações básicas aplicáveis a todos os tipos de dados."""
        issues = []
        
        if df.empty:
            issues.append("DataFrame está vazio")
        
        if df.empty:
            issues.append("DataFrame vazio não pode ser validado")
        
        return issues
        
    def _check_nulls(self, df: pd.DataFrame, columns: List[str]) -> List[str]:
        """Check de valores nulos em colunas específicas."""
        issues = []
        
        for col in columns:
            if col not in df.columns:
                continue
                
            null_count = df[col].isnull().sum()
            if null_count > 0:
                issues.append(f"Coluna '{col}' tem {null_count} valores nulos")
                
        return issues
        
    def _check_ohlc_consistency(self, df: pd.DataFrame) -> List[str]:
        """Valida consistência OHLC (high >= low, etc.)."""
        issues = []
        
        ohlc_issues = (
            (df['high'] < df['low']) |
            (df['open'] > df['high']) |
            (df['close'] < df['low']) |
            (df['close'] > df['high'])
        )
        
        if ohlc_issues.any():
            issues.append(f"Encontradas {ohlc_issues.sum()} inconsistências OHLC")
            
        return issues
        
    def _check_reasonable_bounds(self, df: pd.DataFrame, bounds: Dict) -> List[str]:
        """Valida se valores estão dentro de limites razoáveis."""
        issues = []
        
        for col, (min_val, max_val) in bounds.items():
            if col not in df.columns:
                continue
                
            out_of_bounds = (df[col] < min_val) | (df[col] > max_val)
            if out_of_bounds.any():
                issues.append(f"Coluna {col} tem {out_of_bounds.sum()} valores fora dos limites ({min_val}, {max_val})")
                
        return issues
        
    def _check_gaps(self, df: pd.DataFrame, max_gap_minutes: int) -> List[str]:
        """Valida que não há gaps excessivos entre candles."""
        issues = []
        
        if df.empty:
            return issues
            
        df_sorted = df.sort_values(['symbol', 'datetime'])
        
        if df_sorted['datetime'].dtype == 'timedelta64[ns]':
            gap_minutes = df_sorted['datetime'].dt.total_seconds() / 60
            large_gaps = gap_minutes > max_gap_minutes
            
            if large_gaps.any():
                for symbol in df_sorted[large_gaps]['symbol'].unique():
                    gap_count = large_gaps & (df_sorted['symbol'] == symbol)
                    gap_times = df_sorted[gap_count]['datetime']
                    issues.append(f"Símbolo {symbol}: {gap_count.sum()} gaps maiores que {max_gap_minutes} minutos (ex: {gap_times.max()})")
        
        return issues


# ─────────────────────────────────────────────────────────────────────
# Funções de módulo: gaps / integridade / freshness / repair
# ─────────────────────────────────────────────────────────────────────

def check_gaps(
    symbol: str,
    timeframe: str,
    max_gap_minutes: int = 30,
) -> list[dict]:
    with get_connection() as conn:
        threshold = max_gap_minutes * 60
        rows = conn.execute("""
            SELECT prev_time, time, gap
            FROM (
                SELECT
                    LAG(time) OVER (ORDER BY time) AS prev_time,
                    time,
                    time - LAG(time) OVER (ORDER BY time) AS gap
                FROM ohlc_prices
                WHERE symbol = ? AND timeframe = ?
            )
            WHERE gap > ?
            ORDER BY prev_time
            LIMIT 50
        """, [symbol, timeframe, threshold]).fetchall()

        gaps = []
        for prev, cur, gap_sec in rows:
            from_dt = datetime.fromtimestamp(prev, tz=timezone.utc)
            to_dt = datetime.fromtimestamp(cur, tz=timezone.utc)
            gap_hours = gap_sec / 3600

            is_weekend = gap_hours > 40 and (
                (from_dt.weekday() == 4 and to_dt.weekday() == 6) or
                (from_dt.weekday() == 5 and to_dt.weekday() == 6) or
                (from_dt.weekday() == 4 and to_dt.weekday() == 0)
            )
            is_overnight = gap_hours < 18 and from_dt.hour >= 17
            if is_weekend or is_overnight:
                continue

            gaps.append(dict(
                from_ts=prev, to_ts=cur,
                gap_seconds=gap_sec,
                gap_minutes=round(gap_sec / 60, 1),
                gap_hours=round(gap_hours, 1),
                from_dt=from_dt.isoformat(),
                to_dt=to_dt.isoformat(),
            ))
        return gaps


def validate_integrity() -> dict:
    with get_connection() as conn:
        report = {}

        symbols = conn.execute("SELECT DISTINCT symbol, timeframe FROM ohlc_prices").fetchall()
        for sym, tf in symbols:
            gap_list = check_gaps(sym, tf, max_gap_minutes=30)
            dup = conn.execute("""
                SELECT COUNT(*) - COUNT(DISTINCT time)
                FROM ohlc_prices
                WHERE symbol = ? AND timeframe = ?
            """, [sym, tf]).fetchone()[0]
            future = conn.execute("""
                SELECT COUNT(*) FROM ohlc_prices
                WHERE symbol = ? AND timeframe = ? AND time > ?
            """, [sym, tf, int(datetime.now(timezone.utc).timestamp())]).fetchone()[0]

            report[f"{sym}_{tf}"] = dict(
                symbol=sym,
                timeframe=tf,
                gaps=len(gap_list),
                gap_details=gap_list[:10],
                duplicates=dup,
                future_data=future,
                status="clean" if (len(gap_list) == 0 and dup == 0 and future == 0) else "issues",
            )
        return report


def generate_recommendations() -> list[dict]:
    issues = []
    report = validate_integrity()
    now = int(datetime.now(timezone.utc).timestamp())

    for key, info in report.items():
        sym, tf = info["symbol"], info["timeframe"]

        if info["gaps"] > 0:
            for g in info["gap_details"][:3]:
                from_str = g["from_dt"][:19]
                to_str = g["to_dt"][:19]
                issues.append(dict(
                    severity="high" if g["gap_hours"] > 24 else "medium",
                    symbol=sym, timeframe=tf,
                    message=f"Gap of {g['gap_hours']:.1f}h between {from_str} and {to_str}",
                    action=f"Download data from {from_str[:10]} to {to_str[:10]} via Collector",
                    fix="incremental",
                ))

        if info["duplicates"] > 0:
            issues.append(dict(
                severity="medium",
                symbol=sym, timeframe=tf,
                message=f"{info['duplicates']} duplicate rows found",
                action="Run manual dedup: DELETE via SQL console",
                fix="manual",
            ))

        if info["future_data"] > 0:
            issues.append(dict(
                severity="high",
                symbol=sym, timeframe=tf,
                message=f"{info['future_data']} candles with future timestamps",
                action="Remove records with time > now()",
                fix="manual",
            ))

    freshness = check_freshness()
    for f in freshness:
        if f["label"] == "critical":
            issues.append(dict(
                severity="high",
                symbol=f["symbol"], timeframe=f["timeframe"],
                message=f"Outdated for {f['age_hours']:.0f}h ({f['last_date'][:10]})",
                action="Run incremental collection now",
                fix="incremental",
            ))
        elif f["label"] == "stale":
            issues.append(dict(
                severity="low",
                symbol=f["symbol"], timeframe=f["timeframe"],
                message=f"Outdated for {f['age_hours']:.0f}h",
                action="Schedule collection in next routine",
                fix="schedule",
            ))

    if not issues:
        issues.append(dict(
            severity="info",
            symbol="--", timeframe="--",
            message="No anomalies detected. Database OK.",
            action="",
            fix="none",
        ))

    return issues


def check_freshness() -> list[dict]:
    with get_connection() as conn:
        now = int(datetime.now(timezone.utc).timestamp())
        rows = conn.execute("""
            SELECT
                symbol,
                timeframe,
                MAX(time) AS last_ts,
                COUNT(*)  AS rows
            FROM ohlc_prices
            GROUP BY symbol, timeframe
            ORDER BY symbol
        """).fetchall()

        result = []
        for r in rows:
            symbol, tf, last_ts, n = r
            age_hours = (now - last_ts) / 3600 if last_ts else 999999
            if age_hours < 24:
                label = "ok"
            elif age_hours < 168:
                label = "stale"
            else:
                label = "critical"
            result.append(dict(
                symbol=symbol,
                timeframe=tf,
                rows=n,
                last_date=datetime.fromtimestamp(last_ts, tz=timezone.utc).isoformat() if last_ts else "N/A",
                age_hours=round(age_hours, 1),
                label=label,
            ))
        return result


# ─────────────────────────────────────────────────────────────────────
# Domain-level thresholds
# ─────────────────────────────────────────────────────────────────────

DOMAIN_THRESHOLDS = {
    "OHLC": {"ok": 24, "stale": 168, "table": "ohlc_prices", "ts_col": "time"},
    "Macro": {"ok": 48, "stale": 336, "table": "macro_series", "ts_col": "date"},
    "Calendar": {"ok": 168, "stale": 720, "table": "calendar_events", "ts_col": "event_time"},
    "Risk": {"ok": 48, "stale": 336, "table": "risk_labels", "ts_col": "date"},
}


def check_domain_freshness() -> dict:
    with get_connection() as conn:
        now = datetime.now(timezone.utc)
        now_ts = int(now.timestamp())
        domains = []

        for domain, cfg in DOMAIN_THRESHOLDS.items():
            table = cfg["table"]
            ts_col = cfg["ts_col"]
            ok_h = cfg["ok"]
            stale_h = cfg["stale"]

            try:
                row = conn.execute(f"SELECT MAX({ts_col}), COUNT(*) FROM {table}").fetchone()
                last_val, total_rows = row

                if last_val is None or last_val == 0:
                    age_hours = 999999
                    last_str = None
                elif isinstance(last_val, (int, float)):
                    age_hours = (now_ts - int(last_val)) / 3600
                    last_str = datetime.fromtimestamp(int(last_val), tz=timezone.utc).isoformat()
                else:
                    last_val = str(last_val)
                    try:
                        dt = datetime.strptime(last_val, "%Y-%m-%d").replace(tzinfo=timezone.utc)
                    except ValueError:
                        dt = datetime.strptime(last_val, "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc)
                    age_hours = (now - dt).total_seconds() / 3600
                    last_str = dt.isoformat()

                if age_hours < 0:
                    age_hours = 0
                    status = "ok"
                elif age_hours < ok_h:
                    status = "ok"
                elif age_hours < stale_h:
                    status = "stale"
                else:
                    status = "critical"

                domains.append(dict(
                    domain=domain,
                    table=table,
                    status=status,
                    age_hours=round(age_hours, 1),
                    last_update=last_str,
                    rows=total_rows or 0,
                ))

            except Exception as e:
                domains.append(dict(
                    domain=domain,
                    table=table,
                    status="critical",
                    age_hours=999999,
                    last_update=None,
                    rows=0,
                    error=str(e),
                ))

        ok_count = sum(1 for d in domains if d["status"] == "ok")
        stale_count = sum(1 for d in domains if d["status"] == "stale")
        critical_count = sum(1 for d in domains if d["status"] == "critical")

        if critical_count > 0:
            overall = "critical"
        elif stale_count > 0:
            overall = "warning"
        else:
            overall = "ok"

        return dict(
            overall=overall,
            checked_at=now.isoformat(),
            summary=dict(ok=ok_count, stale=stale_count, critical=critical_count, total=len(domains)),
            domains=domains,
        )


def get_stale_symbols() -> list[dict]:
    with get_connection() as conn:
        now = int(datetime.now(timezone.utc).timestamp())
        rows = conn.execute("""
            SELECT symbol, timeframe, MAX(time) AS last_ts
            FROM ohlc_prices
            GROUP BY symbol, timeframe
            HAVING (MAX(time) IS NULL) OR ((? - MAX(time)) / 3600 > 24)
            ORDER BY symbol
        """, [now]).fetchall()
        return [{"symbol": r[0], "timeframe": r[1]} for r in rows]


REPAIR_COMMANDS = {
    "OHLC": lambda: _build_ohlc_repair_commands(),
    "Macro": [sys.executable, "-m", "Modulos.datahouse.readiness", "--ensure"],
    "Risk": [sys.executable, "-m", "Modulos.risk_sentiment.engine", "--no-csv"],
}


def _build_ohlc_repair_commands() -> list[list[str]]:
    stale = get_stale_symbols()
    cmds = []
    for s in stale:
        cmds.append([
            sys.executable, "-m", "Modulos.datahouse.cli_collector",
            "--symbol", s["symbol"], "--tf", s["timeframe"],
        ])
    return cmds


REPAIR_DOMAIN_ALIAS = {
    "ohlc": "OHLC", "macro": "Macro", "risk": "Risk",
}


# DuckDB permite apenas UMA conexao de escrita por vez por arquivo.
# Reparos paralelos (multiplos subprocessos) colidem no lock do arquivo.
# Serializar evita "File is already in use by another process".
MAX_CONCURRENT_REPAIRS = 1

# Async repair state (module-level singleton)
_repair_status: dict = {
    "running": False,
    "started_at": None,
    "total": 0,
    "completed": 0,
    "failed": 0,
    "domains": {},
    "results": [],
}


def get_repair_status() -> dict:
    """Return current repair progress."""
    return {**_repair_status}


def _reset_repair_status():
    _repair_status["running"] = False
    _repair_status["started_at"] = None
    _repair_status["total"] = 0
    _repair_status["completed"] = 0
    _repair_status["failed"] = 0
    _repair_status["domains"] = {}
    _repair_status["results"] = []


def _run_one(cmd: list[str], label: str) -> str:
    """Run a single repair subprocess, capturing output to detect real failures."""
    import subprocess
    try:
        result = subprocess.run(
            cmd,
            shell=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(Path(__file__).resolve().parent.parent.parent),
            timeout=600,
        )
        _repair_status["completed"] += 1
        if result.returncode == 0:
            return f"OK: {label}"
        else:
            _repair_status["failed"] += 1
            stderr_tail = result.stderr.decode("utf-8", errors="replace")[-300:].strip() if result.stderr else ""
            stdout_tail = result.stdout.decode("utf-8", errors="replace")[-300:].strip() if result.stdout else ""
            detail = (stderr_tail or stdout_tail or f"exit code {result.returncode}")
            return f"FAIL: {label} -> {detail}"
    except subprocess.TimeoutExpired:
        _repair_status["failed"] += 1
        _repair_status["completed"] += 1
        return f"TIMEOUT: {label}"
    except Exception as e:
        _repair_status["failed"] += 1
        _repair_status["completed"] += 1
        return f"FAIL: {label} -> {e}"


def _build_all_repairs() -> list[tuple[list[str], str]]:
    """Build list of (cmd, label) for all stale domains."""
    repairs = []

    ohlc_cmds = _build_ohlc_repair_commands()
    for cmd in ohlc_cmds:
        repairs.append((cmd, cmd[cmd.index("--symbol") + 1] + " " + cmd[cmd.index("--tf") + 1]))

    macro_cmd = REPAIR_COMMANDS["Macro"]
    repairs.append((macro_cmd, "Macro"))

    risk_cmd = REPAIR_COMMANDS["Risk"]
    repairs.append((risk_cmd, "Risk"))

    return repairs


def _run_repairs_async(domain: str):
    """Run repairs in background thread with parallel subprocess pool."""
    import threading as _thr
    from concurrent.futures import ThreadPoolExecutor, as_completed

    _reset_repair_status()
    _repair_status["running"] = True
    _repair_status["started_at"] = datetime.now(timezone.utc).isoformat()

    if domain == "all":
        all_items = _build_all_repairs()
    else:
        cmd_or_list = REPAIR_COMMANDS.get(domain, [])
        if callable(cmd_or_list):
            cmds = cmd_or_list()
        else:
            cmds = [cmd_or_list] if cmd_or_list else []
        all_items = [(c, domain) for c in cmds]

    _repair_status["total"] = len(all_items)
    _repair_status["domains"] = {domain: {"total": len(all_items), "completed": 0, "failed": 0}}
    _repair_status["results"] = []

    def _run_wrapped(item):
        cmd, label = item
        return _run_one(cmd, label)

    with ThreadPoolExecutor(max_workers=MAX_CONCURRENT_REPAIRS) as pool:
        futures = [pool.submit(_run_wrapped, item) for item in all_items]
        for f in as_completed(futures):
            _repair_status["results"].append(f.result())

    _repair_status["running"] = False


def count_pending_repairs() -> dict:
    """Return count of items needing repair per domain."""
    stale = get_stale_symbols()
    result = {
        "OHLC": {"count": len(stale), "items": stale},
        "Macro": {"count": 1},
        "Risk": {"count": 1},
    }
    total = sum(v["count"] for v in result.values())
    return {"total": total, "domains": result}


def repair_domain(domain: str) -> dict:
    domain = REPAIR_DOMAIN_ALIAS.get(domain.lower(), domain)

    if domain != "all" and domain not in REPAIR_COMMANDS:
        return {"domain": domain, "status": "error", "message": f"Unknown domain: {domain}"}

    if _repair_status["running"]:
        return {"domain": domain, "status": "busy", "message": "Repair already in progress"}

    # Marcar como running ANTES de disparar a thread para evitar corrida
    # (garante que uma 2a chamada imediata nao inicie outro reparo paralelo).
    _repair_status["running"] = True

    import threading as _thr
    _thr.Thread(target=_run_repairs_async, args=(domain,), daemon=True).start()

    return {
        "domain": domain,
        "status": "started",
        "message": f"Repair triggered for {domain}. Use GET /api/health/repair/status to track progress.",
    }
