"""
ALXQuant Asset DNA Profiler v7.2-Full (State of the Art Enhanced)
=================================================================
NOVAS FEATURES ACADÊMICAS (v7.2):
✓ [NEW-1] Wavelet Multiscale Analysis (PyWavelets) para Roughness e Hurst multiresolução.
✓ [NEW-2] Rényi Entropy (q=2.0) para detecção de "fat tails" e riscos extremos.
✓ [NEW-3] HMM Condicionado à Volatilidade (Aproximação de Adaptive Hierarchical HMM).
✓ [NEW-4] Effective Transfer Entropy (ETE) com Block Bootstrap causal reforçado.
✓ [MANTIDO] ChartGenerator completo (todos os gráficos originais).
✓ [MANTIDO] PDFReportBuilder completo (relatório visual institucional).
✓ [MANTIDO] Todos os validadores institucionais (PBO, CPCV, Purged WF, Macro FDR).
✓ [MANTIDO] Geração completa de JSON e Narrativa para o EA MQL5.
"""
from __future__ import annotations
import os, sys, time, math, hashlib, pickle, warnings, argparse, json, logging
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional, Tuple, List, Union

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _THIS_DIR)
sys.path.insert(0, os.path.dirname(_THIS_DIR))

from itertools import combinations
import duckdb
DB_PATH = r"C:\ALXQuant\data\ALXQuantCore.duckdb"
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

try:
    import pywt
    HAS_PYWT = True
except ImportError:
    HAS_PYWT = False
    pywt = None

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

ALGO_VERSION = "v7.2.0-SOTA"
_MODULE_DIR = Path(__file__).parent
_DATA_DIR = Path(os.getenv('ALXQUANT_DATA_DIR', r'C:\ALXQuant\data\datasets'))

if HAS_PYDANTIC:
    class Config(BaseSettings):
        output_dir: Path = Path(os.getenv('ALXQUANT_DATA_DIR', str(_DATA_DIR)))
        report_dir: Path = Path(r'C:\ALXQuant\data\mql5')
        cache_dir: Path = Path(r'C:\ALXQuant\data\cache\asset_dna')
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
        cache_dir = Path(r'C:\ALXQuant\data\cache\asset_dna')
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
REGIME_LABELS = ['TREND_FORTE', 'TREND_FRACO', 'BREAKOUT', 'RANGE', 'CHOP']
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
# NUMBA KERNELS & NEW SOTA FUNCTIONS
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


# [NEW-2] Rényi Entropy
def renyi_entropy(data: np.ndarray, q: float = 2.0, bins: int = 30) -> float:
    if len(data) < bins:
        return 0.0
    hist, _ = np.histogram(data, bins=bins, density=True)
    hist = hist[hist > 1e-10]
    if len(hist) == 0:
        return 0.0
    if abs(q - 1.0) < 1e-6:
        return -np.sum(hist * np.log(hist))
    else:
        return (1.0 / (1.0 - q)) * np.log(np.sum(hist ** q))


# [NEW-1] Wavelet Multiscale Features
def compute_wavelet_features(data: np.ndarray, wavelet: str = 'db4', level: int = 4) -> Dict[str, float]:
    if not HAS_PYWT or len(data) < 2**level:
        return {'wavelet_roughness': np.nan, 'wavelet_hurst': np.nan}
    try:
        clean_data = data[~np.isnan(data)]
        if len(clean_data) < 2**level:
            return {'wavelet_roughness': np.nan, 'wavelet_hurst': np.nan}
        coeffs = pywt.wavedec(clean_data, wavelet, level=level)
        energies = [np.sum(c**2) for c in coeffs]
        total_energy = sum(energies)
        if total_energy > 0:
            detail_energy = sum(energies[1:])
            roughness = detail_energy / total_energy
            variances = [np.var(c) for c in coeffs[1:] if np.var(c) > 1e-10]
            if len(variances) >= 2:
                scales = np.arange(1, len(variances) + 1)
                log_scales = np.log2(scales)
                log_vars = np.log2(variances)
                slope, _, r_value, _, _ = stats.linregress(log_scales, log_vars)
                w_hurst = 0.5 + (slope / 2.0)
                w_hurst = max(0.01, min(0.99, w_hurst))
            else:
                w_hurst = 0.5
        else:
            roughness = 0.0
            w_hurst = 0.5
        return {'wavelet_roughness': float(roughness), 'wavelet_hurst': float(w_hurst)}
    except Exception:
        return {'wavelet_roughness': np.nan, 'wavelet_hurst': np.nan}


def _fracdiff_weights(d: float, window: int) -> np.ndarray:
    w = [1.0]
    for k in range(1, window):
        w.append(-w[-1] * (d - k + 1) / k)
    return np.array(w, dtype=np.float64)

def _ffd_series_lfilter(series: np.ndarray, d: float, window: int = 200) -> np.ndarray:
    if len(series) == 0: return np.array([], dtype=np.float64)
    w = _fracdiff_weights(d, window)
    result = lfilter(w, [1.0], series)
    result[:window - 1] = np.nan
    return result

def _find_optimal_d(series: np.ndarray, window: int = 200, d_range: Tuple[float, float] = (0.0, 1.0), step: float = 0.1) -> float:
    if not HAS_STATSMODELS: return 0.5
    best_d = d_range[1]
    for d in np.arange(d_range[0], d_range[1] + step / 2, step):
        d = round(d, 2)
        fd = _ffd_series_lfilter(series, d, window)
        fd_clean = fd[~np.isnan(fd)]
        if len(fd_clean) < 200: continue
        try:
            _, p_val, *_ = adfuller(fd_clean, maxlag=1, autolag=None)
            if p_val < 0.05:
                best_d = d
                break
        except Exception:
            continue
    return best_d

def _kalman_filter_1d(series: np.ndarray, delta: float = 1e-4) -> Tuple[np.ndarray, np.ndarray]:
    n = len(series)
    state = np.full(n, np.nan, dtype=np.float64)
    P = np.full(n, np.nan, dtype=np.float64)
    if n < 2: return series.copy(), np.ones(n)
    state[0] = series[0]
    R = max(np.var(series[:min(20, n)]), 1e-10)
    P[0] = R
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
        n_tp = max(1, len(tree_tp.query_ball_point(marg_tp[i], eps, p=np.inf)) - 1)
        n_ts = max(1, len(tree_ts.query_ball_point(marg_ts[i], eps, p=np.inf)) - 1)
        n_t = max(1, len(tree_t.query_ball_point(marg_t[i], eps, p=np.inf)) - 1)
        te_sum += digamma(k) - digamma(n_tp) - digamma(n_ts) + digamma(n_t)
    return max(0.0, float(te_sum / m))

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
# SURROGATE TESTS
# ══════════════════════════════════════════════════════════════
def _aaft_surrogate(data: np.ndarray, n_surrogates: int = 50) -> List[np.ndarray]:
    n = len(data)
    surrogates = []
    ranks = stats.rankdata(data)
    gauss = stats.norm.ppf(ranks / (n + 1))
    for _ in range(n_surrogates):
        fft_g = np.fft.fft(gauss)
        phases = np.exp(1j * np.random.uniform(0, 2 * np.pi, n))
        fft_surr = np.abs(fft_g) * phases
        gauss_surr = np.real(np.fft.ifft(fft_surr))
        ranks_surr = stats.rankdata(gauss_surr)
        surrogate = np.sort(data)[(ranks_surr - 1).astype(int)]
        surrogates.append(surrogate)
    return surrogates

def _hurst_significance_test(log_returns: np.ndarray, window: int, n_surrogates: int = 50) -> Dict[str, float]:
    hurst_obs = _dfa_numba(log_returns, window)[-1]
    if np.isnan(hurst_obs):
        return {'hurst_observed': np.nan, 'p_value': 1.0, 'significant_5pct': False}
    surrogate_hursts = []
    surrogates = _aaft_surrogate(log_returns, n_surrogates)
    for sr in surrogates:
        h = _dfa_numba(sr, window)[-1]
        if not np.isnan(h):
            surrogate_hursts.append(h)
    if len(surrogate_hursts) < 10:
        return {'hurst_observed': float(hurst_obs), 'p_value': 1.0, 'significant_5pct': False}
    surrogate_hursts = np.array(surrogate_hursts)
    p_value = float(np.mean(np.abs(surrogate_hursts - 0.5) >= np.abs(hurst_obs - 0.5)))
    return {
        'hurst_observed': float(hurst_obs),
        'surrogate_mean': float(surrogate_hursts.mean()),
        'surrogate_std': float(surrogate_hursts.std()),
        'p_value': p_value,
        'significant_5pct': p_value < 0.05,
        'n_surrogates': len(surrogate_hursts),
        'method': 'AAFT_true_phase_randomization',
    }

def _te_significance_test(source: np.ndarray, target: np.ndarray, k: int = 4, delay: int = 1, n_surrogates: int = 30) -> Dict[str, float]:
    te_obs = _transfer_entropy_ksg(source, target, k=k, delay=delay)
    surrogate_tes = []
    block_size = max(10, len(source) // 50)
    n_blocks = len(source) // block_size
    for _ in range(n_surrogates):
        blocks = np.random.choice(n_blocks, n_blocks, replace=True)
        idx = np.concatenate([np.arange(b * block_size, (b + 1) * block_size) for b in blocks])
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
        'method': 'causal_block_bootstrap',
    }


