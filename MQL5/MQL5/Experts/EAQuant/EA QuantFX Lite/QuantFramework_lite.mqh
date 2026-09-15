//+------------------------------------------------------------------+
//|                                          QuantFramework_lite.mqh |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      "https://www.mql5.com"
#property version   "1.10"

//+------------------------------------------------------------------+
//| API MQL5                                                          |
//+------------------------------------------------------------------+
#include <Trade\PositionInfo.mqh>  CPositionInfo  m_position;
#include <Trade\Trade.mqh>         CTrade         m_trade;
#include <Trade\SymbolInfo.mqh>    CSymbolInfo    m_symbol;
#include <Trade\AccountInfo.mqh>   CAccountInfo   m_account;

//+------------------------------------------------------------------+
//| #Structs                                                         |
//+------------------------------------------------------------------+
struct Setting
{
   string   m_ea_name;
   string   m_ea_version;
   ulong    m_magic;
   int      m_max_slippage;
   string   m_comment;
   int      digits_adjust;
   double   m_adjusted_point;

   //-- Strategy
   double   price_open;
   datetime time_open;
   datetime time_new;

   //-- Execution Control
   bool     m_need_open_buy;
   bool     m_need_open_sell;

   //-- Daily Drawdown
   double   m_day_start_balance;
   datetime m_last_day_reset;

   //-- Time sync
   datetime g_utcOffsetSeconds;
   bool     g_syncOk;
} sets;

//+------------------------------------------------------------------+
//| Includes                                                         |
//+------------------------------------------------------------------+
#include "TimeFilter.mqh";
#include "Commission.mqh";
#include "OnTester.mqh";
#include "Design.mqh" CDesign m_design;


//+------------------------------------------------------------------+
//| MAGIC ID                                                         |
//+------------------------------------------------------------------+
ulong AutoMagicID(string ea_name, string version="1.0")
{
   ulong accountLogin = (ulong)AccountInfoInteger(ACCOUNT_LOGIN);
   string key = ea_name + "|" + version + "|" + _Symbol + "|" + IntegerToString(_Period) + "|" + IntegerToString(accountLogin);

   ulong hash = 5381;
   for(int i = 0; i < StringLen(key); i++)
      hash = ((hash << 5) + hash) + StringGetCharacter(key, i);

   return hash & 0x7FFFFFFF;
}

//+------------------------------------------------------------------+
//| REFRESH RATES                                                    |
//+------------------------------------------------------------------+
bool RefreshRates(void)
{
   if(!m_symbol.RefreshRates())
   {
      Print("RefreshRates error");
      return(false);
   }
   if(m_symbol.Ask()==0 || m_symbol.Bid()==0)
      return(false);
   return(true);
}

//+------------------------------------------------------------------+
//| COUNT POSITIONS                                                  |
//+------------------------------------------------------------------+
int CalculateAllPositions(void)
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(m_position.SelectByIndex(i))
         if(m_position.Symbol()==m_symbol.Name() && m_position.Magic()==sets.m_magic)
            count++;
   return(count);
}

//+------------------------------------------------------------------+
//| CLOSE ALL                                                        |
//+------------------------------------------------------------------+
void CloseAllByMagic()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == sets.m_magic)
         m_trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| TRAILING STOP                                                    |
//+------------------------------------------------------------------+
void TrailingStop()
{
   double Point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == sets.m_magic)
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);

         if(posType == POSITION_TYPE_BUY && InpTrailingStep != 0)
         {
            if((currentSL < openPrice || currentSL == 0) && Bid - (InpTrailingStep + InpTrailingStart) * Point >= openPrice)
               m_trade.PositionModify(ticket, NormalizeDouble(openPrice + InpTrailingStart * Point, digits), currentTP);
            if(currentSL >= openPrice && Bid - InpTrailingStep * Point > currentSL)
               m_trade.PositionModify(ticket, NormalizeDouble(Bid - InpTrailingStep * Point, digits), currentTP);
         }

         if(posType == POSITION_TYPE_SELL && InpTrailingStep != 0)
         {
            if((currentSL > openPrice || currentSL == 0) && Ask + (InpTrailingStep + InpTrailingStart) * Point <= openPrice)
               m_trade.PositionModify(ticket, NormalizeDouble(openPrice - InpTrailingStart * Point, digits), currentTP);
            if(currentSL <= openPrice && Ask + InpTrailingStep * Point < currentSL)
               m_trade.PositionModify(ticket, NormalizeDouble(Ask + InpTrailingStep * Point, digits), currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| TOTAL LOTS                                                       |
//+------------------------------------------------------------------+
double AllLots(int type)
{
   double lot = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == sets.m_magic)
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL))
            lot += PositionGetDouble(POSITION_VOLUME);
      }
   }
   return lot;
}

//+------------------------------------------------------------------+
//| PROFIT ALL                                                       |
//+------------------------------------------------------------------+
double ProfitAll(int type)
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == sets.m_magic)
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL))
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }
   return profit;
}

//+------------------------------------------------------------------+
//| DAILY DRAWDOWN PROTECTION                                        |
//+------------------------------------------------------------------+
void UpdateDayStartBalance()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));

   if(today != sets.m_last_day_reset)
   {
      sets.m_day_start_balance = m_account.Balance();
      sets.m_last_day_reset = today;
   }
}

bool IsDailyDrawdownExceeded()
{
   if(InpMaxDailyDrawdownPct <= 0) return false;

   UpdateDayStartBalance();

   if(sets.m_day_start_balance <= 0) return false;

   double equity = m_account.Equity();
   double dd_pct = (sets.m_day_start_balance - equity) / sets.m_day_start_balance * 100.0;

   return (dd_pct >= InpMaxDailyDrawdownPct);
}

//+------------------------------------------------------------------+
//| SPREAD CHECK                                                     |
//+------------------------------------------------------------------+
bool IsSpreadOk()
{
   if(InpMaxSpreadPips <= 0) return true;

   double spread_pts = (double)m_symbol.Spread();
   double spread_pips = spread_pts / 10.0;

   return (spread_pips <= InpMaxSpreadPips);
}


//+------------------------------------------------------------------+
//| LOT CALCULATION                                                  |
//+------------------------------------------------------------------+
double CalculateLot()
{
   double lots = InpLotValue;

   //--- normalize
   double minLot  = m_symbol.LotsMin();
   double maxLot  = m_symbol.LotsMax();
   double lotStep = m_symbol.LotsStep();

   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = MathMin(lots, InpMaxLot);

   int ratio = (int)MathRound(lots / lotStep);
   lots = ratio * lotStep;

   return NormalizeDouble(lots, 2);
}
//+------------------------------------------------------------------+
