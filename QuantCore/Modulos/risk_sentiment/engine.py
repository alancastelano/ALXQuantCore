"""
RiskSentimentEngine v3.2 — SMART H1 INCREMENTAL
===============================================
Run every 1 hour (Task Scheduler / Cron).

Usage:
    python -m Modulos.risk_sentiment.engine [--no-csv]
    python -m Modulos.risk_sentiment.engine --no-csv  # DB only, no CSV export

Changes v3.2 (Fase 0 + 1):
  - validate_data corrigido: valida por NOME DE COLUNA e QUARENTENA (NaN) valores
    fora dos bounds (antes chaveava por FRED id e nunca casava; so imprimia).
  - save_to_db com transacao atomica (BEGIN/COMMIT/ROLLBACK).
  - Resiliência: fetch_daily_series com fallback via sources.fetch_resilient
    (primaria -> FRED_HTTP/Yahoo) + detect_frozen (serie descontinuada) + alerta.
  - Timestamps Yahoo normalizados p/ naive (UTC-consistent); coluna is_stale
    no output (dias sem dado real); checksum .md5 no CSV export.
Changes v3.1:
  - DB is primary source (CSV is optional).
  - Revised classification: risk_label (3 states) + signal_strength (4 levels).
"""
import sys
import os
import time
import warnings
import argparse
import logging
import numpy as np
from dataclasses import dataclass
from typing import Optional
import pandas as pd
import math
import yfinance as yf
from fredapi import Fred
from datetime import datetime, timedelta, timezone
from tenacity import retry, stop_after_attempt, wait_exponential
from sklearn.decomposition import PCA
from scipy.stats import mstats
import signal as _signal

warnings.filterwarnings("ignore")
sys.path.insert(0, r"C:\ALXQuant\QuantCore")

# DB central no ALXQuant (fonte única de verdade)
from Modulos.datahouse.collector import get_connection
from config import config

# ── Lock file + Timeout ──
LOCK_FILE = r"C:\ALXQuant\data\.risk_engine.lock"
ENGINE_TIMEOUT = 120  # seconds


def _acquire_lock():
    """Check for another running engine instance; abort if found."""
    if os.path.exists(LOCK_FILE):
        try:
            with open(LOCK_FILE) as f:
                old_pid = int(f.read().strip())
            os.kill(old_pid, 0)  # check if alive
            print(f"[ABORT] Engine already running (PID {old_pid}). Exiting.")
            sys.exit(1)
        except (OSError, ValueError):
            pass  # stale lock, continue
    with open(LOCK_FILE, "w") as f:
        f.write(str(os.getpid()))


def _release_lock():
    """Remove lock file."""
    try:
        os.remove(LOCK_FILE)
    except OSError:
        pass


def _timeout_handler(signum, frame):
    """Abort if engine exceeds 120s."""
    print(f"\n[TIMEOUT] Engine exceeded {ENGINE_TIMEOUT}s — aborting!")
    _release_lock()
    sys.exit(1)

# =====================================================================
# Módulos consolidados (observability + spec + sources + roro_v4 + migrate)
# Originalmente em arquivos separados; fundidos em engine.py (2026-08-29).
# Os imports relativos foram eliminados e o dead code foi removido:
#   - spec: SIGNAL_CONTRACT_OPTIONAL, FROZEN_STATE
#   - roro_v4: roro_residual
#   - engine: fetch_v4_levels, compute_roro_v4 (nunca chamados)
#   - sources: "from .engine import send_alert" -> chamada direta send_alert
# =====================================================================

# ----------------------------- observability -----------------------------
import json as _obs_json

LOG_PATH = r"C:\ALXQuant\data\logs\risk_sentiment.log"
_LOGGER_NAME = "risk_sentiment.obs"


class _JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "ts": datetime.now().isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "event": record.getMessage(),
        }
        extra = getattr(record, "obs_fields", {})
        if isinstance(extra, dict):
            payload.update(extra)
        return _obs_json.dumps(payload, ensure_ascii=False, default=str)


def setup_logging(log_path: str = LOG_PATH):
    """Configura logger JSON-lines em data/logs/risk_sentiment.log (append)."""
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    logger = logging.getLogger(_LOGGER_NAME)
    logger.setLevel(logging.INFO)
    logger.handlers.clear()
    fh = logging.FileHandler(log_path, encoding="utf-8")
    fh.setFormatter(_JsonFormatter())
    logger.addHandler(fh)
    logger.propagate = False
    # tambem roteia o logger risk_sentiment.sources (usado em sources) p/ o mesmo arquivo
    src = logging.getLogger("risk_sentiment.sources")
    src.setLevel(logging.INFO)
    src.handlers.clear()
    src.addHandler(fh)
    src.propagate = False
    return logger


def log_event(event: str, **fields):
    try:
        logger = logging.getLogger(_LOGGER_NAME)
        if not logger.handlers:
            logger = setup_logging()
        logger.info(event, extra={"obs_fields": fields})
    except Exception:
        pass


# ------------------------------- spec ----------------------------------
MODEL_EST_END = "2023-12-29"
MODEL_REFIT_FREQ = 365

CATEGORY_FACTORS = {
    "credit": {
        "credit_hy":      dict(transform="diff",    primary="FRED",  code="BAMLH0A0HYM2",  label="US HY OAS"),
        "credit_euro_hy": dict(transform="diff",    primary="FRED",  code="BAMLHE00EHYIOAS", label="Euro HY OAS", optional=True),
        "credit_baa":     dict(transform="diff",    primary="FRED",  code="BAA10Y",        label="US BAA - 10Y"),
        "credit_bbb":     dict(transform="diff",    primary="FRED",  code="BAMLC0A4CBBB",  label="Equity BBB OAS", optional=True),
    },
    "equity_vol": {
        "equity_sp":      dict(transform="neg_pct", primary="YAHOO", code="^GSPC",         label="S&P 500 (inverso)",
                              fallback=(("FRED", "SP500"),)),
        "equity_intl":    dict(transform="neg_pct", primary="YAHOO", code="EFA",           label="MSCI AE (inverso)"),
        "vol_vix":        dict(transform="diff",    primary="YAHOO", code="^VIX",          label="VIX",
                              fallback=(("FRED", "VIXCLS"),)),
        "bond_vol":       dict(transform="diff",    primary="YAHOO", code="^MOVE",         label="MOVE (bond vol)", optional=True),
    },
    "funding": {
        "ted_like":       dict(transform="spread",  a="DGS3MO",  b="FEDFUNDS", label="TED-like (DGS3MO - FedFunds)"),
        "cp_ois":         dict(transform="spread",  a="DCPN3M",  b="FEDFUNDS", label="LIBOR-OIS-like (DCPN3M - FF)"),
        "repo_stress":    dict(transform="spread",  a="SOFR",    b="EFFR",     label="Repo stress (SOFR - EFFR)", optional=True),
    },
    "fx_gold": {
        "dxy":            dict(transform="pct",     primary="FRED", code="DTWEXBGS",      label="DXY TW (broader)"),
        "gold":           dict(transform="pct",     primary="YAHOO", code="GLD",          label="Ouro"),
    },
}


@dataclass(frozen=True)
class SeriesSpec:
    col: str
    source: str
    code: str
    fallback: tuple = ()
    frozen_max_days: Optional[int] = None

    def primary(self):
        return (self.source, self.code)

    def alternatives(self):
        out = []
        for c in self.fallback:
            out.append(c)
            if c[0] == "FRED":
                out.append(("FRED_HTTP", c[1]))
        return out