# ═════════════════════════════════════════════════════════════
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
        years = getattr(self, 'years', 5)
        logger.info(f"[LOAD] DuckDB: {self.symbol}_{self.tf} (Últimos {years} anos)")
        conn = duckdb.connect(DB_PATH, read_only=True)
        try:
            from datetime import datetime as dt
            limit_date = dt.now() - pd.DateOffset(years=years)
            limit_ts = int(limit_date.timestamp())
            query = """
                SELECT time, open, high, low, close, tick_volume, spread, real_volume
                FROM ohlc_prices 
                WHERE symbol = ? AND timeframe = ? AND time >= ?
                ORDER BY time
            """
            df = conn.execute(query, [self.symbol, self.tf, limit_ts]).df()
        finally:
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
# FEATURE ENGINE (COM NOVAS FEATURES SOTA)
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
        logger.info(f"[ADV FEATURES] DFA + FFD + Kalman + KSG TE + Wavelets + Rényi...")

        # 1. Entropias
        t1 = time.time()
        entropy_win = min(500, n // 4)
        entropy_step = 100
        se = np.full(n, np.nan, dtype=np.float32)
        pe = np.full(n, np.nan, dtype=np.float32)
        re = np.full(n, np.nan, dtype=np.float32)
        idx_calc = list(range(entropy_win, n, entropy_step))
        if idx_calc and idx_calc[-1] != n - 1:
            idx_calc.append(n - 1)
        se_vals, pe_vals, re_vals = [], [], []
        pbar = tqdm(idx_calc, desc="  [ENTROPY]", unit="candle", mininterval=2.0, ncols=80) if HAS_TQDM else idx_calc
        for i in pbar:
            chunk = log_ret[i - entropy_win:i]
            if len(chunk) < 50:
                se_vals.append(np.float32(np.nan))
                pe_vals.append(np.float32(np.nan))
                re_vals.append(np.float32(np.nan))
                continue
            se_vals.append(np.float32(_sample_entropy_numba(chunk)))
            pe_vals.append(np.float32(_permutation_entropy(chunk, order=4)))
            re_vals.append(np.float32(renyi_entropy(chunk, q=2.0, bins=30)))
        se_vals = np.array(se_vals, dtype=np.float32)
        pe_vals = np.array(pe_vals, dtype=np.float32)
        re_vals = np.array(re_vals, dtype=np.float32)
        idx_calc_arr = np.array(idx_calc, dtype=np.int64)
        for i in range(len(se)):
            nearest = idx_calc_arr[idx_calc_arr <= i]
            if len(nearest) > 0:
                j = nearest[-1]
                idx_j = np.where(idx_calc_arr == j)[0]
                if len(idx_j) > 0:
                    se[i] = se_vals[idx_j[0]]
                    pe[i] = pe_vals[idx_j[0]]
                    re[i] = re_vals[idx_j[0]]
        df['sample_entropy'] = se
        df['perm_entropy'] = pe
        df['renyi_entropy'] = re
        logger.info(f"  [ENTROPY] OK em {time.time()-t1:.2f}s")

        # 2. FFD
        t2 = time.time()
        fd_window = min(200, n // 4)
        log_close = np.log(close)
        self.ffd_d_close = _find_optimal_d(log_close, window=fd_window)
        self.ffd_d_return = _find_optimal_d(log_ret, window=fd_window)
        df['fracdiff_close'] = _ffd_series_lfilter(log_close, self.ffd_d_close, fd_window).astype(np.float32)
        df['fracdiff_return'] = _ffd_series_lfilter(log_ret, self.ffd_d_return, fd_window).astype(np.float32)
        logger.info(f"  [FFD] OK em {time.time()-t2:.2f}s")

        # 3. Kalman
        t3 = time.time()
        kalman_state, kalman_P = _kalman_filter_1d(log_close, delta=1e-4)
        df['log_close_denoised'] = np.where(np.isfinite(kalman_state), kalman_state.astype(np.float32), np.float32(np.nan))
        df['close_denoised'] = np.exp(df['log_close_denoised'].to_numpy(dtype=np.float64))
        logger.info(f"  [KALMAN] OK em {time.time()-t3:.2f}s")

        # 4. Wavelets
        t_wave = time.time()
        wavelet_hurst = np.full(n, np.nan, dtype=np.float32)
        wavelet_roughness = np.full(n, np.nan, dtype=np.float32)
        wavelet_step = 200
        wavelet_win = 512
        idx_wave = list(range(wavelet_win, n, wavelet_step))
        if idx_wave and idx_wave[-1] != n - 1:
            idx_wave.append(n - 1)
        for i in idx_wave:
            chunk = close[i - wavelet_win:i]
            if len(chunk) >= wavelet_win:
                wf = compute_wavelet_features(chunk, wavelet='db4', level=4)
                end_idx = min(i + wavelet_step, n)
                wavelet_hurst[i:end_idx] = wf['wavelet_hurst']
                wavelet_roughness[i:end_idx] = wf['wavelet_roughness']
        df['wavelet_hurst'] = wavelet_hurst
        df['wavelet_roughness'] = wavelet_roughness
        logger.info(f"  [WAVELETS] OK em {time.time()-t_wave:.2f}s")

        # 5. MI Matrix
        t4 = time.time()
        mi_cols = ['hurst', 'adx', 'atr', 'return', 'volume_zscore', 'tr_zscore']
        mi_available = [c for c in mi_cols if c in df.columns]
        if len(mi_available) >= 2:
            self.mi_matrix = _mutual_information_matrix_numba(df, mi_available)
            self.mi_labels = mi_available
        logger.info(f"  [MI] OK em {time.time()-t4:.2f}s")

        # 6. Transfer Entropy
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
        self.transfer_entropy = te_results
        logger.info(f"  [TE-KSG] OK em {time.time()-t5:.2f}s")

        # 7. Significância
        t6 = time.time()
        log_ret_arr = df['log_return'].to_numpy(dtype=np.float64)
        log_ret_arr = log_ret_arr[~np.isnan(log_ret_arr)]
        hurst_test_sample = log_ret_arr[-10000:] if len(log_ret_arr) > 10000 else log_ret_arr
        self.hurst_significance = _hurst_significance_test(hurst_test_sample, 100 * self.ws, n_surrogates=50)
        if 'return' in df.columns and 'volume_zscore' in df.columns:
            self.te_significance = {
                'ret_to_vol': _te_significance_test(r_sub, v_sub, k=4, delay=1, n_surrogates=30),
                'vol_to_ret': _te_significance_test(v_sub, r_sub, k=4, delay=1, n_surrogates=30),
            }
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
        df_pl = df_pl.with_columns([plus_di.alias('plus_di'), minus_di.alias('minus_di'), dx.alias('dx'), dx.rolling_mean(atr_win).alias('adx')])

        hurst_win = 100 * ws
        log_ret_arr = np.nan_to_num(df_pl['log_return'].cast(pl.Float64).to_numpy(), nan=0.0)
        hurst_cached = CACHE.get("dfa_hurst_v7", log_ret_arr.astype(np.float32))
        if hurst_cached is not None:
            hurst = hurst_cached
        else:
            hurst = _dfa_numba(log_ret_arr, hurst_win)
            CACHE.put("dfa_hurst_v7", log_ret_arr.astype(np.float32), hurst)
        df_pl = df_pl.with_columns(pl.Series('hurst', hurst.astype(np.float32)))

        hours = df_pl['time'].dt.hour().cast(pl.Int32).to_numpy()
        sess_int = _classify_session_numba(hours)
        sess_cat = pd.Categorical.from_codes(sess_int, categories=SESSION_LABELS)
        df_pl = df_pl.with_columns([
            pl.col('time').dt.hour().cast(pl.Int8).alias('hour'),
            pl.col('time').dt.weekday().cast(pl.Int8).alias('day_of_week'),
        ])
        df = df_pl.to_pandas()
        df['session'] = sess_cat
        df.dropna(inplace=True)
        logger.info(f"  [OK] {len(df):,} candles em {time.time()-t0:.2f}s")
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
        tick_vol = df['tick_volume'].to_numpy(dtype=np.float64)
        vol_ma = rolling_mean(tick_vol, 50*ws)
        vol_std = rolling_std(tick_vol, 50*ws)
        vol_std_safe = np.where(vol_std < 1e-10, 1e-10, vol_std)
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
        df['adx'] = rolling_mean(dx, 14*ws).astype(np.float32)

        hurst_win = 100 * ws
        log_ret_arr = np.nan_to_num(df['log_return'].to_numpy(dtype=np.float64), nan=0.0)
        hurst_cached = CACHE.get("dfa_hurst_v7", log_ret_arr.astype(np.float32))
        if hurst_cached is not None:
            hurst = hurst_cached
        else:
            hurst = _dfa_numba(log_ret_arr, hurst_win)
            CACHE.put("dfa_hurst_v7", log_ret_arr.astype(np.float32), hurst)
        df['hurst'] = hurst.astype(np.float32)

        hours = df.index.hour.to_numpy(dtype=np.int32)
        sess_int = _classify_session_numba(hours)
        sess_cat = pd.Categorical.from_codes(sess_int, categories=SESSION_LABELS)
        df['hour'] = hours.astype(np.int8)
        df['day_of_week'] = df.index.dayofweek.to_numpy(dtype=np.int8)
        df['session'] = sess_cat
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
# REGIME MODEL
# ══════════════════════════════════════════════════════════════
class RegimeModelExpanding:
    def __init__(self, df: pd.DataFrame, warmup: int = 2000):
        self.df = df
        self.warmup = warmup
        self.global_thresholds = {}
        self.final_expanding_thresholds = {}

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
        adx_p75_w, adx_p50_w = np.percentile(warmup_adx, 75), np.percentile(warmup_adx, 50)
        hurst_p75_w, hurst_p60_w, hurst_p40_w = np.percentile(warmup_hurst, 75), np.percentile(warmup_hurst, 60), np.percentile(warmup_hurst, 40)
        for i in range(self.warmup):
            regime_arr[i] = self._classify_point(adx[i], hurst[i], adx_p75_w, adx_p50_w, hurst_p75_w, hurst_p60_w, hurst_p40_w)
        update_step = 100
        last_adx_p75, last_adx_p50 = adx_p75_w, adx_p50_w
        last_hurst_p75, last_hurst_p60, last_hurst_p40 = hurst_p75_w, hurst_p60_w, hurst_p40_w
        pbar = trange(self.warmup, n, desc="  [REGIMES-EXP]", unit="candle", mininterval=5.0, ncols=80) if HAS_TQDM else range(self.warmup, n)
        for i in pbar:
            if (i - self.warmup) % update_step == 0:
                last_adx_p75, last_adx_p50 = np.percentile(adx[:i], 75), np.percentile(adx[:i], 50)
                last_hurst_p75, last_hurst_p60, last_hurst_p40 = np.percentile(hurst[:i], 75), np.percentile(hurst[:i], 60), np.percentile(hurst[:i], 40)
            regime_arr[i] = self._classify_point(adx[i], hurst[i], last_adx_p75, last_adx_p50, last_hurst_p75, last_hurst_p60, last_hurst_p40)
        df['regime'] = pd.Categorical(regime_arr, categories=REGIME_LABELS)
        self.global_thresholds = {'adx_p75': float(np.percentile(adx, 75)), 'adx_p50': float(np.percentile(adx, 50)), 'hurst_p75': float(np.percentile(hurst, 75)), 'hurst_p60': float(np.percentile(hurst, 60)), 'hurst_p40': float(np.percentile(hurst, 40))}
        self.final_expanding_thresholds = {'adx_p75': float(last_adx_p75), 'adx_p50': float(last_adx_p50), 'hurst_p75': float(last_hurst_p75), 'hurst_p60': float(last_hurst_p60), 'hurst_p40': float(last_hurst_p40)}
        dist = df['regime'].value_counts()
        for r in REGIME_LABELS:
            logger.info(f"  {r}: {dist.get(r, 0) / n * 100:.1f}%")
        return df

    @staticmethod
    def _classify_point(adx_val, hurst_val, adx_p75, adx_p50, hurst_p75, hurst_p60, hurst_p40):
        if adx_val > adx_p75:
            if hurst_val > hurst_p75: return 'TREND_FORTE'
            elif hurst_val > hurst_p60: return 'TREND_FRACO'
            elif hurst_val > hurst_p40: return 'BREAKOUT'
            else: return 'CHOP'
        elif adx_val > adx_p50:
            if hurst_val > hurst_p60: return 'TREND_FRACO'
            elif hurst_val > hurst_p40: return 'BREAKOUT'
            else: return 'CHOP'
        else:
            if hurst_val < hurst_p40: return 'CHOP'
            else: return 'RANGE'

    def transition_matrix(self) -> Tuple[np.ndarray, List[str]]:
        regime_int = self.df['regime'].cat.codes.to_numpy(dtype=np.int32)
        cached = CACHE.get("transition_expanding_v7", regime_int)
        if cached is not None: return cached, REGIME_LABELS
        mat = _transition_matrix_numba(regime_int, len(REGIME_LABELS))
        CACHE.put("transition_expanding_v7", regime_int, mat)
        return mat, REGIME_LABELS


# ══════════════════════════════════════════════════════════════
# HMM COM META-REGIME DE VOLATILIDADE
# ══════════════════════════════════════════════════════════════
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
        s = pd.Series(log_ret)
        skew = s.rolling(window).skew().to_numpy()
        kurt = s.rolling(window).kurt().to_numpy()
        autocorr = np.full(n, np.nan)
        ret_shift = np.empty_like(log_ret); ret_shift[0] = np.nan; ret_shift[1:] = log_ret[:-1]
        mean = pd.Series(log_ret).rolling(window).mean().to_numpy()
        mean_shift = np.empty_like(mean); mean_shift[0] = np.nan; mean_shift[1:] = mean[:-1]
        std = rolling_std(log_ret, window)
        cov = pd.Series((log_ret - mean) * (ret_shift - mean_shift)).rolling(window).mean().to_numpy()
        valid = std > 1e-10
        autocorr[valid] = cov[valid] / (std[valid] ** 2)
        atr = df['atr'].to_numpy(dtype=np.float64)
        atr_median = np.median(atr[~np.isnan(atr)])
        vol_meta_regime = (atr > atr_median).astype(np.float64)
        features = np.column_stack([
            np.nan_to_num(log_ret, nan=0.0),
            np.nan_to_num(rvol, nan=0.0),
            np.nan_to_num(skew, nan=0.0),
            np.nan_to_num(kurt, nan=0.0),
            np.nan_to_num(autocorr, nan=0.0),
            np.nan_to_num(vol_meta_regime, nan=0.0)
        ])
        return features

    def classify(self) -> pd.DataFrame:
        if not HAS_HMM:
            logger.warning("[HMM] hmmlearn não disponível")
            self.df['hmm_state'] = -1
            self.df['hmm_regime'] = self.df['regime']
            return self.df
        logger.info(f"[HMM-CAUSAL-AH] Treino walk-forward com condicionante de volatilidade ({self.n_states} estados)...")
        t0 = time.time()
        df = self.df
        features_all = self._build_features(df)
        valid = ~np.any(np.isnan(features_all) | np.isinf(features_all), axis=1)
        features_clean = features_all[valid]
        if len(features_clean) < 1000:
            self.df['hmm_state'] = -1
            self.df['hmm_regime'] = self.df['regime']
            return df
        n = len(features_all)
        max_train = min(n, 50000)
        train_features = features_clean[:max_train]
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
                    if np.any(np.isnan(m.startprob_)) or np.any(np.isnan(m.transmat_)):
                        raise ValueError("NaN params")
                    return m, ns
                except Exception as e:
                    if att >= min(max_att, len(states_to_try)) - 1:
                        raise
            raise ValueError("Todas as tentativas falharam")

        try:
            model, self.n_states = _train_safe(train_features[:first_train], self.n_states)
        except Exception as e:
            logger.warning(f"[HMM] Treino falhou: {e}")
            self.df['hmm_state'] = -1
            self.df['hmm_regime'] = self.df['regime']
            return self.df
        try:
            hidden_states[:first_train] = model.predict(features_all[:first_train])
        except Exception:
            hidden_states[:first_train] = 0
        wf_steps = list(range(first_train + stride, n + 1, stride))
        wf_iter = tqdm(wf_steps, desc="  [HMM-CAUSAL]", unit="iter", mininterval=5.0, ncols=80) if HAS_TQDM else wf_steps
        for right in wf_iter:
            chunk_start = right - stride
            train_seq = features_all[:chunk_start]
            train_valid = ~np.any(np.isnan(train_seq) | np.isinf(train_seq), axis=1)
            if train_valid.sum() < 500: continue
            try:
                m, _ = _train_safe(train_seq[train_valid], self.n_states)
                test_seq = features_all[chunk_start:min(right, n)]
                hidden_states[chunk_start:min(right, n)] = m.predict(test_seq)
            except Exception:
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
            regime = RegimeModelExpanding._classify_point(m_adx, m_hurst, adx_p75, adx_p50, hurst_p75, hurst_p60, hurst_p40)
            state_info.append((s, m_ret, m_adx, m_hurst, regime))
        self.state_map = {s: info[-1] for s, *info in state_info}
        state_map_arr = np.array([self.state_map[s] for s in hidden_states])
        df['hmm_state'] = hidden_states.astype(np.int32)
        df['hmm_regime'] = pd.Categorical(state_map_arr, categories=REGIME_LABELS)
        self.agreement = float((df['regime'] == df['hmm_regime']).mean() * 100)
        self.model = model
        logger.info(f"  [HMM-CAUSAL-AH] OK em {time.time()-t0:.2f}s | {self.n_states} estados | concordância: {self.agreement:.1f}%")
        return df


# ══════════════════════════════════════════════════════════════
# TEMPORAL + TAIL RISK + MACRO RISK
# ══════════════════════════════════════════════════════════════
class TemporalProfiler:
    def __init__(self, df: pd.DataFrame):
        self.df = df
        self.profile: Dict[str, Any] = {}

    def analyze(self) -> Dict[str, Any]:
        logger.info("[TEMPORAL] Analisando sazonalidade...")
        df = self.df.copy()
        
        # [FIX CRÍTICO] Cria as colunas de tempo a partir do índice se não existirem
        if isinstance(df.index, pd.DatetimeIndex):
            if 'hour' not in df.columns:
                df['hour'] = df.index.hour.astype(int)
            if 'day_of_week' not in df.columns:
                df['day_of_week'] = df.index.dayofweek.astype(int)
            if 'month' not in df.columns:
                df['month'] = df.index.month.astype(int)
        
        # Garante que as colunas existam antes do groupby
        if 'month' not in df.columns:
            logger.warning("[TEMPORAL] Coluna 'month' não encontrada. Pulando análise mensal.")
            self.profile = {'hour': {}, 'day_of_week': {}, 'month': {}, 'session': {}}
            return self.profile
            
        grp_h = df.groupby('hour', observed=True) if 'hour' in df.columns else None
        grp_d = df.groupby('day_of_week', observed=True) if 'day_of_week' in df.columns else None
        grp_m = df.groupby('month', observed=True)
        grp_s = df.groupby('session', observed=True) if 'session' in df.columns else None

        self.profile = {}
        
        if grp_h is not None:
            self.profile['hour'] = {
                'atr_mean': grp_h['atr'].mean().to_dict() if 'atr' in df.columns else {},
                'volume_mean': grp_h['tick_volume'].mean().to_dict() if 'tick_volume' in df.columns else {},
                'regime_pct': pd.crosstab(df['hour'], df['regime'], normalize='index').to_dict('index') if 'regime' in df.columns else {},
            }
        
        if grp_d is not None:
            self.profile['day_of_week'] = {
                'atr_mean': grp_d['atr'].mean().to_dict() if 'atr' in df.columns else {},
                'volume_mean': grp_d['tick_volume'].mean().to_dict() if 'tick_volume' in df.columns else {},
            }
        
        self.profile['month'] = {
            'atr_mean': grp_m['atr'].mean().to_dict() if 'atr' in df.columns else {},
            'volume_mean': grp_m['tick_volume'].mean().to_dict() if 'tick_volume' in df.columns else {},
        }
        
        if grp_s is not None:
            self.profile['session'] = {
                'atr_mean': grp_s['atr'].mean().to_dict() if 'atr' in df.columns else {},
                'volume_mean': grp_s['tick_volume'].mean().to_dict() if 'tick_volume' in df.columns else {},
                'regime_pct': pd.crosstab(df['session'], df['regime'], normalize='index').to_dict('index') if 'regime' in df.columns else {},
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
            'top_atr_by_session': df[df['atr'] >= threshold]['session'].value_counts(normalize=True).to_dict() if n > 0 else {},
            'spike_count': n_spikes,
            'spike_pct': n_spikes / n * 100,
            'spike_by_session': df[spike_mask]['session'].value_counts(normalize=True).to_dict() if n_spikes else {},
            'avg_atr_spike': float(atr[spike_mask].mean()) if n_spikes else 0.0,
            'avg_atr_normal': float(atr[~spike_mask].mean()) if (~spike_mask).any() else 0.0,
        }
        return self.results

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
        self.db_path = db_path or DB_PATH
        self.macro_wide = None
        self.catalog = {}
        self.roro_df = None
        self.correlations = {}
        self._sensitivity = {}
    def load(self) -> pd.DataFrame:
        if not os.path.exists(self.db_path): return pd.DataFrame()
        conn = None
        try:
            conn = duckdb.connect(DB_PATH, read_only=True)
            cat_df = conn.execute("SELECT symbol, name, category, country, unit FROM macro_catalog").df()
            self.catalog = {r['symbol']: {'name': r['name'], 'category': r['category'], 'country': r['country'], 'unit': r['unit']} for _, r in cat_df.iterrows()}
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
            return wide
        except Exception as e:
            logger.warning(f"[MACRO] Erro: {e}")
            return pd.DataFrame()
        finally:
            if conn is not None: conn.close()
    def cross_reference(self, asset_df: pd.DataFrame, symbol: str = "") -> Dict[str, Any]:
        if self.macro_wide is None or len(self.macro_wide) < 10: return {}
        asset_daily = asset_df.resample('D').agg({'hurst': 'mean', 'adx': 'mean', 'atr': 'mean', 'tr_zscore': 'mean', 'close': 'last'}).dropna()
        asset_daily['close_ret'] = asset_daily['close'].pct_change()
        asset_daily['atr_pct'] = asset_daily['atr'].pct_change()
        asset_daily.dropna(inplace=True)
        if len(asset_daily) < 10: return {}
        common = asset_daily.index.intersection(self.macro_wide.index)
        if len(common) < 10: return {}
        a = asset_daily.loc[common]
        m = self.macro_wide.loc[common]
        roro = self.roro_df.reindex(common, method='ffill') if self.roro_df is not None else None
        merged = a.join(m)
        asset_feats = ['hurst', 'adx', 'atr_pct', 'tr_zscore', 'close_ret']
        macro_symbols = [c for c in m.columns if c != 'date']
        exclude_self = list(self.SYMBOL_SELF_MACRO.get(symbol, []))
        self_sym = symbol.replace('USD', '').replace('X', '')
        for sym in macro_symbols:
            cat = self.catalog.get(sym, {})
            if self_sym.lower() in cat.get('name', sym).lower(): exclude_self.append(sym)
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
                corr_records.append({'macro_symbol': ms, 'asset_feature': af, 'correlation': round(r_val, 4), 'p_value': round(p_val, 4), 'abs_corr': abs(r_val)})
        corr_records.sort(key=lambda x: x['abs_corr'], reverse=True)
        self.correlations = {f"{cr['asset_feature']}_vs_{cr['macro_symbol']}": cr['correlation'] for cr in corr_records}
        top20 = corr_records[:20]
        KEY_MACRO = ['DTWEXBGS', 'VIX', 'DGS10', 'DGS2', 'FEDFUNDS', 'CPIAUCSL', 'DCOILWTICO', 'STLFSI4', 'T10Y2Y']
        KEY_MACRO = [k for k in KEY_MACRO if k not in exclude_self]
        ret_std = merged['close_ret'].std()
        regime_betas = {}
        if 'regime' in asset_df.columns:
            asset_regime = asset_df.resample('D')['regime'].agg(lambda x: x.mode().iloc[0] if len(x) > 0 else 'RANGE')
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
                        betas[k] = {'raw_beta': round(slope, 8), 'elasticity': round(elasticity, 4), 'r_squared': round(r_val**2, 4), 'p_value': round(p_val, 4), 'n_days': len(valid)}
                    except Exception:
                        pass
                if betas: regime_betas[rl] = betas
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
            p_adjusted = np.minimum.accumulate((p_vals[sorted_idx] * n_tests / ranks)[::-1])[::-1]
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
                leading.append({'symbol': sym, 'name': info['name'], 'category': info['category'], 'country': info['country'], 'lag_days': t['lag'], 'cross_correlation': round(t['corr'], 4), 'direction': 'leads' if t['lag'] > 0 else 'lags', 'p_raw': round(float(t['p']), 6), 'p_adjusted_fdr': round(float(t['p_adjusted']), 6), 'fdr_q': q, 'n_total_tests': n_tests})
            leading.sort(key=lambda x: abs(x['cross_correlation']), reverse=True)
            leading = leading[:15]
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
                    coint_results.append({'macro': ms, 'trace_stat': round(trace_stat, 2), 'crit_5pct': round(crit_5, 2), 'result': 'COINTEGRADO' if trace_stat > crit_5 else 'Não'})
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
            macro_factors[fn] = {'score_current': round(float(fs.iloc[-1]), 4), 'score_min': round(float(fs.min()), 4), 'score_max': round(float(fs.max()), 4), 'n_members': len(avail), 'members': avail}
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
            adr = asset_df.resample('D')['regime'].agg(lambda x: x.mode().iloc[0] if len(x) > 0 else 'RANGE')
            crr = adr.index.intersection(roro.index)
            if len(crr) >= 5:
                combined = pd.DataFrame({'regime': adr.loc[crr], 'risk_label': roro.loc[crr, 'risk_label']}).dropna()
                regime_by_risk = pd.crosstab(combined['risk_label'], combined['regime'], normalize='index').to_dict('index')
        self._sensitivity = {'top_correlations': top20, 'regime_betas': regime_betas, 'leading_indicators': leading, 'macro_factors': macro_factors, 'cointegration': coint_results}
        return {'merged': merged, 'correlations': self.correlations, 'regime_by_risk': regime_by_risk, 'macro_sensitivity': self._sensitivity}


# ══════════════════════════════════════════════════════════════
# WALK-FORWARD VALIDATORS
# ══════════════════════════════════════════════════════════════
class WalkForwardValidator:
    def __init__(self, df: pd.DataFrame, n_windows: int = 6):
        self.df = df; self.n_windows = n_windows; self.results = []
    def analyze(self) -> Dict[str, Any]:
        logger.info(f"[WALK-FORWARD] {self.n_windows} janelas...")
        dates = self.df.index.sort_values() if isinstance(self.df.index, pd.DatetimeIndex) else self.df['time'].sort_values()
        if len(dates) < 10000:
            return {'stability_score': 0, 'periods': []}
        ws = len(dates) // self.n_windows
        periods = []
        for i in range(self.n_windows):
            start = i * ws
            end = (i + 1) * ws if i < self.n_windows - 1 else len(dates)
            wdf = self.df.iloc[start:end]
            if len(wdf) < 100: continue
            date_values = wdf['time'] if 'time' in wdf.columns else wdf.index
            start_date = pd.to_datetime(date_values.iloc[0] if hasattr(date_values, 'iloc') else date_values[0])
            end_date = pd.to_datetime(date_values.iloc[-1] if hasattr(date_values, 'iloc') else date_values[-1])
            rc = wdf['regime'].value_counts(normalize=True)
            periods.append({'label': f"{start_date.strftime('%Y-%m')} a {end_date.strftime('%Y-%m')}", 'hurst': float(wdf['hurst'].mean()), 'adx': float(wdf['adx'].mean()), 'atr': float(wdf['atr'].mean()), 'dominant': rc.index[0], 'dominant_pct': float(rc.iloc[0]*100), 'trend_pct': float((rc.get('TREND_FORTE',0)+rc.get('TREND_FRACO',0))*100), 'range_pct': float(rc.get('RANGE',0)*100), 'chop_pct': float(rc.get('CHOP',0)*100), 'n_candles': len(wdf)})
        if len(periods) < 2:
            return {'stability_score': 0, 'periods': periods}
        h_std = np.std([p['hurst'] for p in periods])
        a_std = np.std([p['adx'] for p in periods])
        max_drift = max(abs(p['hurst'] - periods[0]['hurst']) for p in periods)
        score = max(10, 100 - min(50, h_std/0.05*50) - min(30, a_std/5*30) - min(20, max_drift/0.15*20))
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
        self.df = df; self.n_windows = n_windows; self.purge_pct = purge_pct; self.embargo_pct = embargo_pct; self.results = []
    def analyze(self) -> Dict[str, Any]:
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
            periods.append({'label': f"J{i+1}", 'train_hurst': float(train_df['hurst'].mean()), 'test_hurst': float(test_df['hurst'].mean()), 'train_adx': float(train_df['adx'].mean()), 'test_adx': float(test_df['adx'].mean()), 'hurst_diff': float(h_diff), 'adx_diff': float(a_diff), 'js_divergence': float(js)})
        if len(periods) < 2:
            return {'stability_score': 0, 'periods': periods, 'purged': True}
        score = max(10, 100 - min(40, np.mean([p['hurst_diff'] for p in periods])/0.05*40) - min(30, np.mean([p['adx_diff'] for p in periods])/5*30) - min(30, np.mean([p['js_divergence'] for p in periods])/0.1*30))
        self.results = periods
        return {'stability_score': score, 'periods': periods, 'purged': True, 'mean_hurst_diff': float(np.mean([p['hurst_diff'] for p in periods])), 'mean_adx_diff': float(np.mean([p['adx_diff'] for p in periods])), 'mean_js_divergence': float(np.mean([p['js_divergence'] for p in periods]))}
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

class CPCVValidator:
    def __init__(self, df: pd.DataFrame, n_splits: int = 6, n_test_splits: int = 2, purge_pct: float = 0.02):
        self.df = df; self.n_splits = n_splits; self.n_test = n_test_splits; self.purge_pct = purge_pct
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
        path_scores = []
        for combo in combos[:min(n_paths, 15)]:
            test_blocks = set(combo)
            train_idx, test_idx = [], []
            for b in range(self.n_splits):
                b_start = b * block_size
                b_end = (b + 1) * block_size if b < self.n_splits - 1 else n
                if b in test_blocks:
                    test_idx.extend(range(b_start + purge, b_end))
                else:
                    train_idx.extend(range(b_start, b_end - purge))
            train_idx = [i for i in train_idx if 0 <= i < n]
            test_idx = [i for i in test_idx if 0 <= i < n]
            if len(train_idx) < 100 or len(test_idx) < 50: continue
            train_h = self.df['hurst'].iloc[train_idx].mean()
            test_h = self.df['hurst'].iloc[test_idx].mean()
            path_scores.append(abs(train_h - test_h))
        if len(path_scores) < 2:
            return {'regime_stability_score': None, 'n_paths': len(path_scores)}
        mean_drift = np.mean(path_scores)
        std_drift = np.std(path_scores)
        cv = std_drift / max(mean_drift, 1e-6)
        stability_score = max(0.0, 100.0 - cv * 100.0)
        return {'regime_stability_score': round(float(stability_score), 1), 'methodology_note': 'Métrica baseada no Coeficiente de Variação (CV) do drift do DFA-Hurst entre caminhos CPCV purgados. 100 = perfeitamente estável, <50 = alta instabilidade.', 'n_paths': len(path_scores), 'mean_hurst_drift': round(float(mean_drift), 4), 'std_hurst_drift': round(float(std_drift), 4)}

class InstitutionalValidators:
    def __init__(self, df: pd.DataFrame):
        self.df = df; self.pbo_results: Dict[str, Any] = {}; self.optimal_wf: Dict[str, Any] = {}
    def _daily_ohlc(self) -> pd.DataFrame:
        source = self.df
        if not isinstance(source.index, (pd.DatetimeIndex, pd.TimedeltaIndex, pd.PeriodIndex)):
            if 'time' not in source.columns:
                raise TypeError("Institutional validators require a DatetimeIndex or a 'time' column")
            source = source.copy()
            source.index = pd.to_datetime(source['time'], errors='coerce')
            source = source.loc[source.index.notna()]
        return source.resample('D').agg({'open': 'first', 'high': 'max', 'low': 'min', 'close': 'last'}).dropna()
    @staticmethod
    def _vectorized_backtest(df: pd.DataFrame, strategy: str, params: Dict) -> pd.Series:
        close = df['close']; high = df['high']; low = df['low']
        if strategy == 'mean_reversion':
            period = params.get('period', 20); std_mult = params.get('std_mult', 2.0)
            sma = close.rolling(period).mean(); rstd = close.rolling(period).std()
            upper = sma + std_mult * rstd; lower = sma - std_mult * rstd
            pos = np.where(close < lower, 1, np.where(close > upper, -1, np.nan))
            pos = pd.Series(pos, index=close.index).ffill().fillna(0)
        elif strategy == 'breakout':
            period = params.get('period', 20)
            upper = high.rolling(period).max().shift(1); lower = low.rolling(period).min().shift(1)
            pos = np.where(close > upper, 1, np.where(close < lower, -1, np.nan))
            pos = pd.Series(pos, index=close.index).ffill().fillna(0)
        else:
            return pd.Series(0, index=close.index)
        rets = close.pct_change() * pos.shift(1)
        return rets.fillna(0)
    @staticmethod
    def _calc_sharpe(rets: pd.Series) -> float:
        if rets.std() == 0: return 0.0
        return rets.mean() / rets.std() * np.sqrt(252)
    def compute_pbo(self):
        logger.info("[PBO] Calculando Probability of Backtest Overfitting...")
        df_daily = self._daily_ohlc()
        mr_params = [{'period': p, 'std_mult': s} for p in [10, 20, 50, 100] for s in [1.5, 2.0, 2.5, 3.0]]
        bo_params = [{'period': p} for p in [10, 20, 50, 100, 200]]
        strategies = [('mean_reversion', p) for p in mr_params] + [('breakout', p) for p in bo_params]
        all_rets = [self._vectorized_backtest(df_daily, s, p) for s, p in strategies]
        n = len(df_daily); n_blocks = 16; block_size = n // n_blocks
        combos = list(combinations(range(n_blocks), n_blocks // 2))
        np.random.seed(42)
        if len(combos) > 100:
            indices = np.random.choice(len(combos), 100, replace=False)
            combos = [combos[i] for i in indices]
        pbo_counts = {'mean_reversion': 0, 'breakout': 0}; total_combos = 0
        for c_idx in (combos if not HAS_TQDM else tqdm(combos, desc="  [PBO]")):
            is_blocks = set(c_idx); is_idx, oos_idx = [], []
            for b in range(n_blocks):
                start = b * block_size; end = start + block_size
                if b in is_blocks: is_idx.extend(range(start, end))
                else: oos_idx.extend(range(start, end))
            if not is_idx or not oos_idx: continue
            is_sharpes = [self._calc_sharpe(all_rets[i].iloc[is_idx]) for i in range(len(strategies))]
            oos_sharpes = [self._calc_sharpe(all_rets[i].iloc[oos_idx]) for i in range(len(strategies))]
            mr_is = is_sharpes[:len(mr_params)]; mr_oos = oos_sharpes[:len(mr_params)]
            bo_is = is_sharpes[len(mr_params):]; bo_oos = oos_sharpes[len(mr_params):]
            best_mr_is = np.argmax(mr_is); mr_median = np.median(mr_oos)
            if mr_oos[best_mr_is] < mr_median: pbo_counts['mean_reversion'] += 1
            best_bo_is = np.argmax(bo_is); bo_median = np.median(bo_oos)
            if bo_oos[best_bo_is] < bo_median: pbo_counts['breakout'] += 1
            total_combos += 1
        self.pbo_results = {
            'mean_reversion_pbo': (pbo_counts['mean_reversion'] / total_combos * 100 if total_combos > 0 else 0),
            'breakout_pbo': (pbo_counts['breakout'] / total_combos * 100 if total_combos > 0 else 0),
            'n_combinations': total_combos,
            'best_mr_params': mr_params[np.argmax([self._calc_sharpe(r) for r in all_rets[:len(mr_params)]])],
            'best_bo_params': bo_params[np.argmax([self._calc_sharpe(r) for r in all_rets[len(mr_params):]])],
        }
        return self.pbo_results
    def compute_optimal_stopping(self):
        logger.info("[OPTIMAL STOPPING] Procurando janela ideal de re-treino...")
        df_daily = self._daily_ohlc()
        n = len(df_daily)
        if n < 1000: return {}
        train_sizes = [252, 504, 756]; test_size = 126; retrain_freqs = [63, 126, 252]
        best_config = None; best_score = -np.inf
        for train_size in train_sizes:
            for retrain_freq in retrain_freqs:
                oos_returns = []
                for start in range(train_size, n - test_size, retrain_freq):
                    train_df = df_daily.iloc[start - train_size:start]; test_df = df_daily.iloc[start:start + test_size]
                    mr_rets = [self._vectorized_backtest(train_df, 'mean_reversion', {'period': p}) for p in [10, 20, 50]]
                    bo_rets = [self._vectorized_backtest(train_df, 'breakout', {'period': p}) for p in [20, 50, 100]]
                    best_mr = np.argmax([self._calc_sharpe(r) for r in mr_rets]); best_bo = np.argmax([self._calc_sharpe(r) for r in bo_rets])
                    mr_test = self._vectorized_backtest(test_df, 'mean_reversion', [{'period': 10}, {'period': 20}, {'period': 50}][best_mr])
                    bo_test = self._vectorized_backtest(test_df, 'breakout', [{'period': 20}, {'period': 50}, {'period': 100}][best_bo])
                    oos_ret = (mr_test + bo_test) / 2; oos_returns.append(oos_ret)
                if oos_returns:
                    total_oos = pd.concat(oos_returns); score = self._calc_sharpe(total_oos)
                    if score > best_score:
                        best_score = score; best_config = {'train_size_days': train_size, 'retrain_freq_days': retrain_freq, 'sharpe': round(float(score), 3)}
        self.optimal_wf = best_config if best_config else {}
        return self.optimal_wf


# ══════════════════════════════════════════════════════════════
# CHART GENERATOR (RESTAURADO COMPLETO)
# ══════════════════════════════════════════════════════════════
class ChartGenerator:
    def __init__(self, df: pd.DataFrame, chart_dir: Path = None):
        self.df = df
        self.chart_dir = Path(chart_dir or CFG.report_dir / 'charts')
        self.chart_dir.mkdir(parents=True, exist_ok=True)
        self.charts: Dict[str, str] = {}

    def generate_all(self, regime_model, temporal, tail_risk, hmm_model=None,
                     entropy=None, fracdiff=None, signal_data=None,
                     walkforward=None, purged_wf=None, cpcv=None,
                     macro=None, pbo=None, optimal_wf=None) -> Dict[str, str]:
        logger.info("[CHARTS] Gerando gráficos institucionais...")
        t0 = time.time()

        # 1. Regime Distribution
        self._plot_regime_distribution()

        # 2. Hurst + ADX Evolution
        self._plot_hurst_adx_evolution()

        # 3. Wavelet Analysis (NOVO)
        self._plot_wavelet_analysis()

        # 4. Entropy Evolution
        self._plot_entropy_evolution()

        # 5. Transition Matrix Heatmap
        self._plot_transition_matrix(regime_model)

        # 6. Temporal Profile
        self._plot_temporal_profile(temporal)

        # 7. Tail Risk Distribution
        self._plot_tail_risk(tail_risk)

        # 8. MI Matrix
        self._plot_mi_matrix()

        # 9. Walk-Forward Stability
        if walkforward:
            walkforward.generate_charts(self.chart_dir, self.charts)

        # 10. Purged Walk-Forward
        if purged_wf:
            purged_wf.generate_charts(self.chart_dir, self.charts)

        # 11. Macro Correlations
        if macro and macro.get('macro_sensitivity', {}).get('top_correlations'):
            self._plot_macro_correlations(macro)

        # 12. Regime by Session
        self._plot_regime_by_session(temporal)

        # 13. PBO Analysis
        if pbo:
            self._plot_pbo(pbo)

        logger.info(f"  [CHARTS] OK em {time.time()-t0:.2f}s | {len(self.charts)} gráficos gerados")
        return self.charts

    def _plot_regime_distribution(self):
        fig, ax = plt.subplots(figsize=(10, 5))
        regime_counts = self.df['regime'].value_counts()
        colors_bar = [REGIME_COLORS.get(r, C['gray']) for r in regime_counts.index]
        bars = ax.bar(regime_counts.index, regime_counts.values, color=colors_bar, edgecolor='white', linewidth=0.5)
        for bar, count in zip(bars, regime_counts.values):
            pct = count / len(self.df) * 100
            ax.text(bar.get_x() + bar.get_width()/2., bar.get_height() + 0.5,
                    f'{pct:.1f}%', ha='center', va='bottom', fontweight='bold', fontsize=9)
        ax.set_ylabel('Frequência'); ax.set_title('Distribuição de Regimes', fontweight='bold')
        ax.set_xticklabels(regime_counts.index, rotation=45, ha='right')
        plt.tight_layout()
        path = str(self.chart_dir / 'regime_distribution.png')
        fig.savefig(path, dpi=CFG.chart_dpi, bbox_inches='tight'); plt.close(fig)
        self.charts['regime_distribution'] = path

    def _plot_hurst_adx_evolution(self):
        fig, ax1 = plt.subplots(figsize=(12, 5))
        ax1.plot(self.df.index, self.df['hurst'], color=C['blue'], linewidth=0.8, alpha=0.7, label='DFA-Hurst')
        ax1.axhline(y=0.5, color='gray', linestyle='--', linewidth=0.5, alpha=0.5)
        ax1.axhline(y=0.55, color='red', linestyle='--', linewidth=0.5, alpha=0.5)
        ax1.set_ylabel('DFA-Hurst', color=C['blue']); ax1.set_ylim(0.3, 0.8)
        ax2 = ax1.twinx()
        ax2.plot(self.df.index, self.df['adx'], color=C['gold'], linewidth=0.8, alpha=0.7, label='ADX')
        ax2.set_ylabel('ADX', color=C['gold'])
        ax1.set_title('Evolução Hurst + ADX', fontweight='bold')
        lines = ax1.get_lines() + ax2.get_lines()
        ax1.legend(lines, [l.get_label() for l in lines], loc='upper left')
        plt.tight_layout()
        path = str(self.chart_dir / 'hurst_adx_evolution.png')
        fig.savefig(path, dpi=CFG.chart_dpi, bbox_inches='tight'); plt.close(fig)
        self.charts['hurst_adx_evolution'] = path

    def _plot_wavelet_analysis(self):
        if 'wavelet_hurst' not in self.df.columns: return
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 6), sharex=True)
        ax1.plot(self.df.index, self.df['wavelet_hurst'], color=C['purple'], linewidth=0.8, alpha=0.7, label='Wavelet Hurst')
        ax1.axhline(y=0.5, color='gray', linestyle='--', linewidth=0.5, alpha=0.5)
        ax1.set_ylabel('Wavelet Hurst', color=C['purple']); ax1.set_ylim(0.3, 0.8)
        ax1.legend(loc='upper left')
        ax2.plot(self.df.index, self.df['wavelet_roughness'], color=C['teal'], linewidth=0.8, alpha=0.7, label='Wavelet Roughness')
        ax2.set_ylabel('Roughness', color=C['teal'])
        ax2.legend(loc='upper left')
        ax1.set_title('Análise Wavelet Multiresolução', fontweight='bold')
        plt.tight_layout()
        path = str(self.chart_dir / 'wavelet_analysis.png')
        fig.savefig(path, dpi=CFG.chart_dpi, bbox_inches='tight'); plt.close(fig)
        self.charts['wavelet_analysis'] = path

    def _plot_entropy_evolution(self):
        if 'sample_entropy' not in self.df.columns: return
        fig, ax1 = plt.subplots(figsize=(12, 5))
        ax1.plot(self.df.index, self.df['sample_entropy'], color=C['blue'], linewidth=0.8, alpha=0.7, label='Sample Entropy')
        ax2 = ax1.twinx()
        ax2.plot(self.df.index, self.df['perm_entropy'], color=C['green'], linewidth=0.8, alpha=0.7, label='Permutation Entropy')
        if 'renyi_entropy' in self.df.columns:
            ax2.plot(self.df.index, self.df['renyi_entropy'], color=C['red'], linewidth=0.8, alpha=0.7, label='Rényi Entropy (q=2)')
        ax1.set_ylabel('Sample Entropy', color=C['blue'])
        ax2.set_ylabel('Permutation / Rényi', color=C['green'])
        lines = ax1.get_lines() + ax2.get_lines()
        ax1.legend(lines, [l.get_label() for l in lines], loc='upper left')
        ax1.set_title('Evolução de Entropias', fontweight='bold')
        plt.tight_layout()
        path = str(self.chart_dir / 'entropy_evolution.png')
        fig.savefig(path, dpi=CFG.chart_dpi, bbox_inches='tight'); plt.close(fig)
        self.charts['entropy_evolution'] = path

    def _plot_transition_matrix(self, regime_model):
        mat, labels = regime_model.transition_matrix()
        fig, ax = plt.subplots(figsize=(8, 6))
        sns.heatmap(mat, annot=True, fmt='.3f', cmap='YlOrRd', xticklabels=labels, yticklabels=labels, ax=ax)
        ax.set_title('Matriz de Transição de Regimes', fontweight='bold')
        ax.set_xlabel('Próximo Regime'); ax.set_ylabel('Regime Atual')
        plt.tight_layout()
        path = str(self.chart_dir / 'transition_matrix.png')
        fig.savefig(path, dpi=CFG.chart_dpi, bbox_inches='tight'); plt.close(fig)
        self.charts['transition_matrix'] = path

    def _plot_temporal_profile(self, temporal):
        if not temporal: return
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5))
        if 'hour' in temporal:
            hour_atr = temporal['hour'].get('atr_mean', {})
            hours = sorted(hour_atr.keys())
            atr_vals = [hour_atr[h] for h in hours]
            ax1.bar(hours, atr_vals, color=C['blue'], alpha=0.7)
            ax1.set_xlabel('Hora'); ax1.set_ylabel('ATR Médio'); ax1.set_title('Volatilidade por Hora', fontweight='bold')
        if 'session' in temporal:
            sess_atr = temporal['session'].get('atr_mean', {})
            sessions = list(sess_atr.keys())
            atr_vals = [sess_atr[s] for s in sessions]
            ax2.bar(sessions, atr_vals, color=C['gold'], alpha=0.7)
            ax2.set_xlabel('Sessão'); ax2.set_ylabel('ATR Médio'); ax2.set_title('Volatilidade por Sessão', fontweight='bold')
            ax2.tick_params(axis='x', rotation=45)
        plt.tight_layout()
        path = str(self.chart_dir / 'temporal_profile.png')
        fig.savefig(path, dpi=CFG.chart_dpi, bbox_inches='tight'); plt.close(fig)
        self.charts['temporal_profile'] = path

    def _plot_tail_risk(self, tail_risk):
        if not tail_risk: return
        fig, ax = plt.subplots(figsize=(10, 5))
        atr = self.df['atr'].dropna()
        ax.hist(atr, bins=50, color=C['navy'], alpha=0.7, edgecolor='white')
        threshold = tail_risk.get('atr_threshold', 0)
        if threshold > 0:
            ax.axvline(x=threshold, color=C['red'], linestyle='--', linewidth=2, label=f'Threshold 99%: {threshold:.2f}')
        ax.set_xlabel('ATR'); ax.set_ylabel('Frequência'); ax.set_title('Distribuição de ATR (Risco de Cauda)', fontweight='bold')
        ax.legend()
        plt.tight_layout()
        path = str(self.chart_dir / 'tail_risk.png')
        fig.savefig(path, dpi=CFG.chart_dpi, bbox_inches='tight'); plt.close(fig)
        self.charts['tail_risk'] = path

        def _plot_mi_matrix(self):
        if not hasattr(self, '_mi_matrix') or self._mi_matrix is None: return
        fig, ax = plt.subplots(figsize=(8, 6))
        sns.heatmap(self._mi_matrix, annot=True, fmt='.3f', cmap='Blues',
                    xticklabels=self._mi_labels, yticklabels=self._mi_labels, ax=ax)
        ax.set_title('Matriz de Mutual Information', fontweight='bold')
        plt.tight_layout()
        path = str(self.chart_dir / 'mi_matrix.png')
        fig.savefig(path, dpi=CFG.chart_dpi, bbox_inches='tight'); plt.close(fig)
        self.charts['mi_matrix'] = path

    def _plot_regime_by_session(self, temporal):
        if not temporal or 'session' not in temporal: return
        regime_pct = temporal['session'].get('regime_pct', {})
        if not regime_pct: return
        fig, ax = plt.subplots(figsize=(10, 6))
        sessions = list(regime_pct.keys())
        regimes = list(set().union(*(regime_pct[s].keys() for s in sessions)))
        x = np.arange(len(sessions))
        width = 0.15
        for i, regime in enumerate(regimes):
            vals = [regime_pct[s].get(regime, 0) * 100 for s in sessions]
            color = REGIME_COLORS.get(regime, C['gray'])
            ax.bar(x + i * width, vals, width, label=regime, color=color, alpha=0.8)
        ax.set_xlabel('Sessão'); ax.set_ylabel('% do Tempo'); ax.set_title('Regime por Sessão', fontweight='bold')
        ax.set_xticks(x + width * 1.5); ax.set_xticklabels(sessions, rotation=45, ha='right')
        ax.legend()
        plt.tight_layout()
        path = str(self.chart_dir / 'regime_by_session.png')
        fig.savefig(path, dpi=CFG.chart_dpi, bbox_inches='tight'); plt.close(fig)
        self.charts['regime_by_session'] = path

    def _plot_macro_correlations(self, macro):
        top = macro.get('macro_sensitivity', {}).get('top_correlations', [])
        if len(top) < 3: return
        fig, ax = plt.subplots(figsize=(10, max(4, len(top[:20])*0.35)))
        labels = [f"{t['macro_symbol']}({t['asset_feature']})" for t in top[:20]]
        vals = [t['correlation'] for t in top[:20]]
        colors_bar = [C['red'] if v < 0 else C['green'] for v in vals]
        ax.barh(range(len(labels)), vals, color=colors_bar, height=0.6)
        ax.set_yticks(range(len(labels))); ax.set_yticklabels(labels, fontsize=7)
        ax.axvline(0, color='gray', linewidth=0.5)
        ax.set_xlabel('Correlação'); ax.set_title('Top 20 Macro vs Ativo', fontweight='bold')
        plt.tight_layout()
        path = str(self.chart_dir / 'macro_corr_heatmap.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['macro_corr_heatmap'] = path

    def _plot_pbo(self, pbo):
        fig, ax = plt.subplots(figsize=(8, 5))
        strategies = ['Mean Reversion', 'Breakout']
        pbo_vals = [pbo.get('mean_reversion_pbo', 0), pbo.get('breakout_pbo', 0)]
        colors_bar = [C['green'] if v < 50 else C['orange'] if v < 75 else C['red'] for v in pbo_vals]
        bars = ax.bar(strategies, pbo_vals, color=colors_bar, alpha=0.8, edgecolor='white')
        for bar, val in zip(bars, pbo_vals):
            ax.text(bar.get_x() + bar.get_width()/2., bar.get_height() + 1,
                    f'{val:.1f}%', ha='center', va='bottom', fontweight='bold')
        ax.axhline(y=50, color='gray', linestyle='--', linewidth=0.5, alpha=0.5, label='Limite aceitável (50%)')
        ax.set_ylabel('PBO (%)'); ax.set_title('Probability of Backtest Overfitting', fontweight='bold')
        ax.legend()
        plt.tight_layout()
        path = str(self.chart_dir / 'pbo_analysis.png')
        fig.savefig(path, dpi=CFG.chart_dpi, bbox_inches='tight'); plt.close(fig)
        self.charts['pbo_analysis'] = path


# ══════════════════════════════════════════════════════════════
# PDF REPORT BUILDER (RESTAURADO COMPLETO)
# ══════════════════════════════════════════════════════════════
class PDFReportBuilder:
    def __init__(self, df: pd.DataFrame, charts: Dict[str, str], narratives: Dict[str, str],
                 regime_model, temporal, tail_risk, hmm_model=None, entropy=None,
                 fracdiff=None, signal_data=None, walkforward=None, purged_wf=None,
                 cpcv=None, macro=None, pbo=None, optimal_wf=None, symbol: str = "", tf: str = ""):
        self.df = df; self.charts = charts; self.narratives = narratives
        self.regime_model = regime_model; self.temporal = temporal; self.tail_risk = tail_risk
        self.hmm = hmm_model or {}; self.entropy = entropy or {}; self.fracdiff = fracdiff or {}
        self.signal = signal_data or {}; self.walkforward = walkforward or {}
        self.purged_wf = purged_wf or {}; self.cpcv = cpcv or {}; self.macro = macro or {}
        self.pbo = pbo or {}; self.optimal_wf = optimal_wf or {}
        self.symbol = symbol; self.tf = tf

    def build(self, output_path: str):
        logger.info(f"[PDF] Gerando relatório: {output_path}")
        doc = SimpleDocTemplate(output_path, pagesize=A4,
                                rightMargin=15*mm, leftMargin=15*mm,
                                topMargin=15*mm, bottomMargin=15*mm)
        styles = getSampleStyleSheet()
        title_style = ParagraphStyle('CustomTitle', parent=styles['Title'],
                                     fontSize=18, textColor=colors.HexColor(C['navy']),
                                     spaceAfter=6*mm, alignment=TA_CENTER)
        h1_style = ParagraphStyle('H1', parent=styles['Heading1'],
                                  fontSize=14, textColor=colors.HexColor(C['steel']),
                                  spaceAfter=4*mm, spaceBefore=6*mm)
        h2_style = ParagraphStyle('H2', parent=styles['Heading2'],
                                  fontSize=12, textColor=colors.HexColor(C['blue']),
                                  spaceAfter=3*mm, spaceBefore=4*mm)
        body_style = ParagraphStyle('Body', parent=styles['Normal'],
                                    fontSize=10, leading=14, alignment=TA_JUSTIFY)

        story = []

        # Capa
        story.append(Spacer(1, 20*mm))
        story.append(Paragraph(f"ALXQuant Asset DNA Report", title_style))
        story.append(Paragraph(f"{self.symbol} — {self.tf}", styles['Heading2']))
        story.append(Spacer(1, 5*mm))
        story.append(Paragraph(f"Gerado em: {datetime.now().strftime('%Y-%m-%d %H:%M')}", body_style))
        story.append(Paragraph(f"Versão: {ALGO_VERSION}", body_style))
        story.append(Spacer(1, 10*mm))
        story.append(HRFlowable(width="100%", thickness=1, color=colors.HexColor(C['steel'])))
        story.append(Spacer(1, 10*mm))

        # Executive Summary
        story.append(Paragraph("1. Executive Summary", h1_style))
        story.append(Paragraph(self.narratives.get('executive', ''), body_style))
        story.append(Spacer(1, 5*mm))

        # Key Metrics Table
        story.append(Paragraph("2. Métricas Principais", h1_style))
        avg_hurst = float(self.df['hurst'].mean())
        avg_adx = float(self.df['adx'].mean())
        avg_atr = float(self.df['atr'].mean())
        dominant = self.df['regime'].value_counts().index[0]
        data = [
            ['Métrica', 'Valor'],
            ['DFA-Hurst Médio', f"{avg_hurst:.3f}"],
            ['ADX Médio', f"{avg_adx:.2f}"],
            ['ATR Médio', f"{avg_atr:.4f}"],
            ['Regime Dominante', dominant],
            ['Stability Score (WF)', f"{self.walkforward.get('stability_score', 0):.1f}"],
            ['Purged WF Score', f"{self.purged_wf.get('stability_score', 0):.1f}"],
            ['CPCV Stability', f"{self.cpcv.get('regime_stability_score', 'N/A')}"],
            ['PBO Mean Reversion', f"{self.pbo.get('mean_reversion_pbo', 0):.1f}%"],
            ['PBO Breakout', f"{self.pbo.get('breakout_pbo', 0):.1f}%"],
        ]
        if 'wavelet_hurst' in self.df.columns:
            wh = float(self.df['wavelet_hurst'].mean())
            wr = float(self.df['wavelet_roughness'].mean())
            data.append(['Wavelet Hurst', f"{wh:.3f}"])
            data.append(['Wavelet Roughness', f"{wr:.3f}"])
        if 'renyi_entropy' in self.df.columns:
            re = float(self.df['renyi_entropy'].mean())
            data.append(['Rényi Entropy (q=2)', f"{re:.3f}"])

        t = Table(data, colWidths=[80*mm, 80*mm])
        t.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor(C['navy'])),
            ('TEXTCOLOR', (0, 0), (-1, 0), colors.white),
            ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
            ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
            ('FONTSIZE', (0, 0), (-1, 0), 10),
            ('BOTTOMPADDING', (0, 0), (-1, 0), 8),
            ('TOPPADDING', (0, 1), (-1, -1), 6),
            ('BOTTOMPADDING', (0, 1), (-1, -1), 6),
            ('GRID', (0, 0), (-1, -1), 0.5, colors.grey),
            ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.white, colors.HexColor(C['lighter'])]),
        ]))
        story.append(t)
        story.append(PageBreak())

        # Regime Analysis
        story.append(Paragraph("3. Análise de Regimes", h1_style))
        story.append(Paragraph(self.narratives.get('transition', ''), body_style))
        story.append(Spacer(1, 5*mm))
        if 'regime_distribution' in self.charts:
            story.append(Image(self.charts['regime_distribution'], width=160*mm, height=80*mm))
        if 'transition_matrix' in self.charts:
            story.append(Spacer(1, 5*mm))
            story.append(Image(self.charts['transition_matrix'], width=120*mm, height=90*mm))
        story.append(PageBreak())

        # Temporal & Tail Risk
        story.append(Paragraph("4. Perfil Temporal e Risco de Cauda", h1_style))
        story.append(Paragraph(self.narratives.get('tail_risk', ''), body_style))
        story.append(Spacer(1, 5*mm))
        if 'temporal_profile' in self.charts:
            story.append(Image(self.charts['temporal_profile'], width=160*mm, height=60*mm))
        if 'tail_risk' in self.charts:
            story.append(Spacer(1, 5*mm))
            story.append(Image(self.charts['tail_risk'], width=160*mm, height=70*mm))
        story.append(PageBreak())

        # Complexity & Signal
        story.append(Paragraph("5. Complexidade e Sinais", h1_style))
        story.append(Paragraph(self.narratives.get('complexity', ''), body_style))
        story.append(Spacer(1, 5*mm))
        if 'entropy_evolution' in self.charts:
            story.append(Image(self.charts['entropy_evolution'], width=160*mm, height=70*mm))
        if 'wavelet_analysis' in self.charts:
            story.append(Spacer(1, 5*mm))
            story.append(Image(self.charts['wavelet_analysis'], width=160*mm, height=90*mm))
        story.append(Paragraph(self.narratives.get('signal_analysis', ''), body_style))
        story.append(PageBreak())

        # Validation
        story.append(Paragraph("6. Validação Institucional", h1_style))
        story.append(Paragraph(f"<b>Walk-Forward Score:</b> {self.walkforward.get('stability_score', 0):.1f}", body_style))
        story.append(Paragraph(f"<b>Purged WF Score:</b> {self.purged_wf.get('stability_score', 0):.1f}", body_style))
        story.append(Paragraph(f"<b>CPCV Stability:</b> {self.cpcv.get('regime_stability_score', 'N/A')}", body_style))
        story.append(Paragraph(f"<b>PBO Mean Reversion:</b> {self.pbo.get('mean_reversion_pbo', 0):.1f}%", body_style))
        story.append(Paragraph(f"<b>PBO Breakout:</b> {self.pbo.get('breakout_pbo', 0):.1f}%", body_style))
        story.append(Spacer(1, 5*mm))
        if 'wf_stability' in self.charts:
            story.append(Image(self.charts['wf_stability'], width=160*mm, height=60*mm))
        if 'purged_wf' in self.charts:
            story.append(Spacer(1, 5*mm))
            story.append(Image(self.charts['purged_wf'], width=160*mm, height=60*mm))
        if 'pbo_analysis' in self.charts:
            story.append(Spacer(1, 5*mm))
            story.append(Image(self.charts['pbo_analysis'], width=120*mm, height=70*mm))
        story.append(PageBreak())

        # Macro
        if self.macro and self.macro.get('macro_sensitivity', {}).get('top_correlations'):
            story.append(Paragraph("7. Sensibilidade Macro", h1_style))
            if 'macro_corr_heatmap' in self.charts:
                story.append(Image(self.charts['macro_corr_heatmap'], width=160*mm, height=100*mm))
            story.append(PageBreak())

        # Footer
        story.append(HRFlowable(width="100%", thickness=1, color=colors.HexColor(C['steel'])))
        story.append(Spacer(1, 5*mm))
        story.append(Paragraph(f"ALXQuant Asset DNA Profiler {ALGO_VERSION}", body_style))
        story.append(Paragraph("Relatório gerado automaticamente. Uso institucional.", body_style))

        doc.build(story)
        logger.info(f"  [PDF] OK: {output_path}")


