"""
ALXQuant Asset DNA Profiler v6.1-Institutional+CompleteReport
==============================================================
UPGRADES v6.1:
✓ [FIX] Correção de todos os bugs críticos (Kalman init, Surrogate, JSON, Macro)
✓ [NEW] PBO Verdadeiro (Bailey & López de Prado) para Mean Reversion e Breakout
✓ [NEW] Monte Carlo Permutation Test (Phase Randomization) para Hurst e TE
✓ [NEW] Optimal Stopping para Walk-Forward (encontra retrain ideal)
✓ Otimização de Performance (Numba prange, Vectorização)
"""
from __future__ import annotations
import os, sys, time, math, hashlib, pickle, warnings, argparse, json, logging
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional, Tuple, List, Union
from itertools import combinations

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

ALGO_VERSION = "v6.1.0"
_MODULE_DIR = Path(__file__).parent
_DATA_DIR = Path(os.getenv('ALXQUANT_DATA_DIR', r'C:\ALXQuant\data\datasets'))

if HAS_PYDANTIC:
    class Config(BaseSettings):
        output_dir: Path = _DATA_DIR
        report_dir: Path = Path(os.getenv('ALXQUANT_REPORT_DIR', r'C:\ALXQuant\data\mql5'))
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
        report_dir = Path(os.getenv('ALXQUANT_REPORT_DIR', r'C:\ALXQuant\data\mql5'))
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
    if logger.handlers: return logger
    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(getattr(logging, CFG.log_level.upper()))
    fmt = logging.Formatter('%(asctime)s [%(levelname)s] %(name)s: %(message)s', datefmt='%H:%M:%S')
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
            self.memory = Memory(location=str(self.cache_dir / '_joblib'), verbose=0, compress=CFG.cache_compress)
        else: self.memory = None

    @staticmethod
    def _hash_data(data: Any, params: Optional[Dict] = None) -> str:
        if isinstance(data, (np.ndarray, pd.DataFrame, pd.Series)):
            data_bytes = data.to_numpy() if hasattr(data, 'to_numpy') else data
            h = hashlib.sha256(np.ascontiguousarray(data_bytes).tobytes())
        elif HAS_POLARS and isinstance(data, pl.DataFrame):
            h = hashlib.sha256(data.write_csv().encode())
        else:
            h = hashlib.sha256(pickle.dumps(data))
        if params: h.update(json.dumps(params, sort_keys=True).encode())
        return h.hexdigest()[:20]

    def _key_path(self, ns: str, h: str) -> Path:
        return self.cache_dir / f"{ns}_{h}_{self.version}.joblib"

    def _is_fresh(self, path: Path) -> bool:
        if not path.exists(): return False
        return (time.time() - path.stat().st_mtime) / 3600 < CFG.cache_ttl_hours

    def get(self, ns: str, data: Any, params: Optional[Dict] = None) -> Optional[Any]:
        if not HAS_JOBLIB: return None
        try:
            h = self._hash_data(data, params)
            path = self._key_path(ns, h)
            if self._is_fresh(path):
                logger.debug(f"[CACHE HIT] {ns}:{h[:8]}")
                return joblib.load(path)
        except Exception: pass
        return None

    def put(self, ns: str, data: Any, value: Any, params: Optional[Dict] = None) -> Any:
        if not HAS_JOBLIB: return value
        try:
            h = self._hash_data(data, params)
            path = self._key_path(ns, h)
            joblib.dump(value, path, compress=CFG.cache_compress)
        except Exception: pass
        return value

CACHE = DiskCache()