FRED_HTTP_TEMPLATE = "https://fred.stlouisfed.org/graph/fredgraph.csv?id={code}"


RORO_SPECS: dict[str, SeriesSpec] = {
    "kcroro":       SeriesSpec("kcroro", "FRED", "KCRORO", frozen_max_days=5),
    "credit_hy":    SeriesSpec("credit_hy", "FRED", "BAMLH0A0HYM2", frozen_max_days=7),
    "credit_baa":   SeriesSpec("credit_baa", "FRED", "BAA10Y", frozen_max_days=7),
    "equity_sp":    SeriesSpec("equity_sp", "YAHOO", "^GSPC", fallback=(("FRED", "SP500"),), frozen_max_days=12),
    "equity_intl":  SeriesSpec("equity_intl", "YAHOO", "EFA", frozen_max_days=12),
    "vix":          SeriesSpec("vix", "YAHOO", "^VIX", fallback=(("FRED", "VIXCLS"),), frozen_max_days=7),
    "dxy":          SeriesSpec("dxy", "YAHOO", "DX-Y.NYB", fallback=(("FRED", "DTWEXBGS"),), frozen_max_days=7),
    "gold":         SeriesSpec("gold", "YAHOO", "GLD", frozen_max_days=7),
}

FACTOR_SPECS: dict[str, SeriesSpec] = {
    "credit_hy":       SeriesSpec("credit_hy", "FRED", "BAMLH0A0HYM2", frozen_max_days=7),
    "credit_euro_hy":  SeriesSpec("credit_euro_hy", "FRED", "BAMLHE00EHYIOAS", frozen_max_days=7),
    "credit_baa":      SeriesSpec("credit_baa", "FRED", "BAA10Y", frozen_max_days=7),
    "credit_bbb":      SeriesSpec("credit_bbb", "FRED", "BAMLC0A4CBBB", frozen_max_days=7),
    "equity_sp":       SeriesSpec("equity_sp", "YAHOO", "^GSPC", fallback=(("FRED", "SP500"),), frozen_max_days=12),
    "equity_intl":     SeriesSpec("equity_intl", "YAHOO", "EFA", frozen_max_days=12),
    "vol_vix":         SeriesSpec("vol_vix", "YAHOO", "^VIX", fallback=(("FRED", "VIXCLS"),), frozen_max_days=7),
    "bond_vol":        SeriesSpec("bond_vol", "YAHOO", "^MOVE", frozen_max_days=7),
    "dxy":             SeriesSpec("dxy", "YAHOO", "DX-Y.NYB", fallback=(("FRED", "DTWEXBGS"),), frozen_max_days=7),
    "gold":            SeriesSpec("gold", "YAHOO", "GLD", frozen_max_days=7),
    "DGS3MO":          SeriesSpec("DGS3MO", "FRED", "DGS3MO", frozen_max_days=7),
    "FEDFUNDS":        SeriesSpec("FEDFUNDS", "FRED", "FEDFUNDS", frozen_max_days=7),
    "DCPN3M":          SeriesSpec("DCPN3M", "FRED", "DCPN3M", frozen_max_days=7),
    "SOFR":            SeriesSpec("SOFR", "FRED", "SOFR", frozen_max_days=7),
    "EFFR":            SeriesSpec("EFFR", "FRED", "EFFR", frozen_max_days=7),
}

ALL_SPECS: dict[str, SeriesSpec] = {**RORO_SPECS, **FACTOR_SPECS}


SIGNAL_CONTRACT = {
    "date":            ("str", "data de fechamento (YYYY-MM-DD)"),
    "risk_label":      ("str", "RISK_ON | NEUTRAL | RISK_OFF"),
    "roro_score":      ("float", "z-score do RORO (legado PCA interno)"),
    "global_risk_score": ("float", "apetite de risco em [-1,1]; positivo = RISK_ON"),
    "roro_kcroro":     ("float", "nivel KCRORO oficial (KC Fed, em sigma)"),
    "roro_kcroro_z":   ("float", "z do KCRORO (= nivel; ja e' z)"),
    "is_stale":        ("int", "1 onde o dia nao tem dado real (copiado/feriado)"),
}


def check_signal_contract(df):
    missing = [c for c in SIGNAL_CONTRACT if c != "date" and c not in df.columns]
    return missing


def flattened_factors() -> dict:
    out = {}
    for cat in CATEGORY_FACTORS.values():
        for k, v in cat.items():
            out[k] = v
    return out


# ------------------------------ sources ---------------------------------
log = logging.getLogger("risk_sentiment.sources")


class QuarantinedError(Exception):
    pass


def _utc_now():
    return datetime.now(timezone.utc)


def _naive(idx):
    if getattr(idx, "tz", None) is not None:
        return idx.tz_localize(None)
    return idx


def _fetch_fred(code, start, fred=None):
    data = fred.get_series(code, observation_start=start)
    s = pd.Series(data.values, index=pd.to_datetime(data.index), name=code)
    return s.dropna()


def _fetch_fred_http(code, start):
    import io as _io
    import requests as _req
    url = FRED_HTTP_TEMPLATE.format(code=code)
    r = _req.get(url, timeout=20)
    r.raise_for_status()
    df = pd.read_csv(_io.StringIO(r.text))
    df.columns = [c.strip().upper() for c in df.columns]
    date_col = "OBSERVATION_DATE" if "OBSERVATION_DATE" in df.columns else "DATE"
    df[date_col] = pd.to_datetime(df[date_col])
    val_col = df.columns[df.columns != date_col][0]
    s = df.set_index(date_col)[val_col]
    s = s[s.index >= pd.Timestamp(start)]
    s.name = code
    return s.dropna()


def _fetch_yahoo(symbol, start):
    df = yf.download(symbol, start=start, progress=False, auto_adjust=True)
    if df is None or df.empty:
        return pd.Series(dtype=float)
    s = df["Close"].squeeze()
    if isinstance(s, pd.DataFrame):
        s = s.iloc[:, 0]
    s.index = _naive(s.index)
    s.name = symbol
    return s.dropna()


_FETCHERS = {
    "FRED": _fetch_fred,
    "FRED_HTTP": lambda code, start, fred=None: _fetch_fred_http(code, start),
    "YAHOO": lambda code, start, fred=None: _fetch_yahoo(code, start),
}


def _fetch(source, code, start, fred):
    fn = _FETCHERS[source]
    return fn(code, start, fred)


def fetch_resilient(col, start, fred=None):
    spec = ALL_SPECS.get(col)
    if spec is None:
        raise KeyError(f"spec desconhecida: {col}")
    chain = [spec.primary()] + list(spec.alternatives())
    tried = []
    last_err = None
    for (source, code) in chain:
        try:
            s = _fetch(source, code, start, fred)
            if s is not None and not s.empty:
                s.name = col
                log.info("fetch %s via %s(%s): %d obs ate %s",
                         col, source, code, len(s), s.index[-1].date())
                return s
            tried.append(f"{source}:{code} (vazio)")
        except Exception as e:
            tried.append(f"{source}:{code} ({type(e).__name__}: {e}")
            last_err = e
            log.warning("falha %s %s:%s -> %s", col, source, code, e)
    msg = f"Quarentena '{col}': todas as fontes falharam [{'; '.join(tried)}]"
    log.error(msg)
    _alert_once(col, msg)
    raise QuarantinedError(msg)


