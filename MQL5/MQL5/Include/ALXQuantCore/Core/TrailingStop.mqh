//+------------------------------------------------------------------+
//|                                                 TrailingStop.mqh |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
*/

#include <Trade/Trade.mqh>

class CTrailingStop
{
private:
   CTrade m_trade;
   long   m_magic;
   string m_symbol; // Adicionado para melhor mapeamento
   
   double m_trail_start;
   double m_trail_distance;
   double m_trail_step;
   double m_be_start;
   double m_be_profit;

public:
   CTrailingStop() { m_magic = 0; }
  ~CTrailingStop() {}

   // Adicionamos a passagem do 'symbol' no construtor/Init
   void Init(string symbol, long magic, double trail_start, double trail_distance, double trail_step, double be_start = 0.0, double be_profit = 0.0)
   {
      m_symbol        = symbol;
      m_magic         = magic;
      m_trail_start   = trail_start;
      m_trail_distance= trail_distance;
      m_trail_step    = trail_step;
      m_be_start      = be_start;
      m_be_profit     = be_profit;
      
      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(100); 
   }

   void Process()
   {
      if(m_magic == 0) return;

      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i); 
         if(ticket == 0) continue;

         if(PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;

         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double posOpen  = PositionGetDouble(POSITION_PRICE_OPEN);
         double posSL    = PositionGetDouble(POSITION_SL);
         double posTP    = PositionGetDouble(POSITION_TP);
         
         double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
         int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
         
         double priceAct = (posType == POSITION_TYPE_BUY) ? bid : ask;

         // Combinação de StopsLevel e FreezeLevel em um único limitador
         double stop_level = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
         double freeze_level = (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL) * point;
         if(stop_level == 0.0) stop_level = (ask - bid) * 3.0; 
         
         double min_stop_distance = MathMax(stop_level, freeze_level);
         double new_sl = 0;

         //--- LÓGICA COMPRA (BUY)
         if(posType == POSITION_TYPE_BUY)
         {
            // Fase 1: Breakeven
            if(m_be_start > 0 && (posSL < posOpen || posSL == 0) && (priceAct - posOpen >= m_be_start))
            {
               new_sl = posOpen + m_be_profit; 
            }
            // Fase 2: Trailing Contínuo
            else if(priceAct - posOpen >= m_trail_start)
            {
               double calc_trail_sl = priceAct - m_trail_distance;
               if(posSL == 0 || calc_trail_sl > posSL + m_trail_step)
               {
                  new_sl = calc_trail_sl;
               }
            }

            if(new_sl > 0)
            {
               new_sl = NormalizeDouble(new_sl, digits);
               
               // Correção: Pula a modificação se o preço atual estiver perto demais do alvo calculado.
               if(priceAct - new_sl < min_stop_distance) continue; 

               if(new_sl > posSL || posSL == 0)
               {
                  m_trade.PositionModify(ticket, new_sl, posTP);
               }
            }
         }
         
         //--- LÓGICA VENDA (SELL)
         else if(posType == POSITION_TYPE_SELL)
         {
            // Fase 1: Breakeven
            if(m_be_start > 0 && (posSL > posOpen || posSL == 0) && (posOpen - priceAct >= m_be_start))
            {
               new_sl = posOpen - m_be_profit;
            }
            // Fase 2: Trailing Contínuo
            else if(posOpen - priceAct >= m_trail_start)
            {
               double calc_trail_sl = priceAct + m_trail_distance;
               if(posSL == 0 || calc_trail_sl < posSL - m_trail_step)
               {
                  new_sl = calc_trail_sl;
               }
            }

            if(new_sl > 0)
            {
               new_sl = NormalizeDouble(new_sl, digits);
               
               // Correção: Pula a modificação se o preço atual estiver perto demais do alvo calculado.
               if(new_sl - priceAct < min_stop_distance) continue;

               if(new_sl < posSL || posSL == 0)
               {
                  m_trade.PositionModify(ticket, new_sl, posTP);
               }
            }
         }
      }
   }
};