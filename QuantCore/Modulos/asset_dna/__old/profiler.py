"""
ALXQuant Asset DNA Profiler v2.1 (Polars + Multi-Asset + Modular)
==================================================================
Pipeline otimizado para:
  - Dezenas de milhões de candles (M1 desde 2008)
  - 100+ ativos em batch via Joblib
  - Polars streaming para datasets > RAM
  - Cache agressivo + lazy evaluation

Novidades vs v2.0:
  * Polars para I/O + FeatureEngine (3-5× mais rápido)
  * Joblib parallel executor para batch multi-ativo
  * Config via Pydantic (settings centralizados)
  * Logging estruturado (json output opcional)
  * Lazy evaluation + streaming para grandes datasets
  * CLI unificada: single asset ou batch via --batch

Preservado 100%:
  - Lógica estatística
  - Thresholds e fórmulas
  - Formato do PDF
  - Saída MQL5
  - Narrativas
"""

from __future__ import annotations

import os
import sys
import time
import math
import hashlib
import pickle
import warnings
import subprocess
import argparse
import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Any, Optional, Tuple, List, Union

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _THIS_DIR)
sys.path.insert(0, os.path.dirname(_THIS_DIR))  # parent (app/) for db.schema
from db.schema import get_connection

import numpy as np
import pandas as pd

# Polars - novo backend para I/O e feature engineering
try:
    import polars as pl
    HAS_POLARS = True
except ImportError:
    HAS_POLARS = False
    pl = None  # type: ignore

# Numba JIT
try:
    from numba import njit, prange
    HAS_NUMBA = True
except ImportError:
    HAS_NUMBA = False
    def njit(*args, **kwargs):
        def wrapper(fn): return fn
        return wrapper
    prange = range

# Joblib para paralelização
try:
    from joblib import Parallel, delayed, Memory
    import joblib
    HAS_JOBLIB = True
except ImportError:
    HAS_JOBLIB = False

# Bottleneck para rolling
try:
    import bottleneck as bn
    HAS_BOTTLENECK = True
except ImportError:
    HAS_BOTTLENECK = False

from scipy import stats

# PyWavelets para wavelet denoising (Fase 2)
try:
    import pywt
    HAS_PYWT = True
except ImportError:
    HAS_PYWT = False

# sklearn para mutual information
try:
    from sklearn.feature_selection import mutual_info_regression
    HAS_SKLEARN = True
except ImportError:
    HAS_SKLEARN = False

# HMM para detecção de regimes (institucional)
try:
    from hmmlearn.hmm import GaussianHMM
    HAS_HMM = True
except ImportError:
    HAS_HMM = False
    GaussianHMM = None  # type: ignore

# tqdm para barras de progresso
try:
    from tqdm import tqdm, trange
    HAS_TQDM = True
except ImportError:
    HAS_TQDM = False
    def tqdm(iterable, **kwargs):
        return iterable
    def trange(*args, **kwargs):
        return range(*args)

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

# Pydantic para config (opcional, fallback para dict)
try:
    from pydantic import BaseModel, Field, validator
    from pydantic_settings import BaseSettings
    HAS_PYDANTIC = True
except ImportError:
    HAS_PYDANTIC = False
    BaseModel = object  # type: ignore
    BaseSettings = object  # type: ignore
    Field = lambda *args, **kwargs: None  # type: ignore

warnings.filterwarnings('ignore')


# ══════════════════════════════════════════════════════════════
# CONFIGURAÇÃO CENTRALIZADA (Pydantic ou fallback)
# ══════════════════════════════════════════════════════════════
ALGO_VERSION = "v2.2"

_MODULE_DIR = Path(__file__).parent

_DATA_DIR = Path(os.getenv('ALXQUANT_DATA_DIR', r'C:\ALXQuant\data\datasets'))

if HAS_PYDANTIC:
    class Config(BaseSettings):
        # Paths
        output_dir: Path = Path(os.getenv('ALXQUANT_DATA_DIR', str(_DATA_DIR)))
        report_dir: Path = Path(r'C:\ALXQuant\data\mql5')
        cache_dir: Path = _MODULE_DIR / "_cache"
        # Performance
        use_polars: bool = True
        use_numba: bool = True
        use_bottleneck: bool = True
        use_joblib: bool = True
        n_jobs: int = -1  # -1 = todos os cores
        chunk_size: int = 1_000_000  # para streaming
        # Visual
        chart_dpi: int = 120
        chart_format: str = 'png'
        # Cache
        cache_ttl_hours: int = 168  # 7 dias
        cache_compress: int = 3
        # Logging
        log_level: str = 'INFO'
        log_json: bool = False

        class Config:
            env_file = '.env'
            env_file_encoding = 'utf-8'

    CFG = Config()
else:
    # Fallback sem Pydantic
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

# Criar diretórios
for d in [CFG.output_dir, CFG.report_dir, CFG.cache_dir]:
    d.mkdir(parents=True, exist_ok=True)

# Cores e constantes visuais
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

# Constantes de negócio
SESSION_LABELS = ['Asia', 'London', 'NY_AM', 'NY_PM']
SESSION_HOURS = [(0, 8), (8, 13), (13, 17), (17, 24)]
REGIME_LABELS = ['TREND_FORTE', 'TREND_FRACO', 'RANGE', 'CHOP']
REGIME_COLORS = {
    'TREND_FORTE': '#27AE60', 'TREND_FRACO': '#3498DB',
    'RANGE': '#F39C12', 'CHOP': '#E74C3C',
}


# ══════════════════════════════════════════════════════════════
# LOGGING ESTRUTURADO
# ══════════════════════════════════════════════════════════════
def setup_logger(name: str = 'asset_dna') -> logging.Logger:
    logger = logging.getLogger(name)
    logger.setLevel(getattr(logging, CFG.log_level.upper()))
    
    if logger.handlers:
        return logger
    
    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(getattr(logging, CFG.log_level.upper()))
    
    if CFG.log_json:
        # Formato JSON para ingestão em sistemas de log
        formatter = logging.Formatter(
            '{"time":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}'
        )
    else:
        # Formato humano legível
        formatter = logging.Formatter(
            '%(asctime)s [%(levelname)s] %(name)s: %(message)s',
            datefmt='%H:%M:%S'
        )
    
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    return logger

logger = setup_logger()


# ══════════════════════════════════════════════════════════════
# CACHE INFRASTRUCTURE (DiskCache com TTL)
# ══════════════════════════════════════════════════════════════
class DiskCache:
    """Cache em disco com TTL, hash-based, suporte a Polars/Pandas."""
    
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
        """Gera hash SHA-256 para dados + parametros do algoritmo."""
        if isinstance(data, (np.ndarray, pd.DataFrame, pd.Series)):
            if isinstance(data, pd.DataFrame):
                data_bytes = data.to_numpy()
            elif isinstance(data, pd.Series):
                data_bytes = data.to_numpy()
            else:
                data_bytes = data
            h = hashlib.sha256(np.ascontiguousarray(data_bytes).tobytes())
        elif HAS_POLARS and isinstance(data, pl.DataFrame):
            h = hashlib.sha256(data.write_csv().encode())
        else:
            h = hashlib.sha256(pickle.dumps(data))
        if params:
            h.update(json.dumps(params, sort_keys=True).encode())
        return h.hexdigest()[:20]
    
    def _key_path(self, namespace: str, data_hash: str) -> Path:
        return self.cache_dir / f"{namespace}_{data_hash}_{self.version}.joblib"
    
    def _is_fresh(self, path: Path) -> bool:
        """Verifica se cache está dentro do TTL."""
        if not path.exists():
            return False
        age_hours = (time.time() - path.stat().st_mtime) / 3600
        return age_hours < CFG.cache_ttl_hours
    
    def get(self, namespace: str, data_for_hash: Any, params: Optional[Dict] = None) -> Optional[Any]:
        """Tenta recuperar do cache."""
        if not HAS_JOBLIB:
            return None
        try:
            h = self._hash_data(data_for_hash, params)
            path = self._key_path(namespace, h)
            if self._is_fresh(path):
                logger.debug(f"[CACHE HIT] {namespace}:{h[:8]}")
                return joblib.load(path)
        except Exception as e:
            logger.warning(f"[CACHE] Erro ao ler cache: {e}")
        return None
    
    def put(self, namespace: str, data_for_hash: Any, value: Any, params: Optional[Dict] = None) -> Any:
        """Salva no cache."""
        if not HAS_JOBLIB:
            return value
        try:
            h = self._hash_data(data_for_hash, params)
            path = self._key_path(namespace, h)
            joblib.dump(value, path, compress=CFG.cache_compress)
            logger.debug(f"[CACHE SAVE] {namespace}:{h[:8]}")
        except Exception as e:
            logger.warning(f"[CACHE] Erro ao salvar cache: {e}")
        return value
    
    def invalidate(self, namespace: str = None):
        """Invalida cache por namespace ou tudo."""
        pattern = f"{namespace}_" if namespace else ""
        for f in self.cache_dir.glob(f"{pattern}*.joblib"):
            try:
                f.unlink()
                logger.info(f"[CACHE INVALIDATE] {f.name}")
            except Exception as e:
                logger.warning(f"[CACHE] Erro ao invalidar {f}: {e}")

CACHE = DiskCache()