def detect_frozen(s, max_days=7, label=""):
    if s is None or s.empty:
        return False
    idx = _naive(s.index)
    last = idx.max()
    age_days = (_utc_now().replace(tzinfo=None) - last).days
    if age_days > max_days:
        _alert_once(label or s.name,
                    f"[FROZEN] {label or s.name}: ultimo obs {last.date()} "
                    f"({age_days}d atras) - possivel serie descontinuada")
        return True
    return False


# Persistencia de alertas (evita spam de Telegram a cada execucao horaria)
ALERT_STATE_PATH = r"C:\ALXQuant\data\state\alerts_sent.json"


def _load_alert_state() -> dict:
    try:
        if os.path.exists(ALERT_STATE_PATH):
            with open(ALERT_STATE_PATH, "r", encoding="utf-8") as fh:
                return _obs_json.load(fh)
    except Exception:
        pass
    return {}


def _save_alert_state(state: dict) -> None:
    try:
        os.makedirs(os.path.dirname(ALERT_STATE_PATH), exist_ok=True)
        with open(ALERT_STATE_PATH, "w", encoding="utf-8") as fh:
            _obs_json.dump(state, fh)
    except Exception:
        pass


_ALERTED: dict[str, str] = _load_alert_state()


def _alert_once(key, message):
    today = datetime.now().strftime("%Y-%m-%d")
    k = f"{key}|{today}"
    if _ALERTED.get(k) == message:
        return
    _ALERTED[k] = message
    _save_alert_state(_ALERTED)
    try:
        send_alert(message)
    except Exception as e:
        log.warning("send_alert falhou: %s", e)


# ------------------------------ roro_v4 ----------------------------------
Z_WINDOW = 252
Z_MIN = 60

STRENGTH_BINS = [2.5, 1.5, 0.5]
STRENGTH_NAMES = ["extreme", "strong", "moderate"]


def transform_component(levels):
    out = pd.DataFrame(index=levels.index)
    for cat in CATEGORY_FACTORS.values():
        for key, cfg in cat.items():
            t = cfg.get("transform")
            if t == "spread":
                a, b = cfg.get("a"), cfg.get("b")
                if a in levels.columns and b in levels.columns:
                    out[key] = levels[a].astype(float) - levels[b].astype(float)
                continue
            if key in levels.columns:
                raw = levels[key].astype(float)
                out[key] = _apply_transform(raw, t)
    return out


def _apply_transform(s, t):
    if t == "diff":
        return s.diff()
    if t == "pct":
        return s.pct_change()
    if t == "neg_pct":
        return -s.pct_change()
    return s.diff()


def _zscore(df):
    m = df.rolling(Z_WINDOW, min_periods=Z_MIN).mean()
    std = df.rolling(Z_WINDOW, min_periods=Z_MIN).std().replace(0, np.nan)
    return (df - m) / std


class ModelRefit:
    def __init__(self, est_end=MODEL_EST_END, refit_freq=MODEL_REFIT_FREQ):
        self.est_end = pd.Timestamp(est_end)
        self.refit_freq = refit_freq
        self._weights = {}
        self._boundaries = []

    def _fit_window(self, z, as_of):
        train = z[z.index <= as_of]
        cat_w = {}
        for cat, factors in CATEGORY_FACTORS.items():
            cols = [c for c in factors if c in train.columns
                    and train[c].notna().sum() >= Z_MIN]
            sub = train[cols].fillna(0).to_numpy()
            if len(cols) < 1 or len(sub) < Z_MIN:
                continue
            w = _pca1_orient(sub, positive_first=True)
            cat_w[cat] = {"cols": cols, "weights": w}
        feat_cols = [c for c in train.columns
                     if train[c].notna().sum() >= Z_MIN]
        global_ = None
        if len(feat_cols) >= 3:
            mat = z[feat_cols].fillna(0)
            train_mat = mat[mat.index <= as_of]
            if len(train_mat) >= Z_MIN:
                gw = _pca1_orient(train_mat.to_numpy(), positive_first=True)
                oidx = feat_cols.index("vol_vix") if "vol_vix" in feat_cols \
                    else feat_cols.index("equity_sp") if "equity_sp" in feat_cols else 0
                if gw[oidx] < 0:
                    gw = -gw
                global_ = gw
        return {"cat": cat_w, "global_cols": feat_cols, "global": global_}

    def _category_scores(self, z, cat_w):
        out = pd.DataFrame(index=z.index)
        for cat, meta in cat_w.items():
            out[cat] = (z[meta["cols"]].fillna(0).to_numpy() @ meta["weights"])
        return out

    def _global_score(self, z, w):
        cols = w.get("global_cols") or []
        if w["global"] is None or not cols:
            subs = self._category_scores(z, w["cat"])
            return subs.mean(axis=1)
        mat = z[cols].fillna(0)
        return pd.Series(mat.to_numpy() @ w["global"], index=z.index)

    def _boundaries_of(self, df):
        bs, t = [], self.est_end
        while t <= df.index.max():
            bs.append(t)
            t += pd.Timedelta(days=self.refit_freq)
        if not bs:
            bs = [df.index.max()]
        return bs

    def project(self, z):
        if not self._boundaries:
            self._boundaries = self._boundaries_of(z)
        for b in self._boundaries:
            if b not in self._weights:
                self._weights[b] = self._fit_window(z, b)
        scores = {f"roro_{c}": pd.Series(np.nan, index=z.index)
                  for c in CATEGORY_FACTORS}
        g = pd.Series(np.nan, index=z.index, name="roro_v4")
        prev = None
        for b in self._boundaries:
            mask = (z.index <= b) if prev is None else \
                (z.index > prev) & (z.index <= b)
            w = self._weights[b]
            subs = self._category_scores(z.loc[mask], w["cat"])
            for cat in CATEGORY_FACTORS:
                if cat in subs.columns:
                    scores[f"roro_{cat}"].loc[mask] = subs[cat]
            g.loc[mask] = self._global_score(z.loc[mask], w)
            prev = b
        after = z.index > prev
        if after.any():
            w = self._weights[prev]
            subs = self._category_scores(z.loc[after], w["cat"])
            for cat in CATEGORY_FACTORS:
                if cat in subs.columns:
                    scores[f"roro_{cat}"].loc[after] = subs[cat]
            g.loc[after] = self._global_score(z.loc[after], w)
        return {**scores, "roro_v4": g}


def _pca1_orient(mat, positive_first=True):
    pca = PCA(n_components=1, svd_solver="full")
    w = pca.fit(mat).components_[0]
    if w[0] < 0 and positive_first:
        w = -w
    return w


def build_roro_v4(levels, refit=None):
    comp = transform_component(levels)
    z = _zscore(comp)
    refit = refit or ModelRefit()
    result = refit.project(z)
    df = pd.DataFrame(index=levels.index)
    for k, v in result.items():
        df[k] = v
    df["roro_v4_z"] = _zscore(df[["roro_v4"]]).iloc[:, 0]  # normalizacao rolling (sem look-ahead)
    return df


def classify_v4(roro_z):
    z = roro_z.clip(lower=-6.0, upper=6.0)
    label = pd.Series("NEUTRAL", index=roro_z.index)
    label[z <= -1.0] = "RISK_ON"
    label[z >= 1.0] = "RISK_OFF"
    strength = _strength(z.abs())
    return pd.DataFrame({"risk_label": label, "signal_strength": strength,
                         "roro_z": z})


def _strength(abs_z):
    cond = [abs_z >= STRENGTH_BINS[0],
            abs_z >= STRENGTH_BINS[1],
            abs_z >= STRENGTH_BINS[2]]
    return pd.Series(np.select(cond, STRENGTH_NAMES, default="low"),
                     index=abs_z.index)


