from __future__ import annotations

"""
ALXQuant NLP Sentiment Analysis — news-driven asset sentiment engine.

The implementation lives in ``nlp_sentiment.py``; this package init only
performs version compatibility checks and re-exports the public API so that
both ``from Modulos.nlp_sentiment import NLPSentimentEngine`` and
``from Modulos.nlp_sentiment.nlp_sentiment import NLPSentimentEngine`` work.
"""

__version__ = "10.0.0"

try:
    from Modulos._versioning import check_compat
    check_compat("python:nlp_sentiment", __version__)
except Exception as e:
    import sys
    print(f"[ALXQuant Versioning] {e}", file=sys.stderr)
    raise

from .nlp_sentiment import *  # noqa: F401,F403
from .nlp_sentiment import __all__  # noqa: F401
