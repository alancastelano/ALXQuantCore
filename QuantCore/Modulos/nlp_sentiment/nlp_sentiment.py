from __future__ import annotations

import asyncio
import hashlib
import json
import math
import os
import re
from pathlib import Path
from urllib.parse import urlparse
from abc import ABC, abstractmethod
from datetime import datetime, timedelta, timezone
from typing import Any, Sequence

import duckdb
import httpx
import numpy as np
import pandas as pd
from dotenv import load_dotenv
from loguru import logger
from pydantic import BaseModel, ConfigDict, Field

try:
    import google.generativeai as genai
except ImportError:  # pragma: no cover
    genai = None

try:
    import feedparser
except ImportError:  # pragma: no cover
    feedparser = None

try:
    import torch
except ImportError:  # pragma: no cover
    torch = None

try:
    from transformers import pipeline
except ImportError:  # pragma: no cover
    pipeline = None

try:
    from rapidfuzz import fuzz
except ImportError:  # pragma: no cover
    fuzz = None

try:
    from tenacity import retry, stop_after_attempt, wait_exponential
except ImportError:  # pragma: no cover
    retry = None

load_dotenv()

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
FINNHUB_API_KEY = os.getenv("FINNHUB_API_KEY")

DEFAULT_WATCHLIST = [
    {"symbol": "XAUUSD", "keywords": "gold,XAUUSD,XAU,precious metals,spot gold"},
    {"symbol": "EURUSD", "keywords": "EURUSD,euro,dollar,ECB,EUR,FX"},
    {"symbol": "GBPUSD", "keywords": "GBPUSD,pound,sterling,BOE,GBP,FX"},
    {"symbol": "USDJPY", "keywords": "USDJPY,yen,JPY,BOJ,FX"},
    {"symbol": "US30", "keywords": "US30,Dow Jones,Wall Street,SPX,indices"},
]

MACRO_ECONOMIES = [
    {"entity": "USD", "keywords": "dollar,usd,fed,fomc,powell,treasury,rates", "proxy_assets": ["EURUSD", "USDJPY", "XAUUSD", "US30"]},
    {"entity": "EUR", "keywords": "euro,eur,ecb,lagarde,eurozone", "proxy_assets": ["EURUSD"]},
    {"entity": "JPY", "keywords": "yen,jpy,boj,japan", "proxy_assets": ["USDJPY"]},
    {"entity": "CNY", "keywords": "yuan,china,chinese,pboc", "proxy_assets": []},
]


def load_macro_economies() -> list[dict[str, Any]]:
    raw = os.getenv("NLP_MACRO_ECONOMIES", "").strip()
    if raw:
        try:
            data = json.loads(raw)
            if isinstance(data, list) and data:
                return data
        except Exception as exc:
            logger.warning("Invalid NLP_MACRO_ECONOMIES JSON: {}", exc)
    return MACRO_ECONOMIES


def build_asset_keywords(watchlist_df: "pd.DataFrame | None") -> dict[str, list[str]]:
    kw: dict[str, list[str]] = {}
    if watchlist_df is not None and not watchlist_df.empty:
        for _, row in watchlist_df.iterrows():
            sym = str(row.get("symbol") or "").upper()
            k = row.get("keywords")
            if sym and isinstance(k, str) and k.strip():
                kw[sym] = [p.strip().lower() for p in k.split(",") if p.strip()]
    for e in load_macro_economies():
        ent = str(e.get("entity", "")).upper()
        if ent:
            kw[ent] = [p.strip().lower() for p in str(e.get("keywords", "")).split(",") if p.strip()]
    return kw

HALF_LIFE_MINUTES = 120

HTTP_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    )
}


def make_news_id(url: str, published: str) -> str:
    """Deterministic, restart-safe news id (hashlib instead of Python's salted hash())."""
    return hashlib.sha256(f"{url}:{published}".encode("utf-8")).hexdigest()[:32]


DEFAULT_RSS_FEEDS = [
    "https://www.investing.com/rss/news.rss",
    "https://feeds.a.dj.com/rss/RSSMarketsMain.xml",
    "https://www.cnbc.com/id/100003114/device/rss/rss.html",
    "https://seekingalpha.com/market_currents.xml",
    "https://www.federalreserve.gov/feeds/press_all.xml",
    "https://www.federalreserve.gov/feeds/press_monetary.xml",
    "https://www.federalreserve.gov/feeds/speeches.xml",
    "https://www.ecb.europa.eu/rss/press.xml",
    "https://www.bankofengland.co.uk/rss/news",
    "https://www.boj.or.jp/en/rss/whatsnew.xml",
]

SOURCE_CREDIBILITY = {
    "alphavantage": 0.85,
    "finnhub": 0.85,
    "federalreserve": 1.0,
    "ecb": 1.0,
    "bankofengland": 1.0,
    "boj": 1.0,
    "investing": 0.6,
    "cnbc": 0.85,
    "seekingalpha": 0.7,
    "wsj": 0.9,
    "dj": 0.9,
    "gdelt": 0.5,
    "rss": 0.6,
    "finbert": 0.7,
    "lexicon": 0.5,
    "gemini": 0.9,
    "macro": 0.8,
    "_default": 0.7,
}

ASSET_POLARITY = {
    "USD": {"XAUUSD": -1.0, "EURUSD": -1.0, "GBPUSD": -1.0, "USDJPY": 1.0, "US30": -0.4},
    "EUR": {"EURUSD": 1.0, "XAUUSD": -0.3},
    "JPY": {"USDJPY": -1.0},
    "CNY": {"US30": -0.3},
    "XAUUSD": {"USD": 0.3, "EUR": -0.2},
}


def _source_credibility(source: str | None) -> float:
    if not source:
        return float(SOURCE_CREDIBILITY["_default"])
    s = str(source).lower()
    for key, weight in SOURCE_CREDIBILITY.items():
        if key != "_default" and key in s:
            return float(weight)
    return float(SOURCE_CREDIBILITY["_default"])


def _propagate_polarity(impacts: list[AssetImpact]) -> list[AssetImpact]:
    """Add causally-inverted impacts when text signals strength/weakness of a base currency."""
    base_assets = {imp.asset for imp in impacts}
    extra: list[AssetImpact] = []
    for imp in impacts:
        for related, mult in ASSET_POLARITY.get(imp.asset, {}).items():
            if related in base_assets:
                continue
            s = max(-1.0, min(1.0, imp.sentiment * mult))
            extra.append(
                AssetImpact(
                    asset=related,
                    sentiment=s,
                    relevance=float(min(1.0, imp.relevance * 0.8)),
                    direction="bullish" if s > 0 else "bearish" if s < 0 else "neutral",
                    reasoning=f"Polarity propagated from {imp.asset}",
                )
            )
    return impacts + extra


_CLASSIFIER_RANK = {"gemini": 5, "groq": 4, "finbert": 3, "macro": 2, "lexicon": 1}


def dedup_impacts_by_asset(impacts: list[Any]) -> list[Any]:
    """Keep at most one impact per asset, preferring higher relevance and (tie) stronger classifier.

    Prevents the same news from double-counting an asset when two classifiers
    (e.g. Lexicon/FinBERT and MacroClassifier) independently tag the same entity.
    """
    def _asset(imp):
        return str(getattr(imp, "asset", None) or (imp.get("asset") if isinstance(imp, dict) else "")).upper()

    def _rel(imp):
        try:
            v = getattr(imp, "relevance", None)
            if v is None and isinstance(imp, dict):
                v = imp.get("relevance")
            return float(v or 0.0)
        except Exception:
            return 0.0

    def _cls(imp):
        c = getattr(imp, "classifier_used", None)
        if c is None and isinstance(imp, dict):
            c = imp.get("classifier_used")
        return _CLASSIFIER_RANK.get(str(c or "lexicon"), 1)

    best: dict[str, Any] = {}
    for imp in impacts:
        asset = _asset(imp)
        if not asset:
            continue
        prev = best.get(asset)
        if prev is None:
            best[asset] = imp
            continue
        cur = (_rel(imp), _cls(imp))
        old = (_rel(prev), _cls(prev))
        if cur > old:
            best[asset] = imp
    return list(best.values())