def roro_sentiment(roro_z):
    return (-roro_z / 3.0).clip(-1.0, 1.0)


# ------------------------------ migrate ----------------------------------
SQL_MIGRATE = """
ALTER TABLE risk_labels ADD COLUMN signal_strength TEXT DEFAULT 'low';
DROP VIEW IF EXISTS risk_sentiment_daily;
CREATE VIEW IF NOT EXISTS v_risk_sentiment AS
SELECT
    rl.date,
    rl.risk_label,
    rl.signal_strength,
    ROUND(rl.roro_score, 4) AS roro_score,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'VIX'      AND ms.date = rl.date), 2) AS vix,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'DTWEXBGS' AND ms.date = rl.date), 3) AS dxy,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'DGS2'     AND ms.date = rl.date), 3) AS yield_2y,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'DGS10'    AND ms.date = rl.date), 3) AS yield_10y,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'DGS30'    AND ms.date = rl.date), 3) AS yield_30y,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'T10Y2Y'   AND ms.date = rl.date), 3) AS yield_curve,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'BAMLH0A0HYM2' AND ms.date = rl.date), 2) AS credit_hy,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'BAA10Y'   AND ms.date = rl.date), 2) AS credit_baa,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'CPIAUCSL' AND ms.date = rl.date), 2) AS cpi_us,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'UNRATE'   AND ms.date = rl.date), 2) AS unemp_us,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'CP0000EZ19M086NEST' AND ms.date = rl.date), 2) AS cpi_eu,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'JPNCPIALLMINMEI' AND ms.date = rl.date), 2) AS cpi_jp,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'CHNCPIALLMINMEI' AND ms.date = rl.date), 2) AS cpi_cn,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'FEDFUNDS' AND ms.date = rl.date), 3) AS fed_funds,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'NFCI'     AND ms.date = rl.date), 3) AS nfci,
    ROUND((SELECT ms.value FROM macro_series ms WHERE ms.symbol = 'STLFSI4'  AND ms.date = rl.date), 3) AS stlfsi
FROM risk_labels rl;
"""


def migrate():
    conn = get_connection(read_only=False)
    try:
        for statement in SQL_MIGRATE.strip().split(';'):
            stmt = statement.strip()
            if stmt:
                conn.execute(stmt + ';')
        print("[MIGRATE] v_risk_sentiment criada com 20 colunas + ROUND().")
    except Exception as e:
        print(f"[MIGRATE] Erro: {e}")
    finally:
        conn.close()


def verify():
    with get_connection() as conn:
        cols = [r[1] for r in conn.execute("PRAGMA table_info('risk_labels')").fetchall()]
        assert 'signal_strength' in cols, "signal_strength not found!"
        sql = conn.execute(
            "SELECT sql FROM duckdb_views() WHERE view_name='v_risk_sentiment'"
        ).fetchone()
        assert sql is not None, "v_risk_sentiment not found!"
        print(f"[VERIFY] v_risk_sentiment:\n{sql[0][:200]}...")
        cnt = conn.execute("SELECT COUNT(*) FROM v_risk_sentiment").fetchone()[0]
        print(f"[VERIFY] v_risk_sentiment rows: {cnt}")
        desc = [d[0] for d in conn.execute("SELECT * FROM v_risk_sentiment LIMIT 1").description]
        print(f"[VERIFY] columns: {desc}")
        print("[VERIFY] OK")

OUTPUT_PATH = r"C:\ALXQuant\data\mql5\risk_sentiment_daily.csv"
COMMON_FILES = r"C:\Users\User\AppData\Roaming\MetaQuotes\Terminal\Common\Files\risk_sentiment_daily.csv"

FRED_RORO = {"credit_hy": "BAMLH0A0HYM2", "credit_baa": "BAA10Y"}
YAHOO_RORO = {"equity_sp": "SPY", "equity_intl": "EFA", "gold": "GLD"}
YAHOO_INTRADAY = {"vix": "^VIX", "dxy": "DX-Y.NYB"}
FRED_EXTRA = {"yield_2y": "DGS2", "yield_10y": "DGS10"}
FRED_PHILLIPS = {
    "cpi_us": "CPIAUCSL", "unemp_us": "UNRATE",
    "cpi_eu": "CP0000EZ19M086NEST", "unemp_eu": "LRHUTTTTEM156S",
    "cpi_jp": "JPNCPIALLMINMEI", "unemp_jp": "LRHUTTTTJM156S",
    "cpi_cn": "CHNCPIALLMINMEI",
}
COLUMN_TO_SYMBOL = {
    "vix": "VIX", "dxy": "DTWEXBGS",
    "yield_2y": "DGS2", "yield_10y": "DGS10",
    "credit_hy": "BAMLH0A0HYM2", "credit_baa": "BAA10Y",
    "cpi_us": "CPIAUCSL", "unemp_us": "UNRATE",
    "cpi_eu": "CP0000EZ19M086NEST", "unemp_eu": "LRHUTTTTEM156S",
    "cpi_jp": "JPNCPIALLMINMEI", "unemp_jp": "LRHUTTTTJM156S",
    "cpi_cn": "CHNCPIALLMINMEI",
    "equity_sp": "SPY", "gold": "GLD",
}
COLUMN_SOURCE = {
    "vix": "YAHOO", "dxy": "YAHOO",
    "yield_2y": "FRED", "yield_10y": "FRED",
    "credit_hy": "FRED", "credit_baa": "FRED",
    "cpi_us": "FRED", "unemp_us": "FRED",
    "cpi_eu": "FRED", "unemp_eu": "FRED",
    "cpi_jp": "FRED", "unemp_jp": "FRED",
    "cpi_cn": "FRED",
}
COLUMN_FREQ = {
    "vix": "daily", "dxy": "daily",
    "yield_2y": "daily", "yield_10y": "daily",
    "credit_hy": "daily", "credit_baa": "daily",
    "cpi_us": "monthly", "unemp_us": "monthly",
    "cpi_eu": "monthly", "unemp_eu": "monthly",
    "cpi_jp": "monthly", "unemp_jp": "monthly",
    "cpi_cn": "monthly",
}

# Limites físicos para validação de dados
BOUNDS = {
    'vix':        (0.0, 100.0),
    'dxy':        (50.0, 200.0),
    'yield_2y':   (-5.0, 20.0),
    'yield_10y':  (-5.0, 20.0),
    'yield_30y':  (-5.0, 30.0),
    'yield_curve':(-10.0, 10.0),
    'credit_hy':  (0.0, 50.0),
    'credit_baa': (0.0, 20.0),
    'credit_euro_hy': (0.0, 50.0),
    'credit_bbb': (0.0, 50.0),
    'equity_sp':  (0.0, 10000.0),
    'equity_intl':(0.0, 10000.0),
    'vol_vix':    (0.0, 100.0),
    'bond_vol':   (0.0, 100.0),
    'gold':       (0.0, 10000.0),
    'DGS3MO':     (-5.0, 20.0),
    'FEDFUNDS':   (-5.0, 20.0),
    'DCPN3M':     (-5.0, 20.0),
    'SOFR':       (-5.0, 20.0),
    'EFFR':       (-5.0, 20.0),
    'cpi_us':     (0.0, 1000.0),
    'cpi_eu':     (0.0, 1000.0),
    'cpi_jp':     (0.0, 1000.0),
    'cpi_cn':     (0.0, 1000.0),
    'unemp_us':   (0.0, 100.0),
    'unemp_eu':   (0.0, 100.0),
    'unemp_jp':   (0.0, 100.0),
    'unemp_cn':   (0.0, 100.0),
}


