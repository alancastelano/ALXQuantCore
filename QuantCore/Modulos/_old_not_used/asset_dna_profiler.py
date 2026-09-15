"""
ALXQuant Asset DNA Profiler v1.1
===================================
Pipeline de perfil estrutural de ativos:
  OHLC (M1/M5) -> Feature Engine -> Regime Model -> Report PDF -> MQL5 Constants

Uso: python asset_dna_profiler.py --symbol EURUSD --tf M1
      python asset_dna_profiler.py --input C:\ALXQuant\data\datasets\EURUSD_M1.csv
"""

import os, sys, warnings, textwrap, subprocess
import pandas as pd
import numpy as np
from datetime import datetime
from scipy import stats

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
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

warnings.filterwarnings('ignore')

# ══════════════════════════════════════════════════════════════
# CONFIGURAÇÃO VISUAL (mesmo estilo do alpha_research_v2.py)
# ══════════════════════════════════════════════════════════════
C = {
    'navy':      '#0A1628',
    'dark':      '#1A1A2E',
    'steel':     '#2C5F8A',
    'blue':      '#3498DB',
    'gold':      '#D4A843',
    'green':     '#27AE60',
    'red':       '#E74C3C',
    'orange':    '#F39C12',
    'purple':    '#9B59B6',
    'teal':      '#1ABC9C',
    'light':     '#ECF0F1',
    'lighter':   '#F8F9FA',
    'gray':      '#666666',
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

OUTPUT_DIR = r"C:\ALXQuant\data\datasets"
REPORT_DIR = r"C:\ALXQuant\data\report\asset_dna"
CHART_DIR = os.path.join(REPORT_DIR, '_charts')
os.makedirs(CHART_DIR, exist_ok=True)

SESSION_MAP = {
    'Asia': (0, 8),
    'London': (8, 13),
    'NY_AM': (13, 17),
    'NY_PM': (17, 24),
}

REGIME_COLORS = {
    'TREND_FORTE': '#27AE60',
    'TREND_FRACO': '#3498DB',
    'RANGE':       '#F39C12',
    'CHOP':        '#E74C3C',
}


# ══════════════════════════════════════════════════════════════
# DATA LOADER
# ══════════════════════════════════════════════════════════════
class DataLoader:
    def __init__(self, filepath=None):
        if filepath is None:
            filepath = os.path.join(OUTPUT_DIR, "XAUUSD_M5.csv")
        self.filepath = filepath
        self.df = None

    def load(self):
        print(f"[LOAD] {self.filepath}")
        if not os.path.exists(self.filepath):
            print(f"  ERRO: Arquivo nao encontrado: {self.filepath}")
            print(f"  Dica: Execute primeiro: python mt5_data_collector.py")
            sys.exit(1)
        self.df = pd.read_csv(self.filepath, parse_dates=['time'])
        self.df.set_index('time', inplace=True)
        self.df.index.name = 'time'
        print(f"  [OK] {len(self.df)} candles | {self.df.index[0]} a {self.df.index[-1]}")
        return self.df


# ══════════════════════════════════════════════════════════════
# FEATURE ENGINE
# ══════════════════════════════════════════════════════════════
class FeatureEngine:
    def __init__(self, df, tf='M5'):
        self.df = df.copy()
        # Escala de janelas: M1 precisa de 5x mais candles para mesmo periodo
        self.ws = 5 if tf == 'M1' else 1

    def compute(self):
        df = self.df
        print(f"[FEATURES] Computando features (janelas x{self.ws})...")

        # Retornos
        df['return'] = df['close'].pct_change()
        df['log_return'] = np.log(df['close'] / df['close'].shift(1))

        # ATR(14 * ws)
        df['tr'] = np.maximum(
            df['high'] - df['low'],
            np.maximum(
                abs(df['high'] - df['close'].shift(1)),
                abs(df['low'] - df['close'].shift(1))
            )
        )
        df['atr'] = df['tr'].rolling(14 * self.ws).mean()

        # Z-Score de volatilidade
        df['tr_zscore'] = (df['tr'] - df['tr'].rolling(500 * self.ws).mean()) / df['tr'].rolling(500 * self.ws).std().clip(lower=1e-10)

        # Vol Z-score suavizado
        df['atr_50'] = df['tr'].rolling(50 * self.ws).mean()
        df['vol_zscore'] = (df['atr_50'] - df['tr'].rolling(500 * self.ws).mean()) / df['tr'].rolling(500 * self.ws).std().clip(lower=1e-10)

        # Volume Z-Score
        df['vol_ma'] = df['tick_volume'].rolling(50 * self.ws).mean()
        df['vol_std'] = df['tick_volume'].rolling(50 * self.ws).std()
        df['volume_zscore'] = (df['tick_volume'] - df['vol_ma']) / df['vol_std'].clip(lower=1e-10)

        # ADX(14 * ws)
        df['up_move'] = df['high'].diff()
        df['down_move'] = -df['low'].diff()
        df['plus_dm'] = np.where((df['up_move'] > df['down_move']) & (df['up_move'] > 0), df['up_move'], 0)
        df['minus_dm'] = np.where((df['down_move'] > df['up_move']) & (df['down_move'] > 0), df['down_move'], 0)
        df['tr_smooth'] = df['tr'].rolling(14 * self.ws).mean()
        df['plus_di'] = 100 * df['plus_dm'].rolling(14 * self.ws).mean() / df['tr_smooth'].clip(lower=1e-10)
        df['minus_di'] = 100 * df['minus_dm'].rolling(14 * self.ws).mean() / df['tr_smooth'].clip(lower=1e-10)
        df['dx'] = 100 * abs(df['plus_di'] - df['minus_di']) / (df['plus_di'] + df['minus_di']).clip(lower=1e-10)
        df['adx'] = df['dx'].rolling(14 * self.ws).mean()

        # Hurst Exponent (janela 100 * ws)
        df['log_price'] = np.log(df['close'])
        df['hurst'] = df['log_price'].rolling(100 * self.ws).apply(self._hurst_exponent, raw=False)

        # Multi-timeframe returns via resample
        df['return_m15'] = self._resample_return('15min')
        df['return_h1'] = self._resample_return('1h')
        df['return_h4'] = self._resample_return('4h')
        df['return_d1'] = self._resample_return('1D')

        # Sessão
        df['hour'] = df.index.hour
        df['day_of_week'] = df.index.dayofweek
        df['month'] = df.index.month
        df['session'] = df['hour'].map(self._classify_session)

        df.dropna(inplace=True)
        print(f"  [OK] {len(df)} candles apos feature engineering")
        return df

    @staticmethod
    def _hurst_exponent(series):
        series = np.asarray(series, dtype=float)
        if np.std(series) < 1e-10 or len(series) < 50:
            return 0.5
        lags = range(2, min(50, len(series) // 2))
        tau = []
        for lag in lags:
            diff = series[lag:] - series[:-lag]
            s = np.std(diff)
            if s > 1e-10:
                tau.append(s)
            else:
                tau.append(np.nan)
        tau = np.array(tau)
        valid = ~np.isnan(tau) & (tau > 1e-10)
        if valid.sum() < 5:
            return 0.5
        lags_arr = np.array(list(lags))[valid]
        tau_valid = tau[valid]
        try:
            poly = np.polyfit(np.log(lags_arr), np.log(tau_valid), 1)
            return float(np.clip(poly[0], 0.01, 0.99))
        except Exception:
            return 0.5

    def _resample_return(self, freq):
        close = self.df['close'].resample(freq, label='right').last()
        close = close.reindex(self.df.index, method='ffill')
        return close.pct_change()

    @staticmethod
    def _classify_session(h):
        if 0 <= h < 8:
            return 'Asia'
        elif 8 <= h < 13:
            return 'London'
        elif 13 <= h < 17:
            return 'NY_AM'
        else:
            return 'NY_PM'


# ══════════════════════════════════════════════════════════════
# REGIME MODEL
# ══════════════════════════════════════════════════════════════
class RegimeModel:
    def __init__(self, df):
        self.df = df.copy()

    def classify(self):
        df = self.df
        print("[REGIMES] Classificando regimes...")

        conditions = [
            (df['adx'] > 30) & (df['hurst'] > 0.55),
            (df['adx'] > 20) & (df['hurst'] > 0.45),
            (df['adx'] < 20) & (df['hurst'] < 0.45),
            (df['adx'] < 20) & (df['hurst'] > 0.50),
        ]
        choices = ['TREND_FORTE', 'TREND_FRACO', 'RANGE', 'CHOP']
        df['regime'] = np.select(conditions, choices, default='RANGE')

        dist = df['regime'].value_counts()
        for r in ['TREND_FORTE', 'TREND_FRACO', 'RANGE', 'CHOP']:
            pct = dist.get(r, 0) / len(df) * 100
            print(f"  {r}: {pct:.1f}%")

        return df

    @staticmethod
    def transition_matrix(df):
        regimes = df['regime'].values
        labels = ['TREND_FORTE', 'TREND_FRACO', 'RANGE', 'CHOP']
        n = len(labels)
        mat = np.zeros((n, n))
        for i in range(len(regimes) - 1):
            r_from = np.where(np.array(labels) == regimes[i])[0]
            r_to = np.where(np.array(labels) == regimes[i + 1])[0]
            if len(r_from) and len(r_to):
                mat[r_from[0], r_to[0]] += 1
        row_sums = mat.sum(axis=1, keepdims=True)
        mat_prob = np.divide(mat, row_sums, out=np.zeros_like(mat, dtype=float), where=row_sums > 0)
        return mat_prob, labels


# ══════════════════════════════════════════════════════════════
# TEMPORAL PROFILER
# ══════════════════════════════════════════════════════════════
class TemporalProfiler:
    def __init__(self, df):
        self.df = df.copy()
        self.profile = {}

    def analyze(self):
        df = self.df
        print("[TEMPORAL] Analisando sazonalidade...")

        groups = {
            'hour': 'hour',
            'day_of_week': 'day_of_week',
            'month': 'month',
            'session': 'session',
        }

        for name, col in groups.items():
            grp = df.groupby(col, observed=False)
            self.profile[name] = {
                'atr_mean': grp['atr'].mean().to_dict(),
                'volume_mean': grp['tick_volume'].mean().to_dict(),
                'regime_pct': grp['regime'].value_counts(normalize=True).unstack(fill_value=0).to_dict('index')
                if col in ['hour', 'session']
                else {},
                'gap_risk': grp['atr'].mean().to_dict() if col == 'session' else {},
            }
        print("  [OK] Perfis temporal, semanal, mensal e por sessao gerados")
        return self.profile


# ══════════════════════════════════════════════════════════════
# TAIL RISK ENGINE
# ══════════════════════════════════════════════════════════════
class TailRiskEngine:
    def __init__(self, df):
        self.df = df.copy()
        self.results = {}

    def analyze(self):
        df = self.df
        print("[TAIL RISK] Analisando risco de cauda...")

        threshold = df['atr'].quantile(0.99)
        top_atr = df[df['atr'] >= threshold]
        spikes = df[df['tr_zscore'] > 2.0]

        self.results['atr_threshold'] = threshold
        self.results['top_atr_pct'] = len(top_atr) / len(df) * 100
        self.results['top_atr_by_session'] = top_atr['session'].value_counts(normalize=True).to_dict() if len(top_atr) else {}
        self.results['spike_count'] = len(spikes)
        self.results['spike_pct'] = len(spikes) / len(df) * 100
        self.results['spike_by_session'] = spikes['session'].value_counts(normalize=True).to_dict() if len(spikes) else {}
        self.results['avg_atr_spike'] = spikes['atr'].mean() if len(spikes) else 0
        self.results['avg_atr_normal'] = df[df['tr_zscore'] <= 2.0]['atr'].mean()

        print(f"  Top 1% ATR threshold: {threshold:.2f}")
        print(f"  Spikes (Vol Z>2): {len(spikes)} candles ({len(spikes)/len(df)*100:.2f}%)")
        return self.results


# ══════════════════════════════════════════════════════════════
# NARRATIVE ENGINE
# ══════════════════════════════════════════════════════════════
class NarrativeEngine:
    def __init__(self, df, regime_model, temporal, tail_risk):
        self.df = df
        self.regime_model = regime_model
        self.temporal = temporal
        self.tail_risk = tail_risk

    def generate(self):
        df = self.df
        dominant = df['regime'].value_counts().index[0]
        dominant_pct = df['regime'].value_counts(normalize=True).iloc[0] * 100

        noise_level = df['hurst'].mean()
        if noise_level < 0.45:
            noise_desc = "Alta (mercado ruidoso)"
        elif noise_level < 0.55:
            noise_desc = "Media (mercado aleatorio)"
        else:
            noise_desc = "Baixa (mercado tendente)"

        vol_hour = df.groupby('hour')['atr'].mean().idxmax()

        session_regime = self.temporal.get('session', {}).get('regime_pct', {})
        trend_session = None
        for s in ['NY_AM', 'London', 'NY_PM', 'Asia']:
            if s in session_regime:
                rp = session_regime[s]
                trend_pct = sum(rp.get(r, 0) for r in ['TREND_FORTE', 'TREND_FRACO'])
                if trend_session is None or trend_pct > trend_session[1]:
                    trend_session = (s, trend_pct)

        exec_summary = (
            f"O perfil estrutural do ativo revela {dominant} como regime dominante "
            f"({dominant_pct:.1f}% do periodo amostral). "
            f"O nivel de ruido estrutural (Hurst medio: {noise_level:.2f}) indica {noise_desc}. "
            f"A hora mais volatil e {vol_hour:02d}h, "
            f"e a sessao com maior propensao a tendencia e {trend_session[0] if trend_session else 'N/A'} "
            f"({trend_session[1]:.1f}% tendencia)."
        )

        transition_text = "A matriz de Markov indica a seguinte dinâmica de transicao entre regimes."
        tail_text = (
            f"Risco de cauda: {self.tail_risk['spike_count']} spikes de volatilidade "
            f"(Vol Z>2, {self.tail_risk['spike_pct']:.1f}% das amostras). "
            f"ATR medio em spikes: {self.tail_risk['avg_atr_spike']:.2f} "
            f"vs {self.tail_risk['avg_atr_normal']:.2f} em condicoes normais."
        )

        self.narratives = {
            'executive': exec_summary,
            'transition': transition_text,
            'tail_risk': tail_text,
        }
        return self.narratives


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

    def generate_all(self):
        print("[CHARTS] Gerando graficos...")
        self._heatmap_hour_day_atr()
        self._heatmap_hour_day_trend()
        self._markov_matrix()
        self._regime_bars()
        self._boxplot_atr_month()
        self._intraday_curve()
        print(f"  [OK] {len(self.charts)} graficos gerados")
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
        path = os.path.join(CHART_DIR, 'heatmap_atr.png')
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
        path = os.path.join(CHART_DIR, 'heatmap_trend.png')
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
        path = os.path.join(CHART_DIR, 'markov_matrix.png')
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
        path = os.path.join(CHART_DIR, 'regime_bars.png')
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
        path = os.path.join(CHART_DIR, 'boxplot_atr_month.png')
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
        path = os.path.join(CHART_DIR, 'intraday_curve.png')
        fig.savefig(path, dpi=150, bbox_inches='tight')
        plt.close(fig)
        self.charts['intraday_curve'] = path


# ══════════════════════════════════════════════════════════════
# PDF REPORT BUILDER (mesmo estilo do alpha_research_v2.py)
# ══════════════════════════════════════════════════════════════
class PDFReportBuilder:
    def __init__(self, output_path, charts, narratives, df, transition_mat, regime_labels, features, tf='M5'):
        self.output = output_path
        self._tf = tf
        self.charts = charts
        self.narr = narratives
        self.df = df
        self.transition_mat = transition_mat
        self.regime_labels = regime_labels
        self.features = features
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
            f"",
            f"// --- Regime Parameters ---",
            f"#define DOMINANT_REGIME \"{dominant}\"",
            f"#define AVG_HURST {avg_hurst:.2f}",
            f"#define AVG_ADX {avg_adx:.1f}",
            f"#define TREND_PROBABILITY {trend_pct:.1f}",
            f"#define CHOP_PROBABILITY {chop_pct:.1f}",
            f"#define RANGE_PROBABILITY {range_pct:.1f}",
            f"",
            f"// --- Seasonality Parameters ---",
            f"#define PEAK_VOL_HOUR {vol_hour}",
            f"#define BEST_TREND_SESSION \"{best_session}\"",
            f"#define BEST_TREND_SESSION_PROBABILITY {best_session_trend:.0f}",
            f"",
            f"// --- Transition Probabilities ---",
        ]
        for i, frm in enumerate(self.regime_labels):
            for j, to in enumerate(self.regime_labels):
                if self.transition_mat[i, j] > 0.10:
                    mql5_lines.append(
                        f"#define TRANS_{frm[:4].upper()}_TO_{to[:4].upper()} {self.transition_mat[i, j]:.2f}"
                    )

        mql5_lines.extend([
            f"",
            f"// --- Tail Risk ---",
            f"#define TOP1PCT_ATR {self.features.get('tail_risk', {}).get('atr_threshold', 0):.2f}",
            f"#define SPIKE_FREQUENCY {self.features.get('tail_risk', {}).get('spike_pct', 0):.2f}",
        ])

        code = '\n'.join(mql5_lines)
        for line in mql5_lines:
            if line:
                self._add(Paragraph(line.replace(' ', '&nbsp;'), self.s_code))
            else:
                self._add(Spacer(1, 2))

        # Summary table
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

    def build_pdf(self):
        self._add(Spacer(1, 1))
        self._add(PageBreak())

        self.build_executive_summary()
        self.build_regime_analysis()
        self.build_temporal_analysis()
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

    @staticmethod
    def _page_cover(canvas_obj, doc):
        w, h = A4
        builder = doc._builder
        symbol = os.path.basename(builder.output).split('_')[2] if hasattr(builder, 'output') else 'ASSET'
        tf_label = builder._tf if hasattr(builder, '_tf') else 'M5'
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
        canvas_obj.drawString(35*mm, h/2 - 15*mm, f"Candles: {n:,}  |  {tf_label}  |  Gerado: {datetime.now().strftime('%d/%m/%Y')}")
        canvas_obj.setFillColor(colors.HexColor('#556677'))
        canvas_obj.setFont('Helvetica', 9)
        canvas_obj.drawString(35*mm, 35*mm, f"Gerado em: {datetime.now().strftime('%d/%m/%Y - %H:%M')}")
        canvas_obj.drawString(35*mm, 25*mm, "ALXQuant Asset DNA Profiler v1.1")
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
        canvas_obj.drawRightString(w - 18*mm, 10*mm, "ALXQuant v1.0")
        canvas_obj.restoreState()


# ══════════════════════════════════════════════════════════════
# MAIN PIPELINE
# ══════════════════════════════════════════════════════════════
def main():
    import argparse
    parser = argparse.ArgumentParser(description='Asset DNA Profiler')
    parser.add_argument('--symbol', default=None, help='Simbolo (ex: XAUUSD, EURUSD)')
    parser.add_argument('--tf', default='M5', choices=['M1', 'M5'], help='Timeframe (M1 ou M5, default M5)')
    parser.add_argument('--input', default=None, help='Caminho do CSV de entrada (opcional, sobrescreve --symbol)')
    parser.add_argument('--output', default=None, help='Caminho do PDF de saida (opcional)')
    args = parser.parse_args()

    if args.input:
        input_file = args.input
        symbol = os.path.basename(input_file).split('_')[0]
        tf = os.path.basename(input_file).split('_')[1] if '_' in os.path.basename(input_file) and len(os.path.basename(input_file).split('_')) > 1 else args.tf
    elif args.symbol:
        symbol = args.symbol.upper()
        tf = args.tf.upper()
        input_file = os.path.join(OUTPUT_DIR, f"{symbol}_{tf}.csv")
    else:
        symbol = "XAUUSD"
        tf = args.tf.upper()
        input_file = os.path.join(OUTPUT_DIR, f"{symbol}_{tf}.csv")
    output_pdf = args.output or os.path.join(REPORT_DIR, f"asset_dna_{symbol}_{tf}.pdf")

    os.makedirs(REPORT_DIR, exist_ok=True)
    os.makedirs(CHART_DIR, exist_ok=True)

    print("=" * 55)
    print("  ALXQuant Asset DNA Profiler v1.1")
    print(f"  Simbolo: {symbol} | TF: {tf} | Candles: ?")
    print("=" * 55)

    # 0) Auto-download se CSV não existir
    collector_script = os.path.join(os.path.dirname(__file__), '..', 'mt5_data_collector.py')
    if not os.path.exists(input_file) and os.path.exists(collector_script):
        print(f"\n[INFO] Dataset nao encontrado: {input_file}")
        print("[INFO] Coletando dados do MT5 automaticamente...")
        result = subprocess.run(
            [sys.executable, collector_script, '--symbol', symbol, '--tf', tf, '--years', '2']
        )
        if result.returncode != 0:
            print(f"[ERRO] Falha ao coletar dados para {symbol}")
            sys.exit(1)
        print("[INFO] Coleta concluida, prosseguindo com analise...\n")

    # 1) Load
    print("\n[1/6] Carregando dados...")
    loader = DataLoader(input_file)
    df_raw = loader.load()

    # 2) Features
    print("\n[2/6] Feature engineering...")
    fe = FeatureEngine(df_raw, tf=tf)
    df = fe.compute()

    # 3) Regimes
    print("\n[3/6] Modelagem de regimes...")
    rm = RegimeModel(df)
    df = rm.classify()
    trans_mat, regime_labels = RegimeModel.transition_matrix(df)

    # 4) Temporal + Tail Risk
    print("\n[4/6] Analise temporal e tail risk...")
    tp = TemporalProfiler(df)
    temporal = tp.analyze()

    tr = TailRiskEngine(df)
    tail_risk = tr.analyze()

    features_agg = {
        'tail_risk': tail_risk,
        'temporal': temporal,
    }

    # 5) Narrativas
    print("\n[5/6] Gerando narrativas...")
    ne = NarrativeEngine(df, rm, temporal, tail_risk)
    narratives = ne.generate()

    # 6) Charts
    print("\n[6/6] Gerando graficos e PDF...")
    cg = ChartGenerator(df, regime_labels, trans_mat, features_agg)
    charts = cg.generate_all()

    # 7) PDF
    print("\n[7/6] Montando relatorio PDF...")
    builder = PDFReportBuilder(output_pdf, charts, narratives, df, trans_mat, regime_labels, features_agg, tf=tf)
    builder.build_pdf()
    print(f"  [OK] PDF salvo: {output_pdf}")

    print(f"\n{'=' * 55}")
    print(f"  ASSET DNA PROFILE COMPLETO")
    print(f"  Simbolo: {symbol} | TF: {tf}")
    print(f"  PDF: {output_pdf}")
    print(f"{'=' * 55}")


if __name__ == '__main__':
    main()
