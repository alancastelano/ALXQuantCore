//+------------------------------------------------------------------+
//| MacroRegimeEngine_v8_refactored.mqh                              |
//| Copyright 2026, ALXQuantCore Ltd.                                |
//| v8.0.0 - REFACTORED & AUDITED                                    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link "https://www.mql5.com"
#property version "10.1"
/*
========================================================================
v8.0 - AUDITORIA COMPLETA:
1. Throttle System: Adicionado GetRegimeScore() (0-100). O motor agora 
   acelera/frea o risco em vez de apenas bloquear.
2. Bug Fix Spread: GetSpreadAnomaly agora compara spread da última barra 
   fechada vs média histórica (antes usava spread em tempo real).
3. Bug Fix VWAP: GetDailyVWAP não inclui mais a barra 0 (formando).
4. Conceito MR Fix: IsMeanReversionRegime não bloqueia Alta Volatilidade 
   ou Bursts. MR precisa de volatilidade para reverter.
5. Conceito Chaos Fix: IsChaosRegime não classifica mais "lateral = caos".
6. Conceito Liquidity Fix: Liquidez tóxica agora requer Spread Alto E Vol Alto.
   (Antes volume baixo era tóxico, o que estava invertido).
7. Unificação: GetRegime, GetLabel e GetTrend agora usam o mesmo enum base.
8. Breakout Fix: Thresholds de burst ajustados, aceita momentum moderado (1).
9. Timeframe: Recebido no Init() em vez de usar o gráfico atual.
========================================================================
*/
#property strict

//+------------------------------------------------------------------+
//| #Input                                                           |
//+------------------------------------------------------------------+
input group "▸ Market Regime Engine"
input bool   InpMacroRegime       = true;  // Macro Regime filter
input int    InpDFAPeriod         = 200;   // DFA period
input int    InpDFA_min_scale     = 4;     // DFA min scale
input int    InpDFA_max_scale     = 60;    // DFA max scale
input ENUM_TIMEFRAMES InpRegimeTimeframe   = PERIOD_CURRENT;  // Timeframe for regime calculation

input group "▸ Microstructure Filters"
input bool   InpSpreadAnomaly      = true;   // Enable Spread Anomaly filter
input double InpSpreadAnomalyValue = 2.0;    // Toxic Spread multiplier
input bool   InpRelativeVolume     = true;   // Enable Relative Volume filter
input double InpRelativeVolumeValue = 0.5;   // Dead market volume threshold

//+------------------------------------------------------------------+
//| ENUMS & STRUCTS                                                  |
//+------------------------------------------------------------------+
enum ENUM_ASSET_CLASS
{
   CLASS_METAL,
   CLASS_CRYPTO,
   CLASS_INDEX,
   CLASS_FOREX_MAJOR,
   CLASS_FOREX_CARRY
};

enum ENUM_REGIME_STATE
{
   STATE_CHAOS,
   STATE_MEAN_REVERSION,
   STATE_NEUTRAL,
   STATE_TREND,
   STATE_BREAKOUT
};

struct SAssetProfile
{
   ENUM_ASSET_CLASS asset_class;
   string class_name;
   double high_vol_mult;
   double burst_vol_mult;
   double slope_threshold;
   double trend_h_threshold;
   double trend_h_strong_threshold;
   double mr_h_threshold;
   double mr_h_extreme_threshold;
   double trend_r2_threshold;
   double chaos_r2_threshold;
};

//+------------------------------------------------------------------+
//| CLASSE PRINCIPAL                                                 |
//+------------------------------------------------------------------+
class CMacroRegimeEngine
{
private:
   int               m_period;
   int               m_min_scale;
   int               m_max_scale;
   ENUM_TIMEFRAMES   m_timeframe;
   
   double            m_last_r2;
   double            m_last_strength;
   double            m_last_hurst;
   double            m_last_slope;
   double            m_last_slope_normalized;
   double            m_last_atr;
   
