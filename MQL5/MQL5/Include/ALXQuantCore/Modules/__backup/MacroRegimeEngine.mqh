//+------------------------------------------------------------------+
//|                            MacroRegimeEngine_v3_refactored.mqh    |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//|                                     https://www.mql5.com          |
//| v7.2.0 - REFATORADO                                               |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      "https://www.mql5.com"
#property version "7.20"

/*
========================================================================
MACRO REGIME ENGINE v3.00 — ALXQuantCore Architecture
========================================================================

DOCUMENTAÇÃO OFICIAL PARA PUBLICAÇÃO / DESENVOLVIMENTO

PROPÓSITO:
Módulo central de classificação de microestrutura de mercado. Determina 
QUAIS estratégias podem operar, QUAL direção é segura, e QUANTO capital 
arriscar. O Regime não é um portão liga/desliga, é um acelerador (Throttle).

CONCEITOS FUNDAMENTAIS (MÓDULOS LÓGICOS):
------------------------------------------------------------------------
1. TREND (Tendência): 
   - O que é: Persistência de movimento contínuo.
   - Como medimos: Hurst Exponent (DFA) para PERSISTÊNCIA + Regressão 
     Linear (Slope) para DIREÇÃO.
   - Fórmula: H > 0.55 + Slope Direcional = Trend Forte.

2. MOMENTUM (Momento/Impulso): 
   - O que é: Velocidade e aceleração do preço atual vs período passado.
   - Como medimos: Razão de velocidade (Speed Ratio) vs tamanho médio 
     das barras + distância das Bandas de VWAP (2x Desvio Padrão).
   - Fórmula: Velocidade > 1.5x Média = Forte. Preço fora das Bandas = Reversão.

3. VOLATILITY (Volatilidade): 
   - O que é: Taxa de expansão ou contração do range de preço.
   - Como medimos: Comparação de ATR Rápido (14) vs ATR Lento (100).
   - Fórmula: ATR_Fast > ATR_Slow * Mult = Burst (Explosão).

4. LIQUIDITY & SPREAD (Liquidez Microestrutural): 
   - O que é: Custo de transação e profundidade do livro de ofertas.
   - Como medimos: Anomalia de Spread (Spread Atual / Média) + Volume 
     Relativo (Volume Atual / Média).
   - Fórmula: Spread > 2x Média OU Vol < 0.5x = Liquidez Tóxica.

5. VWAP DISTANCE (Distância do VWAP - NOVO v3.0): 
   - O que é: Quão longe o preço justo intraday está do preço atual.
   - Como medimos: Distância em pontos ou normalizada pelo ATR.
   - Uso: Filtro de sobrecompra/sobrevenda institucional.

========================================================================
FLUXO DE DECISÃO (CONFLUÊNCIA)
========================================================================
                 +---------------------+
                 ¦  Calcular Get(1)    ¦
                 ¦  H = 0.62, R²=0.85  ¦
                 +---------------------+
                           ¦
                 +---------?-----------+
                 ¦  R² >= 0.70?  SIM   ¦
                 +---------------------+
                           ¦
                 +---------?-----------+
                 ¦  H > 0.55?    SIM   ¦ ? PERSISTENTE
                 +---------------------+
                           ¦
                 +---------?-----------+
                 ¦  GetDirection()?    ¦
                 ¦  Slope norm = -0.15 ¦
                 ¦  Resultado: -1 (?)  ¦
                 +---------------------+
                           ¦
                 +---------?-----------+
                 ¦  H>0.55 + Dir=-1    ¦
                 ¦  = BEARISH TREND ?? ¦ ?
                 +---------------------+
========================================================================
*/