# ══════════════════════════════════════════════════════════════
# NARRATIVE ENGINE
# ══════════════════════════════════════════════════════════════
class NarrativeEngine:
    def __init__(self, df, regime_model, temporal, tail_risk, hmm_model=None,
                 entropy=None, fracdiff=None, signal_data=None, wavelet_data=None):
        self.df = df; self.regime_model = regime_model; self.temporal = temporal; self.tail_risk = tail_risk
        self.hmm = hmm_model or {}; self.entropy = entropy or {}; self.fracdiff = fracdiff or {}
        self.signal = signal_data or {}; self.wavelet = wavelet_data or {}
    def generate(self) -> Dict[str, str]:
        df = self.df
        dominant = df['regime'].value_counts().index[0]
        dominant_pct = df['regime'].value_counts().iloc[0] / len(df) * 100
        noise = float(df['hurst'].mean())
        noise_desc = "Alta" if noise < 0.45 else "Media" if noise < 0.55 else "Baixa"
        vol_hour = int(df.groupby('hour', observed=True)['atr'].mean().idxmax())
        session_regime = self.temporal.get('session', {}).get('regime_pct', {})
        trend_session = None
        for s in ['NY_AM', 'London', 'NY_PM', 'Asia']:
            if s in session_regime:
                trend_pct = sum(session_regime[s].get(r, 0) for r in ['TREND_FORTE', 'TREND_FRACO']) * 100
                if trend_session is None or trend_pct > trend_session[1]:
                    trend_session = (s, trend_pct)
        pe_mean = self.entropy.get('perm_entropy_mean', 0)
        re_mean = self.entropy.get('renyi_entropy_mean', 0)
        complexity_desc = "ALTA (mercado eficiente)" if pe_mean > 0.85 else "MODERADA" if pe_mean > 0.65 else "BAIXA (padrões detectáveis)"
        tail_desc = "ELEVADO" if re_mean > 1.5 else "MODERADO"
        hmm_agree = self.hmm.get('agreement', 0)
        hmm_note = f"O modelo HMM (condicionado à volatilidade) identificou {self.hmm.get('n_states', 4)} estados com {hmm_agree:.1f}% de concordância. " if hmm_agree > 0 else ""
        te = self.signal.get('transfer_entropy', {})
        te_note = ""
        if te:
            r2v, v2r = te.get('ret_to_vol', 0), te.get('vol_to_ret', 0)
            if r2v > 0.001 or v2r > 0.001:
                direction = "retornos→volume" if r2v > v2r else "volume→retornos"
                te_note = f"Transfer Entropy indica que {direction} domina. "
        wavelet_note = ""
        if self.wavelet.get('wavelet_roughness_mean', 0) > 0:
            wr = self.wavelet['wavelet_roughness_mean']
            wavelet_note = f"Análise Wavelet multiresolução indica roughness de {wr:.3f}. "
        return {
            'executive': f"O perfil estrutural revela {dominant} como regime dominante ({dominant_pct:.1f}%). Ruído (DFA-Hurst: {noise:.2f}) indica {noise_desc}. Hora mais volátil: {vol_hour:02d}h. Sessão de tendência: {trend_session[0] if trend_session else 'N/A'}. {hmm_note}{te_note}{wavelet_note}",
            'transition': "A matriz de Markov indica a seguinte dinâmica de transição entre regimes.",
            'tail_risk': f"Risco de cauda: {self.tail_risk['spike_count']} spikes ({self.tail_risk['spike_pct']:.1f}%). ATR médio em spikes: {self.tail_risk['avg_atr_spike']:.2f} vs {self.tail_risk['avg_atr_normal']:.2f} normal.",
            'complexity': f"Entropia: Permutation {pe_mean:.3f} ({complexity_desc}). Rényi (q=2.0): {re_mean:.3f} (Risco de cauda {tail_desc}). {wavelet_note}",
            'signal_analysis': f"{te_note}",
        }