   SAssetProfile     m_profile;
   
   // Cache
   datetime          m_cache_bar_time;
   bool              m_cache_valid;
   double            m_cache_atr_fast;
   double            m_cache_atr_slow;
   double            m_cache_spread_anomaly;
   double            m_cache_rvol;
   int               m_cache_momentum_state;
   
   // VWAP Cache
   datetime          m_vwap_bar_time;
   double            m_vwap_value;
   
   void              RefreshBarCache();
   int               CalcMomentumStateRaw();
   double            LinearRegression(double &x[], double &y[], int n, double &r2);
   void              CalculateSlope(const double &close[], int shift);
   SAssetProfile     BuildDefaultProfile(string symbol);
   ENUM_REGIME_STATE ClassifyRegime();
   
public:
   void Init(int period, int min_scale, int max_scale, ENUM_TIMEFRAMES timeframe = PERIOD_CURRENT);
   SAssetProfile DetectAssetProfile(string symbol) { return BuildDefaultProfile(symbol); }
    void SetProfile(const SAssetProfile &profile) { m_profile = profile; }
    void SetProfileFromDNA(double hurst_p40, double hurst_p60,
                            double adx_p50, double adx_p75)
    {
       m_profile.trend_h_threshold = hurst_p60;
       m_profile.mr_h_threshold    = hurst_p40;
    }

   // MÓDULO 1: Dados Brutos
   double Get(int shift = 1);
   double GetLastHurst()    { return m_last_hurst; }
   double GetConfidence()   { return m_last_r2; }
   double GetStrength()     { return m_last_strength; }
   double GetSlope()        { return m_last_slope; }
   double GetSlopeNormalized() { return m_last_slope_normalized; }
   double GetDirection();
   int    GetMomentumState();
   double GetDailyVWAP();
   double DistanceVWAP();
   double DistanceVWAP_ATR();
   double CustomATR(string symbol, ENUM_TIMEFRAMES period, int atr_period, int shift = 1);
   double CachedATR(int shift = 1);
   void   GetVWAPBands(double &upper, double &lower, double multiplier);
   double GetSpreadAnomaly(int period = 20);
   double GetRelativeVolume(int period = 20);

   // MÓDULO 2: Validadores
   bool isTrending()       { return (m_last_hurst > m_profile.trend_h_threshold && m_last_r2 >= m_profile.trend_r2_threshold); }
   bool isMeanReverting()  { return (m_last_hurst < m_profile.mr_h_threshold && m_last_r2 >= m_profile.trend_r2_threshold); }
   bool isBullish()        { return isTrending() && GetDirection() > 0; }
   bool isBearish()        { return isTrending() && GetDirection() < 0; }
   bool isBullishAboveVWAP() { return isTrending() && DistanceVWAP() > 0; }
   bool isBearishBelowVWAP() { return isTrending() && DistanceVWAP() < 0; }
   
   bool hasStrongMomentum()  { return (GetMomentumState() == 2); }
   bool possibleReversal()   { return (GetMomentumState() == -2); }
   bool isHighVol();
   bool isLowVol();
   bool IsVolatilityBurst(int fast_period = 14, int slow_period = 50, double multiplier = 0.0, int shift = 1);
   
   int  GetLiquidityState();
   bool isLiquiditySafe()    { return (GetLiquidityState() != -1); }
   
   // MÓDULO 3: Habitats
   bool IsChaosRegime();
   bool IsTrendFollowingRegime(bool return_only_pullbacks = false);
   bool IsBreakoutRegime();
   bool IsMeanReversionRegime();
   
   // NOVO: THROTTLE SCORE (0-100)
   int  GetRegimeScore();
   bool IsOverbought()  { return (DistanceVWAP_ATR() >= 1.5); }
   bool IsOversold()    { return (DistanceVWAP_ATR() <= -1.5); }

// MÓDULO 5: Apresentação
    string GetLabel();
    color  GetRegimeColor();
    string GetMarketSummary();
    string GetTrend();
    string GetVolatility();
    string GetMomentum();
};