/*
    v7.20 - 2026-08-11 - Refactor de auditoria:
      1) Cache por barra (ATR14/ATR100, spread anomaly, rvol, momentum state)
         para eliminar recomputação redundante em chamadas compostas
         (GetMarketSummary + IsTrendFollowingRegime no mesmo tick, etc).
      2) Bug corrigido: Get(shift) agora propaga o MESMO shift para o
         cálculo de slope/direção (antes CalculateSlope() ignorava o
         parâmetro shift e sempre usava 1, dessincronizando H vs Direction
         quando Get() era chamado com shift != 1).
      3) CopyClose duplicado eliminado: Get() e CalculateSlope() agora
         reaproveitam o mesmo array de preços.
      4) Thresholds de regime (H, R²) centralizados em SAssetProfile em
         vez de espalhados/duplicados entre isTrending(), GetTrend(),
         GetRegime() e GetLabel() com valores divergentes.
      5) GetLabel() agora respeita confiança (R²), antes ignorava.
      6) Init() e DetectAssetProfile() não duplicam mais o profile default.
      7) CachedATR() agora usa cache real (antes era apenas um alias sem
         cache, nome enganoso).
      NOTA DE COMPORTAMENTO PRESERVADO INTENCIONALMENTE:
      isHighVol()/isLowVol()/GetVolatility() usam ATR(14) vs ATR(100).
      IsVolatilityBurst() usa por padrão ATR(14) vs ATR(50) (parâmetros
      próprios). Essa divergência já existia no original — não foi
      "corrigida" aqui porque pode ser intencional (burst de curto prazo
      vs regime de volatilidade de médio prazo). Ver nota na auditoria.
*/


//+------------------------------------------------------------------+
//| #Input                                                           |
//+------------------------------------------------------------------+
input group             "▸ Market Regime Engine"
input bool              InpMacroRegime                         = true;                 // Macro Regime filter
input int               InpDFAPeriod                           = 200;                  // DFA period
input int               InpDFA_min_scale                       = 4;                    // DFA min scale
input int               InpDFA_max_scale                       = 40;                   // DFA max scale
//+------------------------------------------------------------------+
input double            InpLastHurstMinValue                   = 0.50;                  // Last min H
input double            InpLastHurstMaxValue                   = 0.60;                  // Last max H
//---
input bool              InpBlock_afternoon                     = false;                // Hour >= 15 && Hour < 19
input bool              InpBlock_opening                       = false;                // Day week==WEDNESDAY && Hour==10 && (dt.hour == 9 && dt.min < 15)
input bool              InpNewBar                              = false;                // Wait new bar
//---
input bool              InpSpreadAnomaly                       = false;                // Spread Anomaly filter
input double            InpSpreadAnomalyValue                  = 1.5;                  // Spread Anomaly value
//---   
input bool              InpRelativeVolume                      = false;                // Relative Volume filter            
input double            InpRelativeVolumeValue                 = 0.5;                  // Relative Volume value
//+------------------------------------------------------------------+



//+------------------------------------------------------------------+
//| ASSET PROFILE (Configuração por Ativo)                            |
//+------------------------------------------------------------------+
enum ENUM_ASSET_CLASS
{
   CLASS_METAL,
   CLASS_CRYPTO,
   CLASS_INDEX,
   CLASS_FOREX_MAJOR,
   CLASS_FOREX_CARRY
};

struct SAssetProfile
{
   ENUM_ASSET_CLASS asset_class;
   string           class_name;
   double           high_vol_mult;
   double           burst_vol_mult;
   double           slope_threshold;
   int              risk_on_dir;
   int              risk_off_dir;

   // --- NOVO: thresholds de regime centralizados ---
   // Antes espalhados com valores DIVERGENTES entre isTrending() (0.52/0.60),
   // GetTrend()/GetRegime() (0.55/0.70) e GetLabel() (sem checar R² nenhum).
   double           trend_h_threshold;        // H mínimo p/ tendência (default 0.52)
   double           trend_h_strong_threshold; // H mínimo p/ tendência FORTE (default 0.60)
   double           mr_h_threshold;           // H máximo p/ mean reversion (default 0.48)
   double           mr_h_extreme_threshold;   // H máximo p/ MR extrema (default 0.45)
   double           trend_r2_threshold;       // R² mínimo de confiança (default 0.60)
   double           chaos_r2_threshold;       // R² abaixo do qual é ruído puro (default 0.50)
};

//+------------------------------------------------------------------+
//| CLASSE PRINCIPAL                                                  |
//+------------------------------------------------------------------+
class CMacroRegimeEngine
{
private:
   // --- Variáveis de Estado Interno ---
   int               m_period;
   int               m_min_scale;
   int               m_max_scale;
   double            m_last_r2;
   double            m_last_strength;
   double            m_last_hurst;
   double            m_last_slope;
   double            m_last_slope_normalized;
   double            m_last_atr;
   SAssetProfile     m_profile;

   // --- Cache VWAP (só recalcula por barra) ---
   datetime          m_vwap_bar_time;
   double            m_vwap_value;