def _stem_token(tok: str) -> str:
    """Cheap English suffix stemmer (no external dependency)."""
    tok = str(tok).lower()
    if len(tok) <= 3:
        return tok
    for suf in ("ies", "es", "ed", "ing", "ly", "s"):
        if tok.endswith(suf) and len(tok) - len(suf) >= 2:
            return tok[: -len(suf)]
    return tok



if retry is not None:
    @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1.0, min=1.0, max=5.0), reraise=True)
    async def _http_get(url: str, timeout: float, params: dict | None = None, headers: dict | None = None) -> httpx.Response:
        merged = dict(HTTP_HEADERS)
        if headers:
            merged.update(headers)
        async with httpx.AsyncClient(timeout=timeout, headers=merged, follow_redirects=True) as client:
            resp = await client.get(url, params=params)
            resp.raise_for_status()
            return resp
else:
    async def _http_get(url: str, timeout: float, params: dict | None = None, headers: dict | None = None) -> httpx.Response:
        merged = dict(HTTP_HEADERS)
        if headers:
            merged.update(headers)
        async with httpx.AsyncClient(timeout=timeout, headers=merged, follow_redirects=True) as client:
            resp = await client.get(url, params=params)
            resp.raise_for_status()
            return resp


def _dedup_classified(classified_news: list[dict[str, Any]], threshold: int = 85, window_min: int = 30) -> list[dict[str, Any]]:
    """Drop near-duplicate news (same wire republished by multiple venues) before scoring."""
    if fuzz is None or not classified_news:
        return classified_news

    def _ts(news: dict[str, Any]):
        t = pd.to_datetime(news.get("published_at"), errors="coerce", utc=True)
        if pd.isna(t):
            return pd.Timestamp.min.tz_localize("UTC")
        return t.tz_localize("UTC") if t.tzinfo is None else t

    items = sorted(classified_news, key=_ts)
    kept: list[dict[str, Any]] = []
    for cand in items:
        ct = _ts(cand)
        ctitle = (cand.get("title") or "").lower().strip()
        is_dup = False
        for k in kept:
            if abs((_ts(k) - ct).total_seconds() / 60.0) > window_min:
                continue
            ktitle = (k.get("title") or "").lower().strip()
            if ctitle and ktitle and fuzz.ratio(ctitle, ktitle) >= threshold:
                is_dup = True
                break
        if not is_dup:
            kept.append(cand)
    removed = len(classified_news) - len(kept)
    if removed:
        logger.info("NLP dedup removeu {} noticia(s) duplicada(s)", removed)
    return kept


class AssetImpact(BaseModel):
    model_config = ConfigDict(extra="forbid")

    asset: str
    sentiment: float = Field(..., ge=-1.0, le=1.0)
    relevance: float = Field(..., ge=0.0, le=1.0)
    direction: str = Field(..., pattern="^(bullish|bearish|neutral)$")
    reasoning: str


class ClassifiedNews(BaseModel):
    model_config = ConfigDict(extra="forbid")

    news_id: str
    source: str
    title: str
    snippet: str
    url: str
    published_at: datetime
    impacts: list[AssetImpact]
    classifier_used: str


class AssetSignal(BaseModel):
    model_config = ConfigDict(extra="forbid")

    asset: str
    timestamp: datetime
    raw_score: float
    decayed_score: float
    z_score: float
    news_count: int
    confidence: float = Field(..., ge=0.0, le=1.0)


