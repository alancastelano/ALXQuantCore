"""
ALXQuant Asset DNA Profiler v7.0-FastExecution
================================================
FOCO: 100% de compatibilidade com o CAssetProfileLoader.mqh
VELOCIDADE: ~12 segundos (Removido loops lentos de HMM, TE, Kalman, Entropy)
SAÍDA: JSON legado perfeito + Novos parâmetros de ajuste fino (mql5_directives)
"""

from __future__ import annotations
import os, sys, time, logging, json
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional, Tuple, List

# CORREÇÃO PATH
_THIS_DIR = Path(__file__).parent.resolve()
sys.path.insert(0, str(_THIS_DIR))
sys.path.insert(0, str(_THIS_DIR.parent))

import duckdb
import numpy as np
import pandas as pd

try:
    import polars as pl
    HAS_POLARS = True
except ImportError:
    HAS_POLARS = False

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
    from joblib import Memory
    import joblib
    HAS_JOBLIB = True
except ImportError:
    HAS_JOBLIB = False

try:
    from tqdm import tqdm
    HAS_TQDM = True
except ImportError:
    HAS_TQDM = False
    def tqdm(it, **kw): return it

import warnings
warnings.filterwarnings('ignore')

ALGO_VERSION = "v7.0.0"
DB_PATH = r"C:\ALXQuant\data\ALXQuantCore.duckdb"
_DATA_DIR = Path(os.getenv('ALXQUANT_DATA_DIR', r'C:\ALXQuant\data\datasets'))
REPORT_DIR = Path(r'C:\ALXQuant\data\mql5')
CACHE_DIR = Path(r'C:\ALXQuant\data\cache\asset_dna')

for d in [_DATA_DIR, REPORT_DIR, CACHE_DIR]:
    d.mkdir(parents=True, exist_ok=True)

SESSION_LABELS = ['Asia', 'London', 'NY_AM', 'NY_PM']
REGIME_LABELS = ['TREND_FORTE', 'TREND_FRACO', 'BREAKOUT', 'RANGE', 'CHOP']

def setup_logger():
    logger = logging.getLogger('asset_dna_fast')
    logger.setLevel(logging.INFO)
    if not logger.handlers:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(logging.Formatter('%(asctime)s [%(levelname)s]: %(message)s', datefmt='%H:%M:%S'))
        logger.addHandler(handler)
    return logger

logger = setup_logger()

# ══════════════════════════════════════════════════════════════
# CACHE
# ══════════════════════════════════════════════════════════════
class DiskCache:
    def __init__(self):
        self.memory = Memory(location=str(CACHE_DIR), verbose=0, compress=3) if HAS_JOBLIB else None

    def get(self, key: str, data: np.ndarray) -> Optional[Any]:
        if not self.memory: return None
        try:
            h = str(hash(data.tobytes()))[:16]
            return joblib.load(CACHE_DIR / f"{key}_{h}.joblib")
        except: return None

    def put(self, key: str, data: np.ndarray, value: Any):
        if not self.memory: return
        try:
            h = str(hash(data.tobytes()))[:16]
            joblib.dump(value, CACHE_DIR / f"{key}_{h}.joblib", compress=3)
        except: pass

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
    def _dfa_numba(log_returns: np.ndarray, window: int) -> np.ndarray:
        n = log_returns.shape[0]
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
        scales = scales[:n_scales]
        log_scales = np.log(scales.astype(np.float64))
        
        for i in prange(window - 1, n):
            seg = log_returns[i - window + 1 : i + 1]
            w_len = len(seg)
            mean_seg = seg.mean()
            profile = np.empty(w_len, dtype=np.float64)
            cum = 0.0
            for k in range(w_len):
                cum += seg[k] - mean_seg
                profile[k] = cum
            
            sum_x = 0.0; sum_x2 = 0.0; sum_y = 0.0; sum_xy = 0.0; n_valid = 0
            for si in range(n_scales):
                s = scales[si]
                n_boxes = w_len // s
                if n_boxes < 1: continue
                rms_sum = 0.0
                for b in range(n_boxes):
                    box = profile[b*s : (b+1)*s]
                    bx_mean = 0.0; by_mean = 0.0
                    for k in range(s): bx_mean += k; by_mean += box[k]
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
                    rms_sum += (rms2 / s)
                
                if n_boxes > 0:
                    F_s = np.sqrt(rms_sum / n_boxes)
                    if F_s > 1e-15:
                        log_F = np.log(F_s)
                        lx = log_scales[si]
                        sum_x += lx; sum_x2 += lx * lx
                        sum_y += log_F; sum_xy += lx * log_F
                        n_valid += 1
            
            if n_valid < 3: out[i] = 0.5; continue
            denom = n_valid * sum_x2 - sum_x * sum_x
            if abs(denom) < 1e-20: out[i] = 0.5; continue
            alpha = (n_valid * sum_xy - sum_x * sum_y) / denom
            out[i] = max(0.01, min(alpha, 0.99))
        return out