   // --- NOVO: Cache geral por barra (ATR, spread, rvol, momentum) ---
   // Elimina recomputação redundante quando várias funções do Módulo 2/3/5
   // são chamadas no mesmo tick (ex: GetMarketSummary() + IsTrendFollowingRegime()
   // antes recalculavam ATR14/ATR100/spread/rvol/momentum do zero cada uma).
   datetime          m_cache_bar_time;
   bool              m_cache_valid;
   double            m_cache_atr_fast;   // ATR(14)
   double            m_cache_atr_slow;   // ATR(100)
   double            m_cache_spread_anomaly;
   double            m_cache_rvol;
   int               m_cache_momentum_state;

   void              RefreshBarCache();
   int               CalcMomentumStateRaw();

   // --- MÓDULO 4: MATEMÁTICA PURA (Privado) ---
   double            LinearRegression(double &x[], double &y[], int n, double &r2);
   void              CalculateSlope(const double &close[], int shift); // agora recebe array + shift (sem recopiar, sem dessincronizar)

   SAssetProfile     BuildDefaultProfile(string symbol); // NOVO: fonte única de defaults (usada por Init() e DetectAssetProfile())

public:
   // =================================================================
   // MÓDULO 0: INICIALIZAÇÃO E CONFIGURAÇÃO
   // =================================================================
   void              Init(int period, int min_scale, int max_scale);
   void              SetProfile(const SAssetProfile &profile) { m_profile = profile; }
   SAssetProfile     DetectAssetProfile(string symbol);

   // =================================================================
   // MÓDULO 1: DADOS BRUTOS (GETS DIRETOS)
   // Retornam números crus. Sem julgamento de mercado.
   // =================================================================
   double            Get(int shift = 1);             // Calcula o DFA (Hurst, R2)
   double            GetLastHurst();                 // Último Hurst calculado
   double            GetConfidence();                // R² da regressão do Hurst
   double            GetStrength();                  // |H - 0.5| * 2
   double            GetSlope();                     // Inclinação bruta (Log Prices)
   double            GetSlopeNormalized();           // Inclinação / ATR
   double            GetDirection();                 // +1 (Up), -1 (Down), 0 (Flat)
   int               GetMomentumState();             // 2 (Forte), 1 (Medio), -1 (Fraco), -2 (Reversão)
   double            GetDailyVWAP();                 // VWAP intraday acumulado
   double            DistanceVWAP();                 // Distância em PONTOS do VWAP
   double            DistanceVWAP_ATR();              // Distância normalizada pelo ATR
   double            CustomATR(string symbol, ENUM_TIMEFRAMES period, int atr_period, int shift = 1);
   double            CachedATR(int shift = 1);        // AGORA usa cache real quando shift==1 (caso comum)
   void              GetVWAPBands(double &upper, double &lower, double multiplier);
   double            GetSpreadAnomaly(int period = 20);
   double            GetRelativeVolume(int period = 20);

   // =================================================================
   // MÓDULO 2: VALIDADORES DE ESTADO (IS / HAS)
   // Transformam dados brutos em booleanos lógicos de ambiente.
   // =================================================================

   // --- 2.1 Trend ---
   // Usa m_profile.trend_h_threshold / trend_r2_threshold (antes hardcoded 0.52/0.60)
   bool              isTrending()       { return (m_last_hurst > m_profile.trend_h_threshold && m_last_r2 >= m_profile.trend_r2_threshold); }
   bool              isMeanReverting()  { return (m_last_hurst < m_profile.mr_h_threshold    && m_last_r2 >= m_profile.trend_r2_threshold); }
   // NOTA DE SEMÂNTICA: isBullish/isBearish respondem "o preço está do lado
   // certo do VWAP intraday DADO que há tendência" — é um filtro de VWAP,
   // não o mesmo conceito de direção usado em GetTrend()/GetLabel() (que usam
   // o slope da regressão). Os dois podem discordar (ex: slope positivo mas
   // preço abaixo do VWAP do dia). Use isTrendBullish()/isTrendBearish() abaixo
   // se quiser o critério baseado em slope explicitamente.
   bool              isBullish()        { return isTrending() && priceAboveVWAP();   }
   bool              isBearish()        { return isTrending() && !priceAboveVWAP();  }
   bool              isTrendBullish()   { return isTrending() && GetDirection() > 0; } // NOVO: baseado em slope
   bool              isTrendBearish()   { return isTrending() && GetDirection() < 0; } // NOVO: baseado em slope
   bool              priceAboveVWAP();

   // --- 2.2 Momentum ---
   bool              hasStrongMomentum()   { return (GetMomentumState() == 2); }
   bool              possibleReversal()    { return (GetMomentumState() == -2); }