//+------------------------------------------------------------------+
//| MÓDULO 0: INICIALIZAÇÃO                                          |
//+------------------------------------------------------------------+
SAssetProfile CMacroRegimeEngine::BuildDefaultProfile(string symbol)
{
   SAssetProfile p;
   p.asset_class = CLASS_FOREX_MAJOR;
   p.class_name = "FOREX MAJOR";
   p.high_vol_mult = 1.2;
   p.burst_vol_mult = 1.25;  // Reduzido de 1.5 para capturar breakouts reais
   p.slope_threshold = 0.010;
   p.trend_h_threshold = 0.53;
   p.trend_h_strong_threshold = 0.60;
   p.mr_h_threshold = 0.47;
   p.mr_h_extreme_threshold = 0.43;
   p.trend_r2_threshold = 0.50; // Reduzido de 0.60
   p.chaos_r2_threshold = 0.40; // Reduzido de 0.50

   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0) {
      p.asset_class = CLASS_METAL; p.class_name = "METAL"; p.burst_vol_mult = 1.3;
   } else if(StringFind(symbol, "BTC") >= 0 || StringFind(symbol, "ETH") >= 0) {
      p.asset_class = CLASS_CRYPTO; p.class_name = "CRYPTO"; p.burst_vol_mult = 1.5; p.high_vol_mult = 1.5;
   } else if(StringFind(symbol, "SP500") >= 0 || StringFind(symbol, "NAS") >= 0) {
      p.asset_class = CLASS_INDEX; p.class_name = "INDEX"; p.burst_vol_mult = 1.35; p.high_vol_mult = 1.3;
   }
   return p;
}

void CMacroRegimeEngine::Init(int period, int min_scale, int max_scale, ENUM_TIMEFRAMES timeframe)
{
   m_period = period;
   m_min_scale = min_scale;
   m_max_scale = max_scale;
   m_timeframe = (timeframe == PERIOD_CURRENT) ? _Period : timeframe;
   
   m_last_r2 = 0.0; m_last_strength = 0.0; m_last_hurst = 0.5;
   m_last_slope = 0.0; m_last_slope_normalized = 0.0; m_last_atr = 0.0;
   
   m_vwap_bar_time = 0; m_vwap_value = 0.0;
   m_cache_bar_time = 0; m_cache_valid = false;
   
   m_profile = BuildDefaultProfile(_Symbol);
}

//+------------------------------------------------------------------+
//| CACHE                                                            |
//+------------------------------------------------------------------+
void CMacroRegimeEngine::RefreshBarCache()
{
   datetime bar = iTime(_Symbol, m_timeframe, 0);
   if(m_cache_valid && bar == m_cache_bar_time) return;
   
   m_cache_atr_fast = CustomATR(_Symbol, m_timeframe, 14, 1);
   m_cache_atr_slow = CustomATR(_Symbol, m_timeframe, 100, 1);
   m_cache_spread_anomaly = GetSpreadAnomaly(20);
   m_cache_rvol = GetRelativeVolume(20);
   m_cache_momentum_state = CalcMomentumStateRaw();
   m_cache_bar_time = bar;
   m_cache_valid = true;
}

//+------------------------------------------------------------------+
//| MÓDULO 1: DADOS BRUTOS                                           |
//+------------------------------------------------------------------+
double CMacroRegimeEngine::GetDirection()
{
   double threshold = m_profile.slope_threshold;
   if(threshold == 0.0) threshold = 0.01;
   if(m_last_slope_normalized > threshold) return 1;
   if(m_last_slope_normalized < -threshold) return -1;
   return 0;
}