else:
    def _classify_session_numba(h): return np.zeros(len(h), dtype=np.int8)
    def _transition_matrix_numba(r, n): return np.zeros((n, n))
    def _dfa_numba(lp, w): return np.full(len(lp), 0.5)

# ══════════════════════════════════════════════════════════════
# DATA LOADER
# ══════════════════════════════════════════════════════════════
class DataLoader:
    def __init__(self, symbol: str = "XAUUSD", tf: str = 'M5', years: int = 5):
        self.symbol = symbol
        self.tf = tf
        self.years = years

    def load(self) -> pd.DataFrame:
        logger.info(f"[LOAD] DuckDB: {self.symbol}_{self.tf} (Últimos {self.years} anos)")
        conn = duckdb.connect(DB_PATH, read_only=True)
        try:
            limit_date = datetime.now() - pd.DateOffset(years=self.years)
            limit_ts = int(limit_date.timestamp())
            
            query = """SELECT time, open, high, low, close, tick_volume, spread 
                       FROM ohlc_prices 
                       WHERE symbol = ? AND timeframe = ? AND time >= ? ORDER BY time"""
            df = conn.execute(query, [self.symbol, self.tf, limit_ts]).df()
        finally:
            conn.close()
        
        if df.empty: return pd.DataFrame()
        df['time'] = pd.to_datetime(df['time'], unit='s')
        df.set_index('time', inplace=True)
        logger.info(f"  [OK] {len(df):,} candles carregados.")
        return df

