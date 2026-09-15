//+------------------------------------------------------------------+
//|                                                   Trailling.mqh  |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//| v11.1.0 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      ""
#property version   "11.1"
/*
    v.11.1 - 2026-09-06 - Fix: Input names matching EA (InpTraillingStep/InpTraliingStart).
                           Fix: Commission-aware trailing (commFloor from CCommission).
                           Fix: Logic exactly matches EA Quant Cripto v11 Traling().
                           Default 0.0 = off (trailing disabled by default).
    v.11.0 - 2026-09-06 - Renamed from TrailingStop.mqh.
                           Inputs declarados internamente (padrao Commission.mqh).
                           Adicionado SetParams() para reconfigurar em runtime.
                           Mesma logica comprovada: BE + Trailing, freeze/stops level.
    v.10.0 - 2026-08-24 - Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
*/

#include <Trade/Trade.mqh>
#include <ALXQuantCore\Core\Commission.mqh>

//+------------------------------------------------------------------+
//| #Inputs - Trailing & Breakeven                                    |
//+------------------------------------------------------------------+
input group              "➜ Trailing & Breakeven"
input double             InpTraillingStep      = 0.0;   // Trailing step (points, 0=off)
input double             InpTraliingStart      = 0.0;   // Trailing start/BE (points, 0=off)

//+------------------------------------------------------------------+
//| CTrailling - Breakeven + Trailing Stop                           |
//|   Lógica exata do EA Quant Cripto v11 Traling()                  |
//|   Commission-aware: usa commFloor no cálculo de BE e trailing    |
//+------------------------------------------------------------------+
class CTrailling
  {
private:
   CTrade      m_trade;
   long        m_magic;
   string      m_symbol;
   CCommission *m_comm;

   double      m_step;
   double      m_start;

public:
                     CTrailling()  { m_magic = 0; m_comm = NULL; }
                    ~CTrailling() {}

   //--- inicializa com symbol, magic e ponteiro de comissão
   void             Init(const string symbol, const long magic, CCommission *comm)
     {
      m_symbol = symbol;
      m_magic  = magic;
      m_comm   = comm;
      m_step   = InpTraillingStep;
      m_start  = InpTraliingStart;

      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(100);
     }

   //--- reconfigura em runtime
   void             SetParams(const double step, const double start)
     {
      m_step  = step;
      m_start = start;
     }

   //--- loop principal: itera posicoes e aplica BE + Trailing
   void             Process(void)
     {
      if(m_magic == 0) return;
      if(m_step == 0)  return;  // trailing desligado

      //--- commFloor: distância em preço que cobre comissão+buffer
      double commFloor = 0.0;
      if(m_comm != NULL)
         commFloor = m_comm.DistPrice();

      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      int    digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);

      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;

         if(PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;

         long   posType  = PositionGetInteger(POSITION_TYPE);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);

         double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);

         //--- stops_level + freeze_level
         double stop_level   = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
         double freeze_level = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL) * point;
         if(stop_level == 0.0) stop_level = (ask - bid) * 3.0;
         double min_stop_distance = MathMax(stop_level, freeze_level);

         //--- LOGICA COMPRA (BUY)
         if(posType == POSITION_TYPE_BUY && m_step != 0)
           {
            double firstLockPrice = NormalizeDouble(openPrice + m_start * point + commFloor, digits);
            double trailPrice     = NormalizeDouble(bid - m_step * point, digits);

            //--- First lock: cost floor (breakeven real = abertura + comissão)
            if((currentSL < openPrice || currentSL == 0)
               && bid - (m_step + m_start) * point >= openPrice + commFloor)
              {
               if(bid - firstLockPrice >= min_stop_distance)
                  m_trade.PositionModify(ticket, firstLockPrice, currentTP);
              }

            //--- Subsequent steps: only move if above cost floor
            if(currentSL >= openPrice + commFloor && trailPrice > currentSL)
              {
               if(bid - trailPrice >= min_stop_distance)
                  m_trade.PositionModify(ticket, trailPrice, currentTP);
              }
           }

         //--- LOGICA VENDA (SELL)
         if(posType == POSITION_TYPE_SELL && m_step != 0)
           {
            double firstLockPrice = NormalizeDouble(openPrice - m_start * point - commFloor, digits);
            double trailPrice     = NormalizeDouble(ask + m_step * point, digits);

            //--- First lock: cost floor (breakeven real = abertura - comissão)
            if((currentSL > openPrice || currentSL == 0)
               && ask + (m_step + m_start) * point <= openPrice - commFloor)
              {
               if(firstLockPrice - ask >= min_stop_distance)
                  m_trade.PositionModify(ticket, firstLockPrice, currentTP);
              }

            //--- Subsequent steps: only move if below cost floor
            if(currentSL <= openPrice - commFloor && trailPrice < currentSL)
              {
               if(trailPrice - ask >= min_stop_distance)
                  m_trade.PositionModify(ticket, trailPrice, currentTP);
              }
           }
        }
     }
  };
//+------------------------------------------------------------------+
