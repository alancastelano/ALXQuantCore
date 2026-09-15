//+------------------------------------------------------------------+
//|                                                RangeBreakout.mqh |
//|                        ALXQuant � Range Breakout Strategy Module  |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "ALXQuant"
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
    v.7.20 - 2026-08-02 - Add: Init(symbol, magic, min_range, max_range,
                           hl_filter, be, distance, step, enabled) recebe
                           parametros do EA; removidos os globais de
                           file-scope (InpStrategy_RM_*). Sinal e trailing
                           gated por m_enabled. Lot/comm agora vem do EA.
*/

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>


class CRangeBreakout
  {
private:
   struct SBreakoutParams
     {
      ulong    magic;
      int      breakout_MinRange;
      int      breakout_MaxRange;
      int      breakout_HLFilter;
      double   breakout_treilling_be;
      double   breakout_treilling_distance;
      double   breakout_treilling_step;
     };
   SBreakoutParams m_params;

   CPositionInfo  m_position;
   CTrade         m_trade;
   CSymbolInfo    m_symbol;

   //--- Estado de altern�ncia (replica G_ibuf_204 do indicador)
   int      m_lastSignalDir;     // 0=bull, 1=bear, -1=nenhum
   double   m_lastSignalClose;   // fechamento do �ltimo sinal
   datetime m_lastBullRangeEnd;  // fim do �ltimo range bull (anti-sobreposi��o)
   datetime m_lastBearRangeEnd;  // fim do �ltimo range bear

   double   m_pip;               // pip ajustado (_Point ou _Point*10)
   bool     m_enabled;           // estrategia habilitada (set pelo Init do EA)

   //--- M�todos privados
   double   CustomATR(int atr_period, int shift=1);
   bool     CheckBullPattern1(int shift, int range);
   bool     CheckBearPattern1(int shift, int range);
   bool     CheckBullPattern2(int shift, int range);
   bool     CheckBearPattern2(int shift, int range);
   bool     PassesAlternationFilter(int direction, double currentClose);
   bool     PassesOverlapFilter(int direction, int shift, int range);

public:
                     CRangeBreakout();
                    ~CRangeBreakout();

     void            Init(const string symbol, const ulong magic,
                          const int min_range, const int max_range,
                          const int hl_filter, const double be,
                          const double distance, const double step,
                          const bool enabled);
     uchar           SignalRangeBreakout();
     void            Trailing();

     ulong           GetMagic(void)      { return m_params.magic; }
   };


//+------------------------------------------------------------------+
CRangeBreakout::CRangeBreakout()
  {
   ZeroMemory(m_params);

   m_enabled        = false;
   m_lastSignalDir  = -1;
   m_lastSignalClose = 0.0;
   m_lastBullRangeEnd = 0;
   m_lastBearRangeEnd = 0;
  }

//+------------------------------------------------------------------+
CRangeBreakout::~CRangeBreakout()
  {
   ZeroMemory(m_params);
  }

//+------------------------------------------------------------------+
void CRangeBreakout::Init(const string symbol, const ulong magic,
                          const int min_range, const int max_range,
                          const int hl_filter, const double be,
                          const double distance, const double step,
                          const bool enabled)
  {
   m_params.magic                       = magic;
   m_params.breakout_MinRange           = min_range;
   m_params.breakout_MaxRange           = max_range;
   m_params.breakout_HLFilter           = hl_filter;
   m_params.breakout_treilling_be       = be;
   m_params.breakout_treilling_distance = distance;
   m_params.breakout_treilling_step     = step;
   m_enabled                            = enabled;

   m_symbol.Name(symbol);
   m_symbol.RefreshRates();

   m_trade.SetExpertMagicNumber(m_params.magic);
   m_trade.SetDeviationInPoints(10);
   m_trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Pip adjustment: 5/3 d�gitos ? pip = 10 points
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   m_pip = (digits == 3 || digits == 5) ? _Point * 10.0 : _Point;
  }