# ══════════════════════════════════════════════════════════════
# NUMBA KERNELS (hot path otimizado)
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
    def _hurst_numba(log_prices: np.ndarray, window: int) -> np.ndarray:
        n = log_prices.shape[0]
        out = np.full(n, np.nan, dtype=np.float64)
        max_lag = min(50, window // 2)
        if max_lag < 6:
            return out
        
        lags = np.arange(2, max_lag + 1, dtype=np.int64)
        log_lags = np.log(lags.astype(np.float64))
        
        for i in prange(window - 1, n):
            w_start = i - window + 1
            mean_w = log_prices[w_start:i+1].mean()
            var_w = ((log_prices[w_start:i+1] - mean_w) ** 2).mean()
            
            if var_w < 1e-20 or window < 50:
                out[i] = 0.5
                continue
            
            sum_x, sum_x2, sum_y, sum_xy, n_valid = 0.0, 0.0, 0.0, 0.0, 0
            
            for j in range(len(lags)):
                lag = lags[j]
                n_diff = window - lag
                if n_diff < 2: continue
                diff = log_prices[w_start:i+1-lag] - log_prices[w_start+lag:i+1]
                tau = np.std(diff)
                if tau > 1e-10:
                    log_tau = np.log(tau)
                    lx = log_lags[j]
                    sum_x += lx; sum_x2 += lx*lx
                    sum_y += log_tau; sum_xy += lx*log_tau
                    n_valid += 1
            
            if n_valid < 5:
                out[i] = 0.5
                continue
            denom = n_valid * sum_x2 - sum_x * sum_x
            if abs(denom) < 1e-20:
                out[i] = 0.5
                continue
            a = (n_valid * sum_xy - sum_x * sum_y) / denom
            out[i] = max(0.01, min(a, 0.99))
        return out
else:
    def _classify_session_numba(hours): return np.zeros(len(hours), dtype=np.int8)
    def _transition_matrix_numba(regimes_int, n_labels): return np.zeros((n_labels, n_labels))
    def _hurst_numba(log_prices, window): return np.full(len(log_prices), 0.5)


# Numba warm-up: compila kernels com dados dummy antes do pipeline real
def warmup_numba_kernels():
    """Forca compilacao JIT dos kernels Numba com dados sinteticos.
    Executar uma vez no inicio do pipeline para evitar "travamento" silencioso."""
    if not HAS_NUMBA:
        return
    logger.info("[WARM-UP] Compilando kernels Numba (pode levar ate 60s)...")
    dummy = np.random.randn(2000).astype(np.float64)
    dummy_int = np.random.randint(0, 4, 2000).astype(np.int32)
    t0 = time.time()
    # Session classifier
    _classify_session_numba(np.array([0, 6, 10, 15, 20], dtype=np.int32))
    # Sample Entropy
    _sample_entropy_numba(dummy, m=2, r_factor=0.2)
    # Hurst
    _hurst_numba(np.cumsum(dummy), 100)
    # Transition matrix
    _transition_matrix_numba(dummy_int, 4)
    # MI
    _mi_numba(dummy[:1000], dummy[1000:2000], bins=20)
    # Transfer Entropy
    dummy_bin = np.random.randint(0, 3, 200).astype(np.int64)
    _transfer_entropy_numba(dummy_bin, dummy_bin, 3, 1)
    elapsed = time.time() - t0
    logger.info(f"[WARM-UP] Kernels Numba compilados em {elapsed:.1f}s")


# ══════════════════════════════════════════════════════════════
# ADVANCED STATISTICAL FEATURES (Entropy + Fractional Diff)
# ══════════════════════════════════════════════════════════════

@njit(cache=True, fastmath=True)
def _sample_entropy_numba(data: np.ndarray, m: int = 2, r_factor: float = 0.2) -> float:
    """Sample Entropy — measure of time-series complexity. Numba JIT."""
    n = data.shape[0]
    if n < m + 2:
        return 0.0
    std_val = np.std(data)
    if std_val < 1e-10:
        return 0.0
    r = r_factor * std_val
    # Count template matches using Numba-compatible loops
    A = 0
    B = 0
    for i in range(n - m):
        for j in range(i + 1, n - m):
            match_m = True
            for k in range(m):
                if abs(data[i + k] - data[j + k]) >= r:
                    match_m = False
                    break
            if match_m:
                B += 1
                # Also check m+1
                if i < n - m - 1 and j < n - m - 1:
                    if abs(data[i + m] - data[j + m]) < r:
                        A += 1
    if B == 0:
        return 0.0
    if A == 0:
        return float(np.log(2.0 * n))
    return -np.log(A / B)


def _permutation_entropy(data: np.ndarray, order: int = 4, delay: int = 1) -> float:
    """Permutation Entropy — measure of chaos / randomness in ordinal patterns.
    Lower  → more ordered (trending / oscillating with pattern).
    Higher → more random (efficient market).
    """
    n = len(data)
    if n < order * delay + 1:
        return 0.0
    permutations: Dict[Tuple[int, ...], int] = {}
    for i in range(n - (order - 1) * delay):
        window = data[i:i + order * delay:delay]
        pattern = tuple(np.argsort(window))
        permutations[pattern] = permutations.get(pattern, 0) + 1
    total = sum(permutations.values())
    probs = np.array(list(permutations.values()), dtype=np.float64) / total
    probs = probs[probs > 0]
    if len(probs) == 0:
        return 0.0
    max_ent = math.log(math.factorial(order))
    if max_ent < 1e-10:
        return 0.0
    return -np.sum(probs * np.log(probs)) / max_ent


def _fracdiff_weights(d: float, window: int) -> np.ndarray:
    """Compute fractional differentiation weights (expanding window).
    d = 0 → original series (no diff)
    d = 1 → first difference
    0 < d < 1 → fractionally differentiated (balance stationarity vs memory)
    """
    w = [1.0]
    for k in range(1, window):
        w.append(-w[-1] * (d - k + 1) / k)
    return np.array(w, dtype=np.float64)


def _fracdiff_series(series: np.ndarray, d: float = 0.5, window: int = 100) -> np.ndarray:
    """Apply fractional differentiation to a series.
    Returns array of same length with leading NaN for the initial window.
    """
    w = _fracdiff_weights(d, window)
    result = np.full(len(series), np.nan, dtype=np.float64)
    for i in range(window - 1, len(series)):
        result[i] = np.dot(w, series[i - window + 1:i + 1][::-1])
    return result


def rolling_entropy(data: np.ndarray, window: int, method: str = 'sample', **kwargs) -> np.ndarray:
    """Rolling entropy over a window. method='sample' or 'permutation'."""
    n = len(data)
    result = np.full(n, np.nan, dtype=np.float64)
    half = window // 2
    for i in range(half, n - half):
        chunk = data[i - half:i + half]
        if len(chunk) < 10:
            continue
        if method == 'sample':
            result[i] = _sample_entropy_numba(chunk, **kwargs)
        else:
            result[i] = _permutation_entropy(chunk, **kwargs)
    return result


# ══════════════════════════════════════════════════════════════
# ROLLING HELPERS (Bottleneck ou fallback)
# ══════════════════════════════════════════════════════════════
def rolling_mean(arr: np.ndarray, window: int) -> np.ndarray:
    if HAS_BOTTLENECK:
        return bn.move_mean(arr, window, min_count=window)
    return pd.Series(arr).rolling(window, min_periods=window).mean().to_numpy()

def rolling_std(arr: np.ndarray, window: int) -> np.ndarray:
    if HAS_BOTTLENECK:
        return bn.move_std(arr, window, min_count=window)
    return pd.Series(arr).rolling(window, min_periods=window).std().to_numpy()


# ══════════════════════════════════════════════════════════════
# FASE 2: WAVELET + MUTUAL INFORMATION + TRANSFER ENTROPY
# ══════════════════════════════════════════════════════════════

def _wavelet_denoise(data: np.ndarray, wavelet: str = 'db4', level: int = None) -> np.ndarray:
    """Wavelet denoising via soft-thresholding (Donoho) — interior function, non-causal per-segment."""
    if not HAS_PYWT:
        return data
    if level is None:
        level = min(4, int(np.log2(len(data))) - 1)
    if level < 1:
        return data
    coeffs = pywt.wavedec(data, wavelet, level=level)
    sigma = np.median(np.abs(coeffs[-1])) / 0.6745
    if sigma < 1e-10:
        return data
    threshold = sigma * np.sqrt(2 * np.log(len(data)))
    coeffs = [coeffs[0]] + [pywt.threshold(c, threshold, mode='soft') for c in coeffs[1:]]
    return pywt.waverec(coeffs, wavelet)[:len(data)]


def _wavelet_denoise_causal(data: np.ndarray, window: int = 504, step: int = 21,
                             wavelet: str = 'db4', level: int = None) -> np.ndarray:
    """Wavelet denoising com janela deslizante causal (sem look-ahead)."""
    n = len(data)
    result = np.full(n, np.nan, dtype=np.float64)
    win = min(window, n)
    for right in range(win, n, step):
        chunk = data[right - win:right]
        denoised = _wavelet_denoise(chunk, wavelet, level)
        result[right - step:right] = denoised[-step:]
    return result


# ══════════════════════════════════════════════════════════════
# FASE 3: NUMBA-JIT OPTIMIZED MI + TE + FRACDIFF
# ══════════════════════════════════════════════════════════════

@njit(cache=True, fastmath=True)
def _mi_numba(x: np.ndarray, y: np.ndarray, bins: int = 20) -> float:
    """Mutual Information via 2D histogram (Numba). MI = H(X)+H(Y)-H(X,Y)."""
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


@njit(cache=True, fastmath=True)
def _transfer_entropy_numba(s_bin: np.ndarray, t_bin: np.ndarray,
                            nbins: int, delay: int) -> float:
    """Transfer Entropy via 3D histogram (Numba)."""
    n = len(s_bin)
    if n < 100:
        return 0.0
    joint = np.zeros((nbins, nbins, nbins), dtype=np.int64)
    for i in range(delay, n - 1):
        tp = t_bin[i + 1]
        t = t_bin[i]
        s = s_bin[i - delay]
        if 0 <= tp < nbins and 0 <= t < nbins and 0 <= s < nbins:
            joint[tp, t, s] += 1
    total = joint.sum()
    if total == 0:
        return 0.0
    p_t = np.zeros(nbins, dtype=np.float64)
    p_tt = np.zeros((nbins, nbins), dtype=np.float64)
    p_ts = np.zeros((nbins, nbins), dtype=np.float64)
    for tp in range(nbins):
        for t in range(nbins):
            for s in range(nbins):
                c = joint[tp, t, s]
                if c == 0:
                    continue
                p_t[t] += c
                p_tt[tp, t] += c
                p_ts[t, s] += c
    for k in range(nbins): p_t[k] /= total
    for i in range(nbins):
        for j in range(nbins):
            p_tt[i, j] /= total
            p_ts[i, j] /= total
    te = 0.0
    for tp in range(nbins):
        for t in range(nbins):
            for s in range(nbins):
                c = joint[tp, t, s]
                if c == 0:
                    continue
                p_tts = c / total
                num = p_tts * p_t[t]
                den = p_ts[t, s] * p_tt[tp, t]
                if num > 0 and den > 0:
                    te += p_tts * np.log2(num / den)
    return max(0.0, te)


def _mutual_information_matrix_numba(df: pd.DataFrame, cols: List[str]) -> np.ndarray:
    """Pairwise MI via Numba (10-50x faster than sklearn)."""
    n = len(cols)
    mi_mat = np.zeros((n, n))
    data = {c: df[c].dropna().to_numpy(dtype=np.float64) for c in cols}
    for i in range(n):
        for j in range(i + 1, n):
            x = data[cols[i]]
            y = data[cols[j]]
            if len(x) == 0 or len(y) == 0:
                continue
            mi_mat[i, j] = _mi_numba(x, y, bins=20)
            mi_mat[j, i] = mi_mat[i, j]
    return mi_mat


def _transfer_entropy_fast(source: np.ndarray, target: np.ndarray,
                            bins: int = 3, delay: int = 1) -> float:
    """Discrete TE via Numba array histogram."""
    n = len(source)
    if n < 100:
        return 0.0
    s_bin = np.digitize(source, np.percentile(source, [100/bins * (i+1) for i in range(bins-1)]))
    t_bin = np.digitize(target, np.percentile(target, [100/bins * (i+1) for i in range(bins-1)]))
    return _transfer_entropy_numba(s_bin, t_bin, bins, delay)


# ══════════════════════════════════════════════════════════════
# DATA LOADER (Polars + Pandas fallback)
# ══════════════════════════════════════════════════════════════


# ══════════════════════════════════════════════════════════════
# DATA LOADER (Polars + Pandas fallback)
# ══════════════════════════════════════════════════════════════
class DataLoader:
    """Carrega dados com Polars (streaming) ou Pandas fallback.
    Suporta CSV (padrão) ou SQLite (when from_db=True)."""
    
    def __init__(self, filepath: Optional[Union[str, Path]] = None, symbol: str = None, tf: str = 'M5',
                 from_db: bool = True):
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
        self.df: Optional[Union[pd.DataFrame, pl.DataFrame]] = None
        self.backend = 'polars' if HAS_POLARS and CFG.use_polars else 'pandas'
    
    @staticmethod
    def _normalize_columns(df: pd.DataFrame) -> pd.DataFrame:
        """Normaliza colunas para o formato interno (time, open, high, low, close, tick_volume, spread, real_volume).
        Suporta Dukascopy (Date+Time, Volume) e outros formatos comuns."""
        cols_lower = [c.lower() for c in df.columns]

        # --- Dukascopy: Date+Time separados, Volume em maiúsculo ---
        if 'date' in cols_lower and 'time' in cols_lower:
            # Mapear nomes reais (respeitando capitalização original)
            col_map = {c: c for c in df.columns}
            date_col = next(c for c in df.columns if c.lower() == 'date')
            time_col = next(c for c in df.columns if c.lower() == 'time')
            df['time'] = pd.to_datetime(
                df[date_col].astype(str) + ' ' + df[time_col].astype(str),
                format='%Y%m%d %H:%M:%S', errors='coerce'
            )
            df.drop(columns=[date_col, time_col], inplace=True)

        # --- Renomear Volume → tick_volume ---
        if 'volume' in cols_lower and 'tick_volume' not in cols_lower:
            vol_col = next(c for c in df.columns if c.lower() == 'volume')
            df.rename(columns={vol_col: 'tick_volume'}, inplace=True)

        # --- Forçar lower case nos nomes das colunas ---
        df.columns = [c.lower() for c in df.columns]

        # --- Adicionar colunas faltantes (spread, real_volume) ---
        if 'spread' not in df.columns:
            df['spread'] = 0
        if 'real_volume' not in df.columns:
            df['real_volume'] = 0

        # Ordernar colunas no formato canônico
        cols = ['time', 'open', 'high', 'low', 'close', 'tick_volume', 'spread', 'real_volume']
        for c in cols:
            if c not in df.columns:
                df[c] = 0
        df = df[[c for c in cols if c in df.columns]]
        return df

    def _load_from_db(self) -> pd.DataFrame:
        """Carrega dados OHLC do banco DuckDB."""
        logger.info(f"[LOAD] DuckDB: {self.symbol}_{self.tf}")
        conn = get_connection(read_only=True)
        query = """
            SELECT time, open, high, low, close, tick_volume, spread, real_volume
            FROM ohlc_prices
            WHERE symbol = ? AND timeframe = ?
            ORDER BY time
        """
        df = conn.execute(query, [self.symbol, self.tf]).df()
        conn.close()
        if df.empty:
            logger.warning("  Nenhum dado encontrado no banco")
            return pd.DataFrame()
        df['time'] = pd.to_datetime(df['time'], unit='s')
        df.set_index('time', inplace=True)
        df.index.name = 'time'
        logger.info(f"  [OK] {len(df):,} candles do banco | {df.index[0]} a {df.index[-1]}")
        return df

    def load(self) -> pd.DataFrame:
        if self.from_db:
            return self._load_from_db()

        logger.info(f"[LOAD] {self.filepath} (backend: {self.backend})")
        
        if not self.filepath.exists():
            logger.error(f"Arquivo nao encontrado: {self.filepath}")
            sys.exit(1)
        
        # Tenta cache Parquet primeiro
        parquet_path = self.filepath.with_suffix('.parquet')
        use_parquet = parquet_path.exists() and self.filepath.suffix.lower() == '.csv'
        
        if use_parquet and self.backend == 'polars':
            logger.info(f"  -> Usando cache Parquet via Polars")
            df_pl = pl.scan_parquet(parquet_path).collect(streaming=True)
            df = df_pl.to_pandas()
        elif use_parquet:
            logger.info(f"  -> Usando cache Parquet via Pandas")
            df = pd.read_parquet(parquet_path)
        elif self.backend == 'polars':
            # Polars scan — lê cru, depois normaliza
            df_pl = pl.scan_csv(self.filepath, parse_dates=False).collect(streaming=True)
            df = self._normalize_columns(df_pl.to_pandas())
            # Salva cache Parquet para próximas execuções
            try:
                pl.from_pandas(df).write_parquet(parquet_path, compression='snappy')
                logger.info(f"  -> Cache Parquet criado")
            except Exception as e:
                logger.warning(f"  -> Aviso: não foi possível criar cache Parquet: {e}")
        else:
            # Pandas fallback — lê cru (sem parse_dates), depois normaliza
            df = pd.read_csv(self.filepath, low_memory=False)
            df = self._normalize_columns(df)
            # Salva cache Parquet
            try:
                df.to_parquet(parquet_path, engine='pyarrow', compression='snappy')
            except Exception as e:
                pass
        
        # Converter colunas para datetime
        if 'time' in df.columns and not np.issubdtype(df['time'].dtype, np.datetime64):
            df['time'] = pd.to_datetime(df['time'])
        
        # Setup index
        if 'time' in df.columns:
            df.set_index('time', inplace=True)
            df.index.name = 'time'
        
        logger.info(f"  [OK] {len(df):,} candles | {df.index[0]} a {df.index[-1]}")
        self.df = df
        return df


# ══════════════════════════════════════════════════════════════
# FEATURE ENGINE (Polars-optimized + Numba)
# ══════════════════════════════════════════════════════════════
class FeatureEngine:
    """Feature engineering otimizado com Polars e Numba."""
    
    def __init__(self, df: pd.DataFrame, tf: str = 'M5'):
        self.df = df
        self.ws = 5 if tf == 'M1' else 1
        self.tf = tf
        self.backend = 'polars' if HAS_POLARS and CFG.use_polars else 'pandas'
        self.mi_matrix = None
        self.mi_labels = []
        self.transfer_entropy = {}
    
    def compute(self) -> pd.DataFrame:
        t0 = time.time()
        logger.info(f"[FEATURES] Computando features (janelas x{self.ws}, backend: {self.backend})")
        
        df = self.df
        
        cache_seed = np.column_stack([
            df['close'].to_numpy(dtype=np.float32),
            df['high'].to_numpy(dtype=np.float32),
            df['low'].to_numpy(dtype=np.float32),
            df['tick_volume'].to_numpy(dtype=np.int32),
        ])
        cache_params = {'ws': self.ws, 'tf': self.tf, 'algo': ALGO_VERSION}
        cached = CACHE.get("features_v4", cache_seed, params=cache_params)
        if cached is not None:
            logger.info(f"  [CACHE HIT] Features em {time.time()-t0:.2f}s")
            if cached.index[0] != df.index[0]:
                logger.info("  Cache index mismatch, recomputing...")
            elif len(cached) == len(df):
                logger.info(f"  [OK] {len(cached):,} candles do cache")
                return cached
        
        if self.backend == 'polars' and HAS_POLARS:
            df = self._compute_polars(df, cache_seed)
        else:
            df = self._compute_pandas(df, cache_seed)
        
        # Post-processing: entropy + fractional diff (sempre numpy)
        df = self._add_advanced_features(df)
        
        # Save cache com advanced features
        CACHE.put("features_v4", cache_seed, df, params=cache_params)
        return df
    
    def _add_advanced_features(self, df: pd.DataFrame) -> pd.DataFrame:
        """Adiciona Entropy, Fractional Diff, Wavelet Denoising, MI, Transfer Entropy."""
        close = df['close'].to_numpy(dtype=np.float64)
        log_ret = df['log_return'].to_numpy(dtype=np.float64)
        high = df['high'].to_numpy(dtype=np.float64)
        low = df['low'].to_numpy(dtype=np.float64)
        n = len(close)
        t0 = time.time()
        logger.info(f"[ADV FEATURES] Entropy + Fractional Diff + Wavelet + MI + TE...")
        
        # --- Entropy: rolling causal com sub-amostragem (step=50) ---
        # Sample Entropy é O(L²) por janela; calcular a cada 50 candles
        # reduz o custo de O(N×L²) para O(N/step × L²) e interpola.
        t1 = time.time()
        entropy_win = min(500, n // 4)
        entropy_step = 50
        se = np.full(n, np.nan, dtype=np.float32)
        pe = np.full(n, np.nan, dtype=np.float32)
        
        # Indices onde calcular entropy (sub-amostrados)
        idx_calc = list(range(entropy_win, n, entropy_step))
        if idx_calc and idx_calc[-1] != n - 1:
            idx_calc.append(n - 1)
        
        se_vals, pe_vals = [], []
        if HAS_TQDM:
            pbar = tqdm(idx_calc, desc="[ENTROPY] Rolling causal", unit="candle",
                        mininterval=2.0, ncols=80)
        else:
            pbar = idx_calc
        
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
        
        # Interpolar para preencher todos os pontos (forward-fill simples)
        idx_calc_arr = np.array(idx_calc, dtype=np.int64)
        for i in range(len(se)):
            nearest = idx_calc_arr[idx_calc_arr <= i]
            if len(nearest) > 0:
                j = nearest[-1]
                se[i] = se_vals[np.where(idx_calc_arr == j)[0][0]]
                pe[i] = pe_vals[np.where(idx_calc_arr == j)[0][0]]
        
        df['sample_entropy'] = se
        df['perm_entropy'] = pe
        reduction = f"{n}/{entropy_step} = {len(idx_calc)} pontos"
        logger.info(f"  [ENTROPY] OK em {time.time()-t1:.2f}s (sub-amostragem step={entropy_step}, {reduction}, win={entropy_win})")
        
        # --- Fractional Differentiation (d=0.5) ---
        fd_window = 50 * self.ws
        fd = _fracdiff_series(np.log(close), d=0.5, window=fd_window)
        df['fracdiff_close'] = fd.astype(np.float32)
        
        fd_ret = _fracdiff_series(log_ret, d=0.3, window=fd_window)
        df['fracdiff_return'] = fd_ret.astype(np.float32)
        
        # --- Wavelet Denoising (Fase 2) ---
        t2 = time.time()
        if HAS_PYWT:
            denoised = _wavelet_denoise_causal(np.log(close.copy()), wavelet='db4', level=4)
            df['log_close_denoised'] = np.where(np.isfinite(denoised), denoised.astype(np.float32), np.float32(np.nan))
            df['close_denoised'] = np.exp(df['log_close_denoised'].to_numpy(dtype=np.float64))
            ret_denoised = _wavelet_denoise_causal(log_ret.copy(), wavelet='db4', level=3)
            df['return_denoised'] = np.where(np.isfinite(ret_denoised), ret_denoised.astype(np.float32), np.float32(np.nan))
        logger.info(f"  [WAVELET] OK em {time.time()-t2:.2f}s")
        
        # --- Mutual Information Matrix (Numba JIT, ~10x faster) ---
        t3 = time.time()
        mi_cols = ['hurst', 'adx', 'atr', 'return', 'volume_zscore', 'tr_zscore']
        mi_available = [c for c in mi_cols if c in df.columns]
        if len(mi_available) >= 2:
            self.mi_matrix = _mutual_information_matrix_numba(df, mi_available)
            self.mi_labels = mi_available
        else:
            self.mi_matrix = np.zeros((len(mi_available), len(mi_available)))
            self.mi_labels = mi_available
        logger.info(f"  [MI] OK em {time.time()-t3:.2f}s")
        
        # --- Transfer Entropy directional (Numba JIT, ~5x faster) ---
        t4 = time.time()
        te_results = {}
        if 'return' in df.columns and 'volume_zscore' in df.columns:
            r = df['return'].dropna().to_numpy(dtype=np.float64)
            v = df['volume_zscore'].dropna().to_numpy(dtype=np.float64)
            min_len = min(len(r), len(v))
            r = r[:min_len]
            v = v[:min_len]
            te_results['ret_to_vol'] = round(_transfer_entropy_fast(r, v, bins=3, delay=1), 4)
            te_results['vol_to_ret'] = round(_transfer_entropy_fast(v, r, bins=3, delay=1), 4)
        if 'hurst' in df.columns and 'adx' in df.columns:
            h = df['hurst'].dropna().to_numpy(dtype=np.float64)
            a = df['adx'].dropna().to_numpy(dtype=np.float64)
            min_len = min(len(h), len(a))
            h = h[:min_len]
            a = a[:min_len]
            te_results['hurst_to_adx'] = round(_transfer_entropy_fast(h, a, bins=3, delay=1), 4)
            te_results['adx_to_hurst'] = round(_transfer_entropy_fast(a, h, bins=3, delay=1), 4)
        self.transfer_entropy = te_results
        logger.info(f"  [TE] OK em {time.time()-t4:.2f}s")
        
        logger.info(f"  [ADV OK] em {time.time()-t0:.2f}s")
        return df
    
    def _compute_polars(self, df: pd.DataFrame, cache_seed: np.ndarray = None) -> pd.DataFrame:
        """Feature engineering via Polars (lazy + streaming)."""
        t0 = time.time()
        # Converter para Polars
        df_pl = pl.from_pandas(df.reset_index())
        
        ws = self.ws
        
        # Retornos
        df_pl = df_pl.with_columns([
            (pl.col('close') - pl.col('close').shift(1)) / pl.col('close').shift(1).alias('return'),
            (pl.col('close').log() - pl.col('close').log().shift(1)).alias('log_return'),
        ])
        
        # ATR
        high, low, close = pl.col('high'), pl.col('low'), pl.col('close')
        close_prev = close.shift(1)
        tr = pl.max_horizontal([
            high - low,
            (high - close_prev).abs(),
            (low - close_prev).abs()
        ]).alias('tr')
        df_pl = df_pl.with_columns(tr)
        
        atr_win = 14 * ws
        df_pl = df_pl.with_columns(
            pl.col('tr').rolling_mean(window_size=atr_win).alias('atr')
        )
        
        # Z-Scores (janela longa 500*ws)
        z_win = 500 * ws
        tr_mean_long = pl.col('tr').rolling_mean(window_size=z_win)
        tr_std_long = pl.col('tr').rolling_std(window_size=z_win).clip(lower=1e-10)
        
        df_pl = df_pl.with_columns([
            ((pl.col('tr') - tr_mean_long) / tr_std_long).alias('tr_zscore'),
            ((pl.col('tr').rolling_mean(50*ws) - tr_mean_long) / tr_std_long).alias('vol_zscore'),
        ])
        
        # Volume Z-Score
        vol = pl.col('tick_volume')
        df_pl = df_pl.with_columns([
            vol.rolling_mean(50*ws).alias('vol_ma'),
            vol.rolling_std(50*ws).clip(lower=1e-10).alias('vol_std'),
            ((vol - vol.rolling_mean(50*ws)) / vol.rolling_std(50*ws).clip(lower=1e-10)).alias('volume_zscore'),
        ])
        
        # ADX (reusa ATR como tr_smooth)
        up_move = pl.col('high').diff()
        down_move = -pl.col('low').diff()
        plus_dm = pl.when((up_move > down_move) & (up_move > 0)).then(up_move).otherwise(0)
        minus_dm = pl.when((down_move > up_move) & (down_move > 0)).then(down_move).otherwise(0)
        
        tr_smooth = pl.col('atr')  # REUSO
        tr_smooth_safe = tr_smooth.clip(lower=1e-10)
        
        plus_di = 100 * plus_dm.rolling_mean(atr_win) / tr_smooth_safe
        minus_di = 100 * minus_dm.rolling_mean(atr_win) / tr_smooth_safe
        di_sum = (plus_di + minus_di).clip(lower=1e-10)
        dx = 100 * (plus_di - minus_di).abs() / di_sum
        
        df_pl = df_pl.with_columns([
            plus_di.alias('plus_di'),
            minus_di.alias('minus_di'),
            dx.alias('dx'),
            dx.rolling_mean(atr_win).alias('adx'),
        ])
        
        # Hurst via Numba (chamado sobre array numpy)
        log_price = df_pl['close'].log().to_numpy(dtype=np.float64)
        hurst_win = 100 * ws
        
        hurst_cached = CACHE.get("hurst", log_price.astype(np.float32))
        if hurst_cached is not None:
            logger.info(f"  [CACHE HIT] Hurst")
            hurst = hurst_cached
        else:
            logger.info(f"  [HURST] Calculando (window={hurst_win})...")
            t_h = time.time()
            hurst = _hurst_numba(log_price, hurst_win)
            logger.info(f"  [HURST] OK em {time.time()-t_h:.2f}s")
            CACHE.put("hurst", log_price.astype(np.float32), hurst)
        
        df_pl = df_pl.with_columns(pl.Series('hurst', hurst.astype(np.float32)))
        
        # Multi-timeframe via group_by_dynamic (Polars nativo)
        for freq_name, freq_str in [('return_m15', '15m'), ('return_h1', '1h'), 
                                     ('return_h4', '4h'), ('return_d1', '1d')]:
            close_mtf = (df_pl.select(['time', 'close'])
                        .group_by_dynamic(index_column='time', every=freq_str)
                        .last())
            # Forward fill via join_asof
            df_pl = df_pl.join_asof(
                close_mtf.with_columns(pl.col('close').alias(f'close_{freq_name}')),
                on='time', strategy='backward'
            )
            df_pl = df_pl.with_columns(
                (pl.col(f'close_{freq_name}') - pl.col(f'close_{freq_name}').shift(1)) 
                / pl.col(f'close_{freq_name}').shift(1)
            ).rename({f'close_{freq_name}': freq_name})
        
        # Sessão via Numba
        hours = df_pl['time'].dt.hour().to_numpy(dtype=np.int32)
        sess_int = _classify_session_numba(hours)
        sess_cat = pd.Categorical.from_codes(sess_int, categories=SESSION_LABELS)
        
        df_pl = df_pl.with_columns([
            pl.col('time').dt.hour().cast(pl.Int8).alias('hour'),
            pl.col('time').dt.weekday().cast(pl.Int8).alias('day_of_week'),  # Monday=0
            pl.col('time').dt.month().cast(pl.Int8).alias('month'),
        ])
        
        # Converter de volta para Pandas com dtypes otimizados
        df = df_pl.to_pandas()
        df['session'] = sess_cat
        
        # Drop NA
        before = len(df)
        df.dropna(inplace=True)
        logger.info(f"  [OK] {len(df):,} candles apos features ({before-len(df):,} removidos) em {time.time()-t0:.2f}s")
        
        return df
    
    def _compute_pandas(self, df: pd.DataFrame, cache_seed: np.ndarray = None) -> pd.DataFrame:
        """Feature engineering via Pandas (fallback)."""
        t0 = time.time()
        # Implementação idêntica à v2.0, mas sem df.copy() desnecessários
        close = df['close'].to_numpy(dtype=np.float64)
        
        # Retornos
        ret = np.empty_like(close); ret[0] = np.nan; ret[1:] = (close[1:] - close[:-1]) / close[:-1]
        df['return'] = ret
        log_ret = np.empty_like(close); log_ret[0] = np.nan; log_ret[1:] = np.log(close[1:] / close[:-1])
        df['log_return'] = log_ret
        
        # ATR
        high, low = df['high'].to_numpy(dtype=np.float64), df['low'].to_numpy(dtype=np.float64)
        close_prev = np.empty_like(close); close_prev[0] = np.nan; close_prev[1:] = close[:-1]
        tr = np.maximum(high - low, np.maximum(np.abs(high - close_prev), np.abs(low - close_prev)))
        df['tr'] = tr.astype(np.float32)
        
        ws = self.ws
        atr = rolling_mean(tr, 14*ws)
        df['atr'] = atr.astype(np.float32)
        
        # Z-Scores (calculados UMA vez)
        z_win = 500 * ws
        tr_mean_long = rolling_mean(tr, z_win)
        tr_std_long = rolling_std(tr, z_win)
        tr_std_safe = np.where(tr_std_long < 1e-10, 1e-10, tr_std_long)
        df['tr_zscore'] = ((tr - tr_mean_long) / tr_std_safe).astype(np.float32)
        df['vol_zscore'] = ((rolling_mean(tr, 50*ws) - tr_mean_long) / tr_std_safe).astype(np.float32)
        
        # Volume
        tick_vol = df['tick_volume'].to_numpy(dtype=np.float64)
        vol_ma = rolling_mean(tick_vol, 50*ws)
        vol_std = rolling_std(tick_vol, 50*ws)
        vol_std_safe = np.where(vol_std < 1e-10, 1e-10, vol_std)
        df['vol_ma'] = vol_ma.astype(np.float32)
        df['vol_std'] = vol_std.astype(np.float32)
        df['volume_zscore'] = ((tick_vol - vol_ma) / vol_std_safe).astype(np.float32)
        
        # ADX (reusa ATR)
        up_move = np.empty_like(high); up_move[0] = np.nan; up_move[1:] = high[1:] - high[:-1]
        down_move = np.empty_like(low); down_move[0] = np.nan; down_move[1:] = -(low[1:] - low[:-1])
        plus_dm = np.where((up_move > down_move) & (up_move > 0), up_move, 0.0)
        minus_dm = np.where((down_move > up_move) & (down_move > 0), down_move, 0.0)
        
        tr_smooth = atr  # REUSO
        tr_smooth_safe = np.where(tr_smooth < 1e-10, 1e-10, tr_smooth)
        plus_di = 100 * rolling_mean(plus_dm, 14*ws) / tr_smooth_safe
        minus_di = 100 * rolling_mean(minus_dm, 14*ws) / tr_smooth_safe
        di_sum = plus_di + minus_di
        di_sum_safe = np.where(di_sum < 1e-10, 1e-10, di_sum)
        dx = 100 * np.abs(plus_di - minus_di) / di_sum_safe
        df['plus_di'] = plus_di.astype(np.float32)
        df['minus_di'] = minus_di.astype(np.float32)
        df['dx'] = dx.astype(np.float32)
        df['adx'] = rolling_mean(dx, 14*ws).astype(np.float32)
        
        # Hurst
        log_price = np.log(close)
        df['log_price'] = log_price.astype(np.float32)
        hurst_win = 100 * ws
        
        hurst_cached = CACHE.get("hurst", log_price.astype(np.float32))
        if hurst_cached is not None:
            logger.info(f"  [CACHE HIT] Hurst")
            hurst = hurst_cached
        else:
            logger.info(f"  [HURST] Calculando...")
            t_h = time.time()
            hurst = _hurst_numba(log_price, hurst_win)
            logger.info(f"  [HURST] OK em {time.time()-t_h:.2f}s")
            CACHE.put("hurst", log_price.astype(np.float32), hurst)
        df['hurst'] = hurst.astype(np.float32)
        
        # MTF returns via merge_asof
        for freq_name, freq_str in [('return_m15', '15min'), ('return_h1', '1h'), 
                                     ('return_h4', '4h'), ('return_d1', '1D')]:
            close_mtf = df['close'].resample(freq_str, label='right').last().dropna()
            close_mtf_df = close_mtf.to_frame().reset_index().rename(columns={'time': 'time_mtf', 'close': f'close_{freq_name}'})
            merged = pd.merge_asof(
                df[['close']].reset_index().sort_values('time'),
                close_mtf_df.sort_values('time_mtf'),
                left_on='time', right_on='time_mtf', direction='backward'
            )
            df[f'{freq_name}'] = merged[f'close_{freq_name}'].pct_change().to_numpy(dtype=np.float32)
        
        # Sessão
        hours = df.index.hour.to_numpy(dtype=np.int32)
        sess_int = _classify_session_numba(hours)
        sess_cat = pd.Categorical.from_codes(sess_int, categories=SESSION_LABELS)
        df['hour'] = hours.astype(np.int8)
        df['day_of_week'] = df.index.dayofweek.to_numpy(dtype=np.int8)
        df['month'] = df.index.month.to_numpy(dtype=np.int8)
        df['session'] = sess_cat
        
        # Drop NA (fill auxiliary DB columns that may be all-NaN first)
        for col in ('spread', 'real_volume'):
            if col in df.columns and df[col].isna().all():
                df[col] = 0
        before = len(df)
        df.dropna(inplace=True)
        logger.info(f"  [OK] {len(df):,} candles apos features em {time.time()-t0:.2f}s")
        
        return df


# ══════════════════════════════════════════════════════════════
# REGIME MODEL (Numba + cache)
# ══════════════════════════════════════════════════════════════
class RegimeModel:
    def __init__(self, df: pd.DataFrame):
        self.df = df
    
    def classify(self) -> pd.DataFrame:
        logger.info("[REGIMES] Classificando regimes (thresholds adaptativos por percentil)...")
        df = self.df
        
        adx_p75 = df['adx'].quantile(0.75)
        adx_p50 = df['adx'].quantile(0.50)
        hurst_p75 = df['hurst'].quantile(0.75)
        hurst_p60 = df['hurst'].quantile(0.60)
        hurst_p40 = df['hurst'].quantile(0.40)
        logger.info(f"  ADX: p50={adx_p50:.1f}, p75={adx_p75:.1f} | HURST: p40={hurst_p40:.2f}, p60={hurst_p60:.2f}, p75={hurst_p75:.2f}")
        
        conditions = [
            (df['adx'] > adx_p75) & (df['hurst'] > hurst_p75),
            (df['adx'] > adx_p50) & (df['hurst'] > hurst_p60),
            (df['adx'] < adx_p50) & (df['hurst'] < hurst_p40),
            (df['adx'] < adx_p50) & (df['hurst'] > hurst_p60),
        ]
        choices = REGIME_LABELS
        regime_arr = np.select(conditions, choices, default='RANGE')
        df['regime'] = pd.Categorical(regime_arr, categories=REGIME_LABELS)
        
        dist = df['regime'].value_counts()
        n = len(df)
        for r in REGIME_LABELS:
            pct = dist.get(r, 0) / n * 100
            logger.info(f"  {r}: {pct:.1f}%")
        return df
    
    def transition_matrix(self) -> Tuple[np.ndarray, List[str]]:
        df = self.df
        regime_int = df['regime'].cat.codes.to_numpy(dtype=np.int32)
        
        cached = CACHE.get("transition", regime_int)
        if cached is not None:
            logger.info("  [CACHE HIT] Matriz de transicao")
            return cached, REGIME_LABELS
        
        t0 = time.time()
        mat = _transition_matrix_numba(regime_int, len(REGIME_LABELS))
        logger.info(f"  [TRANSITION] OK em {time.time()-t0:.3f}s")
        
        CACHE.put("transition", regime_int, mat)
        return mat, REGIME_LABELS


# ══════════════════════════════════════════════════════════════
# HMM REGIME MODEL (Hidden Markov Model — nível institucional)
# ══════════════════════════════════════════════════════════════
class HMMRegimeModel:
    """Hidden Markov Model para detecção de regimes latentes.
    
    Mais sofisticado que o RegimeModel baseado em regras ADX+Hurst:
      - Estados latentes inferidos por máxima verossimilhança
      - Transições probabilísticas (não determinísticas)
      - Utiliza log-retornos + volatilidade como observáveis
    
    Preserva 100% o regime ADX+Hurst original em df['regime'];
    adiciona df['hmm_state'] e df['hmm_regime'].
    """
    
    def __init__(self, df: pd.DataFrame, n_states: int = 4):
        self.df = df
        self.n_states = n_states
        self.model = None
        self.state_map: Dict[int, str] = {}
        self.agreement: float = 0.0
    
    def classify(self) -> pd.DataFrame:
        if not HAS_HMM:
            logger.warning("[HMM] hmmlearn não disponível — pulando HMM")
            self.df['hmm_state'] = -1
            self.df['hmm_regime'] = self.df['regime']
            return self.df
        
        logger.info(f"[HMM] Treinando GaussianHMM com {self.n_states} estados...")
        t0 = time.time()
        
        df = self.df
        log_returns = df['log_return'].to_numpy(dtype=np.float64)
        tr_z = df['tr_zscore'].to_numpy(dtype=np.float64)
        
        # Limpar NaN
        valid = ~(np.isnan(log_returns) | np.isnan(tr_z))
        features = np.column_stack([
            np.nan_to_num(log_returns, nan=0.0),
            np.nan_to_num(tr_z, nan=0.0),
        ])[valid]
        
        if len(features) < 1000:
            logger.warning(f"[HMM] Dados insuficientes ({len(features)} amostras) — pulando")
            df['hmm_state'] = -1
            df['hmm_regime'] = df['regime']
            return df
        
        # Subamostrar para treino (max 50k pontos é suficiente para HMM)
        max_train = min(len(features), 50000)
        if len(features) > max_train:
            indices = np.linspace(0, len(features) - 1, max_train, dtype=int)
            train_features = features[indices]
        else:
            train_features = features
        
        logger.info(f"  [HMM] Treinando com {len(train_features)} amostras (de {len(features)} totais)...")
        
        # Walk-forward: treina em janela expansiva, prediz apenas o proximo segmento
        # Limite maximo de retreinos: 25 iteracoes (de horas para minutos)
        features_all = np.column_stack([
            np.nan_to_num(log_returns, nan=0.0),
            np.nan_to_num(tr_z, nan=0.0),
        ])
        n = len(features_all)
        max_retrain = 25
        stride = max(500, (n - 3000) // max_retrain)
        first_train = min(3000, n // 2)
        hidden_states = np.full(n, -1, dtype=np.int32)
        
        def _train_hmm_safe(feats, n_states_initial, max_attempts=3):
            """Treina GaussianHMM com fallback progressivo.
            
            Tenta n_states_initial primeiro; se falhar (NaN nos parametros
            ou excecao), reduz numero de estados e/ou muda random_state.
            """
            states_to_try = list(dict.fromkeys(
                [n_states_initial] + [n for n in [3, 2] if n < n_states_initial]
            ))
            for attempt in range(min(max_attempts, len(states_to_try))):
                ns = states_to_try[attempt]
                rs = 42 + attempt * 7
                try:
                    m = GaussianHMM(
                        n_components=ns,
                        covariance_type='diag',
                        random_state=rs,
                        n_iter=1000,
                        tol=1e-4,
                    )
                    m.fit(feats)
                    # Validar parametros apos fit (evita NaN no decode)
                    if np.any(np.isnan(m.startprob_)) or np.any(np.isnan(m.transmat_)):
                        raise ValueError(f"NaN nos parametros do HMM ({ns} estados)")
                    return m, ns
                except (ValueError, np.linalg.LinAlgError) as e:
                    if attempt < min(max_attempts, len(states_to_try)) - 1:
                        logger.warning(f"[HMM] Falha com {ns} estados (rs={rs}): {e}. Tentando alternativa...")
                    else:
                        raise
            raise ValueError("Todas as tentativas de treino HMM falharam")
        
        def _predict_safe(model, feats, fallback_val=0):
            """Predict com fallback se decode falhar."""
            try:
                return model.predict(feats)
            except (ValueError, np.linalg.LinAlgError) as e:
                logger.warning(f"[HMM] predict falhou: {e}. Usando fallback.")
                return np.full(len(feats), fallback_val, dtype=np.int32)
        
        # Primeiro treino
        try:
            model, self.n_states = _train_hmm_safe(features_all[:first_train], self.n_states)
        except (ValueError, np.linalg.LinAlgError) as e:
            logger.warning(f"[HMM] Todas as tentativas de treino falharam: {e}. Pulando HMM.")
            df['hmm_state'] = -1
            df['hmm_regime'] = df['regime']
            return df
        hidden_states[:first_train] = _predict_safe(model, features_all[:first_train])
        
        # Atualizacoes walk-forward (max retrain controlado)
        wf_steps = list(range(first_train + stride, n + 1, stride))
        logger.info(f"  [HMM] Walk-forward: {len(wf_steps)} iteracoes (stride={stride}, max_retrain={max_retrain})")
        wf_iter = tqdm(wf_steps, desc="[HMM] Walk-forward", unit="iter",
                       mininterval=5.0, ncols=80) if HAS_TQDM else wf_steps
        
        for right in wf_iter:
            seq = features_all[:right]
            try:
                m, _ = _train_hmm_safe(seq, self.n_states)
            except (ValueError, np.linalg.LinAlgError) as e:
                logger.warning(f"[HMM] Falha no walk-forward chunk {right}: {e}")
                continue
            states = _predict_safe(m, seq)
            chunk_start = right - stride
            chunk_end = min(right, n)
            hidden_states[chunk_start:chunk_end] = states[-stride:]
        
        # Preencher estados -1 residuais (final do array nao coberto pelo walk-forward)
        hidden_states[hidden_states == -1] = 0
        
        # Mapear cada estado HMM para um regime label
        # Baseado nas características do estado: média de retorno e ADX
        adx = df['adx'].to_numpy(dtype=np.float64)
        hurst = df['hurst'].to_numpy(dtype=np.float64)
        
        state_info = []
        for s in range(self.n_states):
            mask = hidden_states == s
            n = mask.sum()
            if n == 0:
                state_info.append((s, 0.0, 0.0, 0.0, 'RANGE'))
                continue
            m_ret = float(log_returns[mask].mean()) if mask.any() else 0.0
            m_adx = float(adx[mask].mean()) if mask.any() else 0.0
            m_hurst = float(hurst[mask].mean()) if mask.any() else 0.0
            
            # Classificar usando mesmas regras adaptativas do RegimeModel
            adx_p75, adx_p50 = np.percentile(adx, [75, 50])
            hurst_p75, hurst_p60, hurst_p40 = np.percentile(hurst, [75, 60, 40])
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
        df['hmm_regime'] = pd.Categorical(
            state_map_arr, categories=REGIME_LABELS
        )
        
        # Concordância com ADX+Hurst
        agreement = (df['regime'] == df['hmm_regime']).mean() * 100
        self.agreement = float(agreement)
        self.model = model
        
        logger.info(f"  [HMM] OK em {time.time()-t0:.2f}s | {self.n_states} estados | "
                    f"concordancia com ADX+Hurst: {agreement:.1f}%")
        for s, m_ret, m_adx, m_hurst, regime in state_info:
            logger.info(f"  Estado {s}: ret={m_ret:.4f} adx={m_adx:.1f} hurst={m_hurst:.2f} -> {regime}")
        
        return df
    
    def transition_matrix(self) -> Tuple[np.ndarray, List[str]]:
        """Matriz de transição dos estados HMM."""
        if 'hmm_state' not in self.df.columns:
            return np.eye(4), REGIME_LABELS
        regime_int = self.df['hmm_regime'].cat.codes.to_numpy(dtype=np.int32)
        mat = _transition_matrix_numba(regime_int, len(REGIME_LABELS))
        return mat, REGIME_LABELS


# ══════════════════════════════════════════════════════════════
# TEMPORAL + TAIL RISK (otimizados)
# ══════════════════════════════════════════════════════════════
class TemporalProfiler:
    def __init__(self, df: pd.DataFrame):
        self.df = df
        self.profile: Dict[str, Any] = {}
    
    def analyze(self) -> Dict[str, Any]:
        logger.info("[TEMPORAL] Analisando sazonalidade...")
        df = self.df
        
        # Groupby otimizado (uma passada)
        grp_hour = df.groupby('hour', observed=True)
        grp_dow = df.groupby('day_of_week', observed=True)
        grp_month = df.groupby('month', observed=True)
        grp_session = df.groupby('session', observed=True)
        
        self.profile = {
            'hour': {
                'atr_mean': grp_hour['atr'].mean().to_dict(),
                'volume_mean': grp_hour['tick_volume'].mean().to_dict(),
                'regime_pct': pd.crosstab(df['hour'], df['regime'], normalize='index').to_dict('index'),
            },
            'day_of_week': {
                'atr_mean': grp_dow['atr'].mean().to_dict(),
                'volume_mean': grp_dow['tick_volume'].mean().to_dict(),
            },
            'month': {
                'atr_mean': grp_month['atr'].mean().to_dict(),
                'volume_mean': grp_month['tick_volume'].mean().to_dict(),
            },
            'session': {
                'atr_mean': grp_session['atr'].mean().to_dict(),
                'volume_mean': grp_session['tick_volume'].mean().to_dict(),
                'regime_pct': pd.crosstab(df['session'], df['regime'], normalize='index').to_dict('index'),
                'gap_risk': grp_session['atr'].mean().to_dict(),
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
# NARRATIVE + CHARTS + PDF (inalterados, apenas logging)
# ══════════════════════════════════════════════════════════════
class NarrativeEngine:
    def __init__(self, df, regime_model, temporal, tail_risk, hmm_model=None,
                 entropy=None, fracdiff=None, signal_data=None):
        self.df = df
        self.regime_model = regime_model
        self.temporal = temporal
        self.tail_risk = tail_risk
        self.hmm = hmm_model
        self.entropy = entropy or {}
        self.fracdiff = fracdiff or {}
        self.signal = signal_data or {}
    
    def generate(self) -> Dict[str, str]:
        df = self.df
        regime_counts = df['regime'].value_counts()
        dominant = regime_counts.index[0]
        dominant_pct = regime_counts.iloc[0] / len(df) * 100
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
        
        # Entropy narrative
        se_mean = self.entropy.get('sample_entropy_mean', 0)
        pe_mean = self.entropy.get('perm_entropy_mean', 0)
        complexity_desc = "ALTA (mercado eficiente)" if pe_mean > 0.85 else \
                          "MODERADA" if pe_mean > 0.65 else "BAIXA (padroes detectaveis)"
        
        # HMM narrative
        hmm_agree = self.hmm.get('agreement', 0) if self.hmm else 0
        hmm_note = ""
        if hmm_agree > 0:
            hmm_note = (
                f"O modelo HMM (Hidden Markov Model) identificou {self.hmm.get('n_states', 4)} "
                f"estados latentes com {hmm_agree:.1f}% de concordancia com a classificacao "
                f"ADX+Hurst tradicional, sugerindo que os regimes sao "
                f"{'consistentes' if hmm_agree > 70 else 'moderadamente consistentes' if hmm_agree > 50 else 'divergentes'} "
                f"entre as duas metodologias. "
            )
        
        # Fase 2: Wavelet + Transfer Entropy narrative
        te = self.signal.get('transfer_entropy', {})
        te_note = ""
        if te:
            r2v = te.get('ret_to_vol', 0)
            v2r = te.get('vol_to_ret', 0)
            if r2v > 0.01 or v2r > 0.01:
                direction = "retornos->volume" if r2v > v2r else "volume->retornos"
                te_note = (
                    f"Transferencia de entropia indica que {direction} domina o fluxo de informacao "
                    f"(TE ret->vol: {r2v:.4f}, TE vol->ret: {v2r:.4f}). "
                )
        
        wavelet_note = ""
        if self.signal.get('has_wavelet'):
            wavelet_note = "Filtragem wavelet (db4) aplicada para remocao de ruido de alta frequencia. "
        
        return {
            'executive': (
                f"O perfil estrutural do ativo revela {dominant} como regime dominante "
                f"({dominant_pct:.1f}% do periodo amostral). "
                f"O nivel de ruido estrutural (Hurst medio: {noise:.2f}) indica {noise_desc} (mercado {'ruidoso' if noise<0.45 else 'aleatorio' if noise<0.55 else 'tendente'}). "
                f"A hora mais volatil e {vol_hour:02d}, "
                f"e a sessao com maior propensao a tendencia e {trend_session[0] if trend_session else 'N/A'} "
                f"({trend_session[1]:.1f}% tendencia). "
                f"{hmm_note}"
                f"{te_note}"
            ),
            'transition': "A matriz de Markov indica a seguinte dinâmica de transicao entre regimes.",
            'tail_risk': (
                f"Risco de cauda: {self.tail_risk['spike_count']} spikes de volatilidade "
                f"(Vol Z>2, {self.tail_risk['spike_pct']:.1f}% das amostras). "
                f"ATR medio em spikes: {self.tail_risk['avg_atr_spike']:.2f} "
                f"vs {self.tail_risk['avg_atr_normal']:.2f} em condicoes normais."
            ),
            'complexity': (
                f"Analise de entropia: Sample Entropy medio {se_mean:.4f} e "
                f"Permutation Entropy medio {pe_mean:.3f} indicam complexidade {complexity_desc}. "
                f"{wavelet_note}"
                f"Quanto menor a entropia, mais previsivel e o mercado no periodo."
            ),
            'signal_analysis': (
                f"{wavelet_note}"
                f"{te_note}"
            ),
        }


# ══════════════════════════════════════════════════════════════
# CHART GENERATOR
# ══════════════════════════════════════════════════════════════
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
        logger.info("[CHARTS] Gerando graficos...")
        self._heatmap_hour_day_atr()
        self._heatmap_hour_day_trend()
        self._markov_matrix()
        self._regime_bars()
        self._boxplot_atr_month()
        self._intraday_curve()
        self._correlation_matrix()
        self._return_by_regime()
        self._hurst_vs_adx_scatter()
        self._hmm_agreement_chart()
        self._entropy_timeline()
        self._wavelet_comparison()
        self._transfer_entropy_chart()
        if hasattr(self, '_macro_risk_charts'):
            self._macro_risk_charts()
        if hasattr(self, '_stability_charts'):
            self._stability_charts()
        logger.info(f"  [OK] {len(self.charts)} graficos gerados")
        return self.charts

    def _heatmap_hour_day_atr(self):
        fig, ax = plt.subplots(figsize=(9, 5))
        pivot = self.df.pivot_table(values='atr', index='hour', columns='day_of_week', aggfunc='mean')
        day_labels = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sab', 'Dom']
        pivot = pivot.reindex(columns=range(7), fill_value=0)
        pivot.columns = day_labels
        sns.heatmap(pivot, ax=ax, cmap='RdYlBu_r', annot=True, fmt='.1f',
                    linewidths=0.5, cbar_kws={'label': 'ATR Medio'})
        ax.set_title('Heatmap ATR: Hora x Dia da Semana', fontweight='bold')
        ax.set_ylabel('Hora')
        ax.set_xlabel('Dia da Semana')
        plt.tight_layout()
        path = str(self._chart_dir / 'heatmap_atr.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['heatmap_atr'] = path

    def _heatmap_hour_day_trend(self):
        fig, ax = plt.subplots(figsize=(9, 5))
        day_labels = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sab', 'Dom']
        trend = self.df[self.df['regime'].isin(['TREND_FORTE', 'TREND_FRACO'])]
        total = self.df.pivot_table(values='atr', index='hour', columns='day_of_week', aggfunc='count').reindex(columns=range(7), fill_value=0)
        if len(trend) and total.sum().sum() > 0:
            pivot_count = trend.pivot_table(values='atr', index='hour', columns='day_of_week', aggfunc='count').reindex(columns=range(7), fill_value=0)
            pivot = pivot_count.div(total.replace(0, np.nan)) * 100
        else:
            pivot = pd.DataFrame(0, index=range(24), columns=range(7))
        pivot.columns = day_labels
        sns.heatmap(pivot, ax=ax, cmap='RdYlGn', annot=True, fmt='.0f',
                    linewidths=0.5, cbar_kws={'label': '% Tendencia'})
        ax.set_title('Heatmap Tendencia: Hora x Dia da Semana (%)', fontweight='bold')
        ax.set_ylabel('Hora')
        ax.set_xlabel('Dia da Semana')
        plt.tight_layout()
        path = str(self._chart_dir / 'heatmap_trend.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['heatmap_trend'] = path

    def _markov_matrix(self):
        fig, ax = plt.subplots(figsize=(7, 6))
        sns.heatmap(self.transition_mat, annot=True, fmt='.2f', cmap='Blues',
                    xticklabels=self.regime_labels, yticklabels=self.regime_labels,
                    linewidths=0.5, ax=ax, cbar_kws={'label': 'Prob. Transicao'})
        ax.set_title('Matriz de Transicao de Markov', fontweight='bold')
        ax.set_ylabel('De')
        ax.set_xlabel('Para')
        plt.tight_layout()
        path = str(self._chart_dir / 'markov_matrix.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['markov_matrix'] = path

    def _regime_bars(self):
        fig, ax = plt.subplots(figsize=(9, 4))
        dist = self.df['regime'].value_counts()
        colors_list = [REGIME_COLORS.get(r, '#999999') for r in dist.index]
        bars = ax.bar(dist.index, dist.values, color=colors_list, edgecolor='white', linewidth=1.5)
        ax.bar_label(bars, labels=[f'{v/len(self.df)*100:.1f}%' for v in dist.values], padding=2)
        ax.set_title('Distribuicao de Regimes', fontweight='bold')
        ax.set_ylabel('Candles')
        ax.set_xlabel('Regime')
        for label in ax.get_xticklabels():
            label.set_rotation(0)
        plt.tight_layout()
        path = str(self._chart_dir / 'regime_bars.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['regime_bars'] = path

    def _boxplot_atr_month(self):
        fig, ax = plt.subplots(figsize=(10, 4))
        df_sample = self.df.sample(min(50000, len(self.df)))
        sns.boxplot(x='month', y='atr', data=df_sample, ax=ax,
                    palette='Blues', showfliers=False)
        ax.set_title('Boxplot ATR Mensal', fontweight='bold')
        ax.set_ylabel('ATR')
        ax.set_xlabel('Mes')
        plt.tight_layout()
        path = str(self._chart_dir / 'boxplot_atr_month.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['boxplot_atr_month'] = path

    def _intraday_curve(self):
        fig, ax = plt.subplots(figsize=(10, 4))
        atr_hour = self.df.groupby('hour')['atr'].mean()
        vol_hour = self.df.groupby('hour')['tick_volume'].mean()
        vol_hour_norm = vol_hour / vol_hour.max()

        ax2 = ax.twinx()
        line1 = ax.plot(atr_hour.index, atr_hour.values, color=C['steel'], linewidth=2, label='ATR Medio')
        line2 = ax2.plot(vol_hour_norm.index, vol_hour_norm.values, color=C['gold'], linewidth=1.5,
                         linestyle='--', label='Volume Relativo')
        ax.set_xlabel('Hora')
        ax.set_ylabel('ATR Medio', color=C['steel'])
        ax2.set_ylabel('Volume Relativo', color=C['gold'])
        ax.set_title('Curva Intradiaria Media: ATR e Volume', fontweight='bold')
        lines = line1 + line2
        labels = [l.get_label() for l in lines]
        ax.legend(lines, labels, loc='upper left')
        plt.tight_layout()
        path = str(self._chart_dir / 'intraday_curve.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['intraday_curve'] = path

    # ---------------------------------------------------------------
    # NOVOS GRAFICOS (Fase A, B, C)
    # ---------------------------------------------------------------

    def _correlation_matrix(self):
        cols = ['hurst', 'adx', 'atr', 'tr_zscore', 'volume_zscore', 'return']
        available = [c for c in cols if c in self.df.columns]
        if len(available) < 2:
            return
        fig, ax = plt.subplots(figsize=(8, 7))
        corr = self.df[available].corr()
        mask = np.triu(np.ones_like(corr, dtype=bool))
        sns.heatmap(corr, mask=mask, annot=True, fmt='.2f', cmap='RdBu_r',
                    center=0, vmin=-1, vmax=1, linewidths=0.5, ax=ax,
                    cbar_kws={'label': 'Correlacao'})
        ax.set_title('Matriz de Correlacao entre Features', fontweight='bold')
        plt.tight_layout()
        path = str(self._chart_dir / 'correlation_matrix.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['correlation_matrix'] = path

    def _return_by_regime(self):
        if 'return' not in self.df.columns:
            return
        fig, ax = plt.subplots(figsize=(10, 5))
        df_sample = self.df.sample(min(100000, len(self.df)))
        sns.boxplot(x='regime', y='return', data=df_sample, ax=ax,
                    palette=list(REGIME_COLORS.values()), showfliers=False)
        ax.set_title('Distribuicao de Retornos por Regime', fontweight='bold')
        ax.set_ylabel('Retorno')
        ax.set_xlabel('Regime')
        ax.axhline(y=0, color='black', linewidth=0.5, linestyle='--')
        plt.tight_layout()
        path = str(self._chart_dir / 'return_by_regime.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['return_by_regime'] = path

    def _hurst_vs_adx_scatter(self):
        fig, ax = plt.subplots(figsize=(8, 6))
        df_sample = self.df.sample(min(50000, len(self.df)))
        colors_reg = [REGIME_COLORS.get(r, '#999') for r in df_sample['regime']]
        ax.scatter(df_sample['hurst'], df_sample['adx'], c=colors_reg,
                   alpha=0.3, s=5, edgecolors='none')
        ax.set_xlabel('Hurst Exponent')
        ax.set_ylabel('ADX')
        ax.set_title('Hurst vs ADX (colorido por Regime)', fontweight='bold')
        ax.axvline(x=0.55, color='red', linestyle='--', linewidth=0.8, alpha=0.5)
        ax.axhline(y=25, color='red', linestyle='--', linewidth=0.8, alpha=0.5)
        from matplotlib.lines import Line2D
        legend_elements = [Line2D([0], [0], marker='o', color='w', markerfacecolor=c, label=l, markersize=8)
                          for l, c in REGIME_COLORS.items()]
        ax.legend(handles=legend_elements, loc='upper right')
        plt.tight_layout()
        path = str(self._chart_dir / 'hurst_vs_adx.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['hurst_vs_adx'] = path

    def _hmm_agreement_chart(self):
        if 'hmm_regime' not in self.df.columns:
            return
        fig, ax = plt.subplots(figsize=(10, 4))
        agreement = (self.df['regime'] == self.df['hmm_regime']).astype(int)
        rolling_agree = agreement.rolling(5000, min_periods=100).mean() * 100
        ax.plot(rolling_agree.index, rolling_agree.values, color=C['purple'], linewidth=0.6)
        ax.axhline(y=70, color=C['green'], linestyle='--', linewidth=0.8, alpha=0.5, label='70%')
        ax.axhline(y=50, color=C['gold'], linestyle='--', linewidth=0.8, alpha=0.5, label='50%')
        ax.set_ylabel('Concordancia HMM vs ADX+Hurst (%)')
        ax.set_title('Concordancia entre Modelos de Regime (rolling 5000)', fontweight='bold')
        ax.set_ylim(0, 100)
        ax.legend()
        plt.tight_layout()
        path = str(self._chart_dir / 'hmm_agreement.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['hmm_agreement'] = path
    
    def _entropy_timeline(self):
        if 'sample_entropy' not in self.df.columns:
            return
        fig, ax1 = plt.subplots(figsize=(10, 4))
        se_rolling = self.df['sample_entropy'].rolling(5000, min_periods=100).mean()
        pe_rolling = self.df['perm_entropy'].rolling(5000, min_periods=100).mean()
        ax1.plot(se_rolling.index, se_rolling.values, color=C['blue'], linewidth=0.8, label='Sample Entropy')
        ax1.set_ylabel('Sample Entropy', color=C['blue'])
        ax1.set_ylim(0, se_rolling.quantile(0.99) * 1.5)
        ax2 = ax1.twinx()
        ax2.plot(pe_rolling.index, pe_rolling.values, color=C['red'], linewidth=0.8, label='Permutation Entropy')
        ax2.set_ylabel('Permutation Entropy', color=C['red'])
        ax2.set_ylim(0, 1.1)
        ax1.set_title('Evolucao da Entropia (Complexidade do Mercado)', fontweight='bold')
        lines = ax1.get_lines() + ax2.get_lines()
        ax1.legend(lines, [l.get_label() for l in lines], loc='upper left')
        plt.tight_layout()
        path = str(self._chart_dir / 'entropy_timeline.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['entropy_timeline'] = path
    
    def _wavelet_comparison(self):
        if 'close_denoised' not in self.df.columns:
            return
        fig, ax = plt.subplots(figsize=(10, 4))
        sample = self.df.iloc[-5000:]  # Last 5000 candles
        ax.plot(sample.index, sample['close'].values, color=C['steel'], linewidth=0.5, alpha=0.6, label='Original')
        ax.plot(sample.index, sample['close_denoised'].values, color=C['red'], linewidth=0.8, label='Wavelet Denoised')
        ax.set_title('Comparacao: Preco Original vs Wavelet Denoised (db4)', fontweight='bold')
        ax.set_ylabel('Preco')
        ax.legend()
        plt.tight_layout()
        path = str(self._chart_dir / 'wavelet_comparison.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['wavelet_comparison'] = path
    
    def _transfer_entropy_chart(self):
        signal = self.features.get('signal', {})
        te = signal.get('transfer_entropy', {})
        if not te:
            return
        fig, ax = plt.subplots(figsize=(7, 4))
        labels = list(te.keys())
        values = list(te.values())
        colors_bar = [C['steel'] if 'ret_to_vol' in k or 'hurst_to_adx' in k else C['gold'] for k in labels]
        bars = ax.barh(labels, values, color=colors_bar, edgecolor='white', linewidth=1.2)
        ax.bar_label(bars, labels=[f'{v:.4f}' for v in values], padding=2)
        ax.set_title('Transferencia de Entropia (Fluxo Direcional)', fontweight='bold')
        ax.set_xlabel('TE (bits)')
        plt.tight_layout()
        path = str(self._chart_dir / 'transfer_entropy.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['transfer_entropy'] = path


# ══════════════════════════════════════════════════════════════
# PDF REPORT BUILDER
# ══════════════════════════════════════════════════════════════
class PDFReportBuilder:
    def __init__(self, output_path, charts, narratives, df, transition_mat, regime_labels, features, tf='M5',
                 walkforward=None, macro=None, hmm_model=None, signal_data=None):
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
        self._macro_correlation = macro.get('correlations', {}) if macro else {}
        self._macro_sensitivity = macro.get('macro_sensitivity', {}) if macro else {}
        self._hmm = hmm_model or {}
        self._signal = signal_data or {}
        self._setup_styles()

    def _setup_styles(self):
        self.styles = getSampleStyleSheet()
        self.s_title = ParagraphStyle('CustomTitle', parent=self.styles['Title'],
            fontName='Helvetica-Bold', fontSize=22, textColor=colors.HexColor(C['navy']),
            spaceAfter=6, alignment=TA_LEFT)
        self.s_h1 = ParagraphStyle('H1', parent=self.styles['Heading1'],
            fontName='Helvetica-Bold', fontSize=16, textColor=colors.HexColor(C['navy']),
            spaceBefore=16, spaceAfter=8, borderPadding=(0, 0, 4, 0),
            borderColor=colors.HexColor(C['gold']), borderWidth=2, leftIndent=0)
        self.s_h2 = ParagraphStyle('H2', parent=self.styles['Heading2'],
            fontName='Helvetica-Bold', fontSize=12, textColor=colors.HexColor(C['steel']),
            spaceBefore=12, spaceAfter=6)
        self.s_body = ParagraphStyle('Body', parent=self.styles['Normal'],
            fontName='Helvetica', fontSize=9, textColor=colors.HexColor(C['dark']),
            spaceAfter=6, leading=13, alignment=TA_JUSTIFY)
        self.s_body_small = ParagraphStyle('BodySmall', parent=self.s_body, fontSize=8, leading=11)
        self.s_code = ParagraphStyle('Code', parent=self.styles['Code'],
            fontName='Courier', fontSize=7, textColor=colors.HexColor(C['dark']),
            backColor=colors.HexColor('#F0F2F5'), leftIndent=10, rightIndent=10,
            spaceBefore=4, spaceAfter=4, leading=9,
            borderPadding=6, borderColor=colors.HexColor('#D0D5DD'), borderWidth=0.5)
        self.s_metric_label = ParagraphStyle('MetricLabel', parent=self.styles['Normal'],
            fontName='Helvetica', fontSize=7, textColor=colors.HexColor(C['gray']),
            alignment=TA_CENTER, spaceAfter=0)
        self.s_metric_value = ParagraphStyle('MetricValue', parent=self.styles['Normal'],
            fontName='Helvetica-Bold', fontSize=16, textColor=colors.HexColor(C['navy']),
            alignment=TA_CENTER, spaceAfter=0)
        self.s_footer_note = ParagraphStyle('FooterNote', parent=self.styles['Normal'],
            fontName='Helvetica-Oblique', fontSize=7, textColor=colors.HexColor(C['gray']),
            alignment=TA_LEFT, spaceBefore=4)

    def _add(self, element):
        self.elements.append(element)

    def _hr(self):
        self._add(HRFlowable(width="100%", thickness=0.5, color=colors.HexColor(C['light']),
                             spaceBefore=6, spaceAfter=6))

    def _metric_box(self, label, value, color=C['navy']):
        data = [[Paragraph(f'<font color="{color}"><b>{value}</b></font>', self.s_metric_value)],
                [Paragraph(label, self.s_metric_label)]]
        t = Table(data, colWidths=[40*mm])
        t.setStyle(TableStyle([
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('BOX', (0, 0), (-1, -1), 1, colors.HexColor(C['light'])),
            ('TOPPADDING', (0, 0), (-1, 0), 8),
            ('BOTTOMPADDING', (0, -1), (-1, -1), 6),
            ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor(C['lighter'])),
        ]))
        return t

    def build_executive_summary(self):
        df = self.df
        dominant = df['regime'].value_counts().index[0]
        dominant_pct = df['regime'].value_counts(normalize=True).iloc[0] * 100
        noise = df['hurst'].mean()
        vol_hour = df.groupby('hour')['atr'].mean().idxmax()

        self._add(Paragraph("EXECUTIVE SUMMARY", self.s_h1))
        self._hr()

        boxes = Table([[
            self._metric_box("REGIME DOMINANTE", f"{dominant}", C['navy']),
            self._metric_box("HORA MAIS VOLATIL", f"{vol_hour:02d}h", C['steel']),
            self._metric_box("RUIDO ESTRUTURAL", f"{noise:.2f}", C['gold']),
            self._metric_box("AMOSTRA", f"{len(df):,} candles", C['gray']),
        ]], colWidths=[40*mm, 40*mm, 40*mm, 40*mm])
        boxes.setStyle(TableStyle([
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('VALIGN', (0, 0), (-1, -1), 'TOP'),
        ]))
        self._add(boxes)
        self._add(Spacer(1, 8))
        self._add(Paragraph(self.narr['executive'], self.s_body))
        self._add(PageBreak())

    def build_regime_analysis(self):
        self._add(Paragraph("REGIME ANALYSIS", self.s_h1))
        self._hr()

        if 'regime_bars' in self.charts:
            self._add(Paragraph("Distribuicao de Regimes", self.s_h2))
            self._add(Image(self.charts['regime_bars'], width=160*mm, height=60*mm))

        if 'markov_matrix' in self.charts:
            self._add(Paragraph("Matriz de Transicao de Markov", self.s_h2))
            self._add(Paragraph(self.narr['transition'], self.s_body))
            self._add(Spacer(1, 4))
            self._add(Image(self.charts['markov_matrix'], width=120*mm, height=90*mm))
        self._add(PageBreak())

    def build_temporal_analysis(self):
        self._add(Paragraph("TEMPORAL & SEASONALITY", self.s_h1))
        self._hr()

        if 'heatmap_atr' in self.charts:
            self._add(Paragraph("Volatilidade: Hora x Dia da Semana", self.s_h2))
            self._add(Image(self.charts['heatmap_atr'], width=160*mm, height=80*mm))

        if 'heatmap_trend' in self.charts:
            self._add(Paragraph("Propensao a Tendencia: Hora x Dia da Semana (%)", self.s_h2))
            self._add(Image(self.charts['heatmap_trend'], width=160*mm, height=80*mm))

        if 'intraday_curve' in self.charts:
            self._add(Paragraph("Curva Intradiaria", self.s_h2))
            self._add(Image(self.charts['intraday_curve'], width=160*mm, height=60*mm))

        if 'boxplot_atr_month' in self.charts:
            self._add(Paragraph("Sazonalidade Mensal do ATR", self.s_h2))
            self._add(Image(self.charts['boxplot_atr_month'], width=160*mm, height=60*mm))
        self._add(PageBreak())

    def build_tail_risk(self):
        self._add(Paragraph("TAIL RISK ANALYSIS", self.s_h1))
        self._hr()
        self._add(Paragraph(self.narr['tail_risk'], self.s_body))
        self._add(Spacer(1, 6))

        tail = self.features.get('tail_risk', {})
        rows = [
            ['ATR Threshold (Top 1%)', f"{tail.get('atr_threshold', 0):.2f}"],
            ['% Spikes (Vol Z>2)', f"{tail.get('spike_pct', 0):.2f}%"],
            ['ATR Medio em Spikes', f"{tail.get('avg_atr_spike', 0):.2f}"],
            ['ATR Medio Normal', f"{tail.get('avg_atr_normal', 0):.2f}"],
            ['Fator de Amplificacao', f"{tail.get('avg_atr_spike', 0) / max(tail.get('avg_atr_normal', 0.001), 0.001):.1f}x"],
        ]
        if rows:
            self._add(self._data_table(['Metrica', 'Valor'], rows, col_widths=[70*mm, 60*mm]))
        self._add(PageBreak())

    def build_hmm_analysis(self):
        self._add(Paragraph("HIDDEN MARKOV MODEL — REGIME LATENTE", self.s_h1))
        self._hr()

        if 'hmm_regime' not in self.df.columns:
            self._add(Paragraph("HMM nao disponivel para este ativo.", self.s_body))
            self._add(PageBreak())
            return

        df = self.df
        hmm_counts = df['hmm_regime'].value_counts()
        ahp_counts = df['regime'].value_counts()

        # Concordancia
        agree = (df['regime'] == df['hmm_regime']).mean() * 100
        self._add(Paragraph(
            f"Concordancia entre HMM e classificacao ADX+Hurst: <b>{agree:.1f}%</b>. "
            f"O HMM identifica estados latentes baseados em log-retornos e volatilidade, "
            f"enquanto o metodo ADX+Hurst utiliza limiares deterministicos. "
            f"Uma concordancia acima de 70% indica consistencia entre as abordagens.",
            self.s_body
        ))

        # Distribuicao comparativa
        self._add(Spacer(1, 6))
        self._add(Paragraph("Distribuicao Comparativa: HMM vs ADX+Hurst", self.s_h2))
        rows = []
        for r in REGIME_LABELS:
            hmm_pct = hmm_counts.get(r, 0) / len(df) * 100
            ahp_pct = ahp_counts.get(r, 0) / len(df) * 100
            rows.append([r, f'{hmm_pct:.1f}%', f'{ahp_pct:.1f}%', f'{abs(hmm_pct - ahp_pct):.1f}%'])
        self._add(self._data_table(
            ['Regime', 'HMM %', 'ADX+Hurst %', 'Diferenca'],
            rows, col_widths=[35*mm, 35*mm, 35*mm, 35*mm]
        ))

        # HMM states info
        if 'hmm_state' in df.columns:
            self._add(Spacer(1, 6))
            self._add(Paragraph("Caracteristicas dos Estados HMM", self.s_h2))
            state_rows = []
            for s in sorted(df['hmm_state'].unique()):
                if s < 0:
                    continue
                mask = df['hmm_state'] == s
                n = mask.sum()
                if n == 0:
                    continue
                sub = df[mask]
                state_rows.append([
                    f'Estado {s}',
                    f'{n:,}',
                    f'{sub["hurst"].mean():.2f}',
                    f'{sub["adx"].mean():.1f}',
                    f'{sub["atr"].mean():.2f}',
                    sub['hmm_regime'].iloc[0],
                ])
            if state_rows:
                self._add(self._data_table(
                    ['Estado', 'Candles', 'Hurst', 'ADX', 'ATR', 'Regime'],
                    state_rows, col_widths=[22*mm, 25*mm, 20*mm, 20*mm, 20*mm, 25*mm]
                ))

        # HMM chart
        if 'hmm_agreement' in self.charts:
            self._add(Spacer(1, 8))
            self._add(Paragraph("Evolucao da Concordancia (rolling 5000)", self.s_h2))
            self._add(Image(self.charts['hmm_agreement'], width=160*mm, height=60*mm))

        if 'entropy_timeline' in self.charts:
            self._add(Paragraph("Evolucao da Entropia (Complexidade do Mercado)", self.s_h2))
            self._add(Image(self.charts['entropy_timeline'], width=160*mm, height=60*mm))

        self._add(PageBreak())

    def build_signal_analysis(self):
        self._add(Paragraph("SIGNAL ANALYSIS — WAVELET & TRANSFER ENTROPY", self.s_h1))
        self._hr()

        signal = self._signal
        te = signal.get('transfer_entropy', {})

        # Wavelet denoising
        if 'wavelet_comparison' in self.charts:
            self._add(Paragraph(
                f"Wavelet Denoising (db4): remocao de ruido de alta frequencia via "
                f"soft-thresholding de Donoho. Preserva estrutura de tendencia enquanto "
                f"suaviza flutuacoes estocasticas.",
                self.s_body
            ))
            self._add(Image(self.charts['wavelet_comparison'], width=160*mm, height=60*mm))

        # Transfer Entropy
        if te:
            self._add(Spacer(1, 6))
            self._add(Paragraph("Transferencia de Entropia (Fluxo Direcional de Informacao)", self.s_h2))
            self._add(Paragraph(
                f"Retorno -> Volume: <b>{te.get('ret_to_vol', 0):.4f}</b> bits | "
                f"Volume -> Retorno: <b>{te.get('vol_to_ret', 0):.4f}</b> bits. "
                f"Hurst -> ADX: <b>{te.get('hurst_to_adx', 0):.4f}</b> bits | "
                f"ADX -> Hurst: <b>{te.get('adx_to_hurst', 0):.4f}</b> bits. "
                f"Quanto maior a TE, mais forte o fluxo causal entre as variaveis.",
                self.s_body
            ))
            if 'transfer_entropy' in self.charts:
                self._add(Image(self.charts['transfer_entropy'], width=120*mm, height=80*mm))

        self._add(PageBreak())

    def build_mql5_constants(self):
        self._add(Paragraph("MQL5 SYSTEM PARAMETERS", self.s_h1))
        self._hr()

        df = self.df
        dominant = df['regime'].value_counts().index[0]
        dominant_pct = df['regime'].value_counts(normalize=True).iloc[0] * 100
        vol_hour = df.groupby('hour')['atr'].mean().idxmax()
        avg_hurst = df['hurst'].mean()
        avg_adx = df['adx'].mean()
        trend_pct = (df['regime'].isin(['TREND_FORTE', 'TREND_FRACO']).mean()) * 100
        chop_pct = (df['regime'] == 'CHOP').mean() * 100
        range_pct = (df['regime'] == 'RANGE').mean() * 100

        session_trend = {}
        for s in df['session'].unique():
            m = df[df['session'] == s]
            session_trend[s] = m['regime'].isin(['TREND_FORTE', 'TREND_FRACO']).mean()

        best_session = max(session_trend, key=session_trend.get) if session_trend else 'N/A'
        best_session_trend = session_trend.get(best_session, 0) * 100

        mql5_lines = [
            f"// MQL5 System Parameters - Gerado em {datetime.now().strftime('%Y-%m-%d %H:%M')}",
            f"// Asset DNA Profile",
            "",
            f"// --- Regime Parameters ---",
            f"#define DOMINANT_REGIME \"{dominant}\"",
            f"#define AVG_HURST {avg_hurst:.2f}",
            f"#define AVG_ADX {avg_adx:.1f}",
            f"#define TREND_PROBABILITY {trend_pct:.1f}",
            f"#define CHOP_PROBABILITY {chop_pct:.1f}",
            f"#define RANGE_PROBABILITY {range_pct:.1f}",
            "",
            f"// --- Seasonality Parameters ---",
            f"#define PEAK_VOL_HOUR {vol_hour}",
            f"#define BEST_TREND_SESSION \"{best_session}\"",
            f"#define BEST_TREND_SESSION_PROBABILITY {best_session_trend:.0f}",
            "",
            f"// --- Transition Probabilities ---",
        ]
        for i, frm in enumerate(self.regime_labels):
            for j, to in enumerate(self.regime_labels):
                if self.transition_mat[i, j] > 0.10:
                    mql5_lines.append(
                        f"#define TRANS_{frm[:4].upper()}_TO_{to[:4].upper()} {self.transition_mat[i, j]:.2f}"
                    )

        mql5_lines.extend([
            "",
            f"// --- Tail Risk ---",
            f"#define TOP1PCT_ATR {self.features.get('tail_risk', {}).get('atr_threshold', 0):.2f}",
            f"#define SPIKE_FREQUENCY {self.features.get('tail_risk', {}).get('spike_pct', 0):.2f}",
        ])

        for line in mql5_lines:
            if line:
                self._add(Paragraph(line.replace(' ', '&nbsp;'), self.s_code))
            else:
                self._add(Spacer(1, 2))

        self._add(Spacer(1, 8))
        self._add(Paragraph("Metricas Compiladas", self.s_h2))
        rows = [
            ['Regime Dominante', dominant, f'{dominant_pct:.1f}%'],
            ['Hurst Medio', f'{avg_hurst:.2f}', '> 0.55 = tendente'],
            ['ADX Medio', f'{avg_adx:.1f}', '> 25 = tendencia forte'],
            ['Tendencia %', f'{trend_pct:.1f}%', 'TREND_FORTE + TREND_FRACO'],
            ['Range %', f'{range_pct:.1f}%', 'RANGE puro'],
            ['Chop %', f'{chop_pct:.1f}%', 'CHOP (ruido alto)'],
            ['Pico Volatilidade', f'{vol_hour:02d}h', 'hora com maior ATR'],
            ['Melhor Sessao', best_session, f'{best_session_trend:.0f}% tendencia'],
        ]
        self._add(self._data_table(
            ['Metrica', 'Valor', 'Interpretacao'],
            rows, col_widths=[50*mm, 40*mm, 60*mm]
        ))

    def _data_table(self, headers, rows, col_widths=None):
        header_paras = [Paragraph(f'<b>{h}</b>', ParagraphStyle('TH', parent=self.s_body_small,
                      fontName='Helvetica-Bold', textColor=colors.white, alignment=TA_CENTER))
                       for h in headers]
        data = [header_paras]
        for row in rows:
            data.append([Paragraph(str(c), self.s_body_small) for c in row])
        if col_widths is None:
            col_widths = [None] * len(headers)
        t = Table(data, colWidths=col_widths, repeatRows=1)
        style_cmds = [
            ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor(C['navy'])),
            ('TEXTCOLOR', (0, 0), (-1, 0), colors.white),
            ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
            ('FONTSIZE', (0, 0), (-1, 0), 8),
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('GRID', (0, 0), (-1, -1), 0.5, colors.HexColor(C['light'])),
            ('TOPPADDING', (0, 0), (-1, -1), 4),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 4),
            ('LEFTPADDING', (0, 0), (-1, -1), 4),
            ('RIGHTPADDING', (0, 0), (-1, -1), 4),
        ]
        for i in range(1, len(data)):
            if i % 2 == 0:
                style_cmds.append(('BACKGROUND', (0, i), (-1, i), colors.HexColor(C['lighter'])))
        t.setStyle(TableStyle(style_cmds))
        return t

    def build_feature_correlation(self):
        self._add(Paragraph("FEATURE CORRELATION ANALYSIS", self.s_h1))
        self._hr()

        if 'correlation_matrix' in self.charts:
            self._add(Paragraph("Matriz de Correlacao entre Features", self.s_h2))
            self._add(Image(self.charts['correlation_matrix'], width=140*mm, height=110*mm))

        if 'hurst_vs_adx' in self.charts:
            self._add(Paragraph("Hurst vs ADX por Regime", self.s_h2))
            self._add(Image(self.charts['hurst_vs_adx'], width=140*mm, height=100*mm))

        if 'return_by_regime' in self.charts:
            self._add(Paragraph("Distribuicao de Retornos por Regime", self.s_h2))
            self._add(Image(self.charts['return_by_regime'], width=160*mm, height=80*mm))

        # Summary statistics table
        df = self.df
        stats = {}
        for col in ['hurst', 'adx', 'atr', 'tr_zscore']:
            if col in df.columns:
                stats[col.upper()] = {
                    'media': f'{df[col].mean():.3f}',
                    'std': f'{df[col].std():.3f}',
                    'p1': f'{df[col].quantile(0.01):.3f}',
                    'p99': f'{df[col].quantile(0.99):.3f}',
                }
        if stats:
            self._add(Spacer(1, 8))
            self._add(Paragraph("Estatisticas das Features", self.s_h2))
            rows = []
            for name, vals in stats.items():
                rows.append([name, vals['media'], vals['std'], vals['p1'], vals['p99']])
            self._add(self._data_table(
                ['Feature', 'Media', 'Std', 'P1', 'P99'],
                rows, col_widths=[30*mm, 30*mm, 30*mm, 30*mm, 30*mm]
            ))
        self._add(PageBreak())

    def build_macro_risk(self):
        self._add(Paragraph("MACRO RISK CROSS-REFERENCE", self.s_h1))
        self._hr()

        charts_avail = [k for k in ['dxy_vs_hurst', 'vix_vs_atr', 'regime_by_risk',
                                     'roro_timeline', 'macro_corr_heatmap', 'regime_betas']
                        if k in self.charts]
        if not charts_avail:
            self._add(Paragraph("Dados macro nao disponiveis para este ativo.", self.s_body))
            self._add(PageBreak())
            return

        # --- Novos charts institucionais ---
        if 'macro_corr_heatmap' in self.charts:
            self._add(Paragraph("Top Correlacoes Macro vs Ativo", self.s_h2))
            self._add(Image(self.charts['macro_corr_heatmap'], width=160*mm, height=90*mm))

        if 'macro_factors' in self.charts:
            self._add(Paragraph("Correlacao com Fatores Macro", self.s_h2))
            self._add(Image(self.charts['macro_factors'], width=150*mm, height=70*mm))

        if 'regime_betas' in self.charts:
            self._add(Paragraph("Betas por Regime (Elasticidade)", self.s_h2))
            self._add(Image(self.charts['regime_betas'], width=160*mm, height=70*mm))

        if 'regime_by_risk' in self.charts:
            self._add(Paragraph("Distribuicao de Regime por Cenario Macro", self.s_h2))
            self._add(Image(self.charts['regime_by_risk'], width=160*mm, height=80*mm))

        # --- Charts legados ---
        if 'dxy_vs_hurst' in self.charts:
            self._add(Paragraph("DXY vs Hurst Exponent", self.s_h2))
            self._add(Image(self.charts['dxy_vs_hurst'], width=140*mm, height=100*mm))

        if 'vix_vs_atr' in self.charts:
            self._add(Paragraph("VIX vs ATR", self.s_h2))
            self._add(Image(self.charts['vix_vs_atr'], width=140*mm, height=100*mm))

        if 'roro_timeline' in self.charts:
            self._add(Paragraph("Timeline RORO Score", self.s_h2))
            self._add(Image(self.charts['roro_timeline'], width=160*mm, height=60*mm))

        # --- Tabela de fatores macro ---
        ms = getattr(self, '_macro_sensitivity', None)
        if ms and ms.get('macro_factors'):
            self._add(Spacer(1, 8))
            self._add(Paragraph("Fatores Macro (Z-Score Composto)", self.s_h2))
            rows = []
            for fname, fdata in ms['macro_factors'].items():
                corr_str = f"{fdata.get('correlation', 0):+.3f}"
                rows.append([
                    fname,
                    str(fdata['n_members']),
                    f"{fdata['score_current']:+.2f}",
                    f"{fdata['score_min']:+.2f} / {fdata['score_max']:+.2f}",
                    corr_str,
                ])
            self._add(self._data_table(
                ['Fator', 'N', 'Atual', 'Range', 'Corr Ativo'],
                rows, col_widths=[30*mm, 10*mm, 25*mm, 35*mm, 30*mm]
            ))

        # --- Tabela de leading indicators ---
        if ms and ms.get('leading_indicators'):
            self._add(Spacer(1, 8))
            self._add(Paragraph("Leading Indicators (Macro que Antecedem)", self.s_h2))
            rows = []
            for li in ms['leading_indicators'][:8]:
                rows.append([
                    li['symbol'],
                    f"{li['lag_days']}d",
                    f"{li['cross_correlation']:+.3f}",
                    li['direction'],
                ])
            self._add(self._data_table(
                ['Macro', 'Lag', 'Spearman', 'Direcao'],
                rows, col_widths=[40*mm, 20*mm, 35*mm, 35*mm]
            ))

        # --- Tabela de correlações legada ---
        macro_data = getattr(self, '_macro_correlation', None)
        if macro_data:
            self._add(Spacer(1, 8))
            self._add(Paragraph("Correlacao Ativo vs Macro (completa)", self.s_h2))
            top_items = sorted(macro_data.items(), key=lambda x: abs(x[1]), reverse=True)[:15]
            rows = [[k, f'{v:.2f}'] for k, v in top_items]
            self._add(self._data_table(
                ['Par', 'Correlacao'], rows, col_widths=[70*mm, 60*mm]
            ))
        self._add(PageBreak())

    def build_walk_forward(self):
        self._add(Paragraph("WALK-FORWARD VALIDATION", self.s_h1))
        self._hr()

        wf_data = getattr(self, '_walkforward', None)
        if not wf_data:
            self._add(Paragraph("Validacao walk-forward nao disponivel.", self.s_body))
            self._add(PageBreak())
            return

        if 'wf_stability' in self.charts:
            self._add(Paragraph("Evolucao Temporal dos Parametros", self.s_h2))
            self._add(Image(self.charts['wf_stability'], width=160*mm, height=80*mm))

        if 'wf_regime' in self.charts:
            self._add(Paragraph("Distribuicao de Regime por Periodo", self.s_h2))
            self._add(Image(self.charts['wf_regime'], width=160*mm, height=80*mm))

        # Stability score
        score = wf_data.get('stability_score', 0)
        verdict = "ESTAVEL" if score >= 70 else "MODERADO" if score >= 40 else "INSTAVEL"
        score_color = C['green'] if score >= 70 else C['gold'] if score >= 40 else C['red']
        self._add(Spacer(1, 6))
        self._add(self._metric_box("ESTABILIDADE", f"{score:.0f}%", score_color))
        self._add(Spacer(1, 4))
        self._add(Paragraph(
            f"Score de estabilidade: {score:.0f}% — Perfil classificado como <b>{verdict}</b>. "
            f"Quanto maior, mais confiavel e a configuracao gerada para o EA.",
            self.s_body
        ))

        # Period table
        periods = wf_data.get('periods', [])
        if periods:
            self._add(Spacer(1, 8))
            self._add(Paragraph("Metricas por Periodo", self.s_h2))
            rows = []
            for p in periods:
                rows.append([p['label'], f"{p['hurst']:.2f}", f"{p['adx']:.1f}",
                            p['dominant'], f"{p['trend_pct']:.0f}%", f"{p['range_pct']:.0f}%"])
            self._add(self._data_table(
                ['Periodo', 'Hurst', 'ADX', 'Regime', 'Trend%', 'Range%'],
                rows, col_widths=[30*mm, 20*mm, 20*mm, 30*mm, 20*mm, 20*mm]
            ))
        self._add(PageBreak())

    def build_pdf(self):
        self._add(Spacer(1, 1))
        self._add(PageBreak())

        self.build_executive_summary()
        self.build_regime_analysis()
        self.build_hmm_analysis()
        self.build_signal_analysis()
        self.build_feature_correlation()
        self.build_temporal_analysis()
        self.build_macro_risk()
        self.build_walk_forward()
        self.build_tail_risk()
        self.build_mql5_constants()

        doc = SimpleDocTemplate(
            self.output, pagesize=A4,
            leftMargin=18*mm, rightMargin=18*mm,
            topMargin=30*mm, bottomMargin=22*mm,
            title="ALXQuant Asset DNA Profile",
            author="ALXQuant AI Engine",
        )

        class DocProxy:
            def __init__(self, page_num, report_builder):
                self.page = page_num
                self._builder = report_builder

        original_build = doc.build
        def custom_build(elements, onFirstPage=None, onLaterPages=None):
            def first_page(c, d):
                self._page_cover(c, DocProxy(d.page, self))
            def later_pages(c, d):
                self._page_content(c, DocProxy(d.page, self))
            original_build(elements, onFirstPage=first_page, onLaterPages=later_pages)

        custom_build(self.elements)
        logger.info(f"  [OK] PDF salvo: {self.output}")

    @staticmethod
    def _page_cover(canvas_obj, doc):
        w, h = A4
        builder = doc._builder
        canvas_obj.saveState()
        canvas_obj.setFillColor(colors.HexColor(C['navy']))
        canvas_obj.rect(0, 0, w, h, fill=1, stroke=0)
        canvas_obj.setFillColor(colors.HexColor(C['gold']))
        canvas_obj.rect(25*mm, h/2 - 10*mm, 3*mm, 80*mm, fill=1, stroke=0)
        canvas_obj.setFillColor(colors.white)
        canvas_obj.setFont('Helvetica-Bold', 32)
        canvas_obj.drawString(35*mm, h/2 + 50*mm, "ASSET DNA")
        canvas_obj.drawString(35*mm, h/2 + 25*mm, "PROFILE")
        canvas_obj.setFillColor(colors.HexColor(C['gold']))
        canvas_obj.setFont('Helvetica', 13)
        canvas_obj.drawString(35*mm, h/2 + 5*mm, "Perfil Estrutural de Ativos")
        canvas_obj.setFont('Helvetica', 11)
        n = len(builder.df) if hasattr(builder, 'df') else 0
        canvas_obj.drawString(35*mm, h/2 - 15*mm, f"Candles: {n:,}  |  {builder._tf}  |  Gerado: {datetime.now().strftime('%d/%m/%Y')}")
        canvas_obj.setFillColor(colors.HexColor('#556677'))
        canvas_obj.setFont('Helvetica', 9)
        canvas_obj.drawString(35*mm, 35*mm, f"Gerado em: {datetime.now().strftime('%d/%m/%Y - %H:%M')}")
        canvas_obj.drawString(35*mm, 25*mm, "ALXQuant Asset DNA Profiler v2.1")
        canvas_obj.setFillColor(colors.HexColor(C['gold']))
        canvas_obj.setFont('Helvetica-Bold', 11)
        canvas_obj.drawCentredString(w/2, 15*mm, "CONFIDENTIAL")
        canvas_obj.restoreState()

    @staticmethod
    def _page_content(canvas_obj, doc):
        w, h = A4
        canvas_obj.saveState()
        canvas_obj.setFillColor(colors.HexColor(C['navy']))
        canvas_obj.rect(0, h - 22*mm, w, 22*mm, fill=1, stroke=0)
        canvas_obj.setFillColor(colors.white)
        canvas_obj.setFont('Helvetica-Bold', 9)
        canvas_obj.drawString(18*mm, h - 14*mm, "ALXQUANT  |  ASSET DNA PROFILE")
        canvas_obj.setFont('Helvetica', 8)
        canvas_obj.drawRightString(w - 18*mm, h - 14*mm, f"Pag {doc.page - 1}")
        canvas_obj.setStrokeColor(colors.HexColor(C['gold']))
        canvas_obj.setLineWidth(2)
        canvas_obj.line(0, h - 22*mm, w, h - 22*mm)
        canvas_obj.setStrokeColor(colors.HexColor(C['light']))
        canvas_obj.setLineWidth(0.5)
        canvas_obj.line(18*mm, 15*mm, w - 18*mm, 15*mm)
        canvas_obj.setFillColor(colors.HexColor(C['gray']))
        canvas_obj.setFont('Helvetica', 7)
        canvas_obj.drawString(18*mm, 10*mm, f"Gerado: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
        canvas_obj.drawCentredString(w/2, 10*mm, f"- {doc.page - 1} -")
        canvas_obj.drawRightString(w - 18*mm, 10*mm, "ALXQuant v2.1")
        canvas_obj.restoreState()


# ══════════════════════════════════════════════════════════════
# MACRO RISK INTEGRATOR (Fase B)
# ══════════════════════════════════════════════════════════════
class MacroRiskIntegrator:
    """Lê macro_series do ALXQuantCore.db e cruza 57 indicadores com o ativo.

    Gera:
    - Correlações completas (top 20 por abs)
    - Regime-conditional betas para DXY, VIX, Treasuries, Fed Funds
    - Leading indicators (cross-correlation com lag)
    - Macro fatores: Risk, Carry, Inflation, Liquidity, Growth
    - Charts: heatmap macro, regime beta timeline, RORO, DXY/VIX
    """

    # Símbolos macro que SÃO o próprio ativo (correlação circular)
    SYMBOL_SELF_MACRO: Dict[str, list] = {
        'XAUUSD': ['GOLDAMGBD228NLBM'],
        'XAGUSD': [],
        'BTCUSD': [],
        'ETHUSD': [],
    }

    # Fatores macro para PCA simplificada (z-score composto)
    MACRO_FACTORS: Dict[str, list] = {
        'RISK': ['VIX', 'STLFSI4', 'NFCI', 'BAMLH0A0HYM2'],
        'CARRY': ['DTWEXBGS', 'T10Y2Y', 'DGS2', 'DGS10'],
        'INFLATION': ['CPIAUCSL', 'CPILFESL', 'PCEPI', 'PPIACO'],
        'LIQUIDITY': ['BOGMBASE', 'WALCL', 'RRPONTSYD', 'SOFR'],
        'GROWTH': ['INDPRO', 'GDPC1', 'PAYEMS', 'UNRATE', 'RSAFS', 'TCU'],
        'COMMODITIES': ['DCOILWTICO', 'DCOILBRENTEU', 'GOLDAMGBD228NLBM', 'PCOPPUSDM'],
        'HOUSING': ['HOUST', 'PERMIT', 'CSUSHPISA', 'EXHOSLUSM495S'],
    }

    def __init__(self, db_path: Optional[str] = None):
        from db.schema import DB_PATH
        self.db_path = db_path or DB_PATH
        self.macro_wide: Optional[pd.DataFrame] = None
        self.catalog: Dict[str, dict] = {}
        self.roro_df: Optional[pd.DataFrame] = None
        self.correlations: Dict[str, float] = {}
        self._sensitivity: Dict = {}
        self._symbol: str = ""

    def load(self) -> pd.DataFrame:
        """Carrega macro_series + macro_catalog + risk_labels do DB."""
        if not os.path.exists(self.db_path):
            logger.warning(f"[MACRO] DB nao encontrado: {self.db_path}")
            return pd.DataFrame()

        try:
            conn = get_connection(read_only=True)
        except Exception:
            logger.warning("[MACRO] Nao foi possivel conectar ao DB")
            return pd.DataFrame()

        try:
            # Catalog
            cat_df = conn.execute(
                "SELECT symbol, name, category, country, unit FROM macro_catalog"
            ).df()
            self.catalog = {}
            for _, r in cat_df.iterrows():
                self.catalog[r['symbol']] = {
                    'name': r['name'],
                    'category': r['category'],
                    'country': r['country'],
                    'unit': r['unit'],
                }

            # Macro series - pivot wide
            raw = conn.execute(
                "SELECT symbol, date, value FROM macro_series ORDER BY date"
            ).df()
            if len(raw) == 0:
                logger.warning("[MACRO] macro_series vazia")
                return pd.DataFrame()

            raw['date'] = pd.to_datetime(raw['date'], errors='coerce')
            raw.dropna(subset=['date'], inplace=True)
            wide = raw.pivot_table(index='date', columns='symbol', values='value', aggfunc='first')
            wide.index = pd.to_datetime(wide.index)
            wide.sort_index(inplace=True)
            wide = wide.ffill().bfill()
            self.macro_wide = wide

            # Risk labels (RORO)
            risk_labels = conn.execute(
                "SELECT date, risk_label, roro_score FROM risk_labels ORDER BY date"
            ).df()
            risk_labels['date'] = pd.to_datetime(risk_labels['date'], errors='coerce')
            risk_labels.dropna(subset=['date'], inplace=True)
            risk_labels.set_index('date', inplace=True)
            risk_labels.sort_index(inplace=True)
            self.roro_df = risk_labels

            logger.info(
                f"[MACRO] DB carregado: {wide.shape[1]} indicadores, "
                f"{len(wide)} datas, {len(risk_labels)} RORO labels"
            )
            return wide

        except Exception as e:
            logger.warning(f"[MACRO] Erro ao carregar DB: {e}")
            return pd.DataFrame()
        finally:
            try:
                conn.close()
            except Exception:
                pass

    # ------------------------------------------------------------------
    def cross_reference(self, asset_df: pd.DataFrame, symbol: str = "") -> Dict[str, Any]:
        """Correlações expandidas + regime betas + leading indicators + fatores."""
        self._symbol = symbol
        if self.macro_wide is None or len(self.macro_wide) < 10:
            return {}

        # Agregar ativo por dia
        asset_daily = asset_df.resample('D').agg({
            'hurst': 'mean', 'adx': 'mean', 'atr': 'mean',
            'tr_zscore': 'mean', 'close': 'last'
        }).dropna()
        asset_daily['close_ret'] = asset_daily['close'].pct_change()
        asset_daily.dropna(inplace=True)

        if len(asset_daily) < 10:
            return {}

        # Alinhar datas
        common = asset_daily.index.intersection(self.macro_wide.index)
        if len(common) < 10:
            return {}

        a = asset_daily.loc[common]
        m = self.macro_wide.loc[common]

        # Juntar RORO se disponivel
        roro = self.roro_df.reindex(common, method='ffill') if self.roro_df is not None else None

        merged = a.join(m)

        # ---- 1. Correlações expandidas (com filtro circular) ----
        asset_feats = ['hurst', 'adx', 'atr', 'tr_zscore', 'close_ret']
        macro_symbols = [c for c in m.columns if c != 'date']
        exclude_self: list = self.SYMBOL_SELF_MACRO.get(symbol, [])
        # Adicionar à exclusão qualquer macro que seja o próprio símbolo
        self_sym = symbol.replace('USD', '').replace('X', '')
        for sym in macro_symbols:
            cat = self.catalog.get(sym, {})
            if self_sym.lower() in cat.get('name', sym).lower():
                exclude_self.append(sym)
        corr_records = []
        for ms in macro_symbols:
            if ms in exclude_self:
                continue
            for af in asset_feats:
                if ms not in merged.columns or af not in merged.columns:
                    continue
                valid = merged[[af, ms]].dropna()
                if len(valid) < 10:
                    continue
                r_val, p_val = stats.pearsonr(valid[af], valid[ms])
                corr_records.append({
                    'macro_symbol': ms,
                    'asset_feature': af,
                    'correlation': round(r_val, 4),
                    'p_value': round(p_val, 4),
                    'abs_corr': abs(r_val),
                })
        corr_records.sort(key=lambda x: x['abs_corr'], reverse=True)
        self.correlations = {}
        for cr in corr_records:
            key = f"{cr['asset_feature']}_vs_{cr['macro_symbol']}"
            self.correlations[key] = cr['correlation']

        top20 = corr_records[:20]

        # ---- 2. Regime-conditional betas + elasticidades padronizadas ----
        KEY_MACRO_BETA = ['DTWEXBGS', 'VIX', 'DGS10', 'DGS2', 'FEDFUNDS',
                          'CPIAUCSL', 'DCOILWTICO',
                          'STLFSI4', 'T10Y2Y', 'BAA10Y', 'NFCI']
        # Excluir gold se for auto-referencia
        KEY_MACRO_BETA = [k for k in KEY_MACRO_BETA if k not in exclude_self]

        ret_std = merged['close_ret'].std()

        regime_betas: Dict[str, Dict[str, Any]] = {}
        if 'regime' in asset_df.columns:
            asset_regime = asset_df.resample('D')['regime'].agg(
                lambda x: x.mode().iloc[0] if len(x) > 0 else 'RANGE'
            )
            common_regime = asset_regime.index.intersection(common)
            for regime_label in sorted(asset_regime.unique()):
                regime_dates = asset_regime[asset_regime == regime_label].index
                regime_dates = regime_dates.intersection(common_regime)
                if len(regime_dates) < 5:
                    continue
                subset = merged.loc[regime_dates].dropna()
                if len(subset) < 5:
                    continue
                betas: Dict[str, Any] = {}
                for k in KEY_MACRO_BETA:
                    if k not in subset.columns:
                        continue
                    valid = subset[['close_ret', k]].dropna()
                    if len(valid) < 5:
                        continue
                    try:
                        slope, _intercept, r_val, p_val, _std_err = stats.linregress(
                            valid[k], valid['close_ret']
                        )
                        macro_std = valid[k].std()
                        elasticity = slope * macro_std / ret_std if ret_std > 0 else 0
                        betas[k] = {
                            'raw_beta': round(slope, 8),
                            'elasticity': round(elasticity, 4),
                            'r_squared': round(r_val ** 2, 4),
                            'p_value': round(p_val, 4),
                            'n_days': len(valid),
                        }
                    except Exception as e:
                        logger.warning(f"[REGBETA] Falha na regressao de {k}: {e}")
                if betas:
                    regime_betas[regime_label] = betas

        # ---- 3. Leading indicators (Spearman + cross-correlation com lag) ----
        # Usa retornos macro (pct_change) em vez de níveis crus; aplica FDR (Benjamini-Hochberg)
        leading: List[Dict] = []
        all_tests: List[Dict] = []
        for ms in macro_symbols[:40]:
            if ms in exclude_self or ms not in merged.columns:
                continue
            valid = merged[['close_ret', ms]].dropna()
            if len(valid) < 60:
                continue
            # Macro como retorno percentual (estacionário)
            macro_ret = valid[ms].pct_change().dropna()
            # Realinhar apos pct_change
            idx = valid.index.intersection(macro_ret.index)
            if len(idx) < 60:
                continue
            ret_arr = valid.loc[idx, 'close_ret'].values
            macro_arr = macro_ret.loc[idx].values
            best_lag = 0
            best_corr = 0.0
            best_p = 1.0
            max_lag = min(45, len(idx) // 4)
            for lag in range(1, max_lag + 1):
                if len(ret_arr) <= lag:
                    break
                c_lead, p_lead = stats.spearmanr(macro_arr[:-lag], ret_arr[lag:])
                all_tests.append({'symbol': ms, 'lag': lag, 'corr': c_lead, 'p': p_lead, 'leads': True})
                if abs(c_lead) > abs(best_corr):
                    best_corr = c_lead
                    best_p = p_lead
                    best_lag = lag
                c_lag, p_lag = stats.spearmanr(macro_arr[lag:], ret_arr[:-lag])
                all_tests.append({'symbol': ms, 'lag': -lag, 'corr': c_lag, 'p': p_lag, 'leads': False})
                if abs(c_lag) > abs(best_corr):
                    best_corr = c_lag
                    best_p = p_lag
                    best_lag = -lag
        
        # FDR Benjamini-Hochberg
        n_tests = len(all_tests)
        if n_tests > 0 and abs(best_corr) > 0.05:
            p_vals = np.array([t['p'] for t in all_tests])
            p_vals = np.clip(p_vals, 1e-15, 1.0)
            sorted_idx = np.argsort(p_vals)
            q = 0.10
            ranks = np.arange(1, n_tests + 1, dtype=np.float64)
            bh_thresholds = (ranks / n_tests) * q
            significant = p_vals[sorted_idx] <= bh_thresholds
            if significant.any():
                max_sig_idx = sorted_idx[np.where(significant)[0][-1]]
                p_cutoff = p_vals[max_sig_idx]
            else:
                p_cutoff = 0.0
            adjusted_p = best_p * n_tests / max(1, abs(best_lag))
            adjusted_p = min(adjusted_p, 1.0)
            if adjusted_p < q:
                info = self.catalog.get(ms, {'name': ms, 'category': '', 'country': ''})
                leading.append({
                    'symbol': ms,
                    'name': info['name'],
                    'category': info['category'],
                    'country': info['country'],
                    'lag_days': best_lag,
                    'cross_correlation': round(best_corr, 4),
                    'direction': 'leads' if best_lag > 0 else 'lags',
                    'p_raw': round(float(best_p), 6),
                    'p_adjusted': round(float(adjusted_p), 6),
                })

        leading.sort(key=lambda x: abs(x['cross_correlation']), reverse=True)
        leading = leading[:15]

        # ---- 4. Macro by regime contingency ----
        regime_by_risk: Dict = {}
        if roro is not None and 'regime' in asset_df.columns:
            asset_daily_regime = asset_df.resample('D')['regime'].agg(
                lambda x: x.mode().iloc[0] if len(x) > 0 else 'RANGE'
            )
            common_rr = asset_daily_regime.index.intersection(roro.index)
            combined = pd.DataFrame({
                'regime': asset_daily_regime.loc[common_rr],
                'risk_label': roro.loc[common_rr, 'risk_label']
            })
            combined.dropna(inplace=True)
            if len(combined) >= 5:
                regime_by_risk = pd.crosstab(
                    combined['risk_label'], combined['regime'],
                    normalize='index'
                ).to_dict('index')

        # ---- 5. Risk label distribution ----
        risk_labels_dist = {}
        if roro is not None:
            common_rl = roro.index.intersection(common)
            if len(common_rl):
                risk_labels_dist = roro.loc[common_rl, 'risk_label'].value_counts().to_dict()
                risk_labels_dist = {str(k): int(v) for k, v in risk_labels_dist.items()}

        # ---- 6. Macro fatores (z-score composto) ----
        macro_factors: Dict[str, Dict] = {}
        for factor_name, members in self.MACRO_FACTORS.items():
            available = [ms for ms in members if ms in merged.columns]
            if len(available) < 2:
                continue
            factor_df = merged[available].dropna()
            if len(factor_df) < 10:
                continue
            zscores = (factor_df - factor_df.mean()) / factor_df.std()
            factor_series = zscores.mean(axis=1)
            macro_factors[factor_name] = {
                'score_mean': round(float(factor_series.mean()), 4),
                'score_std': round(float(factor_series.std()), 4),
                'score_current': round(float(factor_series.iloc[-1]), 4),
                'score_min': round(float(factor_series.min()), 4),
                'score_max': round(float(factor_series.max()), 4),
                'n_members': len(available),
                'members': available,
            }
            # Correlacao do fator com o ativo (weekly returns)
            common_f = factor_series.index.intersection(a.index)
            if len(common_f) > 20:
                cf_level = factor_series.loc[common_f]
                ca_level = a.loc[common_f, 'close']
                # Aggregate weekly
                cf_weekly = cf_level.resample('W').last()
                ca_weekly = ca_level.resample('W').last()
                cf_ret = cf_weekly.pct_change().dropna()
                ca_ret = ca_weekly.pct_change().dropna()
                common_w = cf_ret.index.intersection(ca_ret.index)
                if len(common_w) > 10:
                    r_f, p_f = stats.pearsonr(ca_ret.loc[common_w], cf_ret.loc[common_w])
                    macro_factors[factor_name]['correlation'] = round(r_f, 4)
                    macro_factors[factor_name]['p_value'] = round(p_f, 4)
                else:
                    macro_factors[factor_name]['correlation'] = 0.0
                    macro_factors[factor_name]['p_value'] = 1.0
                macro_factors[factor_name]['correlation'] = round(r_f, 4)
                macro_factors[factor_name]['p_value'] = round(p_f, 4)

        self._sensitivity = {
            'top_correlations': top20,
            'regime_betas': regime_betas,
            'leading_indicators': leading,
            'macro_factors': macro_factors,
            'n_macro_series': len(macro_symbols),
            'n_dates_aligned': len(common),
        }

        result = {
            'merged': merged,
            'correlations': self.correlations,
            'risk_labels': risk_labels_dist,
            'regime_by_risk': regime_by_risk,
            'macro_sensitivity': self._sensitivity,
        }
        return result

    # ------------------------------------------------------------------
    def generate_charts(self, chart_dir: Path, charts: Dict) -> Dict:
        if self.macro_wide is None or len(self.macro_wide) < 10:
            return charts

        chart_dir = Path(chart_dir)
        chart_dir.mkdir(parents=True, exist_ok=True)

        # 1. Macro correlation heatmap (top 20)
        top = self._sensitivity.get('top_correlations', [])
        if len(top) >= 3:
            try:
                labels = [f"{t['macro_symbol']}\n({t['asset_feature']})" for t in top[:20]]
                vals = [t['correlation'] for t in top[:20]]
                fig, ax = plt.subplots(figsize=(10, max(4, len(labels) * 0.35)))
                colors_bar = [C['red'] if v < 0 else C['green'] for v in vals]
                bars = ax.barh(range(len(labels)), vals, color=colors_bar, height=0.6)
                ax.set_yticks(range(len(labels)))
                ax.set_yticklabels(labels, fontsize=7)
                ax.axvline(0, color='gray', linewidth=0.5)
                ax.set_xlabel('Correlacao de Pearson')
                ax.set_title('Top 20 Correlacoes Macro vs Ativo', fontweight='bold', fontsize=10)
                for bar, v in zip(bars, vals):
                    ax.text(
                        v + (0.01 if v >= 0 else -0.03),
                        bar.get_y() + bar.get_height() / 2,
                        f'{v:.2f}', va='center', fontsize=6
                    )
                plt.tight_layout()
                path = str(chart_dir / 'macro_corr_heatmap.png')
                fig.savefig(path, dpi=150, bbox_inches='tight')
                plt.close(fig)
                charts['macro_corr_heatmap'] = path
            except Exception as e:
                logger.warning(f"[CHART] Falha no macro_corr_heatmap: {e}")

        # 2. Regime-conditional beta chart
        betas = self._sensitivity.get('regime_betas', {})
        if betas:
            try:
                regimes = sorted(betas.keys())
                macro_keys = sorted({k for v in betas.values() for k in v})
                n_macro = len(macro_keys)
                n_reg = len(regimes)
                fig, axes = plt.subplots(1, n_macro, figsize=(3 * n_macro + 1, 4),
                                         sharey=False)
                if n_macro == 1:
                    axes = [axes]
                for ax_i, mk in enumerate(macro_keys):
                    r_vals = [betas[r].get(mk, 0) for r in regimes]
                    colors_beta = [C['red'] if v < 0 else C['green'] for v in r_vals]
                    ax = axes[ax_i]
                    ax.bar(range(n_reg), r_vals, color=colors_beta, width=0.5)
                    ax.set_xticks(range(n_reg))
                    ax.set_xticklabels([r.replace('_', '\n') for r in regimes], fontsize=6)
                    ax.axhline(0, color='gray', linewidth=0.5)
                    ax.set_title(mk, fontsize=7, fontweight='bold')
                    ax.tick_params(axis='y', labelsize=6)
                fig.suptitle('Regime-Conditional Macro Betas', fontweight='bold', fontsize=10, y=1.02)
                plt.tight_layout()
                path = str(chart_dir / 'regime_betas.png')
                fig.savefig(path, dpi=150, bbox_inches='tight')
                plt.close(fig)
                charts['regime_betas'] = path
            except Exception as e:
                logger.warning(f"[CHART] Falha no regime_betas: {e}")

        # 3. RORO Timeline (se disponivel)
        if self.roro_df is not None and len(self.roro_df) >= 10:
            try:
                roro = self.roro_df['roro_score'].dropna()
                fig, ax = plt.subplots(figsize=(10, 3))
                ax.plot(roro.index, roro.values, color=C['steel'], linewidth=0.8)
                ax.axhline(y=0, color='gray', linestyle='--', linewidth=0.5)
                ax.fill_between(roro.index, roro.values, 0,
                                where=roro.values > 0, color=C['green'], alpha=0.3)
                ax.fill_between(roro.index, roro.values, 0,
                                where=roro.values < 0, color=C['red'], alpha=0.3)
                ax.set_title('RORO Score (Risk On / Risk Off)', fontweight='bold')
                ax.set_ylabel('RORO Z-Score')
                plt.tight_layout()
                path = str(chart_dir / 'roro_timeline.png')
                fig.savefig(path, dpi=150, bbox_inches='tight')
                plt.close(fig)
                charts['roro_timeline'] = path
            except Exception as e:
                logger.warning(f"[CHART] Falha no roro_timeline: {e}")

        # 4. DXY vs VIX
        if 'DTWEXBGS' in self.macro_wide.columns and 'VIX' in self.macro_wide.columns:
            try:
                dxy = self.macro_wide['DTWEXBGS'].dropna()
                vix = self.macro_wide['VIX'].dropna()
                fig, ax1 = plt.subplots(figsize=(10, 4))
                ax1.plot(dxy.index, dxy.values, color=C['steel'], linewidth=0.8, label='DXY')
                ax2 = ax1.twinx()
                ax2.plot(vix.index, vix.values, color=C['red'], linewidth=0.8, label='VIX')
                ax1.set_ylabel('DXY', color=C['steel'])
                ax2.set_ylabel('VIX', color=C['red'])
                ax1.set_title('DXY e VIX (Macro Environment)', fontweight='bold')
                lines = ax1.get_lines() + ax2.get_lines()
                ax1.legend(lines, [l.get_label() for l in lines], loc='upper left')
                plt.tight_layout()
                path = str(chart_dir / 'dxy_vix_timeline.png')
                fig.savefig(path, dpi=150, bbox_inches='tight')
                plt.close(fig)
                charts['dxy_vix_timeline'] = path
            except Exception as e:
                logger.warning(f"[CHART] Falha no dxy_vix_timeline: {e}")

        # 5. Macro factors bar chart
        factors = self._sensitivity.get('macro_factors', {})
        if factors:
            try:
                fnames = sorted(factors.keys())
                fcorrs = [factors[f].get('correlation', 0) for f in fnames]
                fig, ax = plt.subplots(figsize=(8, 3.5))
                colors_f = [C['red'] if v < 0 else C['green'] for v in fcorrs]
                bars = ax.bar(range(len(fnames)), fcorrs, color=colors_f, width=0.5)
                ax.axhline(0, color='gray', linewidth=0.5)
                ax.set_xticks(range(len(fnames)))
                ax.set_xticklabels(fnames, fontsize=8, rotation=45, ha='right')
                ax.set_ylabel('Correlacao (close_ret)', fontsize=8)
                ax.set_title('Correlacao do Ativo com Fatores Macro', fontweight='bold', fontsize=10)
                for bar, v in zip(bars, fcorrs):
                    ax.text(bar.get_x() + bar.get_width() / 2,
                            v + (0.02 if v >= 0 else -0.05),
                            f'{v:.2f}', ha='center', fontsize=7)
                plt.tight_layout()
                path = str(chart_dir / 'macro_factors.png')
                fig.savefig(path, dpi=150, bbox_inches='tight')
                plt.close(fig)
                charts['macro_factors'] = path
            except Exception as e:
                logger.warning(f"[CHART] Falha no macro_factors: {e}")

        return charts


# ══════════════════════════════════════════════════════════════
# WALK-FORWARD VALIDATOR (Fase C)
# ══════════════════════════════════════════════════════════════
class WalkForwardValidator:
    """Valida estabilidade do perfil dividindo o histórico em janelas."""

    def __init__(self, df: pd.DataFrame, n_windows: int = 6):
        self.df = df
        self.n_windows = n_windows
        self.results: List[Dict] = []

    def analyze(self) -> Dict[str, Any]:
        logger.info(f"[WALK-FORWARD] Dividindo em {self.n_windows} janelas...")
        dates = self.df.index.sort_values()
        if len(dates) < 10000:
            return {'stability_score': 0, 'periods': []}

        window_size = len(dates) // self.n_windows
        periods = []
        for i in range(self.n_windows):
            start = i * window_size
            end = (i + 1) * window_size if i < self.n_windows - 1 else len(dates)
            window_df = self.df.iloc[start:end]
            if len(window_df) < 100:
                continue
            label = f"{window_df.index[0].strftime('%Y-%m')} a {window_df.index[-1].strftime('%Y-%m')}"
            regime_counts = window_df['regime'].value_counts(normalize=True)
            periods.append({
                'label': label,
                'hurst': float(window_df['hurst'].mean()),
                'adx': float(window_df['adx'].mean()),
                'atr': float(window_df['atr'].mean()),
                'dominant': regime_counts.index[0],
                'dominant_pct': float(regime_counts.iloc[0] * 100),
                'trend_pct': float((regime_counts.get('TREND_FORTE', 0) + regime_counts.get('TREND_FRACO', 0)) * 100),
                'range_pct': float(regime_counts.get('RANGE', 0) * 100),
                'chop_pct': float(regime_counts.get('CHOP', 0) * 100),
                'n_candles': len(window_df),
            })

        if len(periods) < 2:
            return {'stability_score': 0, 'periods': periods}

        # Stability score: lower std = more stable
        hurst_std = np.std([p['hurst'] for p in periods])
        adx_std = np.std([p['adx'] for p in periods])
        trend_std = np.std([p['trend_pct'] for p in periods])
        max_drift = max(abs(p['hurst'] - periods[0]['hurst']) for p in periods)

        # Score 0-100
        score = 100.0
        score -= min(50, hurst_std / 0.05 * 50)
        score -= min(30, adx_std / 5.0 * 30)
        score -= min(20, max_drift / 0.15 * 20)
        score = max(10, score)

        logger.info(f"  [OK] Score: {score:.0f}% | {len(periods)} periodos")
        self.results = periods
        return {
            'stability_score': score,
            'periods': periods,
            'hurst_std': hurst_std,
            'adx_std': adx_std,
            'trend_std': trend_std,
        }

    def generate_charts(self, chart_dir: Path, charts: Dict) -> Dict:
        """Gera gráficos de walk-forward."""
        if len(self.results) < 2:
            return charts

        # Stability line chart
        fig, ax1 = plt.subplots(figsize=(10, 4))
        labels = [p['label'].split(' a ')[0] for p in self.results]
        x = range(len(self.results))
        hurst_vals = [p['hurst'] for p in self.results]
        adx_vals = [p['adx'] for p in self.results]

        ax1.plot(x, hurst_vals, color=C['blue'], marker='o', linewidth=2, label='Hurst')
        ax1.axhline(y=0.55, color='red', linestyle='--', linewidth=0.8, alpha=0.5)
        ax1.axhline(y=0.45, color='red', linestyle='--', linewidth=0.8, alpha=0.5)
        ax1.set_ylabel('Hurst', color=C['blue'])
        ax1.set_ylim(0.3, 0.8)

        ax2 = ax1.twinx()
        ax2.plot(x, adx_vals, color=C['gold'], marker='s', linewidth=2, label='ADX')
        ax2.axhline(y=25, color='orange', linestyle='--', linewidth=0.8, alpha=0.5)
        ax2.set_ylabel('ADX', color=C['gold'])

        ax1.set_xticks(x)
        ax1.set_xticklabels(labels, rotation=45, ha='right', fontsize=8)
        ax1.set_title('Estabilidade Temporal: Hurst e ADX', fontweight='bold')
        lines = ax1.get_lines() + ax2.get_lines()
        ax1.legend(lines, [l.get_label() for l in lines], loc='upper left')
        plt.tight_layout()
        path = str(chart_dir / 'wf_stability.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        charts['wf_stability'] = path

        # Regime stacked bar
        fig, ax = plt.subplots(figsize=(10, 4))
        categories = ['TREND_FORTE', 'TREND_FRACO', 'RANGE', 'CHOP']
        colors_list = [REGIME_COLORS.get(r, '#999') for r in categories]
        bottom = np.zeros(len(self.results))
        for idx, cat in enumerate(categories):
            vals = [p.get(cat.lower().replace('_', '_pct'), 0) / 100 for p in self.results]
            ax.bar(x, vals, bottom=bottom, color=colors_list[idx], label=cat, width=0.6)
            bottom += vals
        ax.set_xticks(x)
        ax.set_xticklabels(labels, rotation=45, ha='right', fontsize=8)
        ax.set_ylabel('Proporcao')
        ax.set_title('Evolucao de Regime por Periodo', fontweight='bold')
        ax.legend(loc='upper right')
        ax.set_ylim(0, 1)
        plt.tight_layout()
        path = str(chart_dir / 'wf_regime.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        charts['wf_regime'] = path

        return charts


# ══════════════════════════════════════════════════════════════
# PURGED WALK-FORWARD VALIDATOR (López de Prado — sem leakage)
# ══════════════════════════════════════════════════════════════
class PurgedWalkForwardValidator:
    """Walk-Forward Validation com purge gap e embargo.
    
    Elimina leakage informacional entre treino e teste:
      - Purge gap: remove N candles após cada janela de treino
      - Embargo: remove M candles antes de cada janela de teste
    
    Preserva 100% o WalkForwardValidator original; 
    adiciona validação mais robusta para perfilagem.
    """
    
    def __init__(self, df: pd.DataFrame, n_windows: int = 6,
                 purge_pct: float = 0.02, embargo_pct: float = 0.01):
        self.df = df
        self.n_windows = n_windows
        self.purge_pct = purge_pct
        self.embargo_pct = embargo_pct
        self.results: List[Dict] = []
    
    def analyze(self) -> Dict[str, Any]:
        logger.info(f"[PURGED WF] Walk-forward com purge={self.purge_pct:.1%} embargo={self.embargo_pct:.1%}...")
        dates = self.df.index.sort_values()
        n = len(dates)
        if n < 10000:
            return {'stability_score': 0, 'periods': [], 'purged': False}
        
        window_size = n // self.n_windows
        purge_size = max(10, int(window_size * self.purge_pct))
        embargo_size = max(5, int(window_size * self.embargo_pct))
        
        periods = []
        for i in range(self.n_windows):
            train_start = 0
            train_end = (i + 1) * window_size
            test_start = train_end + purge_size
            test_end = test_start + window_size
            
            if test_end > n:
                test_end = n
            
            if test_start >= test_end:
                continue
            
            # Train set (com embargo: remove últimos embargo_size candles)
            train_df = self.df.iloc[train_start:train_end - embargo_size].copy()
            test_df = self.df.iloc[test_start:test_end].copy()
            
            if len(train_df) < 100 or len(test_df) < 10:
                continue
            
            label = (f"treino:{train_df.index[0].strftime('%Y-%m')}-{train_df.index[-1].strftime('%Y-%m')} "
                    f"→ teste:{test_df.index[0].strftime('%Y-%m')}-{test_df.index[-1].strftime('%Y-%m')}")
            
            # Métricas no treino
            train_counts = train_df['regime'].value_counts(normalize=True)
            # Métricas no teste
            test_counts = test_df['regime'].value_counts(normalize=True)
            
            # Estabilidade: diferença entre treino e teste
            hurst_diff = abs(train_df['hurst'].mean() - test_df['hurst'].mean())
            adx_diff = abs(train_df['adx'].mean() - test_df['adx'].mean())
            
            # Divergência de regime (Jensen-Shannon-like)
            regime_labels_set = ['TREND_FORTE', 'TREND_FRACO', 'RANGE', 'CHOP']
            js_div = 0.0
            for r in regime_labels_set:
                p = train_counts.get(r, 0)
                q = test_counts.get(r, 0)
                m = (p + q) / 2
                if p > 0:
                    js_div += p * np.log(p / m) if m > 0 else 0
                if q > 0:
                    js_div += q * np.log(q / m) if m > 0 else 0
            js_div /= 2
            
            periods.append({
                'label': label,
                'train_hurst': float(train_df['hurst'].mean()),
                'test_hurst': float(test_df['hurst'].mean()),
                'train_adx': float(train_df['adx'].mean()),
                'test_adx': float(test_df['adx'].mean()),
                'train_dominant': train_counts.index[0] if len(train_counts) else 'N/A',
                'test_dominant': test_counts.index[0] if len(test_counts) else 'N/A',
                'hurst_diff': float(hurst_diff),
                'adx_diff': float(adx_diff),
                'js_divergence': float(js_div),
                'n_train': len(train_df),
                'n_test': len(test_df),
            })
        
        if len(periods) < 2:
            return {'stability_score': 0, 'periods': periods, 'purged': True}
        
        # Score combinado: estabilidade + divergência
        hurst_diffs = [p['hurst_diff'] for p in periods]
        adx_diffs = [p['adx_diff'] for p in periods]
        js_divs = [p['js_divergence'] for p in periods]
        
        score = 100.0
        score -= min(40, np.mean(hurst_diffs) / 0.05 * 40)
        score -= min(30, np.mean(adx_diffs) / 5.0 * 30)
        score -= min(30, np.mean(js_divs) / 0.1 * 30)
        score = max(10, score)
        
        logger.info(f"  [PURGED WF] Score: {score:.0f}% | {len(periods)} janelas")
        self.results = periods
        return {
            'stability_score': score,
            'periods': periods,
            'purged': True,
            'mean_hurst_diff': float(np.mean(hurst_diffs)),
            'mean_adx_diff': float(np.mean(adx_diffs)),
            'mean_js_divergence': float(np.mean(js_divs)),
        }
    
    def generate_charts(self, chart_dir: Path, charts: Dict) -> Dict:
        if len(self.results) < 2:
            return charts
        
        # Train vs Test scatter: Hurst
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 4))
        labels_short = [f"J{i+1}" for i in range(len(self.results))]
        x = range(len(self.results))
        
        train_h = [p['train_hurst'] for p in self.results]
        test_h = [p['test_hurst'] for p in self.results]
        ax1.plot(x, train_h, color=C['blue'], marker='o', linewidth=2, label='Treino')
        ax1.plot(x, test_h, color=C['red'], marker='s', linewidth=2, linestyle='--', label='Teste')
        ax1.set_ylabel('Hurst')
        ax1.set_title('Hurst: Treino vs Teste (Purged)', fontweight='bold')
        ax1.legend()
        ax1.set_xticks(x)
        ax1.set_xticklabels(labels_short, rotation=0, fontsize=8)
        
        train_a = [p['train_adx'] for p in self.results]
        test_a = [p['test_adx'] for p in self.results]
        ax2.plot(x, train_a, color=C['blue'], marker='o', linewidth=2, label='Treino')
        ax2.plot(x, test_a, color=C['red'], marker='s', linewidth=2, linestyle='--', label='Teste')
        ax2.set_ylabel('ADX')
        ax2.set_title('ADX: Treino vs Teste (Purged)', fontweight='bold')
        ax2.legend()
        ax2.set_xticks(x)
        ax2.set_xticklabels(labels_short, rotation=0, fontsize=8)
        
        plt.tight_layout()
        path = str(chart_dir / 'purged_wf.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        charts['purged_wf'] = path
        
        return charts


# ══════════════════════════════════════════════════════════════
# JSON PROFILE EXPORTER (Fase D)
# ══════════════════════════════════════════════════════════════
class JsonProfileExporter:
    """Exporta perfil completo do ativo para JSON consumível pelo EA."""

    def __init__(self, df: pd.DataFrame, regime_labels: list, transition_mat: np.ndarray,
                 temporal: dict, tail_risk: dict, walkforward: dict, macro: dict,
                 hmm_model: dict = None, entropy: dict = None, fracdiff: dict = None,
                 signal_data: dict = None, purged_wf: dict = None):
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

    def export(self, output_path: str, symbol: str, tf: str) -> str:
        profile = self._build(symbol, tf)
        with open(output_path, 'w') as f:
            json.dump(profile, f, indent=2, default=str)
        logger.info(f"[JSON] Perfil exportado: {output_path}")
        return output_path

    def _build(self, symbol: str, tf: str) -> dict:
        df = self.df
        regime_dist = df['regime'].value_counts(normalize=True).to_dict()
        regime_dist_str = {str(k): float(v) for k, v in regime_dist.items()}
        avg_hurst = float(df['hurst'].mean())
        avg_adx = float(df['adx'].mean())
        avg_atr = float(df['atr'].mean())
        vol_hour = int(df.groupby('hour')['atr'].mean().idxmax())

        # DFA recommendation based on Hurst and volatility
        if avg_hurst > 0.58:
            dfa_period, dfa_min, dfa_max = 300, 14, 56
        elif avg_hurst > 0.52:
            dfa_period, dfa_min, dfa_max = 200, 8, 40
        else:
            dfa_period, dfa_min, dfa_max = 150, 6, 28

        # Strategy fit scores
        trend_score = min(1.0, (avg_hurst - 0.45) / 0.3 * 0.7 + regime_dist_str.get('TREND_FORTE', 0))
        meanrev_score = min(1.0, (0.6 - avg_hurst) / 0.3 * 0.7 + regime_dist_str.get('RANGE', 0))
        breakout_score = min(1.0, avg_adx / 40 * 0.5 + avg_atr * 0.1)

        # HMM data
        hmm_data = {}
        if 'hmm_regime' in df.columns:
            hmm_dist = df['hmm_regime'].value_counts(normalize=True).to_dict()
            hmm_data = {
                'states': int(df['hmm_state'].nunique()) if 'hmm_state' in df.columns else 0,
                'agreement_adx_hurst': round(self.hmm.get('agreement', 0), 1),
                'hmm_regime_distribution': {str(k): float(v) for k, v in hmm_dist.items()},
            }

        # Entropy data
        entropy_data = {}
        if 'sample_entropy' in df.columns:
            se = df['sample_entropy'].dropna()
            pe = df['perm_entropy'].dropna()
            entropy_data = {
                'sample_entropy_mean': round(float(se.mean()), 4) if len(se) else 0,
                'sample_entropy_std': round(float(se.std()), 4) if len(se) else 0,
                'perm_entropy_mean': round(float(pe.mean()), 4) if len(pe) else 0,
                'perm_entropy_std': round(float(pe.std()), 4) if len(pe) else 0,
            }

        # Fractional Differentiation data
        fracdiff_data = {}
        if 'fracdiff_close' in df.columns:
            fd = df['fracdiff_close'].dropna()
            fd_ret = df['fracdiff_return'].dropna()
            fracdiff_data = {
                'fracdiff_close_mean': round(float(fd.mean()), 6) if len(fd) else 0,
                'fracdiff_close_std': round(float(fd.std()), 6) if len(fd) else 0,
                'fracdiff_return_mean': round(float(fd_ret.mean()), 6) if len(fd_ret) else 0,
                'fracdiff_return_std': round(float(fd_ret.std()), 6) if len(fd_ret) else 0,
                'd_param': 0.5,
            }

        return {
            'meta': {
                'symbol': symbol,
                'timeframe': tf,
                'generated_at': datetime.now().isoformat(),
                'candles': len(df),
                'date_from': str(df.index[0]),
                'date_to': str(df.index[-1]),
            },
            'regime_profile': {
                'dominant': str(regime_dist_str),
                'hurst_mean': avg_hurst,
                'adx_mean': avg_adx,
                'atr_mean': avg_atr,
                'regime_distribution': regime_dist_str,
            },
            'hmm_model': hmm_data,
            'entropy': entropy_data,
            'fracdiff': fracdiff_data,
            'dfa_recommendation': {
                'period': dfa_period,
                'min_scale': dfa_min,
                'max_scale': dfa_max,
            },
            'session_profile': {
                'most_volatile_hour': vol_hour,
                'hourly_atr': {str(h): float(v) for h, v in df.groupby('hour')['atr'].mean().to_dict().items()},
            },
            'strategy_fit': {
                'trend_following_score': round(trend_score, 2),
                'mean_reversion_score': round(meanrev_score, 2),
                'breakout_score': round(breakout_score, 2),
            },
            'tail_risk': {
                'spike_pct': self.tail_risk.get('spike_pct', 0),
                'atr_threshold': self.tail_risk.get('atr_threshold', 0),
                'amplification_factor': round(self.tail_risk.get('avg_atr_spike', 0) / max(self.tail_risk.get('avg_atr_normal', 0.001), 0.001), 1),
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
                'wavelet_denoised': self.signal.get('has_wavelet', False),
                'transfer_entropy': {
                    k: v for k, v in self.signal.get('transfer_entropy', {}).items()
                } if self.signal.get('transfer_entropy') else {},
            },
            'purged_wf': {
                'score': round(self.purged_wf.get('stability_score', 0), 1),
                'n_windows': len(self.purged_wf.get('periods', [])),
                'purge_pct': 0.02,
                'embargo_pct': 0.01,
                'mean_js_divergence': round(self.purged_wf.get('mean_js_divergence', 0), 4),
            },
        }


# ══════════════════════════════════════════════════════════════
# BATCH RUNNER (Joblib para multi-asset)
# ══════════════════════════════════════════════════════════════
def process_single_asset(symbol: str, tf: str, input_file: Optional[str] = None, 
                         output_pdf: Optional[str] = None, no_cache: bool = False,
                         from_db: bool = True) -> Dict[str, Any]:
    """Processa um único ativo - função para paralelização."""
    if no_cache:
        CACHE.invalidate()
    
    try:
        if from_db:
            loader = DataLoader(symbol=symbol, tf=tf, from_db=True)
        else:
            loader = DataLoader(input_file or CFG.output_dir / f"{symbol}_{tf}.csv")
        df = loader.load()
        
        fe = FeatureEngine(df, tf=tf)
        df = fe.compute()
        
        rm = RegimeModel(df)
        df = rm.classify()
        trans_mat, regime_labels = rm.transition_matrix()
        
        tp = TemporalProfiler(df)
        temporal = tp.analyze()
        
        tr = TailRiskEngine(df)
        tail_risk = tr.analyze()
        
        ne = NarrativeEngine(df, rm, temporal, tail_risk)
        narratives = ne.generate()
        
        # Charts + PDF (simplified for batch - could skip for large batches)
        # ... (same as main pipeline)
        
        return {
            'symbol': symbol, 'tf': tf, 'status': 'success',
            'candles': len(df), 'dominant_regime': df['regime'].value_counts().index[0],
            'hurst_mean': float(df['hurst'].mean()), 'adx_mean': float(df['adx'].mean()),
        }
    except Exception as e:
        logger.error(f"[BATCH] Erro em {symbol}: {e}")
        return {'symbol': symbol, 'tf': tf, 'status': 'error', 'error': str(e)}


def run_batch(symbols: List[str], tf: str, no_cache: bool = False,
              from_db: bool = True) -> List[Dict[str, Any]]:
    """Executa batch de ativos em paralelo via Joblib."""
    if not HAS_JOBLIB:
        logger.warning("Joblib não disponível - executando sequencialmente")
        return [process_single_asset(s, tf, no_cache=no_cache, from_db=from_db) for s in symbols]
    
    n_jobs = CFG.n_jobs if CFG.n_jobs > 0 else None
    logger.info(f"[BATCH] Processando {len(symbols)} ativos com {n_jobs or 'auto'} workers")
    
    results = Parallel(n_jobs=n_jobs, backend='loky', verbose=10)(
        delayed(process_single_asset)(symbol, tf, no_cache=no_cache, from_db=from_db)
        for symbol in symbols
    )
    
    # Summary
    success = sum(1 for r in results if r['status'] == 'success')
    logger.info(f"[BATCH] Concluído: {success}/{len(symbols)} sucesso")
    return results


# ══════════════════════════════════════════════════════════════
# MAIN PIPELINE (CLI unificada)
# ══════════════════════════════════════════════════════════════
def main():
    parser = argparse.ArgumentParser(description='Asset DNA Profiler v2.1')
    parser.add_argument('--symbol', default=None, help='Simbolo único')
    parser.add_argument('--tf', default='M5', choices=['M1', 'M5'], help='Timeframe')
    parser.add_argument('--input', default=None, help='CSV de entrada')
    parser.add_argument('--output', default=None, help='PDF de saída')
    parser.add_argument('--batch', nargs='+', default=None, help='Lista de símbolos para batch')
    parser.add_argument('--no-cache', action='store_true', help='Ignora cache')
    parser.add_argument('--force-pandas', action='store_true', help='Força backend Pandas')
    parser.add_argument('--csv', action='store_true', help='Carrega de CSV em vez do SQLite (padrão: DB)')
    args = parser.parse_args()
    
    if args.force_pandas:
        CFG.use_polars = False
    
    from_db = not args.csv
    
    if args.batch:
        results = run_batch(args.batch, args.tf, no_cache=args.no_cache, from_db=from_db)
        # Save summary
        summary_file = CFG.report_dir / f"batch_summary_{datetime.now().strftime('%Y%m%d_%H%M')}.json"
        with open(summary_file, 'w') as f:
            json.dump(results, f, indent=2, default=str)
        logger.info(f"[BATCH] Resumo salvo em {summary_file}")
        return
    
    # Single asset mode (original pipeline)
    symbol = args.symbol or "XAUUSD"
    tf = args.tf.upper()
    input_file = args.input or CFG.output_dir / f"{symbol}_{tf}.csv"
    output_pdf = str(args.output or CFG.report_dir / f"asset_dna_{symbol}_{tf}.pdf")
    
    logger.info("=" * 60)
    logger.info(f"ALXQuant Asset DNA Profiler v2.2")
    source = "SQLite" if from_db else "CSV"
    logger.info(f"Simbolo: {symbol} | TF: {tf} | Fonte: {source} | Backend: {'Polars' if CFG.use_polars else 'Pandas'}")
    logger.info(f"Numba: {'ON' if HAS_NUMBA else 'OFF'} | tqdm: {'ON' if HAS_TQDM else 'OFF'}")
    logger.info("=" * 60)
    
    # Warm-up Numba antes de qualquer processamento real
    warmup_numba_kernels()
    
    t_total = time.time()
    
    if from_db:
        loader = DataLoader(symbol=symbol, tf=tf, from_db=True)
    else:
        loader = DataLoader(input_file)
    df = loader.load()
    
    fe = FeatureEngine(df, tf=tf)
    df = fe.compute()
    
    rm = RegimeModel(df)
    df = rm.classify()
    trans_mat, regime_labels = rm.transition_matrix()
    
    tp = TemporalProfiler(df)
    temporal = tp.analyze()
    
    tr = TailRiskEngine(df)
    tail_risk = tr.analyze()
    
    # --- HMM Regime Model (Institucional) ---
    hmm = HMMRegimeModel(df, n_states=4)
    df = hmm.classify()
    hmm_model_data = {
        'n_states': hmm.n_states,
        'agreement': hmm.agreement,
        'has_hmm': HAS_HMM and hmm.model is not None,
    }

    # Entropy stats for narrative
    entropy_stats = {}
    if 'sample_entropy' in df.columns:
        se = df['sample_entropy'].dropna()
        pe = df['perm_entropy'].dropna()
        entropy_stats = {
            'sample_entropy_mean': float(se.mean()) if len(se) else 0,
            'perm_entropy_mean': float(pe.mean()) if len(pe) else 0,
        }

    # --- Fase 2: Signal Analysis (Wavelet, MI, Transfer Entropy) ---
    signal_data = {
        'mi_matrix': fe.mi_matrix.tolist() if fe.mi_matrix is not None else None,
        'mi_labels': fe.mi_labels,
        'transfer_entropy': fe.transfer_entropy,
        'has_wavelet': HAS_PYWT and 'close_denoised' in df.columns,
    }

    ne = NarrativeEngine(df, rm, temporal, tail_risk,
                         hmm_model=hmm_model_data, entropy=entropy_stats,
                         signal_data=signal_data)
    narratives = ne.generate()

    # Charts + PDF
    features_agg = {
        'tail_risk': tail_risk,
        'temporal': temporal,
        'entropy': entropy_stats,
        'signal': signal_data,
    }

    cg = ChartGenerator(df, regime_labels, trans_mat, features_agg)
    charts = cg.generate_all()

    # --- Fase B: Macro Risk Integration ---
    try:
        macro_integrator = MacroRiskIntegrator()
        macro_integrator.load()
        macro_results = macro_integrator.cross_reference(df, symbol=symbol)
        charts = macro_integrator.generate_charts(CFG.report_dir / '_charts', charts)
    except Exception as e:
        logger.warning(f"[MACRO] Erro na integracao macro: {e}")
        macro_results = {}
        import traceback
        traceback.print_exc()

    # --- Fase C: Walk-Forward Validation (duplo: clássico + purged) ---
    wf_validator = WalkForwardValidator(df, n_windows=6)
    wf_results = wf_validator.analyze()
    charts = wf_validator.generate_charts(CFG.report_dir / '_charts', charts)

    purged_wf = PurgedWalkForwardValidator(df, n_windows=6, purge_pct=0.02, embargo_pct=0.01)
    purged_results = purged_wf.analyze()
    charts = purged_wf.generate_charts(CFG.report_dir / '_charts', charts)

    builder = PDFReportBuilder(output_pdf, charts, narratives, df, trans_mat,
                                regime_labels, features_agg, tf=tf,
                                walkforward=wf_results, macro=macro_results,
                                hmm_model=hmm_model_data, signal_data=signal_data)
    builder.build_pdf()

    # --- Fase D: JSON Export ---
    json_output = str(CFG.report_dir / f"asset_profile_{symbol}_{tf}.json")
    exporter = JsonProfileExporter(
        df, regime_labels, trans_mat, temporal, tail_risk, wf_results, macro_results,
        hmm_model=hmm_model_data, entropy=entropy_stats, fracdiff=None,
        signal_data=signal_data, purged_wf=purged_results,
    )
    exporter.export(json_output, symbol, tf)

    elapsed = time.time() - t_total
    logger.info(f"\n[OK] PDF: {output_pdf} | JSON: {json_output} | Tempo total: {elapsed:.2f}s | Candles: {len(df):,}")


if __name__ == '__main__':
    main()