   // --- 2.3 Volatility ---
   bool              isHighVol();
   bool              isLowVol();
   bool              IsVolatilityBurst(int fast_period = 14, int slow_period = 50, double multiplier = 0.0, int shift = 1);

   // --- 2.4 Liquidity & Spread ---
   int               GetLiquidityState(); // -1 Tóxico, 0 Neutro, 1 Ideal
   bool              isLiquiditySafe();

   // --- 2.5 Master Gate ---
   bool              IsChaosRegime(); // Aciona o "Kill Switch" institucional

   // =================================================================
   // MÓDULO 3: CLASSIFICADORES DE ESTRATÉGIA (HABITATS)
   // =================================================================
   bool              IsTrendFollowingRegime(bool return_only_pullbacks = false);
   bool              IsBreakoutRegime();
   bool              IsMeanReversionRegime();

   // =================================================================
   // MÓDULO 5: APRESENTAÇÃO E LABELS
   // =================================================================
   int               GetRegime(double H, double confidence = 0.0);
   string            GetLabel(double H);
   color             GetRegimeColor();
   string            GetMarketSummary();
   string            GetTrend();
   string            GetVolatility();
   string            GetMomentum();
};


//+------------------------------------------------------------------+
//| MÓDULO 0: INICIALIZAÇÃO                                          |
//+------------------------------------------------------------------+
SAssetProfile CMacroRegimeEngine::BuildDefaultProfile(string symbol)
{
   // Fonte ÚNICA de defaults. Antes Init() e DetectAssetProfile()
   // mantinham cópias manuais separadas do mesmo bloco de valores.
   SAssetProfile p;
   p.asset_class = CLASS_FOREX_MAJOR;
   p.class_name  = "FOREX MAJOR";
   p.high_vol_mult   = 1.2;
   p.burst_vol_mult  = 1.5;
   p.slope_threshold = 0.010;
   p.risk_on_dir  = 1;
   p.risk_off_dir = -1;

   p.trend_h_threshold        = 0.52;
   p.trend_h_strong_threshold = 0.60;
   p.mr_h_threshold           = 0.48;
   p.mr_h_extreme_threshold   = 0.45;
   p.trend_r2_threshold       = 0.60;
   p.chaos_r2_threshold       = 0.50;

   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0) {
      p.asset_class = CLASS_METAL; p.class_name = "METAL (Gold)"; p.high_vol_mult = 1.2; p.burst_vol_mult = 1.5; p.slope_threshold = 0.010; p.risk_on_dir = 1; p.risk_off_dir = -1;
   } else if(StringFind(symbol, "BTC") >= 0 || StringFind(symbol, "ETH") >= 0) {
      p.asset_class = CLASS_CRYPTO; p.class_name = "CRYPTO"; p.high_vol_mult = 1.5; p.burst_vol_mult = 2.0; p.slope_threshold = 0.008; p.risk_on_dir = 1; p.risk_off_dir = -1;
   } else if(StringFind(symbol, "SP500") >= 0 || StringFind(symbol, "US500") >= 0 || StringFind(symbol, "NAS") >= 0) {
      p.asset_class = CLASS_INDEX; p.class_name = "INDEX"; p.high_vol_mult = 1.3; p.burst_vol_mult = 1.8; p.slope_threshold = 0.010; p.risk_on_dir = 1; p.risk_off_dir = -1;
   } else if(StringFind(symbol, "AUDJPY") >= 0 || StringFind(symbol, "NZDJPY") >= 0) {
      p.asset_class = CLASS_FOREX_CARRY; p.class_name = "CARRY TRADE"; p.high_vol_mult = 1.2; p.burst_vol_mult = 1.5; p.slope_threshold = 0.012; p.risk_on_dir = 1; p.risk_off_dir = -1;
   } else if(StringFind(symbol, "USDCAD") >= 0) {
      p.asset_class = CLASS_FOREX_MAJOR; p.class_name = "FOREX COMMODITY"; p.high_vol_mult = 1.2; p.burst_vol_mult = 1.5; p.slope_threshold = 0.010; p.risk_on_dir = -1; p.risk_off_dir = 1;
   } else if(StringFind(symbol, "EURUSD") >= 0 || StringFind(symbol, "GBPUSD") >= 0) {
      p.asset_class = CLASS_FOREX_MAJOR; p.class_name = "FOREX MAJOR (EU/UK)"; p.high_vol_mult = 1.2; p.burst_vol_mult = 1.5; p.slope_threshold = 0.010; p.risk_on_dir = 1; p.risk_off_dir = -1;
   }

   if(Period() <= PERIOD_M15)     { p.high_vol_mult *= 0.9; p.burst_vol_mult *= 0.9; }
   else if(Period() >= PERIOD_H4) { p.high_vol_mult *= 1.1; p.burst_vol_mult *= 1.1; }

   return p;
}