def send_alert(message: str):
    """Envia alerta via webhook Telegram/Slack se configurado via env var."""
    webhook_url = os.environ.get('ALXQUANT_ALERT_WEBHOOK')
    if not webhook_url:
        print(f"[ALERT] {message}")
        return
    try:
        import requests as req
        req.post(webhook_url, json={'text': message}, timeout=5)
    except Exception as e:
        print(f"[ALERT] Webhook send failed: {e}")


def validate_data(series: pd.Series, name: str) -> pd.Series:
    """Valida uma serie pelo NOME CANONICO da coluna e QUARENTENA valores ruins.

    Correcao v4 (Fase 0): antes o parametro recebia o FRED id
    ("BAMLH0A0HYM2") e BOUNDS chaveava por coluna ("credit_hy") - nunca casava.

    Comportamento:
      - Fora dos limites fisicos (BOUNDS[col]) -> NaN + alerta (quarentena).
      - Desvios |z|>6 (rolling 252, min 50) -> mantidos (cauda real) + log.
    """
    series = series.copy()
    name = name.replace("_daily", "")  # colunas Yahoo chegam como vix_daily/dxy_daily
    if name in BOUNDS:
        lo, hi = BOUNDS[name]
        bad = (series < lo) | (series > hi)
        if bad.any():
            n = int(bad.sum())
            series[bad] = np.nan
            _q = f"[VALIDATE] {name}: {n} valores fora de ({lo},{hi}) quarentenados (NaN)"
            print(_q)
            try:
                send_alert(_q)
            except Exception:
                pass
    fl = series.rolling(window=252, min_periods=50)
    z = (series - fl.mean()) / fl.std()
    extreme = z.abs() > 6
    if extreme.any():
        print(f"[VALIDATE] {name}: {int(extreme.sum())} extremos |z|>6 (mantidos - cauda real)")
    return series


def classify_signal_strength(roro_series: pd.Series) -> pd.Series:
    abs_z = roro_series.abs()
    conditions = [abs_z >= STRENGTH_BINS[0],
                  abs_z >= STRENGTH_BINS[1],
                  abs_z >= STRENGTH_BINS[2]]
    return pd.Series(np.select(conditions, STRENGTH_NAMES, default='low'),
                     index=roro_series.index)


def apply_kcroro_signal(df: pd.DataFrame, fred) -> pd.DataFrame:
    """Sobrescreve risk_label/global_risk_score com o KCRORO oficial (Fase 2).

    KCRORO (KC Fed, Chari/Dilts Stedman/Lundblad) JA E o z-score do PC1 das
    mudancas diarias normalizadas - o nivel vem em unidades de desvio padrao.
    POR ISSO o nivel e usado DIRETO nos limiares (nao re-z-scoreado):

    - risk_label:      nivel<=-1 RISK_ON | |nivel|<1 NEUTRAL | nivel>=1 RISK_OFF
                       (3 estados que o MQL5 aceita; intensidade vai p/ strength)
    - global_risk_score: -nivel/3 clipado em [-1,1] (positivo=RISK_ON, coere MQL5)
    - signal_strength: |nivel| via STRENGTH_BINS (extremo >= 2.5)
    - shift(1): sem look-ahead (o EA usa o sinal de ontem na abertura de hoje).
    - Se o KCRORO estiver indisponivel -> mantem PCA interno (degradado) + alerta.
    """
    try:
        kc = fetch_resilient("kcroro", "2003-01-01", fred)
    except QuarantinedError as e:
        print(f"[KCRORO] indisponivel: {e}. Mantendo sinal PCA interno (degradado).")
        send_alert(f"[KCRORO] indisponivel - sinal degradado para PCA interno: {e}")
        return df

    if kc is None or kc.empty:
        return df
    if detect_frozen(kc, max_days=5, label="kcroro"):
        print("[KCRORO] serie congelada (desatualizada); usando PCA interno (degradado).")
        send_alert("[KCRORO] congelado - sinal degradado para PCA interno")
        return df
    kc.name = "kcroro"

    lvl = kc.reindex(df.index)
    label = pd.Series('NEUTRAL', index=df.index)
    label[lvl <= -1.0] = 'RISK_ON'
    label[lvl >= 1.0] = 'RISK_OFF'
    strength = classify_signal_strength(lvl.clip(lower=-6.0, upper=6.0))
    g = (-1.0 * lvl / 3.0).clip(-1.0, 1.0)

    df['roro_kcroro'] = lvl.shift(1)
    df['roro_kcroro_z'] = lvl.shift(1)  # nivel ja e z-score; shift(1) sem look-ahead
    df['roro_pca'] = df.get('roro_score', np.nan)

    # shift(1): o trade de hoje decide com o sinal de ontem
    df['risk_label'] = label.shift(1)
    df['signal_strength'] = strength.shift(1)
    df['global_risk_score'] = g.shift(1)
    print(f"[KCRORO] sinal primario ativo (headline KC Fed): ultimo nivel={lvl.dropna().iloc[-1]:+.3f}")
    return df


def load_existing_csv() -> pd.DataFrame:
    if os.path.exists(OUTPUT_PATH):
        try:
            df = pd.read_csv(OUTPUT_PATH, parse_dates=['date'])
            df.set_index('date', inplace=True)
            print(f"[INFO] Existing CSV loaded. Last date: {df.index[-1].date()}")
            return df
        except Exception as e:
            print(f"[WARN] Error reading CSV, starting from scratch: {e}")
    return pd.DataFrame()


def load_existing_from_db() -> pd.DataFrame:
    """Carrega o estado anterior a partir do DuckDB (macro_series) via PIVOT.

    Reconstroi o DataFrame largo (colunas do motor) a partir da tabela longa
    macro_series. Fonte PRIMARIA; o CSV e fallback (ver main()).
    """
    conn = get_connection()
    try:
        rows = conn.execute("SELECT date, symbol, value FROM macro_series").fetchdf()
    finally:
        conn.close()
    if rows is None or rows.empty:
        return pd.DataFrame()
    wide = rows.pivot(index="date", columns="symbol", values="value")
    sym2col = {v: k for k, v in COLUMN_TO_SYMBOL.items()}
    for c in ["roro_v4", "roro_v4_z", "roro_v4_sentiment",
              "roro_credit", "roro_equity_vol", "roro_funding", "roro_fx_gold",
              "roro_score", "roro_kcroro", "roro_kcroro_z", "roro_pca"]:
        sym2col.setdefault(f"RORO_{c.upper()}", c)
    wide = wide.rename(columns=sym2col)
    wide.index = pd.to_datetime(wide.index)
    wide = wide.sort_index()
    return wide