int CMacroRegimeEngine::CalcMomentumStateRaw()
{
   double close1 = iClose(_Symbol, m_timeframe, 1);
   double close_ref = iClose(_Symbol, m_timeframe, 11);
   double avgBar = 0.0;
   for(int i = 1; i <= 10; i++) avgBar += (iHigh(_Symbol, m_timeframe, i) - iLow(_Symbol, m_timeframe, i)) / _Point;
   avgBar /= 10.0;
   if(avgBar == 0) return 0;
   
   double speed = (close1 - close_ref) / _Point;
   double speed_ratio = MathAbs(speed) / avgBar;
   
   if(speed_ratio > 1.5) return 2; // Forte
   if(speed_ratio < 0.8) return -1; // Fraco
   
   double upper_band2 = 0.0, lower_band2 = 0.0;
   GetVWAPBands(upper_band2, lower_band2, 2.0);
   if(upper_band2 > 0 && (close1 >= upper_band2 || close1 <= lower_band2)) return -2; // Reversão
   
   return 1; // Moderado
}

int CMacroRegimeEngine::GetMomentumState()
{
   RefreshBarCache();
   return m_cache_momentum_state;
}

double CMacroRegimeEngine::GetDailyVWAP()
{
   datetime current_bar = iTime(_Symbol, m_timeframe, 0);
   if(current_bar == m_vwap_bar_time && m_vwap_value != 0.0) return m_vwap_value;
   
   datetime startOfDay = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   int bars = Bars(_Symbol, m_timeframe, startOfDay, TimeCurrent());
   if(bars <= 1) return 0.0; // Precisa de pelo menos 1 barra fechada
   
   double sum_pv = 0.0;
   long sum_vol = 0;
   
   // CORREÇÃO: Exclui barra 0 (i >= 1). VWAP só com barras fechadas.
   for(int i = bars-1; i >= 1; i--)
   {
      double h = iHigh(_Symbol, m_timeframe, i);
      double l = iLow(_Symbol, m_timeframe, i);
      double c = iClose(_Symbol, m_timeframe, i);
      long vol = iVolume(_Symbol, m_timeframe, i);
      if(h == 0 || vol == 0) continue;
      double typical = (h + l + c) / 3.0;
      sum_pv += typical * vol;
      sum_vol += vol;
   }
   
   m_vwap_value = (sum_vol > 0) ? sum_pv / (double)sum_vol : 0.0;
   m_vwap_bar_time = current_bar;
   return m_vwap_value;
}

double CMacroRegimeEngine::DistanceVWAP()
{
   double vwap = GetDailyVWAP();
   if(vwap == 0.0) return 0.0;
   return (iClose(_Symbol, m_timeframe, 1) - vwap) / _Point;
}

double CMacroRegimeEngine::DistanceVWAP_ATR()
{
   double dist_points = DistanceVWAP() * _Point;
   double atr = CachedATR(1);
   return (atr > 0) ? dist_points / atr : 0.0;
}

void CMacroRegimeEngine::GetVWAPBands(double &upper, double &lower, double multiplier)
{
   double vwap = GetDailyVWAP();
   if(vwap == 0.0) { upper = 0.0; lower = 0.0; return; }
   
   datetime startOfDay = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   int barsSinceOpen = Bars(_Symbol, m_timeframe, startOfDay, TimeCurrent());
   if(barsSinceOpen <= 1) { upper = vwap; lower = vwap; return; }
   
   int sample_size = MathMin(20, barsSinceOpen);
   double sum_sq_diff = 0.0;
   int count = 0;
   
   // CORREÇÃO: Calcula desvio populacional ponderado por volume das últimas 20 barras fechadas
   for(int i = 1; i <= sample_size; i++)
   {
      double h = iHigh(_Symbol, m_timeframe, i);
      double l = iLow(_Symbol, m_timeframe, i);
      double c = iClose(_Symbol, m_timeframe, i);
      long vol = iVolume(_Symbol, m_timeframe, i);
      if(h == 0 || vol == 0) continue;
      double typical = (h + l + c) / 3.0;
      sum_sq_diff += MathPow(typical - vwap, 2) * vol;
      count++;
   }
   
   double std_dev = (count > 0) ? MathSqrt(sum_sq_diff / (double)count) : 0.0;
   upper = vwap + (std_dev * multiplier);
   lower = vwap - (std_dev * multiplier);
}