void CMacroRegimeEngine::Init(int period, int min_scale, int max_scale)
{
   if(!InpMacroRegime)
      return;

   m_period        = period;
   m_min_scale     = min_scale;
   m_max_scale     = max_scale;
   m_last_r2       = 0.0;
   m_last_strength = 0.0;
   m_last_hurst    = 0.5;
   m_last_slope    = 0.0;
   m_last_slope_normalized = 0.0;
   m_last_atr      = 0.0;
   m_vwap_bar_time = 0;
   m_vwap_value    = 0.0;

   m_cache_bar_time = 0;
   m_cache_valid    = false;
   m_cache_atr_fast = 0.0;
   m_cache_atr_slow = 0.0;
   m_cache_spread_anomaly = 1.0;
   m_cache_rvol           = 1.0;
   m_cache_momentum_state = 0;

   // Antes: bloco de defaults duplicado manualmente aqui. Agora reaproveita
   // o mesmo caminho de DetectAssetProfile(), então nunca diverge.
   m_profile = BuildDefaultProfile(_Symbol);
   
   Print(__FUNCTION__ + " - The initial design module has been successfully initialized!"); 
}

SAssetProfile CMacroRegimeEngine::DetectAssetProfile(string symbol)
{
   return BuildDefaultProfile(symbol);
}

//+------------------------------------------------------------------+
//| NOVO: CACHE POR BARRA                                             |
//| Recalcula ATR14/ATR100/spread anomaly/rvol/momentum SÓ quando a   |
//| barra atual muda. Antes cada função (isHighVol, isLowVol,         |
//| IsVolatilityBurst-defaults, GetLiquidityState, GetMomentumState,  |
//| GetVolatility) recalculava tudo do zero, mesmo dentro do mesmo    |
//| tick.                                                             |
//+------------------------------------------------------------------+
void CMacroRegimeEngine::RefreshBarCache()
{
   datetime bar = iTime(_Symbol, _Period, 0);
   if(m_cache_valid && bar == m_cache_bar_time) return; // já calculado nesta barra

   m_cache_atr_fast      = CustomATR(_Symbol, _Period, 14, 1);
   m_cache_atr_slow      = CustomATR(_Symbol, _Period, 100, 1);
   m_cache_spread_anomaly = GetSpreadAnomaly(20);
   m_cache_rvol           = GetRelativeVolume(20);
   m_cache_momentum_state = CalcMomentumStateRaw();

   m_cache_bar_time = bar;
   m_cache_valid    = true;
}

//+------------------------------------------------------------------+
//| MÓDULO 1: DADOS BRUTOS (GETS)                                    |
//+------------------------------------------------------------------+
double CMacroRegimeEngine::GetLastHurst()       { return m_last_hurst; }
double CMacroRegimeEngine::GetConfidence()      { return m_last_r2; }
double CMacroRegimeEngine::GetStrength()        { return m_last_strength; }
double CMacroRegimeEngine::GetSlope()           { return m_last_slope; }
double CMacroRegimeEngine::GetSlopeNormalized() { return m_last_slope_normalized; }

double CMacroRegimeEngine::GetDirection()
{
   double threshold = m_profile.slope_threshold;
   if(threshold == 0.0) threshold = 0.01;
   if(m_last_slope_normalized > threshold)  return 1;  // Direção Para Cima
   if(m_last_slope_normalized < -threshold) return -1; // Direção Para Baixo
   return 0; // Neutro / Lateral
}

int CMacroRegimeEngine::CalcMomentumStateRaw()
{
   double close1  = iClose(_Symbol, _Period, 1);
   double close10 = iClose(_Symbol, _Period, 11);
   double avgBar  = 0.0;
   for(int i = 1; i <= 10; i++) avgBar += (iHigh(_Symbol, _Period, i) - iLow(_Symbol, _Period, i)) / _Point;
   avgBar /= 10.0;
   if(avgBar == 0) return 0;

   double speed = (close1 - close10) / _Point;
   double speed_ratio = MathAbs(speed) / avgBar;

   if(speed_ratio > 1.5) return 2;  // Momentum Forte

   double upper_band2 = 0.0, lower_band2 = 0.0;
   GetVWAPBands(upper_band2, lower_band2, 2.0);
   if(upper_band2 > 0 && lower_band2 > 0)
   {
      if(close1 >= upper_band2 || close1 <= lower_band2) return -2; // Possível Reversão
   }

   if(speed_ratio < 0.8) return -1; // Momentum Fraco
   return 1; // Momentum Moderado
}