//+------------------------------------------------------------------+
//| Custom ATR                                                       |
//+------------------------------------------------------------------+
double CRangeBreakout::CustomATR(int atr_period, int shift=1)
  {
   if(atr_period <= 0) return 0.0;

   string sym = m_symbol.Name();
   double sum_tr = 0.0;
   int valid_bars = 0;

   for(int i = shift; i < shift + atr_period; i++)
     {
      double high       = iHigh(sym, PERIOD_CURRENT, i);
      double low        = iLow(sym, PERIOD_CURRENT, i);
      double close_prev = iClose(sym, PERIOD_CURRENT, i + 1);

      if(high == 0 || low == 0 || close_prev == 0) continue;

      double tr = MathMax(high - low,
                          MathMax(MathAbs(high - close_prev),
                                  MathAbs(low - close_prev)));
      sum_tr += tr;
      valid_bars++;
     }

   return (valid_bars > 0) ? sum_tr / valid_bars : 0.0;
  }

//+------------------------------------------------------------------+
//| Padr�es de Breakout (r�plica exata do indicador)                 |
//+------------------------------------------------------------------+

// f0_16: Bullish padr�o
bool CRangeBreakout::CheckBullPattern1(int shift, int range)
  {
   string sym = m_symbol.Name();
   double c1 = iClose(sym, PERIOD_CURRENT, shift);
   double o1 = iOpen(sym, PERIOD_CURRENT, shift);
   double r_h = iHigh(sym, PERIOD_CURRENT,
                      iHighest(sym, PERIOD_CURRENT, MODE_HIGH, range, shift + 1));
   double c_start = iClose(sym, PERIOD_CURRENT, shift + range + 1);
   double h_start = iHigh(sym, PERIOD_CURRENT, shift + range + 1);

   return (c1 > o1 && c1 > r_h && o1 < c_start && c1 > h_start);
  }

// f0_7: Bearish padr�o
bool CRangeBreakout::CheckBearPattern1(int shift, int range)
  {
   string sym = m_symbol.Name();
   double c1 = iClose(sym, PERIOD_CURRENT, shift);
   double o1 = iOpen(sym, PERIOD_CURRENT, shift);
   double r_l = iLow(sym, PERIOD_CURRENT,
                     iLowest(sym, PERIOD_CURRENT, MODE_LOW, range, shift + 1));
   double c_start = iClose(sym, PERIOD_CURRENT, shift + range + 1);
   double l_start = iLow(sym, PERIOD_CURRENT, shift + range + 1);

   return (c1 < o1 && c1 < r_l && o1 > c_start && c1 < l_start);
  }

// f0_17: Bullish alternativo (exaust�o vendedora)
bool CRangeBreakout::CheckBullPattern2(int shift, int range)
  {
   string sym = m_symbol.Name();
   double c1 = iClose(sym, PERIOD_CURRENT, shift);
   double o1 = iOpen(sym, PERIOD_CURRENT, shift);
   double r_h = iHigh(sym, PERIOD_CURRENT,
                      iHighest(sym, PERIOD_CURRENT, MODE_HIGH, range, shift + 1));
   double c_start = iClose(sym, PERIOD_CURRENT, shift + range + 1);
   double o_start = iOpen(sym, PERIOD_CURRENT, shift + range + 1);

   return (c1 > o1 && c1 > r_h && c_start < o_start);
  }

// f0_13: Bearish alternativo (exaust�o compradora)
bool CRangeBreakout::CheckBearPattern2(int shift, int range)
  {
   string sym = m_symbol.Name();
   double c1 = iClose(sym, PERIOD_CURRENT, shift);
   double o1 = iOpen(sym, PERIOD_CURRENT, shift);
   double r_l = iLow(sym, PERIOD_CURRENT,
                     iLowest(sym, PERIOD_CURRENT, MODE_LOW, range, shift + 1));
   double c_start = iClose(sym, PERIOD_CURRENT, shift + range + 1);
   double o_start = iOpen(sym, PERIOD_CURRENT, shift + range + 1);

   return (c1 < o1 && c1 < r_l && c_start > o_start);
  }

//+------------------------------------------------------------------+
//| Filtro de altern�ncia (r�plica de G_ibuf_204)                    |
//+------------------------------------------------------------------+
bool CRangeBreakout::PassesAlternationFilter(int direction, double currentClose)
  {
   // direction: 0=bull, 1=bear
   if(m_lastSignalDir == -1)
      return true;  // Primeiro sinal, sempre aceita

   if(direction == 0) // Bullish
     {
      // Aceita se �ltimo N�O foi bull, OU se pre�o caiu abaixo do close do �ltimo bull
      return (m_lastSignalDir != 0 || m_lastSignalClose > currentClose);
     }
   else // Bearish
     {
      // Aceita se �ltimo N�O foi bear, OU se pre�o subiu acima do close do �ltimo bear
      return (m_lastSignalDir != 1 || m_lastSignalClose < currentClose);
     }
  }