# ══════════════════════════════════════════════════════════════
# JSON EXPORTER
# ══════════════════════════════════════════════════════════════
class JsonProfileExporter:
    def __init__(self, df, regime_labels, transition_mat, temporal, tail_risk, walkforward, macro,
                 hmm_model=None, entropy=None, fracdiff=None, signal_data=None, purged_wf=None,
                 cpcv=None, pbo=None, optimal_wf=None, regime_thresholds=None, wavelet_data=None):
        self.df = df; self.regime_labels = regime_labels; self.transition_mat = transition_mat
        self.temporal = temporal; self.tail_risk = tail_risk; self.walkforward = walkforward; self.macro = macro
        self.hmm = hmm_model or {}; self.entropy = entropy or {}; self.fracdiff = fracdiff or {}
        self.signal = signal_data or {}; self.purged_wf = purged_wf or {}; self.cpcv = cpcv or {}
        self.pbo = pbo or {}; self.optimal_wf = optimal_wf or {}; self.regime_thresholds = regime_thresholds or {}
        self.wavelet = wavelet_data or {}
    def export(self, output_path: str, symbol: str, tf: str) -> str:
        profile = self._build(symbol, tf)
        tmp_path = output_path + '.tmp'
        with open(tmp_path, 'w', encoding='utf-8') as f:
            json.dump(profile, f, indent=2, ensure_ascii=False, cls=SafeEncoder)
        import shutil; shutil.move(tmp_path, output_path)
        logger.info(f"[JSON] Perfil exportado: {output_path}")
        return output_path
    def _build(self, symbol: str, tf: str) -> dict:
        df = self.df
        regime_dist = {str(k): float(v) for k, v in df['regime'].value_counts(normalize=True).to_dict().items()}
        avg_hurst, avg_adx, avg_atr = float(df['hurst'].mean()), float(df['adx'].mean()), float(df['atr'].mean())
        vol_hour = int(df.groupby('hour')['atr'].mean().idxmax())
        if avg_hurst > 0.58: dfa_period, dfa_min, dfa_max = 300, 14, 56
        elif avg_hurst > 0.52: dfa_period, dfa_min, dfa_max = 200, 8, 40
        else: dfa_period, dfa_min, dfa_max = 150, 6, 28
        trend_score = min(1.0, (avg_hurst - 0.45) / 0.3 * 0.7 + regime_dist.get('TREND_FORTE', 0))
        meanrev_score = min(1.0, (0.6 - avg_hurst) / 0.3 * 0.7 + regime_dist.get('RANGE', 0))
        atr_pct = avg_atr / df['close'].mean()
        breakout_score = min(1.0, avg_adx / 40 * 0.5 + atr_pct * 100 * 0.1)
        hmm_data = {}
        if 'hmm_regime' in df.columns:
            hmm_dist = {str(k): float(v) for k, v in df['hmm_regime'].value_counts(normalize=True).to_dict().items()}
            hmm_data = {'states': int(df['hmm_state'].nunique()) if 'hmm_state' in df.columns else 0, 'agreement_adx_hurst': round(self.hmm.get('agreement', 0), 1), 'hmm_regime_distribution': hmm_dist, 'hmm_features': ['log_return', 'realized_vol', 'skewness', 'kurtosis', 'autocorr_lag1', 'volatility_meta_regime']}
        entropy_data = {}
        if 'sample_entropy' in df.columns:
            se, pe, re = df['sample_entropy'].dropna(), df['perm_entropy'].dropna(), df['renyi_entropy'].dropna()
            entropy_data = {'sample_entropy_mean': round(float(se.mean()), 4) if len(se) else 0, 'perm_entropy_mean': round(float(pe.mean()), 4) if len(pe) else 0, 'renyi_entropy_mean': round(float(re.mean()), 4) if len(re) else 0}
        wavelet_export = {}
        if 'wavelet_hurst' in df.columns:
            wh, wr = df['wavelet_hurst'].dropna(), df['wavelet_roughness'].dropna()
            wavelet_export = {'wavelet_hurst_mean': round(float(wh.mean()), 4) if len(wh) else 0, 'wavelet_roughness_mean': round(float(wr.mean()), 4) if len(wr) else 0, 'method': 'PyWavelets_db4_level4' if HAS_PYWT else 'disabled'}
        df['regime_change'] = df['regime'].ne(df['regime'].shift()).cumsum()
        regime_durations = df.groupby(['regime_change', 'regime']).size().reset_index(level='regime')
        mean_durations = regime_durations.groupby('regime')[0].mean().to_dict()
        sl_mult, tp_mult = {}, {}
        for r in REGIME_LABELS:
            dur = mean_durations.get(r, 50)
            sl_mult[r] = round(max(0.5, min(5.0, 1.0 + (dur / 50.0))), 1)
            tp_mult[r] = round(sl_mult[r] * 2.0, 1)
        macro_corr_dxy, macro_beta_dxy_trend, macro_beta_dxy_range = None, None, None
        macro_sens = self.macro.get('macro_sensitivity', {})
        for cr in macro_sens.get('top_correlations', []):
            if cr.get('macro_symbol') == 'DTWEXBGS' and cr.get('asset_feature') == 'close_ret':
                macro_corr_dxy = cr.get('correlation')
        regime_betas = macro_sens.get('regime_betas', {})
        if 'TREND_FORTE' in regime_betas and 'DTWEXBGS' in regime_betas['TREND_FORTE']:
            macro_beta_dxy_trend = regime_betas['TREND_FORTE']['DTWEXBGS'].get('elasticity')
        if 'RANGE' in regime_betas and 'DTWEXBGS' in regime_betas['RANGE']:
            macro_beta_dxy_range = regime_betas['RANGE']['DTWEXBGS'].get('elasticity')
        te = self.signal.get('transfer_entropy', {})
        dominant_regime = max(regime_dist, key=regime_dist.get) if regime_dist else "RANGE"
        return {
            'meta': {'symbol': symbol, 'timeframe': tf, 'generated_at': datetime.now().isoformat(), 'candles': len(df), 'date_from': str(df.index[0]), 'date_to': str(df.index[-1]), 'algo_version': ALGO_VERSION},
            'hurst_mean': avg_hurst, 'adx_mean': avg_adx, 'atr_mean': avg_atr, 'most_volatile_hour': vol_hour,
            'dfa_period': dfa_period, 'amplification_factor': round(self.tail_risk.get('avg_atr_spike', 0) / max(self.tail_risk.get('avg_atr_normal', 0.001), 0.001), 1),
            'hmm_agreement': round(self.hmm.get('agreement', 0), 1),
            'perm_entropy_mean': entropy_data.get('perm_entropy_mean', 0),
            'renyi_entropy_mean': entropy_data.get('renyi_entropy_mean', 0),
            'wavelet_hurst_mean': wavelet_export.get('wavelet_hurst_mean', 0),
            'wavelet_roughness_mean': wavelet_export.get('wavelet_roughness_mean', 0),
            'te_ret_to_vol': te.get('ret_to_vol', 0), 'te_vol_to_ret': te.get('vol_to_ret', 0),
            'stability_score': round(self.walkforward.get('stability_score', 0), 1),
            'purged_wf_score': round(self.purged_wf.get('stability_score', 0), 1),
            'trend_following_score': round(trend_score, 2), 'mean_reversion_score': round(meanrev_score, 2), 'breakout_score': round(breakout_score, 2),
            'macro_corr_dxy': macro_corr_dxy, 'macro_beta_dxy_trend': macro_beta_dxy_trend, 'macro_beta_dxy_range': macro_beta_dxy_range,
            'pbo_mean_reversion': round(self.pbo.get('mean_reversion_pbo', 0), 1), 'pbo_breakout': round(self.pbo.get('breakout_pbo', 0), 1),
            'optimal_wf_train_days': self.optimal_wf.get('train_size_days', 504), 'optimal_wf_retrain_days': self.optimal_wf.get('retrain_freq_days', 126),
            'dominant_regime': dominant_regime,
            'ea_trading_parameters': {'sl_atr_multiplier': sl_mult, 'tp_atr_multiplier': tp_mult, 'optimal_mr_params': self.pbo.get('best_mr_params', {'period': 20, 'std_mult': 2.0}), 'optimal_bo_params': self.pbo.get('best_bo_params', {'period': 50})},
            'mql5_directives': {'regime_thresholds': self.regime_thresholds},
            'regime_profile': {'dominant': dominant_regime, 'regime_distribution': regime_dist},
            'hmm_model': hmm_data,
            'entropy': entropy_data,
            'wavelet_analysis': wavelet_export,
            'fracdiff': {'d_param_close': self.fracdiff.get('d_close', 0.5), 'd_param_return': self.fracdiff.get('d_return', 0.3), 'd_method': 'FFD_ADF_optimized'},
            'tail_risk': {'spike_pct': self.tail_risk.get('spike_pct', 0), 'atr_threshold': self.tail_risk.get('atr_threshold', 0)},
            'transition_matrix': {f'{frm}_to_{to}': round(float(self.transition_mat[i][j]), 3) for i, frm in enumerate(self.regime_labels) for j, to in enumerate(self.regime_labels) if self.transition_mat[i][j] > 0.01},
            'macro_sensitivity': macro_sens,
            'signal_analysis': {'kalman_filtered': self.signal.get('has_kalman', False), 'transfer_entropy': te},
            'statistical_significance': {'hurst_test': self.signal.get('hurst_significance', {}), 'transfer_entropy_tests': self.signal.get('te_significance', {})},
            'purged_wf': {'score': round(self.purged_wf.get('stability_score', 0), 1), 'mean_js_divergence': round(self.purged_wf.get('mean_js_divergence', 0), 4)},
            'cpcv': {'regime_stability_score': self.cpcv.get('regime_stability_score'), 'methodology_note': self.cpcv.get('methodology_note', ''), 'n_paths': self.cpcv.get('n_paths', 0)},
        }

class SafeEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, (np.floating, float)):
            if np.isnan(obj) or np.isinf(obj): return None
            return float(obj)
        if isinstance(obj, np.integer): return int(obj)
        if isinstance(obj, np.bool_): return bool(obj)
        if isinstance(obj, (np.ndarray, pd.Series)): return obj.tolist()
        if isinstance(obj, pd.Timestamp): return str(obj)
        return super().default(obj)


# ══════════════════════════════════════════════════════════════
# MAIN PIPELINE
# ═════════════════════════════════════════════════════════════
def process_single_asset(symbol: str, tf: str, from_db: bool, years: int, skip_pdf: bool, skip_institutional: bool, no_cache: bool, force_pandas: bool, input_path: str = None) -> Dict[str, Any]:
    if force_pandas:
        import asset_dna_full as _m
        _m.CFG.use_polars = False
    warmup_numba_kernels()
    TOTAL_PHASES = 10 if not skip_institutional else 9
    t_total = time.time()

    log_phase(1, TOTAL_PHASES, f"DATA LOADING ({years} anos)")
    loader = DataLoader(symbol=symbol, tf=tf, from_db=from_db) if from_db else DataLoader(input_path)
    loader.years = years
    df = loader.load()
    if df.empty: return {'symbol': symbol, 'tf': tf, 'status': 'error', 'error': 'no data'}

    log_phase(2, TOTAL_PHASES, "FEATURE ENGINEERING (DFA + FFD + Kalman + KSG + Wavelets + Rényi)")
    fe = FeatureEngine(df, tf=tf)
    df = fe.compute()

    log_phase(3, TOTAL_PHASES, "REGIME (EXPANDING) + HMM-CAUSAL-AH")
    rm = RegimeModelExpanding(df, warmup=2000)
    df = rm.classify()
    trans_mat, regime_labels = rm.transition_matrix()
    hmm = HMMRegimeModel(df, n_states=4)
    df = hmm.classify()
    hmm_model_data = {'n_states': hmm.n_states, 'agreement': hmm.agreement, 'has_hmm': HAS_HMM and hmm.model is not None}

    log_phase(4, TOTAL_PHASES, "TEMPORAL + TAIL RISK")
    tp = TemporalProfiler(df)
    temporal = tp.analyze()
    tr = TailRiskEngine(df)
    tail_risk = tr.analyze()

    log_phase(5, TOTAL_PHASES, "MACRO RISK (FDR + ATR% + Johansen)")
    try:
        macro_int = MacroRiskIntegrator()
        macro_int.load()
        macro_results = macro_int.cross_reference(df, symbol=symbol)
    except Exception as e:
        logger.warning(f"[MACRO] Erro: {e}")
        macro_results = {}

    log_phase(6, TOTAL_PHASES, "WALK-FORWARD + CPCV (Regime Stability)")
    wf = WalkForwardValidator(df, n_windows=6)
    wf_results = wf.analyze()
    purged = PurgedWalkForwardValidator(df, n_windows=6)
    purged_results = purged.analyze()
    cpcv = CPCVValidator(df, n_splits=6, n_test_splits=2)
    cpcv_results = cpcv.analyze()

    pbo_results, opt_wf_results = {}, {}
    if not skip_institutional:
        log_phase(7, TOTAL_PHASES, "INSTITUTIONAL VALIDATION (PBO + Optimal Stopping)")
        validator = InstitutionalValidators(df)
        pbo_results = validator.compute_pbo()
        opt_wf_results = validator.compute_optimal_stopping()

    entropy_stats = {}
    if 'sample_entropy' in df.columns:
        se, pe, re = df['sample_entropy'].dropna(), df['perm_entropy'].dropna(), df['renyi_entropy'].dropna()
        entropy_stats = {'sample_entropy_mean': float(se.mean()) if len(se) else 0, 'perm_entropy_mean': float(pe.mean()) if len(pe) else 0, 'renyi_entropy_mean': float(re.mean()) if len(re) else 0}
    wavelet_stats = {}
    if 'wavelet_hurst' in df.columns:
        wh, wr = df['wavelet_hurst'].dropna(), df['wavelet_roughness'].dropna()
        wavelet_stats = {'wavelet_hurst_mean': float(wh.mean()) if len(wh) else 0, 'wavelet_roughness_mean': float(wr.mean()) if len(wr) else 0}

    signal_data = {'transfer_entropy': fe.transfer_entropy, 'has_kalman': 'close_denoised' in df.columns, 'hurst_significance': fe.hurst_significance, 'te_significance': fe.te_significance}
    fracdiff_data = {'d_close': fe.ffd_d_close, 'd_return': fe.ffd_d_return}

    ne = NarrativeEngine(df, rm, temporal, tail_risk, hmm_model=hmm_model_data, entropy=entropy_stats, fracdiff=fracdiff_data, signal_data=signal_data, wavelet_data=wavelet_stats)
    narratives = ne.generate()

    # [RESTAURADO] Chart Generator
    log_phase(8, TOTAL_PHASES, "CHART GENERATION")
    chart_gen = ChartGenerator(df)
    charts = chart_gen.generate_all(
        regime_model=rm, temporal=temporal, tail_risk=tail_risk, hmm_model=hmm_model_data,
        entropy=entropy_stats, fracdiff=fracdiff_data, signal_data=signal_data,
        walkforward=wf, purged_wf=purged, cpcv=cpcv, macro=macro_results,
        pbo=pbo_results, optimal_wf=opt_wf_results
    )

    # [RESTAURADO] PDF Report
    if not skip_pdf:
        log_phase(9, TOTAL_PHASES, "PDF REPORT GENERATION")
        pdf_output = str(CFG.report_dir / f"asset_dna_{symbol}_{tf}.pdf")
        pdf_builder = PDFReportBuilder(
            df, charts, narratives, rm, temporal, tail_risk,
            hmm_model=hmm_model_data, entropy=entropy_stats, fracdiff=fracdiff_data,
            signal_data=signal_data, walkforward=wf_results, purged_wf=purged_results,
            cpcv=cpcv_results, macro=macro_results, pbo=pbo_results, optimal_wf=opt_wf_results,
            symbol=symbol, tf=tf
        )
        pdf_builder.build(pdf_output)
    else:
        log_phase(9, TOTAL_PHASES, "PDF SKIPPED")

    log_phase(10, TOTAL_PHASES, "JSON EXPORT")
    json_output = str(CFG.report_dir / f"asset_profile_{symbol}_{tf}.json")
    exporter = JsonProfileExporter(
        df, regime_labels, trans_mat, temporal, tail_risk, wf_results, macro_results,
        hmm_model=hmm_model_data, entropy=entropy_stats, fracdiff=fracdiff_data,
        signal_data=signal_data, purged_wf=purged_results, cpcv=cpcv_results,
        pbo=pbo_results, optimal_wf=opt_wf_results,
        regime_thresholds=rm.final_expanding_thresholds, wavelet_data=wavelet_stats
    )
    exporter.export(json_output, symbol, tf)

    elapsed = time.time() - t_total
    logger.info(f"\n{'='*60}")
    logger.info(f"[OK] {symbol} {tf} | JSON: {json_output}")
    if not skip_pdf:
        logger.info(f"[OK] PDF: {pdf_output}")
    logger.info(f"[OK] Tempo: {elapsed:.2f}s | Candles: {len(df):,}")
    logger.info(f"[OK] DFA-Hurst: {df['hurst'].mean():.3f} | Wavelet-H: {wavelet_stats.get('wavelet_hurst_mean', 0):.3f}")
    logger.info(f"[OK] Regime Stability (CPCV): {cpcv_results.get('regime_stability_score', 'N/A')}%")
    logger.info(f"{'='*60}")

    return {
        'symbol': symbol, 'tf': tf, 'status': 'success',
        'candles': len(df), 'elapsed': round(elapsed, 2),
        'hurst': round(float(df['hurst'].mean()), 3),
        'dominant_regime': str(df['regime'].value_counts().index[0]),
        'json': json_output,
        'pdf': pdf_output if not skip_pdf else None,
    }


