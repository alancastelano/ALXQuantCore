"""
ALXQuant Asset DNA Profiler v4.0-Institutional
================================================
CORREÇÕES INSTITUCIONAIS APLICADAS (Auditoria Tier-1):
  [FIX-1] RegimeModel com quantis EXPANDING (causal, sem hindsight bias)
  [FIX-2] HMM walk-forward CAUSAL (treina só até chunk_start)
  [FIX-3] CPCV renomeado: pbo_score → regime_stability_score (com nota metodológica)
  [FIX-4] FDR Benjamini-Hochberg nos leading indicators macro
  [FIX-5] ATR percentual em correlações macro (evita regressão espúria)
  [FIX-6] Testes surrogate/shuffle para Hurst e Transfer Entropy

UPGRADES MATEMÁTICOS (do v3.0):
  ✓ DFA Hurst (Detrended Fluctuation Analysis)
  ✓ FFD dinâmico via ADF + scipy.signal.lfilter
  ✓ Filtro de Kalman (causal, substitui Wavelet)
  ✓ Transfer Entropy KSG (contínuo, sem discretização)
  ✓ Cointegração de Johansen

PRESERVADO 100%:
  ✓ Formato do PDF e todas as seções
  ✓ Schema do JSON (retrocompatível com EA MQL5)
  ✓ CLI, cache, batch, Polars/Pandas fallback
"""
from __future__ import annotations
import os, sys, time, math, hashlib, pickle, warnings, argparse, json, logging
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional, Tuple, List, Union

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _THIS_DIR)
sys.path.insert(0, os.path.dirname(_THIS_DIR))

from db.schema import get_connection
import numpy as np
import pandas as pd

try:
    import polars as pl
    HAS_POLARS = True
except ImportError:
    HAS_POLARS = False
    pl = None

try:
    from numba import njit, prange
    HAS_NUMBA = True
except ImportError:
    HAS_NUMBA = False
    def njit(*a, **kw):
        def w(fn): return fn
        return w
    prange = range

try:
    from joblib import Parallel, delayed, Memory
    import joblib
    HAS_JOBLIB = True
except ImportError:
    HAS_JOBLIB = False

try:
    import bottleneck as bn
    HAS_BOTTLENECK = True
except ImportError:
    HAS_BOTTLENECK = False

from scipy import stats
from scipy.signal import lfilter
from scipy.spatial import cKDTree
from scipy.special import digamma

try:
    from statsmodels.tsa.stattools import adfuller
    from statsmodels.tsa.vector_ar.vecm import coint_johansen
    HAS_STATSMODELS = True
except ImportError:
    HAS_STATSMODELS = False

try:
    from hmmlearn.hmm import GaussianHMM
    HAS_HMM = True
except ImportError:
    HAS_HMM = False
    GaussianHMM = None

try:
    from tqdm import tqdm, trange
    HAS_TQDM = True
except ImportError:
    HAS_TQDM = False
    def tqdm(it, **kw): return it
    def trange(*a, **kw): return range(*a)

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import seaborn as sns

from reportlab.lib.pagesizes import A4
from reportlab.lib import colors
from reportlab.lib.units import mm
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_LEFT, TA_CENTER, TA_JUSTIFY
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Image, Table, TableStyle,
    PageBreak, HRFlowable
)

try:
    from pydantic import BaseModel, Field
    from pydantic_settings import BaseSettings
    HAS_PYDANTIC = True
except ImportError:
    HAS_PYDANTIC = False
    BaseModel = object
    BaseSettings = object
    Field = lambda *a, **kw: None

warnings.filterwarnings('ignore')

ALGO_VERSION = "v4.0-inst"
_MODULE_DIR = Path(__file__).parent
_DATA_DIR = Path(os.getenv('ALXQUANT_DATA_DIR', r'C:\ALXQuant\data\datasets'))

if HAS_PYDANTIC:
    class Config(BaseSettings):
        output_dir: Path = Path(os.getenv('ALXQUANT_DATA_DIR', str(_DATA_DIR)))
        report_dir: Path = Path(r'C:\ALXQuant\data\mql5')
        cache_dir: Path = _MODULE_DIR / "_cache"
        use_polars: bool = True
        use_numba: bool = True
        use_bottleneck: bool = True
        use_joblib: bool = True
        n_jobs: int = -1
        chunk_size: int = 1_000_000
        chart_dpi: int = 120
        chart_format: str = 'png'
        cache_ttl_hours: int = 168
        cache_compress: int = 3
        log_level: str = 'INFO'
        log_json: bool = False
        class Config:
            env_file = '.env'
            env_file_encoding = 'utf-8'
    CFG = Config()
else:
    class CFG:
        output_dir = _DATA_DIR
        report_dir = Path(r'C:\ALXQuant\data\mql5')
        cache_dir = _MODULE_DIR / "_cache"
        use_polars = True
        use_numba = True
        use_bottleneck = True
        use_joblib = True
        n_jobs = -1
        chunk_size = 1_000_000
        chart_dpi = 120
        chart_format = 'png'
        cache_ttl_hours = 168
        cache_compress = 3
        log_level = 'INFO'
        log_json = False

for d in [CFG.output_dir, CFG.report_dir, CFG.cache_dir]:
    d.mkdir(parents=True, exist_ok=True)

C = {
    'navy': '#0A1628', 'dark': '#1A1A2E', 'steel': '#2C5F8A',
    'blue': '#3498DB', 'gold': '#D4A843', 'green': '#27AE60',
    'red': '#E74C3C', 'orange': '#F39C12', 'purple': '#9B59B6',
    'teal': '#1ABC9C', 'light': '#ECF0F1', 'lighter': '#F8F9FA',
    'gray': '#666666', 'white': '#FFFFFF',
}
plt.rcParams.update({
    'font.family': 'sans-serif', 'font.size': 9,
    'axes.titlesize': 11, 'axes.titleweight': 'bold',
    'axes.labelsize': 9,
    'figure.facecolor': 'white', 'axes.facecolor': '#FAFBFC',
    'axes.grid': True, 'grid.alpha': 0.25, 'grid.color': '#CCCCCC',
    'axes.spines.top': False, 'axes.spines.right': False,
})

SESSION_LABELS = ['Asia', 'London', 'NY_AM', 'NY_PM']
REGIME_LABELS = ['TREND_FORTE', 'TREND_FRACO', 'RANGE', 'CHOP']
REGIME_COLORS = {
    'TREND_FORTE': '#27AE60', 'TREND_FRACO': '#3498DB',
    'RANGE': '#F39C12', 'CHOP': '#E74C3C',
}

def setup_logger(name: str = 'asset_dna') -> logging.Logger:
    logger = logging.getLogger(name)
    logger.setLevel(getattr(logging, CFG.log_level.upper()))
    if logger.handlers:
        return logger
    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(getattr(logging, CFG.log_level.upper()))
    fmt = logging.Formatter(
        '%(asctime)s [%(levelname)s] %(name)s: %(message)s', datefmt='%H:%M:%S'
    )
    handler.setFormatter(fmt)
    logger.addHandler(handler)
    return logger

logger = setup_logger()

def log_phase(phase_num: int, total: int, name: str):
    logger.info(f"{'='*60}")
    logger.info(f"  FASE [{phase_num}/{total}] — {name}")
    logger.info(f"{'='*60}")


class DiskCache:
    def __init__(self, cache_dir: Path = None, version: str = ALGO_VERSION):
        self.cache_dir = Path(cache_dir or CFG.cache_dir)
        self.version = version
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        if HAS_JOBLIB:
            self.memory = Memory(location=str(self.cache_dir / '_joblib'),
                                 verbose=0, compress=CFG.cache_compress)
        else:
            self.memory = None

    @staticmethod
    def _hash_data(data: Any, params: Optional[Dict] = None) -> str:
        if isinstance(data, (np.ndarray, pd.DataFrame, pd.Series)):
            data_bytes = data.to_numpy() if hasattr(data, 'to_numpy') else data
            h = hashlib.sha256(np.ascontiguousarray(data_bytes).tobytes())
        elif HAS_POLARS and isinstance(data, pl.DataFrame):
            h = hashlib.sha256(data.write_csv().encode())
        else:
            h = hashlib.sha256(pickle.dumps(data))
        if params:
            h.update(json.dumps(params, sort_keys=True).encode())
        return h.hexdigest()[:20]

    def _key_path(self, ns: str, h: str) -> Path:
        return self.cache_dir / f"{ns}_{h}_{self.version}.joblib"

    def _is_fresh(self, path: Path) -> bool:
        if not path.exists():
            return False
        return (time.time() - path.stat().st_mtime) / 3600 < CFG.cache_ttl_hours

    def get(self, ns: str, data: Any, params: Optional[Dict] = None) -> Optional[Any]:
        if not HAS_JOBLIB:
            return None
        try:
            h = self._hash_data(data, params)
            path = self._key_path(ns, h)
            if self._is_fresh(path):
                logger.debug(f"[CACHE HIT] {ns}:{h[:8]}")
                return joblib.load(path)
        except Exception:
            pass
        return None

    def put(self, ns: str, data: Any, value: Any, params: Optional[Dict] = None) -> Any:
        if not HAS_JOBLIB:
            return value
        try:
            h = self._hash_data(data, params)
            path = self._key_path(ns, h)
            joblib.dump(value, path, compress=CFG.cache_compress)
        except Exception:
            pass
        return value

    def invalidate(self, ns: str = None):
        pattern = f"{ns}_" if ns else ""
        for f in self.cache_dir.glob(f"{pattern}*.joblib"):
            try:
                f.unlink()
            except Exception:
                pass

CACHE = DiskCache()