int CMacroRegimeEngine::GetMomentumState()
{
   RefreshBarCache();
   return m_cache_momentum_state;
}

double CMacroRegimeEngine::GetDailyVWAP()
{
   datetime current_bar = iTime(_Symbol, _Period, 0);
   if(current_bar == m_vwap_bar_time && m_vwap_value != 0.0)
      return m_vwap_value;

   datetime startOfDay = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   int bars = Bars(_Symbol, _Period, startOfDay, TimeCurrent());
   if(bars <= 0) return 0.0;
   double sum_pv = 0.0;
   long sum_vol = 0;
   for(int i = bars-1; i >= 0; i--)
   {
      double h = iHigh(_Symbol, _Period, i);
      double l = iLow(_Symbol, _Period, i);
      double c = iClose(_Symbol, _Period, i);
      long vol = iVolume(_Symbol, _Period, i);
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
   return (iClose(_Symbol, _Period, 1) - vwap) / _Point;
}

double CMacroRegimeEngine::DistanceVWAP_ATR()
{
   double dist_points = DistanceVWAP() * _Point;
   double atr = m_last_atr > 0 ? m_last_atr : CachedATR(1);
   return (atr > 0) ? dist_points / atr : 0.0;
}

void CMacroRegimeEngine::GetVWAPBands(double &upper, double &lower, double multiplier)
{
   double vwap = GetDailyVWAP();
   if(vwap == 0.0) { upper = 0.0; lower = 0.0; return; }
   datetime startOfDay = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   int barsSinceOpen = Bars(_Symbol, _Period, startOfDay, TimeCurrent());
   if(barsSinceOpen <= 0) { upper = vwap; lower = vwap; return; }
   int sample_size = MathMin(20, barsSinceOpen);
   double sum_sq_diff = 0.0;
   int count = 0;
   for(int i = 1; i <= sample_size; i++)
   {
      double h = iHigh(_Symbol, _Period, i);
      double l = iLow(_Symbol, _Period, i);
      double c = iClose(_Symbol, _Period, i);
      if(h == 0) continue;
      double typical = (h + l + c) / 3.0;
      sum_sq_diff += MathPow(typical - vwap, 2);
      count++;
   }
   double std_dev = (count > 1) ? MathSqrt(sum_sq_diff / (count - 1)) : 0.0;
   upper = vwap + (std_dev * multiplier);
   lower = vwap - (std_dev * multiplier);
}

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
      double high = rates[i].high;
      double low = rates[i].low;
      double close_prev = rates[i+1].close;
      double tr1 = high - low;
      double tr2 = MathAbs(high - close_prev);
      double tr3 = MathAbs(low - close_prev);
      sum_tr += MathMax(tr1, MathMax(tr2, tr3));
      valid_bars++;
   }
   return (valid_bars > 0) ? (sum_tr / (double)valid_bars) : 0.0;
}

double CMacroRegimeEngine::CachedATR(int shift)
{
   // Antes: alias direto pra CustomATR, SEM cache nenhum (nome enganoso).
   // Agora: usa o cache por barra quando shift==1 (caso de uso comum,
   // "ATR do último candle fechado"). Para outros shifts, cai no cálculo
   // direto, já que o cache só guarda o estado da barra atual.
   if(shift == 1)
   {
      RefreshBarCache();
      return m_cache_atr_fast;
   }
   return CustomATR(_Symbol, _Period, 14, shift);
}

double CMacroRegimeEngine::GetSpreadAnomaly(int period)
{
   long current_spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, period, rates) <= 0) return 1.0;
   long sum_spread = 0;
   for(int i = 0; i < period; i++) sum_spread += rates[i].spread;
   double avg_spread = (double)sum_spread / (double)period;
   if(avg_spread == 0) return 1.0;
   return (double)current_spread / avg_spread;
}