def export_csv(df: pd.DataFrame, path: str):
    """Exporta CSV p/ MQL5, validando SIGNAL_CONTRACT (fail-fast)."""
    missing = check_signal_contract(df)
    if missing:
        msg = f"[CONTRACT] colunas obrigatorias ausentes: {missing}; abortei export"
        print(msg)
        send_alert(msg)
        return False
    df_out = df.reset_index()
    df_out['date'] = df_out['date'].dt.strftime('%Y-%m-%d')
    dec_map = {'roro_score': 4, 'global_risk_score': 4, 'yield_2y': 3, 'yield_10y': 3, 'vix': 2, 'dxy': 3, 'usd_index': 3,
               'roro_kcroro': 4, 'roro_kcroro_z': 4, 'roro_pca': 4,
               'roro_v4': 4, 'roro_v4_z': 4, 'roro_v4_sentiment': 4,
               'roro_credit': 4, 'roro_equity_vol': 4, 'roro_funding': 4, 'roro_fx_gold': 4}
    for col, dec in dec_map.items():
        if col in df_out.columns:
            df_out[col] = df_out[col].round(dec)
    for col in ['cpi_us', 'cpi_eu', 'cpi_jp', 'cpi_cn', 'unemp_us', 'unemp_eu', 'unemp_jp']:
        if col in df_out.columns:
            df_out[col] = df_out[col].round(2)
    cols = ['date', 'risk_label', 'roro_score', 'global_risk_score', 'roro_kcroro', 'roro_kcroro_z', 'roro_pca',
            'roro_v4', 'roro_v4_z', 'roro_v4_sentiment',
            'roro_credit', 'roro_equity_vol', 'roro_funding', 'roro_fx_gold',
            'yield_2y', 'yield_10y', 'vix', 'dxy', 'usd_index', 'is_stale'] + list(FRED_PHILLIPS.keys())
    df_out = df_out[[c for c in cols if c in df_out.columns]]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp_path = path + '.tmp'
    df_out.to_csv(tmp_path, index=False)
    os.replace(tmp_path, path)
    try:
        import hashlib
        with open(path, 'rb') as fh:
            digest = hashlib.md5(fh.read()).hexdigest()
        with open(path + '.md5', 'w', encoding='utf-8') as fh:
            fh.write(digest)
    except Exception as e:
        print(f"[CSV] checksum falhou {path}: {e}")


def save_to_db(df: pd.DataFrame, shadow: bool = False):
    df_out = df.reset_index()
    df_out['date'] = df_out['date'].dt.strftime('%Y-%m-%d')
    now_str = datetime.now().strftime('%Y-%m-%d %H:%M')

    conn = get_connection(read_only=False)
    conn.begin()  # transacao: delete+insert atomicos (Fase 0)
    try:
        try:
            conn.execute("ALTER TABLE risk_labels ADD COLUMN signal_strength TEXT DEFAULT 'low'")
        except Exception:
            pass

        # macro_series: melt + delete-then-insert (DuckDB 1.5+ nao suporta INSERT OR REPLACE sem PK)
        symbol_map = dict(COLUMN_TO_SYMBOL)
        v4_cols = ['roro_v4', 'roro_v4_z', 'roro_v4_sentiment',
                   'roro_credit', 'roro_equity_vol', 'roro_funding', 'roro_fx_gold']
        if shadow:
            # Shadow mode: v4 e' somente observacao -> NAO persiste (evita
            # contaminar o banco que o EA consulta com sinal nao operacional).
            v4_cols = []
        for v4col in v4_cols + ['roro_score', 'roro_kcroro', 'roro_kcroro_z', 'roro_pca', 'global_risk_score']:
            symbol_map.setdefault(v4col, f"RORO_{v4col.upper()}")
        cols_present = [c for c in symbol_map if c in df_out.columns]
        if cols_present:
            melted = df_out.melt(id_vars=['date'], value_vars=cols_present,
                                 var_name='col', value_name='value')
            melted = melted.dropna(subset=['value'])
            melted['symbol'] = melted['col'].map(symbol_map)
            melted['updated_at'] = now_str
            melted['value'] = melted['value'].astype(float)
            series_rows = list(melted[['symbol', 'date', 'value', 'updated_at']].itertuples(index=False, name=None))

            pairs = list(melted[['symbol', 'date']].drop_duplicates().itertuples(index=False, name=None))
            for sym, dt in pairs:
                conn.execute("DELETE FROM macro_series WHERE symbol = ? AND date = ?", [sym, dt])

            conn.executemany(
                "INSERT INTO macro_series (symbol, date, value, updated_at) VALUES (?, ?, ?, ?)",
                series_rows
            )
            series_count = len(series_rows)
        else:
            series_count = 0

        # risk_labels: delete-then-insert
        label_df = df_out[['date', 'risk_label', 'roro_score', 'signal_strength']].copy()
        label_df = label_df.dropna(subset=['risk_label'])
        if not label_df.empty:
            label_df['roro_score'] = label_df['roro_score'].astype(float)
            label_df['signal_strength'] = label_df['signal_strength'].fillna('low').astype(str).str.strip()
            label_df['risk_label'] = label_df['risk_label'].astype(str).str.strip()
            label_rows = list(label_df[['date', 'risk_label', 'roro_score', 'signal_strength']].itertuples(index=False, name=None))

            dates = list(label_df['date'].unique())
            for dt in dates:
                conn.execute("DELETE FROM risk_labels WHERE date = ?", [dt])

            conn.executemany(
                "INSERT INTO risk_labels (date, risk_label, roro_score, signal_strength) VALUES (?, ?, ?, ?)",
                label_rows
            )
            label_count = len(label_rows)
        else:
            label_count = 0

        conn.commit()
        print(f"[DB] macro_series: {series_count} valores | risk_labels: {label_count} datas")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=2, min=2, max=30))
def fetch_fred_smart(fred: Fred, series_id: str, start_date: str) -> pd.Series:
    try:
        data = fred.get_series(series_id, observation_start=start_date)
        s = pd.Series(data.values, index=pd.to_datetime(data.index), name=series_id)
        return s
    except Exception as e:
        print(f"[FRED] Failed to fetch {series_id}: {e}")
        return pd.Series(dtype=float, name=series_id)


@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=2, min=2, max=30))
def fetch_yahoo_daily(symbol: str, start_date: str) -> pd.Series:
    try:
        df = yf.download(symbol, start=start_date, progress=False, auto_adjust=True)
        if df.empty:
            return pd.Series(dtype=float)
        s = df["Close"].squeeze()
        if isinstance(s, pd.DataFrame):
            s = s.iloc[:, 0]
        if s.index.tz is not None:
            s.index = s.index.tz_localize(None)
        s.name = symbol
        return s
    except Exception as e:
        print(f"[YAHOO] Failed to fetch {symbol}: {e}")
        return pd.Series(dtype=float)


def fetch_daily_series(name: str, source: str, code: str, start_date: str, fred) -> pd.Series:
    """Fetch de uma serie diaria com resiliencia + validacao por coluna (v4).

    Primaria = fetch com retry (fredapi/yfinance). Se vazio E a serie tem spec
    de fallback, tenta a cadeia resiliente (fetch_resilient). Depois:
    valida por NOME DE COLUNA e detecta 'frozen' (possivel descontinuada).
    """
    spec_name = name.replace("_daily", "")  # compatibiliza vix_daily/dxy_daily com specs
    spec = ALL_SPECS.get(spec_name)
    s = fetch_fred_smart(fred, code, start_date) if source == "FRED" else fetch_yahoo_daily(code, start_date)
    if (s is None or s.empty) and spec is not None:
        s = fetch_resilient(spec_name, start_date, fred)
    if s is not None and not s.empty:
        s.name = name
        s = validate_data(s, name)
        if spec is not None and detect_frozen(s, max_days=spec.frozen_max_days or 7, label=name):
            # serie primaria congelada -> tenta a cadeia resiliente (ex.: VIX via FRED_HTTP)
            s2 = fetch_resilient(spec_name, start_date, fred)
            if s2 is not None and not s2.empty:
                s2.name = name
                s = validate_data(s2, name)
                if spec is not None:
                    detect_frozen(s2, max_days=spec.frozen_max_days or 7, label=name)
    return s