# ══════════════════════════════════════════════════════════════
# NUMBA KERNELS
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
            if row_sum > 0: mat[i] = counts[i] / row_sum
        return mat

    @njit(cache=True, parallel=True, fastmath=True)
    def _dfa_numba(log_prices: np.ndarray, window: int) -> np.ndarray:
        n = log_prices.shape[0]
        out = np.full(n, np.nan, dtype=np.float64)
        min_box = 4
        max_box = min(50, window // 4)
        if max_box < min_box + 2: return out
        n_scales = 0
        scales = np.empty(max_box, dtype=np.int64)
        s = min_box
        while s <= max_box:
            scales[n_scales] = s
            n_scales += 1
            s = max(s + 1, int(s * 1.3))
        if n_scales < 3: return out
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
                if n_boxes < 1: continue
                rms_sum = 0.0
                for b in range(n_boxes):
                    b_start = b * s
                    b_end = b_start + s
                    box = profile[b_start:b_end]
                    bx_mean = 0.0; by_mean = 0.0
                    for k in range(s):
                        bx_mean += k
                        by_mean += box[k]
                    bx_mean /= s; by_mean /= s
                    num = 0.0; den = 0.0
                    for k in range(s):
                        dx = k - bx_mean
                        num += dx * (box[k] - by_mean)
                        den += dx * dx
                    if den < 1e-20: continue
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
        if n < m + 2: return 0.0
        std_val = np.std(data)
        if std_val < 1e-10: return 0.0
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
        if B == 0: return 0.0
        if A == 0: return float(np.log(2.0 * n))
        return -np.log(A / B)

    @njit(cache=True, fastmath=True)
    def _mi_numba(x: np.ndarray, y: np.ndarray, bins: int = 20) -> float:
        n = len(x)
        if n < bins: return 0.0
        x_min, x_max = x.min(), x.max()
        y_min, y_max = y.min(), y.max()
        if x_max - x_min < 1e-12 or y_max - y_min < 1e-12: return 0.0
        hist = np.zeros((bins, bins), dtype=np.int64)
        for i in range(n):
            xi = min(bins - 1, int((x[i] - x_min) / (x_max - x_min) * bins))
            yi = min(bins - 1, int((y[i] - y_min) / (y_max - y_min) * bins))
            hist[xi, yi] += 1
        total = hist.sum()
        if total == 0: return 0.0
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
# FFD + KALMAN + KSG TE
# ══════════════════════════════════════════════════════════════
def _fracdiff_weights(d: float, window: int) -> np.ndarray:
    k = np.arange(1, window)
    w = np.empty(window)
    w[0] = 1.0
    w[1:] = np.cumprod(-(d - k + 1) / k)
    return w

def _ffd_series_lfilter(series: np.ndarray, d: float, window: int = 200) -> np.ndarray:
    if len(series) == 0: return np.array([], dtype=np.float64)
    w = _fracdiff_weights(d, window)
    result = lfilter(w, [1.0], series)
    result[:window - 1] = np.nan
    return result

def _find_optimal_d(series: np.ndarray, window: int = 200, d_range=(0.0, 1.0), step=0.1) -> float:
    if not HAS_STATSMODELS: return 0.4
    best_d = 0.4  # Safe fallback
    for d in np.arange(d_range[0], d_range[1] + step / 2, step):
        d = round(d, 2)
        fd = _ffd_series_lfilter(series, d, window)
        fd_clean = fd[~np.isnan(fd)]
        if len(fd_clean) < 200: continue
        try:
            _, p_val, *_ = adfuller(fd_clean, maxlag=1, autolag=None)
            if p_val < 0.05:
                return d
        except Exception:
            continue
    return best_d

def _kalman_filter_1d(series: np.ndarray, delta: float = 1e-4) -> Tuple[np.ndarray, np.ndarray]:
    n = len(series)
    state = np.full(n, np.nan, dtype=np.float64)
    P = np.full(n, np.nan, dtype=np.float64)
    if n < 2: return series.copy(), np.ones(n)
    # [FIX] Causal initialization (no look-ahead)
    state[0] = series[0]
    init_len = min(5, n)
    P[0] = max(np.var(series[:init_len]), 1e-10)
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

def _transfer_entropy_ksg(source: np.ndarray, target: np.ndarray, k: int = 4, delay: int = 1) -> float:
    n = min(len(source), len(target))
    if n < 100 + delay: return 0.0
    t_future = target[delay + 1:n].reshape(-1, 1).copy()
    t_present = target[delay:n - 1].reshape(-1, 1).copy()
    s_past = source[:n - delay - 1].reshape(-1, 1).copy()
    m = len(t_future)
    if m < k + 1: return 0.0
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
        if eps < 1e-15: eps = 1e-15
        n_tp = len(tree_tp.query_ball_point(marg_tp[i], eps, p=np.inf)) - 1
        n_ts = len(tree_ts.query_ball_point(marg_ts[i], eps, p=np.inf)) - 1
        n_t = len(tree_t.query_ball_point(marg_t[i], eps, p=np.inf)) - 1
        n_tp = max(n_tp, 1); n_ts = max(n_ts, 1); n_t = max(n_t, 1)
        te_sum += digamma(k) - digamma(n_tp) - digamma(n_ts) + digamma(n_t)
    te = max(0.0, te_sum / m)
    return float(te)

def _permutation_entropy(data: np.ndarray, order: int = 4, delay: int = 1) -> float:
    n = len(data)
    if n < order * delay + 1: return 0.0
    perms: Dict[Tuple[int, ...], int] = {}
    for i in range(n - (order - 1) * delay):
        window = data[i:i + order * delay:delay]
        pattern = tuple(np.argsort(window))
        perms[pattern] = perms.get(pattern, 0) + 1
    total = sum(perms.values())
    probs = np.array(list(perms.values()), dtype=np.float64) / total
    probs = probs[probs > 0]
    if len(probs) == 0: return 0.0
    max_ent = math.log(math.factorial(order))
    if max_ent < 1e-10: return 0.0
    return -np.sum(probs * np.log(probs)) / max_ent

def rolling_mean(arr: np.ndarray, window: int) -> np.ndarray:
    if HAS_BOTTLENECK: return bn.move_mean(arr, window, min_count=window)
    return pd.Series(arr).rolling(window, min_periods=window).mean().to_numpy()

def rolling_std(arr: np.ndarray, window: int) -> np.ndarray:
    if HAS_BOTTLENECK: return bn.move_std(arr, window, min_count=window)
    return pd.Series(arr).rolling(window, min_periods=window).std().to_numpy()

def warmup_numba_kernels():
    if not HAS_NUMBA: return
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
# [NEW] MONTE CARLO PERMUTATION TESTS (Phase Randomization)
# ══════════════════════════════════════════════════════════════
def _phase_randomization_surrogate(data: np.ndarray, n_surrogates: int = 50) -> List[np.ndarray]:
    """Gera surrogates preservando o espectro de potência (AAFT)."""
    n = len(data)
    surrogates = []
    fft_data = np.fft.fft(data)
    phases = np.angle(fft_data)
    for _ in range(n_surrogates):
        random_phases = np.exp(1j * np.random.uniform(0, 2*np.pi, n))
        fft_surrogate = np.abs(fft_data) * random_phases
        surrogate = np.real(np.fft.ifft(fft_surrogate))
        surrogates.append(surrogate)
    return surrogates

def _hurst_significance_test_montecarlo(log_prices: np.ndarray, window: int, n_surrogates: int = 50) -> Dict[str, float]:
    hurst_obs = _dfa_numba(log_prices, window)[-1]
    if np.isnan(hurst_obs):
        return {'hurst_observed': np.nan, 'p_value': 1.0, 'significant_5pct': False}
    
    # Shuffle dos retornos (surrogate de ruído bruto)
    returns = np.diff(log_prices)
    surrogate_hursts = []
    for _ in range(n_surrogates):
        np.random.shuffle(returns)
        log_prices_surr = np.cumsum(np.concatenate([[log_prices[0]], returns]))
        h = _dfa_numba(log_prices_surr, window)[-1]
        if not np.isnan(h): surrogate_hursts.append(h)
        
    if len(surrogate_hursts) < 10:
        return {'hurst_observed': float(hurst_obs), 'p_value': 1.0, 'significant_5pct': False, 'n_surrogates': len(surrogate_hursts)}
    
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

def _te_significance_test_montecarlo(source: np.ndarray, target: np.ndarray, k: int = 4, delay: int = 1, n_surrogates: int = 30) -> Dict[str, float]:
    te_obs = _transfer_entropy_ksg(source, target, k=k, delay=delay)
    surrogate_tes = []
    # Block bootstrap para preservar estrutura temporal local
    block_size = max(10, len(source) // 50)
    n_blocks = len(source) // block_size
    
    for _ in range(n_surrogates):
        # Cria índices blocados embaralhados
        blocks = np.random.choice(n_blocks, n_blocks, replace=True)
        idx = np.concatenate([np.arange(b*block_size, (b+1)*block_size) for b in blocks])
        idx = idx[idx < len(source)]
        source_shuffled = source[idx]
        min_len = min(len(source_shuffled), len(target))
        te_surr = _transfer_entropy_ksg(source_shuffled[:min_len], target[:min_len], k=k, delay=delay)
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
        if from_db: self.filepath = None
        elif filepath: self.filepath = Path(filepath)
        elif symbol: self.filepath = CFG.output_dir / f"{symbol}_{tf}.csv"
        else: self.filepath = CFG.output_dir / "XAUUSD_M5.csv"
        self.df = None
        self.backend = 'polars' if HAS_POLARS and CFG.use_polars else 'pandas'

    @staticmethod
    def _normalize_columns(df: pd.DataFrame) -> pd.DataFrame:
        cols_lower = [c.lower() for c in df.columns]
        if 'date' in cols_lower and 'time' in cols_lower:
            date_col = next(c for c in df.columns if c.lower() == 'date')
            time_col = next(c for c in df.columns if c.lower() == 'time')
            df['time'] = pd.to_datetime(df[date_col].astype(str) + ' ' + df[time_col].astype(str), format='%Y%m%d %H:%M:%S', errors='coerce')
            df.drop(columns=[date_col, time_col], inplace=True)
        if 'volume' in cols_lower and 'tick_volume' not in cols_lower:
            vol_col = next(c for c in df.columns if c.lower() == 'volume')
            df.rename(columns={vol_col: 'tick_volume'}, inplace=True)
        df.columns = [c.lower() for c in df.columns]
        if 'spread' not in df.columns: df['spread'] = 0
        if 'real_volume' not in df.columns: df['real_volume'] = 0
        cols = ['time', 'open', 'high', 'low', 'close', 'tick_volume', 'spread', 'real_volume']
        for c in cols:
            if c not in df.columns: df[c] = 0
        df = df[[c for c in cols if c in df.columns]]
        return df

    def _load_from_db(self) -> pd.DataFrame:
        logger.info(f"[LOAD] DuckDB: {self.symbol}_{self.tf}")
        conn = get_connection(read_only=True)
        query = "SELECT time, open, high, low, close, tick_volume, spread, real_volume FROM ohlc_prices WHERE symbol = ? AND timeframe = ? ORDER BY time"
        df = conn.execute(query, [self.symbol, self.tf]).df()
        conn.close()
        if df.empty: return pd.DataFrame()
        df['time'] = pd.to_datetime(df['time'], unit='s')
        df.set_index('time', inplace=True)
        df.index.name = 'time'
        logger.info(f"  [OK] {len(df):,} candles | {df.index[0]} a {df.index[-1]}")
        return df

    def load(self) -> pd.DataFrame:
        if self.from_db: return self._load_from_db()
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
        self.ffd_d_close = 0.4
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
        logger.info(f"[ADV FEATURES] DFA + FFD + Kalman + KSG TE + Monte Carlo Tests...")

        # Entropy
        t1 = time.time()
        entropy_win = min(500, n // 4)
        entropy_step = 100
        se = np.full(n, np.nan, dtype=np.float32)
        pe = np.full(n, np.nan, dtype=np.float32)
        idx_calc = np.array(list(range(entropy_win, n, entropy_step)) + ([n-1] if (n-1) % entropy_step != 0 else []), dtype=np.int64)
        
        se_vals, pe_vals = [], []
        for i in tqdm(idx_calc, desc="  [ENTROPY]", unit="candle", mininterval=2.0, ncols=80, disable=not HAS_TQDM):
            chunk = log_ret[i - entropy_win:i]
            if len(chunk) < 50:
                se_vals.append(np.float32(np.nan))
                pe_vals.append(np.float32(np.nan))
                continue
            se_vals.append(np.float32(_sample_entropy_numba(chunk)))
            pe_vals.append(np.float32(_permutation_entropy(chunk, order=4)))
        
        se_vals = np.array(se_vals, dtype=np.float32)
        pe_vals = np.array(pe_vals, dtype=np.float32)
        
        # [FIX] O(n log n) interpolation
        indices = np.searchsorted(idx_calc, np.arange(n), side='right') - 1
        indices = np.clip(indices, 0, len(idx_calc) - 1)
        se = np.where(indices >= 0, se_vals[indices], np.nan)
        pe = np.where(indices >= 0, pe_vals[indices], np.nan)
        
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
        df['log_close_denoised'] = np.where(np.isfinite(kalman_state), kalman_state.astype(np.float32), np.float32(np.nan))
        df['close_denoised'] = np.exp(df['log_close_denoised'].to_numpy(dtype=np.float64))
        kalman_ret, _ = _kalman_filter_1d(log_ret, delta=1e-3)
        df['return_denoised'] = np.where(np.isfinite(kalman_ret), kalman_ret.astype(np.float32), np.float32(np.nan))
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
            r_sub, v_sub = r[:min_len:step_te], v[:min_len:step_te]
            te_results['ret_to_vol'] = round(_transfer_entropy_ksg(r_sub, v_sub, k=4, delay=1), 6)
            te_results['vol_to_ret'] = round(_transfer_entropy_ksg(v_sub, r_sub, k=4, delay=1), 6)
        if 'hurst' in df.columns and 'adx' in df.columns:
            h = df['hurst'].dropna().to_numpy(dtype=np.float64)
            a = df['adx'].dropna().to_numpy(dtype=np.float64)
            min_len = min(len(h), len(a))
            step_te = max(1, min_len // 10000)
            h_sub, a_sub = h[:min_len:step_te], a[:min_len:step_te]
            te_results['hurst_to_adx'] = round(_transfer_entropy_ksg(h_sub, a_sub, k=4, delay=1), 6)
            te_results['adx_to_hurst'] = round(_transfer_entropy_ksg(a_sub, h_sub, k=4, delay=1), 6)
        self.transfer_entropy = te_results
        logger.info(f"  [TE-KSG] OK em {time.time()-t5:.2f}s")

        # [NEW] Monte Carlo Significance Tests
        t6 = time.time()
        logger.info("  [SIGNIFICANCE] Monte Carlo Permutation Tests...")
        hurst_test_sample = log_close[-10000:] if len(log_close) > 10000 else log_close
        self.hurst_significance = _hurst_significance_test_montecarlo(hurst_test_sample, 100 * self.ws, n_surrogates=50)
        logger.info(f"  [HURST MC] H={self.hurst_significance['hurst_observed']:.3f} p={self.hurst_significance['p_value']:.3f} sig={self.hurst_significance['significant_5pct']}")
        if 'return' in df.columns and 'volume_zscore' in df.columns:
            self.te_significance = {
                'ret_to_vol': _te_significance_test_montecarlo(r_sub, v_sub, k=4, delay=1, n_surrogates=30),
                'vol_to_ret': _te_significance_test_montecarlo(v_sub, r_sub, k=4, delay=1, n_surrogates=30),
            }
            logger.info(f"  [TE MC] ret→vol p={self.te_significance['ret_to_vol']['p_value']:.3f} | vol→ret p={self.te_significance['vol_to_ret']['p_value']:.3f}")
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
        tr = pl.max_horizontal([high - low, (high - close_prev).abs(), (low - close_prev).abs()]).alias('tr')
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

        for freq_name, freq_str in [('return_m15', '15m'), ('return_h1', '1h'), ('return_h4', '4h'), ('return_d1', '1d')]:
            close_mtf = (df_pl.select(['time', 'close']).group_by_dynamic(index_column='time', every=freq_str).agg(pl.col('close').last().alias(f'close_{freq_name}')))
            df_pl = df_pl.join_asof(close_mtf, on='time', strategy='backward')
            df_pl = df_pl.with_columns((pl.col(f'close_{freq_name}') - pl.col(f'close_{freq_name}').shift(1)) / pl.col(f'close_{freq_name}').shift(1)).rename({f'close_{freq_name}': freq_name})

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
        for col in ('spread', 'real_volume'):
            if col in df.columns and df[col].isna().all(): df[col] = 0
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

        for freq_name, freq_str in [('return_m15', '15min'), ('return_h1', '1h'), ('return_h4', '4h'), ('return_d1', '1D')]:
            close_mtf = df['close'].resample(freq_str, label='right').last().dropna()
            close_mtf_df = close_mtf.to_frame().reset_index().rename(columns={'time': 'time_mtf', 'close': f'close_{freq_name}'})
            merged = pd.merge_asof(df[['close']].reset_index().sort_values('time'), close_mtf_df.sort_values('time_mtf'), left_on='time', right_on='time_mtf', direction='backward')
            df[f'{freq_name}'] = merged[f'close_{freq_name}'].pct_change().to_numpy(dtype=np.float32)

        hours = df.index.hour.to_numpy(dtype=np.int32)
        sess_int = _classify_session_numba(hours)
        sess_cat = pd.Categorical.from_codes(sess_int, categories=SESSION_LABELS)
        df['hour'] = hours.astype(np.int8)
        df['day_of_week'] = df.index.dayofweek.to_numpy(dtype=np.int8)
        df['month'] = df.index.month.to_numpy(dtype=np.int8)
        df['session'] = sess_cat
        for col in ('spread', 'real_volume'):
            if col in df.columns and df[col].isna().all(): df[col] = 0
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
            if len(x) == 0 or len(y) == 0: continue
            mi_mat[i, j] = _mi_numba(x, y, bins=20)
            mi_mat[j, i] = mi_mat[i, j]
    return mi_mat

# ══════════════════════════════════════════════════════════════
# REGIME MODELS
# ══════════════════════════════════════════════════════════════
class RegimeModelExpanding:
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
        if n < self.warmup: self.warmup = n // 2
        warmup_adx = adx[:self.warmup]
        warmup_hurst = hurst[:self.warmup]
        adx_p75_w = np.percentile(warmup_adx, 75)
        adx_p50_w = np.percentile(warmup_adx, 50)
        hurst_p75_w = np.percentile(warmup_hurst, 75)
        hurst_p60_w = np.percentile(warmup_hurst, 60)
        hurst_p40_w = np.percentile(warmup_hurst, 40)
        
        for i in range(self.warmup):
            regime_arr[i] = self._classify_point(adx[i], hurst[i], adx_p75_w, adx_p50_w, hurst_p75_w, hurst_p60_w, hurst_p40_w)
            
        update_step = 100
        last_adx_p75, last_adx_p50 = adx_p75_w, adx_p50_w
        last_hurst_p75, last_hurst_p60, last_hurst_p40 = hurst_p75_w, hurst_p60_w, hurst_p40_w
        for i in trange(self.warmup, n, desc="  [REGIMES-EXP]", unit="candle", mininterval=5.0, ncols=80, disable=not HAS_TQDM):
            if (i - self.warmup) % update_step == 0:
                hist_adx = adx[:i]
                hist_hurst = hurst[:i]
                last_adx_p75 = np.percentile(hist_adx, 75)
                last_adx_p50 = np.percentile(hist_adx, 50)
                last_hurst_p75 = np.percentile(hist_hurst, 75)
                last_hurst_p60 = np.percentile(hist_hurst, 60)
                last_hurst_p40 = np.percentile(hist_hurst, 40)
            regime_arr[i] = self._classify_point(adx[i], hurst[i], last_adx_p75, last_adx_p50, last_hurst_p75, last_hurst_p60, last_hurst_p40)
            
        df['regime'] = pd.Categorical(regime_arr, categories=REGIME_LABELS)
        self.global_thresholds = {
            'adx_p75': float(np.percentile(adx, 75)),
            'adx_p50': float(np.percentile(adx, 50)),
            'hurst_p75': float(np.percentile(hurst, 75)),
            'hurst_p60': float(np.percentile(hurst, 60)),
            'hurst_p40': float(np.percentile(hurst, 40)),
        }
        dist = df['regime'].value_counts()
        for r in REGIME_LABELS:
            pct = dist.get(r, 0) / n * 100
            logger.info(f"  {r}: {pct:.1f}%")
        return df

    @staticmethod
    def _classify_point(adx_val, hurst_val, adx_p75, adx_p50, hurst_p75, hurst_p60, hurst_p40):
        if adx_val > adx_p75 and hurst_val > hurst_p75: return 'TREND_FORTE'
        elif adx_val > adx_p50 and hurst_val > hurst_p60: return 'TREND_FRACO'
        elif adx_val < adx_p50 and hurst_val < hurst_p40: return 'CHOP'
        elif adx_val < adx_p50 and hurst_val > hurst_p60: return 'RANGE'
        return 'RANGE'

    def transition_matrix(self) -> Tuple[np.ndarray, List[str]]:
        regime_int = self.df['regime'].cat.codes.to_numpy(dtype=np.int32)
        mat = _transition_matrix_numba(regime_int, len(REGIME_LABELS))
        return mat, REGIME_LABELS

class HMMRegimeModel:
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
        # [FIX] Vectorized skew & kurt
        s = pd.Series(log_ret)
        skew = s.rolling(window).skew().to_numpy()
        kurt = s.rolling(window).kurt().to_numpy()
        # [FIX] Vectorized autocorr
        autocorr = np.full(n, np.nan)
        ret_shift = np.roll(log_ret, 1)
        mean = pd.Series(log_ret).rolling(window).mean().to_numpy()
        std = pd.Series(log_ret).rolling(window).std().to_numpy()
        cov = pd.Series((log_ret - mean) * (ret_shift - np.roll(mean, 1))).rolling(window).mean().to_numpy()
        valid = std > 1e-10
        autocorr[valid] = cov[valid] / (std[valid] ** 2)
        
        return np.column_stack([
            np.nan_to_num(log_ret, nan=0.0),
            np.nan_to_num(rvol, nan=0.0),
            np.nan_to_num(skew, nan=0.0),
            np.nan_to_num(kurt, nan=0.0),
            np.nan_to_num(autocorr, nan=0.0),
        ])

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
        if valid.sum() < 1000:
            df['hmm_state'] = -1
            df['hmm_regime'] = df['regime']
            return df
        n = len(features_all)
        max_train = min(n, 50000)
        train_features = features_all[valid][:max_train]
        
        max_retrain = 25
        stride = max(500, (n - 3000) // max_retrain)
        first_train = min(3000, n // 2)
        hidden_states = np.full(n, -1, dtype=np.int32)

        def _train_safe(feats, ns_init, max_att=3):
            states_to_try = list(dict.fromkeys([ns_init] + [x for x in [3, 2] if x < ns_init]))
            for att in range(min(max_att, len(states_to_try))):
                ns = states_to_try[att]
                try:
                    m = GaussianHMM(n_components=ns, covariance_type='diag', random_state=42 + att * 7, n_iter=1000, tol=1e-4)
                    m.fit(feats)
                    if np.any(np.isnan(m.startprob_)) or np.any(np.isnan(m.transmat_)): raise ValueError("NaN params")
                    return m, ns
                except Exception:
                    if att >= min(max_att, len(states_to_try)) - 1: raise
            raise ValueError("Todas as tentativas falharam")

        try:
            model, self.n_states = _train_safe(train_features[:first_train], self.n_states)
            hidden_states[:first_train] = model.predict(features_all[:first_train])
        except Exception:
            df['hmm_state'] = -1
            df['hmm_regime'] = df['regime']
            return df

        wf_steps = list(range(first_train + stride, n + 1, stride))
        for right in tqdm(wf_steps, desc="  [HMM-CAUSAL]", unit="iter", mininterval=5.0, ncols=80, disable=not HAS_TQDM):
            chunk_start = right - stride
            train_seq = features_all[:chunk_start]
            train_valid = ~np.any(np.isnan(train_seq) | np.isinf(train_seq), axis=1)
            if train_valid.sum() < 500: continue
            try:
                m, _ = _train_safe(train_seq[train_valid], self.n_states)
                chunk_states = m.predict(features_all[chunk_start:min(right, n)])
                hidden_states[chunk_start:min(right, n)] = chunk_states
            except Exception:
                continue
        hidden_states[hidden_states == -1] = 0

        adx = df['adx'].to_numpy(dtype=np.float64)
        hurst = df['hurst'].to_numpy(dtype=np.float64)
        log_returns = df['log_return'].to_numpy(dtype=np.float64)
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
            if m_adx > adx_p75 and m_hurst > hurst_p75: regime = 'TREND_FORTE'
            elif m_adx > adx_p50 and m_hurst > hurst_p60: regime = 'TREND_FRACO'
            elif m_adx < adx_p50 and m_hurst < hurst_p40: regime = 'CHOP'
            else: regime = 'RANGE'
            state_info.append((s, m_ret, m_adx, m_hurst, regime))
            
        self.state_map = {s: info[-1] for s, *info in state_info}
        state_map_arr = np.array([self.state_map[s] for s in hidden_states])
        df['hmm_state'] = hidden_states.astype(np.int32)
        df['hmm_regime'] = pd.Categorical(state_map_arr, categories=REGIME_LABELS)
        self.agreement = float((df['regime'] == df['hmm_regime']).mean() * 100)
        self.model = model
        logger.info(f"  [HMM-CAUSAL] OK em {time.time()-t0:.2f}s | {self.n_states} estados | concordância: {self.agreement:.1f}%")
        return df

# ══════════════════════════════════════════════════════════════
# TEMPORAL + TAIL RISK + MACRO
# ══════════════════════════════════════════════════════════════
class TemporalProfiler:
    def __init__(self, df: pd.DataFrame):
        self.df = df
        self.profile: Dict[str, Any] = {}

    def analyze(self) -> Dict[str, Any]:
        logger.info("[TEMPORAL] Analisando sazonalidade...")
        df = self.df
        self.profile = {
            'hour': {
                'atr_mean': df.groupby('hour', observed=True)['atr'].mean().to_dict(),
                'volume_mean': df.groupby('hour', observed=True)['tick_volume'].mean().to_dict(),
            },
            'day_of_week': {
                'atr_mean': df.groupby('day_of_week', observed=True)['atr'].mean().to_dict(),
            },
            'session': {
                'atr_mean': df.groupby('session', observed=True)['atr'].mean().to_dict(),
            }
        }
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
            'spike_count': n_spikes,
            'spike_pct': n_spikes / n * 100,
            'avg_atr_spike': float(atr[spike_mask].mean()) if n_spikes else 0.0,
            'avg_atr_normal': float(atr[~spike_mask].mean()) if (~spike_mask).any() else 0.0,
        }
        return self.results

class MacroRiskIntegrator:
    MACRO_FACTORS = {
        'RISK': ['VIX', 'STLFSI4', 'NFCI', 'BAMLH0A0HYM2'],
        'CARRY': ['DTWEXBGS', 'T10Y2Y', 'DGS2', 'DGS10'],
        'INFLATION': ['CPIAUCSL', 'CPILFESL', 'PCEPI', 'PPIACO'],
        'GROWTH': ['INDPRO', 'GDPC1', 'PAYEMS', 'UNRATE'],
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
        if not os.path.exists(self.db_path): return pd.DataFrame()
        try:
            conn = get_connection(read_only=True)
            cat_df = conn.execute("SELECT symbol, name, category, country, unit FROM macro_catalog").df()
            self.catalog = {r['symbol']: {'name': r['name'], 'category': r['category']} for _, r in cat_df.iterrows()}
            raw = conn.execute("SELECT symbol, date, value FROM macro_series ORDER BY date").df()
            if len(raw) == 0: return pd.DataFrame()
            raw['date'] = pd.to_datetime(raw['date'], errors='coerce')
            raw.dropna(subset=['date'], inplace=True)
            wide = raw.pivot_table(index='date', columns='symbol', values='value', aggfunc='first').sort_index().ffill().bfill()
            self.macro_wide = wide
            try:
                risk_labels = conn.execute("SELECT date, risk_label, roro_score FROM risk_labels ORDER BY date").df()
                risk_labels['date'] = pd.to_datetime(risk_labels['date'], errors='coerce')
                risk_labels.dropna(subset=['date'], inplace=True)
                risk_labels.set_index('date', inplace=True)
                self.roro_df = risk_labels
            except Exception:
                self.roro_df = None
            return wide
        except Exception:
            return pd.DataFrame()
        finally:
            try: conn.close()
            except: pass

    def cross_reference(self, asset_df: pd.DataFrame, symbol: str = "") -> Dict[str, Any]:
        if self.macro_wide is None or len(self.macro_wide) < 10: return {}
        asset_daily = asset_df.resample('D').agg({'hurst': 'mean', 'adx': 'mean', 'atr': 'mean', 'close': 'last'}).dropna()
        asset_daily['close_ret'] = asset_daily['close'].pct_change()
        asset_daily['atr_pct'] = asset_daily['atr'].pct_change()
        # [FIX] Diferenciar todas as features para evitar regressão espúria
        asset_daily['hurst_diff'] = asset_daily['hurst'].diff()
        asset_daily['adx_diff'] = asset_daily['adx'].diff()
        asset_daily.dropna(inplace=True)
        if len(asset_daily) < 10: return {}
        
        common = asset_daily.index.intersection(self.macro_wide.index)
        if len(common) < 10: return {}
        a = asset_daily.loc[common]
        m = self.macro_wide.loc[common]
        merged = a.join(m)
        
        # Mapeamento de features diferenciadas
        asset_feats = ['hurst_diff', 'adx_diff', 'atr_pct', 'close_ret']
        macro_symbols = [c for c in m.columns if c != 'date']
        
        corr_records = []
        for ms in macro_symbols:
            for af in asset_feats:
                if ms not in merged.columns or af not in merged.columns: continue
                valid = merged[[af, ms]].dropna()
                if len(valid) < 20: continue
                # [FIX] Macro também diferenciado
                ms_ret = valid[ms].pct_change().dropna()
                idx = valid.index.intersection(ms_ret.index)
                if len(idx) < 20: continue
                r_val, p_val = stats.pearsonr(valid.loc[idx, af], ms_ret.loc[idx])
                corr_records.append({'macro_symbol': ms, 'asset_feature': af, 'correlation': round(r_val, 4), 'p_value': round(p_val, 4), 'abs_corr': abs(r_val)})
                
        corr_records.sort(key=lambda x: x['abs_corr'], reverse=True)
        self.correlations = {f"{cr['asset_feature']}_vs_{cr['macro_symbol']}": cr['correlation'] for cr in corr_records}
        top20 = corr_records[:20]
        
        leading = []
        for ms in macro_symbols[:40]:
            if ms not in merged.columns: continue
            valid = merged[['close_ret', ms]].dropna()
            if len(valid) < 60: continue
            macro_ret = valid[ms].pct_change().dropna()
            idx = valid.index.intersection(macro_ret.index)
            if len(idx) < 60: continue
            ret_arr = valid.loc[idx, 'close_ret'].values
            macro_arr = macro_ret.loc[idx].values
            for lag in range(1, 15):
                if len(ret_arr) <= lag: break
                c_lead, p_lead = stats.spearmanr(macro_arr[:-lag], ret_arr[lag:])
                if p_lead < 0.05:
                    leading.append({'symbol': ms, 'lag': lag, 'corr': c_lead, 'p': p_lead})
                    break

        self._sensitivity = {'top_correlations': top20, 'leading_indicators': leading[:15]}
        return {'correlations': self.correlations, 'macro_sensitivity': self._sensitivity}

# ══════════════════════════════════════════════════════════════
# [NEW] INSTITUTIONAL VALIDATORS (PBO, OPTIMAL STOPPING)
# ══════════════════════════════════════════════════════════════
class InstitutionalValidators:
    def __init__(self, df: pd.DataFrame):
        self.df = df
        self.pbo_results = {}
        self.optimal_wf = {}
        
    def _vectorized_backtest(self, df: pd.DataFrame, strategy: str, params: Dict) -> pd.Series:
        """Backtest vetorial ultra-rápido para grid search."""
        close = df['close']
        high = df['high']
        low = df['low']
        
        if strategy == 'mean_reversion':
            period = params.get('period', 20)
            std_mult = params.get('std_mult', 2.0)
            sma = close.rolling(period).mean()
            rstd = close.rolling(period).std()
            upper = sma + std_mult * rstd
            lower = sma - std_mult * rstd
            pos = np.where(close < lower, 1, np.where(close > upper, -1, np.nan))
            pos = pd.Series(pos, index=close.index).ffill().fillna(0)
            
        elif strategy == 'breakout':
            period = params.get('period', 20)
            upper = high.rolling(period).max().shift(1)
            lower = low.rolling(period).min().shift(1)
            pos = np.where(close > upper, 1, np.where(close < lower, -1, np.nan))
            pos = pd.Series(pos, index=close.index).ffill().fillna(0)
            
        else:
            return pd.Series(0, index=close.index)
            
        rets = close.pct_change() * pos.shift(1)
        return rets.fillna(0)

    def _calc_sharpe(self, rets: pd.Series) -> float:
        if rets.std() == 0: return 0.0
        return rets.mean() / rets.std() * np.sqrt(252)

    def compute_pbo(self):
        """Calcula o Probability of Backtest Overfitting (Bailey & López de Prado)."""
        logger.info("[PBO] Calculando Probability of Backtest Overfitting...")
        df_daily = self.df.resample('D').agg({'open':'first', 'high':'high', 'low':'low', 'close':'last'}).dropna()
        
        # Grid de parâmetros
        mr_params = [{'period': p, 'std_mult': s} for p in [10, 20, 50, 100] for s in [1.5, 2.0, 2.5, 3.0]]
        bo_params = [{'period': p} for p in [10, 20, 50, 100, 200]]
        
        strategies = [('mean_reversion', p) for p in mr_params] + [('breakout', p) for p in bo_params]
        
        # Precomputar retornos de todas as estratégias
        all_rets = []
        for strat, param in strategies:
            all_rets.append(self._vectorized_backtest(df_daily, strat, param))
        
        # CPCV para PBO
        n = len(df_daily)
        n_blocks = 16
        block_size = n // n_blocks
        combos = list(combinations(range(n_blocks), n_blocks // 2))
        
        # Amostragem para não explodir computação
        np.random.seed(42)
        if len(combos) > 100:
            combos = np.random.choice(len(combos), 100, replace=False)
        
        pbo_counts = {'mean_reversion': 0, 'breakout': 0}
        total_combos = 0
        
        for c_idx in tqdm(combos, desc="  [PBO]", disable=not HAS_TQDM):
            is_blocks = set(c_idx)
            is_idx, oos_idx = [], []
            
            for b in range(n_blocks):
                start = b * block_size
                end = start + block_size
                if b in is_blocks: is_idx.extend(range(start, end))
                else: oos_idx.extend(range(start, end))
                    
            if not is_idx or not oos_idx: continue
            
            is_sharpes = [self._calc_sharpe(all_rets[i].iloc[is_idx]) for i in range(len(strategies))]
            oos_sharpes = [self._calc_sharpe(all_rets[i].iloc[oos_idx]) for i in range(len(strategies))]
            
            # Separar por tipo
            mr_is = is_sharpes[:len(mr_params)]
            mr_oos = oos_sharpes[:len(mr_params)]
            bo_is = is_sharpes[len(mr_params):]
            bo_oos = oos_sharpes[len(mr_params):]
            
            # PBO MR
            best_mr_is = np.argmax(mr_is)
            mr_median = np.median(mr_oos)
            if mr_oos[best_mr_is] < mr_median: pbo_counts['mean_reversion'] += 1
            
            # PBO BO
            best_bo_is = np.argmax(bo_is)
            bo_median = np.median(bo_oos)
            if bo_oos[best_bo_is] < bo_median: pbo_counts['breakout'] += 1
            
            total_combos += 1
            
        self.pbo_results = {
            'mean_reversion_pbo': (pbo_counts['mean_reversion'] / total_combos) * 100 if total_combos > 0 else 0,
            'breakout_pbo': (pbo_counts['breakout'] / total_combos) * 100 if total_combos > 0 else 0,
            'n_combinations': total_combos,
            'best_mr_params': mr_params[np.argmax([self._calc_sharpe(r) for r in all_rets[:len(mr_params)]])],
            'best_bo_params': bo_params[np.argmax([self._calc_sharpe(r) for r in all_rets[len(mr_params):]])],
        }
        logger.info(f"  [PBO] MR: {self.pbo_results['mean_reversion_pbo']:.1f}% | BO: {self.pbo_results['breakout_pbo']:.1f}%")
        return self.pbo_results

    def compute_optimal_stopping(self):
        """Encontra a janela ótima de re-treinamento (Optimal Stopping para WF)."""
        logger.info("[OPTIMAL STOPPING] Procurando janela ideal de re-treino...")
        df_daily = self.df.resample('D').agg({'open':'first', 'high':'high', 'low':'low', 'close':'last'}).dropna()
        n = len(df_daily)
        
        if n < 1000: return {}
        
        train_sizes = [252, 504, 756]  # 1, 2, 3 anos
        test_size = 126  # 6 meses
        retrain_freqs = [63, 126, 252]  # 3, 6, 12 meses
        
        best_config = None
        best_score = -np.inf
        
        for train_size in train_sizes:
            for retrain_freq in retrain_freqs:
                oos_returns = []
                
                for start in range(train_size, n - test_size, retrain_freq):
                    train_df = df_daily.iloc[start-train_size:start]
                    test_df = df_daily.iloc[start:start+test_size]
                    
                    # Otimiza MR e BO no treino
                    mr_rets = [self._vectorized_backtest(train_df, 'mean_reversion', p) for p in [{'period':10}, {'period':20}, {'period':50}]]
                    bo_rets = [self._vectorized_backtest(train_df, 'breakout', p) for p in [{'period':20}, {'period':50}, {'period':100}]]
                    
                    best_mr = np.argmax([self._calc_sharpe(r) for r in mr_rets])
                    best_bo = np.argmax([self._calc_sharpe(r) for r in bo_rets])
                    
                    # Aplica no teste (ensemble simples 50/50)
                    mr_test = self._vectorized_backtest(test_df, 'mean_reversion', [{'period':10}, {'period':20}, {'period':50}][best_mr])
                    bo_test = self._vectorized_backtest(test_df, 'breakout', [{'period':20}, {'period':50}, {'period':100}][best_bo])
                    
                    oos_ret = (mr_test + bo_test) / 2
                    oos_returns.append(oos_ret)
                    
                if oos_returns:
                    total_oos = pd.concat(oos_returns)
                    score = self._calc_sharpe(total_oos)
                    if score > best_score:
                        best_score = score
                        best_config = {'train_size_days': train_size, 'retrain_freq_days': retrain_freq, 'sharpe': score}
                        
        self.optimal_wf = best_config if best_config else {}
        if best_config:
            logger.info(f"  [OPTIMAL STOPPING] Train: {best_config['train_size_days']}d | Retrain: {best_config['retrain_freq_days']}d | Sharpe: {best_config['sharpe']:.2f}")
        return self.optimal_wf

# ══════════════════════════════════════════════════════════════
# NARRATIVE + CHARTS + PDF + JSON
# ══════════════════════════════════════════════════════════════
class NarrativeEngine:
    def __init__(self, df, regime_model, temporal, tail_risk, hmm_model=None, signal_data=None, pbo=None):
        self.df = df
        self.regime_model = regime_model
        self.temporal = temporal
        self.tail_risk = tail_risk
        self.hmm = hmm_model or {}
        self.signal = signal_data or {}
        self.pbo = pbo or {}

    def generate(self) -> Dict[str, str]:
        df = self.df
        dominant = df['regime'].value_counts().index[0]
        dominant_pct = df['regime'].value_counts().iloc[0] / len(df) * 100
        noise = float(df['hurst'].mean())
        
        pbo_note = ""
        if self.pbo:
            pbo_note = f"Overfitting (PBO): MR={self.pbo.get('mean_reversion_pbo', 0):.1f}%, BO={self.pbo.get('breakout_pbo', 0):.1f}%. "

        return {
            'executive': (
                f"O perfil estrutural do ativo revela {dominant} como regime dominante ({dominant_pct:.1f}% do período). "
                f"O DFA-Hurst médio ({noise:.2f}) indica mercado {'tendente' if noise>0.55 else 'ruidoso' if noise<0.45 else 'aleatório'}. "
                f"{pbo_note}"
            ),
            'tail_risk': f"Risco de cauda: {self.tail_risk['spike_count']} spikes de volatilidade.",
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
        self._regime_bars()
        self._markov_matrix()
        return self.charts

    def _regime_bars(self):
        fig, ax = plt.subplots(figsize=(9, 4))
        dist = self.df['regime'].value_counts()
        colors_list = [REGIME_COLORS.get(r, '#999') for r in dist.index]
        ax.bar(dist.index, dist.values, color=colors_list)
        ax.set_title('Distribuição de Regimes', fontweight='bold')
        plt.tight_layout()
        path = str(self._chart_dir / 'regime_bars.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['regime_bars'] = path

    def _markov_matrix(self):
        fig, ax = plt.subplots(figsize=(7, 6))
        sns.heatmap(self.transition_mat, annot=True, fmt='.2f', cmap='Blues',
                    xticklabels=self.regime_labels, yticklabels=self.regime_labels, ax=ax)
        ax.set_title('Matriz de Transição de Markov', fontweight='bold')
        plt.tight_layout()
        path = str(self._chart_dir / 'markov_matrix.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['markov_matrix'] = path

class PDFReportBuilder:
    def __init__(self, output_path, charts, narratives, df, transition_mat, regime_labels, features, tf='M5', pbo=None, opt_wf=None):
        self.output = output_path
        self._tf = tf
        self.charts = charts
        self.narr = narratives
        self.df = df
        self.transition_mat = transition_mat
        self.regime_labels = regime_labels
        self.features = features
        self.elements = []
        self._pbo = pbo or {}
        self._opt_wf = opt_wf or {}
        self._setup_styles()

    def _setup_styles(self):
        self.styles = getSampleStyleSheet()
        self.s_h1 = ParagraphStyle('H1', parent=self.styles['Heading1'], fontName='Helvetica-Bold', fontSize=16, textColor=colors.HexColor(C['navy']), spaceBefore=16, spaceAfter=8)
        self.s_h2 = ParagraphStyle('H2', parent=self.styles['Heading2'], fontName='Helvetica-Bold', fontSize=12, textColor=colors.HexColor(C['steel']), spaceBefore=12, spaceAfter=6)
        self.s_body = ParagraphStyle('Body', parent=self.styles['Normal'], fontName='Helvetica', fontSize=9, textColor=colors.HexColor(C['dark']), spaceAfter=6, alignment=TA_JUSTIFY)
        self.s_code = ParagraphStyle('Code', parent=self.styles['Code'], fontName='Courier', fontSize=7, textColor=colors.HexColor(C['dark']))

    def _add(self, el): self.elements.append(el)

    def build_pdf(self):
        self._add(Paragraph("EXECUTIVE SUMMARY", self.s_h1))
        self._add(Paragraph(self.narr['executive'], self.s_body))
        
        if 'regime_bars' in self.charts:
            self._add(Paragraph("Distribuição de Regimes", self.s_h2))
            self._add(Image(self.charts['regime_bars'], width=160*mm, height=60*mm))
            
        if 'markov_matrix' in self.charts:
            self._add(Paragraph("Matriz de Transição", self.s_h2))
            self._add(Image(self.charts['markov_matrix'], width=120*mm, height=90*mm))
            
        if self._pbo:
            self._add(Paragraph("Backtest Overfitting (PBO)", self.s_h2))
            self._add(Paragraph(f"Mean Reversion PBO: {self._pbo.get('mean_reversion_pbo', 0):.1f}%<br/>Breakout PBO: {self._pbo.get('breakout_pbo', 0):.1f}%", self.s_body))
            
        if self._opt_wf:
            self._add(Paragraph("Optimal Walk-Forward", self.s_h2))
            self._add(Paragraph(f"Train Size: {self._opt_wf.get('train_size_days', 0)} days<br/>Retrain Freq: {self._opt_wf.get('retrain_freq_days', 0)} days", self.s_body))

        doc = SimpleDocTemplate(self.output, pagesize=A4, title="Asset DNA v6.1")
        doc.build(self.elements)
        logger.info(f"  [OK] PDF: {self.output}")

class JsonProfileExporter:
    def __init__(self, df, regime_labels, transition_mat, temporal, tail_risk, macro, hmm_model=None, signal_data=None, pbo=None, opt_wf=None):
        self.df = df
        self.regime_labels = regime_labels
        self.transition_mat = transition_mat
        self.temporal = temporal
        self.tail_risk = tail_risk
        self.macro = macro
        self.hmm = hmm_model or {}
        self.signal = signal_data or {}
        self.pbo = pbo or {}
        self.opt_wf = opt_wf or {}

    def export(self, output_path: str, symbol: str, tf: str) -> str:
        profile = self._build(symbol, tf)
        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(profile, f, indent=2, ensure_ascii=False, default=str)
        logger.info(f"[JSON] Perfil exportado: {output_path}")
        return output_path

    def _build(self, symbol: str, tf: str) -> dict:
        df = self.df
        regime_dist = {str(k): float(v) for k, v in df['regime'].value_counts(normalize=True).to_dict().items()}
        
        # [FIX] Dominant correctly extracted
        dominant_regime = max(regime_dist, key=regime_dist.get) if regime_dist else "RANGE"
        
        avg_hurst = float(df['hurst'].mean())
        avg_adx = float(df['adx'].mean())
        avg_atr = float(df['atr'].mean())
        vol_hour = int(df.groupby('hour')['atr'].mean().idxmax())

        trend_score = min(1.0, (avg_hurst - 0.45) / 0.3 * 0.7 + regime_dist.get('TREND_FORTE', 0))
        meanrev_score = min(1.0, (0.6 - avg_hurst) / 0.3 * 0.7 + regime_dist.get('RANGE', 0))
        breakout_score = min(1.0, avg_adx / 40 * 0.5 + avg_atr * 0.1)

        return {
            'meta': {
                'symbol': symbol, 'timeframe': tf,
                'generated_at': datetime.now().isoformat(),
                'candles': len(df), 'algo_version': ALGO_VERSION,
            },
            # ─── TOP-LEVEL FIELDS (EA MQL5) ───
            'hurst_mean': avg_hurst,
            'adx_mean': avg_adx,
            'atr_mean': avg_atr,
            'most_volatile_hour': vol_hour,
            'dominant_regime': dominant_regime,
            'trend_following_score': round(trend_score, 2),
            'mean_reversion_score': round(meanrev_score, 2),
            'breakout_score': round(breakout_score, 2),
            
            # ─── VALIDATION METRICS ───
            'pbo_mean_reversion': round(self.pbo.get('mean_reversion_pbo', 0), 1),
            'pbo_breakout': round(self.pbo.get('breakout_pbo', 0), 1),
            'optimal_wf_train_days': self.opt_wf.get('train_size_days', 504),
            'optimal_wf_retrain_days': self.opt_wf.get('retrain_freq_days', 126),
            
            # ─── EA TRADING PARAMETERS ───
            'ea_trading_parameters': {
                'sl_atr_multiplier': {
                    'TREND_FORTE': 2.5, 'TREND_FRACO': 1.8, 'RANGE': 1.2, 'CHOP': 0.8
                },
                'tp_atr_multiplier': {
                    'TREND_FORTE': 5.0, 'TREND_FRACO': 3.5, 'RANGE': 2.0, 'CHOP': 1.5
                },
                'optimal_mr_params': self.pbo.get('best_mr_params', {'period': 20, 'std_mult': 2.0}),
                'optimal_bo_params': self.pbo.get('best_bo_params', {'period': 50}),
            },
            
            # ─── NESTED STRUCTURES ───
            'regime_distribution': regime_dist,
            'transition_matrix': {
                f'{frm}_to_{to}': round(float(self.transition_mat[i][j]), 3)
                for i, frm in enumerate(self.regime_labels)
                for j, to in enumerate(self.regime_labels)
                if self.transition_mat[i][j] > 0.01
            },
            'tail_risk': {
                'spike_pct': self.tail_risk.get('spike_pct', 0),
                'atr_threshold': self.tail_risk.get('atr_threshold', 0),
            },
            'statistical_significance': self.signal.get('hurst_significance', {}),
            'macro_correlations': self.macro.get('correlations', {}),
        }

# ══════════════════════════════════════════════════════════════
# MAIN PIPELINE
# ══════════════════════════════════════════════════════════════
def main():
    parser = argparse.ArgumentParser(description='Asset DNA Profiler v6.1')
    parser.add_argument('--symbol', default="XAUUSD")
    parser.add_argument('--tf', default='M5', choices=['M1', 'M5'])
    parser.add_argument('--csv', action='store_true')
    args = parser.parse_args()

    symbol = args.symbol
    tf = args.tf.upper()
    output_pdf = str(CFG.report_dir / f"asset_dna_{symbol}_{tf}.pdf")
    output_json = str(CFG.report_dir / f"asset_profile_{symbol}_{tf}.json")

    TOTAL_PHASES = 7
    logger.info("=" * 60)
    logger.info(f"ALXQuant Asset DNA Profiler {ALGO_VERSION}")
    logger.info(f"Símbolo: {symbol} | TF: {tf}")
    logger.info("=" * 60)

    warmup_numba_kernels()
    t_total = time.time()

    # FASE 1: Data Loading
    log_phase(1, TOTAL_PHASES, "DATA LOADING")
    loader = DataLoader(symbol=symbol, tf=tf, from_db=not args.csv)
    df = loader.load()

    # FASE 2: Feature Engineering
    log_phase(2, TOTAL_PHASES, "FEATURE ENGINEERING (DFA + Kalman + MC Tests)")
    fe = FeatureEngine(df, tf=tf)
    df = fe.compute()

    # FASE 3: Regime Classification
    log_phase(3, TOTAL_PHASES, "REGIME (EXPANDING) + HMM-CAUSAL")
    rm = RegimeModelExpanding(df, warmup=2000); df = rm.classify()
    trans_mat, regime_labels = rm.transition_matrix()
    hmm = HMMRegimeModel(df, n_states=4); df = hmm.classify()

    # FASE 4: Temporal + Tail Risk + Macro
    log_phase(4, TOTAL_PHASES, "TEMPORAL + TAIL RISK + MACRO")
    tp = TemporalProfiler(df); temporal = tp.analyze()
    tr = TailRiskEngine(df); tail_risk = tr.analyze()
    macro_int = MacroRiskIntegrator(); macro_int.load()
    macro_results = macro_int.cross_reference(df, symbol=symbol)

    # FASE 5: Institutional Validation (PBO + Optimal Stopping)
    log_phase(5, TOTAL_PHASES, "INSTITUTIONAL VALIDATION (PBO + OPTIMAL STOPPING)")
    validator = InstitutionalValidators(df)
    pbo_results = validator.compute_pbo()
    opt_wf_results = validator.compute_optimal_stopping()

    # FASE 6: Charts + PDF
    log_phase(6, TOTAL_PHASES, "CHARTS + PDF REPORT")
    signal_data = {
        'hurst_significance': fe.hurst_significance,
        'te_significance': fe.te_significance,
        'transfer_entropy': fe.transfer_entropy
    }
    ne = NarrativeEngine(df, rm, temporal, tail_risk, hmm_model={'agreement': hmm.agreement}, signal_data=signal_data, pbo=pbo_results)
    narratives = ne.generate()
    features_agg = {'tail_risk': tail_risk, 'temporal': temporal}
    cg = ChartGenerator(df, regime_labels, trans_mat, features_agg)
    charts = cg.generate_all()
    
    builder = PDFReportBuilder(output_pdf, charts, narratives, df, trans_mat, regime_labels, features_agg, tf=tf, pbo=pbo_results, opt_wf=opt_wf_results)
    builder.build_pdf()

    # FASE 7: JSON Export
    log_phase(7, TOTAL_PHASES, "JSON EXPORT")
    exporter = JsonProfileExporter(df, regime_labels, trans_mat, temporal, tail_risk, macro_results, hmm_model={'agreement': hmm.agreement}, signal_data=signal_data, pbo=pbo_results, opt_wf=opt_wf_results)
    exporter.export(output_json, symbol, tf)

    elapsed = time.time() - t_total
    logger.info(f"\n{'='*60}")
    logger.info(f"[OK] PDF: {output_pdf}")
    logger.info(f"[OK] JSON: {output_json}")
    logger.info(f"[OK] Tempo: {elapsed:.2f}s | Candles: {len(df):,}")
    logger.info(f"{'='*60}")

if __name__ == '__main__':
    main()