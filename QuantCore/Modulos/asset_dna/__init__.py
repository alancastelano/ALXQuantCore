"""
Asset DNA Profiler — statistical profiling of financial assets.
"""

__version__ = "10.3.3"

try:
    from Modulos._versioning import check_compat
    check_compat("python:asset_dna", __version__)
except Exception as e:
    import sys
    print(f"[ALXQuant Versioning] {e}", file=sys.stderr)
    raise
