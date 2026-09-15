"""Persistencia e gestao das API Keys por account_id.

Auto-registro "trust on first use":
    O EA envia a Master Key no primeiro contato. O servidor valida e
    emite uma API Key individual para aquele account_id (gravada aqui).
    Nos proximos heartbeats o EA usa a propria API Key.

As chaves sao armazenadas como SHA-256 (nunca em claro). Nunca armazenamos
senha de MT5, investor password ou trading password.
"""
import hashlib
import hmac
import json
import os
import threading
import time
import uuid
from typing import Optional

from .config import KEYS_PATH, config

_lock = threading.Lock()


def _hash(secret: str) -> str:
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


def _load() -> dict:
    if not os.path.exists(KEYS_PATH):
        return {}
    try:
        with open(KEYS_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def _save(data: dict) -> None:
    os.makedirs(os.path.dirname(KEYS_PATH), exist_ok=True)
    tmp = str(KEYS_PATH) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, KEYS_PATH)


def _secret_matches(secret: str, stored_hash: str) -> bool:
    return hmac.compare_digest(_hash(secret), stored_hash)


def is_master_key(secret: str) -> bool:
    """Compara a chave enviada com a Master Key configurada (tempo constante)."""
    if not config.master_key:
        return False
    return hmac.compare_digest(secret, config.master_key)


def issue_key(account_id: str) -> str:
    """Emite (ou rotaciona) uma API Key individual para o account_id. Retorna o texto plano."""
    key = "am_" + uuid.uuid4().hex
    with _lock:
        data = _load()
        data[account_id] = {
            "api_key_hash": _hash(key),
            "created": time.time(),
            "revoked": False,
        }
        _save(data)
    return key


def validate_key(account_id: str, secret: str) -> bool:
    """True se a key enviada corresponde ao account_id e nao esta revogada."""
    if not secret:
        return False
    with _lock:
        data = _load()
    rec = data.get(account_id)
    if not rec or rec.get("revoked"):
        return False
    return _secret_matches(secret, rec["api_key_hash"])


def revoke(account_id: str) -> bool:
    with _lock:
        data = _load()
        if account_id not in data:
            return False
        data[account_id]["revoked"] = True
        data[account_id]["revoked_at"] = time.time()
        _save(data)
        return True


def revoke_all() -> int:
    with _lock:
        data = _load()
        n = 0
        for rec in data.values():
            if not rec.get("revoked"):
                rec["revoked"] = True
                rec["revoked_at"] = time.time()
                n += 1
        _save(data)
        return n


def delete_key(account_id: str) -> bool:
    """Remove a key de um account_id completamente (nao apenas revoga)."""
    with _lock:
        data = _load()
        if account_id not in data:
            return False
        del data[account_id]
        _save(data)
        return True