"""Autenticacao de usuarios GUI (login, sessoes, roles).

Diferente do auth.py (EA machine-to-machine), este modulo lida com
humanos logando na interface web.

Fluxo:
    1. Usuario envia username + password
    2. Servidor valida hash PBKDF2-HMAC-SHA256 contra banco
    3. Retorna token de sessao (hex 32 bytes, TTL configuravel)
    4. Todas as rotas GET exigem Authorization: Bearer <token>

Seguranca:
    - Senhas armazenadas como PBKDF2 (260.000 iteracoes, salt unico)
    - Tokens sao hex aleatorio (32 bytes = 256 bits de entropia)
    - Rate limit no login (5 tentativas por minuto por IP)
    - Sessoes expiram por inatividade (configavel) ou idade maxima
"""
import hashlib
import hmac
import os
import secrets
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from typing import Optional

from . import db
from .config import config

# --- Config de sessao -------------------------------------------------
SESSION_MAX_AGE_SEC = int(os.getenv("AM_SESSION_MAX_AGE_SEC", "86400"))       # 24h
SESSION_IDLE_TIMEOUT_SEC = int(os.getenv("AM_SESSION_IDLE_TIMEOUT_SEC", "1800"))  # 30min
LOGIN_RATE_LIMIT = 5    # tentativas por minuto por IP
LOGIN_RATE_WINDOW = 60  # segundos


# --- Password Hashing (PBKDF2-HMAC-SHA256) ---------------------------

def _hash_password(password: str, salt: Optional[bytes] = None) -> str:
    """Gera hash PBKDF2. Retorna 'pbkdf2:sha256:260000$salt$hash'."""
    if salt is None:
        salt = os.urandom(16)
    iterations = 260_000
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    salt_b64 = salt.hex()
    hash_b64 = dk.hex()
    return f"pbkdf2:sha256:{iterations}${salt_b64}${hash_b64}"


def _verify_password(password: str, stored_hash: str) -> bool:
    """Verifica password contra hash armazenado."""
    try:
        parts = stored_hash.split("$")
        if len(parts) != 3:
            return False
        header = parts[0]  # pbkdf2:sha256:260000
        salt = bytes.fromhex(parts[1])
        expected = parts[2]
        iterations = int(header.split(":")[2])
        dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
        return hmac.compare_digest(dk.hex(), expected)
    except Exception:
        return False


# --- Session Store (in-memory) -----------------------------------------

@dataclass
class Session:
    token: str
    user_id: int
    username: str
    role: str
    created_at: float
    last_access: float


_sessions: dict[str, Session] = {}
_login_attempts: "OrderedDict[str, list[float]]" = OrderedDict()


def _prune_sessions() -> None:
    """Remove sessoes expiradas."""
    now = time.time()
    expired = []
    for token, sess in _sessions.items():
        age = now - sess.created_at
        idle = now - sess.last_access
        max_age_exceeded = age > SESSION_MAX_AGE_SEC
        idle_exceeded = SESSION_IDLE_TIMEOUT_SEC > 0 and idle > SESSION_IDLE_TIMEOUT_SEC
        if max_age_exceeded or idle_exceeded:
            expired.append(token)
    for t in expired:
        del _sessions[t]


def _check_login_rate(ip: str) -> bool:
    """Rate limit: max LOGIN_RATE tentativas por LOGIN_RATE_WINDOW segundos."""
    now = time.time()
    attempts = _login_attempts.get(ip, [])
    # Remove tentativas antigas
    attempts = [t for t in attempts if now - t < LOGIN_RATE_WINDOW]
    _login_attempts[ip] = attempts
    if len(attempts) >= LOGIN_RATE_LIMIT:
        return False
    attempts.append(now)
    return True


# --- DB helpers -------------------------------------------------------

def _get_user_by_username(username: str) -> Optional[dict]:
    """Busca usuario por username. Retorna dict ou None."""
    conn = db.get_connection(read_only=True)
    try:
        row = conn.execute(
            "SELECT id, username, password_hash, role, active FROM users WHERE username=?",
            [username]
        ).fetchone()
        if not row:
            return None
        return {"id": row[0], "username": row[1], "password_hash": row[2],
                "role": row[3], "active": bool(row[4])}
    finally:
        conn.close()


def _update_last_login(user_id: int) -> None:
    conn = db.get_connection(read_only=False)
    try:
        conn.execute("UPDATE users SET last_login=CURRENT_TIMESTAMP WHERE id=?", [user_id])
        conn.commit()
    finally:
        conn.close()


def _create_user(username: str, password: str, role: str = "user") -> dict:
    """Cria usuario. Retorna dict com id/username/role ou erro."""
    conn = db.get_connection(read_only=False)
    try:
        existing = conn.execute("SELECT id FROM users WHERE username=?", [username]).fetchone()
        if existing:
            return {"error": "username already exists"}
        password_hash = _hash_password(password)
        conn.execute(
            "INSERT INTO users (id, username, password_hash, role) VALUES (nextval('users_id_seq'), ?, ?, ?)",
            [username, password_hash, role]
        )
        conn.commit()
        row = conn.execute("SELECT id, username, role FROM users WHERE username=?", [username]).fetchone()
        return {"id": row[0], "username": row[1], "role": row[2]}
    finally:
        conn.close()