def fetch_yahoo_intraday(symbol: str) -> float:
    try:
        ticker = yf.Ticker(symbol)
        hist = ticker.history(period="5d", interval="1h")
        if hist.empty:
            return np.nan
        val = hist['Close'].dropna().iloc[-1]
        return float(val)
    except Exception as e:
        print(f"[WARN] Failed to fetch intraday for {symbol}: {e}")
        return np.nan


def compute_roro_for_new_data(df_daily: pd.DataFrame) -> pd.Series:
    if len(df_daily) < 60:
        return pd.Series(0.0, index=df_daily.index, name='roro_score')

    factors = pd.DataFrame(index=df_daily.index)
    factors['credit_hy'] = df_daily.get('credit_hy', 0)
    factors['credit_baa'] = df_daily.get('credit_baa', 0)
    factors['equity_sp'] = -df_daily.get('equity_sp', 0)
    factors['equity_intl'] = -df_daily.get('equity_intl', 0)
    factors['gold'] = df_daily.get('gold', 0)

    if 'vix_daily' in df_daily.columns:
        factors['vol_vix'] = df_daily['vix_daily']
    if 'dxy_daily' in df_daily.columns:
        factors['dxy'] = df_daily['dxy_daily']

    changes = pd.DataFrame(index=factors.index)
    for col in factors.columns:
        changes[col] = factors[col].pct_change() if 'equity' in col or 'gold' in col else factors[col].diff()
    changes = changes.dropna()

    window = 252
    roll_mean = changes.rolling(window=window, min_periods=50).mean()
    roll_std = changes.rolling(window=window, min_periods=50).std()
    z_scores = (changes - roll_mean) / roll_std

    # Winsorization: cap nos percentis 1 e 99 antes do PCA
    for col in z_scores.columns:
        clipped = mstats.winsorize(z_scores[col].values, limits=[0.01, 0.01])
        z_scores[col] = clipped
    z_scores = z_scores.fillna(0)

    # PCA via sklearn (SVD, mais estável que eigendecomposição manual)
    pca = PCA(n_components=1, svd_solver='full')
    pca.fit(z_scores.values)
    pc1_weights = pca.components_[0]

    # Orientação fixa: fatores de RISK_OFF devem ter loading positivo
    # (VIX, DXY, credit_baa, credit_hy → sobem em pânico; equity_sp já é -SPY)
    risk_off_cols = ['credit_hy', 'credit_baa', 'vol_vix', 'dxy']
    risk_off_idx = [i for i, col in enumerate(z_scores.columns) if col in risk_off_cols]
    if risk_off_idx:
        mean_loading = np.mean(pc1_weights[risk_off_idx])
        if mean_loading < 0:
            pc1_weights = -pc1_weights
            pca.components_[0] = pc1_weights

    roro_raw = z_scores.dot(pc1_weights)

    return roro_raw


def main():
    _acquire_lock()
    # SIGALRM nao existe no Windows — guarda mantem Unix intacto e
    # evita AttributeError que quebrava todo repair de Risk na VPS.
    _has_alarm = hasattr(_signal, "SIGALRM")
    if _has_alarm:
        _signal.signal(_signal.SIGALRM, _timeout_handler)
        _signal.alarm(ENGINE_TIMEOUT)
    try:
        _main_inner()
    finally:
        if _has_alarm:
            _signal.alarm(0)
        _release_lock()


