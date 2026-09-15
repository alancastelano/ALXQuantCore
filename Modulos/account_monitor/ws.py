"""Gerenciador de conexoes WebSocket e broadcast.

Quando uma conta/posicao muda, notificamos os clientes conectados.
Broadcast so em mudanca relevante (nao a cada tick), para nao sobrecarregar.
"""
import asyncio
from typing import Any, Optional

_connections: set = set()


async def register(websocket) -> None:
    _connections.add(websocket)


async def unregister(websocket) -> None:
    _connections.discard(websocket)


async def broadcast(event: str, payload: dict) -> None:
    if not _connections:
        return
    message = {"event": event, **payload}
    dead = []
    for ws in list(_connections):
        try:
            await ws.send_json(message)
        except Exception:
            dead.append(ws)
    for ws in dead:
        _connections.discard(ws)


def connection_count() -> int:
    return len(_connections)