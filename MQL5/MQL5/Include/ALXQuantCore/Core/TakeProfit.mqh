//+------------------------------------------------------------------+
//|                                                  TakeProfit.mqh  |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//| v11.0.0 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property version "11.0"
/*
    v.11.0 - 2026-09-06 - Add: CTakeProfit completo com 4 modos
                           (TP_FIXED, TP_RISK_REWARD, TP_ATR, TP_ADR).
                           ADR inline sem handle, ATR inline (mesma base
                           de StopLoss.mqh). Cache 1x por barra fechada.
    v.10.0 - 2026-08-24 - Initial stub.
*/

#include <ALXQuantCore\Core\enums.mqh>

//+------------------------------------------------------------------+
//| #Inputs - TP Mode (declarados aqui: a classe usa diretamente)     |
//+------------------------------------------------------------------+
input group              "➜ Take Profit"
input ENUM_ALX_TP_MODE   InpTPMode            = TP_RISK_REWARD;  // TP mode
input double             InpTPValue           = 25.0;            // TP value (pips / R:R ratio)
input double             InpATRMult           = 4.0;             // ATR multiplier (TP_ATR)
input int                InpATRPeriod         = 14;              // ATR period (TP_ATR)
input double             InpADRFactor         = 1.0;             // ADR multiplier (TP_ADR)
input int                InpADRDays           = 7;               // ADR lookback days (TP_ADR)

//+------------------------------------------------------------------+
//| CTakeProfit - calculo do Take Profit                              |
//|   Modos: TP_FIXED (pips), TP_RISK_REWARD (R:R),                  |
//|          TP_ATR (ATR multiple), TP_ADR (Average Daily Range)      |
//|   Auto-contido: usa apenas SymbolInfo e iHigh/iLow/iClose nativos.|
//+------------------------------------------------------------------+
class CTakeProfit
  {
private:
   string             m_symbol;
   ENUM_TIMEFRAMES    m_timeframe;
   double             m_adjusted_point;

   //--- cache ADR (recalculada 1x por barra fechada)
   double             m_adr_cache;
   datetime           m_bar_time;

   //--- ATR simples (SMA de True Range) inline
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

   //--- Average Daily Range (soma de ranges diarios / days)
   //    Usa barras de D1 para calcular ADR
   double             CalcADR(const int days)
     {
      if(days <= 0) return(0.0);

      double sum = 0.0;
      int    n   = 0;
      for(int i = 1; i <= days; i++)
        {
         double h = iHigh(m_symbol, PERIOD_D1, i);
         double l = iLow(m_symbol, PERIOD_D1, i);
         if(h <= 0 || l <= 0) continue;
         sum += (h - l);
         n++;
        }
      return((n > 0) ? sum / (double)n : 0.0);
     }

   //--- atualiza cache ADR 1x por barra fechada
   void               Update(void)
     {
      datetime bar_time = iTime(m_symbol, m_timeframe, 1);
      if(bar_time == m_bar_time) return;
      m_bar_time = bar_time;
      m_adr_cache = CalcADR(InpADRDays);
     }

   //--- distancia minima de stop do broker
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

   //--- normaliza preco para tick size
   double             Normalize(const double price)
     {
      return(MathRound(price / SymbolInfoDouble(m_symbol, SYMBOL_POINT)) *
             SymbolInfoDouble(m_symbol, SYMBOL_POINT));
     }

public:
   //--- configura o simbolo/timeframe/pip e zera caches
   void               Init(const string symbol, const ENUM_TIMEFRAMES tf,
                           const double adjusted_point)
     {
      m_symbol         = symbol;
      m_timeframe      = tf;
      m_adjusted_point = adjusted_point;
      m_adr_cache      = 0.0;
      m_bar_time       = 0;
     }

   //--- TP por modo (Fixed / Risk-Reward / ATR / ADR)
   double             GetTakeProfitPrice(const ENUM_POSITION_TYPE pos_type,
                                         const double entry,
                                         const double sl_price)
     {
      double tp       = 0.0;
      double stop_min = StopMin();

      switch(InpTPMode)
        {
         //--- TP_FIXED: distancia fixa em pips
         case TP_FIXED:
           {
            double dist = InpTPValue * m_adjusted_point;
            if(dist > 0.0)
               tp = (pos_type == POSITION_TYPE_BUY) ? entry + dist : entry - dist;
           }
         break;

         //--- TP_RISK_REWARD: multiplicador sobre a distancia SL-Entry
         case TP_RISK_REWARD:
           {
            double risk = MathAbs(entry - sl_price);
            if(risk > 0.0 && InpTPValue > 0.0)
              {
               double dist = risk * InpTPValue;
               tp = (pos_type == POSITION_TYPE_BUY) ? entry + dist : entry - dist;
              }
           }
         break;

         //--- TP_ATR: multiplicador sobre ATR periodico
         case TP_ATR:
           {
            double atr = ATR(InpATRPeriod, 1);  // ultima vela fechada
            if(atr > 0.0 && InpATRMult > 0.0)
              {
               double dist = atr * InpATRMult;
               tp = (pos_type == POSITION_TYPE_BUY) ? entry + dist : entry - dist;
              }
           }
         break;

         //--- TP_ADR: multiplicador sobre Average Daily Range
         case TP_ADR:
           {
            Update();
            if(m_adr_cache > 0.0 && InpADRFactor > 0.0)
              {
               double dist = m_adr_cache * InpADRFactor;
               tp = (pos_type == POSITION_TYPE_BUY) ? entry + dist : entry - dist;
              }
           }
         break;
        }

      //--- validacao de lado + distancia minima do broker
      if(tp > 0.0)
        {
         if(pos_type == POSITION_TYPE_BUY && tp <= entry) tp = entry + stop_min;
         if(pos_type == POSITION_TYPE_SELL && tp >= entry) tp = entry - stop_min;
         double d = MathAbs(tp - entry);
         if(d < stop_min)
            tp = (pos_type == POSITION_TYPE_BUY) ? entry + stop_min : entry - stop_min;
        }

      return(Normalize(tp));
     }

   //--- ADR cache atual
   double             GetADR(void) const  { return(m_adr_cache); }
   void               UpdateTP(void)      { Update(); }
  };
//+------------------------------------------------------------------+