def _main_inner():
    parser = argparse.ArgumentParser(description="RiskSentimentEngine v3.2")
    parser.add_argument("--export-csv", action="store_true", default=True,
                        help="Export CSV for MQL5 compatibility (default: True)")
    parser.add_argument("--no-csv", action="store_true",
                        help="Skip CSV export")
    parser.add_argument("--log", default="",
                        help="Append result line to JSON log file")
    parser.add_argument("--shadow", action="store_true",
                        help="Shadow mode: calcula o v4 e persiste como cross-check, "
                             "mas NAO altera o sinal operacional (KCRORO continua primario).")
    args = parser.parse_args()
    do_export_csv = args.export_csv and not args.no_csv
    shadow = args.shadow
    setup_logging()
    log_event("run_start", shadow=shadow, export_csv=do_export_csv)

    # Sob pythonw.exe nao ha console (sys.stdout = None); redireciona para o log.
    if args.log and (sys.stdout is None or sys.stderr is None):
        try:
            os.makedirs(os.path.dirname(args.log) or ".", exist_ok=True)
            _f = open(args.log, "a", encoding="utf-8", buffering=1)
            sys.stdout = _f
            sys.stderr = _f
        except Exception:
            pass

    t0 = time.time()
    print("\n" + "=" * 60)
    print("RISK SENTIMENT ENGINE v3.2 — Primary Source: DB")
    print("=" * 60)

    df_existing = pd.DataFrame()
    try:
        df_existing = load_existing_from_db()
        if df_existing is None or df_existing.empty:
            raise RuntimeError("DB vazio/indisponivel")
        print(f"[INFO] Existing state loaded from DB. Last date: {df_existing.index[-1].date()}")
    except Exception as e:
        print(f"[WARN] DB load falhou ({e}); fallback para CSV.")
        df_existing = load_existing_csv()
    today = pd.Timestamp.now().normalize()
    fred = Fred(api_key=config.fred.api_key)

    if df_existing.empty:
        print("[MODE] First run. Downloading full history (2015)...")
        start_date = "2015-01-01"
        is_first_run = True
    else:
        last_date = df_existing.index[-1]
        if last_date >= today and 'risk_label' in df_existing.columns and pd.notna(df_existing.loc[today, 'risk_label']):
            print(f"[MODE] Today's data ({today.date()}) already complete. Updating intraday prices only...")
            start_date = None
            is_first_run = False
        else:
            print(f"[MODE] Updating daily data from {last_date.date()}...")
            start_date = (last_date - timedelta(days=5)).strftime('%Y-%m-%d')
            is_first_run = False

    df_daily_new = pd.DataFrame()
    if start_date:
        print("\n[Downloading Daily Data (FRED + Yahoo)]")
        all_series = []
        for name, sid in {**FRED_RORO, **FRED_EXTRA}.items():
            s = fetch_daily_series(name, "FRED", sid, start_date, fred)
            if not s.empty:
                all_series.append(s)

        for name, sym in YAHOO_RORO.items():
            s = fetch_daily_series(name, "YAHOO", sym, start_date, fred)
            if not s.empty:
                all_series.append(s)

        for name, sym in YAHOO_INTRADAY.items():
            s = fetch_daily_series(f"{name}_daily", "YAHOO", sym, start_date, fred)
            if not s.empty:
                all_series.append(s)

        for name, sid in FRED_PHILLIPS.items():
            s = fetch_daily_series(name, "FRED", sid, start_date, fred)
            if not s.empty:
                all_series.append(s)

        if all_series:
            df_daily_new = pd.concat(all_series, axis=1).sort_index()
            df_daily_new = df_daily_new.ffill(limit=3)

    if is_first_run or (not df_daily_new.empty and len(df_daily_new) > 2):
        print("\n[Processing RORO and Labels...]")

        if is_first_run:
            df_work = df_daily_new
        else:
            df_work = pd.concat([df_existing, df_daily_new])
            df_work = df_work[~df_work.index.duplicated(keep='last')]
            df_work = df_work.sort_index()

        roro_scores = compute_roro_for_new_data(df_work)

        # -- P1.2/P2: matriz v4 (CATEGORY_FACTORS) + sub-indices + PC1 global
        v4 = None
        v4_level_cols = [c for c in flattened_factors() if c in df_work.columns]
        if len(v4_level_cols) >= 3:
            try:
                v4 = build_roro_v4(df_work[v4_level_cols])
            except Exception as e:
                print(f"[V4] build_roro_v4 falhou (usa legacy): {e}")
                v4 = None
        if v4 is not None:
            for c in v4.columns:
                df_work[c] = v4[c]
            df_work['roro_v4_sentiment'] = roro_sentiment(df_work['roro_v4_z'])

        window_pct = 504
        roro_pct = roro_scores.rolling(window=window_pct, min_periods=100).rank(pct=True)

        conditions = [roro_pct >= 0.80, roro_pct <= 0.20]
        choices = ['RISK_OFF', 'RISK_ON']
        labels = pd.Series(np.select(conditions, choices, default='NEUTRAL'),
                           index=roro_scores.index)

        signal_strength = classify_signal_strength(roro_scores)

        df_work['roro_score'] = roro_scores.shift(1)
        df_work['risk_label'] = labels.shift(1)
        df_work['signal_strength'] = signal_strength.shift(1)
        df_work['global_risk_score'] = (1.0 - 2.0 * roro_pct).clip(-1.0, 1.0).shift(1)

        df_final = df_work
    else:
        print("\n[Fast Mode] Updating intraday prices only...")
        df_final = df_existing.copy()
        if 'signal_strength' not in df_final.columns:
            df_final['signal_strength'] = classify_signal_strength(
                df_final.get('roro_score', pd.Series(0, index=df_final.index)))
        if 'global_risk_score' not in df_final.columns:
            _roro = df_final.get('roro_score', pd.Series(0.0, index=df_final.index))
            _pct = _roro.rolling(window=504, min_periods=100).rank(pct=True)
            df_final['global_risk_score'] = (1.0 - 2.0 * _pct).clip(-1.0, 1.0)

    print("\n[Applying KCRORO primary signal (KC Fed)]")
    df_final = apply_kcroro_signal(df_final, fred)
    if 'roro_kcroro' in df_final.columns and df_final['roro_kcroro'].notna().any():
        last_kc = float(df_final['roro_kcroro'].dropna().iloc[-1])
        last_label = str(df_final['risk_label'].dropna().iloc[-1])
        log_event("kcroro", kc_level=last_kc, label=last_label, shadow=shadow)

    print("\n[Updating Intraday Prices (VIX, DXY)]")
    current_vix = fetch_yahoo_intraday("^VIX")
    current_dxy = fetch_yahoo_intraday("DX-Y.NYB")

    if today not in df_final.index:
        if not df_final.empty:
            last_row = df_final.iloc[-1]
            df_final.loc[today] = last_row
        else:
            df_final.loc[today] = np.nan

    if isinstance(current_vix, float) and not math.isnan(current_vix):
        df_final.loc[today, 'vix'] = current_vix

    if isinstance(current_dxy, float) and not math.isnan(current_dxy):
        df_final.loc[today, 'dxy'] = current_dxy

    if 'dxy' in df_final.columns:
        df_final['usd_index'] = df_final['dxy']

    # -- is_stale: 1 onde o dia NAO tem dado real (copiado/reindexado/feriado)
    real_index = set(df_final.index)
    all_bdays = pd.bdate_range(start=df_final.index.min(), end=today)
    df_final = df_final.reindex(all_bdays)
    df_final['is_stale'] = 0
    df_final.loc[~df_final.index.isin(real_index), 'is_stale'] = 1

    for col in ['yield_2y', 'yield_10y']:
        if col in df_final.columns:
            df_final[col] = df_final[col].ffill()

    df_final['risk_label'] = df_final['risk_label'].ffill()
    df_final['roro_score'] = df_final['roro_score'].ffill()
    df_final['signal_strength'] = df_final['signal_strength'].ffill()
    if 'global_risk_score' in df_final.columns:
        df_final['global_risk_score'] = df_final['global_risk_score'].ffill()
    if 'usd_index' in df_final.columns:
        df_final['usd_index'] = df_final['usd_index'].ffill()
    for col in ['yield_2y', 'yield_10y', 'vix', 'dxy'] + list(FRED_PHILLIPS.keys()):
        if col in df_final.columns:
            df_final[col] = df_final[col].ffill(limit=5)

    df_final = df_final.dropna(subset=['risk_label'])
    df_final.index.name = 'date'

    save_to_db(df_final, shadow=shadow)

    if do_export_csv:
        export_csv(df_final, OUTPUT_PATH)
        try:
            os.makedirs(os.path.dirname(COMMON_FILES), exist_ok=True)
            tmp_common = COMMON_FILES + '.tmp'
            with open(tmp_common, 'w', encoding='utf-8') as f:
                f.write(open(OUTPUT_PATH, 'r', encoding='utf-8').read())
            os.replace(tmp_common, COMMON_FILES)
            print(f"[CSV] Exportado para Common\\Files (tester): {COMMON_FILES}")
        except Exception as e:
            print(f"[WARN] Common\\Files CSV export failed: {e}")
        try:
            cal_src = r"C:\ALXQuant\data\mql5\Calendar.csv"
            cal_dst = r"C:\Users\User\AppData\Roaming\MetaQuotes\Terminal\Common\Files\Calendar.csv"
            if os.path.exists(cal_src):
                tmp_cal = cal_dst + '.tmp'
                with open(tmp_cal, 'w', encoding='utf-8-sig') as f:
                    f.write(open(cal_src, 'r', encoding='utf-8-sig').read())
                os.replace(tmp_cal, cal_dst)
                print(f"[CSV] Calendar.csv sincronizado para Common\\Files (tester): {cal_dst}")
            else:
                print("[WARN] Calendar.csv nao encontrado em data\\mql5; Common\\Files nao atualizado.")
        except Exception as e:
            print(f"[WARN] Calendar.csv Common sync failed: {e}")
    else:
        print("[CSV] Exportacao CSV suprimida (--no-csv)")

    print(f"\n[SUCCESS] DB updated successfully!")
    print(f"Last row: {df_final.tail(1).to_string()}")
    elapsed = time.time() - t0
    print(f"Execution time: {elapsed:.2f}s")

    try:
        last_row_summary = df_final.tail(1).to_dict(orient="records")[0]
        last_label = str(last_row_summary.get("risk_label", ""))
        last_goro = float(last_row_summary.get("global_risk_score", np.nan))
    except Exception:  # noqa: BLE001
        last_label, last_goro = "", np.nan
    log_event("run_end", ok=True, seconds=round(elapsed, 2),
              rows=int(len(df_final)), last_label=last_label,
              last_global_risk_score=last_goro, shadow=shadow,
              kcroro_primary=True)

    if args.log:
        try:
            os.makedirs(os.path.dirname(args.log) or ".", exist_ok=True)
            import json as _json
            _json.dump(dict(ts=datetime.now().isoformat(), ok=True, engine="risk_sentiment"),
                       open(args.log, "a", encoding="utf-8"))
            print(f"[LOG] Result appended to {args.log}")
        except Exception:
            pass


def _global_excepthook(exc_type, exc_value, exc_tb):
    msg = f"[CRASH] {exc_type.__name__}: {exc_value}"
    print(msg)
    import traceback
    traceback.print_exception(exc_type, exc_value, exc_tb)
    send_alert(msg)


sys.excepthook = _global_excepthook

if __name__ == "__main__":
    main()