double CMacroRegimeEngine::GetRelativeVolume(int period)
{
   long current_vol = iVolume(_Symbol, _Period, 1);
   long vol_array[];
   ArraySetAsSeries(vol_array, true);
   if(CopyTickVolume(_Symbol, _Period, 2, period, vol_array) <= 0) return 1.0;
   long sum_vol = 0;
   for(int i = 0; i < period; i++) sum_vol += vol_array[i];
   double avg_vol = (double)sum_vol / (double)period;
   if(avg_vol == 0) return 1.0;
   return (double)current_vol / avg_vol;
}

//+------------------------------------------------------------------+
//| MÓDULO 2: VALIDADORES DE ESTADO                                  |
//+------------------------------------------------------------------+
bool CMacroRegimeEngine::priceAboveVWAP() { return (DistanceVWAP() > 0); }

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
   double mult = multiplier;
   if(mult == 0.0) mult = m_profile.burst_vol_mult;

   // NOTA: períodos default (14/50) divergem do par usado no cache (14/100),
   // que é o mesmo usado por isHighVol()/isLowVol(). Comportamento original
   // preservado de propósito — ver nota no cabeçalho do arquivo.
   if(fast_period == 14 && slow_period == 100 && shift == 1)
   {
      RefreshBarCache();
      return (m_cache_atr_fast > (m_cache_atr_slow * mult));
   }

   double fast_atr = CustomATR(_Symbol, _Period, fast_period, shift);
   double slow_atr = CustomATR(_Symbol, _Period, slow_period, shift);
   return (fast_atr > (slow_atr * mult));
}

int CMacroRegimeEngine::GetLiquidityState()
{
   RefreshBarCache();
   if(m_cache_spread_anomaly > 2.0 || m_cache_rvol < 0.5) return -1; // Tóxico
   if(m_cache_spread_anomaly <= 1.0 && m_cache_rvol > 1.5) return 1;  // Ideal
   return 0; // Neutro
}

bool CMacroRegimeEngine::isLiquiditySafe() { return (GetLiquidityState() != -1); }

bool CMacroRegimeEngine::IsChaosRegime()
{
   if(m_last_r2 < m_profile.chaos_r2_threshold) return true; // Ruído estatístico absoluto
   if(m_last_hurst > m_profile.mr_h_threshold && m_last_hurst < m_profile.trend_h_threshold && GetDirection() == 0) return true; // Random Walk puro
   if(!isLiquiditySafe()) return true; // Microestrutura quebrada
   return false;
}

//+------------------------------------------------------------------+
//| MÓDULO 3: CLASSIFICADORES DE HABITAT (ESTRATÉGIAS)               |
//+------------------------------------------------------------------+
bool CMacroRegimeEngine::IsTrendFollowingRegime(bool return_only_pullbacks)
{
   if(!isLiquiditySafe()) return false;
   if(!isTrending())      return false;
   if(GetDirection() == 0) return false;
   if(GetMomentumState() == -2) return false; // Reversão anula Trend Following

   if(return_only_pullbacks) return (GetMomentumState() == -1); // Pullback específico
   if(IsVolatilityBurst()) return false; // Burst de volatilidade caça stops de trend

   return (GetMomentumState() == 1 || GetMomentumState() == 2);
}

bool CMacroRegimeEngine::IsBreakoutRegime()
{
   if(!isLiquiditySafe())  return false;
   if(!IsVolatilityBurst()) return false;
   if(GetMomentumState() != 2) return false;
   if(m_last_hurst < m_profile.mr_h_threshold) return false; // Mean reversion não dá breakout
   if(GetDirection() == 0) return false;
   return true;
}

bool CMacroRegimeEngine::IsMeanReversionRegime()
{
   if(!isLiquiditySafe())   return false;
   if(m_last_hurst > m_profile.trend_h_threshold) return false; // Presença de tendência anula MR
   if(isHighVol())          return false;
   if(IsVolatilityBurst())  return false; // Vol explosiva caça stops de MR
   int mom = GetMomentumState();
   if(mom != -1 && mom != -2) return false;
   return true;
}

//+------------------------------------------------------------------+
//| MÓDULO 4: MATEMÁTICA PURA (PRIVADO)                              |
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
   // ANTES: fazia seu próprio CopyClose(_Symbol,_Period,1,m_period,close)
   // hardcoded com shift=1, ignorando o shift passado para Get(). Isso
   // dessincronizava GetDirection()/GetSlopeNormalized() do Hurst calculado
   // quando Get() era chamado com shift != 1.
   // AGORA: recebe o MESMO array de preços já copiado por Get() e o MESMO
   // shift, garantindo consistência e eliminando uma chamada duplicada
   // ao terminal (CopyClose).
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
   m_last_atr = CustomATR(_Symbol, _Period, 14, shift);
   m_last_slope_normalized = (m_last_atr > 0) ? m_last_slope / m_last_atr : 0;
}

