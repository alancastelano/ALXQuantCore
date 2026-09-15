"""
ALXQuant Alpha Miner — signal mining and feature discovery.
"""

__version__ = "10.0.0"

try:
    from Modulos._versioning import check_compat
    check_compat("python:alpha_miner", __version__)
except Exception as e:
    import sys
    print(f"[ALXQuant Versioning] {e}", file=sys.stderr)
    raise