class DuckDBManager:
    """Thin wrapper around the project DuckDB warehouse."""

    def __init__(self, db_path_or_connection: str | duckdb.DuckDBPyConnection):
        if isinstance(db_path_or_connection, duckdb.DuckDBPyConnection):
            self.conn = db_path_or_connection
        elif isinstance(db_path_or_connection, str):
            self.conn = duckdb.connect(db_path_or_connection)
        else:
            raise TypeError("db_path_or_connection must be a DuckDB path or a DuckDB connection")

        self._ensure_schema()

    def _ensure_schema(self) -> None:
        self.conn.execute(
            """
            CREATE TABLE IF NOT EXISTS nlp_raw_news (
                news_id VARCHAR PRIMARY KEY,
                source VARCHAR,
                title VARCHAR,
                snippet VARCHAR,
                url VARCHAR,
                published_at TIMESTAMP,
                raw_payload JSON,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        self.conn.execute(
            """
            CREATE TABLE IF NOT EXISTS nlp_classified_news (
                news_id VARCHAR PRIMARY KEY,
                source VARCHAR,
                title VARCHAR,
                snippet VARCHAR,
                url VARCHAR,
                published_at TIMESTAMP,
                impacts JSON,
                classifier_used VARCHAR,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        self.conn.execute(
            """
            CREATE TABLE IF NOT EXISTS nlp_sentiment_signals (
                asset VARCHAR,
                timestamp TIMESTAMP,
                raw_score DOUBLE,
                decayed_score DOUBLE,
                z_score DOUBLE,
                news_count INTEGER,
                confidence DOUBLE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        self.conn.execute(
            """
            CREATE TABLE IF NOT EXISTS nlp_pipeline_runs (
                timestamp TIMESTAMP,
                duration_ms DOUBLE,
                collected_total INTEGER,
                per_source JSON,
                classified_total INTEGER,
                per_classifier JSON,
                macro_total INTEGER,
                errors JSON,
                degraded BOOLEAN,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        )

        self.conn.execute(
            """
            CREATE TABLE IF NOT EXISTS assets (
                symbol VARCHAR,
                keywords VARCHAR,
                name VARCHAR,
                active BOOLEAN DEFAULT TRUE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        self.conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_assets_symbol ON assets(symbol)"
        )

        self.conn.execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS idx_nlp_sentiment_signals_asset_ts
            ON nlp_sentiment_signals(asset, timestamp)
            """
        )

    def close(self) -> None:
        if self.conn is not None:
            try:
                self.conn.close()
            except Exception:
                pass
            self.conn = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def _ensure_default_watchlist(self) -> None:
        existing = self.conn.execute("SELECT symbol FROM assets").fetchall()
        if existing:
            return

        self.conn.executemany(
            "INSERT OR IGNORE INTO assets (symbol, keywords, name, active) VALUES (?, ?, ?, ?)",
            [
                (item["symbol"], item["keywords"], item["symbol"], True)
                for item in DEFAULT_WATCHLIST
            ],
        )

    def load_watchlist(self) -> pd.DataFrame:
        candidate_tables = ["assets", "watchlist", "asset_watchlist", "market_watchlist"]
        for table in candidate_tables:
            try:
                cols = self.conn.execute(f"DESCRIBE {table}").fetchdf()
                if not cols.empty:
                    df = self.conn.execute(f"SELECT * FROM {table}").df()
                    if {"symbol", "keywords"}.issubset(df.columns):
                        self._ensure_default_watchlist()
                        return df[["symbol", "keywords"]].dropna(subset=["symbol"]).reset_index(drop=True)
            except Exception:
                continue

        self._ensure_default_watchlist()
        try:
            df = self.conn.execute("SELECT symbol, keywords FROM assets").df()
        except Exception:
            df = pd.DataFrame(DEFAULT_WATCHLIST)
        if df.empty:
            df = pd.DataFrame(DEFAULT_WATCHLIST)
        return df[["symbol", "keywords"]].dropna(subset=["symbol"]).reset_index(drop=True)

    def save_raw_news(self, news_list: Sequence[dict[str, Any]]) -> None:
        if not news_list:
            return

        rows: list[dict[str, Any]] = []
        for item in news_list:
            payload = {
                "news_id": item.get("news_id"),
                "source": item.get("source"),
                "title": item.get("title"),
                "snippet": item.get("snippet"),
                "url": item.get("url"),
                "published_at": item.get("published_at"),
                "raw_payload": item,
            }
            rows.append(payload)

        df = pd.DataFrame(rows)
        if df.empty:
            return

        df["published_at"] = pd.to_datetime(df["published_at"], errors="coerce", utc=True)
        df["raw_payload"] = df["raw_payload"].apply(json.dumps)
        df = df.where(pd.notna(df), None)

        self.conn.executemany(
            """
            INSERT OR IGNORE INTO nlp_raw_news (news_id, source, title, snippet, url, published_at, raw_payload)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            list(df[["news_id", "source", "title", "snippet", "url", "published_at", "raw_payload"]].itertuples(index=False, name=None)),
        )

    def save_classified_news(self, news_list: Sequence[dict[str, Any]]) -> None:
        if not news_list:
            return

        rows: list[dict[str, Any]] = []
        for item in news_list:
            impacts = item.get("impacts", [])
            rows.append(
                {
                    "news_id": item.get("news_id"),
                    "source": item.get("source"),
                    "title": item.get("title"),
                    "snippet": item.get("snippet"),
                    "url": item.get("url"),
                    "published_at": item.get("published_at"),
                    "impacts": json.dumps([impact.model_dump() if hasattr(impact, "model_dump") else impact for impact in impacts]),
                    "classifier_used": item.get("classifier_used", "unknown"),
                }
            )

        df = pd.DataFrame(rows)
        if df.empty:
            return

        df["published_at"] = pd.to_datetime(df["published_at"], errors="coerce", utc=True)
        df = df.where(pd.notna(df), None)

        self.conn.executemany(
            """
            INSERT OR IGNORE INTO nlp_classified_news (news_id, source, title, snippet, url, published_at, impacts, classifier_used)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            list(df[["news_id", "source", "title", "snippet", "url", "published_at", "impacts", "classifier_used"]].itertuples(index=False, name=None)),
        )

    def save_signals(self, signals_dict: dict[str, Any]) -> None:
        if not signals_dict:
            return

        rows: list[dict[str, Any]] = []
        for asset, signal in signals_dict.items():
            if isinstance(signal, AssetSignal):
                signal_obj = signal
            else:
                signal_obj = AssetSignal(**signal)

            rows.append(
                {
                    "asset": asset,
                    "timestamp": signal_obj.timestamp,
                    "raw_score": float(signal_obj.raw_score),
                    "decayed_score": float(signal_obj.decayed_score),
                    "z_score": float(signal_obj.z_score),
                    "news_count": int(signal_obj.news_count),
                    "confidence": float(signal_obj.confidence),
                }
            )

        df = pd.DataFrame(rows)
        if df.empty:
            return

        df["timestamp"] = pd.to_datetime(df["timestamp"], errors="coerce", utc=True)
        df = df.where(pd.notna(df), None)

        self.conn.executemany(
            """
            INSERT OR IGNORE INTO nlp_sentiment_signals (asset, timestamp, raw_score, decayed_score, z_score, news_count, confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            list(df[["asset", "timestamp", "raw_score", "decayed_score", "z_score", "news_count", "confidence"]].itertuples(index=False, name=None)),
        )

    def save_pipeline_run(self, metrics: dict[str, Any]) -> None:
        try:
            self.conn.execute(
                """
                INSERT INTO nlp_pipeline_runs (
                    timestamp, duration_ms, collected_total, per_source, classified_total,
                    per_classifier, macro_total, errors, degraded
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    metrics.get("timestamp", datetime.now(timezone.utc)),
                    float(metrics.get("duration_ms", 0.0)),
                    int(metrics.get("collected_total", 0)),
                    json.dumps(metrics.get("per_source", {})),
                    int(metrics.get("classified_total", 0)),
                    json.dumps(metrics.get("per_classifier", {})),
                    int(metrics.get("macro_total", 0)),
                    json.dumps(metrics.get("errors", [])),
                    bool(metrics.get("degraded", False)),
                ],
            )
        except Exception as exc:
            logger.warning("Falha ao salvar metricas do pipeline NLP: {}", exc)

    def get_historical_scores(self, asset: str, days: int = 30) -> pd.DataFrame:
        start_ts = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")
        query = """
            SELECT *
            FROM nlp_sentiment_signals
            WHERE asset = ? AND timestamp >= ?
            ORDER BY timestamp DESC
        """
        return self.conn.execute(query, [asset, start_ts]).df()

    def get_macro_scores(self, entities: list[str], days: int = 30) -> dict[str, Any]:
        if not entities:
            return {}
        placeholders = ", ".join("?" for _ in entities)
        start_ts = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")
        query = f"""
            SELECT asset, decayed_score, raw_score, z_score, news_count, confidence, timestamp
            FROM nlp_sentiment_signals
            WHERE asset IN ({placeholders}) AND timestamp >= ?
            ORDER BY asset, timestamp DESC
        """
        df = self.conn.execute(query, list(entities) + [start_ts]).df()
        out: dict[str, Any] = {}
        for asset in entities:
            sub = df[df["asset"] == asset]
            if sub.empty:
                out[asset] = {
                    "entity": asset,
                    "raw_score": 0.0,
                    "decayed_score": 0.0,
                    "z_score": 0.0,
                    "news_count": 0,
                    "confidence": 0.0,
                    "timestamp": "",
                    "direction": "neutral",
                }
                continue
            row = sub.iloc[0]
            ds = float(row.get("decayed_score", 0.0) or 0.0)
            out[asset] = {
                "entity": asset,
                "raw_score": float(row.get("raw_score", 0.0) or 0.0),
                "decayed_score": ds,
                "z_score": float(row.get("z_score", 0.0) or 0.0),
                "news_count": int(row.get("news_count", 0) or 0),
                "confidence": float(row.get("confidence", 0.0) or 0.0),
                "timestamp": str(row.get("timestamp", "")),
                "direction": "bullish" if ds > 0.02 else "bearish" if ds < -0.02 else "neutral",
            }
        return out


class BaseCollector(ABC):
    """Base class for all news collectors."""

    def __init__(self, config: dict[str, Any] | None = None):
        self.config = config or {}

    @abstractmethod
    async def collect(self, watchlist_df: pd.DataFrame) -> list[dict[str, Any]]:
        raise NotImplementedError


class GDELTCollector(BaseCollector):
    """Free GDELT-based collector using keyword search over news articles."""

    def __init__(self, config: dict[str, Any] | None = None):
        super().__init__(config)
        self.base_url = "https://api.gdeltproject.org/api/v2/doc/doc"
        self.max_rows = int(self.config.get("max_rows", 25))
        self.timeout = float(self.config.get("timeout", 20.0))

    async def collect(self, watchlist_df: pd.DataFrame) -> list[dict[str, Any]]:
        if watchlist_df.empty:
            logger.warning("GDELT collector received empty watchlist; skipping")
            return []

        keywords: list[str] = []
        for _, row in watchlist_df.iterrows():
            k = row.get("keywords")
            if isinstance(k, str) and k.strip():
                keywords.extend([part.strip() for part in k.split(",") if part.strip()])

        if not keywords:
            return []

        query = " OR ".join(f'"{kw}"' for kw in list(dict.fromkeys(keywords))[:8])
        params = {
            "query": query,
            "mode": "artlist",
            "maxrecords": str(self.max_rows),
            "format": "json",
        }

        try:
            response = await _http_get(self.base_url, self.timeout, params=params)
            payload = response.json()
        except Exception as exc:
            logger.warning("GDELT fetch failed: {}", exc)
            return []

        articles: list[dict[str, Any]] = []
        raw_articles = payload.get("articles", []) if isinstance(payload, dict) else []
        for obj in raw_articles[: self.max_rows]:
            title = obj.get("title") or ""
            url = obj.get("url") or ""
            snippet = obj.get("snippet") or title
            published = obj.get("pubDate") or datetime.now(timezone.utc).isoformat()
            if not url:
                continue

            news_id = make_news_id(url, published)
            articles.append(
                {
                    "news_id": news_id,
                    "source": "gdelt",
                    "title": title,
                    "snippet": snippet,
                    "url": url,
                    "published_at": published,
                    "raw_payload": obj,
                }
            )

        return articles


class FinnhubCollector(BaseCollector):
    """Collector that integrates with Finnhub news API."""

    def __init__(self, config: dict[str, Any] | None = None):
        super().__init__(config)
        self.api_key = os.getenv("FINNHUB_API_KEY", self.config.get("api_key"))
        self.base_url = "https://finnhub.io/api/v1/news"
        self.max_rows = int(self.config.get("max_rows", 20))
        self.timeout = float(self.config.get("timeout", 20.0))

    async def collect(self, watchlist_df: pd.DataFrame) -> list[dict[str, Any]]:
        if not self.api_key:
            logger.info("FINNHUB_API_KEY not set; skipping Finnhub collector")
            return []

        keywords: list[str] = []
        for _, row in watchlist_df.iterrows():
            k = row.get("keywords")
            if isinstance(k, str):
                keywords.extend([part.strip().lower() for part in k.split(",") if part.strip()])

        try:
            params = {"category": "general", "token": self.api_key}
            response = await _http_get(self.base_url, self.timeout, params=params)
            payload = response.json()
        except Exception as exc:
            logger.warning("Finnhub fetch failed: {}", exc)
            return []

        if not isinstance(payload, list):
            return []

        articles: list[dict[str, Any]] = []
        for item in payload[: self.max_rows]:
            url = item.get("url") or ""
            headline = item.get("headline") or item.get("title") or ""
            summary = item.get("summary") or headline
            published = item.get("datetime")
            if isinstance(published, (int, float)):
                published_dt = datetime.fromtimestamp(published, tz=timezone.utc).isoformat()
            else:
                published_dt = datetime.now(timezone.utc).isoformat()

            if not url:
                continue
            if keywords and not any(kw.lower() in headline.lower() for kw in keywords):
                continue

            news_id = make_news_id(url, published_dt)
            articles.append(
                {
                    "news_id": news_id,
                    "source": "finnhub",
                    "title": headline,
                    "snippet": summary,
                    "url": url,
                    "published_at": published_dt,
                    "raw_payload": item,
                }
            )

        return articles


class RSSCollector(BaseCollector):
    """RSS/news feed parser for financial sources."""

    def __init__(self, config: dict[str, Any] | None = None):
        super().__init__(config)
        default_feeds = list(DEFAULT_RSS_FEEDS)
        env_feeds = os.getenv("NLP_RSS_FEEDS", "").strip()
        if env_feeds:
            default_feeds = [u.strip() for u in env_feeds.split(",") if u.strip()]
        self.feed_urls = list(self.config.get("feed_urls", default_feeds))
        self.timeout = float(self.config.get("timeout", 20.0))

    async def collect(self, watchlist_df: pd.DataFrame) -> list[dict[str, Any]]:
        if feedparser is None:
            logger.warning("feedparser is not installed; RSS collector skipped")
            return []

        if not self.feed_urls:
            return []

        async def _fetch_feed(url: str) -> list[dict[str, Any]]:
            try:
                response = await _http_get(url, self.timeout)
                feed = feedparser.parse(response.text)
            except Exception as exc:
                logger.warning("RSS feed failure for {}: {}", url, exc)
                return []

            items: list[dict[str, Any]] = []
            domain = urlparse(url).netloc.lower().replace("www.", "")
            for entry in feed.entries[:10]:
                title = getattr(entry, "title", "") or ""
                url_value = getattr(entry, "link", "") or ""
                summary = getattr(entry, "summary", "") or title
                published = getattr(entry, "published", None) or datetime.now(timezone.utc).isoformat()
                if not url_value:
                    continue
                items.append(
                    {
                        "news_id": make_news_id(url_value, published),
                        "source": domain,
                        "title": title,
                        "snippet": summary,
                        "url": url_value,
                        "published_at": published,
                        "raw_payload": entry,
                    }
                )
            return items

        tasks = [_fetch_feed(url) for url in self.feed_urls]
        results = await asyncio.gather(*tasks, return_exceptions=False)
        merged: list[dict[str, Any]] = []
        for batch in results:
            if isinstance(batch, list):
                merged.extend(batch)
        return merged


class CollectorOrchestrator:
    """Runs all collectors in parallel and merges their results."""

    def __init__(self, collectors: Sequence[BaseCollector] | None = None):
        self.collectors = list(collectors or [])

    async def collect_all(self, watchlist_df: pd.DataFrame) -> list[dict[str, Any]]:
        if not self.collectors:
            return []

        results = await asyncio.gather(
            *(collector.collect(watchlist_df) for collector in self.collectors),
            return_exceptions=True,
        )

        merged: list[dict[str, Any]] = []
        for item in results:
            if isinstance(item, list):
                merged.extend(item)
            elif isinstance(item, Exception):
                logger.warning("Collector exception: {}", item)
        return merged


class BaseClassifier(ABC):
    """Base classifier contract."""

    @abstractmethod
    def classify(self, news_list: list[dict[str, Any]], watchlist_df: pd.DataFrame | None = None) -> list[dict[str, Any]]:
        raise NotImplementedError


class GeminiClassifier(BaseClassifier):
    """Gemini-based classifier using strict JSON output."""

    def __init__(self, api_key: str | None = None):
        self.api_key = api_key or GEMINI_API_KEY
        self.model = None

    def _ensure_model(self) -> None:
        if genai is None:
            raise RuntimeError("google-generativeai is not installed")
        if not self.api_key:
            raise RuntimeError("GEMINI_API_KEY is not configured")
        if self.model is None:
            genai.configure(api_key=self.api_key)
            self.model = genai.GenerativeModel("gemini-2.5-flash-lite")

    def _gemini_generate(self, prompt: str):
        if retry is not None:
            @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1.0, min=1.0, max=5.0), reraise=True)
            def _call():
                return self.model.generate_content(prompt)
            return _call()
        return self.model.generate_content(prompt)

    def _classify_one(self, news: dict[str, Any], watchlist_df: pd.DataFrame | None = None) -> dict[str, Any] | None:
        title = str(news.get("title") or "").strip()
        snippet = str(news.get("snippet") or "").strip()
        text = "\n".join(part for part in [title, snippet] if part)
        if not text:
            return None

        prompt = """
        You are a strict financial-news sentiment classifier.
        Return only one valid JSON object, no markdown, no code fences.
        Format:
        {
          "impacts": [
            {"asset": "XAUUSD", "sentiment": -1.0, "relevance": 0.8, "direction": "bearish", "reasoning": "Short reason"}
          ]
        }
        Rules:
        - asset must be a trading symbol (XAUUSD, EURUSD, GBPUSD, USDJPY, US30) OR a macro economy (USD, EUR, JPY, CNY)
        - infer CAUSAL direction per asset: e.g. rate hikes / USD strength are bearish for XAUUSD and EURUSD, bullish for USDJPY
        - sentiment is a float between -1 and 1
        - relevance is a float between 0 and 1
        - direction must be bullish, bearish or neutral
        - only include relevant assets
        News:
        """ + text

        try:
            response = self._gemini_generate(prompt)
            payload_text = getattr(response, "text", "") or ""
            match = re.search(r"\{.*\}", payload_text, re.DOTALL)
            if not match:
                return None
            payload = json.loads(match.group(0))
        except Exception as exc:
            logger.warning("Gemini classification failed: {}", exc)
            return None

        impacts = payload.get("impacts", [])
        if not isinstance(impacts, list):
            return None

        validated: list[AssetImpact] = []
        for impact in impacts:
            try:
                validated.append(AssetImpact(**impact))
            except Exception as exc:
                logger.warning("Rejected impact payload: {} | {}", impact, exc)
                continue

        if not validated:
            return None

        return {
            "news_id": news.get("news_id"),
            "source": news.get("source"),
            "title": news.get("title"),
            "snippet": news.get("snippet"),
            "url": news.get("url"),
            "published_at": news.get("published_at"),
            "impacts": validated,
            "classifier_used": "gemini",
        }

    def classify(self, news_list: list[dict[str, Any]], watchlist_df: pd.DataFrame | None = None) -> list[dict[str, Any]]:
        if not news_list:
            return []
        self._ensure_model()
        results: list[dict[str, Any]] = []
        for news in news_list:
            r = self._classify_one(news, watchlist_df)
            if r:
                results.append(r)
        return results

    async def classify_async(self, news_list: list[dict[str, Any]], watchlist_df: pd.DataFrame | None = None) -> list[dict[str, Any]]:
        if not news_list:
            return []
        self._ensure_model()
        sem = asyncio.Semaphore(5)

        async def _one(news: dict[str, Any]):
            async with sem:
                return await asyncio.to_thread(self._classify_one, news, watchlist_df)

        return [r for r in await asyncio.gather(*[_one(n) for n in news_list]) if r]


class GroqClassifier(BaseClassifier):
    """Groq-based classifier using llama-3.3-70b-versatile as Gemini fallback."""

    def __init__(self, api_key: str | None = None, model: str = "openai/gpt-oss-120b"):
        self.api_key = api_key or os.getenv("LLM_API_KEY") or os.getenv("GROQ_API_KEY")
        self.model = model
        self._client = None

    def _ensure_client(self):
        if self._client is not None:
            return
        if not self.api_key:
            raise RuntimeError("LLM_API_KEY/GROQ_API_KEY not configured")
        try:
            from groq import Groq
        except ImportError:
            raise RuntimeError("groq package not installed: pip install groq")
        self._client = Groq(api_key=self.api_key)

    def _classify_one(self, news: dict[str, Any], watchlist_df=None) -> dict[str, Any] | None:
        title = str(news.get("title") or "").strip()
        snippet = str(news.get("snippet") or "").strip()
        text = "\n".join(part for part in [title, snippet] if part)
        if not text:
            return None

        prompt = (
            "You are a strict financial-news sentiment classifier.\n"
            "Return only one valid JSON object, no markdown, no code fences.\n"
            "Format:\n"
            '{"impacts": [{"asset": "XAUUSD", "sentiment": -1.0, "relevance": 0.8, '
            '"direction": "bearish", "reasoning": "Short reason"}]}\n'
            "Rules:\n"
            "- asset must be a trading symbol (XAUUSD, EURUSD, GBPUSD, USDJPY, US30) OR a macro economy (USD, EUR, JPY, CNY)\n"
            "- infer CAUSAL direction per asset\n"
            "- sentiment is a float between -1 and 1\n"
            "- relevance is a float between 0 and 1\n"
            "- direction must be bullish, bearish or neutral\n"
            "- only include relevant assets\n"
            "News:\n" + text
        )

        try:
            response = self._client.chat.completions.create(
                model=self.model,
                messages=[{"role": "user", "content": prompt}],
                temperature=0.1,
                max_tokens=512,
            )
            payload_text = response.choices[0].message.content or ""
            match = re.search(r"\{.*\}", payload_text, re.DOTALL)
            if not match:
                return None
            payload = json.loads(match.group(0))
        except Exception as exc:
            logger.warning("Groq classification failed: {}", exc)
            return None

        impacts = payload.get("impacts", [])
        if not isinstance(impacts, list):
            return None

        validated: list[AssetImpact] = []
        for impact in impacts:
            try:
                validated.append(AssetImpact(**impact))
            except Exception:
                continue

        if not validated:
            return None

        return {
            "news_id": news.get("news_id"),
            "source": news.get("source"),
            "title": news.get("title"),
            "snippet": news.get("snippet"),
            "url": news.get("url"),
            "published_at": news.get("published_at"),
            "impacts": validated,
            "classifier_used": "groq",
        }

    def classify(self, news_list: list[dict[str, Any]], watchlist_df=None) -> list[dict[str, Any]]:
        if not news_list:
            return []
        self._ensure_client()
        results = []
        for news in news_list:
            r = self._classify_one(news, watchlist_df)
            if r:
                results.append(r)
        return results

    async def classify_async(self, news_list: list[dict[str, Any]], watchlist_df=None) -> list[dict[str, Any]]:
        if not news_list:
            return []
        self._ensure_client()
        sem = asyncio.Semaphore(5)

        async def _one(news):
            async with sem:
                return await asyncio.to_thread(self._classify_one, news, watchlist_df)

        return [r for r in await asyncio.gather(*[_one(n) for n in news_list]) if r]


class FinBERTClassifier(BaseClassifier):
    """Lazy-loaded FinBERT sentiment classifier."""

    def __init__(self, model_name: str = "ProsusAI/finbert"):
        self.model_name = model_name
        self._pipe = None
        self.asset_keywords = {
            "XAUUSD": ["gold", "precious metals", "xau", "bullion", "spot gold"],
            "EURUSD": ["euro", "eur", "ecb", "eurozone", "currency"],
            "GBPUSD": ["pound", "sterling", "gbp", "boe", "uk"],
            "USDJPY": ["yen", "jpy", "boj", "japan", "currency"],
            "US30": ["dow", "wall street", "us30", "stocks", "index"],
        }

    def _ensure_model(self) -> None:
        if self._pipe is None:
            self._pipe = pipeline("sentiment-analysis", model=self.model_name)

    def classify(self, news_list: list[dict[str, Any]], watchlist_df: pd.DataFrame | None = None) -> list[dict[str, Any]]:
        if not news_list:
            return []

        try:
            self._ensure_model()
        except Exception as exc:
            logger.warning("FinBERT unavailable: {}", exc)
            raise RuntimeError("FinBERT unavailable") from exc

        asset_keywords = build_asset_keywords(watchlist_df) or self.asset_keywords

        results: list[dict[str, Any]] = []
        for news in news_list:
            title = str(news.get("title") or "").strip()
            snippet = str(news.get("snippet") or "").strip()
            text = "\n".join(part for part in [title, snippet] if part)
            if not text:
                continue

            impacts: list[AssetImpact] = []
            for asset, keywords in asset_keywords.items():
                lowered_text = text.lower()
                if not any(keyword.lower() in lowered_text for keyword in keywords):
                    continue
                try:
                    scored = self._pipe(text)
                except Exception as exc:
                    logger.warning("FinBERT inference failed for {}: {}", asset, exc)
                    continue

                label = str((scored[0] if isinstance(scored, list) else scored).get("label", "neutral")).lower()
                score = float((scored[0] if isinstance(scored, list) else scored).get("score", 0.0))
                if "positive" in label:
                    sentiment = score
                elif "negative" in label:
                    sentiment = -score
                else:
                    sentiment = 0.0

                impacts.append(
                    AssetImpact(
                        asset=asset,
                        sentiment=float(max(-1.0, min(1.0, sentiment))),
                        relevance=float(min(1.0, 0.35 + 0.15 * len(keywords))),
                        direction="bullish" if sentiment > 0.0 else "bearish" if sentiment < 0.0 else "neutral",
                        reasoning=f"FinBERT score triggered by keyword match for {asset}",
                    )
                )

            if not impacts:
                continue

            results.append(
                {
                    "news_id": news.get("news_id"),
                    "source": news.get("source"),
                    "title": news.get("title"),
                    "snippet": news.get("snippet"),
                    "url": news.get("url"),
                    "published_at": news.get("published_at"),
                    "impacts": _propagate_polarity(impacts),
                    "classifier_used": "finbert",
                }
            )

        return results


class LexiconClassifier(BaseClassifier):
    """Simple English lexicon fallback."""

    def __init__(self):
        self.positive_words = {
            "gain", "growth", "increase", "surge", "rally", "boost", "strong", "upbeat", "rise", "higher", "profit",
            "support", "bullish", "positive", "expansion"
        }
        self.negative_words = {
            "drop", "decline", "loss", "weak", "slump", "risk", "fall", "pressure", "bearish", "negative", "downturn",
            "cut", "selloff", "recession", "lower", "concern"
        }
        self._pos_stem = {_stem_token(w) for w in self.positive_words}
        self._neg_stem = {_stem_token(w) for w in self.negative_words}

    def classify(self, news_list: list[dict[str, Any]], watchlist_df: pd.DataFrame | None = None) -> list[dict[str, Any]]:
        if not news_list:
            return []

        asset_keywords = build_asset_keywords(watchlist_df)
        results: list[dict[str, Any]] = []
        for news in news_list:
            text = " ".join(filter(None, [str(news.get("title") or ""), str(news.get("snippet") or "")])).lower()
            if not text:
                continue

            tokens = {_stem_token(t) for t in re.findall(r"[a-z]+", text)}
            pos = sum(1 for token in tokens if token in self._pos_stem)
            neg = sum(1 for token in tokens if token in self._neg_stem)
            if pos == neg == 0:
                continue
            sentiment = (pos - neg) / max(1, pos + neg)
            if abs(sentiment) < 0.05:
                continue

            matched = [asset for asset, kws in asset_keywords.items() if any(kw in text for kw in kws)]
            if not matched:
                continue

            impacts = [
                AssetImpact(
                    asset=asset,
                    sentiment=float(max(-1.0, min(1.0, sentiment))),
                    relevance=float(min(1.0, 0.4 + 0.1 * max(pos, neg))),
                    direction="bullish" if sentiment > 0 else "bearish" if sentiment < 0 else "neutral",
                    reasoning="Lexicon-based fallback scoring from positive and negative financial terms",
                )
                for asset in matched
            ]
            results.append(
                {
                    "news_id": news.get("news_id"),
                    "source": news.get("source"),
                    "title": news.get("title"),
                    "snippet": news.get("snippet"),
                    "url": news.get("url"),
                    "published_at": news.get("published_at"),
                    "impacts": _propagate_polarity(impacts),
                    "classifier_used": "lexicon",
                }
            )
        return results


class MacroClassifier(BaseClassifier):
    """Hawkish/dovish classifier for macro economies (Fed/ECB/BOJ/PBOC news)."""

    MACRO_ANCHORS = {
        "USD": ["fed", "fomc", "powell", "federal reserve", "dollar", "usd", "treasury", "rates"],
        "EUR": ["ecb", "lagarde", "euro", "eurozone", "emea"],
        "JPY": ["boj", "japan", "yen", "jpy"],
        "CNY": ["pboc", "china", "chinese", "yuan", "cnh"],
    }
    MACRO_TONE = {
        "USD": {"hawk": ["hike", "hikes", "hawkish", "tighten", "tightening", "rate increase"], "dove": ["cut", "cuts", "easing", "dovish", "stimulus", "accommodative", "rate cut"]},
        "EUR": {"hawk": ["hike", "hikes", "hawkish", "tighten", "tightening", "rate increase"], "dove": ["ease", "easing", "cut", "cuts", "stimulus", "dovish"]},
        "JPY": {"hawk": ["normalize", "normalization", "tighten", "hike", "hawkish"], "dove": ["ease", "easing", "stimulus", "dovish", "yield curve control"]},
        "CNY": {"hawk": ["tighten", "hike", "hawkish"], "dove": ["ease", "easing", "stimulus", "cut", "cuts", "dovish"]},
    }

    def classify(self, news_list: list[dict[str, Any]], watchlist_df: pd.DataFrame | None = None) -> list[dict[str, Any]]:
        if not news_list:
            return []
        entities = [e["entity"].upper() for e in load_macro_economies()]
        results: list[dict[str, Any]] = []
        for news in news_list:
            text = " ".join(filter(None, [str(news.get("title") or ""), str(news.get("snippet") or "")])).lower()
            if not text:
                continue
            impacts: list[AssetImpact] = []
            for ent in entities:
                anchors = self.MACRO_ANCHORS.get(ent, [])
                if not any(a in text for a in anchors):
                    continue
                tone = self.MACRO_TONE.get(ent, {"hawk": [], "dove": []})
                hawk = sum(1 for k in tone["hawk"] if k in text)
                dove = sum(1 for k in tone["dove"] if k in text)
                if hawk == dove == 0:
                    continue
                sentiment = (hawk - dove) / max(1, hawk + dove)
                if abs(sentiment) < 0.05:
                    continue
                impacts.append(
                    AssetImpact(
                        asset=ent,
                        sentiment=float(max(-1.0, min(1.0, sentiment))),
                        relevance=float(min(1.0, 0.5 + 0.1 * max(hawk, dove))),
                        direction="bullish" if sentiment > 0 else "bearish",
                        reasoning="Macro hawkish/dovish tone classifier (central-bank news)",
                    )
                )
            if not impacts:
                continue
            results.append(
                {
                    "news_id": news.get("news_id"),
                    "source": news.get("source"),
                    "title": news.get("title"),
                    "snippet": news.get("snippet"),
                    "url": news.get("url"),
                    "published_at": news.get("published_at"),
                    "impacts": _propagate_polarity(impacts),
                    "classifier_used": "macro",
                }
            )
        return results


def _parse_av_time(tp: str) -> str:
    try:
        return datetime.strptime(tp, "%Y%m%dT%H%M%S").replace(tzinfo=timezone.utc).isoformat()
    except Exception:
        return ""


class AlphaVantageCollector(BaseCollector):
    """Alpha Vantage NEWS_SENTIMENT collector (pre-classified per ticker)."""

    TICKER_ALIASES = {"XAU": "XAUUSD", "XAG": "XAGUSD", "BTC": "BTCUSD", "ETH": "ETHUSD"}

    def __init__(self, config: dict[str, Any] | None = None):
        super().__init__(config)
        self.api_key = os.getenv("ALPHAVANTAGE_API_KEY", self.config.get("api_key"))
        self.base_url = "https://www.alphavantage.co/query"
        self.timeout = float(self.config.get("timeout", 20.0))
        self.max_rows = int(self.config.get("max_rows", 20))

    def _known_assets(self, watchlist_df: pd.DataFrame) -> set[str]:
        known: set[str] = set()
        if watchlist_df is not None and not watchlist_df.empty:
            for _, row in watchlist_df.iterrows():
                s = str(row.get("symbol") or "").upper()
                if s:
                    known.add(s)
        for e in load_macro_economies():
            ent = str(e.get("entity", "")).upper()
            if ent:
                known.add(ent)
        return known

    async def collect(self, watchlist_df: pd.DataFrame) -> list[dict[str, Any]]:
        if not self.api_key:
            logger.info("ALPHAVANTAGE_API_KEY not set; skipping Alpha Vantage collector")
            return []

        known = self._known_assets(watchlist_df)
        tickers = ",".join(list(known)[:20])
        params = {
            "function": "NEWS_SENTIMENT",
            "tickers": tickers,
            "apikey": self.api_key,
            "limit": str(self.max_rows),
        }
        try:
            resp = await _http_get(self.base_url, self.timeout, params=params)
            payload = resp.json()
        except Exception as exc:
            logger.warning("Alpha Vantage fetch failed: {}", exc)
            return []

        if "feed" not in payload:
            for key in ("Error Message", "Note", "Information", "Warning Message"):
                if key in payload:
                    logger.warning("Alpha Vantage {}: {}", key, payload[key])
            return []

        articles: list[dict[str, Any]] = []
        for obj in payload.get("feed", [])[: self.max_rows]:
            url = obj.get("url") or ""
            if not url:
                continue
            title = obj.get("title") or ""
            summary = obj.get("summary") or title
            tp = obj.get("time_published") or ""
            published = _parse_av_time(tp) or datetime.now(timezone.utc).isoformat()

            impacts = []
            for ts in obj.get("ticker_sentiment", []):
                ticker = str(ts.get("ticker", "")).upper()
                asset = self.TICKER_ALIASES.get(ticker, ticker)
                if asset not in known:
                    continue
                try:
                    sentiment = float(ts.get("ticker_sentiment_score", 0.0))
                except (TypeError, ValueError):
                    continue
                relevance = float(ts.get("relevance_score", 0.5) or 0.5)
                label = str(ts.get("ticker_sentiment_label", "")).lower()
                direction = "bullish" if sentiment > 0 else "bearish" if sentiment < 0 else "neutral"
                impacts.append(
                    {
                        "asset": asset,
                        "sentiment": float(max(-1.0, min(1.0, sentiment))),
                        "relevance": float(min(1.0, relevance)),
                        "direction": direction,
                        "reasoning": f"Alpha Vantage ticker sentiment ({label})",
                    }
                )
            if not impacts:
                continue

            news_id = make_news_id(url, published)
            articles.append(
                {
                    "news_id": news_id,
                    "source": "alphavantage",
                    "title": title,
                    "snippet": summary,
                    "url": url,
                    "published_at": published,
                    "impacts": impacts,
                    "classifier_used": "alphavantage",
                    "raw_payload": obj,
                }
            )
        return articles


class ClassifierRouter:
    """Try Gemini -> FinBERT -> Lexicon."""

    def __init__(self, watchlist_df: pd.DataFrame | None = None):
        self.watchlist_df = watchlist_df
        self.classifiers = [
            GeminiClassifier(),
            GroqClassifier(),
            FinBERTClassifier(),
            LexiconClassifier(),
        ]

    async def classify(self, news_list: list[dict[str, Any]], watchlist_df: pd.DataFrame | None = None) -> list[dict[str, Any]]:
        if not news_list:
            return []

        resolved_watchlist = watchlist_df if watchlist_df is not None else self.watchlist_df

        remaining = list(news_list)
        results: list[dict[str, Any]] = []
        for classifier in self.classifiers:
            if not remaining:
                break
            try:
                if hasattr(classifier, "classify_async"):
                    classified = await classifier.classify_async(remaining, resolved_watchlist)
                else:
                    classified = classifier.classify(remaining, resolved_watchlist)
            except Exception as exc:
                logger.warning("Classifier {} failed entirely: {}", type(classifier).__name__, exc)
                continue
            if not classified:
                continue
            classified_ids = {c.get("news_id") for c in classified}
            results.extend(classified)
            remaining = [n for n in remaining if n.get("news_id") not in classified_ids]

        if remaining:
            logger.warning("{} noticias nao classificadas por nenhum classificador", len(remaining))
        return results


def exponential_decay(sentiment: float, age_minutes: float, half_life: int = 120) -> float:
    """Apply exponential decay to sentiment with a half-life in minutes."""
    if half_life <= 0:
        raise ValueError("half_life must be positive")
    decay = np.exp(-np.log(2.0) * max(age_minutes, 0.0) / half_life)
    return float(sentiment * decay)


class AssetScorer:
    """Aggregate by asset, apply decayed sentiment and weighted mean by relevance."""

    def __init__(self, half_life_minutes: int = 120):
        self.half_life_minutes = int(half_life_minutes)

    def score_news(self, classified_news: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
        aggregated: dict[str, dict[str, Any]] = {}

        for news in classified_news:
            published_at = pd.to_datetime(news.get("published_at"), errors="coerce", utc=True)
            if pd.isna(published_at):
                published_at = pd.Timestamp.now(tz="UTC")
            if published_at.tzinfo is None:
                published_at = published_at.tz_localize("UTC")
            age_minutes = (pd.Timestamp.now(tz="UTC") - published_at).total_seconds() / 60.0
            src_weight = _source_credibility(news.get("source"))

            for raw_impact in news.get("impacts", []):
                impact = raw_impact.model_dump() if hasattr(raw_impact, "model_dump") else raw_impact
                if not isinstance(impact, dict):
                    continue
                asset = str(impact.get("asset", "")).upper()
                if not asset:
                    continue
                if asset not in aggregated:
                    aggregated[asset] = {"raw_sum": 0.0, "decayed_sum": 0.0, "weight": 0.0, "news_count": 0, "max_rel": 0.0}

                sentiment = float(impact.get("sentiment", 0.0))
                relevance = float(impact.get("relevance", 0.0))
                rel_eff = min(1.0, relevance * src_weight)
                decayed = exponential_decay(sentiment, age_minutes, self.half_life_minutes)
                weighted = decayed * rel_eff
                aggregated[asset]["raw_sum"] += sentiment * rel_eff
                aggregated[asset]["decayed_sum"] += weighted
                aggregated[asset]["weight"] += rel_eff
                aggregated[asset]["news_count"] += 1
                aggregated[asset]["max_rel"] = max(aggregated[asset]["max_rel"], rel_eff)

        output: dict[str, dict[str, Any]] = {}
        for asset, values in aggregated.items():
            weight = max(values["weight"], 1e-9)
            raw_score = values["raw_sum"] / weight
            decayed_score = values["decayed_sum"] / weight
            consensus = 1.0 - math.exp(-0.7 * values["news_count"])
            confidence = min(1.0, max(values["max_rel"], consensus))
            output[asset] = {
                "raw_score": float(raw_score),
                "decayed_score": float(decayed_score),
                "news_count": int(values["news_count"]),
                "confidence": float(confidence),
            }
        return output


class SignalNormalizer:
    """Calculate z-score in DuckDB using SQL window functions."""

    def __init__(self, db_manager: "DuckDBManager", days: int = 30):
        self.db_manager = db_manager
        self.days = max(1, int(days))

    def normalize(self, signals: dict[str, dict[str, Any]]) -> dict[str, AssetSignal]:
        if not signals:
            return {}

        rows: list[dict[str, Any]] = []
        for asset, values in signals.items():
            rows.append(
                {
                    "asset": asset,
                    "timestamp": datetime.now(timezone.utc),
                    "raw_score": float(values.get("raw_score", 0.0)),
                    "decayed_score": float(values.get("decayed_score", 0.0)),
                    "z_score": 0.0,
                    "news_count": int(values.get("news_count", 0)),
                    "confidence": float(values.get("confidence", 0.0)),
                }
            )

        if rows:
            self.db_manager.save_signals({row["asset"]: row for row in rows})

        recent_sql = """
            WITH recent AS (
                SELECT
                    asset,
                    timestamp,
                    decayed_score,
                    AVG(decayed_score) OVER (
                        PARTITION BY asset
                        ORDER BY timestamp
                        RANGE BETWEEN (INTERVAL '1 day' * ?) PRECEDING AND CURRENT ROW
                    ) AS avg_score,
                    STDDEV(decayed_score) OVER (
                        PARTITION BY asset
                        ORDER BY timestamp
                        RANGE BETWEEN (INTERVAL '1 day' * ?) PRECEDING AND CURRENT ROW
                    ) AS stddev_score,
                    ROW_NUMBER() OVER (
                        PARTITION BY asset
                        ORDER BY timestamp DESC
                    ) AS rn
                FROM nlp_sentiment_signals
                WHERE timestamp >= CURRENT_TIMESTAMP - (INTERVAL '1 day' * ?)
            )
            SELECT asset, decayed_score, (decayed_score - avg_score) / NULLIF(stddev_score, 0) AS z_score
            FROM recent
            WHERE rn = 1
        """
        result_df = self.db_manager.conn.execute(recent_sql, [self.days, self.days, self.days]).df()
        z_map = {str(row["asset"]).upper(): float(row.get("z_score", 0.0)) for _, row in result_df.iterrows()}

        final: dict[str, AssetSignal] = {}
        for asset, values in signals.items():
            current_ts = datetime.now(timezone.utc)
            final[asset] = AssetSignal(
                asset=asset,
                timestamp=current_ts,
                raw_score=float(values.get("raw_score", 0.0)),
                decayed_score=float(values.get("decayed_score", 0.0)),
                z_score=float(z_map.get(asset.upper(), 0.0)),
                news_count=int(values.get("news_count", 0)),
                confidence=float(min(1.0, values.get("confidence", 0.0))),
            )
        return final


class NLPSentimentEngine:
    """Main interface for GUI-driven sentiment analysis."""

    def __init__(self, db_connection: str | duckdb.DuckDBPyConnection, config: dict[str, Any] | None = None):
        self.db_manager = DuckDBManager(db_connection)
        self.config = {
            "half_life_minutes": 120,
            "max_news_per_cycle": 50,
            "days_for_zscore": 30,
        }
        if config:
            self.config.update(config)

        self.scorer = AssetScorer(self.config.get("half_life_minutes", 120))
        self.normalizer = SignalNormalizer(self.db_manager, self.config.get("days_for_zscore", 30))
        self.collector_orchestrator = CollectorOrchestrator(
            [
                GDELTCollector({"max_rows": self.config.get("max_news_per_cycle", 50)}),
                FinnhubCollector({"max_rows": max(1, min(25, self.config.get("max_news_per_cycle", 50)))}),
                RSSCollector({"feed_urls": list(DEFAULT_RSS_FEEDS)}),
                AlphaVantageCollector({"max_rows": self.config.get("max_news_per_cycle", 20)}),
            ]
        )

    def _effective_watchlist(self) -> pd.DataFrame:
        wl = self.db_manager.load_watchlist()
        if wl.empty:
            wl = pd.DataFrame(DEFAULT_WATCHLIST)
        macro = pd.DataFrame(
            [{"symbol": str(e["entity"]).upper(), "keywords": e["keywords"]} for e in load_macro_economies()]
        )
        return pd.concat([wl, macro], ignore_index=True)

    async def run_cycle(self) -> dict[str, AssetSignal]:
        t0 = datetime.now(timezone.utc)
        watchlist_df = self._effective_watchlist()
        macro_entities = {e["entity"].upper() for e in load_macro_economies()}

        raw_news = await self.collector_orchestrator.collect_all(watchlist_df)
        self.db_manager.save_raw_news(raw_news)

        classified_news: list[dict[str, Any]] = []
        if not raw_news:
            logger.info("No news collected from any source.")
        else:
            pre_classified = [n for n in raw_news if n.get("impacts")]
            to_classify = [n for n in raw_news if not n.get("impacts")]
            classified_news = list(pre_classified)
            if to_classify:
                try:
                    router = ClassifierRouter(watchlist_df)
                    classified_news += await router.classify(to_classify, watchlist_df)
                except Exception as exc:
                    logger.warning("Classification failed: {}", exc)

            macro_cls = MacroClassifier()
            macro_results = macro_cls.classify(raw_news, watchlist_df)
            if macro_results:
                by_id = {n.get("news_id"): n for n in classified_news}
                for m in macro_results:
                    nid = m.get("news_id")
                    if nid in by_id:
                        merged_impacts = list(by_id[nid].get("impacts", [])) + list(m.get("impacts", []))
                        by_id[nid]["impacts"] = dedup_impacts_by_asset(merged_impacts)
                    else:
                        classified_news.append(m)

        for n in classified_news:
            imps = n.get("impacts")
            if imps:
                n["impacts"] = dedup_impacts_by_asset(imps)

        classified_news = _dedup_classified(classified_news)

        per_source: dict[str, int] = {}
        for n in raw_news:
            s = str(n.get("source", "unknown"))
            per_source[s] = per_source.get(s, 0) + 1
        per_classifier: dict[str, int] = {}
        macro_total = 0
        for n in classified_news:
            c = str(n.get("classifier_used", "unknown"))
            per_classifier[c] = per_classifier.get(c, 0) + 1
            if any(
                str(getattr(i, "asset", None) or (i.get("asset") if isinstance(i, dict) else "")).upper() in macro_entities
                for i in n.get("impacts", [])
            ):
                macro_total += 1

        gemini_used = any(c == "gemini" for c in per_classifier)
        groq_used = any(c == "groq" for c in per_classifier)
        lexicon_used = any(c == "lexicon" for c in per_classifier)
        degraded = bool(lexicon_used and not gemini_used and not groq_used)
        if degraded:
            logger.error("NLP pipeline DEGRADADO: classificacao caiu para Lexicon (Gemini indisponivel). Sinal de menor qualidade.")

        self.db_manager.save_classified_news(classified_news)

        if not classified_news:
            logger.info("No classified news produced; returning empty signal set")
            self.db_manager.save_pipeline_run({
                "timestamp": t0,
                "duration_ms": (datetime.now(timezone.utc) - t0).total_seconds() * 1000.0,
                "collected_total": len(raw_news),
                "per_source": per_source,
                "classified_total": 0,
                "per_classifier": per_classifier,
                "macro_total": 0,
                "errors": [],
                "degraded": degraded,
            })
            return {}

        scored = self.scorer.score_news(classified_news)
        normalized = self.normalizer.normalize(scored)
        self.db_manager.save_signals({asset: signal for asset, signal in normalized.items()})

        self.db_manager.save_pipeline_run({
            "timestamp": t0,
            "duration_ms": (datetime.now(timezone.utc) - t0).total_seconds() * 1000.0,
            "collected_total": len(raw_news),
            "per_source": per_source,
            "classified_total": len(classified_news),
            "per_classifier": per_classifier,
            "macro_total": macro_total,
            "errors": [],
            "degraded": degraded,
        })
        return normalized

    def run_cycle_sync(self) -> dict[str, AssetSignal]:
        return asyncio.run(self.run_cycle())


__all__ = [
    "AssetImpact",
    "ClassifiedNews",
    "AssetSignal",
    "DuckDBManager",
    "BaseCollector",
    "GDELTCollector",
    "FinnhubCollector",
    "RSSCollector",
    "CollectorOrchestrator",
    "BaseClassifier",
    "GeminiClassifier",
    "GroqClassifier",
    "FinBERTClassifier",
    "LexiconClassifier",
    "ClassifierRouter",
    "exponential_decay",
    "AssetScorer",
    "SignalNormalizer",
    "NLPSentimentEngine",
    "DEFAULT_WATCHLIST",
    "HALF_LIFE_MINUTES",
]
