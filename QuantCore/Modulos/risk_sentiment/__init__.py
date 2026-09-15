"""Pacote Modulos.risk_sentiment.

Engine de apetite de risco RORO: busca resiliente de fatores (FRED/Yahoo/HTTP),
PCA por categoria com refit anual, sinal oficial KCRORO e migração de view.
"""
from Modulos.risk_sentiment.engine import (
    main,
    classify_signal_strength,
    save_to_db,
    export_csv,
    send_alert,
    migrate,
    verify,
)

__all__ = [
    "main",
    "classify_signal_strength",
    "save_to_db",
    "export_csv",
    "send_alert",
    "migrate",
    "verify",
]