// ATR Simplificado (SMA-based, não Wilder)
double CMacroRegimeEngine::CustomATR(string symbol, ENUM_TIMEFRAMES period, int atr_period, int shift)
{
   if(atr_period <= 0) return 0.0;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, period, shift, atr_period + 1, rates);
   if(copied <= 0) return 0.0;
   
   double sum_tr = 0.0;
   int valid_bars = 0;
   for(int i = 0; i < atr_period; i++)
   {
      if(i + 1 >= copied) break;
      double tr1 = rates[i].high - rates[i].low;
      double tr2 = MathAbs(rates[i].high - rates[i+1].close);
      double tr3 = MathAbs(rates[i].low - rates[i+1].close);
      sum_tr += MathMax(tr1, MathMax(tr2, tr3));
      valid_bars++;
   }
   return (valid_bars > 0) ? (sum_tr / (double)valid_bars) : 0.0;
}

double CMacroRegimeEngine::CachedATR(int shift)
{
   if(shift == 1) { RefreshBarCache(); return m_cache_atr_fast; }
   return CustomATR(_Symbol, m_timeframe, 14, shift);
}

// CORREÇÃO: Compara spread da barra fechada (rates[0] com ArraySetAsSeries) vs média
double CMacroRegimeEngine::GetSpreadAnomaly(int period)
{
   if(!InpSpreadAnomaly) return 1.0;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, m_timeframe, 1, period + 1, rates) <= 0) return 1.0;
   
   long current_spread = rates[0].spread; // Spread da última barra fechada
   long sum_spread = 0;
   for(int i = 1; i <= period; i++) sum_spread += rates[i].spread; // Média das barras anteriores
   
   double avg_spread = (double)sum_spread / (double)period;
   if(avg_spread == 0) return 1.0;
   return (double)current_spread / avg_spread;
}

double CMacroRegimeEngine::GetRelativeVolume(int period)
{
   if(!InpRelativeVolume) return 1.0;
   long current_vol = iVolume(_Symbol, m_timeframe, 1);
   long vol_array[];
   ArraySetAsSeries(vol_array, true);
   if(CopyTickVolume(_Symbol, m_timeframe, 2, period, vol_array) <= 0) return 1.0;
   
   long sum_vol = 0;
   for(int i = 0; i < period; i++) sum_vol += vol_array[i];
   double avg_vol = (double)sum_vol / (double)period;
   if(avg_vol == 0) return 1.0;
   return (double)current_vol / avg_vol;
}

//+------------------------------------------------------------------+
//| MÓDULO 2: VALIDADORES                                            |
//+------------------------------------------------------------------+
bool CMacroRegimeEngine::isHighVol()
{
   RefreshBarCache();
   return (m_cache_atr_fast > m_cache_atr_slow * m_profile.high_vol_mult);
}

bool CMacroRegimeEngine::isLowVol()
{
   RefreshBarCache();
   return (m_cache_atr_fast < m_cache_atr_slow * 0.8);
}

bool CMacroRegimeEngine::IsVolatilityBurst(int fast_period, int slow_period, double multiplier, int shift)
{
   double mult = (multiplier == 0.0) ? m_profile.burst_vol_mult : multiplier;
   if(fast_period == 14 && slow_period == 100 && shift == 1)
   {
      RefreshBarCache();
      return (m_cache_atr_fast > (m_cache_atr_slow * mult));
   }
   double fast_atr = CustomATR(_Symbol, m_timeframe, fast_period, shift);
   double slow_atr = CustomATR(_Symbol, m_timeframe, slow_period, shift);
   return (fast_atr > (slow_atr * mult));
}

