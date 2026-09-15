"""
ALXQuant Alpha Research Engine v3.1
====================================
   Gera relatório PDF profissional com análise quantitativa institucional.
   Correções v3.1: Z-Score Rolling (look-ahead free), BREAKEVEN handling,
                   profitFactorTrade removido, Schema v5.1 support,
                   Regime Semantic + Session14 + News Flags analysis.
   Uso: python alpha_research_v3.py [--csv <caminho.csv>] [--output <relatorio.pdf>]
        Uso: python alpha_research.py --csv C:\\ALXQuant\\data\\miner\\Ghost_v2_XAUUSD_miner.csv
        Exemplo: python alpha_research.py --csv C:\\ALXQuant\\data\\miner\\Ghost_v2_XAUUSD_miner.csv
"""

import csv
import os
import sys
import argparse

# Ensure parent directory (app/) is in path for module resolution
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import logging
import tempfile
import shutil
import textwrap
import warnings
from pathlib import Path
from datetime import datetime
from collections import Counter

import pandas as pd
import numpy as np
from sklearn.tree import DecisionTreeClassifier, DecisionTreeRegressor
from sklearn.ensemble import RandomForestClassifier, GradientBoostingRegressor
from sklearn.preprocessing import StandardScaler
from sklearn.cluster import KMeans
from scipy import stats
from scipy.stats import mannwhitneyu, spearmanr
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
import seaborn as sns
from sklearn.inspection import permutation_importance
from sklearn.model_selection import cross_val_score, GridSearchCV

try:
    import shap
    SHAP_AVAILABLE = True
except ImportError:
    SHAP_AVAILABLE = False

from reportlab.lib.pagesizes import A4
from reportlab.lib import colors
from reportlab.lib.units import mm, cm
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_LEFT, TA_CENTER, TA_RIGHT, TA_JUSTIFY
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Image, Table, TableStyle,
    PageBreak, KeepTogether, HRFlowable
)
from dotenv import load_dotenv
load_dotenv(r'C:\ALXQuant\.env', override=True)

warnings.filterwarnings('ignore')

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%H:%M:%S'
)
logger = logging.getLogger('ALXQuant')

REPORT_DIR = r'C:\ALXQuant\data\report'
LOGO_PATH = r'C:\ALXQuant\data\image\alxquant_logo.bmp'
FOREXCAL_PATH = r'C:\ALXQuant\data\mql5\Calendar.csv'

C = {
    'navy':      '#0A1628',
    'dark':      '#1A1A2E',
    'orange':    '#FF6B35',
    'fire':      '#E85D04',
    'gold':      '#D4A843',
    'silver':    '#B0B0B0',
    'gray':      '#8A8A8A',
    'light':     '#E8E8E8',
    'lighter':   '#F5F5F5',
    'green':     '#27AE60',
    'red':       '#E74C3C',
    'white':     '#FFFFFF',
}

plt.rcParams.update({
    'font.family': 'sans-serif',
    'font.size': 9,
    'axes.titlesize': 11,
    'axes.titleweight': 'bold',
    'axes.labelsize': 9,
    'figure.facecolor': 'white',
    'axes.facecolor': '#FAFBFC',
    'axes.grid': True,
    'grid.alpha': 0.25,
    'grid.color': '#CCCCCC',
    'axes.spines.top': False,
    'axes.spines.right': False,
})

CHART_DIR = None

COLUMNS_V51 = [
    'TradeID', 'Ticket', 'MagicNumber', 'Symbol', 'Direction',
    'EntryTime', 'EntryPrice', 'Volume', 'SpreadAtEntry',

    'Hurst', 'Confidence_R2', 'Strength', 'Slope', 'SlopeNormalized',
    'DirectionScore', 'MomentumState', 'ATR', 'DistanceVWAP',
    'DistanceVWAP_ATR', 'SpreadAnomaly', 'RelativeVolume',
    'LiquidityState', 'VolatilityBurst',

    'Trending', 'MeanReverting', 'Bullish', 'Bearish', 'HighVol',
    'LowVol', 'StrongMomentum', 'PossibleReversal', 'LiquiditySafe',
    'ChaosRegime', 'TrendFollowingHabitat', 'BreakoutHabitat',
    'MeanReversionHabitat',

    'RegimeName',

    # Regime Semantic (v5.1)
    'RegimeTrendStrongBull', 'RegimeTrendStrongBear',
    'RegimeTrendWeakBull', 'RegimeTrendWeakBear',
    'RegimeRangeTight', 'RegimeRangeVolatile',
    'RegimeChaos', 'RegimeReversalImminent', 'RegimeBreakoutForming',

    'EntrySL', 'EntryTP',

    'RiskScore', 'RiskDirection', 'LotMultiplier',

    'VIX', 'DXY', 'SP500', 'Yield2Y', 'Yield10Y',
    'VIX_PctChange', 'DXY_PctChange', 'SP500_PctChange',
    'Yield2Y_PctChange', 'Yield10Y_PctChange',
    'YieldCurve', 'isHighVIX', 'MacroProfile',

    'SessionName', 'SessionName14',

    # News Flags (v5.1)
    'NewsHighActive', 'NewsMediumActive',
    'MinutesToNextHighNews', 'BlockingNewsEvent', 'NewsImpactScore',

    'EntryHour', 'EntryMinute', 'DayOfWeek', 'WeekOfMonth', 'Month', 'Quarter',

    'Bid', 'Ask', 'SpreadAtExit', 'PointValue', 'TickValue', 'TickSize',
    'ContractSize',

    'CurrentBalance', 'CurrentEquity', 'CurrentFreeMargin',
    'CurrentMarginLevel',

    'DDAbsolute', 'DDRelative', 'OpenPositionsCount',

    'Close_M5', 'Close_M15', 'Close_H1', 'Close_H4', 'Close_D1',
    'Return_M5', 'Return_M15', 'Return_H1', 'Return_H4', 'Return_D1',

    'MFE_Points', 'MAE_Points',

    'ExitTime', 'ExitPrice', 'GrossProfit', 'NetProfit',
    'Commission', 'Swap', 'TradeDurationMinutes', 'TradeDurationBars',

    'InitialRisk', 'ResultR', 'ResultPercent',
    'MFE_R', 'MAE_R', 'CaptureRatio',

    'ExitReason', 'TradeOutcome', 'CatastrophicTrade',

    'RegimeAtExit'
]
# C7: profitFactorTrade REMOVIDO (inválido por trade)
# v5.1: 107 original - 1 (profitFactorTrade) + 9 (regime semantic) + 1 (SessionName14) + 5 (news flags) = 121
assert len(COLUMNS_V51) == 121, f"Expected 121 columns (v5.1), got {len(COLUMNS_V51)}"

# Backward compatibility alias
COLUMNS = COLUMNS_V51


def load_forexfactory_calendar(file_path=FOREXCAL_PATH):
    """Carrega o calendario ForexFactory e retorna DataFrame com datetime."""
    if not os.path.exists(file_path):
        logger.warning(f"ForexFactory Calendar nao encontrado: {file_path}")
        return None
    try:
        df = pd.read_csv(file_path, encoding='utf-8-sig',
                          on_bad_lines='skip')
        df['Data'] = pd.to_datetime(df['Data'], format='%Y.%m.%d', errors='coerce')
        df['Hora'] = df['Hora'].astype(str).str.strip()
        df['Hora'] = df['Hora'].replace('00:00', '00:00')
        df['EventTime'] = pd.to_datetime(
            df['Data'].dt.strftime('%Y-%m-%d') + ' ' + df['Hora'],
            errors='coerce'
        )
        df['Impacto'] = df['Impacto'].astype(str).str.strip().str.lower()
        logger.info(f"ForexFactory Calendar carregado: {len(df)} eventos")
        return df
    except Exception as e:
        logger.warning(f"Falha ao carregar ForexFactory Calendar: {e}")
        return None


def match_trades_with_news(df_trades, df_cal, hours_window=4):
    """Associa trades a eventos de noticia proximos no tempo."""
    if df_cal is None or df_cal.empty:
        return None
    results = []
    for _, trade in df_trades.iterrows():
        entry = trade.get('EntryTime')
        if pd.isna(entry):
            continue
        symbol = str(trade.get('Symbol', '')).upper()[:3] if 'Symbol' in df_trades.columns else ''
        window_start = entry - pd.Timedelta(hours=hours_window)
        window_end = entry + pd.Timedelta(hours=hours_window)
        mask = (df_cal['EventTime'] >= window_start) & (df_cal['EventTime'] <= window_end)
        if symbol and 'Pais' in df_cal.columns:
            country_map = {'EUR': 'EUR', 'GBP': 'GBP', 'USD': 'USD', 'JPY': 'JPY',
                           'CHF': 'CHF', 'AUD': 'AUD', 'CAD': 'CAD', 'NZD': 'NZD',
                           'XAU': 'USD', 'XAG': 'USD', 'US30': 'USD', 'SPX': 'USD',
                           'NAS': 'USD', 'VIX': 'USD', 'DXY': 'USD'}
            country = country_map.get(symbol, '')
            if country:
                mask = mask & (df_cal['Pais'].str.upper() == country)
        nearby = df_cal[mask]
        if not nearby.empty:
            high = int((nearby['Impacto'] == 'high').sum())
            medium = int((nearby['Impacto'] == 'medium').sum())
            low = int((nearby['Impacto'] == 'low').sum())
            first_event = nearby.iloc[0]['Evento'] if 'Evento' in nearby.columns else ''
            delta_h = (entry - nearby['EventTime'].min()).total_seconds() / 3600
        else:
            high = medium = low = 0
            first_event = ''
            delta_h = 999
        results.append({
            'has_news': high + medium + low > 0,
            'high_impact': high,
            'medium_impact': medium,
            'low_impact': low,
            'total_events': high + medium + low,
            'first_event': first_event,
            'delta_hours': delta_h,
        })
    return results


def analyze_news_impact(df_trades, df_cal):
    """Analisa o impacto de noticias na performance dos trades."""
    news_data = match_trades_with_news(df_trades, df_cal)
    if news_data is None:
        return None
    ndf = pd.DataFrame(news_data)
    df_merged = df_trades.reset_index(drop=True).join(ndf)
    analysis = {}
    for col in ['has_news', 'high_impact']:
        if col not in df_merged.columns:
            continue
        group_0 = df_merged[df_merged[col] == 0]
        group_1 = df_merged[df_merged[col] >= 1] if col == 'high_impact' else df_merged[df_merged[col] == True]
        if len(group_0) < 2 or len(group_1) < 2:
            continue
        key = 'Sem noticias' if col == 'has_news' else 'Sem high-impact'
        key2 = 'Com noticias' if col == 'has_news' else 'Com high-impact'
        analysis[key2] = {
            'count': len(group_1),
            'win_rate': (group_1['Target_Win'].mean() * 100) if 'Target_Win' in group_1.columns else 0,
            'avg_r': group_1['ResultR'].mean() if 'ResultR' in group_1.columns else 0,
        }
        analysis[key] = {
            'count': len(group_0),
            'win_rate': (group_0['Target_Win'].mean() * 100) if 'Target_Win' in group_0.columns else 0,
            'avg_r': group_0['ResultR'].mean() if 'ResultR' in group_0.columns else 0,
        }
    return analysis


def load_and_clean_data(file_path):
    """
    Carrega o CSV com tratamento robusto de encoding e limpeza.
    Suporta Schema v5.0 (107 cols) e v5.1 (114 cols) com detecção automática.

    Correções v3.1:
    - utf-8-sig como primeira tentativa de encoding (BOM detection)
    - Detecta schema version via header #SCHEMA_VERSION=X.Y
    - Suporta v5.0 (107 cols) e v5.1 (114 cols) automaticamente
    - C7: profitFactorTrade removido no v5.1
    - C6: BREAKEVEN → NaN no Target_Win
    - C5: Z-Score rolling preparado (feito em _create_derived_columns)
    - C8: Schema version detection via header
    """
    p = Path(file_path)
    if not p.exists():
        raise FileNotFoundError(f"CSV nao encontrado: {file_path}")

    rows = []
    encodings = ['utf-8-sig', 'utf-8', 'latin-1']
    schema_version = "5.0"
    expected_cols = 107
    columns = None

    for enc in encodings:
        try:
            with p.open('r', encoding=enc, newline='') as f:
                # Check first line for schema version
                first_line = f.readline()
                if first_line.startswith('#SCHEMA_VERSION='):
                    import re
                    match = re.search(r'#SCHEMA_VERSION=([\d.]+)', first_line)
                    if match:
                        schema_version = match.group(1)
                        logger.info(f"Schema version detectado: {schema_version}")
                    if schema_version.startswith('5.1'):
                        expected_cols = 121
                        columns = COLUMNS_V51
                    else:
                        expected_cols = 107
                        columns = COLUMNS_V51[:107]  # v5.0 subset
                    # Reset file pointer
                    f.seek(0)
                else:
                    f.seek(0)
                    schema_version = "5.0"
                    expected_cols = 107
                    columns = COLUMNS_V51[:107]

                reader = csv.reader(f, delimiter=';', quotechar='"')
                rows = list(reader)
            logger.info(f"Arquivo lido com encoding {enc}: {len(rows)} linhas brutas, schema v{schema_version}")
            break
        except (UnicodeDecodeError, Exception) as e:
            logger.debug(f"Encoding {enc} falhou: {e}")
            continue

    if not rows:
        raise ValueError(f"Nao foi possivel ler o CSV: {file_path}")

    before_filter = len(rows)
    rows = [r for r in rows if len(r) == expected_cols]
    filtered = before_filter - len(rows)
    if filtered > 0:
        logger.info(f"[CLEAN] {filtered} linhas ignoradas (colunas != {expected_cols})")

    if not rows:
        raise ValueError(f"Nenhuma linha valida ({expected_cols} colunas) encontrada no CSV")

    df = pd.DataFrame(rows, columns=columns)

    # Skip header row if present
    if df.iloc[0]['TradeID'] in columns or not str(df.iloc[0]['TradeID']).lstrip('\ufeff').isdigit():
        before = len(df)
        df = df.iloc[1:].reset_index(drop=True)
        logger.info(f"[CLEAN] Linha de header removida: {before} -> {len(df)} linhas")

    before = len(df)
    df = df[df['TradeOutcome'].str.strip() != ''].reset_index(drop=True)
    if before != len(df):
        logger.info(f"[CLEAN] Removidas {before - len(df)} linhas sem TradeOutcome")

    before = len(df)
    df = df.drop_duplicates().reset_index(drop=True)
    if before != len(df):
        logger.info(f"[CLEAN] Removidas {before - len(df)} linhas duplicadas")

    cat_cols = ['Symbol', 'Direction', 'TradeOutcome', 'ExitReason',
                'MacroProfile', 'RiskDirection', 'LiquidityState',
                'EntryTime', 'ExitTime', 'RegimeName', 'SessionName',
                'SessionName14', 'BlockingNewsEvent']
    cat_cols = [c for c in cat_cols if c in df.columns]
    df_cat = df[cat_cols].copy()

    for col in df.columns:
        if col not in cat_cols:
            df[col] = pd.to_numeric(df[col].astype(str).str.strip(),
                                    errors='coerce')

    df = df.fillna(0)

    for col in cat_cols:
        df[col] = df_cat[col].fillna('').astype(str).str.strip()

    if 'EntryTime' in df.columns:
        df['EntryTime'] = pd.to_datetime(df['EntryTime'],
                                          format='%Y.%m.%d %H:%M',
                                          errors='coerce')
    if 'ExitTime' in df.columns:
        df['ExitTime'] = pd.to_datetime(df['ExitTime'],
                                         format='%Y.%m.%d %H:%M',
                                         errors='coerce')

    if 'Direction' in df.columns:
        dir_map = {'0': 'SELL', '1': 'BUY', 0: 'SELL', 1: 'BUY',
                    'BUY': 'BUY', 'SELL': 'SELL'}
        df['Direction'] = df['Direction'].map(dir_map).fillna(df['Direction'])

    # C6: BREAKEVEN → NaN no Target_Win (exclui do treino)
    df['Target_Win'] = (df['TradeOutcome'] == 'WIN').astype(int)
    if 'TradeOutcome' in df.columns:
        breakeven_mask = df['TradeOutcome'] == 'BREAKEVEN'
        if breakeven_mask.any():
            df.loc[breakeven_mask, 'Target_Win'] = np.nan
            logger.info(f"[CLEAN] {breakeven_mask.sum()} trades BREAKEVEN → Target_Win=NaN (excluídos do treino)")

    if 'Ticket' in df.columns:
        before = len(df)
        df = df.drop_duplicates(subset='Ticket', keep='last').reset_index(drop=True)
        after = len(df)
        if before != after:
            logger.info(f"[CLEAN] Dedup Ticket: {before} -> {after} trades unicos")

    logger.info(f"[DONE] {len(df)} trades carregados e limpos (schema v{schema_version})")
    return df