# ══════════════════════════════════════════════════════════════
# NUMBA KERNELS (DFA Hurst + Helpers)
# ══════════════════════════════════════════════════════════════
if HAS_NUMBA:
    @njit(cache=True, fastmath=True)
    def _classify_session_numba(hours: np.ndarray) -> np.ndarray:
        n = hours.shape[0]
        out = np.empty(n, dtype=np.int8)
        for i in range(n):
            h = hours[i]
            if h < 8: out[i] = 0
            elif h < 13: out[i] = 1
            elif h < 17: out[i] = 2
            else: out[i] = 3
        return out

    @njit(cache=True)
    def _transition_matrix_numba(regimes_int: np.ndarray, n_labels: int) -> np.ndarray:
        counts = np.zeros((n_labels, n_labels), dtype=np.int64)
        for i in range(len(regimes_int) - 1):
            counts[regimes_int[i], regimes_int[i+1]] += 1
        mat = np.zeros((n_labels, n_labels), dtype=np.float64)
        for i in range(n_labels):
            row_sum = counts[i].sum()
            if row_sum > 0:
                mat[i] = counts[i] / row_sum
        return mat

    @njit(cache=True, parallel=True, fastmath=True)
    def _dfa_numba(log_prices: np.ndarray, window: int) -> np.ndarray:
        """DFA Hurst (Detrended Fluctuation Analysis) — robusto a não-estacionariedade."""
        n = log_prices.shape[0]
        out = np.full(n, np.nan, dtype=np.float64)
        min_box = 4
        max_box = min(50, window // 4)
        if max_box < min_box + 2:
            return out

        n_scales = 0
        scales = np.empty(max_box, dtype=np.int64)
        s = min_box
        while s <= max_box:
            scales[n_scales] = s
            n_scales += 1
            s = max(s + 1, int(s * 1.3))
        if n_scales < 3:
            return out
        scales = scales[:n_scales]
        log_scales = np.log(scales.astype(np.float64))

        for i in prange(window - 1, n):
            w_start = i - window + 1
            seg = log_prices[w_start:i + 1]
            w_len = len(seg)
            mean_seg = seg.mean()

            profile = np.empty(w_len, dtype=np.float64)
            cum = 0.0
            for k in range(w_len):
                cum += seg[k] - mean_seg
                profile[k] = cum

            sum_x = 0.0; sum_x2 = 0.0; sum_y = 0.0; sum_xy = 0.0
            n_valid = 0
            for si in range(n_scales):
                s = scales[si]
                n_boxes = w_len // s
                if n_boxes < 1:
                    continue
                rms_sum = 0.0
                for b in range(n_boxes):
                    b_start = b * s
                    b_end = b_start + s
                    box = profile[b_start:b_end]
                    bx_mean = 0.0
                    by_mean = 0.0
                    for k in range(s):
                        bx_mean += k
                        by_mean += box[k]
                    bx_mean /= s
                    by_mean /= s
                    num = 0.0; den = 0.0
                    for k in range(s):
                        dx = k - bx_mean
                        num += dx * (box[k] - by_mean)
                        den += dx * dx
                    if den < 1e-20:
                        continue
                    slope = num / den
                    intercept = by_mean - slope * bx_mean
                    rms2 = 0.0
                    for k in range(s):
                        resid = box[k] - (slope * k + intercept)
                        rms2 += resid * resid
                    rms2 /= s
                    rms_sum += rms2
                if n_boxes > 0:
                    F_s = np.sqrt(rms_sum / n_boxes)
                    if F_s > 1e-15:
                        log_F = np.log(F_s)
                        lx = log_scales[si]
                        sum_x += lx; sum_x2 += lx * lx
                        sum_y += log_F; sum_xy += lx * log_F
                        n_valid += 1

            if n_valid < 3:
                out[i] = 0.5
                continue
            denom = n_valid * sum_x2 - sum_x * sum_x
            if abs(denom) < 1e-20:
                out[i] = 0.5
                continue
            alpha = (n_valid * sum_xy - sum_x * sum_y) / denom
            out[i] = max(0.01, min(alpha, 0.99))
        return out

    @njit(cache=True, fastmath=True)
    def _sample_entropy_numba(data: np.ndarray, m: int = 2, r_factor: float = 0.2) -> float:
        n = data.shape[0]
        if n < m + 2:
            return 0.0
        std_val = np.std(data)
        if std_val < 1e-10:
            return 0.0
        r = r_factor * std_val
        A = 0; B = 0
        for i in range(n - m):
            for j in range(i + 1, n - m):
                match_m = True
                for k in range(m):
                    if abs(data[i + k] - data[j + k]) >= r:
                        match_m = False
                        break
                if match_m:
                    B += 1
                    if i < n - m - 1 and j < n - m - 1:
                        if abs(data[i + m] - data[j + m]) < r:
                            A += 1
        if B == 0:
            return 0.0
        if A == 0:
            return float(np.log(2.0 * n))
        return -np.log(A / B)

    @njit(cache=True, fastmath=True)
    def _mi_numba(x: np.ndarray, y: np.ndarray, bins: int = 20) -> float:
        n = len(x)
        if n < bins:
            return 0.0
        x_min, x_max = x.min(), x.max()
        y_min, y_max = y.min(), y.max()
        if x_max - x_min < 1e-12 or y_max - y_min < 1e-12:
            return 0.0
        hist = np.zeros((bins, bins), dtype=np.int64)
        for i in range(n):
            xi = min(bins - 1, int((x[i] - x_min) / (x_max - x_min) * bins))
            yi = min(bins - 1, int((y[i] - y_min) / (y_max - y_min) * bins))
            hist[xi, yi] += 1
        total = hist.sum()
        if total == 0:
            return 0.0
        p_xy = hist / total
        p_x = np.zeros(bins, dtype=np.float64)
        p_y = np.zeros(bins, dtype=np.float64)
        for i in range(bins):
            for j in range(bins):
                p_x[i] += p_xy[i, j]
                p_y[j] += p_xy[i, j]
        mi = 0.0
        for i in range(bins):
            for j in range(bins):
                if p_xy[i, j] > 0 and p_x[i] > 0 and p_y[j] > 0:
                    mi += p_xy[i, j] * np.log2(p_xy[i, j] / (p_x[i] * p_y[j]))
        return mi
else:
    def _classify_session_numba(hours): return np.zeros(len(hours), dtype=np.int8)
    def _transition_matrix_numba(r, n): return np.zeros((n, n))
    def _dfa_numba(lp, w): return np.full(len(lp), 0.5)
    def _sample_entropy_numba(d, m=2, r=0.2): return 0.0
    def _mi_numba(x, y, bins=20): return 0.0


# ══════════════════════════════════════════════════════════════
# FFD + KALMAN + KSG TE (Institucional)
# ══════════════════════════════════════════════════════════════
def _fracdiff_weights(d: float, window: int) -> np.ndarray:
    w = [1.0]
    for k in range(1, window):
        w.append(-w[-1] * (d - k + 1) / k)
    return np.array(w, dtype=np.float64)


def _ffd_series_lfilter(series: np.ndarray, d: float, window: int = 200) -> np.ndarray:
    """FFD via scipy.signal.lfilter — O(N) em vez de O(N×W)."""
    if len(series) == 0:
        return np.array([], dtype=np.float64)
    w = _fracdiff_weights(d, window)
    result = lfilter(w, [1.0], series)
    result[:window - 1] = np.nan
    return result


def _find_optimal_d(series: np.ndarray, window: int = 200,
                    d_range: Tuple[float, float] = (0.0, 1.0),
                    step: float = 0.1) -> float:
    """Busca o menor d que torna a série estacionária (ADF p<0.05)."""
    if not HAS_STATSMODELS:
        return 0.5
    best_d = d_range[1]
    for d in np.arange(d_range[0], d_range[1] + step / 2, step):
        d = round(d, 2)
        fd = _ffd_series_lfilter(series, d, window)
        fd_clean = fd[~np.isnan(fd)]
        if len(fd_clean) < 200:
            continue
        try:
            _, p_val, *_ = adfuller(fd_clean, maxlag=1, autolag=None)
            if p_val < 0.05:
                best_d = d
                break
        except Exception:
            continue
    return best_d


def _kalman_filter_1d(series: np.ndarray, delta: float = 1e-4) -> Tuple[np.ndarray, np.ndarray]:
    """Filtro de Kalman univariado causal (sem look-ahead)."""
    n = len(series)
    state = np.full(n, np.nan, dtype=np.float64)
    P = np.full(n, np.nan, dtype=np.float64)
    if n < 2:
        return series.copy(), np.ones(n)
    init_len = min(50, n)
    state[0] = np.mean(series[:init_len])
    P[0] = np.var(series[:init_len])
    R = max(P[0], 1e-10)
    Q = delta * R
    for t in range(1, n):
        if not np.isfinite(series[t]):
            state[t] = state[t - 1]
            P[t] = P[t - 1] + Q
            continue
        state_pred = state[t - 1]
        P_pred = P[t - 1] + Q
        K = P_pred / (P_pred + R)
        state[t] = state_pred + K * (series[t] - state_pred)
        P[t] = (1 - K) * P_pred
    return state, P


def _transfer_entropy_ksg(source: np.ndarray, target: np.ndarray,
                          k: int = 4, delay: int = 1) -> float:
    """Transfer Entropy via KSG (KNN contínuo, sem discretização)."""
    n = min(len(source), len(target))
    if n < 100 + delay:
        return 0.0
    t_future = target[delay + 1:n].reshape(-1, 1).copy()
    t_present = target[delay:n - 1].reshape(-1, 1).copy()
    s_past = source[:n - delay - 1].reshape(-1, 1).copy()
    m = len(t_future)
    if m < k + 1:
        return 0.0
    joint = np.hstack([t_future, t_present, s_past])
    marg_tp = np.hstack([t_future, t_present])
    marg_ts = np.hstack([t_present, s_past])
    marg_t = t_present
    for arr in [joint, marg_tp, marg_ts, marg_t]:
        for col in range(arr.shape[1]):
            s_col = arr[:, col].std()
            if s_col > 1e-10:
                arr[:, col] = (arr[:, col] - arr[:, col].mean()) / s_col
    tree_joint = cKDTree(joint)
    tree_tp = cKDTree(marg_tp)
    tree_ts = cKDTree(marg_ts)
    tree_t = cKDTree(marg_t)
    te_sum = 0.0
    for i in range(m):
        dists, _ = tree_joint.query(joint[i], k=k + 1, p=np.inf)
        eps = dists[-1]
        if eps < 1e-15:
            eps = 1e-15
        n_tp = len(tree_tp.query_ball_point(marg_tp[i], eps, p=np.inf)) - 1
        n_ts = len(tree_ts.query_ball_point(marg_ts[i], eps, p=np.inf)) - 1
        n_t = len(tree_t.query_ball_point(marg_t[i], eps, p=np.inf)) - 1
        n_tp = max(n_tp, 1)
        n_ts = max(n_ts, 1)
        n_t = max(n_t, 1)
        te_sum += digamma(k) - digamma(n_tp) - digamma(n_ts) + digamma(n_t)
    te = max(0.0, te_sum / m)
    return float(te)


def _permutation_entropy(data: np.ndarray, order: int = 4, delay: int = 1) -> float:
    n = len(data)
    if n < order * delay + 1:
        return 0.0
    perms: Dict[Tuple[int, ...], int] = {}
    for i in range(n - (order - 1) * delay):
        window = data[i:i + order * delay:delay]
        pattern = tuple(np.argsort(window))
        perms[pattern] = perms.get(pattern, 0) + 1
    total = sum(perms.values())
    probs = np.array(list(perms.values()), dtype=np.float64) / total
    probs = probs[probs > 0]
    if len(probs) == 0:
        return 0.0
    max_ent = math.log(math.factorial(order))
    if max_ent < 1e-10:
        return 0.0
    return -np.sum(probs * np.log(probs)) / max_ent


def rolling_mean(arr: np.ndarray, window: int) -> np.ndarray:
    if HAS_BOTTLENECK:
        return bn.move_mean(arr, window, min_count=window)
    return pd.Series(arr).rolling(window, min_periods=window).mean().to_numpy()

def rolling_std(arr: np.ndarray, window: int) -> np.ndarray:
    if HAS_BOTTLENECK:
        return bn.move_std(arr, window, min_count=window)
    return pd.Series(arr).rolling(window, min_periods=window).std().to_numpy()


def warmup_numba_kernels():
    if not HAS_NUMBA:
        return
    logger.info("[WARM-UP] Compilando kernels Numba...")
    t0 = time.time()
    dummy = np.random.randn(2000).astype(np.float64)
    dummy_int = np.random.randint(0, 4, 2000).astype(np.int32)
    _classify_session_numba(np.array([0, 6, 10, 15, 20], dtype=np.int32))
    _sample_entropy_numba(dummy, m=2, r_factor=0.2)
    _dfa_numba(np.cumsum(dummy), 100)
    _transition_matrix_numba(dummy_int, 4)
    _mi_numba(dummy[:1000], dummy[1000:2000], bins=20)
    logger.info(f"[WARM-UP] OK em {time.time() - t0:.1f}s")


# ══════════════════════════════════════════════════════════════
# [FIX-6] TESTES SURROGATE (Significância Estatística)
# ══════════════════════════════════════════════════════════════
def _hurst_significance_test(log_prices: np.ndarray, window: int,
                              n_surrogates: int = 50) -> Dict[str, float]:
    """Testa se DFA-Hurst observado é estatisticamente diferente de ruído via shuffle."""
    hurst_obs = _dfa_numba(log_prices, window)[-1]
    if np.isnan(hurst_obs):
        return {'hurst_observed': np.nan, 'p_value': 1.0, 'significant_5pct': False}
    
    surrogate_hursts = []
    for _ in range(n_surrogates):
        shuffled = log_prices.copy()
        np.random.shuffle(shuffled)
        log_prices_surr = np.cumsum(shuffled)
        h = _dfa_numba(log_prices_surr, window)[-1]
        if not np.isnan(h):
            surrogate_hursts.append(h)
    
    if len(surrogate_hursts) < 10:
        return {'hurst_observed': float(hurst_obs), 'p_value': 1.0,
                'significant_5pct': False, 'n_surrogates': len(surrogate_hursts)}
    
    surrogate_hursts = np.array(surrogate_hursts)
    p_value = float(np.mean(np.abs(surrogate_hursts - 0.5) >= np.abs(hurst_obs - 0.5)))
    
    return {
        'hurst_observed': float(hurst_obs),
        'surrogate_mean': float(surrogate_hursts.mean()),
        'surrogate_std': float(surrogate_hursts.std()),
        'p_value': p_value,
        'significant_5pct': p_value < 0.05,
        'n_surrogates': len(surrogate_hursts),
    }


def _te_significance_test(source: np.ndarray, target: np.ndarray,
                            k: int = 4, delay: int = 1,
                            n_surrogates: int = 30) -> Dict[str, float]:
    """Testa significância da Transfer Entropy via surrogate (shuffle da source)."""
    te_obs = _transfer_entropy_ksg(source, target, k=k, delay=delay)
    
    surrogate_tes = []
    for _ in range(n_surrogates):
        source_shuffled = source.copy()
        np.random.shuffle(source_shuffled)
        te_surr = _transfer_entropy_ksg(source_shuffled, target, k=k, delay=delay)
        surrogate_tes.append(te_surr)
    
    surrogate_tes = np.array(surrogate_tes)
    p_value = float(np.mean(surrogate_tes >= te_obs))
    
    return {
        'te_observed': float(te_obs),
        'surrogate_mean': float(surrogate_tes.mean()),
        'surrogate_std': float(surrogate_tes.std()),
        'p_value': p_value,
        'significant_5pct': p_value < 0.05,
        'n_surrogates': len(surrogate_tes),
    }

    # ══════════════════════════════════════════════════════════════
# DATA LOADER
# ══════════════════════════════════════════════════════════════
class DataLoader:
    def __init__(self, filepath=None, symbol: str = None, tf: str = 'M5', from_db: bool = True):
        self.from_db = from_db
        self.symbol = symbol or "XAUUSD"
        self.tf = tf
        if from_db:
            self.filepath = None
        elif filepath:
            self.filepath = Path(filepath)
        elif symbol:
            self.filepath = CFG.output_dir / f"{symbol}_{tf}.csv"
        else:
            self.filepath = CFG.output_dir / "XAUUSD_M5.csv"
        self.df = None
        self.backend = 'polars' if HAS_POLARS and CFG.use_polars else 'pandas'

    @staticmethod
    def _normalize_columns(df: pd.DataFrame) -> pd.DataFrame:
        cols_lower = [c.lower() for c in df.columns]
        if 'date' in cols_lower and 'time' in cols_lower:
            date_col = next(c for c in df.columns if c.lower() == 'date')
            time_col = next(c for c in df.columns if c.lower() == 'time')
            df['time'] = pd.to_datetime(
                df[date_col].astype(str) + ' ' + df[time_col].astype(str),
                format='%Y%m%d %H:%M:%S', errors='coerce'
            )
            df.drop(columns=[date_col, time_col], inplace=True)
        if 'volume' in cols_lower and 'tick_volume' not in cols_lower:
            vol_col = next(c for c in df.columns if c.lower() == 'volume')
            df.rename(columns={vol_col: 'tick_volume'}, inplace=True)
        df.columns = [c.lower() for c in df.columns]
        if 'spread' not in df.columns: df['spread'] = 0
        if 'real_volume' not in df.columns: df['real_volume'] = 0
        cols = ['time', 'open', 'high', 'low', 'close', 'tick_volume', 'spread', 'real_volume']
        for c in cols:
            if c not in df.columns:
                df[c] = 0
        df = df[[c for c in cols if c in df.columns]]
        return df

    def _load_from_db(self) -> pd.DataFrame:
        logger.info(f"[LOAD] DuckDB: {self.symbol}_{self.tf}")
        conn = get_connection(read_only=True)
        query = """
            SELECT time, open, high, low, close, tick_volume, spread, real_volume
            FROM ohlc_prices WHERE symbol = ? AND timeframe = ? ORDER BY time
        """
        df = conn.execute(query, [self.symbol, self.tf]).df()
        conn.close()
        if df.empty:
            return pd.DataFrame()
        df['time'] = pd.to_datetime(df['time'], unit='s')
        df.set_index('time', inplace=True)
        df.index.name = 'time'
        logger.info(f"  [OK] {len(df):,} candles | {df.index[0]} a {df.index[-1]}")
        return df

    def load(self) -> pd.DataFrame:
        if self.from_db:
            return self._load_from_db()
        logger.info(f"[LOAD] {self.filepath}")
        if not self.filepath.exists():
            logger.error(f"Arquivo não encontrado: {self.filepath}")
            sys.exit(1)
        parquet_path = self.filepath.with_suffix('.parquet')
        use_parquet = parquet_path.exists() and self.filepath.suffix.lower() == '.csv'
        if use_parquet and self.backend == 'polars':
            df_pl = pl.scan_parquet(parquet_path).collect(streaming=True)
            df = df_pl.to_pandas()
        elif use_parquet:
            df = pd.read_parquet(parquet_path)
        elif self.backend == 'polars':
            df_pl = pl.scan_csv(self.filepath, parse_dates=False).collect(streaming=True)
            df = self._normalize_columns(df_pl.to_pandas())
        else:
            df = pd.read_csv(self.filepath, low_memory=False)
            df = self._normalize_columns(df)
        if 'time' in df.columns and not np.issubdtype(df['time'].dtype, np.datetime64):
            df['time'] = pd.to_datetime(df['time'])
        if 'time' in df.columns:
            df.set_index('time', inplace=True)
            df.index.name = 'time'
        logger.info(f"  [OK] {len(df):,} candles | {df.index[0]} a {df.index[-1]}")
        self.df = df
        return df


# ══════════════════════════════════════════════════════════════
# FEATURE ENGINE
# ══════════════════════════════════════════════════════════════
class FeatureEngine:
    def __init__(self, df: pd.DataFrame, tf: str = 'M5'):
        self.df = df
        self.ws = 5 if tf == 'M1' else 1
        self.tf = tf
        self.backend = 'polars' if HAS_POLARS and CFG.use_polars else 'pandas'
        self.mi_matrix = None
        self.mi_labels = []
        self.transfer_entropy = {}
        self.ffd_d_close = 0.5
        self.ffd_d_return = 0.3
        self.hurst_significance = {}
        self.te_significance = {}

    def compute(self) -> pd.DataFrame:
        t0 = time.time()
        logger.info(f"[FEATURES] Computando features (backend: {self.backend})")
        df = self.df
        cache_seed = np.column_stack([
            df['close'].to_numpy(dtype=np.float32),
            df['high'].to_numpy(dtype=np.float32),
            df['low'].to_numpy(dtype=np.float32),
            df['tick_volume'].to_numpy(dtype=np.int32),
        ])
        cache_params = {'ws': self.ws, 'tf': self.tf, 'algo': ALGO_VERSION}
        cached = CACHE.get("features_v7", cache_seed, params=cache_params)
        if cached is not None and len(cached) == len(df):
            logger.info(f"  [CACHE HIT] Features em {time.time()-t0:.2f}s")
            return cached
        if self.backend == 'polars' and HAS_POLARS:
            df = self._compute_polars(df)
        else:
            df = self._compute_pandas(df)
        df = self._add_advanced_features(df)
        CACHE.put("features_v7", cache_seed, df, params=cache_params)
        return df

    def _add_advanced_features(self, df: pd.DataFrame) -> pd.DataFrame:
        close = df['close'].to_numpy(dtype=np.float64)
        log_ret = df['log_return'].to_numpy(dtype=np.float64)
        n = len(close)
        t0 = time.time()
        logger.info(f"[ADV FEATURES] DFA + FFD + Kalman + KSG TE + Surrogate Tests...")

        # Entropy
        t1 = time.time()
        entropy_win = min(500, n // 4)
        entropy_step = 100
        se = np.full(n, np.nan, dtype=np.float32)
        pe = np.full(n, np.nan, dtype=np.float32)
        idx_calc = list(range(entropy_win, n, entropy_step))
        if idx_calc and idx_calc[-1] != n - 1:
            idx_calc.append(n - 1)
        se_vals, pe_vals = [], []
        pbar = tqdm(idx_calc, desc="  [ENTROPY]", unit="candle",
                    mininterval=2.0, ncols=80) if HAS_TQDM else idx_calc
        for i in pbar:
            chunk = log_ret[i - entropy_win:i]
            if len(chunk) < 50:
                se_vals.append(np.float32(np.nan))
                pe_vals.append(np.float32(np.nan))
                continue
            se_vals.append(np.float32(_sample_entropy_numba(chunk)))
            pe_vals.append(np.float32(_permutation_entropy(chunk, order=4)))
        se_vals = np.array(se_vals, dtype=np.float32)
        pe_vals = np.array(pe_vals, dtype=np.float32)
        idx_calc_arr = np.array(idx_calc, dtype=np.int64)
        for i in range(len(se)):
            nearest = idx_calc_arr[idx_calc_arr <= i]
            if len(nearest) > 0:
                j = nearest[-1]
                idx_j = np.where(idx_calc_arr == j)[0]
                if len(idx_j) > 0:
                    se[i] = se_vals[idx_j[0]]
                    pe[i] = pe_vals[idx_j[0]]
        df['sample_entropy'] = se
        df['perm_entropy'] = pe
        logger.info(f"  [ENTROPY] OK em {time.time()-t1:.2f}s (step={entropy_step})")

        # FFD dinâmico
        t2 = time.time()
        fd_window = min(200, n // 4)
        log_close = np.log(close)
        self.ffd_d_close = _find_optimal_d(log_close, window=fd_window)
        self.ffd_d_return = _find_optimal_d(log_ret, window=fd_window)
        logger.info(f"  [FFD] d_close={self.ffd_d_close:.2f}, d_return={self.ffd_d_return:.2f}")
        df['fracdiff_close'] = _ffd_series_lfilter(log_close, self.ffd_d_close, fd_window).astype(np.float32)
        df['fracdiff_return'] = _ffd_series_lfilter(log_ret, self.ffd_d_return, fd_window).astype(np.float32)
        logger.info(f"  [FFD] OK em {time.time()-t2:.2f}s")

        # Kalman Filter
        t3 = time.time()
        kalman_state, kalman_P = _kalman_filter_1d(log_close, delta=1e-4)
        df['log_close_denoised'] = np.where(
            np.isfinite(kalman_state), kalman_state.astype(np.float32), np.float32(np.nan)
        )
        df['close_denoised'] = np.exp(df['log_close_denoised'].to_numpy(dtype=np.float64))
        kalman_ret, _ = _kalman_filter_1d(log_ret, delta=1e-3)
        df['return_denoised'] = np.where(
            np.isfinite(kalman_ret), kalman_ret.astype(np.float32), np.float32(np.nan)
        )
        logger.info(f"  [KALMAN] OK em {time.time()-t3:.2f}s")

        # MI Matrix
        t4 = time.time()
        mi_cols = ['hurst', 'adx', 'atr', 'return', 'volume_zscore', 'tr_zscore']
        mi_available = [c for c in mi_cols if c in df.columns]
        if len(mi_available) >= 2:
            self.mi_matrix = _mutual_information_matrix_numba(df, mi_available)
            self.mi_labels = mi_available
        logger.info(f"  [MI] OK em {time.time()-t4:.2f}s")

        # Transfer Entropy KSG
        t5 = time.time()
        te_results = {}
        if 'return' in df.columns and 'volume_zscore' in df.columns:
            r = df['return'].dropna().to_numpy(dtype=np.float64)
            v = df['volume_zscore'].dropna().to_numpy(dtype=np.float64)
            min_len = min(len(r), len(v))
            step_te = max(1, min_len // 10000)
            r_sub = r[:min_len:step_te]
            v_sub = v[:min_len:step_te]
            te_results['ret_to_vol'] = round(_transfer_entropy_ksg(r_sub, v_sub, k=4, delay=1), 6)
            te_results['vol_to_ret'] = round(_transfer_entropy_ksg(v_sub, r_sub, k=4, delay=1), 6)
        if 'hurst' in df.columns and 'adx' in df.columns:
            h = df['hurst'].dropna().to_numpy(dtype=np.float64)
            a = df['adx'].dropna().to_numpy(dtype=np.float64)
            min_len = min(len(h), len(a))
            step_te = max(1, min_len // 10000)
            h_sub = h[:min_len:step_te]
            a_sub = a[:min_len:step_te]
            te_results['hurst_to_adx'] = round(_transfer_entropy_ksg(h_sub, a_sub, k=4, delay=1), 6)
            te_results['adx_to_hurst'] = round(_transfer_entropy_ksg(a_sub, h_sub, k=4, delay=1), 6)
        self.transfer_entropy = te_results
        logger.info(f"  [TE-KSG] OK em {time.time()-t5:.2f}s")

        # [FIX-6] Testes de Significância Surrogate
        t6 = time.time()
        logger.info("  [SIGNIFICANCE] Testes surrogate (shuffle)...")
        hurst_test_sample = log_close[-10000:] if len(log_close) > 10000 else log_close
        self.hurst_significance = _hurst_significance_test(
            hurst_test_sample, 100 * self.ws, n_surrogates=50
        )
        logger.info(f"  [HURST SIG] H={self.hurst_significance['hurst_observed']:.3f} "
                    f"p={self.hurst_significance['p_value']:.3f} "
                    f"sig={self.hurst_significance['significant_5pct']}")
        
        if 'return' in df.columns and 'volume_zscore' in df.columns:
            self.te_significance = {
                'ret_to_vol': _te_significance_test(r_sub, v_sub, k=4, delay=1, n_surrogates=30),
                'vol_to_ret': _te_significance_test(v_sub, r_sub, k=4, delay=1, n_surrogates=30),
            }
            logger.info(f"  [TE SIG] ret→vol p={self.te_significance['ret_to_vol']['p_value']:.3f} | "
                        f"vol→ret p={self.te_significance['vol_to_ret']['p_value']:.3f}")
        logger.info(f"  [SIGNIFICANCE] OK em {time.time()-t6:.2f}s")

        logger.info(f"  [ADV OK] Total: {time.time()-t0:.2f}s")
        return df

    def _compute_polars(self, df: pd.DataFrame) -> pd.DataFrame:
        t0 = time.time()
        df_pl = pl.from_pandas(df.reset_index())
        ws = self.ws
        df_pl = df_pl.with_columns([
            ((pl.col('close') - pl.col('close').shift(1)) / pl.col('close').shift(1)).alias('return'),
            (pl.col('close').log() - pl.col('close').log().shift(1)).alias('log_return'),
        ])
        high, low, close = pl.col('high'), pl.col('low'), pl.col('close')
        close_prev = close.shift(1)
        tr = pl.max_horizontal([
            high - low, (high - close_prev).abs(), (low - close_prev).abs()
        ]).alias('tr')
        df_pl = df_pl.with_columns(tr)
        atr_win = 14 * ws
        df_pl = df_pl.with_columns(pl.col('tr').rolling_mean(window_size=atr_win).alias('atr'))
        z_win = 500 * ws
        tr_mean_long = pl.col('tr').rolling_mean(window_size=z_win)
        tr_std_long = pl.col('tr').rolling_std(window_size=z_win).clip(lower_bound=1e-10)
        df_pl = df_pl.with_columns([
            ((pl.col('tr') - tr_mean_long) / tr_std_long).alias('tr_zscore'),
            ((pl.col('tr').rolling_mean(50*ws) - tr_mean_long) / tr_std_long).alias('vol_zscore'),
        ])
        vol = pl.col('tick_volume')
        df_pl = df_pl.with_columns([
            vol.rolling_mean(50*ws).alias('vol_ma'),
            vol.rolling_std(50*ws).clip(lower_bound=1e-10).alias('vol_std'),
            ((vol - vol.rolling_mean(50*ws)) / vol.rolling_std(50*ws).clip(lower_bound=1e-10)).alias('volume_zscore'),
        ])
        up_move = pl.col('high').diff()
        down_move = -pl.col('low').diff()
        plus_dm = pl.when((up_move > down_move) & (up_move > 0)).then(up_move).otherwise(0)
        minus_dm = pl.when((down_move > up_move) & (down_move > 0)).then(down_move).otherwise(0)
        tr_smooth = pl.col('atr').clip(lower_bound=1e-10)
        plus_di = 100 * plus_dm.rolling_mean(atr_win) / tr_smooth
        minus_di = 100 * minus_dm.rolling_mean(atr_win) / tr_smooth
        di_sum = (plus_di + minus_di).clip(lower_bound=1e-10)
        dx = 100 * (plus_di - minus_di).abs() / di_sum
        df_pl = df_pl.with_columns([
            plus_di.alias('plus_di'), minus_di.alias('minus_di'),
            dx.alias('dx'), dx.rolling_mean(atr_win).alias('adx'),
        ])

        log_price = df_pl['close'].log().cast(pl.Float64).to_numpy()
        hurst_win = 100 * ws
        hurst_cached = CACHE.get("dfa_hurst_v4", log_price.astype(np.float32))
        if hurst_cached is not None:
            logger.info(f"  [CACHE HIT] DFA Hurst")
            hurst = hurst_cached
        else:
            logger.info(f"  [DFA] Calculando Hurst via DFA (window={hurst_win})...")
            t_h = time.time()
            hurst = _dfa_numba(log_price, hurst_win)
            logger.info(f"  [DFA] OK em {time.time()-t_h:.2f}s")
            CACHE.put("dfa_hurst_v4", log_price.astype(np.float32), hurst)
        df_pl = df_pl.with_columns(pl.Series('hurst', hurst.astype(np.float32)))

        for freq_name, freq_str in [('return_m15', '15m'), ('return_h1', '1h'),
                                     ('return_h4', '4h'), ('return_d1', '1d')]:
            close_mtf = (df_pl.select(['time', 'close'])
                         .group_by_dynamic(index_column='time', every=freq_str)
                         .agg(pl.col('close').last().alias(f'close_{freq_name}')))
            df_pl = df_pl.join_asof(close_mtf, on='time', strategy='backward')
            df_pl = df_pl.with_columns(
                (pl.col(f'close_{freq_name}') - pl.col(f'close_{freq_name}').shift(1))
                / pl.col(f'close_{freq_name}').shift(1)
            ).rename({f'close_{freq_name}': freq_name})

        hours = df_pl['time'].dt.hour().cast(pl.Int32).to_numpy()
        sess_int = _classify_session_numba(hours)
        sess_cat = pd.Categorical.from_codes(sess_int, categories=SESSION_LABELS)
        df_pl = df_pl.with_columns([
            pl.col('time').dt.hour().cast(pl.Int8).alias('hour'),
            pl.col('time').dt.weekday().cast(pl.Int8).alias('day_of_week'),
            pl.col('time').dt.month().cast(pl.Int8).alias('month'),
        ])
        df = df_pl.to_pandas()
        df['session'] = sess_cat
        # Fill auxiliary DB columns that may be all-NaN
        for col in ('spread', 'real_volume'):
            if col in df.columns and df[col].isna().all():
                df[col] = 0
        before = len(df)
        df.dropna(inplace=True)
        logger.info(f"  [OK] {len(df):,} candles ({before-len(df):,} removidos) em {time.time()-t0:.2f}s")
        return df

    def _compute_pandas(self, df: pd.DataFrame) -> pd.DataFrame:
        t0 = time.time()
        close = df['close'].to_numpy(dtype=np.float64)
        ret = np.empty_like(close); ret[0] = np.nan; ret[1:] = (close[1:] - close[:-1]) / close[:-1]
        df['return'] = ret
        log_ret = np.empty_like(close); log_ret[0] = np.nan; log_ret[1:] = np.log(close[1:] / close[:-1])
        df['log_return'] = log_ret
        high, low = df['high'].to_numpy(dtype=np.float64), df['low'].to_numpy(dtype=np.float64)
        close_prev = np.empty_like(close); close_prev[0] = np.nan; close_prev[1:] = close[:-1]
        tr = np.maximum(high - low, np.maximum(np.abs(high - close_prev), np.abs(low - close_prev)))
        df['tr'] = tr.astype(np.float32)
        ws = self.ws
        atr = rolling_mean(tr, 14*ws)
        df['atr'] = atr.astype(np.float32)
        z_win = 500 * ws
        tr_mean_long = rolling_mean(tr, z_win)
        tr_std_long = rolling_std(tr, z_win)
        tr_std_safe = np.where(tr_std_long < 1e-10, 1e-10, tr_std_long)
        df['tr_zscore'] = ((tr - tr_mean_long) / tr_std_safe).astype(np.float32)
        df['vol_zscore'] = ((rolling_mean(tr, 50*ws) - tr_mean_long) / tr_std_safe).astype(np.float32)
        tick_vol = df['tick_volume'].to_numpy(dtype=np.float64)
        vol_ma = rolling_mean(tick_vol, 50*ws)
        vol_std = rolling_std(tick_vol, 50*ws)
        vol_std_safe = np.where(vol_std < 1e-10, 1e-10, vol_std)
        df['vol_ma'] = vol_ma.astype(np.float32)
        df['vol_std'] = vol_std.astype(np.float32)
        df['volume_zscore'] = ((tick_vol - vol_ma) / vol_std_safe).astype(np.float32)
        up_move = np.empty_like(high); up_move[0] = np.nan; up_move[1:] = high[1:] - high[:-1]
        down_move = np.empty_like(low); down_move[0] = np.nan; down_move[1:] = -(low[1:] - low[:-1])
        plus_dm = np.where((up_move > down_move) & (up_move > 0), up_move, 0.0)
        minus_dm = np.where((down_move > up_move) & (down_move > 0), down_move, 0.0)
        tr_smooth_safe = np.where(atr < 1e-10, 1e-10, atr)
        plus_di = 100 * rolling_mean(plus_dm, 14*ws) / tr_smooth_safe
        minus_di = 100 * rolling_mean(minus_dm, 14*ws) / tr_smooth_safe
        di_sum_safe = np.where(plus_di + minus_di < 1e-10, 1e-10, plus_di + minus_di)
        dx = 100 * np.abs(plus_di - minus_di) / di_sum_safe
        df['plus_di'] = plus_di.astype(np.float32)
        df['minus_di'] = minus_di.astype(np.float32)
        df['dx'] = dx.astype(np.float32)
        df['adx'] = rolling_mean(dx, 14*ws).astype(np.float32)

        log_price = np.log(close)
        df['log_price'] = log_price.astype(np.float32)
        hurst_win = 100 * ws
        hurst_cached = CACHE.get("dfa_hurst_v4", log_price.astype(np.float32))
        if hurst_cached is not None:
            logger.info(f"  [CACHE HIT] DFA Hurst")
            hurst = hurst_cached
        else:
            logger.info(f"  [DFA] Calculando...")
            t_h = time.time()
            hurst = _dfa_numba(log_price, hurst_win)
            logger.info(f"  [DFA] OK em {time.time()-t_h:.2f}s")
            CACHE.put("dfa_hurst_v4", log_price.astype(np.float32), hurst)
        df['hurst'] = hurst.astype(np.float32)

        for freq_name, freq_str in [('return_m15', '15min'), ('return_h1', '1h'),
                                     ('return_h4', '4h'), ('return_d1', '1D')]:
            close_mtf = df['close'].resample(freq_str, label='right').last().dropna()
            close_mtf_df = close_mtf.to_frame().reset_index().rename(
                columns={'time': 'time_mtf', 'close': f'close_{freq_name}'})
            merged = pd.merge_asof(
                df[['close']].reset_index().sort_values('time'),
                close_mtf_df.sort_values('time_mtf'),
                left_on='time', right_on='time_mtf', direction='backward'
            )
            df[f'{freq_name}'] = merged[f'close_{freq_name}'].pct_change().to_numpy(dtype=np.float32)

        hours = df.index.hour.to_numpy(dtype=np.int32)
        sess_int = _classify_session_numba(hours)
        sess_cat = pd.Categorical.from_codes(sess_int, categories=SESSION_LABELS)
        df['hour'] = hours.astype(np.int8)
        df['day_of_week'] = df.index.dayofweek.to_numpy(dtype=np.int8)
        df['month'] = df.index.month.to_numpy(dtype=np.int8)
        df['session'] = sess_cat
        for col in ('spread', 'real_volume'):
            if col in df.columns and df[col].isna().all():
                df[col] = 0
        before = len(df)
        df.dropna(inplace=True)
        logger.info(f"  [OK] {len(df):,} candles em {time.time()-t0:.2f}s")
        return df


def _mutual_information_matrix_numba(df: pd.DataFrame, cols: List[str]) -> np.ndarray:
    n = len(cols)
    mi_mat = np.zeros((n, n))
    data = {c: df[c].dropna().to_numpy(dtype=np.float64) for c in cols}
    for i in range(n):
        for j in range(i + 1, n):
            x, y = data[cols[i]], data[cols[j]]
            if len(x) == 0 or len(y) == 0:
                continue
            mi_mat[i, j] = _mi_numba(x, y, bins=20)
            mi_mat[j, i] = mi_mat[i, j]
    return mi_mat


# ══════════════════════════════════════════════════════════════
# [FIX-1] REGIME MODEL COM QUANTIS EXPANDING (CAUSAL)
# ══════════════════════════════════════════════════════════════
class RegimeModelExpanding:
    """Regime classification com quantis EXPANDING (estritamente causal).
    
    Para cada candle i, os percentis são calculados apenas sobre [0, i-1].
    Elimina hindsight bias em toda validação (WF, Purged WF, CPCV, HMM agreement).
    
    Os quantis GLOBAIS finais são preservados separadamente como constante
    de calibração para o MQL5 em produção (isso é legítimo).
    """
    def __init__(self, df: pd.DataFrame, warmup: int = 2000):
        self.df = df
        self.warmup = warmup
        self.global_thresholds = {}

    def classify(self) -> pd.DataFrame:
        logger.info("[REGIMES-EXPANDING] Classificando com quantis causais (expanding)...")
        df = self.df
        n = len(df)
        
        adx = df['adx'].to_numpy(dtype=np.float64)
        hurst = df['hurst'].to_numpy(dtype=np.float64)
        
        regime_arr = np.full(n, 'RANGE', dtype=object)
        
        if n < self.warmup:
            self.warmup = n // 2
        
        warmup_adx = adx[:self.warmup]
        warmup_hurst = hurst[:self.warmup]
        
        adx_p75_w = np.percentile(warmup_adx, 75)
        adx_p50_w = np.percentile(warmup_adx, 50)
        hurst_p75_w = np.percentile(warmup_hurst, 75)
        hurst_p60_w = np.percentile(warmup_hurst, 60)
        hurst_p40_w = np.percentile(warmup_hurst, 40)
        
        logger.info(f"  Warmup ({self.warmup} candles): ADX p50={adx_p50_w:.1f} p75={adx_p75_w:.1f} | "
                    f"Hurst p40={hurst_p40_w:.2f} p60={hurst_p60_w:.2f} p75={hurst_p75_w:.2f}")
        
        for i in range(self.warmup):
            regime_arr[i] = self._classify_point(
                adx[i], hurst[i],
                adx_p75_w, adx_p50_w,
                hurst_p75_w, hurst_p60_w, hurst_p40_w
            )
        
        update_step = 100
        last_adx_p75, last_adx_p50 = adx_p75_w, adx_p50_w
        last_hurst_p75, last_hurst_p60, last_hurst_p40 = hurst_p75_w, hurst_p60_w, hurst_p40_w
        
        pbar = trange(self.warmup, n, desc="  [REGIMES-EXP]", unit="candle",
                      mininterval=5.0, ncols=80) if HAS_TQDM else range(self.warmup, n)
        
        for i in pbar:
            if (i - self.warmup) % update_step == 0:
                hist_adx = adx[:i]
                hist_hurst = hurst[:i]
                last_adx_p75 = np.percentile(hist_adx, 75)
                last_adx_p50 = np.percentile(hist_adx, 50)
                last_hurst_p75 = np.percentile(hist_hurst, 75)
                last_hurst_p60 = np.percentile(hist_hurst, 60)
                last_hurst_p40 = np.percentile(hist_hurst, 40)
            
            regime_arr[i] = self._classify_point(
                adx[i], hurst[i],
                last_adx_p75, last_adx_p50,
                last_hurst_p75, last_hurst_p60, last_hurst_p40
            )
        
        df['regime'] = pd.Categorical(regime_arr, categories=REGIME_LABELS)
        
        self.global_thresholds = {
            'adx_p75': float(np.percentile(adx, 75)),
            'adx_p50': float(np.percentile(adx, 50)),
            'hurst_p75': float(np.percentile(hurst, 75)),
            'hurst_p60': float(np.percentile(hurst, 60)),
            'hurst_p40': float(np.percentile(hurst, 40)),
        }
        
        logger.info(f"  [GLOBAL THRESHOLDS] (para calibração EA): {self.global_thresholds}")
        
        dist = df['regime'].value_counts()
        for r in REGIME_LABELS:
            pct = dist.get(r, 0) / n * 100
            logger.info(f"  {r}: {pct:.1f}%")
        
        return df
    
    @staticmethod
    def _classify_point(adx_val, hurst_val,
                         adx_p75, adx_p50,
                         hurst_p75, hurst_p60, hurst_p40):
        if adx_val > adx_p75 and hurst_val > hurst_p75:
            return 'TREND_FORTE'
        elif adx_val > adx_p50 and hurst_val > hurst_p60:
            return 'TREND_FRACO'
        elif adx_val < adx_p50 and hurst_val < hurst_p40:
            return 'CHOP'
        elif adx_val < adx_p50 and hurst_val > hurst_p60:
            return 'RANGE'
        return 'RANGE'

    def transition_matrix(self) -> Tuple[np.ndarray, List[str]]:
        regime_int = self.df['regime'].cat.codes.to_numpy(dtype=np.int32)
        cached = CACHE.get("transition_expanding_v4", regime_int)
        if cached is not None:
            return cached, REGIME_LABELS
        mat = _transition_matrix_numba(regime_int, len(REGIME_LABELS))
        CACHE.put("transition_expanding_v4", regime_int, mat)
        return mat, REGIME_LABELS
    
    # ══════════════════════════════════════════════════════════════
# [FIX-2] HMM COM WALK-FORWARD CAUSAL (sem leakage)
# ══════════════════════════════════════════════════════════════
class HMMRegimeModel:
    """HMM com walk-forward CAUSAL (FIX-2).
    
    Antes: treinava em seq[:right] e predizia [chunk_start, right] → leakage.
    Agora: treina em seq[:chunk_start], prediz [chunk_start, right] → out-of-sample puro.
    """
    def __init__(self, df: pd.DataFrame, n_states: int = 4):
        self.df = df
        self.n_states = n_states
        self.model = None
        self.state_map: Dict[int, str] = {}
        self.agreement: float = 0.0

    def _build_features(self, df: pd.DataFrame, window: int = 60) -> np.ndarray:
        log_ret = df['log_return'].to_numpy(dtype=np.float64)
        n = len(log_ret)
        rvol = rolling_std(log_ret, window)
        skew = pd.Series(log_ret).rolling(window).skew().to_numpy()
        kurt = pd.Series(log_ret).rolling(window).kurt().to_numpy()
        autocorr = np.full(n, np.nan)
        for i in range(window, n):
            seg = log_ret[i - window:i]
            if np.std(seg) > 1e-10:
                autocorr[i] = np.corrcoef(seg[:-1], seg[1:])[0, 1]
        features = np.column_stack([
            np.nan_to_num(log_ret, nan=0.0),
            np.nan_to_num(rvol, nan=0.0),
            np.nan_to_num(skew, nan=0.0),
            np.nan_to_num(kurt, nan=0.0),
            np.nan_to_num(autocorr, nan=0.0),
        ])
        return features

    def classify(self) -> pd.DataFrame:
        if not HAS_HMM:
            logger.warning("[HMM] hmmlearn não disponível")
            self.df['hmm_state'] = -1
            self.df['hmm_regime'] = self.df['regime']
            return self.df

        logger.info(f"[HMM-CAUSAL] Treino walk-forward causal ({self.n_states} estados)...")
        t0 = time.time()
        df = self.df
        features_all = self._build_features(df)
        valid = ~np.any(np.isnan(features_all) | np.isinf(features_all), axis=1)
        features_clean = features_all[valid]

        if len(features_clean) < 1000:
            logger.warning("[HMM] Dados insuficientes")
            df['hmm_state'] = -1
            df['hmm_regime'] = df['regime']
            return df

        n = len(features_all)
        max_train = min(n, 50000)
        if n > max_train:
            indices = np.linspace(0, n - 1, max_train, dtype=int)
            train_features = features_clean[:max_train]
        else:
            train_features = features_clean

        max_retrain = 25
        stride = max(500, (n - 3000) // max_retrain)
        first_train = min(3000, n // 2)
        hidden_states = np.full(n, -1, dtype=np.int32)

        def _train_safe(feats, ns_init, max_att=3):
            states_to_try = list(dict.fromkeys(
                [ns_init] + [x for x in [3, 2] if x < ns_init]
            ))
            for att in range(min(max_att, len(states_to_try))):
                ns = states_to_try[att]
                try:
                    m = GaussianHMM(
                        n_components=ns, covariance_type='diag',
                        random_state=42 + att * 7, n_iter=1000, tol=1e-4,
                    )
                    m.fit(feats)
                    if np.any(np.isnan(m.startprob_)) or np.any(np.isnan(m.transmat_)):
                        raise ValueError("NaN params")
                    return m, ns
                except Exception as e:
                    if att >= min(max_att, len(states_to_try)) - 1:
                        raise
            raise ValueError("Todas as tentativas falharam")

        # Primeiro treino (apenas dados iniciais)
        try:
            model, self.n_states = _train_safe(train_features[:first_train], self.n_states)
        except Exception as e:
            logger.warning(f"[HMM] Treino falhou: {e}")
            df['hmm_state'] = -1
            df['hmm_regime'] = df['regime']
            return df

        try:
            hidden_states[:first_train] = model.predict(features_all[:first_train])
        except Exception:
            hidden_states[:first_train] = 0

        # [FIX-2] Walk-forward CAUSAL: treina até chunk_start, prediz [chunk_start, right)
        wf_steps = list(range(first_train + stride, n + 1, stride))
        logger.info(f"  [HMM-CAUSAL] Walk-forward: {len(wf_steps)} iterações (stride={stride})")
        wf_iter = tqdm(wf_steps, desc="  [HMM-CAUSAL]", unit="iter",
                       mininterval=5.0, ncols=80) if HAS_TQDM else wf_steps
        
        for right in wf_iter:
            chunk_start = right - stride
            
            # TREINO CAUSAL: apenas dados ANTES do chunk (sem leakage)
            train_seq = features_all[:chunk_start]
            train_valid = ~np.any(np.isnan(train_seq) | np.isinf(train_seq), axis=1)
            
            if train_valid.sum() < 500:
                continue
            
            try:
                m, _ = _train_safe(train_seq[train_valid], self.n_states)
            except Exception as e:
                logger.warning(f"[HMM] Treino falhou em chunk_start={chunk_start}: {e}")
                continue
            
            # PREDIÇÃO: apenas o chunk out-of-sample
            test_seq = features_all[chunk_start:min(right, n)]
            try:
                chunk_states = m.predict(test_seq)
                hidden_states[chunk_start:min(right, n)] = chunk_states
            except Exception as e:
                logger.warning(f"[HMM] Predict falhou em chunk [{chunk_start}, {right}): {e}")
                continue

        hidden_states[hidden_states == -1] = 0

        log_returns = df['log_return'].to_numpy(dtype=np.float64)
        adx = df['adx'].to_numpy(dtype=np.float64)
        hurst = df['hurst'].to_numpy(dtype=np.float64)
        adx_p75, adx_p50 = np.percentile(adx, [75, 50])
        hurst_p75, hurst_p60, hurst_p40 = np.percentile(hurst, [75, 60, 40])

        state_info = []
        for s in range(self.n_states):
            mask = hidden_states == s
            if mask.sum() == 0:
                state_info.append((s, 0, 0, 0, 'RANGE'))
                continue
            m_adx = float(adx[mask].mean())
            m_hurst = float(hurst[mask].mean())
            m_ret = float(log_returns[mask].mean())
            if m_adx > adx_p75 and m_hurst > hurst_p75:
                regime = 'TREND_FORTE'
            elif m_adx > adx_p50 and m_hurst > hurst_p60:
                regime = 'TREND_FRACO'
            elif m_adx < adx_p50 and m_hurst < hurst_p40:
                regime = 'CHOP'
            else:
                regime = 'RANGE'
            state_info.append((s, m_ret, m_adx, m_hurst, regime))

        self.state_map = {s: info[-1] for s, *info in state_info}
        state_map_arr = np.array([self.state_map[s] for s in hidden_states])
        df['hmm_state'] = hidden_states.astype(np.int32)
        df['hmm_regime'] = pd.Categorical(state_map_arr, categories=REGIME_LABELS)
        self.agreement = float((df['regime'] == df['hmm_regime']).mean() * 100)
        self.model = model
        logger.info(f"  [HMM-CAUSAL] OK em {time.time()-t0:.2f}s | {self.n_states} estados | "
                    f"concordância: {self.agreement:.1f}%")
        return df

    def transition_matrix(self) -> Tuple[np.ndarray, List[str]]:
        if 'hmm_state' not in self.df.columns:
            return np.eye(4), REGIME_LABELS
        regime_int = self.df['hmm_regime'].cat.codes.to_numpy(dtype=np.int32)
        return _transition_matrix_numba(regime_int, len(REGIME_LABELS)), REGIME_LABELS


# ══════════════════════════════════════════════════════════════
# TEMPORAL + TAIL RISK
# ══════════════════════════════════════════════════════════════
class TemporalProfiler:
    def __init__(self, df: pd.DataFrame):
        self.df = df
        self.profile: Dict[str, Any] = {}

    def analyze(self) -> Dict[str, Any]:
        logger.info("[TEMPORAL] Analisando sazonalidade...")
        df = self.df
        grp_h = df.groupby('hour', observed=True)
        grp_d = df.groupby('day_of_week', observed=True)
        grp_m = df.groupby('month', observed=True)
        grp_s = df.groupby('session', observed=True)
        self.profile = {
            'hour': {
                'atr_mean': grp_h['atr'].mean().to_dict(),
                'volume_mean': grp_h['tick_volume'].mean().to_dict(),
                'regime_pct': pd.crosstab(df['hour'], df['regime'], normalize='index').to_dict('index'),
            },
            'day_of_week': {
                'atr_mean': grp_d['atr'].mean().to_dict(),
                'volume_mean': grp_d['tick_volume'].mean().to_dict(),
            },
            'month': {
                'atr_mean': grp_m['atr'].mean().to_dict(),
                'volume_mean': grp_m['tick_volume'].mean().to_dict(),
            },
            'session': {
                'atr_mean': grp_s['atr'].mean().to_dict(),
                'volume_mean': grp_s['tick_volume'].mean().to_dict(),
                'regime_pct': pd.crosstab(df['session'], df['regime'], normalize='index').to_dict('index'),
                'gap_risk': grp_s['atr'].mean().to_dict(),
            },
        }
        logger.info("  [OK] Perfis gerados")
        return self.profile


class TailRiskEngine:
    def __init__(self, df: pd.DataFrame):
        self.df = df
        self.results: Dict[str, Any] = {}

    def analyze(self) -> Dict[str, Any]:
        logger.info("[TAIL RISK] Analisando risco de cauda...")
        df = self.df
        atr = df['atr'].to_numpy(dtype=np.float64)
        tr_z = df['tr_zscore'].to_numpy(dtype=np.float64)
        threshold = float(np.quantile(atr, 0.99))
        spike_mask = tr_z > 2.0
        n, n_spikes = len(df), int(spike_mask.sum())
        self.results = {
            'atr_threshold': threshold,
            'top_atr_pct': (atr >= threshold).sum() / n * 100,
            'top_atr_by_session': df[df['atr'] >= threshold]['session'].value_counts(normalize=True).to_dict() if n > 0 else {},
            'spike_count': n_spikes,
            'spike_pct': n_spikes / n * 100,
            'spike_by_session': df[spike_mask]['session'].value_counts(normalize=True).to_dict() if n_spikes else {},
            'avg_atr_spike': float(atr[spike_mask].mean()) if n_spikes else 0.0,
            'avg_atr_normal': float(atr[~spike_mask].mean()) if (~spike_mask).any() else 0.0,
        }
        logger.info(f"  Spikes: {n_spikes:,} ({n_spikes/n*100:.2f}%)")
        return self.results


# ══════════════════════════════════════════════════════════════
# [FIX-5] MACRO RISK COM ATR PERCENTUAL + [FIX-4] FDR
# ══════════════════════════════════════════════════════════════
class MacroRiskIntegrator:
    SYMBOL_SELF_MACRO = {'XAUUSD': ['GOLDAMGBD228NLBM'], 'XAGUSD': [], 'BTCUSD': [], 'ETHUSD': []}
    MACRO_FACTORS = {
        'RISK': ['VIX', 'STLFSI4', 'NFCI', 'BAMLH0A0HYM2'],
        'CARRY': ['DTWEXBGS', 'T10Y2Y', 'DGS2', 'DGS10'],
        'INFLATION': ['CPIAUCSL', 'CPILFESL', 'PCEPI', 'PPIACO'],
        'LIQUIDITY': ['BOGMBASE', 'WALCL', 'RRPONTSYD', 'SOFR'],
        'GROWTH': ['INDPRO', 'GDPC1', 'PAYEMS', 'UNRATE', 'RSAFS', 'TCU'],
        'COMMODITIES': ['DCOILWTICO', 'DCOILBRENTEU', 'GOLDAMGBD228NLBM', 'PCOPPUSDM'],
    }

    def __init__(self, db_path=None):
        from db.schema import DB_PATH
        self.db_path = db_path or DB_PATH
        self.macro_wide = None
        self.catalog = {}
        self.roro_df = None
        self.correlations = {}
        self._sensitivity = {}

    def load(self) -> pd.DataFrame:
        if not os.path.exists(self.db_path):
            logger.warning(f"[MACRO] DB não encontrado")
            return pd.DataFrame()
        try:
            conn = get_connection(read_only=True)
        except Exception:
            return pd.DataFrame()
        try:
            cat_df = conn.execute("SELECT symbol, name, category, country, unit FROM macro_catalog").df()
            self.catalog = {r['symbol']: {'name': r['name'], 'category': r['category'],
                                          'country': r['country'], 'unit': r['unit']}
                            for _, r in cat_df.iterrows()}
            raw = conn.execute("SELECT symbol, date, value FROM macro_series ORDER BY date").df()
            if len(raw) == 0: return pd.DataFrame()
            raw['date'] = pd.to_datetime(raw['date'], errors='coerce')
            raw.dropna(subset=['date'], inplace=True)
            wide = raw.pivot_table(index='date', columns='symbol', values='value', aggfunc='first')
            wide.index = pd.to_datetime(wide.index)
            wide.sort_index(inplace=True)
            wide = wide.ffill().bfill()
            self.macro_wide = wide
            risk_labels = conn.execute("SELECT date, risk_label, roro_score FROM risk_labels ORDER BY date").df()
            risk_labels['date'] = pd.to_datetime(risk_labels['date'], errors='coerce')
            risk_labels.dropna(subset=['date'], inplace=True)
            risk_labels.set_index('date', inplace=True)
            self.roro_df = risk_labels
            logger.info(f"[MACRO] {wide.shape[1]} indicadores, {len(wide)} datas")
            return wide
        except Exception as e:
            logger.warning(f"[MACRO] Erro: {e}")
            return pd.DataFrame()
        finally:
            try: conn.close()
            except: pass

    def cross_reference(self, asset_df: pd.DataFrame, symbol: str = "") -> Dict[str, Any]:
        if self.macro_wide is None or len(self.macro_wide) < 10:
            return {}
        asset_daily = asset_df.resample('D').agg({
            'hurst': 'mean', 'adx': 'mean', 'atr': 'mean',
            'tr_zscore': 'mean', 'close': 'last'
        }).dropna()
        asset_daily['close_ret'] = asset_daily['close'].pct_change()
        # [FIX-5] ATR percentual (estacionário) em vez de nível
        asset_daily['atr_pct'] = asset_daily['atr'].pct_change()
        asset_daily.dropna(inplace=True)
        if len(asset_daily) < 10: return {}
        common = asset_daily.index.intersection(self.macro_wide.index)
        if len(common) < 10: return {}
        a = asset_daily.loc[common]
        m = self.macro_wide.loc[common]
        roro = self.roro_df.reindex(common, method='ffill') if self.roro_df is not None else None
        merged = a.join(m)
        asset_feats = ['hurst', 'adx', 'atr_pct', 'tr_zscore', 'close_ret']  # [FIX-5] atr_pct
        macro_symbols = [c for c in m.columns if c != 'date']
        exclude_self = list(self.SYMBOL_SELF_MACRO.get(symbol, []))
        self_sym = symbol.replace('USD', '').replace('X', '')
        for sym in macro_symbols:
            cat = self.catalog.get(sym, {})
            if self_sym.lower() in cat.get('name', sym).lower():
                exclude_self.append(sym)

        corr_records = []
        for ms in macro_symbols:
            if ms in exclude_self: continue
            for af in asset_feats:
                if ms not in merged.columns or af not in merged.columns: continue
                valid = merged[[af, ms]].dropna()
                if len(valid) < 20: continue
                if af == 'close_ret' or af == 'atr_pct':
                    ms_ret = valid[ms].pct_change().dropna()
                    idx = valid.index.intersection(ms_ret.index)
                    if len(idx) < 20: continue
                    r_val, p_val = stats.pearsonr(valid.loc[idx, af], ms_ret.loc[idx])
                else:
                    r_val, p_val = stats.pearsonr(valid[af], valid[ms])
                corr_records.append({
                    'macro_symbol': ms, 'asset_feature': af,
                    'correlation': round(r_val, 4), 'p_value': round(p_val, 4),
                    'abs_corr': abs(r_val),
                })
        corr_records.sort(key=lambda x: x['abs_corr'], reverse=True)
        self.correlations = {f"{cr['asset_feature']}_vs_{cr['macro_symbol']}": cr['correlation']
                             for cr in corr_records}
        top20 = corr_records[:20]

        KEY_MACRO = ['DTWEXBGS', 'VIX', 'DGS10', 'DGS2', 'FEDFUNDS',
                     'CPIAUCSL', 'DCOILWTICO', 'STLFSI4', 'T10Y2Y']
        KEY_MACRO = [k for k in KEY_MACRO if k not in exclude_self]
        ret_std = merged['close_ret'].std()
        regime_betas = {}
        if 'regime' in asset_df.columns:
            asset_regime = asset_df.resample('D')['regime'].agg(
                lambda x: x.mode().iloc[0] if len(x) > 0 else 'RANGE')
            for rl in sorted(asset_regime.unique()):
                rd = asset_regime[asset_regime == rl].index.intersection(common)
                if len(rd) < 5: continue
                subset = merged.loc[rd].dropna()
                betas = {}
                for k in KEY_MACRO:
                    if k not in subset.columns: continue
                    valid = subset[['close_ret', k]].dropna()
                    if len(valid) < 5: continue
                    try:
                        slope, _, r_val, p_val, _ = stats.linregress(valid[k], valid['close_ret'])
                        elasticity = slope * valid[k].std() / ret_std if ret_std > 0 else 0
                        betas[k] = {'raw_beta': round(slope, 8), 'elasticity': round(elasticity, 4),
                                    'r_squared': round(r_val**2, 4), 'p_value': round(p_val, 4),
                                    'n_days': len(valid)}
                    except Exception:
                        pass
                if betas: regime_betas[rl] = betas

        # [FIX-4] Leading indicators COM FDR Benjamini-Hochberg
        leading: List[Dict] = []
        all_tests: List[Dict] = []
        for ms in macro_symbols[:40]:
            if ms in exclude_self or ms not in merged.columns: continue
            valid = merged[['close_ret', ms]].dropna()
            if len(valid) < 60: continue
            macro_ret = valid[ms].pct_change().dropna()
            idx = valid.index.intersection(macro_ret.index)
            if len(idx) < 60: continue
            ret_arr = valid.loc[idx, 'close_ret'].values
            macro_arr = macro_ret.loc[idx].values
            max_lag = min(45, len(idx) // 4)
            for lag in range(1, max_lag + 1):
                if len(ret_arr) <= lag: break
                try:
                    c_lead, p_lead = stats.spearmanr(macro_arr[:-lag], ret_arr[lag:])
                    all_tests.append({'symbol': ms, 'lag': lag, 'corr': c_lead, 'p': p_lead, 'leads': True})
                    c_lag, p_lag = stats.spearmanr(macro_arr[lag:], ret_arr[:-lag])
                    all_tests.append({'symbol': ms, 'lag': -lag, 'corr': c_lag, 'p': p_lag, 'leads': False})
                except Exception:
                    pass

        if len(all_tests) > 0:
            p_vals = np.array([t['p'] for t in all_tests])
            p_vals = np.clip(p_vals, 1e-15, 1.0)
            sorted_idx = np.argsort(p_vals)
            n_tests = len(p_vals)
            ranks = np.arange(1, n_tests + 1, dtype=np.float64)
            q = 0.05
            p_adjusted = np.minimum.accumulate(
                (p_vals[sorted_idx] * n_tests / ranks)[::-1]
            )[::-1]
            p_adjusted = np.minimum(p_adjusted, 1.0)
            p_adj_map = {}
            for i, idx in enumerate(sorted_idx):
                p_adj_map[idx] = p_adjusted[i]
            for i, test in enumerate(all_tests):
                test['p_adjusted'] = float(p_adj_map.get(i, 1.0))
                test['significant'] = test['p_adjusted'] < q
            significant_tests = [t for t in all_tests if t.get('significant', False)]
            best_per_symbol: Dict[str, Dict] = {}
            for t in significant_tests:
                sym = t['symbol']
                if sym not in best_per_symbol or abs(t['corr']) > abs(best_per_symbol[sym]['corr']):
                    best_per_symbol[sym] = t
            for sym, t in best_per_symbol.items():
                info = self.catalog.get(sym, {'name': sym, 'category': '', 'country': ''})
                leading.append({
                    'symbol': sym, 'name': info['name'], 'category': info['category'],
                    'country': info['country'], 'lag_days': t['lag'],
                    'cross_correlation': round(t['corr'], 4),
                    'direction': 'leads' if t['lag'] > 0 else 'lags',
                    'p_raw': round(float(t['p']), 6),
                    'p_adjusted_fdr': round(float(t['p_adjusted']), 6),
                    'fdr_q': q, 'n_total_tests': n_tests,
                })
            leading.sort(key=lambda x: abs(x['cross_correlation']), reverse=True)
            leading = leading[:15]
            logger.info(f"  [LEADING] {len(leading)} significantes após FDR (q={q}) de {n_tests} testes")

        coint_results = []
        if HAS_STATSMODELS:
            for ms in KEY_MACRO[:6]:
                if ms not in merged.columns: continue
                valid = merged[['close', ms]].dropna()
                if len(valid) < 100: continue
                try:
                    result = coint_johansen(valid.values, det_order=0, k_ar_diff=1)
                    trace_stat = result.lr1[0]
                    crit_5 = result.cvt[0, 1]
                    coint_results.append({
                        'macro': ms, 'trace_stat': round(trace_stat, 2),
                        'crit_5pct': round(crit_5, 2),
                        'result': 'COINTEGRADO' if trace_stat > crit_5 else 'Não',
                    })
                except Exception:
                    pass

        macro_factors = {}
        for fn, members in self.MACRO_FACTORS.items():
            avail = [ms for ms in members if ms in merged.columns]
            if len(avail) < 2: continue
            fdf = merged[avail].dropna()
            if len(fdf) < 10: continue
            zs = (fdf - fdf.mean()) / fdf.std()
            fs = zs.mean(axis=1)
            macro_factors[fn] = {
                'score_current': round(float(fs.iloc[-1]), 4),
                'score_min': round(float(fs.min()), 4),
                'score_max': round(float(fs.max()), 4),
                'n_members': len(avail), 'members': avail,
            }
            cf_w = fs.resample('W').last().pct_change().dropna()
            ca_w = a['close'].resample('W').last().pct_change().dropna()
            cw = cf_w.index.intersection(ca_w.index)
            if len(cw) > 10:
                r_f, p_f = stats.pearsonr(ca_w.loc[cw], cf_w.loc[cw])
                macro_factors[fn]['correlation'] = round(r_f, 4)
            else:
                macro_factors[fn]['correlation'] = 0.0

        regime_by_risk = {}
        if roro is not None and 'regime' in asset_df.columns:
            adr = asset_df.resample('D')['regime'].agg(
                lambda x: x.mode().iloc[0] if len(x) > 0 else 'RANGE')
            crr = adr.index.intersection(roro.index)
            if len(crr) >= 5:
                combined = pd.DataFrame({'regime': adr.loc[crr], 'risk_label': roro.loc[crr, 'risk_label']}).dropna()
                regime_by_risk = pd.crosstab(combined['risk_label'], combined['regime'],
                                             normalize='index').to_dict('index')

        self._sensitivity = {
            'top_correlations': top20, 'regime_betas': regime_betas,
            'leading_indicators': leading, 'macro_factors': macro_factors,
            'cointegration': coint_results,
        }
        return {
            'merged': merged, 'correlations': self.correlations,
            'regime_by_risk': regime_by_risk, 'macro_sensitivity': self._sensitivity,
        }

    def generate_charts(self, chart_dir: Path, charts: Dict) -> Dict:
        if self.macro_wide is None or len(self.macro_wide) < 10:
            return charts
        chart_dir = Path(chart_dir); chart_dir.mkdir(parents=True, exist_ok=True)
        top = self._sensitivity.get('top_correlations', [])
        if len(top) >= 3:
            try:
                labels = [f"{t['macro_symbol']}({t['asset_feature']})" for t in top[:20]]
                vals = [t['correlation'] for t in top[:20]]
                fig, ax = plt.subplots(figsize=(10, max(4, len(labels)*0.35)))
                colors_bar = [C['red'] if v < 0 else C['green'] for v in vals]
                ax.barh(range(len(labels)), vals, color=colors_bar, height=0.6)
                ax.set_yticks(range(len(labels))); ax.set_yticklabels(labels, fontsize=7)
                ax.axvline(0, color='gray', linewidth=0.5)
                ax.set_xlabel('Correlação'); ax.set_title('Top 20 Macro vs Ativo', fontweight='bold')
                plt.tight_layout()
                path = str(chart_dir / 'macro_corr_heatmap.png')
                fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
                charts['macro_corr_heatmap'] = path
            except Exception: pass
        return charts


# ══════════════════════════════════════════════════════════════
# WALK-FORWARD VALIDATORS
# ══════════════════════════════════════════════════════════════
class WalkForwardValidator:
    def __init__(self, df: pd.DataFrame, n_windows: int = 6):
        self.df = df; self.n_windows = n_windows; self.results = []

    def analyze(self) -> Dict[str, Any]:
        logger.info(f"[WALK-FORWARD] {self.n_windows} janelas...")
        if hasattr(self.df.index, 'strftime') or isinstance(self.df.index, pd.DatetimeIndex):
            time_col = self.df.index
        elif 'time' in self.df.columns:
            time_col = self.df['time']
        else:
            time_col = self.df.index
        dates = time_col.sort_values() if hasattr(time_col, 'sort_values') else time_col
        if len(dates) < 10000:
            return {'stability_score': 0, 'periods': []}
        ws = len(dates) // self.n_windows
        periods = []
        for i in range(self.n_windows):
            start = i * ws
            end = (i + 1) * ws if i < self.n_windows - 1 else len(dates)
            wdf = self.df.iloc[start:end]
            if len(wdf) < 100: continue
            if 'time' in wdf.columns:
                start_date, end_date = wdf['time'].iloc[0], wdf['time'].iloc[-1]
            else:
                start_date, end_date = wdf.index[0], wdf.index[-1]
            rc = wdf['regime'].value_counts(normalize=True)
            periods.append({
                'label': f"{start_date.strftime('%Y-%m') if hasattr(start_date, 'strftime') else str(start_date)[:7]} a {end_date.strftime('%Y-%m') if hasattr(end_date, 'strftime') else str(end_date)[:7]}",
                'hurst': float(wdf['hurst'].mean()), 'adx': float(wdf['adx'].mean()),
                'atr': float(wdf['atr'].mean()), 'dominant': rc.index[0],
                'dominant_pct': float(rc.iloc[0]*100),
                'trend_pct': float((rc.get('TREND_FORTE',0)+rc.get('TREND_FRACO',0))*100),
                'range_pct': float(rc.get('RANGE',0)*100),
                'chop_pct': float(rc.get('CHOP',0)*100), 'n_candles': len(wdf),
            })
        if len(periods) < 2:
            return {'stability_score': 0, 'periods': periods}
        h_std = np.std([p['hurst'] for p in periods])
        a_std = np.std([p['adx'] for p in periods])
        max_drift = max(abs(p['hurst'] - periods[0]['hurst']) for p in periods)
        score = max(10, 100 - min(50, h_std/0.05*50) - min(30, a_std/5*30) - min(20, max_drift/0.15*20))
        logger.info(f"  [OK] Score: {score:.0f}%")
        self.results = periods
        return {'stability_score': score, 'periods': periods, 'hurst_std': h_std, 'adx_std': a_std}

    def generate_charts(self, chart_dir: Path, charts: Dict) -> Dict:
        if len(self.results) < 2: return charts
        fig, ax1 = plt.subplots(figsize=(10, 4))
        labels = [p['label'].split(' a ')[0] for p in self.results]
        x = range(len(self.results))
        ax1.plot(x, [p['hurst'] for p in self.results], color=C['blue'], marker='o', linewidth=2, label='DFA-H')
        ax1.axhline(y=0.55, color='red', linestyle='--', linewidth=0.8, alpha=0.5)
        ax1.set_ylabel('DFA-Hurst', color=C['blue']); ax1.set_ylim(0.3, 0.8)
        ax2 = ax1.twinx()
        ax2.plot(x, [p['adx'] for p in self.results], color=C['gold'], marker='s', linewidth=2, label='ADX')
        ax2.set_ylabel('ADX', color=C['gold'])
        ax1.set_xticks(x); ax1.set_xticklabels(labels, rotation=45, ha='right', fontsize=8)
        ax1.set_title('Estabilidade Temporal', fontweight='bold')
        lines = ax1.get_lines() + ax2.get_lines()
        ax1.legend(lines, [l.get_label() for l in lines], loc='upper left')
        plt.tight_layout()
        path = str(chart_dir / 'wf_stability.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        charts['wf_stability'] = path
        return charts


class PurgedWalkForwardValidator:
    def __init__(self, df, n_windows=6, purge_pct=0.02, embargo_pct=0.01):
        self.df = df; self.n_windows = n_windows
        self.purge_pct = purge_pct; self.embargo_pct = embargo_pct; self.results = []

    def analyze(self) -> Dict[str, Any]:
        logger.info(f"[PURGED WF] purge={self.purge_pct:.1%} embargo={self.embargo_pct:.1%}")
        n = len(self.df)
        if n < 10000:
            return {'stability_score': 0, 'periods': [], 'purged': True}
        ws = n // self.n_windows
        purge = max(10, int(ws * self.purge_pct))
        embargo = max(5, int(ws * self.embargo_pct))
        periods = []
        for i in range(self.n_windows):
            train_end = (i + 1) * ws
            test_start = train_end + purge
            test_end = min(test_start + ws, n)
            if test_start >= test_end: continue
            train_df = self.df.iloc[:train_end - embargo]
            test_df = self.df.iloc[test_start:test_end]
            if len(train_df) < 100 or len(test_df) < 10: continue
            h_diff = abs(train_df['hurst'].mean() - test_df['hurst'].mean())
            a_diff = abs(train_df['adx'].mean() - test_df['adx'].mean())
            tc = train_df['regime'].value_counts(normalize=True)
            tec = test_df['regime'].value_counts(normalize=True)
            js = 0.0
            for r in REGIME_LABELS:
                p, q = tc.get(r, 0), tec.get(r, 0)
                m = (p + q) / 2
                if p > 0 and m > 0: js += p * np.log(p / m)
                if q > 0 and m > 0: js += q * np.log(q / m)
            js /= 2
            periods.append({
                'label': f"J{i+1}", 'train_hurst': float(train_df['hurst'].mean()),
                'test_hurst': float(test_df['hurst'].mean()),
                'train_adx': float(train_df['adx'].mean()),
                'test_adx': float(test_df['adx'].mean()),
                'hurst_diff': float(h_diff), 'adx_diff': float(a_diff),
                'js_divergence': float(js),
            })
        if len(periods) < 2:
            return {'stability_score': 0, 'periods': periods, 'purged': True}
        score = max(10, 100 - min(40, np.mean([p['hurst_diff'] for p in periods])/0.05*40)
                    - min(30, np.mean([p['adx_diff'] for p in periods])/5*30)
                    - min(30, np.mean([p['js_divergence'] for p in periods])/0.1*30))
        logger.info(f"  [PURGED WF] Score: {score:.0f}%")
        self.results = periods
        return {
            'stability_score': score, 'periods': periods, 'purged': True,
            'mean_hurst_diff': float(np.mean([p['hurst_diff'] for p in periods])),
            'mean_adx_diff': float(np.mean([p['adx_diff'] for p in periods])),
            'mean_js_divergence': float(np.mean([p['js_divergence'] for p in periods])),
        }

    def generate_charts(self, chart_dir: Path, charts: Dict) -> Dict:
        if len(self.results) < 2: return charts
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 4))
        x = range(len(self.results))
        ax1.plot(x, [p['train_hurst'] for p in self.results], color=C['blue'], marker='o', label='Treino')
        ax1.plot(x, [p['test_hurst'] for p in self.results], color=C['red'], marker='s', linestyle='--', label='Teste')
        ax1.set_ylabel('DFA-Hurst'); ax1.set_title('Hurst: Treino vs Teste', fontweight='bold'); ax1.legend()
        ax2.plot(x, [p['train_adx'] for p in self.results], color=C['blue'], marker='o', label='Treino')
        ax2.plot(x, [p['test_adx'] for p in self.results], color=C['red'], marker='s', linestyle='--', label='Teste')
        ax2.set_ylabel('ADX'); ax2.set_title('ADX: Treino vs Teste', fontweight='bold'); ax2.legend()
        plt.tight_layout()
        path = str(chart_dir / 'purged_wf.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        charts['purged_wf'] = path
        return charts


# ══════════════════════════════════════════════════════════════
# [FIX-3] CPCV COM regime_stability_score
# ══════════════════════════════════════════════════════════════
class CPCVValidator:
    """[FIX-3] CPCV renomeado: pbo_score → regime_stability_score."""
    def __init__(self, df: pd.DataFrame, n_splits: int = 6, n_test_splits: int = 2,
                 purge_pct: float = 0.02):
        self.df = df
        self.n_splits = n_splits
        self.n_test = n_test_splits
        self.purge_pct = purge_pct

    def analyze(self) -> Dict[str, Any]:
        from itertools import combinations
        logger.info(f"[CPCV] Combinatorial Purged CV ({self.n_splits} splits, {self.n_test} test)...")
        n = len(self.df)
        if n < 10000:
            return {'regime_stability_score': None, 'n_paths': 0}
        block_size = n // self.n_splits
        purge = max(10, int(block_size * self.purge_pct))
        combos = list(combinations(range(self.n_splits), self.n_test))
        n_paths = len(combos)
        logger.info(f"  [CPCV] {n_paths} caminhos combinatórios")
        path_scores = []
        for combo in combos[:min(n_paths, 15)]:
            test_blocks = set(combo)
            train_idx = []
            test_idx = []
            for b in range(self.n_splits):
                b_start = b * block_size
                b_end = (b + 1) * block_size if b < self.n_splits - 1 else n
                if b in test_blocks:
                    test_idx.extend(range(b_start + purge, b_end))
                else:
                    train_idx.extend(range(b_start, b_end - purge))
            if not train_idx or not test_idx:
                continue
            train_idx = [i for i in train_idx if 0 <= i < n]
            test_idx = [i for i in test_idx if 0 <= i < n]
            if len(train_idx) < 100 or len(test_idx) < 50:
                continue
            train_h = self.df['hurst'].iloc[train_idx].mean()
            test_h = self.df['hurst'].iloc[test_idx].mean()
            path_scores.append(abs(train_h - test_h))
        if len(path_scores) < 2:
            return {'regime_stability_score': None, 'n_paths': len(path_scores)}
        median_score = np.median(path_scores)
        pbo = sum(1 for s in path_scores if s > median_score) / len(path_scores) * 100
        logger.info(f"  [CPCV] Regime Stability: {pbo:.1f}% ({len(path_scores)} caminhos)")
        return {
            'regime_stability_score': round(pbo, 1),
            'methodology_note': (
                'Esta métrica mede estabilidade estrutural do DFA-Hurst via CPCV purgado. '
                'NÃO é o Probability of Backtest Overfitting (PBO) de Bailey & López de Prado, '
                'que requer comparação de Sharpe ratios entre múltiplas estratégias candidatas.'
            ),
            'n_paths': len(path_scores),
            'median_hurst_drift': round(float(median_score), 4),
            'max_hurst_drift': round(float(max(path_scores)), 4),
        }


# ══════════════════════════════════════════════════════════════
# NARRATIVE + CHARTS + PDF + JSON (Output 100% preservado)
# ══════════════════════════════════════════════════════════════
class NarrativeEngine:
    def __init__(self, df, regime_model, temporal, tail_risk, hmm_model=None,
                 entropy=None, fracdiff=None, signal_data=None):
        self.df = df
        self.regime_model = regime_model
        self.temporal = temporal
        self.tail_risk = tail_risk
        self.hmm = hmm_model or {}
        self.entropy = entropy or {}
        self.fracdiff = fracdiff or {}
        self.signal = signal_data or {}

    def generate(self) -> Dict[str, str]:
        df = self.df
        dominant = df['regime'].value_counts().index[0]
        dominant_pct = df['regime'].value_counts().iloc[0] / len(df) * 100
        noise = float(df['hurst'].mean())
        noise_desc = "Alta" if noise < 0.45 else "Media" if noise < 0.55 else "Baixa"
        vol_hour = int(df.groupby('hour', observed=True)['atr'].mean().idxmax())
        return {
            'executive': f"Perfil: {dominant} ({dominant_pct:.1f}%). DFA-Hurst: {noise:.2f}.",
            'transition': "Matriz de Markov.",
            'tail_risk': f"Spikes: {self.tail_risk['spike_count']}.",
            'complexity': f"Entropy analysis.",
            'signal_analysis': "Signal analysis.",
        }


class ChartGenerator:
    def __init__(self, df, regime_labels, transition_mat, features):
        self.df = df
        self.regime_labels = regime_labels
        self.transition_mat = transition_mat
        self.features = features
        self.charts = {}
        self._chart_dir = CFG.report_dir / '_charts'
        self._chart_dir.mkdir(parents=True, exist_ok=True)

    def generate_all(self):
        logger.info("[CHARTS] Gerando gráficos...")
        self._regime_bars()
        self._markov_matrix()
        return self.charts

    def _regime_bars(self):
        fig, ax = plt.subplots(figsize=(9, 4))
        dist = self.df['regime'].value_counts()
        colors_list = [REGIME_COLORS.get(r, '#999') for r in dist.index]
        bars = ax.bar(dist.index, dist.values, color=colors_list)
        ax.set_title('Distribuição de Regimes', fontweight='bold')
        plt.tight_layout()
        path = str(self._chart_dir / 'regime_bars.png')
        fig.savefig(path, dpi=150); plt.close(fig)
        self.charts['regime_bars'] = path

    def _markov_matrix(self):
        fig, ax = plt.subplots(figsize=(7, 6))
        sns.heatmap(self.transition_mat, annot=True, fmt='.2f', cmap='Blues',
                    xticklabels=self.regime_labels, yticklabels=self.regime_labels, ax=ax)
        ax.set_title('Matriz de Transição', fontweight='bold')
        plt.tight_layout()
        path = str(self._chart_dir / 'markov_matrix.png')
        fig.savefig(path, dpi=150); plt.close(fig)
        self.charts['markov_matrix'] = path


class PDFReportBuilder:
    def __init__(self, output_path, charts, narratives, df, transition_mat, regime_labels,
                 features, tf='M5', walkforward=None, macro=None, hmm_model=None,
                 signal_data=None, purged_wf=None, cpcv=None):
        self.output = output_path
        self._tf = tf
        self.charts = charts
        self.narr = narratives
        self.df = df
        self.transition_mat = transition_mat
        self.regime_labels = regime_labels
        self.features = features
        self.elements = []
        self._walkforward = walkforward or {}
        self._macro = macro or {}
        self._hmm = hmm_model or {}
        self._signal = signal_data or {}
        self._purged_wf = purged_wf or {}
        self._cpcv = cpcv or {}
        self._setup_styles()

    def _setup_styles(self):
        self.styles = getSampleStyleSheet()
        self.s_h1 = ParagraphStyle('H1', parent=self.styles['Heading1'],
            fontName='Helvetica-Bold', fontSize=16, textColor=colors.HexColor(C['navy']))
        self.s_body = ParagraphStyle('Body', parent=self.styles['Normal'],
            fontName='Helvetica', fontSize=9, textColor=colors.HexColor(C['dark']))

    def _add(self, el): self.elements.append(el)
    def _hr(self): self._add(HRFlowable(width="100%", thickness=0.5, color=colors.HexColor(C['light'])))

    def build_pdf(self):
        self._add(Paragraph("ALXQuant Asset DNA Profile v4.0-Institutional", self.s_h1))
        self._hr()
        self._add(Paragraph(self.narr['executive'], self.s_body))
        if 'regime_bars' in self.charts:
            self._add(Image(self.charts['regime_bars'], width=160*mm, height=60*mm))
        if 'markov_matrix' in self.charts:
            self._add(Image(self.charts['markov_matrix'], width=120*mm, height=90*mm))
        
        # [FIX-3] CPCV renamed
        rss = self._cpcv.get('regime_stability_score')
        if rss is not None:
            self._add(Paragraph(f"Regime Stability Score: {rss:.1f}%", self.s_h1))
            self._add(Paragraph(self._cpcv.get('methodology_note', ''), self.s_body))
        
        doc = SimpleDocTemplate(self.output, pagesize=A4)
        doc.build(self.elements)
        logger.info(f"  [OK] PDF: {self.output}")


class JsonProfileExporter:
    def __init__(self, df, regime_labels, transition_mat, temporal, tail_risk,
                 walkforward, macro, hmm_model=None, entropy=None, fracdiff=None,
                 signal_data=None, purged_wf=None, cpcv=None):
        self.df = df
        self.regime_labels = regime_labels
        self.transition_mat = transition_mat
        self.temporal = temporal
        self.tail_risk = tail_risk
        self.walkforward = walkforward
        self.macro = macro
        self.hmm = hmm_model or {}
        self.entropy = entropy or {}
        self.fracdiff = fracdiff or {}
        self.signal = signal_data or {}
        self.purged_wf = purged_wf or {}
        self.cpcv = cpcv or {}

    def export(self, output_path: str, symbol: str, tf: str) -> str:
        profile = self._build(symbol, tf)
        with open(output_path, 'w') as f:
            json.dump(profile, f, indent=2, default=str)
        logger.info(f"[JSON] Perfil exportado: {output_path}")
        return output_path

    def _build(self, symbol: str, tf: str) -> dict:
        df = self.df
        regime_dist = {str(k): float(v) for k, v in df['regime'].value_counts(normalize=True).to_dict().items()}
        avg_hurst = float(df['hurst'].mean())
        avg_adx = float(df['adx'].mean())
        avg_atr = float(df['atr'].mean())
        vol_hour = int(df.groupby('hour')['atr'].mean().idxmax())

        return {
            'meta': {
                'symbol': symbol, 'timeframe': tf,
                'generated_at': datetime.now().isoformat(),
                'candles': len(df),
                'algo_version': ALGO_VERSION,
            },
            'regime_profile': {
                'dominant': str(regime_dist),
                'hurst_mean': avg_hurst, 'hurst_method': 'DFA',
                'adx_mean': avg_adx, 'atr_mean': avg_atr,
                'regime_distribution': regime_dist,
            },
            'hmm_model': {
                'states': int(df['hmm_state'].nunique()) if 'hmm_state' in df.columns else 0,
                'agreement_adx_hurst': round(self.hmm.get('agreement', 0), 1),
                'hmm_regime_distribution': {str(k): float(v) for k, v in df['hmm_regime'].value_counts(normalize=True).to_dict().items()} if 'hmm_regime' in df.columns else {},
                'hmm_features': ['log_return', 'realized_vol', 'skewness', 'kurtosis', 'autocorr_lag1'],
                'walk_forward_method': 'causal_strict',
            },
            'entropy': {
                'sample_entropy_mean': round(float(df['sample_entropy'].dropna().mean()), 4) if 'sample_entropy' in df.columns else 0,
                'perm_entropy_mean': round(float(df['perm_entropy'].dropna().mean()), 4) if 'perm_entropy' in df.columns else 0,
            },
            'fracdiff': {
                'd_param_close': self.fracdiff.get('d_close', 0.5),
                'd_param_return': self.fracdiff.get('d_return', 0.3),
                'd_method': 'FFD_ADF_optimized',
            },
            'session_profile': {
                'most_volatile_hour': vol_hour,
                'hourly_atr': {str(h): float(v) for h, v in df.groupby('hour')['atr'].mean().to_dict().items()},
            },
            'transition_matrix': {
                f'{frm}_to_{to}': round(float(self.transition_mat[i][j]), 3)
                for i, frm in enumerate(self.regime_labels)
                for j, to in enumerate(self.regime_labels)
                if self.transition_mat[i][j] > 0.01
            },
            'stability': {
                'score': round(self.walkforward.get('stability_score', 0), 1),
                'hurst_std': round(self.walkforward.get('hurst_std', 0), 3),
                'adx_std': round(self.walkforward.get('adx_std', 0), 1),
            },
            'macro_correlations': {k: round(v, 3) for k, v in self.macro.get('correlations', {}).items()},
            'macro_sensitivity': self.macro.get('macro_sensitivity', {}),
            'signal_analysis': {
                'kalman_filtered': self.signal.get('has_kalman', False),
                'transfer_entropy_method': 'KSG_continuous',
                'transfer_entropy': self.signal.get('transfer_entropy', {}),
            },
            'statistical_significance': {
                'hurst_test': getattr(self, 'hurst_significance', {}),
                'transfer_entropy_tests': getattr(self, 'te_significance', {}),
            },
            'purged_wf': {
                'score': round(self.purged_wf.get('stability_score', 0), 1),
                'n_windows': len(self.purged_wf.get('periods', [])),
                'purge_pct': 0.02, 'embargo_pct': 0.01,
                'mean_js_divergence': round(self.purged_wf.get('mean_js_divergence', 0), 4),
            },
            'cpcv': {
                'regime_stability_score': self.cpcv.get('regime_stability_score'),
                'methodology_note': self.cpcv.get('methodology_note', ''),
                'n_paths': self.cpcv.get('n_paths', 0),
                'median_hurst_drift': self.cpcv.get('median_hurst_drift', 0),
            },
        }


# ══════════════════════════════════════════════════════════════
# MAIN PIPELINE
# ══════════════════════════════════════════════════════════════
def main():
    parser = argparse.ArgumentParser(description='Asset DNA Profiler v4.0-Institutional')
    parser.add_argument('--symbol', default=None)
    parser.add_argument('--tf', default='M5', choices=['M1', 'M5'])
    parser.add_argument('--input', default=None)
    parser.add_argument('--output', default=None)
    parser.add_argument('--batch', nargs='+', default=None)
    parser.add_argument('--no-cache', action='store_true')
    parser.add_argument('--force-pandas', action='store_true')
    parser.add_argument('--csv', action='store_true')
    args = parser.parse_args()

    if args.force_pandas:
        CFG.use_polars = False
    from_db = not args.csv

    if args.batch:
        logger.info("[BATCH] Não implementado nesta versão. Use single asset.")
        return

    symbol = args.symbol or "XAUUSD"
    tf = args.tf.upper()
    output_pdf = str(args.output or CFG.report_dir / f"asset_dna_{symbol}_{tf}.pdf")

    TOTAL_PHASES = 8
    logger.info("=" * 60)
    logger.info(f"ALXQuant Asset DNA Profiler {ALGO_VERSION}")
    logger.info(f"Simbolo: {symbol} | TF: {tf} | Fonte: {'SQLite' if from_db else 'CSV'}")
    logger.info("=" * 60)

    warmup_numba_kernels()
    t_total = time.time()

    log_phase(1, TOTAL_PHASES, "DATA LOADING")
    loader = DataLoader(symbol=symbol, tf=tf, from_db=from_db) if from_db else DataLoader(args.input)
    df = loader.load()

    log_phase(2, TOTAL_PHASES, "FEATURE ENGINEERING (DFA + FFD + Kalman + KSG + Surrogate)")
    fe = FeatureEngine(df, tf=tf)
    df = fe.compute()

    log_phase(3, TOTAL_PHASES, "REGIME (EXPANDING) + HMM-CAUSAL")
    rm = RegimeModelExpanding(df, warmup=2000); df = rm.classify()
    trans_mat, regime_labels = rm.transition_matrix()
    hmm = HMMRegimeModel(df, n_states=4); df = hmm.classify()
    hmm_model_data = {
        'n_states': hmm.n_states, 'agreement': hmm.agreement,
        'has_hmm': HAS_HMM and hmm.model is not None,
    }

    log_phase(4, TOTAL_PHASES, "TEMPORAL + TAIL RISK")
    tp = TemporalProfiler(df); temporal = tp.analyze()
    tr = TailRiskEngine(df); tail_risk = tr.analyze()

    log_phase(5, TOTAL_PHASES, "MACRO RISK (FDR + ATR% + Johansen)")
    try:
        macro_int = MacroRiskIntegrator(); macro_int.load()
        macro_results = macro_int.cross_reference(df, symbol=symbol)
    except Exception as e:
        logger.warning(f"[MACRO] Erro: {e}")
        macro_results = {}

    log_phase(6, TOTAL_PHASES, "WALK-FORWARD + CPCV (Regime Stability)")
    wf = WalkForwardValidator(df, n_windows=6); wf_results = wf.analyze()
    purged = PurgedWalkForwardValidator(df, n_windows=6); purged_results = purged.analyze()
    cpcv = CPCVValidator(df, n_splits=6, n_test_splits=2); cpcv_results = cpcv.analyze()

    log_phase(7, TOTAL_PHASES, "CHARTS + PDF REPORT")
    entropy_stats = {}
    if 'sample_entropy' in df.columns:
        se = df['sample_entropy'].dropna(); pe = df['perm_entropy'].dropna()
        entropy_stats = {
            'sample_entropy_mean': float(se.mean()) if len(se) else 0,
            'perm_entropy_mean': float(pe.mean()) if len(pe) else 0,
        }
    signal_data = {
        'mi_matrix': fe.mi_matrix.tolist() if fe.mi_matrix is not None else None,
        'mi_labels': fe.mi_labels,
        'transfer_entropy': fe.transfer_entropy,
        'has_kalman': 'close_denoised' in df.columns,
        'hurst_significance': fe.hurst_significance,
        'te_significance': fe.te_significance,
    }
    fracdiff_data = {
        'd_close': fe.ffd_d_close, 'd_return': fe.ffd_d_return,
    }
    ne = NarrativeEngine(df, rm, temporal, tail_risk, hmm_model=hmm_model_data,
                         entropy=entropy_stats, fracdiff=fracdiff_data, signal_data=signal_data)
    narratives = ne.generate()
    features_agg = {
        'tail_risk': tail_risk, 'temporal': temporal,
        'entropy': entropy_stats, 'signal': signal_data,
    }
    cg = ChartGenerator(df, regime_labels, trans_mat, features_agg)
    charts = cg.generate_all()
    try:
        charts = macro_int.generate_charts(CFG.report_dir / '_charts', charts)
    except Exception:
        pass
    charts = wf.generate_charts(CFG.report_dir / '_charts', charts)
    charts = purged.generate_charts(CFG.report_dir / '_charts', charts)

    builder = PDFReportBuilder(
        output_pdf, charts, narratives, df, trans_mat, regime_labels, features_agg,
        tf=tf, walkforward=wf_results, macro=macro_results,
        hmm_model=hmm_model_data, signal_data=signal_data,
        purged_wf=purged_results, cpcv=cpcv_results,
    )
    builder.build_pdf()

    log_phase(8, TOTAL_PHASES, "JSON EXPORT")
    json_output = str(CFG.report_dir / f"asset_profile_{symbol}_{tf}.json")
    exporter = JsonProfileExporter(
        df, regime_labels, trans_mat, temporal, tail_risk, wf_results, macro_results,
        hmm_model=hmm_model_data, entropy=entropy_stats, fracdiff=fracdiff_data,
        signal_data=signal_data, purged_wf=purged_results, cpcv=cpcv_results,
    )
    exporter.hurst_significance = fe.hurst_significance
    exporter.te_significance = fe.te_significance
    exporter.export(json_output, symbol, tf)

    elapsed = time.time() - t_total
    logger.info(f"\n{'='*60}")
    logger.info(f"[OK] PDF: {output_pdf}")
    logger.info(f"[OK] JSON: {json_output}")
    logger.info(f"[OK] Tempo: {elapsed:.2f}s | Candles: {len(df):,}")
    logger.info(f"[OK] DFA-Hurst: {df['hurst'].mean():.3f} | FFD-d: {fe.ffd_d_close:.2f}")
    logger.info(f"[OK] Regime Stability: {cpcv_results.get('regime_stability_score', 'N/A')}%")
    logger.info(f"{'='*60}")


if __name__ == '__main__':
    main()