// CORREÇÃO: Liquidez Tóxica agora é Spread Alto + Volume Alto.
int CMacroRegimeEngine::GetLiquidityState()
{
   RefreshBarCache();
   bool toxic_spread = (m_cache_spread_anomaly > InpSpreadAnomalyValue);
   bool dry_market = (m_cache_rvol < InpRelativeVolume);
   
   if(toxic_spread && m_cache_rvol > 1.2) return -1; // Tóxico (alguém comendo o book)
   if(dry_market) return -1;                         // Mercado Seco (sem liquidez)
   if(m_cache_spread_anomaly <= 1.0 && m_cache_rvol >= 1.0) return 1; // Ideal
   return 0; // Neutro
}

// CORREÇÃO: Caos agora requer microestrutura quebrada ou R2 extremamente baixo.
bool CMacroRegimeEngine::IsChaosRegime()
{
   if(GetLiquidityState() == -1) return true;
   if(m_last_r2 < m_profile.chaos_r2_threshold) return true;
   if(IsVolatilityBurst() && GetDirection() == 0) return true; // Pico de vol sem direção
   return false;
}

//+------------------------------------------------------------------+
//| MÓDULO 3: CLASSIFICADORES (HABITATS)                            |
//+------------------------------------------------------------------+
ENUM_REGIME_STATE CMacroRegimeEngine::ClassifyRegime()
{
   if(IsChaosRegime()) return STATE_CHAOS;
   if(IsBreakoutRegime()) return STATE_BREAKOUT;
   if(IsTrendFollowingRegime()) return STATE_TREND;
   if(IsMeanReversionRegime()) return STATE_MEAN_REVERSION;
   return STATE_NEUTRAL;
}

// Permitido operar se há tendência e momentum não está revertendo
bool CMacroRegimeEngine::IsTrendFollowingRegime(bool return_only_pullbacks)
{
   if(!isLiquiditySafe()) return false;
   if(!isTrending()) return false;
   if(GetDirection() == 0) return false;
   
   int mom = GetMomentumState();
   if(mom == -2) return false; // Em reversão forte
   
   if(return_only_pullbacks) return (mom == -1); // Pullback fraco
   return (mom == 1 || mom == 2);
}

// Breakout exige burst, direção e rompimento de mom (não necessariamente forte)
bool CMacroRegimeEngine::IsBreakoutRegime()
{
   if(!isLiquiditySafe()) return false;
   if(!IsVolatilityBurst()) return false;
   if(GetDirection() == 0) return false;
   if(m_last_hurst < m_profile.mr_h_threshold) return false;
   
   int mom = GetMomentumState();
   return (mom == 1 || mom == 2);
}

// CORREÇÃO: Mean Reversion não tem medo de Burst. Se tocou banda, é MR!
bool CMacroRegimeEngine::IsMeanReversionRegime()
{
   if(!isLiquiditySafe()) return false;
   if(m_last_hurst > m_profile.trend_h_threshold) return false; // Se há trend forte, não é MR
   
   int mom = GetMomentumState();
   if(mom == -2) return true; // Sinal forte de reversão nas bandas
   if(mom == -1 && m_last_hurst < m_profile.mr_h_threshold) return true;
   return false;
}

//+------------------------------------------------------------------+
//| THROTTLE SCORE (0-100)                                           |
//+------------------------------------------------------------------+
int CMacroRegimeEngine::GetRegimeScore()
{
   int score = 0;
   // Base de Confiança (0 a 40 points)
   if(m_last_r2 > 0.80) score += 40;
   else if(m_last_r2 > 0.60) score += 30;
   else if(m_last_r2 > 0.50) score += 20;
   else if(m_last_r2 > 0.40) score += 10;

   // Força do Regime (0 a 30 points)
   double strength = GetStrength();
   score += (int)(strength * 30);

   // Liquidez (0 a 20 points)
   int liq = GetLiquidityState();
   if(liq == 1) score += 20;
   else if(liq == 0) score += 10;

   // Aderência da Direção/Momentum (0 a 10 points)
   int mom = GetMomentumState();
   if(MathAbs(mom) == 2) score += 10;
   else if(MathAbs(mom) == 1) score += 5;

   return MathMin(score, 100);
}