class QuantAnalyzer:
    """Motor de analise quantitativa com ordem de execucao corrigida."""

    def __init__(self, df):
        self.df = df.copy()
        self.n = len(df)
        self.symbol = df['Symbol'].iloc[0] if 'Symbol' in df.columns else 'N/A'
        self.date_range = ''
        self.results = {}
        self.initial_balance = df['CurrentBalance'].iloc[0] if 'CurrentBalance' in df.columns else 10000.0

        if 'EntryTime' in df.columns and df['EntryTime'].notna().any():
            dmin = df['EntryTime'].min().strftime('%Y-%m-%d')
            dmax = df['EntryTime'].max().strftime('%Y-%m-%d')
            self.date_range = f"{dmin} a {dmax}"

        self._create_derived_columns()
        self._prepare_features()
        self._run_all_analyses()
        self._train_trees()

    def _create_derived_columns(self):
        """Cria colunas derivadas ANTES de _prepare_features.

        C5: Z-Score Rolling (252, min_periods=50) — elimina look-ahead bias.
        Usa janela rolling de 252 barras (~1 ano) com min_periods=50 para
        calcular mean/std apenas com dados passados (sem look-ahead).
        """
        # Dados ausentes do MQL5 (RiskSentiment/DataMiner):
        # quando o CSV de macro falta, o EA grava -1 (sentinela) em VIX/DXY/SP500
        # e -1 nas news flags. Tratar como NaN para nao contaminar Z-scores nem
        # cair em bucket de regime (Calmo/Fraco/Alta) nem groupbys de noticia.
        for _col in ('VIX', 'DXY', 'SP500'):
            if _col in self.df.columns:
                _invalid = self.df[_col].isna() | (self.df[_col] <= 0)
                if bool(_invalid.any()):
                    logger.info(
                        f"AlphaMiner: {int(_invalid.sum())} trade(s) com {_col}<=0 "
                        f"(macro indisponivel no MQL5) ignorado(s) na analise macro"
                    )
                    self.df.loc[_invalid, _col] = np.nan
        for _col in ('NewsHighActive', 'NewsMediumActive',
                     'MinutesToNextHighNews', 'NewsImpactScore'):
            if _col in self.df.columns:
                _invalid = self.df[_col].isna() | (self.df[_col] < 0)
                if bool(_invalid.any()):
                    self.df.loc[_invalid, _col] = np.nan

        # C5: Rolling Z-Scores (look-ahead free)
        rolling_window = 252
        min_periods = 50
        for raw_col, z_col, state_name, labels in [
            ('VIX', 'VIX_ZScore', 'VIX_State', ['Calmo', 'Neutro', 'Panico']),
            ('DXY', 'DXY_ZScore', 'DXY_State', ['Fraco', 'Neutro', 'Forte']),
            ('SP500', 'SP500_ZScore', 'SP500_State', ['Queda', 'Neutro', 'Alta']),
        ]:
            if raw_col in self.df.columns and raw_col not in ['', '']:
                roll_mean = self.df[raw_col].rolling(rolling_window, min_periods=min_periods).mean()
                roll_std = self.df[raw_col].rolling(rolling_window, min_periods=min_periods).std()
                self.df[z_col] = (self.df[raw_col] - roll_mean) / roll_std
                self.df[state_name] = pd.cut(
                    self.df[z_col],
                    bins=[-99, -0.5, 0.5, 99],
                    labels=labels
                )
            elif z_col in self.df.columns:
                # Já existe (v4 legacy) — mantém para compatibilidade
                self.df[state_name] = pd.cut(
                    self.df[z_col],
                    bins=[-99, -0.5, 0.5, 99],
                    labels=labels
                )

        # VolatilityZScore: se nao existir, derivar de ATR
        if 'VolatilityZScore' not in self.df.columns and 'ATR' in self.df.columns:
            self.df['VolatilityZScore'] = (self.df['ATR'] - self.df['ATR'].mean()) / self.df['ATR'].std()

        if 'EntryHour' in self.df.columns:
            def get_session(h):
                h = int(h)
                if h < 2:           return 'Off_Hours'
                elif h < 6:         return 'Asia_Pacific'
                elif h < 9:         return 'Asia_Japan_SEA'
                elif h < 12:        return 'Europe_London'
                elif h < 14:        return 'Europe_Main'
                elif h < 16:        return 'NY_Pre'
                elif h < 20:        return 'NY_Main'
                elif h < 23:        return 'NY_PM'
                else:               return 'Off_Hours'
            self.df['Session'] = self.df['EntryHour'].apply(get_session)

            # Sessoes expandidas (14 categorias)
            def get_session14(h):
                h = int(h)
                if h < 2:           return 'Off_Hours'
                elif h < 4:         return 'Australia_NZ'
                elif h < 6:         return 'Asia_1_Tokyo'
                elif h < 8:         return 'Asia_2_China_HK'
                elif h < 10:        return 'Asia_3_SE_India'
                elif h < 12:        return 'Europe_Open'
                elif h < 14:        return 'Europe_Main'
                elif h < 16:        return 'NY_Pre_Brazil'
                elif h < 17:        return 'NY_Open'
                elif h < 20:        return 'NY_Main'
                elif h < 22:        return 'NY_Post'
                else:               return 'Off_Hours'
            self.df['Session14'] = self.df['EntryHour'].apply(get_session14)

    def _prepare_features(self):
        """Prepara features para ML. Executa DEPOIS das colunas derivadas."""
        drop = [
            'TradeID', 'Ticket', 'MagicNumber', 'ExitTime', 'ExitPrice',
            'GrossProfit', 'NetProfit', 'Commission', 'Swap',
            'TradeDurationMinutes', 'TradeDurationBars',
            'FinalMAE_Points', 'FinalMFE_Points',
            'ResultR', 'ResultPercent', 'ProfitFactorTrade', 'MFE_R', 'MAE_R',
            'CaptureRatio', 'TradeOutcome', 'Target_Win', 'CatastrophicTrade',
            'MacroProfile', 'Is_Bottom_10', 'VIX_State', 'DXY_State',
        ]
        non_num = self.df.select_dtypes(exclude=[np.number]).columns.tolist()
        drop = list(set(drop + non_num))
        drop = [c for c in drop if c in self.df.columns]
        self.X = self.df.drop(columns=drop).select_dtypes(include=[np.number])
        self.X = self.X.clip(-1e10, 1e10)
        self.y = self.df['Target_Win']
        self.y_reg = self.df['ResultR']

    def _run_all_analyses(self):
        self._basic_stats()
        self._tail_risk()
        self._bootstrap_ci()
        self._macro_analysis()
        self._catastrophe_analysis()
        self._ic_analysis()
        self._effect_sizes()
        self._regime_analysis()
        self._regime_semantic_analysis()    # NOVO v3.1: Regime Semantic flags
        self._news_analysis()               # NOVO v3.1: News flags analysis
        self._temporal_analysis()
        self._autocorrelation()

    def _basic_stats(self):
        r = self.df['ResultR']
        pnl = self.df['NetProfit']
        wins = self.df.loc[self.y == 1]
        losses = self.df.loc[self.y == 0]
        avg_win = wins['NetProfit'].mean() if len(wins) > 0 else 0
        avg_loss = abs(losses['NetProfit'].mean()) if len(losses) > 0 else 0.01
        payoff = avg_win / avg_loss if avg_loss > 0 else 0
        std_r = r.std()
        sharpe_annual = (r.mean() / max(std_r, 1e-10)) * np.sqrt(252) if std_r > 0 else 0
        equity = self.initial_balance + pnl.cumsum()
        equity_peak = equity.cummax()
        dd = equity - equity_peak
        max_dd_amt = dd.min()
        max_dd_pct = (dd.min() / max(equity_peak.max(), 1)) * 100 if len(equity) > 0 else 0
        calmar = abs(sharpe_annual / max(abs(max_dd_pct) / 100, 0.01)) if max_dd_pct < 0 else 0
        sqn = (r.mean() / max(std_r, 1e-10)) * np.sqrt(self.n)
        self.results['basic'] = {
            'n_trades': self.n,
            'win_rate': self.y.mean() * 100,
            'avg_r': r.mean(),
            'median_r': r.median(),
            'std_r': std_r,
            'total_pnl': pnl.sum(),
            'avg_pnl': pnl.mean(),
            'expectancy': pnl.mean(),
            'avg_win': avg_win,
            'avg_loss': -avg_loss,
            'payoff': payoff,
            'profit_factor': (
                wins['NetProfit'].sum()
                / max(abs(losses['NetProfit'].sum()), 0.01)
            ),
            'sharpe_annual': sharpe_annual,
            'calmar': calmar,
            'sqn': sqn,
            'max_drawdown': max_dd_amt,
            'max_drawdown_pct': max_dd_pct,
            'avg_mfe_r': self.df['MFE_R'].mean() if 'MFE_R' in self.df.columns else 0,
            'avg_mae_r': self.df['MAE_R'].mean() if 'MAE_R' in self.df.columns else 0,
            'capture_ratio': self.df['CaptureRatio'].mean() if 'CaptureRatio' in self.df.columns else 0,
            'avg_duration_min': self.df['TradeDurationMinutes'].mean() if 'TradeDurationMinutes' in self.df.columns else 0,
            'direction_split': self.df['Direction'].value_counts().to_dict() if 'Direction' in self.df.columns else {},
            'exit_reason_split': self.df['ExitReason'].value_counts().to_dict() if 'ExitReason' in self.df.columns else {},
        }

    def _tail_risk(self):
        r = self.df['ResultR'].sort_values()
        equity = self.initial_balance + self.df['NetProfit'].cumsum()
        equity_peak = equity.cummax()
        dd = equity - equity_peak
        self.results['tail_risk'] = {
            'cvar_5': r.iloc[:max(1, int(self.n * 0.05))].mean(),
            'cvar_10': r.iloc[:max(1, int(self.n * 0.10))].mean(),
            'worst_trade': r.iloc[0],
            'best_trade': r.iloc[-1],
            'skewness': r.skew(),
            'kurtosis': r.kurtosis(),
            'pct_negative': (r < 0).sum() / self.n * 100,
            'max_consecutive_losses': self._max_consecutive(self.y.values),
            'percentis': {
                'min': r.iloc[0], 'p5': r.iloc[max(0, int(self.n * 0.05) - 1)],
                'p25': r.iloc[max(0, int(self.n * 0.25) - 1)],
                'p50': r.iloc[max(0, int(self.n * 0.50) - 1)],
                'p75': r.iloc[max(0, int(self.n * 0.75) - 1)],
                'p95': r.iloc[max(0, int(self.n * 0.95) - 1)], 'max': r.iloc[-1],
            },
            'max_drawdown_pct': dd.min(),
            'max_drawdown_pct_pct': (dd.min() / max(equity_peak.max(), 1)) * 100,
            'initial_balance': self.initial_balance,
        }

    @staticmethod
    def _max_consecutive(arr):
        max_streak = 0
        streak = 0
        for v in arr:
            if v == 0:
                streak += 1
                max_streak = max(max_streak, streak)
            else:
                streak = 0
        return max_streak

    def _bootstrap_ci(self, n_boot=2000):
        r = self.df['ResultR'].values
        np.random.seed(42)
        boot_means = [np.random.choice(r, size=self.n, replace=True).mean()
                      for _ in range(n_boot)]
        self.results['bootstrap'] = {
            'mean_ci_low': np.percentile(boot_means, 2.5),
            'mean_ci_high': np.percentile(boot_means, 97.5),
            'mean_ci_90_low': np.percentile(boot_means, 5),
            'mean_ci_90_high': np.percentile(boot_means, 95),
            'boot_means': boot_means,
        }
        w = self.y.values
        boot_wr = [np.random.choice(w, size=self.n, replace=True).mean() * 100
                   for _ in range(n_boot)]
        self.results['bootstrap']['wr_ci_low'] = np.percentile(boot_wr, 2.5)
        self.results['bootstrap']['wr_ci_high'] = np.percentile(boot_wr, 97.5)

    def _load_macro_csv(self):
        """Carrega risk_sentiment_daily.csv e mescla com os trades por data."""
        macro_path = r'C:\ALXQuant\data\mql5\risk_sentiment_daily.csv'
        if not os.path.exists(macro_path):
            logger.warning(f"Macro CSV nao encontrado: {macro_path}")
            return None
        try:
            mdf = pd.read_csv(macro_path)
            mdf['date'] = pd.to_datetime(mdf['date'])
            if 'EntryTime' not in self.df.columns:
                return None
            df2 = self.df.copy()
            df2['trade_date'] = df2['EntryTime'].dt.date
            mdf['mdate'] = mdf['date'].dt.date
            merged = df2.merge(mdf, left_on='trade_date', right_on='mdate',
                               how='left')
            logger.info(f"Macro CSV carregado: {len(mdf)} dias, mesclado com {len(merged)} trades")
            return merged, mdf
        except Exception as e:
            logger.warning(f"Falha ao carregar macro CSV: {e}")
            return None

    def _macro_analysis(self):
        macro = {}
        if 'VIX_State' in self.df.columns:
            grp = self.df.groupby('VIX_State', observed=False)['ResultR'].agg(
                ['mean', 'std', 'count'])
            grp['win_rate'] = self.df.groupby('VIX_State', observed=False
                                              )['Target_Win'].mean() * 100
            macro['vix'] = grp.to_dict('index')
        if 'DXY_State' in self.df.columns:
            grp = self.df.groupby('DXY_State', observed=False)['ResultR'].agg(
                ['mean', 'std', 'count'])
            grp['win_rate'] = self.df.groupby('DXY_State', observed=False
                                              )['Target_Win'].mean() * 100
            macro['dxy'] = grp.to_dict('index')

        # Carregar risk_sentiment_daily.csv para macro expandida
        macro_data = self._load_macro_csv()
        if macro_data is not None:
            merged, mdf_full = macro_data
            macro_cols = ['yield_curve', 'fed_funds', 'hy_spread',
                          'reverse_repo', 'cpi', 'core_pce', 'global_risk_score',
                          'vix', 'usd_index']
            macro_cols = [c for c in macro_cols if c in merged.columns]
            for col in macro_cols:
                if merged[col].isna().all():
                    continue
                # Binarizar pela mediana
                median_val = merged[col].median()
                merged[f'{col}_regime'] = (merged[col] > median_val).astype(int)
                grp = merged.groupby(f'{col}_regime')['ResultR'].agg(
                    ['mean', 'std', 'count'])
                grp['win_rate'] = merged.groupby(f'{col}_regime'
                                                 )['Target_Win'].mean() * 100
                label_map = {0: f'Baixo_{col}', 1: f'Alto_{col}'}
                grp.index = [label_map.get(i, str(i)) for i in grp.index]
                macro[col] = grp.to_dict('index')
            self.results['macro_merged'] = merged
            self.results['macro_full'] = mdf_full

        self.results['macro'] = macro

    def _catastrophe_analysis(self):
        corte_bad = self.df['ResultR'].quantile(0.10)
        corte_good = self.df['ResultR'].quantile(0.90)

        mask_bad = self.df['ResultR'] <= corte_bad
        mask_good = self.df['ResultR'] >= corte_good
        mask_mid = ~mask_bad & ~mask_good

        df_bad = self.df[mask_bad]
        df_good = self.df[mask_good]
        df_mid = self.df[mask_mid]
        df_ok = self.df[~mask_bad]  # restante (mid + good) para compatibilidade

        num_vars = [
            'Hurst', 'Confidence_R2', 'Strength', 'SlopeNormalized',
            'MomentumState', 'ATR', 'DistanceVWAP_ATR', 'SpreadAnomaly',
            'RelativeVolume', 'VIX_ZScore', 'DXY_ZScore', 'VIX_PctChange',
            'DXY_PctChange', 'VolatilityZScore', 'RiskScore', 'InitialRisk',
            'SpreadAtExit', 'MFE_Points', 'MAE_Points', 'CurrentMarginLevel',
        ]
        num_vars = [v for v in num_vars if v in self.df.columns]

        comparison = {}
        comparison_best = {}
        for col in num_vars:
            bad_vals = df_bad[col].dropna()
            ok_vals = df_ok[col].dropna()
            good_vals = df_good[col].dropna() if len(df_good) > 0 else pd.Series(dtype=float)
            if len(bad_vals) >= 2 and len(ok_vals) >= 2:
                try:
                    stat_u, p_val = mannwhitneyu(bad_vals, ok_vals,
                                                 alternative='two-sided')
                except Exception:
                    p_val = 1.0
                pooled_std = np.sqrt((bad_vals.std()**2 + ok_vals.std()**2) / 2)
                cohens_d = (ok_vals.mean() - bad_vals.mean()) / max(pooled_std, 1e-10)
                comparison[col] = {
                    'bad_mean': bad_vals.mean(),
                    'ok_mean': ok_vals.mean(),
                    'delta': ok_vals.mean() - bad_vals.mean(),
                    'p_value': p_val,
                    'significant': p_val < 0.10,
                    'cohens_d': cohens_d,
                }
            # Best 10% vs worst 10%
            if len(bad_vals) >= 2 and len(good_vals) >= 2:
                try:
                    stat_u, p_val = mannwhitneyu(bad_vals, good_vals,
                                                 alternative='two-sided')
                except Exception:
                    p_val = 1.0
                pooled_std = np.sqrt((bad_vals.std()**2 + good_vals.std()**2) / 2)
                cohens_d = (good_vals.mean() - bad_vals.mean()) / max(pooled_std, 1e-10)
                melhorias = {}
                if col in ['VIX_ZScore', 'VolatilityZScore', 'SpreadAtExit']:
                    valor_filtro = good_vals.mean() + 0.5 * good_vals.std()
                    if good_vals.mean() < bad_vals.mean():
                        filtro_dir = 'menor que'
                        evitados = (self.df[col] > valor_filtro).sum()
                        subtotal = (self.df[col] > valor_filtro) & mask_bad
                        losses_evitados = subtotal.sum()
                    else:
                        filtro_dir = 'maior que'
                        evitados = (self.df[col] < valor_filtro).sum()
                        subtotal = (self.df[col] < valor_filtro) & mask_bad
                        losses_evitados = subtotal.sum()
                else:
                    valor_filtro = good_vals.mean()
                    evitados = 0
                    losses_evitados = 0
                    filtro_dir = ''
                comparison_best[col] = {
                    'bad_mean': bad_vals.mean(),
                    'good_mean': good_vals.mean(),
                    'delta': good_vals.mean() - bad_vals.mean(),
                    'p_value': p_val,
                    'significant': p_val < 0.10,
                    'cohens_d': cohens_d,
                    'valor_filtro': valor_filtro,
                    'losses_evitados': int(losses_evitados),
                    'filtro_dir': filtro_dir,
                }

        cat_vars = ['Direction', 'Trending', 'ChaosRegime', 'isHighVIX',
                    'LiquiditySafe', 'HighVol', 'LowVol', 'StrongMomentum']
        cat_vars = [v for v in cat_vars if v in self.df.columns]

        cat_comparison = {}
        for col in cat_vars:
            bad_props = df_bad[col].value_counts(normalize=True)
            ok_props = df_ok[col].value_counts(normalize=True)
            for cat_val in set(bad_props.index) | set(ok_props.index):
                b = bad_props.get(cat_val, 0) * 100
                o = ok_props.get(cat_val, 0) * 100
                cat_comparison[f"{col}={cat_val}"] = {
                    'bad_pct': b, 'ok_pct': o, 'delta': b - o
                }

        self.results['catastrophe'] = {
            'threshold': corte_bad,
            'n_bad': len(df_bad),
            'n_ok': len(df_ok),
            'n_good': len(df_good),
            'numeric': comparison,
            'best_vs_worst': comparison_best,
            'categorical': cat_comparison,
        }

    def _ic_analysis(self):
        ics = {}
        for col in self.X.columns:
            if self.X[col].std() < 1e-10:
                continue
            corr, pval = spearmanr(self.X[col], self.y_reg)
            ics[col] = {'ic': corr, 'p_value': pval, 'abs_ic': abs(corr)}
        self.results['ic'] = sorted(ics.items(),
                                    key=lambda x: x[1]['abs_ic'],
                                    reverse=True)

    def _effect_sizes(self):
        df_win = self.df[self.y == 1]
        df_loss = self.df[self.y == 0]
        effects = {}
        for col in self.X.columns:
            w = df_win[col].dropna()
            l = df_loss[col].dropna()
            if len(w) < 2 or len(l) < 2:
                continue
            pooled = np.sqrt((w.std()**2 + l.std()**2) / 2)
            if pooled < 1e-10:
                continue
            d = (w.mean() - l.mean()) / pooled
            effects[col] = d
        self.results['effect_sizes'] = sorted(effects.items(),
                                              key=lambda x: abs(x[1]),
                                              reverse=True)

    def _regime_analysis(self):
        regime_features = ['ATR', 'VolatilityZScore', 'VIX_ZScore',
                           'DXY_ZScore', 'Hurst', 'RelativeVolume',
                           'SpreadAtExit']
        regime_features = [f for f in regime_features if f in self.X.columns]

        if len(regime_features) < 3:
            self.results['regime'] = None
            return

        X_regime = self.X[regime_features].copy()
        valid_mask = X_regime.notna().all(axis=1)
        if valid_mask.sum() < 10:
            self.results['regime'] = None
            return

        X_regime_clean = X_regime[valid_mask]

        scaler = StandardScaler()
        X_scaled = scaler.fit_transform(X_regime_clean)

        n_clusters = min(3, len(X_regime_clean) // 5)
        if n_clusters < 2:
            self.results['regime'] = None
            return

        km = KMeans(n_clusters=n_clusters, random_state=42, n_init=10)
        labels = km.fit_predict(X_scaled)

        # Gerar labels descritivos baseados nos centros
        centroids = scaler.inverse_transform(km.cluster_centers_)
        centroid_df = pd.DataFrame(centroids, columns=regime_features)
        desc_labels = {}
        for i in range(n_clusters):
            row = centroid_df.iloc[i]
            parts = []
            if abs(row['ATR']) > row.drop('ATR').abs().max() * 0.6:
                parts.append('ATR+' if row['ATR'] > 0 else 'ATR-')
            if 'VIX_ZScore' in regime_features and abs(row['VIX_ZScore']) > 0.5:
                parts.append('Panico' if row['VIX_ZScore'] > 0 else 'Calma')
            if 'VolatilityZScore' in regime_features and abs(row['VolatilityZScore']) > 0.5:
                parts.append('Alta_Vol' if row['VolatilityZScore'] > 0 else 'Baixa_Vol')
            if 'Hurst' in regime_features and abs(row['Hurst']) > 0.3:
                parts.append('Trend' if row['Hurst'] > 0.6 else 'Reversao')
            if 'RelativeVolume' in regime_features and abs(row['RelativeVolume']) > 0.5:
                parts.append('Alto_Vol' if row['RelativeVolume'] > 0 else 'Baixo_Vol')
            if not parts:
                parts.append(f'Regime_{i}')
            desc_labels[i] = '_'.join(parts)

        regime_perf = {}
        regime_plot_data = {}
        for lbl in range(n_clusters):
            regime_index = X_regime_clean.index[labels == lbl]
            subset = self.df.loc[regime_index]
            if len(subset) > 0:
                regime_perf[desc_labels[lbl]] = {
                    'n': len(subset),
                    'avg_r': subset['ResultR'].mean(),
                    'win_rate': subset['Target_Win'].mean() * 100,
                    'avg_atr': subset['ATR'].mean() if 'ATR' in subset.columns else 0,
                    'avg_vol_z': subset['VolatilityZScore'].mean() if 'VolatilityZScore' in subset.columns else 0,
                }

        # PCA for visualization
        from sklearn.decomposition import PCA
        pca = PCA(n_components=2, random_state=42)
        X_pca = pca.fit_transform(X_scaled)
        centroids_pca = pca.transform(km.cluster_centers_)
        regime_plot_data = {
            'X_pca': X_pca,
            'labels': labels,
            'centroids_pca': centroids_pca,
            'desc_labels': desc_labels,
            'n_clusters': n_clusters,
            'var_explained': pca.explained_variance_ratio_,
            'regime_features': regime_features,
        }

        self.results['regime'] = regime_perf
        self.regime_plot_data = regime_plot_data

    def _temporal_analysis(self):
        temporal = {}
        for col in ['EntryHour', 'DayOfWeek']:
            if col not in self.df.columns:
                continue
            grp = self.df.groupby(col)['ResultR'].agg(['mean', 'std', 'count'])
            grp['win_rate'] = self.df.groupby(col)['Target_Win'].mean() * 100
            temporal[col] = grp.to_dict('index')

        if 'Session' in self.df.columns:
            sess = self.df.groupby('Session')['ResultR'].agg(['mean', 'count'])
            sess['win_rate'] = self.df.groupby('Session')['Target_Win'].mean() * 100
            temporal['Session'] = sess.to_dict('index')

        if 'Session14' in self.df.columns:
            sess14 = self.df.groupby('Session14')['ResultR'].agg(['mean', 'std', 'count'])
            sess14['win_rate'] = self.df.groupby('Session14')['Target_Win'].mean() * 100
            temporal['Session14'] = sess14.to_dict('index')

        self.results['temporal'] = temporal

    def _regime_semantic_analysis(self):
        """Análise dos regime semantic flags (v5.1) — performance por regime semântico."""
        regime_cols = [
            'RegimeTrendStrongBull', 'RegimeTrendStrongBear',
            'RegimeTrendWeakBull', 'RegimeTrendWeakBear',
            'RegimeRangeTight', 'RegimeRangeVolatile',
            'RegimeChaos', 'RegimeReversalImminent', 'RegimeBreakoutForming'
        ]
        regime_cols = [c for c in regime_cols if c in self.df.columns]
        if not regime_cols:
            self.results['regime_semantic'] = None
            return

        regime_perf = {}
        for col in regime_cols:
            grp = self.df.groupby(col)['ResultR'].agg(['mean', 'std', 'count'])
            grp['win_rate'] = self.df.groupby(col)['Target_Win'].mean() * 100
            grp['avg_mfe_r'] = self.df.groupby(col)['MFE_R'].mean() if 'MFE_R' in self.df.columns else 0
            grp['avg_mae_r'] = self.df.groupby(col)['MAE_R'].mean() if 'MAE_R' in self.df.columns else 0
            grp['capture_ratio'] = self.df.groupby(col)['CaptureRatio'].mean() if 'CaptureRatio' in self.df.columns else 0
            # Renomeia índice 0/1 para nomes descritivos (só se tiver 2 grupos)
            if len(grp) == 2:
                grp.index = ['Ausente', 'Presente']
            regime_perf[col] = grp.to_dict('index')

        self.results['regime_semantic'] = regime_perf

    def _news_analysis(self):
        """Análise de impacto das news flags (v5.1) — performance com/sem notícias."""
        news_cols = ['NewsHighActive', 'NewsMediumActive', 'NewsImpactScore']
        news_cols = [c for c in news_cols if c in self.df.columns]
        if not news_cols:
            self.results['news'] = None
            return

        news_perf = {}
        for col in news_cols:
            if col == 'NewsImpactScore':
                # Score 0-3: binarizar (0 vs >=1)
                mask = self.df[col] >= 1
                grp = self.df.groupby(mask)['ResultR'].agg(['mean', 'std', 'count'])
                grp['win_rate'] = self.df.groupby(mask)['Target_Win'].mean() * 100
                if len(grp) == 2:
                    grp.index = ['Sem_Impacto', 'Com_Impacto']
            else:
                grp = self.df.groupby(col)['ResultR'].agg(['mean', 'std', 'count'])
                grp['win_rate'] = self.df.groupby(col)['Target_Win'].mean() * 100
                if len(grp) == 2:
                    grp.index = ['Ausente', 'Presente']
            news_perf[col] = grp.to_dict('index')

        # Análise combinada: NewsHighActive + RegimeChaos
        if 'NewsHighActive' in self.df.columns and 'RegimeChaos' in self.df.columns:
            combo = self.df.groupby(['NewsHighActive', 'RegimeChaos'])['ResultR'].agg(['mean', 'count'])
            combo['win_rate'] = self.df.groupby(['NewsHighActive', 'RegimeChaos'])['Target_Win'].mean() * 100
            news_perf['NewsHigh_x_RegimeChaos'] = combo.to_dict('index')

        # False Block Rate: NewsHighActive=1 mas trade seria WIN
        if 'NewsHighActive' in self.df.columns:
            news_trades = self.df[self.df['NewsHighActive'] == 1]
            if len(news_trades) > 0:
                false_blocks = news_trades[news_trades['Target_Win'] == 1]
                news_perf['false_block_rate'] = {
                    'total_news_blocked': len(news_trades),
                    'false_blocks': len(false_blocks),
                    'false_block_pct': len(false_blocks) / len(news_trades) * 100,
                    'avg_r_if_taken': false_blocks['ResultR'].mean() if len(false_blocks) > 0 else 0
                }

        self.results['news'] = news_perf
        self._autocorrelation()

    def _autocorrelation(self):
        """Calcula autocorrelação dos retornos R."""
        r = self.df['ResultR'].values
        if len(r) < 5:
            self.results['autocorr'] = {'lag1': 0, 'p_value': 1, 'ljung_box_q': 0, 'ljung_box_p': 1}
            return
        ac = np.corrcoef(r[:-1], r[1:])[0, 1]
        n = len(r) - 1
        t_stat = ac * np.sqrt((n - 2) / (1 - ac**2 + 1e-10))
        p_val = 2 * (1 - stats.t.cdf(abs(t_stat), n - 2))

        # Ljung-Box Q test (lag=1,5,10)
        from scipy.stats import chi2
        lb_stats = {}
        for test_lag in [1, 5, 10]:
            if len(r) <= test_lag + 5:
                continue
            T = len(r)
            lb_q = T * (T + 2) * sum((np.corrcoef(r[:-i], r[i:])[0, 1]**2) / (T - i) for i in range(1, test_lag + 1))
            lb_p = 1 - chi2.cdf(lb_q, test_lag)
            lb_stats[test_lag] = {'q_stat': lb_q, 'p_value': lb_p}

        self.results['autocorr'] = {
            'lag1': ac, 'p_value': p_val,
            'ljung_box': lb_stats
        }

    def _train_trees(self):
        corte = self.df['ResultR'].quantile(0.10)
        y_cat = (self.df['ResultR'] <= corte).astype(int)

        # Catastrophe tree with GridSearch
        gs_cat = GridSearchCV(
            DecisionTreeClassifier(random_state=42),
            {'max_depth': [2, 3, 4], 'min_samples_leaf': [5, 10, 15]},
            cv=min(3, max(2, y_cat.sum())), scoring='roc_auc', n_jobs=1
        )
        gs_cat.fit(self.X, y_cat)
        self.tree_catastrophe = gs_cat.best_estimator_
        self.catastrophe_cv_score = gs_cat.best_score_

        # Win/Loss tree with GridSearch
        gs_wl = GridSearchCV(
            DecisionTreeClassifier(random_state=42),
            {'max_depth': [2, 3, 4], 'min_samples_leaf': [5, 10, 15]},
            cv=min(3, max(2, self.y.sum())), scoring='roc_auc', n_jobs=1
        )
        gs_wl.fit(self.X, self.y)
        self.tree_winloss = gs_wl.best_estimator_

        # Random Forest + permutation importance
        if self.n >= 20:
            rf = RandomForestClassifier(
                n_estimators=100, max_depth=4, random_state=42)
            rf.fit(self.X, self.y)

            # Permutation importance with 3-fold
            try:
                perm = permutation_importance(
                    rf, self.X, self.y, n_repeats=10,
                    random_state=42, n_jobs=1
                )
                fi_mean = perm.importances_mean
                fi_std = perm.importances_std
                self.feature_importances = sorted(
                    zip(self.X.columns, fi_mean, fi_std),
                    key=lambda x: x[1], reverse=True
                )
                self.results['perm_importance'] = perm
            except Exception:
                # Fallback to default importance
                self.feature_importances = sorted(
                    zip(self.X.columns, rf.feature_importances_, [0]*len(self.X.columns)),
                    key=lambda x: x[1], reverse=True
                )

            # Cross-val score
            try:
                cv_scores = cross_val_score(rf, self.X, self.y, cv=min(3, self.n//10),
                                            scoring='roc_auc')
                self.rf_cv_mean = cv_scores.mean()
                self.rf_cv_std = cv_scores.std()
            except Exception:
                self.rf_cv_mean = 0
                self.rf_cv_std = 0
        else:
            self.feature_importances = []
            self.rf_cv_mean = 0
            self.rf_cv_std = 0

        # SHAP
        self.shap_values = None
        self.shap_explainer = None
        if SHAP_AVAILABLE and self.n >= 50:
            try:
                self.shap_explainer = shap.TreeExplainer(rf)
                self.shap_values = self.shap_explainer.shap_values(self.X)
                logger.info(f"SHAP TreeExplainer OK: {self.shap_values.shape}")
            except Exception as e:
                logger.warning(f"SHAP TreeExplainer falhou: {e}. Tentando LinearExplainer...")
                try:
                    from sklearn.linear_model import LinearRegression
                    lin = LinearRegression()
                    lin.fit(self.X, self.y_reg)
                    self.shap_explainer = shap.LinearExplainer(lin, self.X)
                    self.shap_values = self.shap_explainer.shap_values(self.X)
                except Exception as e2:
                    logger.warning(f"SHAP LinearExplainer tambem falhou: {e2}")
        elif SHAP_AVAILABLE and self.n < 50:
            logger.info("SHAP ignorado: necessario minimo 50 trades")

        self.results['feature_importances'] = self.feature_importances


class NarrativeEngine:
    """Interpretacao automatica dos achados quantitativos."""

    @staticmethod
    def executive_summary(a):
        b = a.results['basic']
        t = a.results['tail_risk']
        boot = a.results['bootstrap']
        ac = a.results.get('autocorr', {})
        lines = []

        # Veredicto
        n_low = a.n < 30
        wr = b['win_rate']
        avg_r = b['avg_r']
        ci_positive = boot.get('mean_ci_low', 0) > 0

        if wr >= 55 and avg_r > 0.3 and ci_positive:
            verdict = "[OK] ROBUSTO"
            status_color = "green"
            verdict_desc = (
                f"[OK] Edge estatistico confirmado: WR={wr:.1f}%, R_medio={avg_r:.2f}R. "
                f"IC95% ({boot['mean_ci_low']:.2f}R a {boot['mean_ci_high']:.2f}R) "
                "exclui zero, indicando robustez."
                + (" [ATENCAO] Amostra pequena (n<30) - validar out-of-sample."
                   if n_low else "")
            )
        elif wr >= 50 and avg_r > 0:
            verdict = "[OK] POSITIVO"
            status_color = "orange"
            verdict_desc = (
                f"[OK] Resultado positivo (R_medio={avg_r:.2f}R), WR={wr:.1f}%. "
                + ("[ATENCAO] IC95% inclui zero - edge pode ser ruido."
                   if not ci_positive else "IC95% positivo, porem WR moderado.")
                + (" [ATENCAO] Amostra pequena, validar out-of-sample." if n_low else "")
            )
        else:
            verdict = "[CRITICO] NEGATIVO"
            status_color = "red"
            verdict_desc = (
                f"[CRITICO] Sem edge detectado: WR={wr:.1f}%, R_medio={avg_r:.2f}R. "
                "Revisar modelo e parametros antes de operar ao vivo."
            )

        lines.append(f'<font color="{status_color}"><b>{verdict}</b></font><br/>')
        lines.append(verdict_desc)
        lines.append("")

        # Alertas com [OK]/[ATENCAO]/[CRITICO]
        alerts = []
        # Skewness
        if t['skewness'] < -1:
            alerts.append(
                f"[CRITICO] Assimetria lateral esquerda severa (skew={t['skewness']:.2f}): "
                f"trades catastroficos podem anular wins. Revisar stop-loss.")
        elif t['skewness'] < -0.5:
            alerts.append(
                f"[ATENCAO] Assimetria negativa (skew={t['skewness']:.2f}): "
                f"perdas sao mais extremas que ganhos.")
        else:
            alerts.append(
                f"[OK] Assimetria controlada (skew={t['skewness']:.2f}).")

        # Consecutive losses
        if t['max_consecutive_losses'] >= 5:
            alerts.append(
                f"[CRITICO] Sequencia de {t['max_consecutive_losses']} perdas consecutivas. "
                f"Risco psicologico e de capital elevado. Implementar cool-off period.")
        elif t['max_consecutive_losses'] >= 3:
            alerts.append(
                f"[ATENCAO] Max {t['max_consecutive_losses']} perdas consecutivas. "
                f"Monitorar.")

        capture_ratio = b.get('capture_ratio', 1)
        if capture_ratio < 0.3:
            alerts.append(
                f"[ATENCAO] Capture Ratio baixo ({capture_ratio:.0%}): "
                f"a estrategia captura pouco do movimento. Ajustar TP/trailing stop.")
        elif capture_ratio < 0.6:
            alerts.append(
                f"[OK] Capture Ratio aceitavel ({capture_ratio:.0%}). "
                f"Ha espaco para melhoria no TP.")
        else:
            alerts.append(
                f"[OK] Capture Ratio bom ({capture_ratio:.0%}).")

        if ac.get('lag1', 0) < -0.3 and ac.get('p_value', 1) < 0.1:
            alerts.append(
                "[OK] Autocorrelacao negativa significativa: "
                "apos perda, proximo trade tende a ser melhor (mean-reversion).")
        elif ac.get('lag1', 0) > 0.3 and ac.get('p_value', 1) < 0.1:
            alerts.append(
                "[ATENCAO] Autocorrelacao positiva significativa: efeito momentum. "
                "Cuidado com perdas em serie.")

        if t['cvar_5'] < -2:
            alerts.append(
                f"[CRITICO] CVaR 5% = {t['cvar_5']:.2f}R: perda media no pior cenario "
                f"excede 2R. Reduzir tamanho da posicao.")
        elif t['cvar_5'] < -1:
            alerts.append(
                f"[ATENCAO] CVaR 5% = {t['cvar_5']:.2f}R: monitorar dimensionamento.")

        if alerts:
            lines.append("<b>Alertas de Risco:</b>")
            for al in alerts:
                lines.append(f"• {al}")
            lines.append("")

        fi = a.results.get('feature_importances', [])
        if fi:
            top3 = fi[:3]
            feat_str = ", ".join([
                f[0].replace('_', ' ') for f in top3 if f[1] > 0.01])
            if feat_str:
                lines.append(f"<b>Top Features Discriminantes:</b> {feat_str}")

        return "<br/>".join(lines)

    @staticmethod
    def macro_interpretation(a):
        macro = a.results.get('macro', {})
        lines = []

        if 'vix' in macro:
            vix = macro['vix']
            n_calm = vix.get('Calmo', {}).get('count', 0)
            n_panic = vix.get('Panico', {}).get('count', 0)
            if n_calm > 0 and n_panic > 0:
                wr_calm = vix.get('Calmo', {}).get('win_rate', 0)
                wr_panic = vix.get('Panico', {}).get('win_rate', 0)
                r_calm = vix.get('Calmo', {}).get('mean', 0)
                r_panic = vix.get('Panico', {}).get('mean', 0)
                diff = r_calm - r_panic
                if abs(diff) > 0.5:
                    better = "calmo" if diff > 0 else "panico"
                    lines.append(
                        f"[{'OK' if diff > 0 else 'ATENCAO'}] <b>VIX:</b> Estrategia "
                        f"performa {'melhor' if diff > 0 else 'pior'} em regimes {better}. "
                        f"R_medio: {r_calm:.2f}R (calmo, WR={wr_calm:.0f}%, n={n_calm}) vs "
                        f"{r_panic:.2f}R (panico, WR={wr_panic:.0f}%, n={n_panic}).")
                else:
                    lines.append(
                        f"[OK] <b>VIX:</b> Diferenca entre regimes nao significativa "
                        f"({r_calm:.2f}R calmo vs {r_panic:.2f}R panico).")
            elif n_calm > 0:
                lines.append(f"[OK] <b>VIX:</b> Dados apenas em regime calmo (n={n_calm}).")
            elif n_panic > 0:
                lines.append(f"[ATENCAO] <b>VIX:</b> Dados apenas em regime de panico (n={n_panic}).")
            else:
                lines.append("[ATENCAO] <b>VIX:</b> Dados insuficientes para analise.")

        if 'dxy' in macro:
            dxy = macro['dxy']
            n_strong = dxy.get('Forte', {}).get('count', 0)
            n_weak = dxy.get('Fraco', {}).get('count', 0)
            if n_strong > 0 and n_weak > 0:
                r_strong = dxy.get('Forte', {}).get('mean', 0)
                r_weak = dxy.get('Fraco', {}).get('mean', 0)
                diff = r_strong - r_weak
                if abs(diff) > 0.3:
                    lines.append(
                        f"<b>DXY:</b> Performance diferenciada por regime do Dolar: "
                        f"{r_strong:.2f}R (DXY forte, n={n_strong}) vs "
                        f"{r_weak:.2f}R (DXY fraco, n={n_weak}).")

        return "<br/>".join(lines) if lines else "Dados macro insuficientes."

    @staticmethod
    def catastrophe_interpretation(a):
        cat = a.results.get('catastrophe', {})
        num = cat.get('numeric', {})
        bvw = cat.get('best_vs_worst', {})
        lines = []

        significant = [(k, v) for k, v in num.items()
                       if v['significant'] and abs(v['cohens_d']) > 0.3]
        significant.sort(key=lambda x: abs(x[1]['cohens_d']), reverse=True)

        if significant:
            lines.append(
                f"[{'CRITICO' if len(significant) > 3 else 'ATENCAO'}] "
                f"Identificadas <b>{len(significant)} variaveis</b> com efeito "
                f"significativo (p<0.10, |d|>0.3) entre piores 10% e restante:")
            for feat, vals in significant[:6]:
                direction = "MAIOR" if vals['delta'] < 0 else "MENOR"
                magnitude = ("pequeno" if abs(vals['cohens_d']) < 0.5
                             else ("medio" if abs(vals['cohens_d']) < 0.8
                                   else "grande"))
                sig_flag = "***" if vals['p_value'] < 0.01 else (
                    "**" if vals['p_value'] < 0.05 else "*")
                lines.append(
                    f"• <b>{feat}</b>: {direction} nos piores "
                    f"(piores={vals['bad_mean']:.2f} vs resto={vals['ok_mean']:.2f}, "
                    f"d={vals['cohens_d']:.2f} {sig_flag}, efeito {magnitude})")
        else:
            lines.append(
                "[OK] Nenhuma variavel isolada mostrou diferenca significativa "
                "entre piores 10% e restante. Perdas sao diffuso.")

        # Best vs worst
        if bvw:
            sig_bvw = [(k, v) for k, v in bvw.items()
                       if v.get('significant') and abs(v.get('cohens_d', 0)) > 0.5]
            if sig_bvw:
                lines.append("<b>Comparacao Piores vs Melhores 10%:</b>")
                for feat, vals in sig_bvw[:4]:
                    losses_evit = vals.get('losses_evitados', 0)
                    conf = "ALTO" if vals.get('cohens_d', 0) > 0.8 else (
                        "MEDIO" if vals.get('cohens_d', 0) > 0.5 else "BAIXO")
                    lines.append(
                        f"[{conf}] <b>{feat}</b>: piores={vals['bad_mean']:.2f} vs "
                        f"melhores={vals['good_mean']:.2f} "
                        f"(d={vals['cohens_d']:.2f}). "
                        f"Filtro: {vals.get('filtro_dir', 'ajuste')} "
                        f"{vals.get('valor_filtro', 0):.2f} "
                        f"(~{losses_evit} perdas evitadas de {a.n} trades)")

        cat_comp = cat.get('categorical', {})
        notable = [(k, v) for k, v in cat_comp.items() if abs(v['delta']) > 15]
        if notable:
            lines.append("<b>Padroes categoricos notaveis:</b>")
            for name, vals in notable[:4]:
                lines.append(
                    f"[ATENCAO] {name}: presente em {vals['bad_pct']:.0f}% dos piores vs "
                    f"{vals['ok_pct']:.0f}% do resto (delta={vals['delta']:+.0f}pp)")

        return "<br/>".join(lines) if lines else "Analise nao disponivel."

    @staticmethod
    def temporal_interpretation(a):
        temp = a.results.get('temporal', {})
        lines = []
        if 'Session' in temp:
            sess = temp['Session']
            best = max(sess.items(), key=lambda x: x[1].get('mean', -999))
            worst = min(sess.items(), key=lambda x: x[1].get('mean', 999))
            spread = best[1].get('mean', 0) - worst[1].get('mean', 0)
            if spread > 0.3:
                tag = "[OK]" if best[1].get('mean', 0) > 0 else "[ATENCAO]"
                lines.append(
                    f"{tag} <b>Sessoes (8 grupos):</b> Melhor <b>{best[0]}</b> "
                    f"(R={best[1].get('mean', 0):.2f}, WR={best[1].get('win_rate', 0):.1f}%) "
                    f"vs pior <b>{worst[0]}</b> (R={worst[1].get('mean', 0):.2f}).")
        if 'Session14' in temp:
            sess14 = temp['Session14']
            best14 = max(sess14.items(), key=lambda x: x[1].get('mean', -999))
            worst14 = min(sess14.items(), key=lambda x: x[1].get('mean', 999))
            if best14[1].get('mean', 0) - worst14[1].get('mean', 0) > 0.3:
                lines.append(
                    f"<b>Sessoes (14 grupos detalhados):</b> Melhor <b>{best14[0]}</b> "
                    f"(R={best14[1].get('mean', 0):.2f}, n={best14[1].get('count', 0)}) "
                    f"vs pior <b>{worst14[0]}</b> (R={worst14[1].get('mean', 0):.2f}).")
        if 'EntryHour' in temp:
            hours = temp['EntryHour']
            bad = [(str(int(k)), v) for k, v in hours.items()
                   if v.get('mean', 0) < -0.5 and v.get('count', 0) >= 2]
            if bad:
                h_str = ", ".join([f"{h}h" for h, _ in bad])
                worst_h = min(temp['EntryHour'].items(), key=lambda x: x[1].get('mean', 999))
                lines.append(
                    f"[ATENCAO] <b>Horarios de risco:</b> {h_str} com R negativo. "
                    f"Pior: {int(worst_h[0])}h "
                    f"(R={worst_h[1].get('mean', 0):.2f}, WR={worst_h[1].get('win_rate', 0):.1f}%, "
                    f"n={worst_h[1].get('count', 0)}).")
        if 'DayOfWeek' in temp:
            days = {0: 'Dom', 1: 'Seg', 2: 'Ter', 3: 'Qua', 4: 'Qui', 5: 'Sex', 6: 'Sab'}
            dow = temp['DayOfWeek']
            best_d = max(dow.items(), key=lambda x: x[1].get('mean', -999))
            worst_d = min(dow.items(), key=lambda x: x[1].get('mean', 999))
            bd_name = days.get(int(best_d[0]), str(best_d[0]))
            wd_name = days.get(int(worst_d[0]), str(worst_d[0]))
            spread_d = best_d[1].get('mean', 0) - worst_d[1].get('mean', 0)
            if spread_d > 0.3:
                tag = "[OK]" if best_d[1].get('mean', 0) > 0 else "[ATENCAO]"
                lines.append(
                    f"{tag} <b>Dias:</b> {bd_name} (R={best_d[1].get('mean', 0):.2f}, "
                    f"WR={best_d[1].get('win_rate', 0):.1f}%) "
                    f"vs {wd_name} (R={worst_d[1].get('mean', 0):.2f}, "
                    f"WR={worst_d[1].get('win_rate', 0):.1f}%).")
        return "<br/>".join(lines) if lines else "[OK] Padroes temporais nao significativos."

    @staticmethod
    def regime_semantic_interpretation(a):
        """Interpretação dos regime semantic flags (v5.1)."""
        regime = a.results.get('regime_semantic', {})
        if not regime:
            return "Dados de regime semântico indisponíveis."
        lines = []
        lines.append("<b>Performance por Regime Semântico (v5.1):</b>")

        regime_priority = [
            ('RegimeChaos', 'CHAOS', 'CRITICO'),
            ('RegimeRangeVolatile', 'RANGE_VOLATIL', 'ATENCAO'),
            ('RegimeTrendWeakBull', 'TREND_FRACO_BULL', 'ATENCAO'),
            ('RegimeTrendWeakBear', 'TREND_FRACO_BEAR', 'ATENCAO'),
            ('RegimeRangeTight', 'RANGE_APERTADO', 'OK'),
            ('RegimeTrendStrongBull', 'TREND_FORTE_BULL', 'OK'),
            ('RegimeTrendStrongBear', 'TREND_FORTE_BEAR', 'OK'),
            ('RegimeReversalImminent', 'REVERSÃO_IMINENTE', 'ATENCAO'),
            ('RegimeBreakoutForming', 'BREAKOUT_FORMING', 'ATENCAO'),
        ]

        for col, name, default_tag in regime_priority:
            if col not in regime:
                continue
            data = regime[col]
            presente = data.get('Presente', {})
            ausente = data.get('Ausente', {})
            if not presente or not ausente:
                continue
            r_pres = presente.get('mean', 0)
            r_aus = ausente.get('mean', 0)
            wr_pres = presente.get('win_rate', 0)
            wr_aus = ausente.get('win_rate', 0)
            n_pres = presente.get('count', 0)
            diff = r_pres - r_aus
            tag = '[OK]' if diff > 0.1 else ('[ATENCAO]' if diff < -0.1 else '[OK]')
            lines.append(
                f"{tag} <b>{name}:</b> Presente (n={n_pres}, WR={wr_pres:.1f}%, R={r_pres:.2f}) "
                f"vs Ausente (WR={wr_aus:.1f}%, R={r_aus:.2f}) — "
                f"{'Melhor' if diff > 0 else 'Pior'} em {abs(diff):.2f}R")

        # Chaos específico
        if 'RegimeChaos' in regime:
            chaos = regime['RegimeChaos'].get('Presente', {})
            if chaos.get('count', 0) > 0:
                lines.append(
                    f"[CRITICO] <b>CHAOS detectado em {chaos.get('count',0)} trades:</b> "
                    f"R={chaos.get('mean',0):.2f}, WR={chaos.get('win_rate',0):.1f}%. "
                    f"RECOMENDAÇÃO: Bloquear entradas quando RegimeChaos=1.")

        return "<br/>".join(lines) if lines else "Regime semântico sem padrões significativos."

    @staticmethod
    def news_interpretation(a):
        """Interpretação do impacto de notícias (v5.1)."""
        news = a.results.get('news', {})
        if not news:
            return "Dados de notícias indisponíveis."
        lines = []
        lines.append("<b>Impacto de Notícias Econômicas (v5.1):</b>")

        if 'NewsHighActive' in news:
            nh = news['NewsHighActive']
            presente = nh.get('Presente', {})
            ausente = nh.get('Ausente', {})
            if presente and ausente:
                diff = presente.get('mean', 0) - ausente.get('mean', 0)
                wr_diff = presente.get('win_rate', 0) - ausente.get('win_rate', 0)
                tag = '[CRITICO]' if diff < -0.2 else ('[ATENCAO]' if diff < 0 else '[OK]')
                lines.append(
                    f"{tag} <b>Notícias HIGH ativas:</b> Presente (n={presente.get('count',0)}, "
                    f"WR={presente.get('win_rate',0):.1f}%, R={presente.get('mean',0):.2f}) "
                    f"vs Ausente (WR={ausente.get('win_rate',0):.1f}%, R={ausente.get('mean',0):.2f}) — "
                    f"{'Piora' if diff < 0 else 'Melhora'} {abs(diff):.2f}R / {abs(wr_diff):.1f}pp WR")

        if 'NewsMediumActive' in news:
            nm = news['NewsMediumActive']
            presente = nm.get('Presente', {})
            ausente = nm.get('Ausente', {})
            if presente and ausente:
                diff = presente.get('mean', 0) - ausente.get('mean', 0)
                if abs(diff) > 0.1:
                    lines.append(
                        f"[ATENCAO] <b>Notícias MEDIUM ativas:</b> Impacto {diff:+.2f}R "
                        f"(Presente R={presente.get('mean',0):.2f} vs Ausente R={ausente.get('mean',0):.2f})")

        if 'NewsImpactScore' in news:
            ni = news['NewsImpactScore']
            presente = ni.get('Com_Impacto', {})
            ausente = ni.get('Sem_Impacto', {})
            if presente and ausente:
                diff = presente.get('mean', 0) - ausente.get('mean', 0)
                if abs(diff) > 0.15:
                    lines.append(
                        f"[ATENCAO] <b>NewsImpactScore >= 1:</b> {diff:+.2f}R "
                        f"(Com Impacto R={presente.get('mean',0):.2f} vs Sem R={ausente.get('mean',0):.2f})")

        # False Block Rate
        if 'false_block_rate' in news:
            fbr = news['false_block_rate']
            if fbr.get('false_blocks', 0) > 0:
                lines.append(
                    f"[ATENCAO] <b>False Block Rate:</b> {fbr.get('false_blocks',0)} de "
                    f"{fbr.get('total_news_blocked',0)} trades bloqueados por notícia HIGH "
                    f"seriam WINNERS (R médio={fbr.get('avg_r_if_taken',0):.2f}). "
                    f"Taxa de falso bloqueio: {fbr.get('false_block_pct',0):.1f}%")

        # NewsHigh x RegimeChaos
        if 'NewsHigh_x_RegimeChaos' in news:
            combo = news['NewsHigh_x_RegimeChaos']
            lines.append("<b>Interação Notícia HIGH × Regime CHAOS:</b>")
            for (nh, rc), vals in combo.items():
                tag = 'HIGH+CHAOS' if nh and rc else ('HIGH' if nh else ('CHAOS' if rc else 'NONE'))
                lines.append(
                    f"  {tag}: n={vals.get('count',0)}, R={vals.get('mean',0):.2f}, "
                    f"WR={vals.get('win_rate',0):.1f}%")

        return "<br/>".join(lines) if lines else "Sem impacto significativo de notícias detectado."

    @staticmethod
    def recommendations(a):
        """Gera recomendações baseadas na análise quantitativa."""
        recs = []
        b = a.results['basic']
        t = a.results['tail_risk']
        cat = a.results.get('catastrophe', {})
        boot = a.results['bootstrap']
        macro = a.results.get('macro', {})
        temp = a.results.get('temporal', {})
        ac = a.results.get('autocorr', {})

        wr = b['win_rate']
        avg_r = b['avg_r']
        sr = b.get('sharpe_annual', 0)
        sqn = b.get('sqn', 0)
        pf = b.get('profit_factor', 0)
        dd_pct = b.get('max_drawdown_pct', 0)

        # Recomendacoes baseadas em dados quantitativos
        if sr < 0.5:
            recs.append(("ALTA",
                f"Sharpe anualizado={sr:.2f} abaixo de 0.5. "
                f"Risco-retorno insuficiente. Considere reduzir exposicao ou "
                f"melhorar filtros de entrada."))
        elif sr < 1.0:
            recs.append(("MEDIA",
                f"Sharpe={sr:.2f} marginal. Buscar >1.0 para consistencia."))

        if sqn < 1.5:
            recs.append(("ALTA",
                f"SQN={sqn:.2f} baixo. Sistema precisa de mais edge ou "
                f"menos dispersao nos resultados."))

        if pf < 1.5:
            recs.append(("ALTA",
                f"Profit Factor={pf:.2f} baixo. Ganhos mal cobrem perdas."))

        if dd_pct < -20:
            recs.append(("ALTA",
                f"Drawdown maximo de {dd_pct:.1f}% e elevado. "
                f"Implementar stop-loss global."))

        if t['skewness'] < -0.5:
            recs.append(("ALTA",
                f"Assimetria (Skewness={t['skewness']:.2f}) negativa: "
                f"losses extremos puxam a media. Implementar stop-loss "
                f"dinamico para limitar perdas."))

        cr = b.get('capture_ratio', 1)
        if cr < 0.3:
            recs.append(("MEDIA",
                f"Capture Ratio={cr:.2f} baixo. Otimizar saida: trailing "
                f"stop ou saida parcial em multiplos de R."))

        if 'EntryHour' in temp:
            bad_hours = [int(k) for k, v in temp['EntryHour'].items()
                         if v.get('mean', 0) < -0.5 and v.get('count', 0) >= 2]
            if bad_hours:
                bad_detail = []
                for bh in bad_hours:
                    v = temp['EntryHour'].get(bh, {})
                    bad_detail.append(f"{bh}h (WR={v.get('win_rate', 0):.1f}%, R={v.get('mean', 0):.2f})")
                recs.append(("MEDIA",
                    f"Filtrar horarios: Bloquear entradas entre {bad_detail}."))

        if 'Session' in temp:
            sess = temp['Session']
            s_order = ['Asia', 'Londres', 'NY_AM', 'NY_PM', 'Off-Hours']
            valid_s = [s for s in s_order if s in sess]
            if valid_s:
                best_s = max(valid_s, key=lambda s: sess[s].get('mean', -999))
                worst_s = min(valid_s, key=lambda s: sess[s].get('mean', 999))
                if sess[worst_s].get('mean', 0) < 0 and sess[best_s].get('mean', 0) > 0:
                    recs.append(("MEDIA",
                        f"Sessoes: {best_s} (R={sess[best_s].get('mean',0):.2f}) "
                        f"vs {worst_s} (R={sess[worst_s].get('mean',0):.2f}). "
                        f"Focar na melhor sessao."))

        if 'vix' in macro:
            vix = macro['vix']
            if 'Panico' in vix and 'Calmo' in vix:
                diff = vix['Calmo'].get('mean', 0) - vix['Panico'].get('mean', 0)
                if diff > 0.3:
                    recs.append(("ALTA",
                        f"VIX: Diferenca de {diff:.2f}R entre regimes Calmo e Panico. "
                        f"Bloquear trades quando VIX_ZScore > 0.5."))

        bvw = cat.get('best_vs_worst', {})
        sig_bvw = {k: v for k, v in bvw.items()
                   if v.get('significant') and abs(v.get('cohens_d', 0)) > 0.5}
        if sig_bvw:
            recs.append(("ALTA",
                "Filtro anti-catastrofe: Implementar codigo MQL5 gerado "
                "neste relatorio (inclui arvore + VIX + horario + yield curve)."))

        if boot['mean_ci_low'] <= 0:
            recs.append(("MEDIA",
                "Amostra insuficiente: IC 95% do Avg R inclui zero. "
                f"IC=[{boot['mean_ci_low']:.3f}R, {boot['mean_ci_high']:.3f}R]. "
                "Colete mais trades para confirmar o edge."))

        if ac.get('lag1', 0) < -0.3 and ac.get('p_value', 1) < 0.1:
            recs.append(("BAIXA",
                f"Autocorrelacao lag-1={ac['lag1']:.2f} (p={ac['p_value']:.3f}): "
                f"efeito mean-reversion — apos perdas, probabilidade de win aumenta."))

        if not recs:
            recs.append(("BAIXA",
                "Estrategia aparentemente robusta. Monitore continuamente."))

        return recs


class ChartGenerator:
    """Gera todos os graficos do relatorio."""

    def __init__(self, analyzer):
        self.a = analyzer
        self.paths = {}

    def generate_all(self):
        self._r_distribution()
        self._equity_curve()
        self._underwater_chart()
        self._monthly_heatmap()
        self._macro_charts()
        self._catastrophe_comparison()
        self._tree_chart()
        self._ic_chart()
        self._temporal_charts()
        self._correlation_heatmap()
        self._bootstrap_chart()
        self._acf_chart()
        self._regime_chart()
        # NOVO v3.1
        self._regime_semantic_chart()
        self._news_chart()
        if SHAP_AVAILABLE and self.a.shap_values is not None:
            self._shap_chart()
        return self.paths

    def _save(self, name, fig):
        path = os.path.join(CHART_DIR, f"{name}.png")
        fig.savefig(path, dpi=180, bbox_inches='tight',
                    facecolor='white', edgecolor='none')
        plt.close(fig)
        self.paths[name] = path

    def _r_distribution(self):
        fig, axes = plt.subplots(2, 2, figsize=(12, 8))
        r = self.a.df['ResultR']
        wr = (self.a.y.mean() * 100) if hasattr(self.a, 'y') else 0

        # Main histogram
        axes[0, 0].hist(r, bins=max(12, self.a.n // 4),
                        color=C['silver'], edgecolor='white', alpha=0.85)
        axes[0, 0].axvline(r.mean(), color=C['gold'], linestyle='--', linewidth=2,
                           label=f'Media: {r.mean():.2f}R')
        axes[0, 0].axvline(0, color=C['red'], linestyle='-', linewidth=1, alpha=0.5)
        axes[0, 0].set_title(f'Distribuicao de R-Multiplos (n={self.a.n}, WR={wr:.1f}%)')
        axes[0, 0].set_xlabel('Resultado (R)')
        axes[0, 0].set_ylabel('Frequencia')
        axes[0, 0].legend(fontsize=8)

        # Zoom near zero for detail
        r_zoom = r[(r > -0.5) & (r < 2.0)]
        if len(r_zoom) > 2:
            axes[0, 1].hist(r_zoom, bins=max(8, len(r_zoom) // 4),
                            color=C['gold'], edgecolor='white', alpha=0.7)
            axes[0, 1].axvline(r.mean(), color=C['gold'], linestyle='--', linewidth=2)
            axes[0, 1].axvline(0, color=C['red'], linestyle='-', linewidth=1, alpha=0.5)
            axes[0, 1].set_title('Zoom: trades proximos de 0')
            axes[0, 1].set_xlabel('Resultado (R)')
            axes[0, 1].set_ylabel('Frequencia')

        if 'Direction' in self.a.df.columns:
            dirs = sorted(self.a.df['Direction'].unique())
            data_box = [self.a.df[self.a.df['Direction'] == d]['ResultR'].values
                        for d in dirs]
            bp = axes[1, 0].boxplot(data_box, tick_labels=dirs, patch_artist=True,
                                    medianprops=dict(color=C['gold'], linewidth=2))
            box_colors = [C['orange'], C['red'], C['silver'], C['orange']]
            for i, patch in enumerate(bp['boxes']):
                patch.set_facecolor(box_colors[i % len(box_colors)])
                patch.set_alpha(0.3)
            axes[1, 0].axhline(0, color=C['gray'], linestyle='--', alpha=0.5)
            axes[1, 0].set_title('R-Multiplos por Direcao')
            axes[1, 0].set_ylabel('Resultado (R)')

        # Percentile bar
        pcts = {5: r.quantile(0.05), 25: r.quantile(0.25),
                50: r.median(), 75: r.quantile(0.75), 95: r.quantile(0.95)}
        p_keys = list(pcts.keys())
        p_vals = list(pcts.values())
        p_colors = [C['red'] if v < 0 else C['green'] for v in p_vals]
        axes[1, 1].bar([str(k) for k in p_keys], p_vals, color=p_colors,
                       alpha=0.7, edgecolor='white')
        axes[1, 1].axhline(0, color=C['gray'], linestyle='--', alpha=0.5)
        axes[1, 1].set_title('Percentis')
        axes[1, 1].set_ylabel('R-Multiplo')
        for i, v in enumerate(p_vals):
            axes[1, 1].text(i, v + (0.02 if v >= 0 else -0.08),
                            f'{v:.2f}', ha='center', fontsize=9, fontweight='bold')

        plt.tight_layout()
        self._save('r_distribution', fig)

    def _equity_curve(self):
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8), sharex=True)
        pnl_indiv = self.a.df['NetProfit'].values
        pnl_cum = np.cumsum(pnl_indiv)

        # Individual trade PnL bars
        colors_indiv = [C['green'] if p >= 0 else C['red'] for p in pnl_indiv]
        ax1.bar(range(len(pnl_indiv)), pnl_indiv, color=colors_indiv,
                alpha=0.7, edgecolor='white', width=0.8)
        ax1.axhline(0, color=C['gray'], linestyle='--', alpha=0.5)
        ax1.set_title('PnL por Trade')
        ax1.set_ylabel('PnL ($)')

        # Cumulative equity
        ax2.fill_between(range(len(pnl_cum)), pnl_cum, 0, where=(pnl_cum >= 0),
                         color=C['green'], alpha=0.15, interpolate=True)
        ax2.fill_between(range(len(pnl_cum)), pnl_cum, 0, where=(pnl_cum < 0),
                         color=C['red'], alpha=0.15, interpolate=True)
        ax2.plot(pnl_cum, color=C['silver'], linewidth=1.8)
        ax2.axhline(0, color=C['gray'], linestyle='--', alpha=0.5)
        ax2.set_title('Curva de Equity Acumulada')
        ax2.set_xlabel('Trade #')
        ax2.set_ylabel('PnL Acumulado ($)')
        running_max = np.maximum.accumulate(pnl_cum)
        drawdown = pnl_cum - running_max
        if drawdown.min() < 0:
            worst_idx = np.argmin(drawdown)
            ax2.annotate(f'DD Max: ${drawdown.min():.2f}',
                         xy=(worst_idx, pnl_cum[worst_idx]),
                         xytext=(worst_idx + 2, pnl_cum[worst_idx] - abs(pnl_cum[worst_idx])*0.1),
                         arrowprops=dict(arrowstyle='->', color=C['red']),
                         fontsize=8, color=C['red'], fontweight='bold')
        plt.tight_layout()
        self._save('equity_curve', fig)

    def _underwater_chart(self):
        fig, ax = plt.subplots(figsize=(10, 3))
        pnl = self.a.df['NetProfit'].cumsum()
        running_max = pnl.cummax()
        dd = pnl - running_max
        ax.fill_between(range(len(dd)), dd, 0,
                        where=(dd < 0), color=C['red'], alpha=0.4)
        ax.plot(dd, color=C['red'], linewidth=1)
        ax.axhline(0, color=C['dark'], linewidth=0.5)
        ax.set_title('Drawdown (Underwater Chart)')
        ax.set_xlabel('Trade #')
        ax.set_ylabel('Drawdown ($)')
        worst_idx = dd.idxmin()
        ax.annotate(f'${dd.min():.2f}',
                    xy=(worst_idx, dd.iloc[worst_idx]),
                    xytext=(worst_idx + 2, dd.iloc[worst_idx] + 10),
                    arrowprops=dict(arrowstyle='->', color=C['orange']),
                    fontsize=8, color=C['orange'], fontweight='bold')
        plt.tight_layout()
        self._save('underwater_chart', fig)

    def _monthly_heatmap(self):
        if 'EntryTime' not in self.a.df.columns:
            return
        df = self.a.df.copy()
        df['year'] = df['EntryTime'].dt.year
        df['month'] = df['EntryTime'].dt.month
        monthly = df.groupby(['year', 'month'])['NetProfit'].sum().unstack()
        if monthly.empty:
            return
        fig, ax = plt.subplots(figsize=(10, 4))
        cmap = sns.diverging_palette(10, 130, s=80, l=55, as_cmap=True)
        sns.heatmap(monthly, cmap=cmap, center=0, annot=True, fmt='.0f',
                    linewidths=0.5, ax=ax, cbar_kws={'label': 'PnL ($)'},
                    annot_kws={'size': 8})
        ax.set_title('PnL Mensal ($)', fontsize=12, fontweight='bold')
        ax.set_ylabel('Ano')
        ax.set_xlabel('Mes')
        plt.tight_layout()
        self._save('monthly_heatmap', fig)

    def _macro_charts(self):
        macro = self.a.results.get('macro', {})
        if not macro:
            return
        # Filtra apenas VIX e DXY para os graficos simples
        simple_keys = ['vix', 'dxy']
        macro_simple = {k: macro[k] for k in simple_keys if k in macro}
        if macro_simple:
            n_plots = len(macro_simple)
            fig, axes = plt.subplots(1, n_plots, figsize=(5 * n_plots, 4))
            if n_plots == 1:
                axes = [axes]
            for idx, (key, data) in enumerate(macro_simple.items()):
                ax = axes[idx]
                labels = list(data.keys())
                means = [data[l]['mean'] for l in labels]
                counts = [data[l]['count'] for l in labels]
                wrs = [data[l]['win_rate'] for l in labels]
                x = np.arange(len(labels))
                bars = ax.bar(x, means,
                              color=[C['green'] if m > 0 else C['red'] for m in means],
                              alpha=0.7, edgecolor='white')
                ax.set_xticks(x)
                ax.set_xticklabels(labels, fontsize=9)
                ax.set_ylabel('Resultado Medio (R)')
                ax.set_title(f'Performance por Regime de {key.upper()}')
                ax.axhline(0, color=C['gray'], linestyle='--', alpha=0.5)
                for i, (bar, n, wr) in enumerate(zip(bars, counts, wrs)):
                    ax.text(bar.get_x() + bar.get_width() / 2,
                            bar.get_height() + 0.05,
                            f'n={n}\nWR={wr:.0f}%',
                            ha='center', va='bottom', fontsize=7, color=C['dark'])
            plt.tight_layout()
            self._save('macro_charts', fig)

        # Heatmap dos indicadores macro expandidos
        merged = self.a.results.get('macro_merged', None)
        if merged is not None:
            macro_heat_cols = ['yield_curve', 'fed_funds', 'hy_spread',
                               'reverse_repo', 'cpi', 'core_pce',
                               'global_risk_score', 'vix', 'usd_index']
            macro_heat_cols = [c for c in macro_heat_cols if c in merged.columns]
            if len(macro_heat_cols) >= 3:
                regimes = {}
                for col in macro_heat_cols:
                    med = merged[col].median()
                    merged[f'{col}_bin'] = (merged[col] > med).astype(int)
                    grp = merged.groupby(f'{col}_bin')['ResultR'].mean()
                    regimes[col] = {
                        'Baixo': grp.get(0, 0),
                        'Alto': grp.get(1, 0),
                    }
                hm_data = []
                labels_hm = []
                for col, vals in regimes.items():
                    hm_data.append([vals['Baixo'], vals['Alto']])
                    labels_hm.append(col)
                hm_arr = np.array(hm_data)
                fig, ax = plt.subplots(figsize=(8, max(4, len(labels_hm) * 0.4)))
                cmap = sns.diverging_palette(10, 130, s=80, l=55, as_cmap=True)
                sns.heatmap(hm_arr, cmap=cmap, center=0, annot=True, fmt='.3f',
                            linewidths=0.5, ax=ax,
                            xticklabels=['Abaixo Mediana', 'Acima Mediana'],
                            yticklabels=labels_hm,
                            cbar_kws={'label': 'Avg R'})
                ax.set_title('Performance por Regime Macro (Mediana)',
                             fontsize=12, fontweight='bold')
                plt.tight_layout()
                self._save('macro_heatmap', fig)

    def _catastrophe_comparison(self):
        cat = self.a.results.get('catastrophe', {})
        num = cat.get('numeric', {})
        if not num:
            return
        sorted_vars = sorted(num.items(), key=lambda x: abs(x[1]['delta']),
                             reverse=True)[:10]
        feats = [s[0] for s in sorted_vars]
        deltas = [s[1]['delta'] for s in sorted_vars]
        p_vals = [s[1]['p_value'] for s in sorted_vars]

        fig, ax = plt.subplots(figsize=(10, 5))
        colors_bar = [C['red'] if d < 0 else C['green'] for d in deltas]
        bars = ax.barh(range(len(feats)), deltas, color=colors_bar,
                       alpha=0.8, edgecolor='white')
        ax.set_yticks(range(len(feats)))
        ax.set_yticklabels(feats, fontsize=9)
        ax.set_xlabel('Delta (Restante 90% - Piores 10%)')
        ax.set_title('Diferenca de Features: Piores 10% vs Restante')
        ax.axvline(0, color=C['dark'], linewidth=0.8)
        ax.invert_yaxis()
        for i, (bar, p) in enumerate(zip(bars, p_vals)):
            sig = ('***' if p < 0.01 else ('**' if p < 0.05 else (
                '*' if p < 0.10 else '')))
            if sig:
                x_pos = bar.get_width() + (0.05 if bar.get_width() >= 0 else -0.05)
                ha = 'left' if bar.get_width() >= 0 else 'right'
                ax.text(x_pos, i, sig, va='center', ha=ha, fontsize=9,
                        color=C['red'], fontweight='bold')
        ax.text(0.98, 0.02,
                '*** p<0.01  ** p<0.05  * p<0.10\n(Mann-Whitney U test)',
                transform=ax.transAxes, fontsize=7, va='bottom', ha='right',
                color=C['gray'], style='italic')
        plt.tight_layout()
        self._save('catastrophe_comparison', fig)

    def _tree_chart(self):
        from sklearn.tree import plot_tree
        fig, ax = plt.subplots(figsize=(16, 8))
        plot_tree(self.a.tree_catastrophe,
                  feature_names=list(self.a.X.columns),
                  class_names=['Normal', 'DESASTRE'],
                  filled=True, rounded=True, fontsize=8,
                  impurity=False, ax=ax)
        ax.set_title('Arvore de Decisao: Filtro Anti-Catastrofe (10% Piores)',
                     fontsize=12, fontweight='bold', pad=15)
        plt.tight_layout()
        self._save('tree_catastrophe', fig)

    def _ic_chart(self):
        ics = self.a.results.get('ic', [])
        if not ics:
            return
        top = ics[:15]
        feats = [i[0].replace('_', ' ') for i in top]
        ic_vals = [i[1]['ic'] for i in top]
        p_vals = [i[1]['p_value'] for i in top]

        fig, ax = plt.subplots(figsize=(10, 5))
        colors_bar = [C['green'] if v > 0 else C['red'] for v in ic_vals]
        ax.barh(range(len(feats)), ic_vals, color=colors_bar,
                alpha=0.8, edgecolor='white')
        ax.set_yticks(range(len(feats)))
        ax.set_yticklabels(feats, fontsize=9)
        ax.set_xlabel('Information Coefficient (Spearman rho)')
        ax.set_title('Top 15 Features: Correlacao de Rank com Resultado R')
        ax.axvline(0, color=C['dark'], linewidth=0.8)
        ax.invert_yaxis()
        for i, (ic, p) in enumerate(zip(ic_vals, p_vals)):
            sig = ('***' if p < 0.01 else ('**' if p < 0.05 else (
                '*' if p < 0.10 else '')))
            if sig:
                ax.text(ic + (0.01 if ic >= 0 else -0.01), i, sig,
                        va='center', ha='left' if ic >= 0 else 'right',
                        fontsize=8, color=C['red'], fontweight='bold')
        plt.tight_layout()
        self._save('ic_chart', fig)

    def _temporal_charts(self):
        temp = self.a.results.get('temporal', {})
        if not temp:
            return
        fig, axes = plt.subplots(2, 2, figsize=(16, 10))

        if 'EntryHour' in temp:
            hours = temp['EntryHour']
            h = sorted(hours.keys())
            means_h = [hours[k]['mean'] for k in h]
            colors_h = [C['green'] if m > 0 else C['red'] for m in means_h]
            axes[0, 0].bar([int(x) for x in h], means_h, color=colors_h,
                           alpha=0.7, edgecolor='white')
            axes[0, 0].axhline(0, color=C['gray'], linestyle='--', alpha=0.5)
            axes[0, 0].set_xlabel('Hora')
            axes[0, 0].set_ylabel('Resultado Medio (R)')
            axes[0, 0].set_title('Por Hora de Entrada')
            axes[0, 0].set_xticks([int(x) for x in h])
            axes[0, 0].set_xticklabels([f"{int(x)}h" for x in h], rotation=45)

        if 'DayOfWeek' in temp:
            day_names = {0: 'Dom', 1: 'Seg', 2: 'Ter', 3: 'Qua', 4: 'Qui', 5: 'Sex', 6: 'Sab'}
            dow = temp['DayOfWeek']
            all_days = sorted(dow.keys())
            means_d = [dow[k]['mean'] for k in all_days]
            labels = [day_names.get(int(k), str(k)) for k in all_days]
            colors_d = [C['green'] if m > 0 else C['red'] for m in means_d]
            axes[0, 1].bar(labels, means_d, color=colors_d,
                           alpha=0.7, edgecolor='white')
            axes[0, 1].axhline(0, color=C['gray'], linestyle='--', alpha=0.5)
            axes[0, 1].set_ylabel('Resultado Medio (R)')
            axes[0, 1].set_title('Por Dia da Semana')
            axes[0, 1].tick_params(axis='x', rotation=15)

        if 'Session' in temp:
            sess = temp['Session']
            s_order = ['Asia_Pacific', 'Asia_Japan_SEA', 'Europe_London',
                       'Europe_Main', 'NY_Pre', 'NY_Main', 'NY_PM', 'Off_Hours']
            s = [x for x in s_order if x in sess]
            means_s = [sess[k]['mean'] for k in s]
            colors_s = [C['green'] if m > 0 else C['red'] for m in means_s]
            axes[1, 0].bar(s, means_s, color=colors_s,
                           alpha=0.7, edgecolor='white')
            axes[1, 0].axhline(0, color=C['gray'], linestyle='--', alpha=0.5)
            axes[1, 0].set_ylabel('Resultado Medio (R)')
            axes[1, 0].set_title('Por Sessao (8 grupos)')
            axes[1, 0].tick_params(axis='x', rotation=30)
            for i, label in enumerate(axes[1, 0].get_xticklabels()):
                if sess[s[i]]['count'] < 3:
                    label.set_color('orange')
                    label.set_fontweight('bold')

        if 'Session14' in temp:
            sess14 = temp['Session14']
            s14_order = ['Australia_NZ', 'Asia_1_Tokyo', 'Asia_2_China_HK',
                         'Asia_3_SE_India', 'Europe_Open', 'Europe_Main',
                         'NY_Pre_Brazil', 'NY_Open', 'NY_Main', 'NY_Post',
                         'Off_Hours']
            s14 = [x for x in s14_order if x in sess14]
            means_s14 = [sess14[k]['mean'] for k in s14]
            colors_s14 = [C['green'] if m > 0 else C['red'] for m in means_s14]
            bars = axes[1, 1].bar(s14, means_s14, color=colors_s14,
                                  alpha=0.7, edgecolor='white')
            axes[1, 1].axhline(0, color=C['gray'], linestyle='--', alpha=0.5)
            axes[1, 1].set_ylabel('Resultado Medio (R)')
            axes[1, 1].set_title('Por Sessao (14 grupos)')
            axes[1, 1].tick_params(axis='x', rotation=45)
            for i, label in enumerate(axes[1, 1].get_xticklabels()):
                if sess14[s14[i]]['count'] < 3:
                    label.set_color('orange')
                    label.set_fontweight('bold')
            # Annotate count
            for i, (bar, k) in enumerate(zip(bars, s14)):
                axes[1, 1].text(bar.get_x() + bar.get_width()/2, bar.get_height(),
                                f'n={int(sess14[k]["count"])}',
                                ha='center', va='bottom' if bar.get_height() >= 0 else 'top',
                                fontsize=7, fontweight='bold')

        plt.tight_layout()
        self._save('temporal_charts', fig)

    def _correlation_heatmap(self):
        target_cols = ['ResultR', 'MFE_R', 'MAE_R', 'CaptureRatio',
                       'InitialRisk', 'ATR', 'VolatilityZScore',
                       'VIX_ZScore', 'DXY_ZScore', 'Hurst', 'Strength',
                       'RiskScore', 'RelativeVolume', 'DistanceVWAP_ATR',
                       'SpreadAtExit']
        target_cols = [c for c in target_cols
                       if c in self.a.X.columns or c in self.a.df.columns]
        plot_df = self.a.df[target_cols].copy()
        corr = plot_df.corr()

        fig, ax = plt.subplots(figsize=(12, 10))
        mask = np.triu(np.ones_like(corr, dtype=bool), k=1)
        cmap = sns.diverging_palette(30, 220, s=85, l=55, as_cmap=True)
        sns.heatmap(corr, mask=mask, cmap=cmap, center=0, annot=True,
                    fmt='.2f', square=True, linewidths=0.5, ax=ax,
                    annot_kws={'size': 7}, cbar_kws={'shrink': 0.8})
        ax.set_title('Matriz de Correlacao: Features vs Resultados',
                     fontsize=12, fontweight='bold')
        plt.tight_layout()
        self._save('correlation_heatmap', fig)

    def _bootstrap_chart(self):
        boot = self.a.results.get('bootstrap', {})
        if 'boot_means' not in boot:
            return
        fig, axes = plt.subplots(1, 2, figsize=(10, 4))

        axes[0].hist(boot['boot_means'], bins=50, color=C['silver'],
                     alpha=0.7, edgecolor='white')
        avg_r = self.a.results['basic']['avg_r']
        axes[0].axvline(avg_r, color=C['gold'], linewidth=2,
                        label=f'Observado: {avg_r:.2f}R')
        axes[0].axvline(boot['mean_ci_low'], color=C['red'],
                        linestyle='--', linewidth=1,
                        label=f'IC 95% inf: {boot["mean_ci_low"]:.2f}R')
        axes[0].axvline(boot['mean_ci_high'], color=C['red'],
                        linestyle='--', linewidth=1,
                        label=f'IC 95% sup: {boot["mean_ci_high"]:.2f}R')
        axes[0].axvline(0, color=C['dark'], linewidth=0.8, alpha=0.5)
        axes[0].set_title('Bootstrap: Resultado Medio (R)')
        axes[0].set_xlabel('Resultado Medio (R)')
        axes[0].set_ylabel('Frequencia')
        axes[0].legend(fontsize=7)

        b = self.a.results['basic']
        t = self.a.results['tail_risk']
        metrics = ['Win Rate\n(%)', 'Avg R', 'Skewness', 'Kurtosis', 'CVaR 5%\n(R)']
        values = [b['win_rate'], b['avg_r'], t['skewness'],
                  t['kurtosis'], t['cvar_5']]
        colors_bar = [C['green'] if v > 0 else C['red']
                      for v in [b['win_rate'] - 50, b['avg_r'], 0, 0, t['cvar_5']]]
        axes[1].bar(metrics, values, color=colors_bar, alpha=0.7, edgecolor='white')
        axes[1].axhline(0, color=C['dark'], linewidth=0.8)
        axes[1].set_title('Metricas-Chave')
        for i, v in enumerate(values):
            axes[1].text(i, v + (0.05 if v >= 0 else -0.15), f'{v:.2f}',
                         ha='center', va='bottom' if v >= 0 else 'top',
                         fontsize=8, fontweight='bold')
        plt.tight_layout()
        self._save('bootstrap_metrics', fig)

    def _acf_chart(self):
        fig, ax = plt.subplots(figsize=(10, 3))
        r = self.a.df['ResultR'].values
        lags = min(20, len(r) // 4)
        if lags < 2:
            ax.text(0.5, 0.5, 'Amostra insuficiente para ACF',
                    ha='center', va='center', transform=ax.transAxes)
            plt.tight_layout()
            self._save('acf_chart', fig)
            return

        acf_vals = []
        for lag in range(lags + 1):
            if lag == 0:
                acf_vals.append(1.0)
            else:
                acf_vals.append(np.corrcoef(r[:-lag], r[lag:])[0, 1])

        ax.bar(range(len(acf_vals)), acf_vals, width=0.3,
               color=C['silver'], alpha=0.7)
        ci = 1.96 / np.sqrt(len(r))
        ax.axhline(ci, color=C['red'], linestyle='--', alpha=0.5, linewidth=0.8)
        ax.axhline(-ci, color=C['red'], linestyle='--', alpha=0.5, linewidth=0.8)
        ax.axhline(0, color=C['dark'], linewidth=0.5)
        ax.set_xlabel('Lag')
        ax.set_ylabel('Autocorrelacao')
        ax.set_title('ACF dos R-Multiplos')
        plt.tight_layout()
        self._save('acf_chart', fig)

    def _shap_chart(self):
        if self.a.shap_values is None:
            return
        fig, ax = plt.subplots(figsize=(10, 6))
        try:
            shap.summary_plot(self.a.shap_values, self.a.X, plot_type="bar",
                              max_display=12, show=False, ax=ax)
            ax.set_title('SHAP: Impacto das Features no Resultado R',
                         fontsize=12, fontweight='bold')
        except Exception:
            ax.text(0.5, 0.5, 'SHAP nao disponivel',
                    ha='center', va='center', transform=ax.transAxes)
        plt.tight_layout()
        self._save('shap_chart', fig)

    def _regime_chart(self):
        plot_data = getattr(self.a, 'regime_plot_data', None)
        regime = self.a.results.get('regime', {})
        if plot_data is None or not regime:
            return
        fig, axes = plt.subplots(1, 2, figsize=(14, 5))

        # PCA scatter
        X_pca = plot_data['X_pca']
        labels = plot_data['labels']
        centroids_pca = plot_data['centroids_pca']
        desc_labels = plot_data['desc_labels']
        n_clusters = plot_data['n_clusters']
        var_exp = plot_data['var_explained']

        colors_regime = ['#2E86AB', '#A23B72', '#F18F01']
        for lbl in range(n_clusters):
            mask_l = labels == lbl
            lbl_name = desc_labels.get(lbl, f'Cluster {lbl}')
            perf = regime.get(lbl_name, {})
            n_count = perf.get('n', 0)
            wr_val = perf.get('win_rate', 0)
            r_val = perf.get('avg_r', 0)
            label_str = f'{lbl_name} (n={n_count}, WR={wr_val:.0f}%, R={r_val:.2f})'
            axes[0].scatter(X_pca[mask_l, 0], X_pca[mask_l, 1],
                            c=colors_regime[lbl % len(colors_regime)],
                            label=label_str, alpha=0.6, edgecolors='white',
                            s=80)
            axes[0].scatter(centroids_pca[lbl, 0], centroids_pca[lbl, 1],
                            c=colors_regime[lbl % len(colors_regime)],
                            marker='X', s=200, edgecolors='black', linewidths=2,
                            zorder=5)

        axes[0].set_xlabel(f'PC1 ({var_exp[0]*100:.1f}%)')
        axes[0].set_ylabel(f'PC2 ({var_exp[1]*100:.1f}%)')
        axes[0].set_title('Regimes de Mercado (K-Means + PCA)')
        axes[0].legend(fontsize=7, loc='best')
        axes[0].axhline(0, color='gray', linestyle='--', alpha=0.3)
        axes[0].axvline(0, color='gray', linestyle='--', alpha=0.3)

        # Perf bar chart
        labels_sorted = sorted(regime.keys(), key=lambda k: regime[k].get('avg_r', 0), reverse=True)
        r_vals = [regime[k].get('avg_r', 0) for k in labels_sorted]
        n_vals = [regime[k].get('n', 0) for k in labels_sorted]
        bar_colors = [C['green'] if v >= 0 else C['red'] for v in r_vals]
        bars = axes[1].barh(labels_sorted, r_vals, color=bar_colors, alpha=0.7, edgecolor='white')
        axes[1].axvline(0, color=C['dark'], linewidth=1)
        for i, (bar, n) in enumerate(zip(bars, n_vals)):
            rv = r_vals[i]
            axes[1].text(rv + (0.02 if rv >= 0 else -0.15), bar.get_y() + bar.get_height()/2,
                         f'{rv:.2f}R (n={n})', va='center', fontsize=8)
        axes[1].set_xlabel('Resultado Medio (R)')
        axes[1].set_title('Performance por Regime')

        plt.tight_layout()
        self._save('regime_chart', fig)

    def _regime_semantic_chart(self):
        """Grafico de performance por regime semantico (v5.1)."""
        regime_sem = self.a.results.get('regime_semantic')
        if not regime_sem:
            return

        regime_cols = [
            'RegimeTrendStrongBull', 'RegimeTrendStrongBear',
            'RegimeTrendWeakBull', 'RegimeTrendWeakBear',
            'RegimeRangeTight', 'RegimeRangeVolatile',
            'RegimeChaos', 'RegimeReversalImminent', 'RegimeBreakoutForming'
        ]
        regime_cols = [c for c in regime_cols if c in regime_sem]

        fig, axes = plt.subplots(3, 3, figsize=(18, 14))
        axes = axes.flatten()

        for idx, col in enumerate(regime_cols):
            if idx >= 9:
                break
            ax = axes[idx]
            data = regime_sem.get(col, {})
            presente = data.get('Presente', {})
            ausente = data.get('Ausente', {})

            if not presente or not ausente:
                ax.text(0.5, 0.5, 'Dados insuficientes', ha='center', va='center', transform=ax.transAxes)
                ax.set_title(col.replace('Regime', ''))
                continue

            cats = ['Presente', 'Ausente']
            r_vals = [presente.get('mean', 0), ausente.get('mean', 0)]
            wr_vals = [presente.get('win_rate', 0), ausente.get('win_rate', 0)]
            n_vals = [presente.get('count', 0), ausente.get('count', 0)]

            x = np.arange(len(cats))
            width = 0.35

            bars1 = ax.bar(x - width/2, r_vals, width, label='Avg R', color=[C['green'] if v >= 0 else C['red'] for v in r_vals], alpha=0.7, edgecolor='white')
            ax2 = ax.twinx()
            bars2 = ax2.bar(x + width/2, wr_vals, width, label='Win Rate %', color=C['gold'], alpha=0.7, edgecolor='white')

            ax.set_ylabel('Avg R', color=C['dark'])
            ax2.set_ylabel('Win Rate %', color=C['gold'])
            ax.set_title(col.replace('Regime', ''), fontsize=10, fontweight='bold')
            ax.set_xticks(x)
            ax.set_xticklabels(cats, fontsize=8)
            ax.axhline(0, color=C['gray'], linestyle='--', alpha=0.5)
            ax.legend(loc='upper left', fontsize=6)
            ax2.legend(loc='upper right', fontsize=6)

            for bar, val in zip(bars1, r_vals):
                ax.text(bar.get_x() + bar.get_width()/2, val + (0.02 if val >= 0 else -0.08),
                        f'{val:.2f}', ha='center', va='bottom' if val >= 0 else 'top', fontsize=7, fontweight='bold')
            for bar, val in zip(bars2, wr_vals):
                ax2.text(bar.get_x() + bar.get_width()/2, val + 1,
                        f'{val:.0f}%', ha='center', va='bottom', fontsize=7, color=C['gold'], fontweight='bold')

        for idx in range(len(regime_cols), 9):
            axes[idx].set_visible(False)

        plt.suptitle('Performance por Regime Semantico (v5.1): Presente vs Ausente', fontsize=14, fontweight='bold', y=0.98)
        plt.tight_layout(rect=[0, 0, 1, 0.96])
        self._save('regime_semantic_chart', fig)

    def _news_chart(self):
        """Grafico de impacto de noticias (v5.1)."""
        news = self.a.results.get('news')
        if not news:
            return

        fig, axes = plt.subplots(2, 2, figsize=(14, 10))
        axes = axes.flatten()

        # 1. NewsHighActive
        ax = axes[0]
        if 'NewsHighActive' in self.a.results.get('news', {}):
            data = self.a.results['news']['NewsHighActive']
            presente = data.get('Presente', {})
            ausente = data.get('Ausente', {})
            if presente and ausente:
                cats = ['Presente', 'Ausente']
                r_vals = [presente.get('mean', 0), ausente.get('mean', 0)]
                wr_vals = [presente.get('win_rate', 0), ausente.get('win_rate', 0)]
                n_vals = [presente.get('count', 0), ausente.get('count', 0)]

                x = np.arange(2)
                width = 0.35
                bars1 = ax.bar(x - 0.175, [presente.get('mean', 0), ausente.get('mean', 0)], width, label='Avg R', color=[C['green'] if v >= 0 else C['red'] for v in [presente.get('mean', 0), ausente.get('mean', 0)]], alpha=0.7, edgecolor='white')
                ax2 = ax.twinx()
                bars2 = ax2.bar(x + 0.175, [presente.get('win_rate', 0), ausente.get('win_rate', 0)], width, label='Win Rate %', color=C['gold'], alpha=0.7, edgecolor='white')
                ax.set_ylabel('Avg R')
                ax2.set_ylabel('Win Rate %')
                ax.set_title('News HIGH Active: Presente vs Ausente', fontweight='bold')
                ax.set_xticks([0, 1])
                ax.set_xticklabels(['Presente', 'Ausente'])
                ax.axhline(0, color='gray', linestyle='--', alpha=0.5)
                for bar, val in zip([bars1[0], bars1[1]], [presente.get('mean', 0), ausente.get('mean', 0)]):
                    ax.text(bar.get_x() + bar.get_width()/2, val + (0.02 if val >= 0 else -0.08), f'{val:.2f}R', ha='center', va='bottom' if val >= 0 else 'top', fontsize=8, fontweight='bold')
                for bar, val in zip(bars2, [presente.get('win_rate', 0), ausente.get('win_rate', 0)]):
                    ax2.text(bar.get_x() + bar.get_width()/2, val + 1, f'{val:.0f}%', ha='center', va='bottom', fontsize=8, color=C['gold'], fontweight='bold')
                ax.legend(loc='upper left', fontsize=7)
                ax2.legend(loc='upper right', fontsize=7)

        # 2. NewsMediumActive
        ax = axes[1]
        if 'NewsMediumActive' in self.a.results.get('news', {}):
            data = self.a.results['news']['NewsMediumActive']
            presente = data.get('Presente', {})
            ausente = data.get('Ausente', {})
            if presente and ausente:
                cats = ['Presente', 'Ausente']
                r_vals = [presente.get('mean', 0), ausente.get('mean', 0)]
                wr_vals = [presente.get('win_rate', 0), ausente.get('win_rate', 0)]

                x = np.arange(2)
                width = 0.35
                bars1 = ax.bar(x - 0.175, r_vals, width, color=[C['green'] if v >= 0 else C['red'] for v in r_vals], alpha=0.7, edgecolor='white', label='Avg R')
                ax2 = ax.twinx()
                bars2 = ax2.bar(x + 0.175, wr_vals, width, label='Win Rate %', color=C['gold'], alpha=0.7, edgecolor='white')
                ax.set_ylabel('Avg R')
                ax2.set_ylabel('Win Rate %')
                ax.set_title('News MEDIUM Active', fontweight='bold')
                ax.set_xticks([0, 1])
                ax.set_xticklabels(['Presente', 'Ausente'])
                ax.axhline(0, color='gray', linestyle='--', alpha=0.5)
                for bar, val in zip(bars1, r_vals):
                    ax.text(bar.get_x() + bar.get_width()/2, val + (0.02 if val >= 0 else -0.08), f'{val:.2f}R', ha='center', va='bottom' if val >= 0 else 'top', fontsize=8, fontweight='bold')
                for bar, val in zip(bars2, wr_vals):
                    ax2.text(bar.get_x() + bar.get_width()/2, val + 1, f'{val:.0f}%', ha='center', va='bottom', fontsize=8, color=C['gold'], fontweight='bold')
                ax.legend(loc='upper left', fontsize=7)
                ax2.legend(loc='upper right', fontsize=7)

        # 3. False Block Rate
        ax = axes[2]
        if 'false_block_rate' in self.a.results.get('news', {}):
            fbr = self.a.results['news']['false_block_rate']
            if fbr.get('false_blocks', 0) > 0:
                cats = ['False Blocks', 'True Blocks']
                vals = [fbr.get('false_blocks', 0), fbr.get('total_news_blocked', 0) - fbr.get('false_blocks', 0)]
                colors = [C['red'], C['green']]
                bars = ax.bar(cats, vals, color=colors, alpha=0.7, edgecolor='white')
                ax.set_title(f'False Block Rate: {fbr.get("false_block_pct", 0):.1f}%', fontweight='bold')
                ax.set_ylabel('Numero de Trades')
                for bar, val in zip(bars, vals):
                    ax.text(bar.get_x() + bar.get_width()/2, val + 0.5, str(val), ha='center', va='bottom', fontsize=10, fontweight='bold')
                ax.text(0.5, max(vals) * 0.8, f'False Block Rate: {fbr.get("false_block_pct", 0):.1f}%\nAvg R if taken: {fbr.get("avg_r_if_taken", 0):.2f}R',
                        ha='center', va='center', fontsize=10, fontweight='bold',
                        bbox=dict(boxstyle='round', facecolor='wheat', alpha=0.5))

        # 4. NewsHigh x RegimeChaos
        ax = axes[3]
        if 'NewsHigh_x_RegimeChaos' in self.a.results.get('news', {}):
            combo = self.a.results['news']['NewsHigh_x_RegimeChaos']
            cats = []
            r_vals = []
            for (nh, rc), vals in combo.items():
                label = f'NH={"Y" if nh else "N"}\nRC={"Y" if rc else "N"}'
                cats.append(label)
                r_vals.append(vals.get('mean', 0))

            bars = ax.bar(cats, r_vals, color=[C['green'] if v >= 0 else C['red'] for v in r_vals], alpha=0.7, edgecolor='white')
            ax.set_title('News HIGH x Regime CHAOS', fontweight='bold')
            ax.set_ylabel('Avg R')
            ax.axhline(0, color='gray', linestyle='--', alpha=0.5)
            for bar, val in zip(bars, r_vals):
                ax.text(bar.get_x() + bar.get_width()/2, val + (0.02 if val >= 0 else -0.08), f'{val:.2f}R', ha='center', va='bottom' if val >= 0 else 'top', fontsize=8, fontweight='bold')

        plt.suptitle('Analise de Impacto de Noticias Economicas (v5.1)', fontsize=14, fontweight='bold')
        plt.tight_layout()
        self._save('news_chart', fig)


def load_mql5_report(file_path=None):
    """Extrai metricas chave do relatorio HTML do Strategy Tester MQL5."""
    if file_path is None:
        data_dir = r'C:\ALXQuant\data'
        candidates = [f for f in os.listdir(data_dir) if f.endswith('.html') and 'Report' in f]
        if candidates:
            file_path = os.path.join(data_dir, sorted(candidates, reverse=True)[0])
        else:
            logger.warning(f"MQL5 Report nao encontrado em {data_dir}")
            return None
    if not os.path.exists(file_path):
        logger.warning(f"MQL5 Report nao encontrado: {file_path}")
        return None
    try:
        with open(file_path, 'r', encoding='utf-8-sig', errors='replace') as f:
            html = f.read()
        import re
        metrics = {}

        # Usa busca por fragmentos unicos (evita chars especiais problematicos)
        def extract_between(pattern_before, key, offset=0):
            idx = html.find(pattern_before)
            if idx < 0: return
            chunk = html[idx + len(pattern_before):idx + len(pattern_before) + 100]
            m = re.search(r'<b>([^<]+)</b>', chunk)
            if m: metrics[key] = m.group(1).strip()

        extract_between('ndice de Sharpe:', 'sharpe')
        extract_between('Fator de Recupera', 'recovery')
        extract_between('Retorno Esperado (Payoff):', 'payoff')
        extract_between('Z-Pontua', 'zscore')
        extract_between('GHPR:', 'ghpr')
        extract_between('Resultado OnTester:', 'ontester')
        extract_between('(Lucros,MAE):', 'corr_mae')
        extract_between('Correla', 'lr_corr')

        # Maximo ganhos/perdas consecutivos (chars especiais podem estar corrompidos)
        m = re.search(r'ximo ganhos consecutivos[^<]*</td>[^<]*<td[^>]*><b>(\d+)', html)
        if m: metrics['max_consec_win'] = m.group(1)
        m = re.search(r'ximo perdas consecutivas[^<]*</td>[^<]*<td[^>]*><b>(\d+)', html)
        if m: metrics['max_consec_loss'] = m.group(1)

        logger.info(f"MQL5 Report carregado: {len(metrics)} metricas extraidas ({', '.join(metrics.keys())})")
        return metrics
    except Exception as e:
        logger.warning(f"Erro ao ler MQL5 Report HTML: {e}")
        return None


def tree_to_mql5(tree, feature_names):
    """Converte arvore em funcao MQL5 compilavel com parametros."""
    tree_ = tree.tree_

    used_features = set()
    for node in range(tree_.node_count):
        if tree_.feature[node] != -2:
            used_features.add(feature_names[tree_.feature[node]])
    used_features = sorted(used_features)

    lines = []
    lines.append("// ====================================================")
    lines.append("// FILTRO ANTI-CATASTROFE - ALXQuant AI Engine v3.0")
    lines.append(f"// Gerado em: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("// Baseado nos 10% piores trades do backtest")
    lines.append("// ====================================================")
    lines.append("")
    lines.append("// ---- REGRA 1: Arvore de Decisao (catastrofe) ----")

    params = ", ".join([f"double {f}" for f in used_features])
    lines.append(f"bool IsTreeRisk({params})")
    lines.append("{")

    def recurse(node, depth):
        indent = "   " * (depth + 1)
        if tree_.feature[node] == -2:
            vals = tree_.value[node][0]
            is_high_risk = len(vals) > 1 and vals[1] > vals[0]
            if is_high_risk:
                lines.append(f"{indent}return true;  // BLOQUEADO")
            else:
                lines.append(f"{indent}// Trade seguro neste ramo")
            return
        name = feature_names[tree_.feature[node]]
        thresh = tree_.threshold[node]
        lines.append(f"{indent}if({name} <= {thresh:.10f})")
        lines.append(f"{indent}{{")
        recurse(tree_.children_left[node], depth + 1)
        lines.append(f"{indent}}}")
        lines.append(f"{indent}else")
        lines.append(f"{indent}{{")
        recurse(tree_.children_right[node], depth + 1)
        lines.append(f"{indent}}}")

    recurse(0, 0)
    lines.append("   return false;  // Passou no filtro")
    lines.append("}")
    lines.append("")
    lines.append("// ---- REGRA 2: Filtro VIX (panico) ----")
    lines.append("bool IsVIXPAnic()")
    lines.append("   {")
    lines.append("   double vix = GetVIX(); // funcao externa que retorna VIX atual")
    lines.append("   if(vix > 25) return true;  // VIX > 25 = panico")
    lines.append("   return false;")
    lines.append("   }")
    lines.append("")
    lines.append("// ---- REGRA 3: Filtro por Horario (NY) ----")
    lines.append("bool IsBadHour()")
    lines.append("   {")
    lines.append("   MqlDateTime dt;")
    lines.append("   TimeCurrent(dt);")
    lines.append("   int hourNY = dt.hour;  // UTC-4")
    lines.append("   if(hourNY >= 16 || hourNY < 2) return true;  // Fora do horario ideal")
    lines.append("   return false;")
    lines.append("   }")
    lines.append("")
    lines.append("// ---- REGRA 4: Filtro Sexta-feira ----")
    lines.append("bool IsFriday()")
    lines.append("   {")
    lines.append("   MqlDateTime dt;")
    lines.append("   TimeCurrent(dt);")
    lines.append("   if(dt.day_of_week == 5) return true;  // Sexta-feira")
    lines.append("   return false;")
    lines.append("   }")
    lines.append("")
    lines.append("// ---- REGRA 5: Filtro Yield Curve Invertida ----")
    lines.append("bool IsYieldCurveInverted()")
    lines.append("   {")
    lines.append("   double y2y = GetYield2Y();  // funcao externa")
    lines.append("   double y10y = GetYield10Y();")
    lines.append("   if(y10y < y2y) return true;  // Curva invertida = recessao")
    lines.append("   return false;")
    lines.append("   }")
    lines.append("")
    lines.append("// ---- FILTRO PRINCIPAL (camadas) ----")
    lines.append("bool IsTradeBlocked()")
    lines.append("   {")
    lines.append("   if(IsTreeRisk(" + ", ".join(used_features) + ")) return true;")
    lines.append("   if(IsVIXPAnic()) return true;")
    lines.append("   if(IsBadHour()) return true;")
    lines.append("   if(IsFriday()) { Print(\"Sexta-feira: reduzir lote\"); return false; }")
    lines.append("   if(IsYieldCurveInverted()) return true;")
    lines.append("   return false;")
    lines.append("   }")
    lines.append("")
    lines.append("// EXEMPLO DE USO:")
    lines.append("// if(IsTradeBlocked())")
    lines.append("//    {")
    lines.append("//    Print(\"Trade bloqueado por filtro anti-catastrofe\");")
    lines.append("//    return;")
    lines.append("//    }")
    lines.append("// ====================================================")

    return "\n".join(lines)


class PDFBuilder:
    """Monta relatorio PDF com callbacks corrigidos (closures)."""

    def __init__(self, output_path, analyzer, charts, narratives,
                 news_impact=None, mql5_metrics=None):
        self.output = output_path
        self.a = analyzer
        self.charts = charts
        self.narr = narratives
        self.news_impact = news_impact
        self.mql5 = mql5_metrics
        self.elements = []
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
            fontName='Helvetica-Bold', fontSize=12, textColor=colors.HexColor(C['silver']),
            spaceBefore=12, spaceAfter=6)
        self.s_body = ParagraphStyle('Body', parent=self.styles['Normal'],
            fontName='Helvetica', fontSize=9, textColor=colors.HexColor(C['dark']),
            spaceAfter=6, leading=13, alignment=TA_JUSTIFY)
        self.s_body_small = ParagraphStyle('BodySmall', parent=self.s_body,
            fontSize=8, leading=11)
        self.s_code = ParagraphStyle('Code', parent=self.styles['Code'],
            fontName='Courier', fontSize=7, textColor=colors.HexColor(C['dark']),
            backColor=colors.HexColor('#F0F2F5'), leftIndent=10, rightIndent=10,
            spaceBefore=4, spaceAfter=4, leading=9,
            borderPadding=6, borderColor=colors.HexColor('#D0D5DD'), borderWidth=0.5)
        self.s_callout = ParagraphStyle('Callout', parent=self.s_body,
            fontName='Helvetica', fontSize=9, leading=13,
            backColor=colors.HexColor('#EBF5FB'), borderPadding=8,
            leftIndent=10, rightIndent=10, spaceBefore=6, spaceAfter=6,
            borderColor=colors.HexColor(C['orange']), borderWidth=1.5)
        self.s_callout_red = ParagraphStyle('CalloutRed', parent=self.s_callout,
            backColor=colors.HexColor('#FDEDEC'), borderColor=colors.HexColor(C['red']))
        self.s_callout_green = ParagraphStyle('CalloutGreen', parent=self.s_callout,
            backColor=colors.HexColor('#EAFAF1'), borderColor=colors.HexColor(C['green']))
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
        self._add(HRFlowable(width="100%", thickness=0.5,
                              color=colors.HexColor(C['light']),
                              spaceBefore=6, spaceAfter=6))

    def _cover_page(self):
        self._add(Spacer(1, 1))
        self._add(PageBreak())

    def _metric_box(self, label, value, color_hex=C['navy'], subtitle=None):
        rows = [
            [Paragraph(f'<font color="{color_hex}"><b>{value}</b></font>',
                       self.s_metric_value)],
        ]
        if subtitle:
            rows.append([Paragraph(
                f'<font color="{C["gray"]}" size="7">{subtitle}</font>',
                self.s_metric_label)])
        rows.append([Paragraph(label, self.s_metric_label)])
        t = Table(rows, colWidths=[35 * mm])
        t.setStyle(TableStyle([
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('BOX', (0, 0), (-1, -1), 1, colors.HexColor(C['light'])),
            ('TOPPADDING', (0, 0), (-1, 0), 8),
            ('BOTTOMPADDING', (0, -1), (-1, -1), 6),
            ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor(C['lighter'])),
        ]))
        return t

    def _data_table(self, headers, rows, col_widths=None, highlight_col=None):
        header_paras = [
            Paragraph(f'<b>{h}</b>',
                      ParagraphStyle('TH', parent=self.s_body_small,
                        fontName='Helvetica-Bold', textColor=colors.white,
                        alignment=TA_CENTER))
            for h in headers
        ]
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
            ('TOPPADDING', (0, 0), (-1, -1), 3),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 3),
        ]
        if highlight_col is not None and len(rows) > 0:
            for i in range(len(rows)):
                val = rows[i][highlight_col]
                if isinstance(val, (int, float)):
                    color = C['green'] if val > 0 else (C['red'] if val < 0 else C['gray'])
                    style_cmds.append(
                        ('TEXTCOLOR', (highlight_col, i + 1),
                         (highlight_col, i + 1), colors.HexColor(color)))
        t.setStyle(TableStyle(style_cmds))
        return t

    def _section(self, number, title):
        self._add(Paragraph(f"<seq id='sec'>{number}</seq>. {title}", self.s_h1))
        self._hr()

    def build_pdf(self):
        b = self.a.results['basic']
        t = self.a.results['tail_risk']
        boot = self.a.results['bootstrap']
        macro = self.a.results.get('macro', {})
        cat = self.a.results.get('catastrophe', {})
        temporal = self.a.results.get('temporal', {})
        ic = self.a.results.get('ic', [])
        effects = self.a.results.get('effect_sizes', [])
        regime = self.a.results.get('regime', {})
        ac = self.a.results.get('autocorr', {})

        self._cover_page()

        # Page 2: Executive Summary
        self._section(1, "Executive Summary")
        wr_ci = (boot.get('wr_ci_low', 0), boot.get('wr_ci_high', 0))
        r_ci = (boot.get('mean_ci_low', 0), boot.get('mean_ci_high', 0))

        sr = b.get('sharpe_annual', 0)
        calmar = b.get('calmar', 0)
        sqn = b.get('sqn', 0)
        payoff = b.get('payoff', 0)
        pf = b.get('profit_factor', 0)

        metric_data = [
            [self._metric_box("Trades", str(b['n_trades']), C['silver']),
             self._metric_box("Win Rate",
                 f"{b['win_rate']:.1f}%",
                 C['green'] if b['win_rate'] > 50 else C['red'],
                 f"IC95% [{wr_ci[0]:.1f}% - {wr_ci[1]:.1f}%]"),
             self._metric_box("Avg R",
                 f"{b['avg_r']:.2f}R",
                 C['green'] if b['avg_r'] > 0 else C['red'],
                 f"IC95% [{r_ci[0]:.2f}R - {r_ci[1]:.2f}R]"),
             self._metric_box("PnL Total", f"${b['total_pnl']:.2f}",
                 C['green'] if b['total_pnl'] > 0 else C['red']),
            ],
            [self._metric_box("Sharpe (Ann)",
                 f"{sr:.2f}",
                 C['green'] if sr > 1 else (C['orange'] if sr > 0 else C['red']),
                 ">=1.0 bom, >=2.0 excelente"),
             self._metric_box("Calmar",
                 f"{calmar:.2f}",
                 C['green'] if calmar > 2 else (C['orange'] if calmar > 0 else C['red']),
                 "Retorno / Drawdown"),
             self._metric_box("SQN",
                 f"{sqn:.2f}",
                 C['green'] if sqn > 3 else (C['orange'] if sqn > 1.5 else C['red']),
                 "System Quality Number"),
             self._metric_box("Payoff",
                 f"{payoff:.2f}",
                 C['green'] if payoff > 2 else (C['orange'] if payoff > 1 else C['red']),
                 f"Avg Win ${b.get('avg_win',0):.0f} / Avg Loss ${b.get('avg_loss',0):.0f}"),
            ],
        ]
        mt = Table(metric_data, colWidths=[48*mm, 48*mm, 48*mm, 48*mm])
        mt.setStyle(TableStyle([
            ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
            ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
            ('LEFTPADDING', (0, 0), (-1, -1), 2),
            ('RIGHTPADDING', (0, 0), (-1, -1), 2),
        ]))
        self._add(mt)
        self._add(Spacer(1, 6))

        exec_summary = self.narr.get('executive', '')
        if exec_summary:
            verdict_style = self.s_callout_green if 'POSITIVO' in exec_summary[:100] else (
                self.s_callout_red if 'NEGATIVO' in exec_summary[:100] else self.s_callout)
            self._add(Paragraph(exec_summary, verdict_style))
            self._add(Spacer(1, 4))

        # Cross-validacao com MQL5 Strategy Tester
        if self.mql5:
            self._add(Spacer(1, 6))
            self._add(Paragraph("<b>Cross-Validacao MQL5 Strategy Tester:</b>", self.s_h2))
            csv_sr = b.get('sharpe_annual', 0)
            csv_pf = b.get('profit_factor', 0)
            csv_payoff = b.get('payoff', 0)
            mql_sr = self.mql5.get('sharpe', 'N/A')
            mql_pf = self.mql5.get('payoff', 'N/A')
            mql_rc = self.mql5.get('recovery', 'N/A')
            mql_zs = self.mql5.get('zscore', 'N/A')
            mql_gh = self.mql5.get('ghpr', 'N/A')
            mql_on = self.mql5.get('ontester', 'N/A')
            cv_rows = [
                ['Metrica', 'CSV (Analytics)', 'MQL5 (Tester)'],
                ['Sharpe Ratio', f"{csv_sr:.2f}", mql_sr],
                ['Profit Factor', f"{pf:.2f}", 'N/A (no HTML)'],
                ['Payoff', f"{csv_payoff:.2f}", mql_pf],
                ['Recovery Factor', f"{abs(b.get('total_pnl',0))/max(abs(t.get('max_drawdown_pct',0.01)),0.01):.2f}", mql_rc],
                ['Z-Score', f"N/A", mql_zs],
                ['GHPR', f"N/A", mql_gh],
                ['OnTester Result', f"N/A", mql_on],
            ]
            self._add(self._data_table(
                ['Metrica', 'CSV Analytics', 'MQL5 Tester'],
                cv_rows[1:], col_widths=[36*mm, 36*mm, 36*mm]))
            self._add(Spacer(1, 4))
            self._add(Paragraph(
                "<b>Nota:</b> Diferencas sao esperadas pois o CSV reflete apenas os "
                "trades registrados pelo DataMiner, enquanto o MQL5 Strategy Tester "
                "inclui todos os trades executados (inclusive os forcar fechados ao "
                "final do teste). Consulte o relatorio HTML do Strategy Tester para "
                "a visao completa.",
                self.s_body_small))

        # Page 3: Distribution & Equity
        self._add(PageBreak())
        self._section(2, "Distribuicao de Resultados & Equity Curve")
        if 'r_distribution' in self.charts:
            self._add(Image(self.charts['r_distribution'], width=170*mm,
                            height=70*mm))
        if 'equity_curve' in self.charts:
            self._add(Image(self.charts['equity_curve'], width=170*mm,
                            height=70*mm))

        # Tabela de percentis
        pct = t.get('percentis', {})
        if pct:
            self._add(Spacer(1, 4))
            self._add(Paragraph("<b>Percentis dos R-Multiplos:</b>", self.s_h2))
            pct_rows = [
                ['Min', f"{pct.get('min', 0):.3f}R"],
                ['P5', f"{pct.get('p5', 0):.3f}R"],
                ['P25', f"{pct.get('p25', 0):.3f}R"],
                ['P50 (Mediana)', f"{pct.get('p50', 0):.3f}R"],
                ['P75', f"{pct.get('p75', 0):.3f}R"],
                ['P95', f"{pct.get('p95', 0):.3f}R"],
                ['Max', f"{pct.get('max', 0):.3f}R"],
            ]
            self._add(self._data_table(
                ['Percentil', 'Valor'], pct_rows,
                col_widths=[40*mm, 40*mm], highlight_col=1))

        if 'underwater_chart' in self.charts:
            self._add(Spacer(1, 4))
            self._add(Image(self.charts['underwater_chart'], width=170*mm,
                            height=55*mm))

        if 'monthly_heatmap' in self.charts:
            self._add(Spacer(1, 4))
            self._add(Image(self.charts['monthly_heatmap'], width=170*mm,
                            height=70*mm))

        # Page 4: Bootstrap
        self._add(PageBreak())
        self._section(3, "Robustez Estatistica - Bootstrap")
        if 'bootstrap_metrics' in self.charts:
            self._add(Image(self.charts['bootstrap_metrics'], width=170*mm,
                            height=70*mm))
        boot_conclusion = (
            "<b>Conclusao:</b> O IC 95% do resultado medio "
            + ("<b>nao inclui zero</b>, confirmando edge estatistico."
               if boot.get('mean_ci_low', 0) > 0
               else "<b>inclui zero</b>. O edge precisa de mais amostras.")
        )
        self._add(Paragraph(boot_conclusion, self.s_callout))

        # Interpretacao de curtose e assimetria
        skw = t.get('skewness', 0)
        kur = t.get('kurtosis', 0)
        skw_text = (
            f"Assimetria (Skewness) = {skw:.2f}: "
            + ("cauda direita longa (wins extremos puxam a media)."
               if skw > 0.5
               else ("cauda esquerda longa (losses extremos puxam a media)."
                     if skw < -0.5
                     else "distribuicao aproximadamente simetrica."))
        )
        kur_text = (
            f"Curtose (Kurtosis) = {kur:.2f}: "
            + ("caudas grossas — maior probabilidade de eventos extremos que o normal."
               if kur > 1
               else ("caudas mais leves que o normal — eventos extremos sao raros."
                     if kur < -0.5
                     else "aproximadamente mesocurtica (caudas normais)."))
        )
        self._add(Paragraph(f"<b>Interpretacao:</b> {skw_text} {kur_text}", self.s_body_small))

        # Page 5: Macro
        self._add(PageBreak())
        self._section(4, "Analise Macroeconomica")
        if 'macro_charts' in self.charts:
            self._add(Image(self.charts['macro_charts'], width=170*mm,
                            height=70*mm))
        macro_narr = self.narr.get('macro', '')
        if macro_narr:
            self._add(Paragraph(macro_narr, self.s_body))

        if 'macro_heatmap' in self.charts:
            self._add(Spacer(1, 4))
            self._add(Paragraph("<b>Heatmap Macro Expandido:</b> "
                                "Performance media (Avg R) em cada regime de "
                                "indicadores macro, divididos pela mediana.",
                                self.s_body_small))
            self._add(Image(self.charts['macro_heatmap'], width=150*mm,
                            height=80*mm))

        # Page 6: Catastrophe
        self._add(PageBreak())
        self._section(5, "Diagnostico de Catastrofe - 10% Piores Trades")
        cat_narr = self.narr.get('catastrophe', '')
        if cat_narr:
            self._add(Paragraph(cat_narr, self.s_body))
            self._add(Spacer(1, 4))

        # LLM analysis (if available)
        llm_cat = self.narr.get('llm_catastrophe')
        if llm_cat:
            self._add(Spacer(1, 4))
            self._add(Paragraph(
                "<b>Analise Inteligente (LLM):</b>", self.s_h2))
            llm_paragraphs = llm_cat.split('\n')
            for para in llm_paragraphs:
                para = para.strip()
                if not para:
                    continue
                if para.startswith('1.') or para.startswith('2.') or para.startswith('3.') or para.startswith('4.') or para.startswith('5.'):
                    self._add(Paragraph(f"<b>{para}</b>", self.s_body))
                else:
                    self._add(Paragraph(para, self.s_body))
                self._add(Spacer(1, 2))
        if 'catastrophe_comparison' in self.charts:
            self._add(Image(self.charts['catastrophe_comparison'],
                            width=170*mm, height=80*mm))

        if cat.get('numeric'):
            rows_table = []
            num = cat['numeric']
            headers_t = ['Feature', 'Piores (media)', 'Restante (media)',
                         'Delta', "Cohen's d", 'p-value', 'Sig']
            for feat, vals in sorted(
                    num.items(), key=lambda x: abs(x[1]['cohens_d']),
                    reverse=True)[:12]:
                rows_table.append([
                    feat, f"{vals['bad_mean']:.3f}", f"{vals['ok_mean']:.3f}",
                    f"{vals['delta']:.3f}", f"{vals['cohens_d']:.2f}",
                    f"{vals['p_value']:.4f}",
                    '***' if vals['p_value'] < 0.01 else (
                        '**' if vals['p_value'] < 0.05 else (
                            '*' if vals['p_value'] < 0.10 else ''))
                ])
            self._add(Spacer(1, 4))
            self._add(self._data_table(headers_t, rows_table,
                                        col_widths=[30*mm, 24*mm, 24*mm,
                                                    18*mm, 18*mm, 18*mm, 12*mm]))

        # Tabela Best 10% vs Worst 10%
        bvw = cat.get('best_vs_worst', {})
        if bvw:
            sig_bvw = {k: v for k, v in bvw.items()
                       if v.get('significant') and abs(v.get('cohens_d', 0)) > 0.5}
            if sig_bvw:
                self._add(Spacer(1, 6))
                self._add(Paragraph(
                    "<b>Piores 10% vs Melhores 10%:</b> "
                    "Diferencas significativas com sugestoes de filtro quantificadas",
                    self.s_h2))
                bvw_rows = []
                for feat, vals in sorted(
                        sig_bvw.items(), key=lambda x: abs(x[1]['cohens_d']),
                        reverse=True)[:8]:
                    loss_ev = vals.get('losses_evitados', 0)
                    filtro_info = ''
                    if loss_ev > 0:
                        filtro_info = f"Filtro: {vals.get('filtro_dir','')} {vals.get('valor_filtro',0):.2f} teria evitado ~{loss_ev} perdas"
                    bvw_rows.append([
                        feat,
                        f"{vals.get('bad_mean', 0):.3f}",
                        f"{vals.get('good_mean', 0):.3f}",
                        f"{vals.get('cohens_d', 0):.2f}",
                        filtro_info
                    ])
                self._add(self._data_table(
                    ['Feature', 'Piores (media)', 'Melhores (media)',
                     "Cohen's d", 'Filtro Sugerido'],
                    bvw_rows,
                    col_widths=[24*mm, 22*mm, 22*mm, 16*mm, 56*mm]))

        # Page 7: ML Filter
        self._add(PageBreak())
        self._section(6, "Filtro Anti-Catastrofe - Machine Learning")
        self._add(Paragraph(
            "Arvore de decisao treinada para classificar os 10% piores trades. "
            "Siga os ramos: se a condicao for verdadeira, desce a esquerda; "
            "se falsa, desce a direita. Ramos terminais marcados como 'DESASTRE' "
            "indicam condicoes de alto risco.",
            self.s_body))
        if 'tree_catastrophe' in self.charts:
            self._add(Image(self.charts['tree_catastrophe'], width=170*mm,
                            height=100*mm))

        mql_code = tree_to_mql5(self.a.tree_catastrophe,
                                list(self.a.X.columns))
        self._add(Paragraph(f"<b>Codigo MQL5 Gerado:</b>", self.s_h2))
        self._add(Paragraph(
            mql_code.replace('\n', '<br/>').replace('   ', '&nbsp;&nbsp;&nbsp;'),
            self.s_code))

        # Page 8: Feature Importance
        self._add(PageBreak())
        self._section(7, "Feature Importance & Information Coefficient")
        if 'ic_chart' in self.charts:
            self._add(Image(self.charts['ic_chart'], width=170*mm, height=80*mm))

        fi = self.a.results.get('feature_importances', [])
        if fi:
            # Mapa de acoes praticas por feature
            acao_map = {
                'SpreadAnomaly': 'Reduzir lote se SpreadAnomaly > 2',
                'VIX_ZScore': 'Nao operar se VIX_ZScore > 1.5 (panico)',
                'Hurst': 'Se Hurst<0.4 favorecer mean-reversion; >0.6 trend',
                'VolatilityZScore': 'Reduzir exposicao se VolZ > 1.0',
                'ATR': 'ATR elevado -> reduzir lote proporcionalmente',
                'DXY_ZScore': 'DXY forte (+1.5) favorece SELL em XAUUSD',
                'RelativeVolume': 'Volume anormal -> aguardar normalizacao',
                'DistanceVWAP_ATR': 'Muito distante do VWAP -> evitar entrada',
                'SlopeNormalized': 'Queda acentuada -> esperar estabilizar',
                'MomentumState': 'Momentum extremo -> pode reverter',
                'RiskScore': 'RiskScore > 0.7 -> reduzir tamanho',
                'SpreadAtExit': 'Spread alto na saida -> usar limite',
                'Confidence_R2': 'Baixa confianca -> pular trade',
                'Strength': 'Forca fraca (<30) -> nao entrar',
                'InitialRisk': 'Risk > 2% -> nao operar',
            }
            fi_rows = []
            for f in fi[:15]:
                feat = f[0]
                acao = acao_map.get(feat, 'Monitorar')
                fi_rows.append([feat, f"{f[1]:.4f}", acao])
            self._add(Spacer(1, 4))
            self._add(Paragraph("<b>Top 15 Features (Random Forest):</b>", self.s_h2))
            self._add(self._data_table(
                ['Feature', 'Importancia', 'Acao Pratica'], fi_rows,
                col_widths=[30*mm, 20*mm, 60*mm]))

        if effects:
            def magnitude_label(d):
                ad = abs(d)
                if ad > 0.8:   return 'Muito Grande'
                elif ad > 0.5: return 'Grande'
                elif ad > 0.2: return 'Medio'
                else:          return 'Pequeno'
            def magnitude_color(d):
                return 'green' if d > 0 else 'red'
            ef_rows = [[
                e[0],
                f"{e[1]:.3f}",
                magnitude_label(e[1]),
                '+' if e[1] > 0 else '-'
            ] for e in effects[:12]]
            self._add(Spacer(1, 4))
            self._add(Paragraph(
                "<b>Effect Sizes (Cohen's d: WIN vs LOSS):</b> "
                "Valor positivo = WIN tem media maior. Magnitude: |d|&lt;0.2 pequeno, 0.2-0.5 medio, 0.5-0.8 grande, &gt;0.8 muito grande.",
                self.s_h2))
            self._add(self._data_table(
                ['Feature', "Cohen's d", 'Magnitude', 'Direcao'], ef_rows,
                col_widths=[44*mm, 24*mm, 28*mm, 20*mm],
                highlight_col=1))

        # Page 9: SHAP
        if 'shap_chart' in self.charts:
            self._add(PageBreak())
            self._section(8, "SHAP Analysis")
            self._add(Image(self.charts['shap_chart'], width=170*mm,
                            height=100*mm))

        # Page 10: Temporal
        self._add(PageBreak())
        self._section(9, "Analise Temporal")
        if 'temporal_charts' in self.charts:
            self._add(Image(self.charts['temporal_charts'], width=170*mm,
                            height=70*mm))
        temp_narr = self.narr.get('temporal', '')
        if temp_narr:
            self._add(Paragraph(temp_narr, self.s_body))

        if temporal:
            day_names_tbl = {0: 'Dom', 1: 'Seg', 2: 'Ter', 3: 'Qua', 4: 'Qui', 5: 'Sex', 6: 'Sab'}
            for key in ['Session', 'Session14', 'EntryHour', 'DayOfWeek']:
                if key not in temporal:
                    continue
                data_dict = temporal[key]
                s_order = ['Asia_Pacific', 'Asia_Japan_SEA', 'Europe_London',
                           'Europe_Main', 'NY_Pre', 'NY_Main', 'NY_PM', 'Off_Hours']
                s14_order = ['Australia_NZ', 'Asia_1_Tokyo', 'Asia_2_China_HK',
                             'Asia_3_SE_India', 'Europe_Open', 'Europe_Main',
                             'NY_Pre_Brazil', 'NY_Open', 'NY_Main', 'NY_Post', 'Off_Hours']
                if key == 'Session':
                    keys_sorted = [k for k in s_order if k in data_dict]
                elif key == 'Session14':
                    keys_sorted = [k for k in s14_order if k in data_dict]
                elif key == 'DayOfWeek':
                    keys_sorted = sorted(data_dict.keys(),
                                         key=lambda x: int(x) if str(x).isdigit() else str(x))
                else:
                    keys_sorted = sorted(data_dict.keys(),
                                         key=lambda x: int(x) if str(x).isdigit() else str(x))
                t_rows = []
                for k in keys_sorted:
                    v = data_dict[k]
                    label = str(k)
                    if key == 'DayOfWeek':
                        label = day_names_tbl.get(int(k), str(k))
                    elif key == 'EntryHour':
                        label = f"{int(k)}h"
                    t_rows.append([
                        label,
                        str(v.get('count', 0)),
                        f"{v.get('mean', 0):.3f}R",
                        f"{v.get('std', 0):.3f}R",
                        f"{v.get('win_rate', 0):.1f}%"
                    ])
                if t_rows:
                    self._add(Spacer(1, 4))
                    self._add(Paragraph(f"<b>Performance por {key}:</b>", self.s_h2))
                    self._add(self._data_table(
                        ['Categoria', 'N', 'Avg R', 'Std R', 'Win Rate'],
                        t_rows, col_widths=[30*mm, 20*mm, 30*mm, 30*mm, 30*mm]))

        if t_rows:
                    self._add(Spacer(1, 4))
                    self._add(Paragraph(f"<b>Performance por {key}:</b>", self.s_h2))
                    self._add(self._data_table(
                        ['Categoria', 'N', 'Avg R', 'Std R', 'Win Rate'],
                        t_rows, col_widths=[30*mm, 20*mm, 30*mm, 30*mm, 30*mm]))

        # Page 11 NOVO v3.1: Regime Semantico
        regime_sem = self.a.results.get('regime_semantic')
        if regime_sem:
            self._add(PageBreak())
            self._section(11, "Regime Semantico Institucional (v5.1)")
            reg_sem_narr = self.narr.get('regime_semantic', '')
            if reg_sem_narr:
                self._add(Paragraph(reg_sem_narr, self.s_body))
                self._add(Spacer(1, 4))

            for col in ['RegimeTrendStrongBull', 'RegimeTrendStrongBear',
                        'RegimeTrendWeakBull', 'RegimeTrendWeakBear',
                        'RegimeRangeTight', 'RegimeRangeVolatile',
                        'RegimeChaos', 'RegimeReversalImminent', 'RegimeBreakoutForming']:
                if col not in regime_sem:
                    continue
                data = regime_sem[col]
                presente = data.get('Presente', {})
                ausente = data.get('Ausente', {})
                if not presente or not ausente:
                    continue
                rows_table = [
                    ['Metrica', 'Presente', 'Ausente'],
                    ['Count', str(presente.get('count', 0)), str(ausente.get('count', 0))],
                    ['Avg R', f"{presente.get('mean', 0):.3f}R", f"{ausente.get('mean', 0):.3f}R"],
                    ['Win Rate', f"{presente.get('win_rate', 0):.1f}%", f"{ausente.get('win_rate', 0):.1f}%"],
                    ['Avg MFE_R', f"{presente.get('avg_mfe_r', 0):.3f}", f"{ausente.get('avg_mfe_r', 0):.3f}"],
                    ['Avg MAE_R', f"{presente.get('avg_mae_r', 0):.3f}", f"{ausente.get('avg_mae_r', 0):.3f}"],
                    ['Capture Ratio', f"{presente.get('capture_ratio', 0):.3f}", f"{ausente.get('capture_ratio', 0):.3f}"],
                ]
                self._add(Spacer(1, 4))
                self._add(Paragraph(f"<b>{col}:</b>", self.s_h2))
                self._add(self._data_table(
                    ['Metrica', 'Presente', 'Ausente'], rows_table,
                    col_widths=[30*mm, 35*mm, 35*mm], highlight_col=1))

        # Page 12 NOVO v3.1: News Analysis
        news_analysis = self.a.results.get('news')
        if news_analysis:
            self._add(PageBreak())
            self._section(12, "Analise de Impacto de Noticias (v5.1)")
            news_narr = self.narr.get('news', '')
            if news_narr:
                self._add(Paragraph(news_narr, self.s_body))
                self._add(Spacer(1, 4))

            for col in ['NewsHighActive', 'NewsMediumActive', 'NewsImpactScore']:
                if col not in news_analysis:
                    continue
                data = news_analysis[col]
                if col == 'NewsImpactScore':
                    keys = ['Com_Impacto', 'Sem_Impacto']
                else:
                    keys = ['Presente', 'Ausente']
                rows_table = [['Metrica'] + keys]
                for k in keys:
                    if k not in data:
                        continue
                    d = data[k]
                    rows_table.append([
                        'Count', str(d.get('count', 0)) if isinstance(d.get('count'), (int, float)) else 'N/A'
                    ])
                    rows_table.append([
                        'Avg R', f"{d.get('mean', 0):.3f}R"
                    ])
                    rows.append([
                        'Win Rate', f"{d.get('win_rate', 0):.1f}%"
                    ])
                    if 'avg_mfe_r' in d:
                        rows_table.append([
                            'Avg MFE_R', f"{d.get('avg_mfe_r', 0):.3f}"
                        ])
                    if 'avg_mae_r' in d:
                        rows_table.append([
                            'Avg MAE_R', f"{d.get('avg_mae_r', 0):.3f}"
                        ])
                    if 'capture_ratio' in d:
                        rows_table.append([
                            'Capture Ratio', f"{d.get('capture_ratio', 0):.3f}"
                        ])
                self._add(Spacer(1, 4))
                self._add(Paragraph(f"<b>{col}:</b>", self.s_h2))
                self._add(self._data_table(
                    ['Metrica'] + list(data.keys()), 
                    [[row[0]] + [data[k].get(row[0].lower().replace(' ', '_'), '') for k in data.keys()] for row in rows_table[1:]],
                    col_widths=[30*mm, 35*mm, 35*mm], highlight_col=1))

            # False Block Rate
            if 'false_block_rate' in news_analysis:
                fbr = news_analysis['false_block_rate']
                self._add(Spacer(1, 6))
                self._add(Paragraph("<b>False Block Rate Analysis:</b>", self.s_h2))
                fbr_rows = [
                    ['Metrica', 'Valor'],
                    ['Total Trades Bloqueados por News HIGH', str(fbr.get('total_news_blocked', 0))],
                    ['False Blocks (seriam WIN)', str(fbr.get('false_blocks', 0))],
                    ['False Block Rate', f"{fbr.get('false_block_pct', 0):.1f}%"],
                    ['Avg R se tomados', f"{fbr.get('avg_r_if_taken', 0):.3f}R"],
                ]
                self._add(self._data_table(
                    ['Metrica', 'Valor'], fbr_rows,
                    col_widths=[60*mm, 30*mm], highlight_col=1))

            # NewsHigh x RegimeChaos
            if 'NewsHigh_x_RegimeChaos' in news_analysis:
                self._add(Spacer(1, 6))
                self._add(Paragraph("<b>Interacao News HIGH x Regime CHAOS:</b>", self.s_h2))
                combo = news_analysis['NewsHigh_x_RegimeChaos']
                combo_rows = [['NewsHigh', 'RegimeChaos', 'Count', 'Avg R', 'Win Rate']]
                for (nh, rc), vals in combo.items():
                    combo_rows.append([
                        'Presente' if nh else 'Ausente',
                        'Presente' if rc else 'Ausente',
                        str(vals.get('count', 0)),
                        f"{vals.get('mean', 0):.3f}R",
                        f"{vals.get('win_rate', 0):.1f}%"
                    ])
                self._add(self._data_table(
                    ['NewsHigh', 'RegimeChaos', 'Count', 'Avg R', 'Win Rate'], combo_rows,
                    col_widths=[24*mm, 24*mm, 20*mm, 24*mm, 24*mm]))

        # Page 12: Correlation (renumerado)
        if 'correlation_heatmap' in self.charts:
            self._add(Image(self.charts['correlation_heatmap'],
                            width=160*mm, height=130*mm))

        # Page 12: Regimes
        self._add(PageBreak())
        self._section(11, "Deteccao de Regimes de Mercado (K-Means)")
        if 'regime_chart' in self.charts:
            self._add(Image(self.charts['regime_chart'], width=170*mm, height=80*mm))
            self._add(Spacer(1, 4))
        if regime:
            reg_rows = []
            for rl, rd in regime.items():
                reg_rows.append([
                    rl, str(rd.get('n', 0)),
                    f"{rd.get('avg_r', 0):.3f}R",
                    f"{rd.get('win_rate', 0):.1f}%",
                    f"{rd.get('avg_atr', 0):.2f}",
                    f"{rd.get('avg_vol_z', 0):.2f}"
                ])
            self._add(self._data_table(
                ['Regime', 'N', 'Avg R', 'Win Rate', 'ATR', 'Vol Z'],
                reg_rows, col_widths=[24*mm, 16*mm, 24*mm, 24*mm, 24*mm, 24*mm]))
        else:
            self._add(Paragraph(
                "Nao foi possivel detectar regimes (amostra insuficiente).",
                self.s_body))

        # Page 13: Autocorrelation
        self._add(PageBreak())
        self._section(12, "Dependencia Serial (Autocorrelacao)")
        if 'acf_chart' in self.charts:
            self._add(Image(self.charts['acf_chart'], width=170*mm, height=55*mm))
        if ac:
            ac_text = (
                f"<b>Autocorrelacao lag-1:</b> {ac.get('lag1', 0):.4f} "
                f"(p-value: {ac.get('p_value', 1):.4f})<br/>"
            )
            lb = ac.get('ljung_box', {})
            if lb:
                ac_text += "<b>Teste Ljung-Box:</b> "
                for lag, vals in lb.items():
                    sig = '*' if vals['p_value'] < 0.05 else 'ns'
                    ac_text += f"Lag-{lag}: Q={vals['q_stat']:.2f} (p={vals['p_value']:.3f}, {sig}) "
                ac_text += "<br/>"
            if ac.get('lag1', 0) > 0.3 and ac.get('p_value', 1) < 0.05:
                ac_text += "Efeito momentum detectado: trades vencedores seguem vencedores."
            elif ac.get('lag1', 0) < -0.3 and ac.get('p_value', 1) < 0.05:
                ac_text += "Efeito mean-reversion detectado: o resultado tende a inverter."
            else:
                ac_text += "Nenhuma dependencia serial significativa detectada."
            self._add(Paragraph(ac_text, self.s_callout))

        # Page 14: News Impact
        if self.news_impact:
            self._add(PageBreak())
            self._section(14, "Impacto de Noticias Economicas")
            self._add(Paragraph(
                "Analise de performance dos trades com base em eventos economicos "
                "do calendario ForexFactory dentro de uma janela de 4 horas.",
                self.s_body))
            self._add(Spacer(1, 4))
            rows_news = []
            for k, v in self.news_impact.items():
                rows_news.append([
                    k, str(v.get('count', 0)),
                    f"{v.get('win_rate', 0):.1f}%",
                    f"{v.get('avg_r', 0):.3f}R",
                ])
            self._add(self._data_table(
                ['Grupo', 'N', 'Win Rate', 'Avg R'],
                rows_news,
                col_widths=[40*mm, 20*mm, 30*mm, 30*mm],
                highlight_col=3))
            if 'Com noticias' in self.news_impact and 'Sem noticias' in self.news_impact:
                with_news = self.news_impact['Com noticias']
                without = self.news_impact['Sem noticias']
                if with_news.get('count', 0) >= 3 and without.get('count', 0) >= 3:
                    delta_wr = with_news.get('win_rate', 0) - without.get('win_rate', 0)
                    delta_r = with_news.get('avg_r', 0) - without.get('avg_r', 0)
                    if abs(delta_wr) > 3 or abs(delta_r) > 0.3:
                        direction_wr = "maior" if delta_wr > 0 else "menor"
                        direction_r = "melhor" if delta_r > 0 else "pior"
                        insight = (
                            f"<b>Insight:</b> Trades proximos a noticias apresentam Win Rate "
                            f"{direction_wr} ({with_news.get('win_rate', 0):.1f}% vs "
                            f"{without.get('win_rate', 0):.1f}%) e resultado medio "
                            f"{direction_r} ({with_news.get('avg_r', 0):.3f}R vs "
                            f"{without.get('avg_r', 0):.3f}R)."
                        )
                        self._add(Spacer(1, 4))
                        style_n = (self.s_callout_green if delta_r > 0
                                   else self.s_callout_red)
                        self._add(Paragraph(insight, style_n))

        # Page 15: Recommendations
        self._add(PageBreak())
        self._section(15, "Recomendacoes de Acao")
        recs = self.narr.get('recommendations', [])
        if recs:
            for priority, text in recs:
                color_map = {'ALTA': C['red'], 'MEDIA': C['orange'],
                             'BAIXA': C['green']}
                pc = color_map.get(priority, C['gray'])
                label = f'<font color="{pc}"><b>[{priority}]</b></font>'
                self._add(Paragraph(f"{label} {text}", self.s_body))
                self._add(Spacer(1, 2))

        doc = SimpleDocTemplate(
            self.output,
            pagesize=A4,
            leftMargin=18*mm,
            rightMargin=18*mm,
            topMargin=30*mm,
            bottomMargin=22*mm,
            title="ALXQuant Alpha Research",
            author="ALXQuant AI Engine v3.0",
        )

        analyzer_ref = self.a

        def on_first_page(canvas_obj, doc_obj):
            PDFBuilder._draw_cover(canvas_obj, A4, analyzer_ref)

        def on_later_pages(canvas_obj, doc_obj):
            PDFBuilder._draw_header_footer(canvas_obj, A4,
                                           doc_obj.page, analyzer_ref)

        doc.build(self.elements, onFirstPage=on_first_page,
                  onLaterPages=on_later_pages)
        logger.info(f"PDF gerado: {self.output}")

    @staticmethod
    def _draw_cover(canvas_obj, page_size, analyzer):
        w, h = page_size
        canvas_obj.saveState()
        canvas_obj.setFillColor(colors.HexColor(C['navy']))
        canvas_obj.rect(0, 0, w, h, fill=1, stroke=0)
        canvas_obj.setFillColor(colors.HexColor(C['orange']))
        canvas_obj.rect(25*mm, h/2 - 10*mm, 3*mm, 80*mm, fill=1, stroke=0)
        try:
            canvas_obj.drawImage(LOGO_PATH, 30*mm, h - 45*mm, width=35*mm,
                                 height=35*mm, preserveAspectRatio=True)
        except Exception:
            pass
        canvas_obj.setFillColor(colors.white)
        canvas_obj.setFont('Helvetica-Bold', 36)
        canvas_obj.drawString(75*mm, h/2 + 50*mm, "ALPHA RESEARCH")
        canvas_obj.drawString(75*mm, h/2 + 25*mm, "REPORT")
        canvas_obj.setFillColor(colors.HexColor(C['orange']))
        canvas_obj.setFont('Helvetica', 13)
        canvas_obj.drawString(75*mm, h/2 + 5*mm,
                              "Analise Quantitativa Institucional")
        canvas_obj.setFont('Helvetica', 11)
        info = "Asset: {}  |  Trades: {}  |  {}".format(
            analyzer.symbol, analyzer.n, analyzer.date_range)
        canvas_obj.drawString(75*mm, h/2 - 15*mm, info)
        canvas_obj.setFillColor(colors.HexColor(C['silver']))
        canvas_obj.setFont('Helvetica', 9)
        canvas_obj.drawString(35*mm, 35*mm,
                              "Gerado em: " + datetime.now().strftime('%d/%m/%Y - %H:%M'))
        canvas_obj.drawString(35*mm, 25*mm, "ALXQuant Research Engine v3.0")
        canvas_obj.setFillColor(colors.HexColor(C['orange']))
        canvas_obj.setFont('Helvetica-Bold', 11)
        canvas_obj.drawCentredString(w/2, 15*mm, "CONFIDENTIAL")
        canvas_obj.restoreState()

    @staticmethod
    def _draw_header_footer(canvas_obj, page_size, page_num, analyzer):
        w, h = page_size
        canvas_obj.saveState()
        canvas_obj.setFillColor(colors.HexColor(C['navy']))
        canvas_obj.rect(0, h - 22*mm, w, 22*mm, fill=1, stroke=0)
        try:
            canvas_obj.drawImage(LOGO_PATH, 6*mm, h - 20*mm, width=14*mm,
                                 height=14*mm, preserveAspectRatio=True)
        except Exception:
            pass
        canvas_obj.setFillColor(colors.white)
        canvas_obj.setFont('Helvetica-Bold', 9)
        canvas_obj.drawString(24*mm, h - 14*mm,
                              "ALXQUANT  |  ALPHA RESEARCH REPORT")
        canvas_obj.setFont('Helvetica', 8)
        canvas_obj.drawRightString(w - 18*mm, h - 14*mm, analyzer.symbol)
        canvas_obj.setStrokeColor(colors.HexColor(C['orange']))
        canvas_obj.setLineWidth(2)
        canvas_obj.line(0, h - 22*mm, w, h - 22*mm)
        canvas_obj.setStrokeColor(colors.HexColor(C['light']))
        canvas_obj.setLineWidth(0.5)
        canvas_obj.line(18*mm, 15*mm, w - 18*mm, 15*mm)
        canvas_obj.setFillColor(colors.HexColor(C['gray']))
        canvas_obj.setFont('Helvetica', 7)
        canvas_obj.drawString(18*mm, 10*mm,
                              "Gerado: " + datetime.now().strftime('%Y-%m-%d %H:%M'))
        canvas_obj.drawCentredString(w/2, 10*mm,
                                     f"- {page_num - 1} -")
        canvas_obj.drawRightString(w - 18*mm, 10*mm,
                                   f"ALXQuant v3.0 | {analyzer.n} trades")
        canvas_obj.restoreState()


