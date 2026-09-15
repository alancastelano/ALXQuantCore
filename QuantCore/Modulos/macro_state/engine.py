"""CLI de diagnostico somente-leitura para o Global Macro Economic State.

O macro_state NAO coleta nem persiste dados: le o macro_series do datahouse
(read_only) e computa scores/regimes. A coleta e responsabilidade do datahouse
(Modulos/datahouse/engine._upsert_macro_economy_assets + readiness).

Uso:
    python -m Modulos.macro_state.engine        # computa e imprime (read_only)
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys

PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from Modulos.datahouse.collector import get_connection
from Modulos.macro_state import registry, economic_state

log = logging.getLogger("macro_state.engine")


def run() -> dict:
    conn = get_connection()
    try:
        snapshot = economic_state.get_state(conn)
    finally:
        conn.close()
    return snapshot


def _summary(snapshot: dict) -> dict:
    out = {}
    for e, st in snapshot["economies"].items():
        out[e] = {
            "regime": st["regime"],
            "score": st["score"],
            "dq": (st["data_quality"] or {}).get("status"),
        }
    out["GLOBAL"] = {
        "regime": snapshot["global"]["regime"],
        "score": snapshot["global"]["score"],
    }
    return out


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", help="optional log file path")
    args = ap.parse_args()
    if args.log:
        try:
            fh = logging.FileHandler(args.log, encoding="utf-8")
            fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
            logging.getLogger().addHandler(fh)
        except Exception:
            pass
    snap = run()
    print(json.dumps(_summary(snap), indent=2, default=str))


if __name__ == "__main__":
    main()