//+------------------------------------------------------------------+
//| MÓDULO 4: MATEMÁTICA PURA                                       |
//+------------------------------------------------------------------+
double CMacroRegimeEngine::LinearRegression(double &x[], double &y[], int n, double &r2)
{
   double sx=0, sy=0, sxy=0, sxx=0, syy=0;
   for(int i=0; i<n; i++) { sx+=x[i]; sy+=y[i]; sxy+=x[i]*y[i]; sxx+=x[i]*x[i]; syy+=y[i]*y[i]; }
   double denom = (n*sxx - sx*sx);
   if(denom == 0) { r2 = 0.0; return 0.5; }
   double slope = (n*sxy - sx*sy) / denom;
   double corr_num = (n*sxy - sx*sy);
   double corr_den = MathSqrt((n*sxx - sx*sx) * (n*syy - sy*sy));
   if(corr_den > 0) { double corr = corr_num / corr_den; r2 = corr * corr; } else { r2 = 0.0; }
   return slope;
}

void CMacroRegimeEngine::CalculateSlope(const double &close[], int shift)
{
   int n = m_period;
   if(ArraySize(close) < n) { m_last_slope = 0; m_last_slope_normalized = 0; return; }
   
   double sum_x=0, sum_y=0, sum_xy=0, sum_x2=0;
   for(int i=0; i<n; i++)
   {
      if(close[i] <= 0) { m_last_slope = 0; m_last_slope_normalized = 0; return; }
      double x = (double)i;
      double y = MathLog(close[i]);
      sum_x+=x; sum_y+=y; sum_xy+=x*y; sum_x2+=x*x;
   }
   double denom = n * sum_x2 - sum_x * sum_x;
   if(MathAbs(denom) < 1e-12) { m_last_slope = 0; m_last_slope_normalized = 0; return; }
   
   m_last_slope = (n * sum_xy - sum_x * sum_y) / denom;
   m_last_atr = CustomATR(_Symbol, m_timeframe, 14, shift);
   m_last_slope_normalized = (m_last_atr > 0) ? m_last_slope / m_last_atr : 0;
}