//+------------------------------------------------------------------+
//| Filtro anti-sobreposi��o de ranges (r�plica de f0_0)             |
//+------------------------------------------------------------------+
bool CRangeBreakout::PassesOverlapFilter(int direction, int shift, int range)
  {
   string sym = m_symbol.Name();
   datetime t_end = iTime(sym, PERIOD_CURRENT, shift + range); // fim do range

   if(direction == 0) // Bull
      return (t_end > m_lastBullRangeEnd);
   else
      return (t_end > m_lastBearRangeEnd);
  }

//+------------------------------------------------------------------+
//| Sinal Principal                                                  |
//+------------------------------------------------------------------+
uchar CRangeBreakout::SignalRangeBreakout()
  {
   if(!m_enabled) return 0;
   if(!m_symbol.RefreshRates()) return 0;

   string sym   = m_symbol.Name();
   int    shift = 1;  // vela fechada

   double close1 = iClose(sym, PERIOD_CURRENT, shift);

   for(int range = m_params.breakout_MinRange;
       range <= m_params.breakout_MaxRange;
       range++)
     {
      bool bullSignal = CheckBullPattern1(shift, range) ||
                        CheckBullPattern2(shift, range);

      bool bearSignal = CheckBearPattern1(shift, range) ||
                        CheckBearPattern2(shift, range);

      if(bullSignal)
        {
         // Filtro de altern�ncia (r�plica do indicador)
         if(!PassesAlternationFilter(0, close1)) continue;

         // Filtro anti-sobreposi��o (r�plica de f0_0)
         if(!PassesOverlapFilter(0, shift, range)) continue;

         // Atualiza estado
         m_lastSignalDir    = 0;
         m_lastSignalClose  = close1;
         m_lastBullRangeEnd = iTime(sym, PERIOD_CURRENT, shift + range);

         return 1;  // BUY
        }

      if(bearSignal)
        {
         if(!PassesAlternationFilter(1, close1)) continue;
         if(!PassesOverlapFilter(1, shift, range)) continue;

         m_lastSignalDir    = 1;
         m_lastSignalClose  = close1;
         m_lastBearRangeEnd = iTime(sym, PERIOD_CURRENT, shift + range);

         return 2;  // SELL
        }
     }

   return 0;
  }

//+------------------------------------------------------------------+
//| Trailing Stop (corrigido: pips, step)                            |
//+------------------------------------------------------------------+
void CRangeBreakout::Trailing()
  {
   if(!m_enabled) return;

   string sym = m_symbol.Name();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)m_params.magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double posOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      double posSL   = PositionGetDouble(POSITION_SL);
      double bid     = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask     = SymbolInfoDouble(sym, SYMBOL_ASK);

      double be_dist = m_params.breakout_treilling_be       * m_pip;
      double trail_d = m_params.breakout_treilling_distance  * m_pip;
      double trail_s = m_params.breakout_treilling_step      * m_pip;

      if(posType == POSITION_TYPE_BUY)
        {
         // Break-even: ativa quando lucro >= be + distance
         if((posSL < posOpen || posSL == 0) &&
            (bid - posOpen) >= (be_dist + trail_d))
           {
            m_trade.PositionModify(ticket, posOpen + be_dist, 0);
           }
         // Trailing: s� move se melhoria >= step
         else if(posSL >= posOpen &&
                 (bid - trail_d) > (posSL + trail_s))
           {
            m_trade.PositionModify(ticket, bid - trail_d, 0);
           }
        }
      else if(posType == POSITION_TYPE_SELL)
        {
         if((posSL > posOpen || posSL == 0) &&
            (posOpen - ask) >= (be_dist + trail_d))
           {
            m_trade.PositionModify(ticket, posOpen - be_dist, 0);
           }
         else if(posSL <= posOpen &&
                 (ask + trail_d) < (posSL - trail_s))
           {
            m_trade.PositionModify(ticket, ask + trail_d, 0);
           }
        }
     }
  }