def main():
    parser = argparse.ArgumentParser(description=f'ALXQuant Asset DNA Profiler {ALGO_VERSION}')
    parser.add_argument('--symbol', default=None)
    parser.add_argument('--tf', default='M5', choices=['M1', 'M5'])
    parser.add_argument('--input', default=None)
    parser.add_argument('--batch', nargs='+', default=None)
    parser.add_argument('--no-cache', action='store_true')
    parser.add_argument('--force-pandas', action='store_true')
    parser.add_argument('--csv', action='store_true')
    parser.add_argument('--years', type=int, default=5, help='Anos de histórico (default=5)')
    parser.add_argument('--skip-pdf', action='store_true', help='Pula PDF (só JSON)')
    parser.add_argument('--skip-institutional', action='store_true', help='Pula PBO + Optimal Stopping')
    args = parser.parse_args()
    if args.force_pandas: CFG.use_polars = False
    if args.no_cache: CACHE.invalidate()
    from_db = not args.csv
    tf = args.tf.upper()
    if args.batch:
        logger.info(f"[BATCH] Processando {len(args.batch)} ativos em paralelo...")
        t_batch = time.time()
        if HAS_JOBLIB:
            n_jobs = CFG.n_jobs if CFG.n_jobs > 0 else None
            results = Parallel(n_jobs=n_jobs, backend='loky', verbose=10)(
                delayed(process_single_asset)(symbol, tf, from_db, args.years, args.skip_pdf, args.skip_institutional, args.no_cache, args.force_pandas, args.input)
                for symbol in args.batch
            )
        else:
            results = [process_single_asset(symbol, tf, from_db, args.years, args.skip_pdf, args.skip_institutional, args.no_cache, args.force_pandas, args.input) for symbol in args.batch]
        success = sum(1 for r in results if r.get('status') == 'success')
        logger.info(f"[BATCH] Concluído: {success}/{len(results)} sucesso em {time.time() - t_batch:.1f}s")
        return
    symbol = args.symbol or "XAUUSD"
    logger.info("=" * 60)
    logger.info(f"ALXQuant Asset DNA Profiler {ALGO_VERSION}")
    logger.info(f"Símbolo: {symbol} | TF: {tf} | Fonte: {'DuckDB' if from_db else 'CSV'}")
    logger.info("=" * 60)
    process_single_asset(symbol, tf, from_db, args.years, args.skip_pdf, args.skip_institutional, args.no_cache, args.force_pandas, args.input)


if __name__ == '__main__':
    main()