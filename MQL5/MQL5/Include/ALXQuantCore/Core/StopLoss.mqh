//+------------------------------------------------------------------+
//|                                                    StopLoss.mqh  |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.00 - 2026-08-19 - Add: CStopLoss - SL fixo (pips) + banda
                           ATRStops_v1 inline (ratchet sem repaint,
                           ultima vela fechada). Consolidado a partir
                           das funcoes ATRStops e GetStopLossPrice do
                           EA QUantFX.
    v.7.01 - 2026-08-19 - Change: unificados InpSLFixValue/InpATRStopsKv
                           em InpSLValue (pips no SL_FIXED, multiplicador
                           Kv no SL_ATR).
*/

#include <ALXQuantCore\Core\enums.mqh>

//+------------------------------------------------------------------+
//| #Inputs - SL Mode (declarados aqui: a classe usa os inputs        |
//|            InpSLMode/InpATRStops* diretamente)                    |
//+------------------------------------------------------------------+
input group             "➜ SL Mode"
input ENUM_ALX_SL_MODE  InpSLMode            = SL_ATR;    // Stop mode
input double            InpSLValue           = 4.0;       // Stop value
      int               InpATRStopsLen       = 10;        // ATRStops: Length
      int               InpATRStopsPeriod    = 5;         // ATRStops: ATR period

//+------------------------------------------------------------------+
//| CStopLoss - calculo e gestao do Stop Loss                        |
//|   Modos: SL_FIXED (distancia em pips) e SL_ATR (banda ATRStops)  |
//|   Auto-contido: usa apenas SymbolInfo e iHigh/iLow/iClose nativos.|
//+------------------------------------------------------------------+
class CStopLoss
  {
private:
   string             m_symbol;
   ENUM_TIMEFRAMES    m_timeframe;
   double             m_adjusted_point;

   //--- cache da banda ATRStops (recalculada 1x por barra fechada)
   double             m_upper;
   double             m_lower;
   datetime           m_bar_time;

   //--- ATR simples (SMA de True Range) inline - mesma base do iATR
   double             ATR(const int period, const int shift)
     {
      if(period <= 0 || shift < 0) return(0.0);

      double sum = 0.0;
      int    n   = 0;
      for(int i = shift; i < shift + period; i++)
        {
         double h = iHigh(m_symbol, m_timeframe, i);
         double l = iLow(m_symbol, m_timeframe, i);
         double c = iClose(m_symbol, m_timeframe, i + 1);
         if(h <= 0 || l <= 0 || c <= 0) continue;
         double tr = MathMax(h - l, MathMax(MathAbs(h - c), MathAbs(l - c)));
         sum += tr;
         n++;
        }
      return((n > 0) ? sum / (double)n : 0.0);
     }

   //--- banda ATRStops_v1 (com ratchet de tendencia) - ultima vela fechada
   bool               Compute(double &upper, double &lower)
     {
      upper = 0.0;
      lower = 0.0;

      int    length     = InpATRStopsLen;
      int    atr_period = InpATRStopsPeriod;
      double kv         = InpSLValue;
      int    shift      = 1;                       // sempre ultima vela fechada (estavel)

      if(length <= 0 || atr_period <= 0 || kv <= 0) return(false);

      //--- warmup para estado estavel da cadeia ratchet (mesma base do indicador)
      int origin = shift + length + atr_period + 100;

      double smin1  = -100000.0;
      double smax1  = +100000.0;
      int    trend1 = 0;

      for(int bar = origin; bar >= shift; bar--)
        {
         double smin0 = -100000.0;
         double smax0 = +100000.0;
         bool   ok    = true;

         for(int iii = 0; iii < length; iii++)
           {
            int    barx = bar + iii;
            double h    = iHigh(m_symbol, m_timeframe, barx);
            double l    = iLow(m_symbol, m_timeframe, barx);
            double atr  = ATR(atr_period, barx);
            if(h <= 0 || l <= 0 || atr <= 0) { ok = false; break; }
            smin0 = MathMax(smin0, h - kv * atr);
            smax0 = MathMin(smax0, l + kv * atr);
           }
         if(!ok) return(false);

         double c      = iClose(m_symbol, m_timeframe, bar);
         int    trend0 = trend1;
         if(c > smax1) trend0 = +1;
         if(c < smin1) trend0 = -1;

         if(trend0 > 0) { if(smin0 < smin1) smin0 = smin1; upper = smin0; }
         if(trend0 < 0) { if(smax0 > smax1) smax0 = smax1; lower = smax0; }

         smin1  = smin0;
         smax1  = smax0;
         trend1 = trend0;
        }

      return(upper > 0 || lower > 0);   // bandas independentes (uma so ja basta)
     }

   //--- recalcula a banda 1x por barra fechada (cache)
   void               Update(void)
     {
      datetime bar_time = iTime(m_symbol, m_timeframe, 1);
      if(bar_time == m_bar_time) return;
      m_bar_time = bar_time;

      double up = 0.0, dn = 0.0;
      if(Compute(up, dn))
        {
         m_upper = up;
         m_lower = dn;
        }
     }

   //--- distancia minima de stop do broker (StopsLevel | spread*3 | Point)
   double             StopMin(void)
     {
      double stop_min = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) *
                        SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      if(stop_min <= 0.0)
         stop_min = (SymbolInfoDouble(m_symbol, SYMBOL_ASK) -
                     SymbolInfoDouble(m_symbol, SYMBOL_BID)) * 3.0;
      if(stop_min <= 0.0)
         stop_min = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      return(stop_min);
     }

   //--- replica CSymbolInfo::NormalizePrice (round para o tick do simbolo)
   double             Normalize(const double price)
     {
      return(MathRound(price / SymbolInfoDouble(m_symbol, SYMBOL_POINT)) *
             SymbolInfoDouble(m_symbol, SYMBOL_POINT));
     }

