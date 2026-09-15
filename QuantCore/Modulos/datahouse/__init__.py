"""Módulo de DataHouse do ALXQuant - Camada central de coleta, validação e sync de dados.

Arquitetura:
    collector.py - Coleta MT5 (OHLC) + conexão DuckDB central
    validator.py - Validação completa de integridade + health checks
    scheduler.py - Windows Task Scheduler + jobs automatizados
    engine.py    - Status do banco e utilitários de domínio
    cli_collector.py - CLI para coleta incremental
"""

__version__ = "10.3.3"

try:
    from Modulos._versioning import check_compat
    check_compat("python:datahouse", __version__)
except Exception as e:
    import sys
    print(f"[ALXQuant Versioning] {e}", file=sys.stderr)
    raise

from .collector import (
    get_connection,
    get_last_timestamp,
    incremental_update,
    smart_update,
    full_update,
)
from .validator import (
    DataValidator,
    check_domain_freshness,
    count_pending_repairs,
    get_repair_status,
    repair_domain,
    get_stale_symbols,
)
from .engine import get_db_status, get_ohlc_pairs, get_all_symbols, get_all_timeframes
from .engine import ensure_universe_catalog, query_update_schedule, OHLC_ASSETS, FRESHNESS_BY_FREQUENCY
from .health import health_report
from .scheduler import (
    get_schedules,
    register_windows_tasks,
    unregister_windows_tasks,
    validate_all_tasks,
    update_last_run,
    install_bootstrap_task,
    uninstall_bootstrap_task,
    BOOTSTRAP_TASK,
)
from .ensure_tasks import ensure_tasks_installed

__all__ = [
    "get_connection",
    "get_last_timestamp",
    "incremental_update",
    "smart_update",
    "full_update",
    "DataValidator",
    "check_domain_freshness",
    "count_pending_repairs",
    "get_repair_status",
    "repair_domain",
    "get_stale_symbols",
    "get_db_status",
    "get_ohlc_pairs",
    "get_all_symbols",
    "get_all_timeframes",
    "ensure_universe_catalog",
    "query_update_schedule",
    "OHLC_ASSETS",
    "FRESHNESS_BY_FREQUENCY",
    "health_report",
    "get_schedules",
    "register_windows_tasks",
    "unregister_windows_tasks",
    "validate_all_tasks",
    "update_last_run",
    "install_bootstrap_task",
    "uninstall_bootstrap_task",
    "BOOTSTRAP_TASK",
    "ensure_tasks_installed",
]
