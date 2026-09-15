//+------------------------------------------------------------------+
//|                                             TrendFollowing.mqh   |
//|                                     Copyright 2026, ALXQuantCore |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore"
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
*/ 
#property strict

#include <Trade\Trade.mqh>
// IMPORTAÇÃO CORRETA: A classe agora é auto-suficiente
//#include <ALXQuantCore_v2\Strategy\StopATR.mqh> CStopATR m_trend_stopatr;

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
//input group             "== Strategy Trend Following =="
//input int               InpStrategy_Trend_ATRPeriod            = 10;
//input double            InpStrategy_Trend_Mult                 = 3.0;
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Classe CTrendFollowing                                           |
//+------------------------------------------------------------------+
class CTrendFollowing 
{
private:
   CTrade            m_trade;
   struct SParams
   {
      ulong             m_magic;
      string            m_symbol_name;
      int               m_atr_period;
      double            m_mult;
      // Variáveis mortas removidas (m_enable_sl, m_be_atr_mult, etc...)
   } m_params;
   
   // Sua função de cálculo puro integrada à classe
   double         CustomATR(string symbol, ENUM_TIMEFRAMES period, int atr_period, int shift=1);
   bool           ShouldCloseOnSignal(uchar current_signal, ENUM_POSITION_TYPE pos_type);
   
public:
                  CTrendFollowing();
                  ~CTrendFollowing();
   
   bool           Init(ulong magic, string symbol);
   uchar          Signal();
   void           ManagePosition();
   
};

//+------------------------------------------------------------------+
CTrendFollowing::CTrendFollowing()  { ZeroMemory(m_params); }
CTrendFollowing::~CTrendFollowing() { } // Destrutor limpo, sem handles para liberar

//+------------------------------------------------------------------+
//| Inicialização                                                    |
//+------------------------------------------------------------------+
bool CTrendFollowing::Init(ulong magic, string symbol)
{
   m_params.m_magic       = magic;
   m_params.m_symbol_name = symbol;
   m_params.m_atr_period  = InpStrategy_Trend_ATRPeriod;
   m_params.m_mult        = InpStrategy_Trend_Mult;
   
   return true;
}

//+------------------------------------------------------------------+
//| Custom ATR - Cálculo puro sem indicador (Sua função)             |
//+------------------------------------------------------------------+
double CTrendFollowing::CustomATR(string symbol, ENUM_TIMEFRAMES period, int atr_period, int shift)
{
   if(atr_period <= 0) return 0.0;
   
   double sum_tr = 0.0;
   int valid_bars = 0;
   
   for(int i = shift; i < shift + atr_period; i++)
   {
      double high       = iHigh(symbol, period, i);
      double low        = iLow(symbol, period, i);
      double close_prev = iClose(symbol, period, i + 1); 
      
      if(high == 0 || low == 0 || close_prev == 0) continue; 
      
      double tr1 = high - low;
      double tr2 = MathAbs(high - close_prev);
      double tr3 = MathAbs(low - close_prev);
      
      double true_range = MathMax(tr1, MathMax(tr2, tr3));
      
      sum_tr += true_range;
      valid_bars++;
   }
   
   if(valid_bars == 0) return 0.0;
   
   return (sum_tr / valid_bars); 
}

//+------------------------------------------------------------------+
//| Cálculo do SuperTrend usando CustomATR                          |
//| v2.30: Confluência real aplicada, Cálculo puro integrado        |
//+------------------------------------------------------------------+
uchar CTrendFollowing::Signal()
{
   uchar res = 0;
   int lookback = 20; 
   
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   // Pega os preços necessários para o SuperTrend
   if(CopyHigh(m_params.m_symbol_name, PERIOD_CURRENT, 0, lookback + 1, high) <= 0)    return res;
   if(CopyLow(m_params.m_symbol_name, PERIOD_CURRENT, 0, lookback + 1, low) <= 0)      return res;
   if(CopyClose(m_params.m_symbol_name, PERIOD_CURRENT, 0, lookback + 1, close) <= 0)  return res;

   double up[], dn[];
   ArrayResize(up, lookback + 1); 
   ArrayResize(dn, lookback + 1);
   
   // Inicialização 20 barras atrás
   double median_init = (high[lookback] + low[lookback]) / 2.0;
   int trend = (close[lookback] > median_init) ? 1 : -1;
   
   // Calcula o ATR para a barra de inicialização
   double atr_init = CustomATR(m_params.m_symbol_name, PERIOD_CURRENT, m_params.m_atr_period, lookback);
   
   up[lookback] = median_init + m_params.m_mult * atr_init;
   dn[lookback] = median_init - m_params.m_mult * atr_init;

   // Loop do SuperTrend
   for(int i = lookback - 1; i >= 0; i--) 
   {
      double median = (high[i] + low[i]) / 2.0;
      
      // Chama a sua função CustomATR para cada barra específica do loop
      double current_atr = CustomATR(m_params.m_symbol_name, PERIOD_CURRENT, m_params.m_atr_period, i);
      
      double new_up = median + m_params.m_mult * current_atr;
      double new_dn = median - m_params.m_mult * current_atr;

      // Lógica de reversão
      if(close[i] > up[i+1]) trend = 1;
      else if(close[i] < dn[i+1]) trend = -1;

      up[i] = (trend == 1) ? MathMin(new_up, up[i+1]) : new_up;
      dn[i] = (trend == -1) ? MathMax(new_dn, dn[i+1]) : new_dn;
   }
   
   ENUM_TIMEFRAMES tf_high = PERIOD_H4;
   
   bool buy_htf  = iClose(Symbol(),tf_high,1) > iClose(Symbol(),tf_high,2); 
   bool sell_htf = iClose(Symbol(),tf_high,1) < iClose(Symbol(),tf_high,2); 
   
   
   //--- LÓGICA PRINCIPAL
   if(trend == 1 && buy_htf ) res = 1;  // Buy: SuperTrend ? E StopATR confirma Buy
   else if(trend == -1 && sell_htf  ) res = 2;  // Sell: SuperTrend ? E StopATR confirma Sell
   
   return res;
}

//+------------------------------------------------------------------+
//| Verifica reversão de sinal                                       |
//+------------------------------------------------------------------+
bool CTrendFollowing::ShouldCloseOnSignal(uchar current_signal, ENUM_POSITION_TYPE pos_type)
{
   if(pos_type == POSITION_TYPE_BUY && current_signal == 2) return true;
   if(pos_type == POSITION_TYPE_SELL && current_signal == 1) return true;
   return false;
}

//+------------------------------------------------------------------+
//| GESTOR PRINCIPAL                                                 |
//+------------------------------------------------------------------+
void CTrendFollowing::ManagePosition() 
{
   //m_trend_stopatr.StopTrailing();
}//+------------------------------------------------------------------+//+------------------------------------------------------------------+-----------------------------------------------+