def run_analysis(csv_path=None, output_path=None, analyzer=None):
    """Executa pipeline completo de analise e geracao de PDF.
    Se `analyzer` (QuantAnalyzer ja construido) for passado, reutiliza-o
    (evita reler/limpar o CSV de forma incompativel com o endpoint)."""
    if analyzer is not None:
        a = analyzer
    else:
        logger.info(f"Carregando dados: {csv_path}")
        df = load_and_clean_data(csv_path)
        logger.info(f"Iniciando analise quantitativa ({len(df)} trades)...")
        a = QuantAnalyzer(df)

    logger.info("Carregando calendario economico ForexFactory...")
    df_cal = load_forexfactory_calendar()
    news_impact = analyze_news_impact(a.df, df_cal) if df_cal is not None else None

    logger.info("Gerando graficos...")
    global CHART_DIR
    CHART_DIR = tempfile.mkdtemp(prefix='alxquant_charts_')
    cg = ChartGenerator(a)
    charts = cg.generate_all()

    logger.info("Gerando narrativas...")
    ne = NarrativeEngine()
    narratives = {
        'executive': ne.executive_summary(a),
        'macro': ne.macro_interpretation(a),
        'catastrophe': ne.catastrophe_interpretation(a),
        'temporal': ne.temporal_interpretation(a),
        'regime_semantic': ne.regime_semantic_interpretation(a),    # NOVO v3.1
        'news': ne.news_interpretation(a),                          # NOVO v3.1
        'recommendations': ne.recommendations(a),
    }

    logger.info("Analise via LLM...")
    try:
        from llm_analyzer import LLMAnalyzer
        llm = LLMAnalyzer()
        llm_catastrophe = llm.analyze_catastrophe(a)
        if llm_catastrophe:
            narratives['llm_catastrophe'] = llm_catastrophe
            logger.info("Analise LLM para catastrofe OK")
        else:
            narratives['llm_catastrophe'] = None
    except ModuleNotFoundError:
        logger.warning("llm_analyzer nao importavel (modulo em _old_not_used); LLM omitido")
        narratives['llm_catastrophe'] = None
    except Exception as e:
        logger.warning(f"Analise LLM falhou: {e}")
        narratives['llm_catastrophe'] = None

    logger.info("Carregando relatorio MQL5 Strategy Tester...")
    mql5_metrics = load_mql5_report()

    logger.info(f"Construindo PDF: {output_path}")
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    pb = PDFBuilder(output_path, a, charts, narratives, news_impact,
                    mql5_metrics=mql5_metrics)
    pb.build_pdf()

    shutil.rmtree(CHART_DIR, ignore_errors=True)

    logger.info("Concluido!")
    print(f"\nRelatorio gerado: {output_path}")
    print(f"Trades analisados: {a.n}")
    print(f"Simbolo: {a.symbol}")
    print(f"Periodo: {a.date_range}")
    print(f"Win Rate: {a.results['basic']['win_rate']:.1f}%")
    print(f"Avg R: {a.results['basic']['avg_r']:.3f}R")


def main():
    parser = argparse.ArgumentParser(
        description='ALXQuant Alpha Research Engine v3.0')
    parser.add_argument('--csv', default=r'',
                        help='Caminho do CSV (ex: C:\\ALXQuant\\data\\miner\\Ghost_v2_XAUUSD_miner.csv)')
    parser.add_argument('--output', default=r'',
                        help='Caminho do relatorio PDF (auto se nao informado)')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='Log detalhado')
    args = parser.parse_args()

    # Auto-generate output path from CSV path
    output_path = args.output
    if not output_path and args.csv:
        base = os.path.splitext(os.path.basename(args.csv))[0]
        base = base.replace('_miner', '')
        output_path = os.path.join(REPORT_DIR, f'{base}_report.pdf')
    elif not output_path:
        output_path = os.path.join(REPORT_DIR, 'alpha_research_report.pdf')

    if args.verbose:
        logger.setLevel(logging.DEBUG)

    run_analysis(args.csv, output_path)

if __name__ == '__main__':
    main()