double CMacroRegimeEngine::Get(int shift)
{
   if(!InpMacroRegime)
      return(0.0);

   double price[];
   if(CopyClose(_Symbol,_Period,shift,m_period,price) != m_period) return 0.5;
   double ret[]; ArrayResize(ret, m_period-1);
   double mean = 0.0;
   for(int i=0; i<m_period-1; i++) { if(price[i] <= 0 || price[i+1] <= 0) return 0.5; ret[i] = MathLog(price[i+1] / price[i]); mean += ret[i]; }
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
         double a = (s*sxy - sx*sy) / denom; double b = (sy - a*sx) / s; double rms = 0.0;
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

   // Reaproveita 'price' (mesmo array, mesmo shift) em vez de recopiar.
   CalculateSlope(price, shift);

   return H;
}

//+------------------------------------------------------------------+
//| MÓDULO 5: APRESENTAÇÃO E LABELS                                  |
//+------------------------------------------------------------------+
int CMacroRegimeEngine::GetRegime(double H, double confidence)
{
   if(confidence < m_profile.trend_r2_threshold) return 0;
   double dir = GetDirection();
   if(H > m_profile.trend_h_strong_threshold) { if(dir > 0) return 2; if(dir < 0) return -2; return 1; }
   if(H > m_profile.trend_h_threshold)        { if(dir > 0) return 1; if(dir < 0) return -1; return 0; }
   if(H < m_profile.mr_h_extreme_threshold) return -3;
   if(H < m_profile.mr_h_threshold) return -2;
   return 0;
}

string CMacroRegimeEngine::GetLabel(double H)
{
   // ANTES: não verificava R² nenhum — podia rotular "BULLISH_TREND" com
   // confiança estatística baixíssima (R² ~0.10). Agora usa o mesmo
   // threshold de confiança que as outras funções de regime.
   if(m_last_r2 < m_profile.trend_r2_threshold) return "NEUTRAL (Low Conf)";

   double dir = GetDirection();
   if(H < m_profile.mr_h_extreme_threshold) return "STRONG_MEAN_REVERSION";
   if(H < m_profile.mr_h_threshold)         return "MEAN_REVERSION";
   if(H <= m_profile.trend_h_threshold && H >= m_profile.mr_h_threshold) return "NEUTRAL";
   if(dir > 0) return "BULLISH_TREND";
   if(dir < 0) return "BEARISH_TREND";
   return "TREND_NO_DIRECTION";
}

color CMacroRegimeEngine::GetRegimeColor()
{
   double H = m_last_hurst; double dir = GetDirection();
   if(H > m_profile.trend_h_threshold && dir > 0) return clrLime;
   if(H > m_profile.trend_h_threshold && dir < 0) return clrRed;
   if(H < m_profile.mr_h_extreme_threshold) return clrYellow;
   return clrGray;
}

string CMacroRegimeEngine::GetMarketSummary()
{
   return GetTrend() + " + " + GetVolatility() + "_VOL + " + GetMomentum() + "_MOM";
}

string CMacroRegimeEngine::GetTrend()
{
   if(m_last_r2 < m_profile.trend_r2_threshold) return "SIDEWAYS (Low Conf)";
   if(m_last_hurst > m_profile.trend_h_threshold)
   {
      double dir = GetDirection();
      if(dir > 0) return "BULLISH";
      if(dir < 0) return "BEARISH";
      return "TRENDING";
   }
   if(m_last_hurst < m_profile.mr_h_threshold) return "SIDEWAYS";
   return "NEUTRO";
}

string CMacroRegimeEngine::GetVolatility()
{
   RefreshBarCache();
   if(m_cache_atr_fast > m_cache_atr_slow * 1.2) return "HIGH";
   if(m_cache_atr_fast < m_cache_atr_slow * 0.8) return "LOW";
   return "NORMAL";
}

string CMacroRegimeEngine::GetMomentum()
{
   int mom_state = GetMomentumState();
   if(mom_state == 2)  return "STRONG";
   if(mom_state == -1) return "WEAK";
   if(mom_state == -2) return "REVERSAL";
   return "MODERATE";
}
//+------------------------------------------------------------------+