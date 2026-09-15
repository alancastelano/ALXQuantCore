"""Autenticacao e validacao das requisicoes de telemetria do EA.

Fluxo:
    1. Header X-API-Key + body {account_id, timestamp, nonce, ...}
    2. Se a key for a Master Key -> auto-emite API Key por account_id
       (retorna a nova key para o EA cachear).
    3. Senao, valida a API Key individual do account_id.
    4. Valida timestamp (janela), nonce (anti-replay) e rate limit.

Nunca loga credenciais; apenas prefixos de account_id.
"""
import time
from collections import OrderedDict
from dataclasses import dataclass
from typing import Optional, Tuple

from . import keys_store
from .config import config

# LRU de nonces para anti-replay
_nonces: "OrderedDict[str, float]" = OrderedDict()
_nonce_lock_sz = 10_000


def _prune_nonces() -> None:
    now = time.time()
    while _nonces and next(iter(_nonces.values())) < now - config.nonce_ttl_sec:
        _nonces.popitem(last=False)


def _check_nonce(nonce: Optional[str]) -> bool:
    """True se nonce e valido (nao reaproveitado). Falso se invalido/replay."""
    if not nonce:
        return False
    _prune_nonces()
    if nonce in _nonces:
        return False
    _nonces[nonce] = time.time()
    if len(_nonces) > _nonce_lock_sz:
        # limpa metade para evitar crescimento descontrolado
        for _ in range(_nonce_lock_sz // 2):
            _nonces.popitem(last=False)
    return True


# Rate limiting simples por account_id (janela deslizante aproximada)
_rate_buckets: dict[str, Tuple[float, int]] = {}


def _check_rate_limit(account_id: str) -> bool:
    now = time.time()
    last, count = _rate_buckets.get(account_id, (0.0, 0))
    if now - last > 1.0:
        _rate_buckets[account_id] = (now, 1)
        return True
    if count >= max(1, int(config.rate_limit_per_sec * 10)):
        return False
    _rate_buckets[account_id] = (now, count + 1)
    return True


@dataclass
class AuthResult:
    ok: bool
    status_code: int
    message: str
    account_id: str = ""
    issued_key: Optional[str] = None  # preenchido quando master key auto-emite


def authenticate(api_key: Optional[str], account_id: Optional[str],
                 timestamp: Optional[float], nonce: Optional[str]) -> AuthResult:
    """Valida a requisicao. Retorna AuthResult (ok + nova key se auto-emitida)."""
    if not api_key:
        return AuthResult(False, 401, "missing api key")
    if not account_id:
        return AuthResult(False, 400, "missing account_id")
    if timestamp is None:
        return AuthResult(False, 400, "missing timestamp")

    # 1. Janela de tempo (anti-replay temporal)
    skew = abs(time.time() - float(timestamp))
    if skew > config.max_timestamp_skew_sec:
        return AuthResult(False, 401, "timestamp out of window")

    # 2. Rate limit
    if not _check_rate_limit(account_id):
        return AuthResult(False, 429, "rate limit exceeded")

    # 3. Master key -> auto-emissao
    if keys_store.is_master_key(api_key):
        if not _check_nonce(nonce):
            return AuthResult(False, 401, "nonce replay")
        issued = keys_store.issue_key(account_id)
        return AuthResult(True, 200, "auto-registered", account_id, issued)

    # 4. API Key individual
    if keys_store.validate_key(account_id, api_key):
        if not _check_nonce(nonce):
            return AuthResult(False, 401, "nonce replay")
        return AuthResult(True, 200, "ok", account_id)

    return AuthResult(False, 401, "invalid api key")