# ══════════════════════════════════════════════════════════════
# FEATURE ENGINE
# ══════════════════════════════════════════════════════════════
class FeatureEngine:
    def __init__(self, df: pd.DataFrame, tf: str = 'M5'):
        self.df = df
        self.ws = 5 if tf == 'M1' else 1
        self.dfa_period = 100 * self.ws
        self.dfa_min_scale = 4
        self.dfa_max_scale = min(50, self.dfa_period // 4)

    def compute(self) -> pd.DataFrame:
        t0 = time.time()
        logger.info("[FEATURES] Computando ADX, ATR, Z-Scores e DFA Hurst...")
        if HAS_POLARS:
            df = self._compute_polars()
        else:
            df = self._compute_pandas()
        logger.info(f"  [OK] Features prontas em {time.time()-t0:.2f}s")
        return df

    def _compute_polars(self) -> pd.DataFrame:
        df_pl = pl.from_pandas(self.df.reset_index())
        ws = self.ws
        
        df_pl = df_pl.with_columns([
            (pl.col('close').log() - pl.col('close').log().shift(1)).alias('log_return'),
            pl.max_horizontal([
                pl.col('high') - pl.col('low'), 
                (pl.col('high') - pl.col('close').shift(1)).abs(), 
                (pl.col('low') - pl.col('close').shift(1)).abs()
            ]).alias('tr')
        ])
        
        atr_win = 14 * ws
        z_win = 500 * ws
        df_pl = df_pl.with_columns([
            pl.col('tr').rolling_mean(window_size=atr_win).alias('atr'),
            ((pl.col('tr') - pl.col('tr').rolling_mean(window_size=z_win)) / 
             pl.col('tr').rolling_std(window_size=z_win).clip(lower_bound=1e-10)).alias('tr_zscore'),
            ((pl.col('tr').rolling_mean(50*ws) - pl.col('tr').rolling_mean(window_size=z_win)) / 
             pl.col('tr').rolling_std(window_size=z_win).clip(lower_bound=1e-10)).alias('vol_zscore'),
        ])

        up_move = pl.col('high').diff()
        down_move = -pl.col('low').diff()
        plus_dm = pl.when((up_move > down_move) & (up_move > 0)).then(up_move).otherwise(0)
        minus_dm = pl.when((down_move > up_move) & (down_move > 0)).then(down_move).otherwise(0)
        tr_smooth = pl.col('atr').clip(lower_bound=1e-10)
        plus_di = 100 * plus_dm.rolling_mean(atr_win) / tr_smooth
        minus_di = 100 * minus_dm.rolling_mean(atr_win) / tr_smooth
        dx = 100 * (plus_di - minus_di).abs() / (plus_di + minus_di).clip(lower_bound=1e-10)
        df_pl = df_pl.with_columns(dx.rolling_mean(atr_win).alias('adx'))

        hurst_win = 100 * ws
        log_ret_arr = np.nan_to_num(df_pl['log_return'].cast(pl.Float64).to_numpy(), nan=0.0)
        
        hurst_cached = CACHE.get("dfa_hurst_v7", log_ret_arr.astype(np.float32))
        if hurst_cached is None:
            logger.info(f"  [DFA] Calculando Hurst (window={hurst_win})...")
            hurst = _dfa_numba(log_ret_arr, hurst_win)
            CACHE.put("dfa_hurst_v7", log_ret_arr.astype(np.float32), hurst)
        else:
            logger.info(f"  [DFA] Cache Hit!")
            hurst = hurst_cached
            
        df_pl = df_pl.with_columns([
            pl.Series('hurst', hurst.astype(np.float32)),
            pl.col('time').dt.hour().cast(pl.Int8).alias('hour'),
            pl.col('time').dt.weekday().cast(pl.Int8).alias('day_of_week'),
        ])

        df = df_pl.to_pandas()
        df.dropna(subset=['adx', 'hurst', 'atr'], inplace=True)
        return df

    def _compute_pandas(self) -> pd.DataFrame:
        df = self.df.copy()
        close = df['close'].to_numpy(dtype=np.float64)
        log_ret = np.empty_like(close); log_ret[0] = np.nan; log_ret[1:] = np.log(close[1:] / close[:-1])
        df['log_return'] = log_ret
        high, low = df['high'].to_numpy(dtype=np.float64), df['low'].to_numpy(dtype=np.float64)
        close_prev = np.empty_like(close); close_prev[0] = np.nan; close_prev[1:] = close[:-1]
        tr = np.maximum(high - low, np.maximum(np.abs(high - close_prev), np.abs(low - close_prev)))
        df['tr'] = tr
        ws = self.ws
        df['atr'] = pd.Series(tr).rolling(14*ws, min_periods=14*ws).mean().to_numpy()
        up_move = np.empty_like(high); up_move[0] = np.nan; up_move[1:] = high[1:] - high[:-1]
        down_move = np.empty_like(low); down_move[0] = np.nan; down_move[1:] = -(low[1:] - low[:-1])
        plus_dm = np.where((up_move > down_move) & (up_move > 0), up_move, 0.0)
        minus_dm = np.where((down_move > up_move) & (down_move > 0), down_move, 0.0)
        atr_safe = np.where(df['atr'] < 1e-10, 1e-10, df['atr'])
        plus_di = 100 * pd.Series(plus_dm).rolling(14*ws).mean().to_numpy() / atr_safe
        minus_di = 100 * pd.Series(minus_dm).rolling(14*ws).mean().to_numpy() / atr_safe
        di_sum_safe = np.where(plus_di + minus_di < 1e-10, 1e-10, plus_di + minus_di)
        dx = 100 * np.abs(plus_di - minus_di) / di_sum_safe
        df['adx'] = pd.Series(dx).rolling(14*ws).mean().to_numpy()
        
        log_ret_arr = np.nan_to_num(df['log_return'].to_numpy(dtype=np.float64), nan=0.0)
        hurst = _dfa_numba(log_ret_arr, 100 * ws)
        df['hurst'] = hurst
        df['hour'] = df.index.hour.astype(np.int8)
        df['day_of_week'] = df.index.dayofweek.astype(np.int8)
        df.dropna(subset=['adx', 'hurst', 'atr'], inplace=True)
        return df

# ══════════════════════════════════════════════════════════════
# JSON BUILDER (100% Focado no CAssetProfileLoader.mqh)
# ══════════════════════════════════════════════════════════════
class JsonBuilderForMQL5:
    def __init__(self, df: pd.DataFrame, engine: FeatureEngine):
        self.df = df
        self.engine = engine
        self.regimes = None
        self.trans_mat_dict = {}
        self.dist = {}

    def build(self) -> Dict[str, Any]:
        self._classify_regimes()
        self._calc_transition_matrix()
        
        # Médias Gerais
        hurst_mean = float(self.df['hurst'].mean())
        adx_mean = float(self.df['adx'].mean())
        atr_mean = float(self.df['atr'].mean())
        
        # Perfil de Sessão
        most_volatile_hour = int(self.df.groupby('hour')['atr'].mean().idxmax())
        
        # Tail Risk
        amp_factor = 1.8
        atr_threshold = atr_mean * amp_factor
        spike_pct = round(float((self.df['tr'] > atr_threshold).sum() / len(self.df) * 100), 2)
        
        # Stability Score (Heurística simples baseada no desvio padrão)
        hurst_std = float(self.df['hurst'].std())
        adx_std = float(self.df['adx'].std())
        stability_score = round(max(0.0, min(100.0, 100 - (hurst_std * 500) - (adx_std * 5))), 1)
        
        # Strategy Fit (Scores baseados na distribuição)
        trend_dist = self.dist.get("TREND_FORTE", 0) + self.dist.get("TREND_FRACO", 0)
        self.dist["BREAKOUT"] = self.dist.get("BREAKOUT", 0) # Garante que existe
        
        # Estrutura EXATA que o MQL5 espera (CAssetProfileLoader.mqh)
        return {
            "meta": {
                "symbol": "XAUUSD", # O loader sobrescreve isso no MQL5, mas é bom ter
                "timeframe": "M5",
                "generated_at": datetime.now().isoformat(),
                "candles": len(self.df),
                "algo_version": ALGO_VERSION
            },
            "regime_profile": {
                "dominant": max(self.dist, key=self.dist.get),
                "hurst_mean": round(hurst_mean, 4),
                "adx_mean": round(adx_mean, 4),
                "atr_mean": round(atr_mean, 4),
                "regime_distribution": self.dist
            },
            "dfa_recommendation": {
                "period": self.engine.dfa_period,
                "min_scale": self.engine.dfa_min_scale,
                "max_scale": self.engine.dfa_max_scale
            },
            "session_profile": {
                "most_volatile_hour": most_volatile_hour
            },
            "strategy_fit": {
                "trend_following_score": round(trend_dist * 1.5, 2), # Escala para ficar ~0.3
                "mean_reversion_score": round(self.dist.get("RANGE", 0) * 1.2, 2), # Escala ~0.7
                "breakout_score": round(self.dist.get("BREAKOUT", 0) * 3.0, 2)
            },
            "tail_risk": {
                "spike_pct": spike_pct,
                "atr_threshold": round(atr_threshold, 4),
                "amplification_factor": amp_factor
            },
            "stability": {
                "score": stability_score
            },
            "transition_matrix": self.trans_mat_dict,
            
            # === CAMPOS LEGADOS (ZERADOS PARA NÃO QUEBRAR O MQL5) ===
            "hmm_model": {"states": 0, "agreement_adx_hurst": 0.0},
            "entropy": {"sample_entropy_mean": 0.0, "perm_entropy_mean": 0.0},
            "fracdiff": {"fracdiff_return_std": 0.0},
            "signal_analysis": {
                "kalman_filtered": False,
                "transfer_entropy": {
                    "ret_to_vol": 0.0, "vol_to_ret": 0.0,
                    "hurst_to_adx": 0.0, "adx_to_hurst": 0.0
                }
            },
            "purged_wf": {"score": 0.0, "n_windows": 0},
            "macro_sensitivity": {}, # Vazio para o MQL5 usar os defaults (0.0)
            
            # === NOVO: DIRETIVAS ESTRITAS PARA O EA (Futuro uso) ===
            "mql5_directives": {
                "regime_thresholds": {
                    "adx_p50": round(float(np.percentile(self.df['adx'], 50)), 2),
                    "adx_p75": round(float(np.percentile(self.df['adx'], 75)), 2),
                    "hurst_p40": round(float(np.percentile(self.df['hurst'], 40)), 4),
                    "hurst_p60": round(float(np.percentile(self.df['hurst'], 60)), 4)
                }
            }
        }

    def _classify_regimes(self):
        adx = self.df['adx'].to_numpy()
        hurst = self.df['hurst'].to_numpy()
        
        # Pega os thresholds dinâmicos
        adx_p50 = np.percentile(adx, 50)
        adx_p75 = np.percentile(adx, 75)
        hurst_p40 = np.percentile(hurst, 40)
        hurst_p60 = np.percentile(hurst, 60)

        conditions = [
            (adx < adx_p50),                                                                 # CHOP
            (adx >= adx_p50) & (hurst < hurst_p40),                                         # RANGE
            (adx >= adx_p50) & (hurst >= hurst_p40) & (hurst < hurst_p60),                   # BREAKOUT
            (adx >= adx_p50) & (hurst >= hurst_p60) & (adx < adx_p75),                      # TREND FRACO
            (adx >= adx_p75) & (hurst >= hurst_p60)                                          # TREND FORTE
        ]
        choices = ['CHOP', 'RANGE', 'BREAKOUT', 'TREND_FRACO', 'TREND_FORTE']
        self.regimes = np.select(conditions, choices, default='RANGE')
        
        counts = pd.Series(self.regimes).value_counts(normalize=True).to_dict()
        self.dist = {k: round(v, 4) for k, v in counts.items()}

    def _calc_transition_matrix(self):
        regime_map = {name: i for i, name in enumerate(REGIME_LABELS)}
        # Mapeia regimes que podem não estar no map (segurança)
        regimes_int = np.array([regime_map.get(r, 3) for r in self.regimes], dtype=np.int32) # 3 = RANGE fallback
        mat = _transition_matrix_numba(regimes_int, len(REGIME_LABELS))
        
        for i, name_from in enumerate(REGIME_LABELS):
            for j, name_to in enumerate(REGIME_LABELS):
                self.trans_mat_dict[f"{name_from}_to_{name_to}"] = round(float(mat[i, j]), 3)


# ══════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ══════════════════════════════════════════════════════════════
def run_dna_profiler(symbol: str = "XAUUSD", tf: str = "M5", years: int = 5):
    start_time = time.time()
    
    # 1. Load
    loader = DataLoader(symbol=symbol, tf=tf, years=years)
    df = loader.load()
    if df.empty:
        logger.error("Sem dados. Saindo.")
        return

    # 2. Features
    engine = FeatureEngine(df, tf=tf)
    df_features = engine.compute()

    # 3. Constroi JSON compatível com MQL5
    builder = JsonBuilderForMQL5(df_features, engine)
    final_json = builder.build()

    # 4. Salva JSON com o nome que o MQL5 espera: asset_profile_XAUUSD_M5.json
    filename = f"asset_profile_{symbol}_{tf}.json"
    out_file = REPORT_DIR / filename
    
    with open(out_file, 'w', encoding='utf-8') as f:
        json.dump(final_json, f, indent=2, ensure_ascii=False)
    
    logger.info(f"{'='*60}")
    logger.info(f"JSON SALVO EM: {out_file}")
    logger.info(f"-> Regime Predominante: {final_json['regime_profile']['dominant']}")
    logger.info(f"-> Hora Mais Volátil: {final_json['session_profile']['most_volatile_hour']}h")
    logger.info(f"-> DFA Config: P={final_json['dfa_recommendation']['period']} Min={final_json['dfa_recommendation']['min_scale']} Max={final_json['dfa_recommendation']['max_scale']}")
    logger.info(f"TEMPO TOTAL: {time.time() - start_time:.2f} segundos!")
    logger.info(f"{'='*60}")

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--symbol', type=str, default='XAUUSD')
    parser.add_argument('--tf', type=str, default='M5')
    parser.add_argument('--years', type=int, default=5)
    args = parser.parse_args()
    
    run_dna_profiler(symbol=args.symbol, tf=args.tf, years=args.years)