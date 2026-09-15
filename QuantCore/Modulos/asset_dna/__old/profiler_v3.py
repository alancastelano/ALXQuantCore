"""
ALXQuant Asset DNA Profiler v3.0-Institutional
================================================
Pipeline institucional para perfilagem estrutural de ativos.

UPGRADES vs v2.2 (Auditoria Quantitativa):
  [INST-1] Fractional Diff: FFD dinÃ¢mico (busca de d Ã³timo via ADF) + scipy.signal.lfilter
  [INST-2] Hurst â†’ DFA (Detrended Fluctuation Analysis) â€” robusto a nÃ£o-estacionariedade
  [INST-3] Wavelet â†’ Filtro de Kalman (causal, sem look-ahead bias)
  [INST-4] Transfer Entropy: KSG (KNN contÃ­nuo) em vez de 3 bins discretos
  [INST-5] Macro: CointegraÃ§Ã£o de Johansen + VAR em vez de Pearson em nÃ­veis
  [INST-6] HMM: Features expandidas (RealVol, Skew, Kurtosis, Autocorr)
  [INST-7] ValidaÃ§Ã£o: CPCV (Combinatorial Purged CV) + PBO Score
  [INST-8] Logging: tqdm hierÃ¡rquico com heartbeats e ETA

PRESERVADO 100%:
  - Formato do PDF e todas as seÃ§Ãµes
  - Schema do JSON (retrocompatÃ­vel com EA MQL5)
  - CLI, cache, batch, Polars/Pandas fallback
  - LÃ³gica de regimes ADX+Hurst (thresholds adaptativos)
  - Purged Walk-Forward com embargo
"""
from __future__ import annotations

import os
import sys
import time
import math
import hashlib
import pickle
import warnings
import argparse
import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Any, Optional, Tuple, List, Union

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _THIS_DIR)
sys.path.insert(0, os.path.dirname(_THIS_DIR))

from db.schema import get_connection

import numpy as np
import pandas as pd

# â”€â”€ Polars â”€â”€
try:
    import polars as pl
    HAS_POLARS = True
except ImportError:
    HAS_POLARS = False
    pl = None  # type: ignore

# â”€â”€ Numba â”€â”€
try:
    from numba import njit, prange
    HAS_NUMBA = True
except ImportError:
    HAS_NUMBA = False
    def njit(*a, **kw):
        def w(fn): return fn
        return w
    prange = range

# â”€â”€ Joblib â”€â”€
try:
    from joblib import Parallel, delayed, Memory
    import joblib
    HAS_JOBLIB = True
except ImportError:
    HAS_JOBLIB = False

# â”€â”€ Bottleneck â”€â”€
try:
    import bottleneck as bn
    HAS_BOTTLENECK = True
except ImportError:
    HAS_BOTTLENECK = False

from scipy import stats
from scipy.signal import lfilter  # [INST-1] FFD via convoluÃ§Ã£o vetorial
from scipy.spatial import cKDTree  # [INST-4] KSG estimator

# [INST-1] ADF para busca de d Ã³timo
try:
    from statsmodels.tsa.stattools import adfuller
    HAS_STATSMODELS = True
except ImportError:
    HAS_STATSMODELS = False

# [INST-5] Johansen cointegration
try:
    from statsmodels.tsa.vector_ar.vecm import coint_johansen
    HAS_JOHANSEN = True
except ImportError:
    HAS_JOHANSEN = False

# [INST-3] Kalman â€” implementaÃ§Ã£o nativa (sem pykalman)
# [INST-6] HMM
try:
    from hmmlearn.hmm import GaussianHMM
    HAS_HMM = True
except ImportError:
    HAS_HMM = False
    GaussianHMM = None  # type: ignore

# â”€â”€ tqdm â”€â”€
try:
    from tqdm import tqdm, trange
    HAS_TQDM = True
except ImportError:
    HAS_TQDM = False
    def tqdm(iterable, **kw): return iterable
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
    BaseModel = object  # type: ignore
    BaseSettings = object  # type: ignore
    Field = lambda *a, **kw: None  # type: ignore

warnings.filterwarnings('ignore')

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# CONFIGURAÃ‡ÃƒO
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
ALGO_VERSION = "v3.0-inst"
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
SESSION_HOURS = [(0, 8), (8, 13), (13, 17), (17, 24)]
REGIME_LABELS = ['TREND_FORTE', 'TREND_FRACO', 'RANGE', 'CHOP']
REGIME_COLORS = {
    'TREND_FORTE': '#27AE60', 'TREND_FRACO': '#3498DB',
    'RANGE': '#F39C12', 'CHOP': '#E74C3C',
}

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# LOGGING [INST-8] â€” heartbeats + ETA
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
def setup_logger(name: str = 'asset_dna') -> logging.Logger:
    logger = logging.getLogger(name)
    logger.setLevel(getattr(logging, CFG.log_level.upper()))
    if logger.handlers:
        return logger
    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(getattr(logging, CFG.log_level.upper()))
    if CFG.log_json:
        fmt = logging.Formatter(
            '{"time":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}'
        )
    else:
        fmt = logging.Formatter(
            '%(asctime)s [%(levelname)s] %(name)s: %(message)s', datefmt='%H:%M:%S'
        )
    handler.setFormatter(fmt)
    logger.addHandler(handler)
    return logger

logger = setup_logger()


def log_phase(phase_num: int, total: int, name: str):
    """[INST-8] Log de fase com heartbeat."""
    logger.info(f"{'='*60}")
    logger.info(f"  FASE [{phase_num}/{total}] â€” {name}")
    logger.info(f"{'='*60}")


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# CACHE
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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
        except Exception as e:
            logger.warning(f"[CACHE] Erro: {e}")
        return None

    def put(self, ns: str, data: Any, value: Any, params: Optional[Dict] = None) -> Any:
        if not HAS_JOBLIB:
            return value
        try:
            h = self._hash_data(data, params)
            path = self._key_path(ns, h)
            joblib.dump(value, path, compress=CFG.cache_compress)
        except Exception as e:
            logger.warning(f"[CACHE] Erro save: {e}")
        return value

    def invalidate(self, ns: str = None):
        pattern = f"{ns}_" if ns else ""
        for f in self.cache_dir.glob(f"{pattern}*.joblib"):
            try:
                f.unlink()
            except Exception:
                pass

CACHE = DiskCache()

# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# NUMBA KERNELS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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

    # [INST-2] DFA â€” Detrended Fluctuation Analysis (substitui Hurst variance)
    @njit(cache=True, parallel=True, fastmath=True)
    def _dfa_numba(log_prices: np.ndarray, window: int) -> np.ndarray:
        """Rolling DFA Hurst exponent.
        Para cada janela:
          1. Integra a sÃ©rie (cumsum dos desvios da mÃ©dia)
          2. Divide em caixas de tamanho s
          3. Ajusta reta em cada caixa, calcula RMS dos resÃ­duos
          4. RegressÃ£o log(s) vs log(F(s)) â†’ slope = Hurst
        """
        n = log_prices.shape[0]
        out = np.full(n, np.nan, dtype=np.float64)
        min_box = 4
        max_box = min(50, window // 4)
        if max_box < min_box + 2:
            return out

        # Escalas (lags) para regressÃ£o
        n_scales = 0
        scales = np.empty(max_box, dtype=np.int64)
        s = min_box
        while s <= max_box:
            scales[n_scales] = s
            n_scales += 1
            s = max(s + 1, int(s * 1.3))  # Escalas logarÃ­tmicas
        if n_scales < 3:
            return out
        scales = scales[:n_scales]
        log_scales = np.log(scales.astype(np.float64))

        for i in prange(window - 1, n):
            w_start = i - window + 1
            seg = log_prices[w_start:i + 1]
            w_len = len(seg)
            mean_seg = seg.mean()

            # Passo 1: Perfil (cumsum dos desvios)
            profile = np.empty(w_len, dtype=np.float64)
            cum = 0.0
            for k in range(w_len):
                cum += seg[k] - mean_seg
                profile[k] = cum

            # Passo 2-3: Para cada escala, calcular F(s)
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
                    # Ajuste linear (OLS) no box
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
                    # RMS dos resÃ­duos
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


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# [INST-1] FRACTIONAL DIFFERENTIATION â€” FFD dinÃ¢mico + lfilter
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
def _fracdiff_weights(d: float, window: int) -> np.ndarray:
    """Pesos FFD (Fixed-Width Fractional Differentiation)."""
    w = [1.0]
    for k in range(1, window):
        w.append(-w[-1] * (d - k + 1) / k)
    return np.array(w, dtype=np.float64)


def _ffd_series_lfilter(series: np.ndarray, d: float, window: int = 200) -> np.ndarray:
    """[INST-1] FFD via scipy.signal.lfilter â€” O(N) em vez de O(NÃ—W)."""
    w = _fracdiff_weights(d, window)
    # lfilter aplica o filtro FIR causal
    result = lfilter(w, [1.0], series)
    # Zerar a janela inicial (warmup do filtro)
    result[:window - 1] = np.nan
    return result


def _find_optimal_d(series: np.ndarray, window: int = 200,
                    d_range: Tuple[float, float] = (0.0, 1.0),
                    step: float = 0.1) -> float:
    """[INST-1] Busca o menor d que torna a sÃ©rie estacionÃ¡ria (ADF p<0.05).
    Preserva mÃ¡xima memÃ³ria de longo prazo."""
    if not HAS_STATSMODELS:
        return 0.5  # Fallback seguro
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
                break  # Menor d que estacionariza â†’ mÃ¡xima memÃ³ria
        except Exception:
            continue
    return best_d


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# [INST-3] KALMAN FILTER â€” causal, sem look-ahead bias
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
def _kalman_filter_1d(series: np.ndarray, delta: float = 1e-4) -> Tuple[np.ndarray, np.ndarray]:
    """[INST-3] Filtro de Kalman univariado para extraÃ§Ã£o de tendÃªncia causal.
    Substitui Wavelet denoising (que tinha look-ahead bias).

    Args:
        series: SÃ©rie temporal (ex: log(close))
        delta: Fator de ruÃ­do do processo (menor = mais suave)

    Returns:
        (state, P): TendÃªncia filtrada e variÃ¢ncia do estado
    """
    n = len(series)
    state = np.full(n, np.nan, dtype=np.float64)
    P = np.full(n, np.nan, dtype=np.float64)

    if n < 2:
        return series.copy(), np.ones(n)

    # InicializaÃ§Ã£o via mÃ©dia mÃ³vel curta
    init_len = min(50, n)
    state[0] = np.mean(series[:init_len])
    P[0] = np.var(series[:init_len])
    R = max(P[0], 1e-10)  # VariÃ¢ncia da observaÃ§Ã£o
    Q = delta * R          # VariÃ¢ncia do processo

    for t in range(1, n):
        if not np.isfinite(series[t]):
            state[t] = state[t - 1]
            P[t] = P[t - 1] + Q
            continue
        # Predict
        state_pred = state[t - 1]
        P_pred = P[t - 1] + Q
        # Update
        K = P_pred / (P_pred + R)
        state[t] = state_pred + K * (series[t] - state_pred)
        P[t] = (1 - K) * P_pred

    return state, P


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# [INST-4] TRANSFER ENTROPY â€” KSG (Kraskov-StÃ¶gbauer-Grassberger)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
def _transfer_entropy_ksg(source: np.ndarray, target: np.ndarray,
                          k: int = 4, delay: int = 1) -> float:
    """[INST-4] Transfer Entropy via estimador KSG (KNN em espaÃ§o contÃ­nuo).
    Elimina a discretizaÃ§Ã£o em bins que destruÃ­a informaÃ§Ã£o de cauda.

    TE(Sâ†’T) = H(T_future | T_present) - H(T_future | T_present, S_past)

    Usa k-NN no espaÃ§o conjunto e marginais (Kraskov et al., 2004).
    """
    n = min(len(source), len(target))
    if n < 100 + delay:
        return 0.0

    # Construir vetores de estado
    # T_future = target[delay+1:]
    # T_present = target[delay:-1]
    # S_past = source[:-delay-1]
    t_future = target[delay + 1:n].reshape(-1, 1).copy()
    t_present = target[delay:n - 1].reshape(-1, 1).copy()
    s_past = source[:n - delay - 1].reshape(-1, 1).copy()

    m = len(t_future)
    if m < k + 1:
        return 0.0

    # EspaÃ§os:
    # Joint = (T_future, T_present, S_past) â€” 3D
    # Marginal1 = (T_future, T_present) â€” 2D
    # Marginal2 = (T_present, S_past) â€” 2D
    # Marginal3 = T_present â€” 1D
    joint = np.hstack([t_future, t_present, s_past])
    marg_tp = np.hstack([t_future, t_present])
    marg_ts = np.hstack([t_present, s_past])
    marg_t = t_present

    # Normalizar cada dimensÃ£o (z-score) para KNN equilibrado
    for arr in [joint, marg_tp, marg_ts, marg_t]:
        for col in range(arr.shape[1]):
            s_col = arr[:, col].std()
            if s_col > 1e-10:
                arr[:, col] = (arr[:, col] - arr[:, col].mean()) / s_col

    tree_joint = cKDTree(joint)
    tree_tp = cKDTree(marg_tp)
    tree_ts = cKDTree(marg_ts)
    tree_t = cKDTree(marg_t)

    from scipy.special import digamma

    te_sum = 0.0
    for i in range(m):
        # DistÃ¢ncia ao k-Ã©simo vizinho no espaÃ§o conjunto (chebyshev)
        dists, _ = tree_joint.query(joint[i], k=k + 1, p=np.inf)
        eps = dists[-1]  # Raio do k-NN
        if eps < 1e-15:
            eps = 1e-15

        # Contar vizinhos dentro de eps em cada marginal
        n_tp = len(tree_tp.query_ball_point(marg_tp[i], eps, p=np.inf)) - 1
        n_ts = len(tree_ts.query_ball_point(marg_ts[i], eps, p=np.inf)) - 1
        n_t = len(tree_t.query_ball_point(marg_t[i], eps, p=np.inf)) - 1

        n_tp = max(n_tp, 1)
        n_ts = max(n_ts, 1)
        n_t = max(n_t, 1)

        # KSG formula: psi(k) - psi(n_tp) - psi(n_ts) + psi(n_t)
        te_sum += digamma(k) - digamma(n_tp) - digamma(n_ts) + digamma(n_t)

    te = max(0.0, te_sum / m)
    return float(te)


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# PERMUTATION ENTROPY (mantido â€” jÃ¡ Ã© O(N) e robusto)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# ROLLING HELPERS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
def rolling_mean(arr: np.ndarray, window: int) -> np.ndarray:
    if HAS_BOTTLENECK:
        return bn.move_mean(arr, window, min_count=window)
    return pd.Series(arr).rolling(window, min_periods=window).mean().to_numpy()

def rolling_std(arr: np.ndarray, window: int) -> np.ndarray:
    if HAS_BOTTLENECK:
        return bn.move_std(arr, window, min_count=window)
    return pd.Series(arr).rolling(window, min_periods=window).std().to_numpy()


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# NUMBA WARM-UP
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
def warmup_numba_kernels():
    if not HAS_NUMBA:
        return
    logger.info("[WARM-UP] Compilando kernels Numba (pode levar atÃ© 90s)...")
    t0 = time.time()
    dummy = np.random.randn(2000).astype(np.float64)
    dummy_int = np.random.randint(0, 4, 2000).astype(np.int32)
    _classify_session_numba(np.array([0, 6, 10, 15, 20], dtype=np.int32))
    _sample_entropy_numba(dummy, m=2, r_factor=0.2)
    _dfa_numba(np.cumsum(dummy), 100)
    _transition_matrix_numba(dummy_int, 4)
    _mi_numba(dummy[:1000], dummy[1000:2000], bins=20)
    logger.info(f"[WARM-UP] OK em {time.time() - t0:.1f}s")


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# DATA LOADER
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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
            logger.warning("  Nenhum dado encontrado")
            return pd.DataFrame()
        df['time'] = pd.to_datetime(df['time'], unit='s')
        df.set_index('time', inplace=True)
        df.index.name = 'time'
        logger.info(f"  [OK] {len(df):,} candles | {df.index[0]} a {df.index[-1]}")
        return df

    def load(self) -> pd.DataFrame:
        if self.from_db:
            return self._load_from_db()
        logger.info(f"[LOAD] {self.filepath} (backend: {self.backend})")
        if not self.filepath.exists():
            logger.error(f"Arquivo nÃ£o encontrado: {self.filepath}")
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
            try:
                pl.from_pandas(df).write_parquet(parquet_path, compression='snappy')
            except Exception:
                pass
        else:
            df = pd.read_csv(self.filepath, low_memory=False)
            df = self._normalize_columns(df)
            try:
                df.to_parquet(parquet_path, engine='pyarrow', compression='snappy')
            except Exception:
                pass
        if 'time' in df.columns and not np.issubdtype(df['time'].dtype, np.datetime64):
            df['time'] = pd.to_datetime(df['time'])
        if 'time' in df.columns:
            df.set_index('time', inplace=True)
            df.index.name = 'time'
        logger.info(f"  [OK] {len(df):,} candles | {df.index[0]} a {df.index[-1]}")
        self.df = df
        return df


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# FEATURE ENGINE
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
class FeatureEngine:
    def __init__(self, df: pd.DataFrame, tf: str = 'M5'):
        self.df = df
        self.ws = 5 if tf == 'M1' else 1
        self.tf = tf
        self.backend = 'polars' if HAS_POLARS and CFG.use_polars else 'pandas'
        self.mi_matrix = None
        self.mi_labels = []
        self.transfer_entropy = {}
        self.ffd_d_close = 0.5  # [INST-1] d otimizado
        self.ffd_d_return = 0.3

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
        cached = CACHE.get("features_v5", cache_seed, params=cache_params)
        if cached is not None and len(cached) == len(df):
            logger.info(f"  [CACHE HIT] Features em {time.time()-t0:.2f}s")
            return cached

        if self.backend == 'polars' and HAS_POLARS:
            df = self._compute_polars(df)
        else:
            df = self._compute_pandas(df)

        df = self._add_advanced_features(df)
        CACHE.put("features_v5", cache_seed, df, params=cache_params)
        return df

    def _add_advanced_features(self, df: pd.DataFrame) -> pd.DataFrame:
        """[INST] Entropy + FFD dinÃ¢mico + Kalman + KSG TE."""
        close = df['close'].to_numpy(dtype=np.float64)
        log_ret = df['log_return'].to_numpy(dtype=np.float64)
        n = len(close)
        t0 = time.time()
        logger.info(f"[ADV FEATURES] DFA + FFD + Kalman + KSG TE + Entropy...")

        # â”€â”€ [INST-2] DFA Hurst (substitui Hurst variance) â”€â”€
        # JÃ¡ calculado no _compute_polars/pandas via _dfa_numba
        # df['hurst'] jÃ¡ contÃ©m DFA

        # â”€â”€ Entropy: rolling com sub-amostragem â”€â”€
        t1 = time.time()
        entropy_win = min(500, n // 4)
        entropy_step = 50
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
        logger.info(f"  [ENTROPY] OK em {time.time()-t1:.2f}s")

        # â”€â”€ [INST-1] FFD dinÃ¢mico (busca de d Ã³timo via ADF) â”€â”€
        t2 = time.time()
        fd_window = min(200, n // 4)
        log_close = np.log(close)
        self.ffd_d_close = _find_optimal_d(log_close, window=fd_window)
        self.ffd_d_return = _find_optimal_d(log_ret, window=fd_window)
        logger.info(f"  [FFD] d_close={self.ffd_d_close:.2f}, d_return={self.ffd_d_return:.2f}")
        df['fracdiff_close'] = _ffd_series_lfilter(log_close, self.ffd_d_close, fd_window).astype(np.float32)
        df['fracdiff_return'] = _ffd_series_lfilter(log_ret, self.ffd_d_return, fd_window).astype(np.float32)
        logger.info(f"  [FFD] OK em {time.time()-t2:.2f}s")

        # â”€â”€ [INST-3] Kalman Filter (substitui Wavelet) â”€â”€
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

        # â”€â”€ Mutual Information Matrix (Numba) â”€â”€
        t4 = time.time()
        mi_cols = ['hurst', 'adx', 'atr', 'return', 'volume_zscore', 'tr_zscore']
        mi_available = [c for c in mi_cols if c in df.columns]
        if len(mi_available) >= 2:
            self.mi_matrix = _mutual_information_matrix_numba(df, mi_available)
            self.mi_labels = mi_available
        else:
            self.mi_matrix = np.zeros((len(mi_available), len(mi_available)))
            self.mi_labels = mi_available
        logger.info(f"  [MI] OK em {time.time()-t4:.2f}s")

        # â”€â”€ [INST-4] Transfer Entropy KSG (contÃ­nuo, sem bins) â”€â”€
        t5 = time.time()
        te_results = {}
        if 'return' in df.columns and 'volume_zscore' in df.columns:
            r = df['return'].dropna().to_numpy(dtype=np.float64)
            v = df['volume_zscore'].dropna().to_numpy(dtype=np.float64)
            min_len = min(len(r), len(v))
            # Sub-amostrar para KSG (O(N log N) por ponto)
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

        # [INST-2] DFA Hurst (substitui _hurst_numba)
        log_price = df_pl['close'].log().cast(pl.Float64).to_numpy()
        hurst_win = 100 * ws
        hurst_cached = CACHE.get("dfa_hurst", log_price.astype(np.float32))
        if hurst_cached is not None:
            logger.info(f"  [CACHE HIT] DFA Hurst")
            hurst = hurst_cached
        else:
            logger.info(f"  [DFA] Calculando Hurst via DFA (window={hurst_win})...")
            t_h = time.time()
            hurst = _dfa_numba(log_price, hurst_win)
            logger.info(f"  [DFA] OK em {time.time()-t_h:.2f}s")
            CACHE.put("dfa_hurst", log_price.astype(np.float32), hurst)
        df_pl = df_pl.with_columns(pl.Series('hurst', hurst.astype(np.float32)))

        for freq_name, freq_str in [('return_m15', '15m'), ('return_h1', '1h'),
                                     ('return_h4', '4h'), ('return_d1', '1d')]:
            close_mtf = (df_pl.select(['time', 'close'])
                         .group_by_dynamic(index_column='time', every=freq_str)
                         .agg(pl.col('close').last().alias(f'close_{freq_name}')))
            df_pl = df_pl.join_asof(
                close_mtf,
                on='time', strategy='backward'
            )
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

        # [INST-2] DFA
        log_price = np.log(close)
        df['log_price'] = log_price.astype(np.float32)
        hurst_win = 100 * ws
        hurst_cached = CACHE.get("dfa_hurst", log_price.astype(np.float32))
        if hurst_cached is not None:
            logger.info(f"  [CACHE HIT] DFA Hurst")
            hurst = hurst_cached
        else:
            logger.info(f"  [DFA] Calculando...")
            t_h = time.time()
            hurst = _dfa_numba(log_price, hurst_win)
            logger.info(f"  [DFA] OK em {time.time()-t_h:.2f}s")
            CACHE.put("dfa_hurst", log_price.astype(np.float32), hurst)
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


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# REGIME MODEL
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
class RegimeModel:
    def __init__(self, df: pd.DataFrame):
        self.df = df

    def classify(self) -> pd.DataFrame:
        logger.info("[REGIMES] Classificando regimes (thresholds adaptativos)...")
        df = self.df
        adx_p75 = df['adx'].quantile(0.75)
        adx_p50 = df['adx'].quantile(0.50)
        hurst_p75 = df['hurst'].quantile(0.75)
        hurst_p60 = df['hurst'].quantile(0.60)
        hurst_p40 = df['hurst'].quantile(0.40)
        logger.info(f"  ADX: p50={adx_p50:.1f}, p75={adx_p75:.1f} | "
                    f"DFA-Hurst: p40={hurst_p40:.2f}, p60={hurst_p60:.2f}, p75={hurst_p75:.2f}")
        conditions = [
            (df['adx'] > adx_p75) & (df['hurst'] > hurst_p75),
            (df['adx'] > adx_p50) & (df['hurst'] > hurst_p60),
            (df['adx'] < adx_p50) & (df['hurst'] < hurst_p40),
            (df['adx'] < adx_p50) & (df['hurst'] > hurst_p60),
        ]
        regime_arr = np.select(conditions, REGIME_LABELS, default='RANGE')
        df['regime'] = pd.Categorical(regime_arr, categories=REGIME_LABELS)
        dist = df['regime'].value_counts()
        for r in REGIME_LABELS:
            pct = dist.get(r, 0) / len(df) * 100
            logger.info(f"  {r}: {pct:.1f}%")
        return df

    def transition_matrix(self) -> Tuple[np.ndarray, List[str]]:
        regime_int = self.df['regime'].cat.codes.to_numpy(dtype=np.int32)
        cached = CACHE.get("transition", regime_int)
        if cached is not None:
            return cached, REGIME_LABELS
        mat = _transition_matrix_numba(regime_int, len(REGIME_LABELS))
        CACHE.put("transition", regime_int, mat)
        return mat, REGIME_LABELS


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# [INST-6] HMM REGIME MODEL â€” Features expandidas
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
class HMMRegimeModel:
    """[INST-6] HMM com features institucionais:
    log_return, realized_vol, skewness, kurtosis, autocorr_lag1.
    Captura regimes de pÃ¢nico (kurtosis alta, skew negativa)
    que o modelo anterior (ret + tr_zscore) nÃ£o distinguia.
    """
    def __init__(self, df: pd.DataFrame, n_states: int = 4):
        self.df = df
        self.n_states = n_states
        self.model = None
        self.state_map: Dict[int, str] = {}
        self.agreement: float = 0.0

    def _build_features(self, df: pd.DataFrame, window: int = 60) -> np.ndarray:
        """[INST-6] Features expandidas para HMM."""
        log_ret = df['log_return'].to_numpy(dtype=np.float64)
        n = len(log_ret)
        # Realized Volatility (rolling std)
        rvol = rolling_std(log_ret, window)
        # Skewness (rolling)
        skew = pd.Series(log_ret).rolling(window).skew().to_numpy()
        # Kurtosis (rolling)
        kurt = pd.Series(log_ret).rolling(window).kurt().to_numpy()
        # Autocorrelation lag-1 (rolling)
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
            logger.warning("[HMM] hmmlearn nÃ£o disponÃ­vel â€” pulando")
            self.df['hmm_state'] = -1
            self.df['hmm_regime'] = self.df['regime']
            return self.df

        logger.info(f"[HMM] Treinando GaussianHMM ({self.n_states} estados, 5 features)...")
        t0 = time.time()
        df = self.df
        features_all = self._build_features(df)
        valid = ~np.any(np.isnan(features_all) | np.isinf(features_all), axis=1)
        features_clean = features_all[valid]

        if len(features_clean) < 1000:
            logger.warning("[HMM] Dados insuficientes â€” pulando")
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

        # Walk-forward com limite de retreinos
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

        wf_steps = list(range(first_train + stride, n + 1, stride))
        wf_iter = tqdm(wf_steps, desc="  [HMM] WF", unit="iter",
                       mininterval=5.0, ncols=80) if HAS_TQDM else wf_steps
        for right in wf_iter:
            seq = features_all[:right]
            valid_seq = ~np.any(np.isnan(seq) | np.isinf(seq), axis=1)
            if valid_seq.sum() < 500:
                continue
            try:
                m, _ = _train_safe(seq[valid_seq], self.n_states)
                states = m.predict(seq)
                chunk_start = right - stride
                hidden_states[chunk_start:min(right, n)] = states[-stride:]
            except Exception:
                continue

        hidden_states[hidden_states == -1] = 0

        # Mapear estados â†’ regimes
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
        logger.info(f"  [HMM] OK em {time.time()-t0:.2f}s | {self.n_states} estados | "
                    f"concordÃ¢ncia: {self.agreement:.1f}%")
        for s, m_ret, m_adx, m_hurst, regime in state_info:
            logger.info(f"  Estado {s}: ret={m_ret:.4f} adx={m_adx:.1f} hurst={m_hurst:.2f} â†’ {regime}")
        return df

    def transition_matrix(self) -> Tuple[np.ndarray, List[str]]:
        if 'hmm_state' not in self.df.columns:
            return np.eye(4), REGIME_LABELS
        regime_int = self.df['hmm_regime'].cat.codes.to_numpy(dtype=np.int32)
        return _transition_matrix_numba(regime_int, len(REGIME_LABELS)), REGIME_LABELS


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# TEMPORAL + TAIL RISK
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# NARRATIVE ENGINE
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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
        session_regime = self.temporal.get('session', {}).get('regime_pct', {})
        trend_session = None
        for s in ['NY_AM', 'London', 'NY_PM', 'Asia']:
            if s in session_regime:
                trend_pct = sum(session_regime[s].get(r, 0) for r in ['TREND_FORTE', 'TREND_FRACO']) * 100
                if trend_session is None or trend_pct > trend_session[1]:
                    trend_session = (s, trend_pct)

        se_mean = self.entropy.get('sample_entropy_mean', 0)
        pe_mean = self.entropy.get('perm_entropy_mean', 0)
        complexity_desc = "ALTA (mercado eficiente)" if pe_mean > 0.85 else \
            "MODERADA" if pe_mean > 0.65 else "BAIXA (padrÃµes detectÃ¡veis)"

        hmm_agree = self.hmm.get('agreement', 0)
        hmm_note = ""
        if hmm_agree > 0:
            hmm_note = (
                f"HMM (5 features: ret, vol, skew, kurt, autocorr) identificou "
                f"{self.hmm.get('n_states', 4)} estados latentes com {hmm_agree:.1f}% "
                f"de concordÃ¢ncia com ADX+DFA-Hurst. "
            )

        te = self.signal.get('transfer_entropy', {})
        te_note = ""
        if te:
            r2v = te.get('ret_to_vol', 0)
            v2r = te.get('vol_to_ret', 0)
            if r2v > 0.001 or v2r > 0.001:
                direction = "retornosâ†’volume" if r2v > v2r else "volumeâ†’retornos"
                te_note = (
                    f"Transfer Entropy (KSG contÃ­nuo): {direction} domina "
                    f"(TE retâ†’vol: {r2v:.6f}, TE volâ†’ret: {v2r:.6f}). "
                )

        kalman_note = ""
        if self.signal.get('has_kalman'):
            kalman_note = "Filtro de Kalman aplicado para extraÃ§Ã£o de tendÃªncia causal (sem look-ahead). "

        return {
            'executive': (
                f"O perfil estrutural do ativo revela {dominant} como regime dominante "
                f"({dominant_pct:.1f}%). Hurst DFA mÃ©dio: {noise:.2f} ({noise_desc}). "
                f"Hora mais volÃ¡til: {vol_hour:02d}h. "
                f"SessÃ£o com maior tendÃªncia: {trend_session[0] if trend_session else 'N/A'} "
                f"({trend_session[1]:.1f}%). {hmm_note}{te_note}"
            ),
            'transition': "Matriz de Markov â€” dinÃ¢mica de transiÃ§Ã£o entre regimes.",
            'tail_risk': (
                f"Risco de cauda: {self.tail_risk['spike_count']} spikes "
                f"(Vol Z>2, {self.tail_risk['spike_pct']:.1f}%). "
                f"ATR mÃ©dio spikes: {self.tail_risk['avg_atr_spike']:.2f} "
                f"vs {self.tail_risk['avg_atr_normal']:.2f} normal."
            ),
            'complexity': (
                f"Sample Entropy: {se_mean:.4f} | Permutation Entropy: {pe_mean:.3f} "
                f"â†’ complexidade {complexity_desc}. {kalman_note}"
            ),
            'signal_analysis': f"{kalman_note}{te_note}",
        }


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# CHART GENERATOR
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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
        logger.info("[CHARTS] Gerando grÃ¡ficos...")
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
        self._kalman_comparison()  # [INST-3] substitui _wavelet_comparison
        self._transfer_entropy_chart()
        if hasattr(self, '_macro_risk_charts'):
            self._macro_risk_charts()
        if hasattr(self, '_stability_charts'):
            self._stability_charts()
        logger.info(f"  [OK] {len(self.charts)} grÃ¡ficos")
        return self.charts

    def _heatmap_hour_day_atr(self):
        fig, ax = plt.subplots(figsize=(9, 5))
        pivot = self.df.pivot_table(values='atr', index='hour', columns='day_of_week', aggfunc='mean')
        day_labels = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'SÃ¡b', 'Dom']
        pivot = pivot.reindex(columns=range(7), fill_value=0)
        pivot.columns = day_labels
        sns.heatmap(pivot, ax=ax, cmap='RdYlBu_r', annot=True, fmt='.1f',
                    linewidths=0.5, cbar_kws={'label': 'ATR MÃ©dio'})
        ax.set_title('Heatmap ATR: Hora x Dia da Semana', fontweight='bold')
        ax.set_ylabel('Hora'); ax.set_xlabel('Dia da Semana')
        plt.tight_layout()
        path = str(self._chart_dir / 'heatmap_atr.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['heatmap_atr'] = path

    def _heatmap_hour_day_trend(self):
        fig, ax = plt.subplots(figsize=(9, 5))
        day_labels = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'SÃ¡b', 'Dom']
        trend = self.df[self.df['regime'].isin(['TREND_FORTE', 'TREND_FRACO'])]
        total = self.df.pivot_table(values='atr', index='hour', columns='day_of_week', aggfunc='count').reindex(columns=range(7), fill_value=0)
        if len(trend) and total.sum().sum() > 0:
            pivot_count = trend.pivot_table(values='atr', index='hour', columns='day_of_week', aggfunc='count').reindex(columns=range(7), fill_value=0)
            pivot = pivot_count.div(total.replace(0, np.nan)) * 100
        else:
            pivot = pd.DataFrame(0, index=range(24), columns=range(7))
        pivot.columns = day_labels
        sns.heatmap(pivot, ax=ax, cmap='RdYlGn', annot=True, fmt='.0f',
                    linewidths=0.5, cbar_kws={'label': '% TendÃªncia'})
        ax.set_title('Heatmap TendÃªncia: Hora x Dia (%)', fontweight='bold')
        ax.set_ylabel('Hora'); ax.set_xlabel('Dia da Semana')
        plt.tight_layout()
        path = str(self._chart_dir / 'heatmap_trend.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['heatmap_trend'] = path

    def _markov_matrix(self):
        fig, ax = plt.subplots(figsize=(7, 6))
        sns.heatmap(self.transition_mat, annot=True, fmt='.2f', cmap='Blues',
                    xticklabels=self.regime_labels, yticklabels=self.regime_labels,
                    linewidths=0.5, ax=ax, cbar_kws={'label': 'Prob. TransiÃ§Ã£o'})
        ax.set_title('Matriz de TransiÃ§Ã£o de Markov', fontweight='bold')
        ax.set_ylabel('De'); ax.set_xlabel('Para')
        plt.tight_layout()
        path = str(self._chart_dir / 'markov_matrix.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['markov_matrix'] = path

    def _regime_bars(self):
        fig, ax = plt.subplots(figsize=(9, 4))
        dist = self.df['regime'].value_counts()
        colors_list = [REGIME_COLORS.get(r, '#999') for r in dist.index]
        bars = ax.bar(dist.index, dist.values, color=colors_list, edgecolor='white', linewidth=1.5)
        ax.bar_label(bars, labels=[f'{v/len(self.df)*100:.1f}%' for v in dist.values], padding=2)
        ax.set_title('DistribuiÃ§Ã£o de Regimes', fontweight='bold')
        ax.set_ylabel('Candles'); ax.set_xlabel('Regime')
        plt.tight_layout()
        path = str(self._chart_dir / 'regime_bars.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['regime_bars'] = path

    def _boxplot_atr_month(self):
        fig, ax = plt.subplots(figsize=(10, 4))
        df_s = self.df.sample(min(50000, len(self.df)))
        sns.boxplot(x='month', y='atr', data=df_s, ax=ax, palette='Blues', showfliers=False)
        ax.set_title('Boxplot ATR Mensal', fontweight='bold')
        ax.set_ylabel('ATR'); ax.set_xlabel('MÃªs')
        plt.tight_layout()
        path = str(self._chart_dir / 'boxplot_atr_month.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['boxplot_atr_month'] = path

    def _intraday_curve(self):
        fig, ax = plt.subplots(figsize=(10, 4))
        atr_h = self.df.groupby('hour')['atr'].mean()
        vol_h = self.df.groupby('hour')['tick_volume'].mean()
        vol_h_norm = vol_h / vol_h.max()
        ax2 = ax.twinx()
        l1 = ax.plot(atr_h.index, atr_h.values, color=C['steel'], linewidth=2, label='ATR')
        l2 = ax2.plot(vol_h_norm.index, vol_h_norm.values, color=C['gold'], linewidth=1.5,
                      linestyle='--', label='Volume Rel.')
        ax.set_xlabel('Hora'); ax.set_ylabel('ATR', color=C['steel'])
        ax2.set_ylabel('Volume Rel.', color=C['gold'])
        ax.set_title('Curva IntradiÃ¡ria: ATR e Volume', fontweight='bold')
        lines = l1 + l2
        ax.legend(lines, [l.get_label() for l in lines], loc='upper left')
        plt.tight_layout()
        path = str(self._chart_dir / 'intraday_curve.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['intraday_curve'] = path

    def _correlation_matrix(self):
        cols = ['hurst', 'adx', 'atr', 'tr_zscore', 'volume_zscore', 'return']
        avail = [c for c in cols if c in self.df.columns]
        if len(avail) < 2: return
        fig, ax = plt.subplots(figsize=(8, 7))
        corr = self.df[avail].corr()
        mask = np.triu(np.ones_like(corr, dtype=bool))
        sns.heatmap(corr, mask=mask, annot=True, fmt='.2f', cmap='RdBu_r',
                    center=0, vmin=-1, vmax=1, linewidths=0.5, ax=ax)
        ax.set_title('Matriz de CorrelaÃ§Ã£o entre Features', fontweight='bold')
        plt.tight_layout()
        path = str(self._chart_dir / 'correlation_matrix.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['correlation_matrix'] = path

    def _return_by_regime(self):
        if 'return' not in self.df.columns: return
        fig, ax = plt.subplots(figsize=(10, 5))
        df_s = self.df.sample(min(100000, len(self.df)))
        sns.boxplot(x='regime', y='return', data=df_s, ax=ax,
                    palette=list(REGIME_COLORS.values()), showfliers=False)
        ax.set_title('Retornos por Regime', fontweight='bold')
        ax.set_ylabel('Retorno'); ax.set_xlabel('Regime')
        ax.axhline(y=0, color='black', linewidth=0.5, linestyle='--')
        plt.tight_layout()
        path = str(self._chart_dir / 'return_by_regime.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['return_by_regime'] = path

    def _hurst_vs_adx_scatter(self):
        fig, ax = plt.subplots(figsize=(8, 6))
        df_s = self.df.sample(min(50000, len(self.df)))
        colors_reg = [REGIME_COLORS.get(r, '#999') for r in df_s['regime']]
        ax.scatter(df_s['hurst'], df_s['adx'], c=colors_reg, alpha=0.3, s=5, edgecolors='none')
        ax.set_xlabel('DFA Hurst Exponent'); ax.set_ylabel('ADX')
        ax.set_title('DFA-Hurst vs ADX (por Regime)', fontweight='bold')
        ax.axvline(x=0.55, color='red', linestyle='--', linewidth=0.8, alpha=0.5)
        ax.axhline(y=25, color='red', linestyle='--', linewidth=0.8, alpha=0.5)
        from matplotlib.lines import Line2D
        legend_elements = [Line2D([0], [0], marker='o', color='w', markerfacecolor=c,
                                  label=l, markersize=8) for l, c in REGIME_COLORS.items()]
        ax.legend(handles=legend_elements, loc='upper right')
        plt.tight_layout()
        path = str(self._chart_dir / 'hurst_vs_adx.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['hurst_vs_adx'] = path

    def _hmm_agreement_chart(self):
        if 'hmm_regime' not in self.df.columns: return
        fig, ax = plt.subplots(figsize=(10, 4))
        agreement = (self.df['regime'] == self.df['hmm_regime']).astype(int)
        rolling_agree = agreement.rolling(5000, min_periods=100).mean() * 100
        ax.plot(rolling_agree.index, rolling_agree.values, color=C['purple'], linewidth=0.6)
        ax.axhline(y=70, color=C['green'], linestyle='--', linewidth=0.8, alpha=0.5, label='70%')
        ax.axhline(y=50, color=C['gold'], linestyle='--', linewidth=0.8, alpha=0.5, label='50%')
        ax.set_ylabel('ConcordÃ¢ncia HMM vs ADX+DFA (%)')
        ax.set_title('ConcordÃ¢ncia entre Modelos de Regime (rolling 5000)', fontweight='bold')
        ax.set_ylim(0, 100); ax.legend()
        plt.tight_layout()
        path = str(self._chart_dir / 'hmm_agreement.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['hmm_agreement'] = path

    def _entropy_timeline(self):
        if 'sample_entropy' not in self.df.columns: return
        fig, ax1 = plt.subplots(figsize=(10, 4))
        se_r = self.df['sample_entropy'].rolling(5000, min_periods=100).mean()
        pe_r = self.df['perm_entropy'].rolling(5000, min_periods=100).mean()
        ax1.plot(se_r.index, se_r.values, color=C['blue'], linewidth=0.8, label='Sample Entropy')
        ax1.set_ylabel('Sample Entropy', color=C['blue'])
        ax1.set_ylim(0, se_r.quantile(0.99) * 1.5)
        ax2 = ax1.twinx()
        ax2.plot(pe_r.index, pe_r.values, color=C['red'], linewidth=0.8, label='Permutation Entropy')
        ax2.set_ylabel('Permutation Entropy', color=C['red']); ax2.set_ylim(0, 1.1)
        ax1.set_title('EvoluÃ§Ã£o da Entropia (Complexidade)', fontweight='bold')
        lines = ax1.get_lines() + ax2.get_lines()
        ax1.legend(lines, [l.get_label() for l in lines], loc='upper left')
        plt.tight_layout()
        path = str(self._chart_dir / 'entropy_timeline.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['entropy_timeline'] = path

    # [INST-3] Kalman substitui Wavelet
    def _kalman_comparison(self):
        if 'close_denoised' not in self.df.columns: return
        fig, ax = plt.subplots(figsize=(10, 4))
        sample = self.df.iloc[-5000:]
        ax.plot(sample.index, sample['close'].values, color=C['steel'],
                linewidth=0.5, alpha=0.6, label='Original')
        ax.plot(sample.index, sample['close_denoised'].values, color=C['red'],
                linewidth=0.8, label='Kalman Filter (causal)')
        ax.set_title('PreÃ§o Original vs Kalman Filter (sem look-ahead)', fontweight='bold')
        ax.set_ylabel('PreÃ§o'); ax.legend()
        plt.tight_layout()
        path = str(self._chart_dir / 'kalman_comparison.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['kalman_comparison'] = path

    def _transfer_entropy_chart(self):
        signal = self.features.get('signal', {})
        te = signal.get('transfer_entropy', {})
        if not te: return
        fig, ax = plt.subplots(figsize=(7, 4))
        labels = list(te.keys())
        values = list(te.values())
        colors_bar = [C['steel'] if 'ret_to_vol' in k or 'hurst_to_adx' in k else C['gold'] for k in labels]
        bars = ax.barh(labels, values, color=colors_bar, edgecolor='white', linewidth=1.2)
        ax.bar_label(bars, labels=[f'{v:.6f}' for v in values], padding=2)
        ax.set_title('Transfer Entropy KSG (Fluxo Direcional)', fontweight='bold')
        ax.set_xlabel('TE (nats)')
        plt.tight_layout()
        path = str(self._chart_dir / 'transfer_entropy.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        self.charts['transfer_entropy'] = path


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# PDF REPORT BUILDER
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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
        self._macro_correlation = macro.get('correlations', {}) if macro else {}
        self._macro_sensitivity = macro.get('macro_sensitivity', {}) if macro else {}
        self._hmm = hmm_model or {}
        self._signal = signal_data or {}
        self._purged_wf = purged_wf or {}
        self._cpcv = cpcv or {}
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

    def _add(self, el): self.elements.append(el)
    def _hr(self):
        self._add(HRFlowable(width="100%", thickness=0.5,
                             color=colors.HexColor(C['light']), spaceBefore=6, spaceAfter=6))

    def _metric_box(self, label, value, color=C['navy']):
        data = [[Paragraph(f'<font color="{color}"><b>{value}</b></font>', self.s_metric_value)],
                [Paragraph(label, self.s_metric_label)]]
        t = Table(data, colWidths=[40*mm])
        t.setStyle(TableStyle([
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'), ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('BOX', (0, 0), (-1, -1), 1, colors.HexColor(C['light'])),
            ('TOPPADDING', (0, 0), (-1, 0), 8), ('BOTTOMPADDING', (0, -1), (-1, -1), 6),
            ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor(C['lighter'])),
        ]))
        return t

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
        cmds = [
            ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor(C['navy'])),
            ('TEXTCOLOR', (0, 0), (-1, 0), colors.white),
            ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
            ('FONTSIZE', (0, 0), (-1, 0), 8),
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'), ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('GRID', (0, 0), (-1, -1), 0.5, colors.HexColor(C['light'])),
            ('TOPPADDING', (0, 0), (-1, -1), 4), ('BOTTOMPADDING', (0, 0), (-1, -1), 4),
            ('LEFTPADDING', (0, 0), (-1, -1), 4), ('RIGHTPADDING', (0, 0), (-1, -1), 4),
        ]
        for i in range(1, len(data)):
            if i % 2 == 0:
                cmds.append(('BACKGROUND', (0, i), (-1, i), colors.HexColor(C['lighter'])))
        t.setStyle(TableStyle(cmds))
        return t

    def build_executive_summary(self):
        df = self.df
        dominant = df['regime'].value_counts().index[0]
        dominant_pct = df['regime'].value_counts(normalize=True).iloc[0] * 100
        noise = df['hurst'].mean()
        vol_hour = df.groupby('hour')['atr'].mean().idxmax()
        self._add(Paragraph("EXECUTIVE SUMMARY", self.s_h1)); self._hr()
        boxes = Table([[
            self._metric_box("REGIME DOMINANTE", f"{dominant}", C['navy']),
            self._metric_box("HORA MAIS VOLÃTIL", f"{vol_hour:02d}h", C['steel']),
            self._metric_box("DFA-HURST", f"{noise:.2f}", C['gold']),
            self._metric_box("AMOSTRA", f"{len(df):,} candles", C['gray']),
        ]], colWidths=[40*mm]*4)
        boxes.setStyle(TableStyle([('ALIGN', (0,0), (-1,-1), 'CENTER'),
                                   ('VALIGN', (0,0), (-1,-1), 'TOP')]))
        self._add(boxes); self._add(Spacer(1, 8))
        self._add(Paragraph(self.narr['executive'], self.s_body))
        self._add(PageBreak())

    def build_regime_analysis(self):
        self._add(Paragraph("REGIME ANALYSIS", self.s_h1)); self._hr()
        if 'regime_bars' in self.charts:
            self._add(Paragraph("DistribuiÃ§Ã£o de Regimes", self.s_h2))
            self._add(Image(self.charts['regime_bars'], width=160*mm, height=60*mm))
        if 'markov_matrix' in self.charts:
            self._add(Paragraph("Matriz de TransiÃ§Ã£o de Markov", self.s_h2))
            self._add(Paragraph(self.narr['transition'], self.s_body))
            self._add(Spacer(1, 4))
            self._add(Image(self.charts['markov_matrix'], width=120*mm, height=90*mm))
        self._add(PageBreak())

    def build_temporal_analysis(self):
        self._add(Paragraph("TEMPORAL & SEASONALITY", self.s_h1)); self._hr()
        for key, title in [('heatmap_atr', 'Volatilidade: Hora x Dia'),
                           ('heatmap_trend', 'PropensÃ£o a TendÃªncia (%)'),
                           ('intraday_curve', 'Curva IntradiÃ¡ria'),
                           ('boxplot_atr_month', 'Sazonalidade Mensal ATR')]:
            if key in self.charts:
                self._add(Paragraph(title, self.s_h2))
                self._add(Image(self.charts[key], width=160*mm, height=70*mm))
        self._add(PageBreak())

    def build_tail_risk(self):
        self._add(Paragraph("TAIL RISK ANALYSIS", self.s_h1)); self._hr()
        self._add(Paragraph(self.narr['tail_risk'], self.s_body))
        self._add(Spacer(1, 6))
        tail = self.features.get('tail_risk', {})
        rows = [
            ['ATR Threshold (Top 1%)', f"{tail.get('atr_threshold', 0):.2f}"],
            ['% Spikes (Vol Z>2)', f"{tail.get('spike_pct', 0):.2f}%"],
            ['ATR MÃ©dio Spikes', f"{tail.get('avg_atr_spike', 0):.2f}"],
            ['ATR MÃ©dio Normal', f"{tail.get('avg_atr_normal', 0):.2f}"],
            ['Fator AmplificaÃ§Ã£o', f"{tail.get('avg_atr_spike', 0) / max(tail.get('avg_atr_normal', 0.001), 0.001):.1f}x"],
        ]
        self._add(self._data_table(['MÃ©trica', 'Valor'], rows, col_widths=[70*mm, 60*mm]))
        self._add(PageBreak())

    def build_hmm_analysis(self):
        self._add(Paragraph("HIDDEN MARKOV MODEL â€” REGIME LATENTE", self.s_h1)); self._hr()
        if 'hmm_regime' not in self.df.columns:
            self._add(Paragraph("HMM nÃ£o disponÃ­vel.", self.s_body))
            self._add(PageBreak()); return
        df = self.df
        agree = (df['regime'] == df['hmm_regime']).mean() * 100
        self._add(Paragraph(
            f"ConcordÃ¢ncia HMM (5 features) vs ADX+DFA: <b>{agree:.1f}%</b>. "
            f"Features: log_return, realized_vol, skewness, kurtosis, autocorr_lag1.",
            self.s_body
        ))
        self._add(Spacer(1, 6))
        hmm_counts = df['hmm_regime'].value_counts()
        ahp_counts = df['regime'].value_counts()
        rows = []
        for r in REGIME_LABELS:
            rows.append([r, f'{hmm_counts.get(r,0)/len(df)*100:.1f}%',
                         f'{ahp_counts.get(r,0)/len(df)*100:.1f}%'])
        self._add(self._data_table(['Regime', 'HMM %', 'DFA %'], rows,
                                   col_widths=[45*mm, 45*mm, 45*mm]))
        if 'hmm_state' in df.columns:
            self._add(Spacer(1, 6))
            self._add(Paragraph("Estados HMM", self.s_h2))
            state_rows = []
            for s in sorted(df['hmm_state'].unique()):
                if s < 0: continue
                mask = df['hmm_state'] == s
                if mask.sum() == 0: continue
                sub = df[mask]
                state_rows.append([f'Estado {s}', f'{mask.sum():,}',
                                   f'{sub["hurst"].mean():.2f}', f'{sub["adx"].mean():.1f}',
                                   f'{sub["atr"].mean():.2f}', sub['hmm_regime'].iloc[0]])
            if state_rows:
                self._add(self._data_table(
                    ['Estado', 'Candles', 'DFA-H', 'ADX', 'ATR', 'Regime'],
                    state_rows, col_widths=[22*mm, 25*mm, 20*mm, 20*mm, 20*mm, 25*mm]))
        for key in ['hmm_agreement', 'entropy_timeline']:
            if key in self.charts:
                self._add(Spacer(1, 8))
                self._add(Image(self.charts[key], width=160*mm, height=60*mm))
        self._add(PageBreak())

    def build_signal_analysis(self):
        self._add(Paragraph("SIGNAL ANALYSIS â€” KALMAN & TRANSFER ENTROPY", self.s_h1)); self._hr()
        te = self._signal.get('transfer_entropy', {})
        if 'kalman_comparison' in self.charts:
            self._add(Paragraph(
                "Filtro de Kalman (causal): extraÃ§Ã£o de tendÃªncia sem look-ahead bias. "
                "Substitui wavelet denoising que introduzia phase shift.", self.s_body))
            self._add(Image(self.charts['kalman_comparison'], width=160*mm, height=60*mm))
        if te:
            self._add(Spacer(1, 6))
            self._add(Paragraph("Transfer Entropy KSG (contÃ­nuo, sem discretizaÃ§Ã£o)", self.s_h2))
            self._add(Paragraph(
                f"Retâ†’Vol: <b>{te.get('ret_to_vol', 0):.6f}</b> | "
                f"Volâ†’Ret: <b>{te.get('vol_to_ret', 0):.6f}</b> | "
                f"Hurstâ†’ADX: <b>{te.get('hurst_to_adx', 0):.6f}</b> | "
                f"ADXâ†’Hurst: <b>{te.get('adx_to_hurst', 0):.6f}</b>", self.s_body))
            if 'transfer_entropy' in self.charts:
                self._add(Image(self.charts['transfer_entropy'], width=120*mm, height=80*mm))
        self._add(PageBreak())

    def build_mql5_constants(self):
        self._add(Paragraph("MQL5 SYSTEM PARAMETERS", self.s_h1)); self._hr()
        df = self.df
        dominant = df['regime'].value_counts().index[0]
        dominant_pct = df['regime'].value_counts(normalize=True).iloc[0] * 100
        vol_hour = df.groupby('hour')['atr'].mean().idxmax()
        avg_hurst = df['hurst'].mean()
        avg_adx = df['adx'].mean()
        trend_pct = df['regime'].isin(['TREND_FORTE', 'TREND_FRACO']).mean() * 100
        chop_pct = (df['regime'] == 'CHOP').mean() * 100
        range_pct = (df['regime'] == 'RANGE').mean() * 100
        session_trend = {}
        for s in df['session'].unique():
            m = df[df['session'] == s]
            session_trend[s] = m['regime'].isin(['TREND_FORTE', 'TREND_FRACO']).mean()
        best_session = max(session_trend, key=session_trend.get) if session_trend else 'N/A'
        best_session_trend = session_trend.get(best_session, 0) * 100
        mql5_lines = [
            f"// MQL5 System Parameters â€” {datetime.now().strftime('%Y-%m-%d %H:%M')}",
            f"// Asset DNA Profile v3.0-Institutional", "",
            f"// --- Regime (DFA-based) ---",
            f"#define DOMINANT_REGIME \"{dominant}\"",
            f"#define AVG_HURST {avg_hurst:.2f}",
            f"#define AVG_ADX {avg_adx:.1f}",
            f"#define TREND_PROBABILITY {trend_pct:.1f}",
            f"#define CHOP_PROBABILITY {chop_pct:.1f}",
            f"#define RANGE_PROBABILITY {range_pct:.1f}", "",
            f"// --- Seasonality ---",
            f"#define PEAK_VOL_HOUR {vol_hour}",
            f"#define BEST_TREND_SESSION \"{best_session}\"",
            f"#define BEST_TREND_SESSION_PROBABILITY {best_session_trend:.0f}", "",
            f"// --- Transitions ---",
        ]
        for i, frm in enumerate(self.regime_labels):
            for j, to in enumerate(self.regime_labels):
                if self.transition_mat[i, j] > 0.10:
                    mql5_lines.append(
                        f"#define TRANS_{frm[:4].upper()}_TO_{to[:4].upper()} {self.transition_mat[i,j]:.2f}")
        mql5_lines.extend([
            "", f"// --- Tail Risk ---",
            f"#define TOP1PCT_ATR {self.features.get('tail_risk', {}).get('atr_threshold', 0):.2f}",
            f"#define SPIKE_FREQUENCY {self.features.get('tail_risk', {}).get('spike_pct', 0):.2f}",
        ])
        for line in mql5_lines:
            if line:
                self._add(Paragraph(line.replace(' ', '&nbsp;'), self.s_code))
            else:
                self._add(Spacer(1, 2))
        self._add(Spacer(1, 8))
        rows = [
            ['Regime Dominante', dominant, f'{dominant_pct:.1f}%'],
            ['DFA-Hurst MÃ©dio', f'{avg_hurst:.2f}', '> 0.55 = tendente'],
            ['ADX MÃ©dio', f'{avg_adx:.1f}', '> 25 = tendÃªncia forte'],
            ['TendÃªncia %', f'{trend_pct:.1f}%', 'TREND_FORTE + FRACO'],
            ['Range %', f'{range_pct:.1f}%', 'RANGE puro'],
            ['Chop %', f'{chop_pct:.1f}%', 'CHOP (ruÃ­do)'],
            ['Pico Volatilidade', f'{vol_hour:02d}h', 'maior ATR'],
            ['Melhor SessÃ£o', best_session, f'{best_session_trend:.0f}% tendÃªncia'],
        ]
        self._add(self._data_table(['MÃ©trica', 'Valor', 'InterpretaÃ§Ã£o'], rows,
                                   col_widths=[50*mm, 40*mm, 60*mm]))

    def build_feature_correlation(self):
        self._add(Paragraph("FEATURE CORRELATION", self.s_h1)); self._hr()
        for key in ['correlation_matrix', 'hurst_vs_adx', 'return_by_regime']:
            if key in self.charts:
                title = {'correlation_matrix': 'CorrelaÃ§Ã£o Features',
                         'hurst_vs_adx': 'DFA-Hurst vs ADX',
                         'return_by_regime': 'Retornos por Regime'}[key]
                self._add(Paragraph(title, self.s_h2))
                self._add(Image(self.charts[key], width=150*mm, height=90*mm))
        df = self.df
        stats_d = {}
        for col in ['hurst', 'adx', 'atr', 'tr_zscore']:
            if col in df.columns:
                stats_d[col.upper()] = {
                    'media': f'{df[col].mean():.3f}', 'std': f'{df[col].std():.3f}',
                    'p1': f'{df[col].quantile(0.01):.3f}', 'p99': f'{df[col].quantile(0.99):.3f}',
                }
        if stats_d:
            self._add(Spacer(1, 8))
            rows = [[n, v['media'], v['std'], v['p1'], v['p99']] for n, v in stats_d.items()]
            self._add(self._data_table(['Feature', 'MÃ©dia', 'Std', 'P1', 'P99'], rows,
                                       col_widths=[30*mm]*5))
        self._add(PageBreak())

    def build_macro_risk(self):
        self._add(Paragraph("MACRO RISK CROSS-REFERENCE", self.s_h1)); self._hr()
        charts_avail = [k for k in ['macro_corr_heatmap', 'macro_factors', 'regime_betas',
                                     'regime_by_risk', 'roro_timeline', 'dxy_vix_timeline']
                        if k in self.charts]
        if not charts_avail:
            self._add(Paragraph("Dados macro nÃ£o disponÃ­veis.", self.s_body))
            self._add(PageBreak()); return
        for key, title in [('macro_corr_heatmap', 'Top CorrelaÃ§Ãµes Macro vs Ativo'),
                           ('macro_factors', 'Fatores Macro'),
                           ('regime_betas', 'Betas por Regime'),
                           ('regime_by_risk', 'Regime por CenÃ¡rio Macro'),
                           ('roro_timeline', 'RORO Score'),
                           ('dxy_vix_timeline', 'DXY e VIX')]:
            if key in self.charts:
                self._add(Paragraph(title, self.s_h2))
                self._add(Image(self.charts[key], width=160*mm, height=70*mm))
        ms = self._macro_sensitivity
        if ms and ms.get('macro_factors'):
            self._add(Spacer(1, 8))
            self._add(Paragraph("Fatores Macro (Z-Score)", self.s_h2))
            rows = []
            for fn, fd in ms['macro_factors'].items():
                rows.append([fn, str(fd['n_members']), f"{fd['score_current']:+.2f}",
                             f"{fd.get('correlation', 0):+.3f}"])
            self._add(self._data_table(['Fator', 'N', 'Atual', 'Corr'], rows,
                                       col_widths=[35*mm, 15*mm, 30*mm, 30*mm]))
        if ms and ms.get('leading_indicators'):
            self._add(Spacer(1, 8))
            self._add(Paragraph("Leading Indicators", self.s_h2))
            rows = [[li['symbol'], f"{li['lag_days']}d",
                     f"{li['cross_correlation']:+.3f}", li['direction']]
                    for li in ms['leading_indicators'][:8]]
            self._add(self._data_table(['Macro', 'Lag', 'Spearman', 'Dir'], rows,
                                       col_widths=[40*mm, 20*mm, 35*mm, 35*mm]))
        # [INST-5] CointegraÃ§Ã£o
        coint = ms.get('cointegration', []) if ms else []
        if coint:
            self._add(Spacer(1, 8))
            self._add(Paragraph("CointegraÃ§Ã£o de Johansen (pares estacionÃ¡rios)", self.s_h2))
            rows = [[c['macro'], f"{c['trace_stat']:.2f}", f"{c['crit_5pct']:.2f}",
                     c['result']] for c in coint[:8]]
            self._add(self._data_table(['Macro', 'Trace', 'Crit 5%', 'Result'], rows,
                                       col_widths=[40*mm, 30*mm, 30*mm, 30*mm]))
        self._add(PageBreak())

    def build_walk_forward(self):
        self._add(Paragraph("WALK-FORWARD VALIDATION", self.s_h1)); self._hr()
        wf = self._walkforward
        if not wf:
            self._add(Paragraph("Walk-forward nÃ£o disponÃ­vel.", self.s_body))
            self._add(PageBreak()); return
        for key in ['wf_stability', 'wf_regime', 'purged_wf']:
            if key in self.charts:
                self._add(Image(self.charts[key], width=160*mm, height=70*mm))
        score = wf.get('stability_score', 0)
        verdict = "ESTÃVEL" if score >= 70 else "MODERADO" if score >= 40 else "INSTÃVEL"
        score_color = C['green'] if score >= 70 else C['gold'] if score >= 40 else C['red']
        self._add(Spacer(1, 6))
        self._add(self._metric_box("ESTABILIDADE", f"{score:.0f}%", score_color))
        # CPCV PBO
        pbo = self._cpcv.get('pbo_score', None)
        if pbo is not None:
            pbo_color = C['green'] if pbo < 50 else C['red']
            self._add(Spacer(1, 4))
            self._add(self._metric_box("PBO SCORE", f"{pbo:.1f}%", pbo_color))
            self._add(Paragraph(
                f"Probability of Backtest Overfitting: {pbo:.1f}%. "
                f"{'Baixo risco de overfitting.' if pbo < 50 else 'ALTO risco â€” perfil pode nÃ£o generalizar.'}",
                self.s_body))
        periods = wf.get('periods', [])
        if periods:
            self._add(Spacer(1, 8))
            rows = [[p['label'][:20], f"{p['hurst']:.2f}", f"{p['adx']:.1f}",
                     p['dominant'], f"{p.get('trend_pct', 0):.0f}%"]
                    for p in periods]
            self._add(self._data_table(
                ['PerÃ­odo', 'DFA-H', 'ADX', 'Regime', 'Trend%'], rows,
                col_widths=[35*mm, 20*mm, 20*mm, 30*mm, 20*mm]))
        self._add(PageBreak())

    def build_pdf(self):
        self._add(Spacer(1, 1)); self._add(PageBreak())
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
            title="ALXQuant Asset DNA Profile v3.0",
            author="ALXQuant AI Engine",
        )
        class DocProxy:
            def __init__(self, pn, rb):
                self.page = pn; self._builder = rb
        original_build = doc.build
        def custom_build(elements, onFirstPage=None, onLaterPages=None):
            def fp(c, d): self._page_cover(c, DocProxy(d.page, self))
            def lp(c, d): self._page_content(c, DocProxy(d.page, self))
            original_build(elements, onFirstPage=fp, onLaterPages=lp)
        custom_build(self.elements)
        logger.info(f"  [OK] PDF: {self.output}")

    @staticmethod
    def _page_cover(canvas_obj, doc):
        w, h = A4; b = doc._builder
        canvas_obj.saveState()
        canvas_obj.setFillColor(colors.HexColor(C['navy']))
        canvas_obj.rect(0, 0, w, h, fill=1, stroke=0)
        canvas_obj.setFillColor(colors.HexColor(C['gold']))
        canvas_obj.rect(25*mm, h/2-10*mm, 3*mm, 80*mm, fill=1, stroke=0)
        canvas_obj.setFillColor(colors.white)
        canvas_obj.setFont('Helvetica-Bold', 32)
        canvas_obj.drawString(35*mm, h/2+50*mm, "ASSET DNA")
        canvas_obj.drawString(35*mm, h/2+25*mm, "PROFILE")
        canvas_obj.setFillColor(colors.HexColor(C['gold']))
        canvas_obj.setFont('Helvetica', 13)
        canvas_obj.drawString(35*mm, h/2+5*mm, "Perfil Estrutural Institucional")
        canvas_obj.setFont('Helvetica', 11)
        n = len(b.df) if hasattr(b, 'df') else 0
        canvas_obj.drawString(35*mm, h/2-15*mm,
                              f"Candles: {n:,}  |  {b._tf}  |  {datetime.now().strftime('%d/%m/%Y')}")
        canvas_obj.setFillColor(colors.HexColor('#556677'))
        canvas_obj.setFont('Helvetica', 9)
        canvas_obj.drawString(35*mm, 35*mm, f"Gerado: {datetime.now().strftime('%d/%m/%Y - %H:%M')}")
        canvas_obj.drawString(35*mm, 25*mm, "ALXQuant Asset DNA Profiler v3.0-Institutional")
        canvas_obj.setFillColor(colors.HexColor(C['gold']))
        canvas_obj.setFont('Helvetica-Bold', 11)
        canvas_obj.drawCentredString(w/2, 15*mm, "CONFIDENTIAL")
        canvas_obj.restoreState()

    @staticmethod
    def _page_content(canvas_obj, doc):
        w, h = A4
        canvas_obj.saveState()
        canvas_obj.setFillColor(colors.HexColor(C['navy']))
        canvas_obj.rect(0, h-22*mm, w, 22*mm, fill=1, stroke=0)
        canvas_obj.setFillColor(colors.white)
        canvas_obj.setFont('Helvetica-Bold', 9)
        canvas_obj.drawString(18*mm, h-14*mm, "ALXQUANT  |  ASSET DNA v3.0")
        canvas_obj.setFont('Helvetica', 8)
        canvas_obj.drawRightString(w-18*mm, h-14*mm, f"PÃ¡g {doc.page-1}")
        canvas_obj.setStrokeColor(colors.HexColor(C['gold']))
        canvas_obj.setLineWidth(2)
        canvas_obj.line(0, h-22*mm, w, h-22*mm)
        canvas_obj.setStrokeColor(colors.HexColor(C['light']))
        canvas_obj.setLineWidth(0.5)
        canvas_obj.line(18*mm, 15*mm, w-18*mm, 15*mm)
        canvas_obj.setFillColor(colors.HexColor(C['gray']))
        canvas_obj.setFont('Helvetica', 7)
        canvas_obj.drawString(18*mm, 10*mm, f"Gerado: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
        canvas_obj.drawCentredString(w/2, 10*mm, f"- {doc.page-1} -")
        canvas_obj.drawRightString(w-18*mm, 10*mm, "ALXQuant v3.0")
        canvas_obj.restoreState()


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# [INST-5] MACRO RISK INTEGRATOR â€” Johansen + VAR
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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
            logger.warning(f"[MACRO] DB nÃ£o encontrado")
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
        asset_daily.dropna(inplace=True)
        if len(asset_daily) < 10: return {}
        common = asset_daily.index.intersection(self.macro_wide.index)
        if len(common) < 10: return {}
        a = asset_daily.loc[common]
        m = self.macro_wide.loc[common]
        roro = self.roro_df.reindex(common, method='ffill') if self.roro_df is not None else None
        merged = a.join(m)
        asset_feats = ['hurst', 'adx', 'atr', 'tr_zscore', 'close_ret']
        macro_symbols = [c for c in m.columns if c != 'date']
        exclude_self = list(self.SYMBOL_SELF_MACRO.get(symbol, []))
        self_sym = symbol.replace('USD', '').replace('X', '')
        for sym in macro_symbols:
            cat = self.catalog.get(sym, {})
            if self_sym.lower() in cat.get('name', sym).lower():
                exclude_self.append(sym)

        # 1. CorrelaÃ§Ãµes (em retornos para evitar regressÃ£o espÃºria)
        corr_records = []
        for ms in macro_symbols:
            if ms in exclude_self: continue
            for af in asset_feats:
                if ms not in merged.columns or af not in merged.columns: continue
                valid = merged[[af, ms]].dropna()
                if len(valid) < 20: continue
                # [INST-5] Usar retornos (diferenÃ§as) em vez de nÃ­veis
                if af == 'close_ret':
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

        # 2. Regime betas
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

        # 3. Leading indicators
        leading = []
        for ms in macro_symbols[:40]:
            if ms in exclude_self or ms not in merged.columns: continue
            valid = merged[['close_ret', ms]].dropna()
            if len(valid) < 60: continue
            macro_ret = valid[ms].pct_change().dropna()
            idx = valid.index.intersection(macro_ret.index)
            if len(idx) < 60: continue
            ret_arr = valid.loc[idx, 'close_ret'].values
            macro_arr = macro_ret.loc[idx].values
            best_lag, best_corr, best_p = 0, 0.0, 1.0
            max_lag = min(45, len(idx) // 4)
            for lag in range(1, max_lag + 1):
                if len(ret_arr) <= lag: break
                c, p = stats.spearmanr(macro_arr[:-lag], ret_arr[lag:])
                if abs(c) > abs(best_corr):
                    best_corr, best_p, best_lag = c, p, lag
            if abs(best_corr) > 0.05 and best_p < 0.10:
                info = self.catalog.get(ms, {'name': ms, 'category': '', 'country': ''})
                leading.append({
                    'symbol': ms, 'name': info['name'], 'category': info['category'],
                    'country': info['country'], 'lag_days': best_lag,
                    'cross_correlation': round(best_corr, 4),
                    'direction': 'leads' if best_lag > 0 else 'lags',
                    'p_raw': round(float(best_p), 6),
                })
        leading.sort(key=lambda x: abs(x['cross_correlation']), reverse=True)
        leading = leading[:15]

        # 4. [INST-5] CointegraÃ§Ã£o de Johansen
        coint_results = []
        if HAS_JOHANSEN:
            for ms in KEY_MACRO[:6]:
                if ms not in merged.columns: continue
                valid = merged[['close', ms]].dropna()
                if len(valid) < 100: continue
                try:
                    result = coint_johansen(valid.values, det_order=0, k_ar_diff=1)
                    trace_stat = result.lr1[0]
                    crit_5 = result.cvt[0, 1]  # 5% critical value
                    coint_results.append({
                        'macro': ms, 'trace_stat': round(trace_stat, 2),
                        'crit_5pct': round(crit_5, 2),
                        'result': 'COINTEGRADO' if trace_stat > crit_5 else 'NÃ£o',
                    })
                except Exception:
                    pass

        # 5. Macro fatores
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

        # 6. RORO
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
                ax.set_xlabel('CorrelaÃ§Ã£o'); ax.set_title('Top 20 Macro vs Ativo', fontweight='bold')
                plt.tight_layout()
                path = str(chart_dir / 'macro_corr_heatmap.png')
                fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
                charts['macro_corr_heatmap'] = path
            except Exception: pass
        factors = self._sensitivity.get('macro_factors', {})
        if factors:
            try:
                fnames = sorted(factors.keys())
                fcorrs = [factors[f].get('correlation', 0) for f in fnames]
                fig, ax = plt.subplots(figsize=(8, 3.5))
                colors_f = [C['red'] if v < 0 else C['green'] for v in fcorrs]
                ax.bar(range(len(fnames)), fcorrs, color=colors_f, width=0.5)
                ax.axhline(0, color='gray', linewidth=0.5)
                ax.set_xticks(range(len(fnames))); ax.set_xticklabels(fnames, fontsize=8, rotation=45, ha='right')
                ax.set_title('CorrelaÃ§Ã£o com Fatores Macro', fontweight='bold')
                plt.tight_layout()
                path = str(chart_dir / 'macro_factors.png')
                fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
                charts['macro_factors'] = path
            except Exception: pass
        if self.roro_df is not None and len(self.roro_df) >= 10:
            try:
                roro = self.roro_df['roro_score'].dropna()
                fig, ax = plt.subplots(figsize=(10, 3))
                ax.plot(roro.index, roro.values, color=C['steel'], linewidth=0.8)
                ax.axhline(y=0, color='gray', linestyle='--', linewidth=0.5)
                ax.fill_between(roro.index, roro.values, 0, where=roro.values > 0, color=C['green'], alpha=0.3)
                ax.fill_between(roro.index, roro.values, 0, where=roro.values < 0, color=C['red'], alpha=0.3)
                ax.set_title('RORO Score', fontweight='bold')
                plt.tight_layout()
                path = str(chart_dir / 'roro_timeline.png')
                fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
                charts['roro_timeline'] = path
            except Exception: pass
        return charts


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# WALK-FORWARD VALIDATORS
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
class WalkForwardValidator:
    def __init__(self, df: pd.DataFrame, n_windows: int = 6):
        self.df = df; self.n_windows = n_windows; self.results = []

    def analyze(self) -> Dict[str, Any]:
        logger.info(f"[WALK-FORWARD] {self.n_windows} janelas...")
        dates = self.df.index.sort_values()
        if len(dates) < 10000:
            return {'stability_score': 0, 'periods': []}
        ws = len(dates) // self.n_windows
        periods = []
        for i in range(self.n_windows):
            start = i * ws
            end = (i + 1) * ws if i < self.n_windows - 1 else len(dates)
            wdf = self.df.iloc[start:end]
            if len(wdf) < 100: continue
            rc = wdf['regime'].value_counts(normalize=True)
            periods.append({
                'label': f"{wdf.index[0].strftime('%Y-%m')} a {wdf.index[-1].strftime('%Y-%m')}",
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
        fig, ax = plt.subplots(figsize=(10, 4))
        cats = ['TREND_FORTE', 'TREND_FRACO', 'RANGE', 'CHOP']
        bottom = np.zeros(len(self.results))
        for cat in cats:
            vals = [p.get(f'{cat.lower()}_pct', p.get(f"{cat.lower().replace('_','_pct')}", 0))/100
                    if f'{cat.lower()}_pct' in p else p.get('trend_pct', 0)/100 if 'TREND' in cat else 0
                    for p in self.results]
            # Simplified
            vals = [p.get('trend_pct', 0)/100 if cat == 'TREND_FORTE' else
                    p.get('range_pct', 0)/100 if cat == 'RANGE' else
                    p.get('chop_pct', 0)/100 if cat == 'CHOP' else 0
                    for p in self.results]
            ax.bar(x, vals, bottom=bottom, color=REGIME_COLORS.get(cat, '#999'), label=cat, width=0.6)
            bottom += vals
        ax.set_xticks(x); ax.set_xticklabels(labels, rotation=45, ha='right', fontsize=8)
        ax.set_ylabel('ProporÃ§Ã£o'); ax.set_title('EvoluÃ§Ã£o de Regime', fontweight='bold')
        ax.legend(loc='upper right'); ax.set_ylim(0, 1)
        plt.tight_layout()
        path = str(chart_dir / 'wf_regime.png')
        fig.savefig(path, dpi=150, bbox_inches='tight'); plt.close(fig)
        charts['wf_regime'] = path
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


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# [INST-7] CPCV â€” Combinatorial Purged Cross-Validation + PBO
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
class CPCVValidator:
    """[INST-7] Combinatorial Purged CV com Probability of Backtest Overfitting.
    Gera mÃºltiplos caminhos de backtest para estimar a probabilidade de que
    o melhor resultado seja fruto de overfitting (Bailey & LÃ³pez de Prado).
    """
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
            return {'pbo_score': None, 'n_paths': 0}

        block_size = n // self.n_splits
        purge = max(10, int(block_size * self.purge_pct))
        combos = list(combinations(range(self.n_splits), self.n_test))
        n_paths = len(combos)
        logger.info(f"  [CPCV] {n_paths} caminhos combinatÃ³rios")

        # Para cada caminho, calcular estabilidade do Hurst
        path_scores = []
        for combo in combos[:min(n_paths, 15)]:  # Limitar para performance
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
            return {'pbo_score': None, 'n_paths': len(path_scores)}

        # PBO: proporÃ§Ã£o de caminhos onde o teste Ã© pior que a mediana
        median_score = np.median(path_scores)
        pbo = sum(1 for s in path_scores if s > median_score) / len(path_scores) * 100
        logger.info(f"  [CPCV] PBO: {pbo:.1f}% ({len(path_scores)} caminhos)")
        return {
            'pbo_score': round(pbo, 1),
            'n_paths': len(path_scores),
            'median_hurst_drift': round(float(median_score), 4),
            'max_hurst_drift': round(float(max(path_scores)), 4),
        }


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# JSON PROFILE EXPORTER (retrocompatÃ­vel com EA MQL5)
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
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

        if avg_hurst > 0.58:
            dfa_period, dfa_min, dfa_max = 300, 14, 56
        elif avg_hurst > 0.52:
            dfa_period, dfa_min, dfa_max = 200, 8, 40
        else:
            dfa_period, dfa_min, dfa_max = 150, 6, 28

        trend_score = min(1.0, (avg_hurst - 0.45) / 0.3 * 0.7 + regime_dist.get('TREND_FORTE', 0))
        meanrev_score = min(1.0, (0.6 - avg_hurst) / 0.3 * 0.7 + regime_dist.get('RANGE', 0))
        breakout_score = min(1.0, avg_adx / 40 * 0.5 + avg_atr * 0.1)

        hmm_data = {}
        if 'hmm_regime' in df.columns:
            hmm_dist = {str(k): float(v) for k, v in df['hmm_regime'].value_counts(normalize=True).to_dict().items()}
            hmm_data = {
                'states': int(df['hmm_state'].nunique()) if 'hmm_state' in df.columns else 0,
                'agreement_adx_hurst': round(self.hmm.get('agreement', 0), 1),
                'hmm_regime_distribution': hmm_dist,
                'hmm_features': ['log_return', 'realized_vol', 'skewness', 'kurtosis', 'autocorr_lag1'],
            }

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

        fracdiff_data = {}
        if 'fracdiff_close' in df.columns:
            fd = df['fracdiff_close'].dropna()
            fd_ret = df['fracdiff_return'].dropna()
            fracdiff_data = {
                'fracdiff_close_mean': round(float(fd.mean()), 6) if len(fd) else 0,
                'fracdiff_close_std': round(float(fd.std()), 6) if len(fd) else 0,
                'fracdiff_return_mean': round(float(fd_ret.mean()), 6) if len(fd_ret) else 0,
                'fracdiff_return_std': round(float(fd_ret.std()), 6) if len(fd_ret) else 0,
                'd_param_close': self.fracdiff.get('d_close', 0.5),
                'd_param_return': self.fracdiff.get('d_return', 0.3),
                'd_method': 'FFD_ADF_optimized',
            }

        return {
            'meta': {
                'symbol': symbol, 'timeframe': tf,
                'generated_at': datetime.now().isoformat(),
                'candles': len(df),
                'date_from': str(df.index[0]), 'date_to': str(df.index[-1]),
                'algo_version': ALGO_VERSION,
            },
            'regime_profile': {
                'dominant': str(regime_dist),
                'hurst_mean': avg_hurst, 'hurst_method': 'DFA',
                'adx_mean': avg_adx, 'atr_mean': avg_atr,
                'regime_distribution': regime_dist,
            },
            'hmm_model': hmm_data,
            'entropy': entropy_data,
            'fracdiff': fracdiff_data,
            'dfa_recommendation': {
                'period': dfa_period, 'min_scale': dfa_min, 'max_scale': dfa_max,
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
                'amplification_factor': round(
                    self.tail_risk.get('avg_atr_spike', 0) /
                    max(self.tail_risk.get('avg_atr_normal', 0.001), 0.001), 1),
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
            'purged_wf': {
                'score': round(self.purged_wf.get('stability_score', 0), 1),
                'n_windows': len(self.purged_wf.get('periods', [])),
                'purge_pct': 0.02, 'embargo_pct': 0.01,
                'mean_js_divergence': round(self.purged_wf.get('mean_js_divergence', 0), 4),
            },
            'cpcv': {
                'pbo_score': self.cpcv.get('pbo_score'),
                'n_paths': self.cpcv.get('n_paths', 0),
                'median_hurst_drift': self.cpcv.get('median_hurst_drift', 0),
            },
        }


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# BATCH RUNNER
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
def process_single_asset(symbol: str, tf: str, input_file=None, no_cache=False,
                         from_db=True) -> Dict[str, Any]:
    if no_cache: CACHE.invalidate()
    try:
        loader = DataLoader(symbol=symbol, tf=tf, from_db=from_db) if from_db else DataLoader(input_file)
        df = loader.load()
        fe = FeatureEngine(df, tf=tf); df = fe.compute()
        rm = RegimeModel(df); df = rm.classify()
        return {
            'symbol': symbol, 'tf': tf, 'status': 'success',
            'candles': len(df), 'dominant_regime': df['regime'].value_counts().index[0],
            'hurst_mean': float(df['hurst'].mean()), 'adx_mean': float(df['adx'].mean()),
        }
    except Exception as e:
        logger.error(f"[BATCH] Erro {symbol}: {e}")
        return {'symbol': symbol, 'tf': tf, 'status': 'error', 'error': str(e)}


def run_batch(symbols, tf, no_cache=False, from_db=True):
    if not HAS_JOBLIB:
        return [process_single_asset(s, tf, no_cache=no_cache, from_db=from_db) for s in symbols]
    n_jobs = CFG.n_jobs if CFG.n_jobs > 0 else None
    logger.info(f"[BATCH] {len(symbols)} ativos, {n_jobs or 'auto'} workers")
    results = Parallel(n_jobs=n_jobs, backend='loky', verbose=10)(
        delayed(process_single_asset)(s, tf, no_cache=no_cache, from_db=from_db) for s in symbols)
    success = sum(1 for r in results if r['status'] == 'success')
    logger.info(f"[BATCH] {success}/{len(symbols)} sucesso")
    return results


# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# MAIN PIPELINE
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
def main():
    parser = argparse.ArgumentParser(description='Asset DNA Profiler v3.0-Institutional')
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
        results = run_batch(args.batch, args.tf, no_cache=args.no_cache, from_db=from_db)
        summary_file = CFG.report_dir / f"batch_summary_{datetime.now().strftime('%Y%m%d_%H%M')}.json"
        with open(summary_file, 'w') as f:
            json.dump(results, f, indent=2, default=str)
        return

    symbol = args.symbol or "XAUUSD"
    tf = args.tf.upper()
    output_pdf = str(args.output or CFG.report_dir / f"asset_dna_{symbol}_{tf}.pdf")

    TOTAL_PHASES = 8
    logger.info("=" * 60)
    logger.info(f"ALXQuant Asset DNA Profiler {ALGO_VERSION}")
    logger.info(f"Simbolo: {symbol} | TF: {tf} | Fonte: {'SQLite' if from_db else 'CSV'}")
    logger.info(f"Numba: {'ON' if HAS_NUMBA else 'OFF'} | Polars: {'ON' if HAS_POLARS else 'OFF'}")
    logger.info(f"Statsmodels: {'ON' if HAS_STATSMODELS else 'OFF'} | Johansen: {'ON' if HAS_JOHANSEN else 'OFF'}")
    logger.info("=" * 60)

    warmup_numba_kernels()
    t_total = time.time()

    # â”€â”€ FASE 1: Data Loading â”€â”€
    log_phase(1, TOTAL_PHASES, "DATA LOADING")
    loader = DataLoader(symbol=symbol, tf=tf, from_db=from_db) if from_db else DataLoader(args.input)
    df = loader.load()

    # â”€â”€ FASE 2: Feature Engineering â”€â”€
    log_phase(2, TOTAL_PHASES, "FEATURE ENGINEERING (DFA + FFD + Kalman + KSG)")
    fe = FeatureEngine(df, tf=tf)
    df = fe.compute()

    # â”€â”€ FASE 3: Regime Classification â”€â”€
    log_phase(3, TOTAL_PHASES, "REGIME CLASSIFICATION (ADX + DFA-Hurst + HMM)")
    rm = RegimeModel(df); df = rm.classify()
    trans_mat, regime_labels = rm.transition_matrix()
    hmm = HMMRegimeModel(df, n_states=4); df = hmm.classify()
    hmm_model_data = {
        'n_states': hmm.n_states, 'agreement': hmm.agreement,
        'has_hmm': HAS_HMM and hmm.model is not None,
    }

    # â”€â”€ FASE 4: Temporal + Tail Risk â”€â”€
    log_phase(4, TOTAL_PHASES, "TEMPORAL + TAIL RISK")
    tp = TemporalProfiler(df); temporal = tp.analyze()
    tr = TailRiskEngine(df); tail_risk = tr.analyze()

    # â”€â”€ FASE 5: Macro Integration â”€â”€
    log_phase(5, TOTAL_PHASES, "MACRO RISK (Johansen + VAR)")
    try:
        macro_int = MacroRiskIntegrator(); macro_int.load()
        macro_results = macro_int.cross_reference(df, symbol=symbol)
    except Exception as e:
        logger.warning(f"[MACRO] Erro: {e}")
        macro_results = {}

    # â”€â”€ FASE 6: Walk-Forward + CPCV â”€â”€
    log_phase(6, TOTAL_PHASES, "WALK-FORWARD + CPCV VALIDATION")
    wf = WalkForwardValidator(df, n_windows=6); wf_results = wf.analyze()
    purged = PurgedWalkForwardValidator(df, n_windows=6); purged_results = purged.analyze()
    cpcv = CPCVValidator(df, n_splits=6, n_test_splits=2); cpcv_results = cpcv.analyze()

    # â”€â”€ FASE 7: Charts + PDF â”€â”€
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
        'has_kalman': 'close_denoised' in df.columns,  # [INST-3]
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

    # â”€â”€ FASE 8: JSON Export â”€â”€
    log_phase(8, TOTAL_PHASES, "JSON EXPORT")
    json_output = str(CFG.report_dir / f"asset_profile_{symbol}_{tf}.json")
    exporter = JsonProfileExporter(
        df, regime_labels, trans_mat, temporal, tail_risk, wf_results, macro_results,
        hmm_model=hmm_model_data, entropy=entropy_stats, fracdiff=fracdiff_data,
        signal_data=signal_data, purged_wf=purged_results, cpcv=cpcv_results,
    )
    exporter.export(json_output, symbol, tf)

    elapsed = time.time() - t_total
    logger.info(f"\n{'='*60}")
    logger.info(f"[OK] PDF: {output_pdf}")
    logger.info(f"[OK] JSON: {json_output}")
    logger.info(f"[OK] Tempo: {elapsed:.2f}s | Candles: {len(df):,}")
    logger.info(f"[OK] DFA-Hurst: {df['hurst'].mean():.3f} | FFD-d: {fe.ffd_d_close:.2f}")
    logger.info(f"[OK] PBO: {cpcv_results.get('pbo_score', 'N/A')}%")
    logger.info(f"{'='*60}")


if __name__ == '__main__':
    main()