public:
   //--- configura o simbolo/timeframe/pip e zera o cache da banda
   void               Init(const string symbol, const ENUM_TIMEFRAMES tf,
                           const double adjusted_point)
     {
      m_symbol         = symbol;
      m_timeframe      = tf;
      m_adjusted_point = adjusted_point;
      m_upper          = 0.0;
      m_lower          = 0.0;
      m_bar_time       = 0;
     }

   //--- SL por modo (Fixo / ATRStops)
   //    InpSLMode == SL_FIXED e InpSLValue == 0 => sem SL (off)
   double             GetStopLossPrice(const ENUM_POSITION_TYPE pos_type,
                                       const double entry)
     {
      double sl       = 0.0;
      double stop_min = StopMin();

      if(InpSLMode == SL_ATR)
        {
         Update();
         sl = (pos_type == POSITION_TYPE_BUY) ? m_upper : m_lower;
        }
      else
        {
         double dist = InpSLValue * m_adjusted_point;   // pips -> preco
         if(dist > 0.0)
            sl = (pos_type == POSITION_TYPE_BUY) ? entry - dist : entry + dist;
        }

      //--- validacao de lado + distancia minima do broker
      if(sl > 0.0)
        {
         if(pos_type == POSITION_TYPE_BUY && sl >= entry) sl = entry - stop_min;
         if(pos_type == POSITION_TYPE_SELL && sl <= entry) sl = entry + stop_min;
         double d = MathAbs(entry - sl);
         if(d < stop_min)
            sl = (pos_type == POSITION_TYPE_BUY) ? entry - stop_min : entry + stop_min;
        }

      return(Normalize(sl));
     }

   //--- banda ATRStops atual (para trailing ratchet)
   double             Upper(void)        const { return(m_upper); }
   double             Lower(void)        const { return(m_lower); }
   void               UpdateBands(void)        { Update(); }
  };
//+------------------------------------------------------------------+