double CMacroRegimeEngine::Get(int shift)
{
   if(!InpMacroRegime) return 0.0;
   
   double price[];
   if(CopyClose(_Symbol, m_timeframe, shift, m_period, price) != m_period) return 0.5;
   
   double ret[]; ArrayResize(ret, m_period-1);
   double mean = 0.0;
   for(int i=0; i<m_period-1; i++) { 
      if(price[i] <= 0 || price[i+1] <= 0) return 0.5; 
      ret[i] = MathLog(price[i+1] / price[i]); 
      mean += ret[i]; 
   }
   mean /= (double)(m_period-1);
   
   double y[]; ArrayResize(y, m_period-1);
   double acc = 0.0;
   for(int i=0; i<m_period-1; i++) { acc += (ret[i] - mean); y[i] = acc; }
   
   int scales[] = {4,6,8,10,14,20,28,40,56,80};
   double log_s[], log_f[]; ArrayResize(log_s, ArraySize(scales)); ArrayResize(log_f, ArraySize(scales));
   int count = 0;
   
   for(int k=0; k<ArraySize(scales); k++)
   {
      int s = scales[k]; if(s < m_min_scale || s > m_max_scale) continue;
      int n_segments = (m_period-1) / s; if(n_segments < 2) continue;
      
      double fluct = 0.0; int valid_segments = 0;
      for(int v=0; v<n_segments; v++)
      {
         int start = v * s; double sx=0, sy=0, sxy=0, sxx=0;
         for(int i=0; i<s; i++) { double xi=(double)i; double yi=y[start+i]; sx+=xi; sy+=yi; sxy+=xi*yi; sxx+=xi*xi; }
         double denom = (s*sxx - sx*sx); if(denom == 0) continue;
         double a = (s*sxy - sx*sy) / denom; double b = (sy - a*sx) / s; 
         double rms = 0.0;
         for(int i=0; i<s; i++) { double diff = y[start+i] - (a*i + b); rms += diff*diff; }
         rms = MathSqrt(rms / (double)s);
         if(rms > 0) { fluct += rms; valid_segments++; }
      }
      if(valid_segments > 0) { log_s[count] = MathLog((double)s); log_f[count] = MathLog(fluct / (double)valid_segments); count++; }
   }
   
   if(count < 3) return 0.5;
   double r2 = 0.0;
   double H = LinearRegression(log_s, log_f, count, r2);
   if(H < 0.0) H = 0.0; if(H > 1.0) H = 1.0;
   
   m_last_hurst = H; m_last_r2 = r2; m_last_strength = MathAbs(H - 0.5) * 2.0;
   CalculateSlope(price, shift);
   return H;
}

//+------------------------------------------------------------------+
//| MÓDULO 5: APRESENTAÇÃO                                           |
//+------------------------------------------------------------------+
string CMacroRegimeEngine::GetLabel()
{
   ENUM_REGIME_STATE state = ClassifyRegime();
   string dir = (GetDirection() > 0) ? "UP" : (GetDirection() < 0 ? "DOWN" : "FLAT");
   
   switch(state)
   {
      case STATE_CHAOS:           return "CHAOS (Kill Switch)";
      case STATE_MEAN_REVERSION:  return "MEAN_REVERSION (" + dir + ")";
      case STATE_BREAKOUT:        return "BREAKOUT (" + dir + ")";
      case STATE_TREND:            return "TREND (" + dir + ")";
      default:                    return "NEUTRAL";
   }
}

color CMacroRegimeEngine::GetRegimeColor()
{
   if(m_last_r2 < m_profile.chaos_r2_threshold) return clrGray;
   
   ENUM_REGIME_STATE state = ClassifyRegime();
   switch(state)
   {
      case STATE_CHAOS:           return clrGray;
      case STATE_MEAN_REVERSION:  return clrYellow;
      case STATE_BREAKOUT:        return clrOrange;
      case STATE_TREND:            return (GetDirection() > 0) ? clrLime : clrRed;
      default:                    return clrSilver;
   }
}

string CMacroRegimeEngine::GetMarketSummary()
{
   int score = GetRegimeScore();
   return GetLabel() + " | Score: " + IntegerToString(score) + "/100";
}

string CMacroRegimeEngine::GetTrend()
{
   if(IsTrendFollowingRegime(false)) return (GetDirection() > 0) ? "BULL" : "BEAR";
   if(IsMeanReversionRegime()) return "MEAN_REV";
   if(IsBreakoutRegime()) return "BREAKOUT";
   if(IsChaosRegime()) return "CHAOS";
   return "FLAT";
}

string CMacroRegimeEngine::GetVolatility()
{
   if(IsVolatilityBurst()) return "HIGH";
   if(isHighVol()) return "ELEVATED";
   if(isLowVol()) return "LOW";
   return "NORMAL";
}

string CMacroRegimeEngine::GetMomentum()
{
   int mom = GetMomentumState();
   if(mom == 2) return "STRONG_BULLISH";
   if(mom == 1) return "WEAK_BULLISH";
   if(mom == -1) return "WEAK_BEARISH";
   if(mom == -2) return "STRONG_BEARISH";
   return "NEUTRAL";
}