def _list_users() -> list[dict]:
    conn = db.get_connection(read_only=True)
    try:
        rows = conn.execute(
            "SELECT id, username, role, created_at, last_login, active FROM users ORDER BY id"
        ).fetchall()
        return [{"id": r[0], "username": r[1], "role": r[2],
                 "created_at": str(r[3]) if r[3] else None,
                 "last_login": str(r[4]) if r[4] else None,
                 "active": bool(r[5])} for r in rows]
    finally:
        conn.close()


def _delete_user(user_id: int) -> bool:
    conn = db.get_connection(read_only=False)
    try:
        before = conn.execute("SELECT COUNT(*) FROM users WHERE id=?", [user_id]).fetchone()[0]
        conn.execute("DELETE FROM users WHERE id=?", [user_id])
        conn.commit()
        return before > 0
    finally:
        conn.close()


def _update_user_role(user_id: int, role: str) -> bool:
    if role not in ("admin", "user"):
        return False
    conn = db.get_connection(read_only=False)
    try:
        before = conn.execute("SELECT role FROM users WHERE id=?", [user_id]).fetchone()
        if not before:
            return False
        conn.execute("UPDATE users SET role=? WHERE id=?", [role, user_id])
        conn.commit()
        return True
    finally:
        conn.close()


def _reset_password(user_id: int, new_password: str) -> bool:
    password_hash = _hash_password(new_password)
    conn = db.get_connection(read_only=False)
    try:
        before = conn.execute("SELECT id FROM users WHERE id=?", [user_id]).fetchone()
        if not before:
            return False
        conn.execute("UPDATE users SET password_hash=? WHERE id=?", [password_hash, user_id])
        conn.commit()
        return True
    finally:
        conn.close()


# --- Admin initialization ---------------------------------------------

def ensure_admin_user() -> None:
    """Cria usuario admin padrao se a tabela estiver vazia."""
    conn = db.get_connection(read_only=False)
    try:
        count = conn.execute("SELECT COUNT(*) FROM users").fetchone()[0]
    finally:
        conn.close()
    if count == 0:
        default_password = os.getenv("AM_DEFAULT_ADMIN_PASSWORD", "admin123")
        _create_user("admin", default_password, "admin")
        print(f"[AUTH] Usuario 'admin' criado com senha padrao. ALTERE IMEDIATAMENTE!")


# --- Public API -------------------------------------------------------

def login(username: str, password: str, ip: str = "") -> dict:
    """Autentica usuario. Retorna {token, role, username} ou {error}."""
    if not _check_login_rate(ip):
        return {"error": "rate limit exceeded", "retry_after": LOGIN_RATE_WINDOW}

    user = _get_user_by_username(username)
    if not user or not user["active"]:
        return {"error": "invalid credentials"}

    if not _verify_password(password, user["password_hash"]):
        return {"error": "invalid credentials"}

    _update_last_login(user["id"])

    token = secrets.token_hex(32)
    now = time.time()
    _sessions[token] = Session(
        token=token,
        user_id=user["id"],
        username=user["username"],
        role=user["role"],
        created_at=now,
        last_access=now,
    )
    return {"token": token, "role": user["role"], "username": user["username"]}


def validate_session(token: Optional[str]) -> Optional[Session]:
    """Valida token de sessao. Retorna Session ou None se invalido/expirado."""
    if not token:
        return None
    _prune_sessions()
    sess = _sessions.get(token)
    if not sess:
        return None
    # Verifica idle timeout
    now = time.time()
    idle = now - sess.last_access
    if SESSION_IDLE_TIMEOUT_SEC > 0 and idle > SESSION_IDLE_TIMEOUT_SEC:
        del _sessions[token]
        return None
    # Atualiza last_access
    sess.last_access = now
    return sess


def logout(token: str) -> bool:
    """Remove sessao."""
    if token in _sessions:
        del _sessions[token]
        return True
    return False


def is_admin(token: Optional[str]) -> bool:
    """Verifica se token pertence a um admin."""
    sess = validate_session(token)
    return sess is not None and sess.role == "admin"


# --- User management (admin only) -------------------------------------

def create_user(username: str, password: str, role: str = "user") -> dict:
    return _create_user(username, password, role)


def list_users() -> list[dict]:
    return _list_users()


def delete_user(user_id: int) -> bool:
    return _delete_user(user_id)


def update_user_role(user_id: int, role: str) -> bool:
    return _update_user_role(user_id, role)


def reset_password(user_id: int, new_password: str) -> bool:
    return _reset_password(user_id, new_password)
