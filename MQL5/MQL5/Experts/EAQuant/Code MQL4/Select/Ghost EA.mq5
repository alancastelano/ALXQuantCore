//+------------------------------------------------------------------+
//|                                                 ALXQuantCore.mq5 |
//|                                          Clean MQL5 Port v1.00   |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore"
#property version   "1.10"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>



input string    InpSet              = "EURUSD - M1";
input double    InpRisk             = 2.0;
input int       InpProfitPips       = 30;
input int       InpTimeStart        = 3;
input int       InpTimeEnd          = 16;
input bool      InpFriday           = false;

input double    InpExpBar           = 1.5;
input int       InpHowBar           = 2000;
input int       InpMaxOrders        = 4;
input double    InpMaxSpreadPips    = 0;   // 0 = disabled, max spread in pips


struct settings
{
   ulong    m_magic;
   int      m_slippage;
   
   bool     IsTime;
   bool     IsLimit;
   double   balanceInit;
   

} sets;

const string    EA_NAME             = "ALXQuantGH" + _Symbol;
const ENUM_TIMEFRAMES       TF      = PERIOD_CURRENT;


ulong  InpMagic = 0;
int    g_digitMult;
int    g_lotDig;
CTrade          g_trade;

int OnInit()
{
//---
   EventSetTimer(10); //-- timer 10s

   InpMagic = AutoMagicID();
   sets.IsLimit      = true;
   sets.IsTime       = true;
   sets.balanceInit  = AccountInfoDouble(ACCOUNT_BALANCE);

   g_digitMult = 1;
   if((int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 5 || (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) == 3)
      g_digitMult = 10;

   double ls = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(ls >= 1.0)     g_lotDig = 0;
   else if(ls >= 0.1) g_lotDig = 1;
   else                g_lotDig = 2;

   g_trade.SetExpertMagicNumber(InpMagic);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0,0, OBJ_LABEL);
   ObjectsDeleteAll(0,0, OBJ_RECTANGLE_LABEL);
}

void OnTick()
{
//---
   double pl =  AccountInfoDouble(ACCOUNT_EQUITY)-sets.balanceInit;
   if(pl >= sets.balanceInit * (8.01 / 100.0)) { sets.IsLimit = false; }
//---   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpTimeStart || dt.hour >= InpTimeEnd) { sets.IsTime = false; } else { sets.IsTime = true; }
//---

   bool can_trade = sets.IsLimit &&
                     sets.IsTime ;


   double open0   = iOpen(_Symbol, TF, 0);
   double close0  = iClose(_Symbol, TF, 0);
   double avgBar  = AverageBar(InpHowBar);
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bodyPts = MathAbs(open0 - close0) / point;

   bool bearish = (open0 > close0) && (bodyPts > avgBar * InpExpBar);
   bool bullish = (open0 < close0) && (bodyPts > avgBar * InpExpBar);


   double lot = NormalizeDouble(
      AccountInfoDouble(ACCOUNT_BALANCE) / 100.0 * InpRisk
      / (SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) * 100.0 * g_digitMult), g_lotDig);
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lot = MathMax(MathMin(lot, mx), mn);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pipSize = (_Digits % 2 == 1) ? _Point * 10 : _Point;
   double spreadPips = (ask - bid) / pipSize;
   bool spreadOk = (InpMaxSpreadPips == 0) || (spreadPips <= InpMaxSpreadPips);

   if(CountHistBar(-1) == 0 && can_trade && spreadOk)
   {
      if(Count(-1) == 0)
      {
         if(bearish)
            g_trade.Sell(lot, _Symbol, bid, 0, 0, EA_NAME);
         if(bullish)
            g_trade.Buy(lot, _Symbol, ask, 0, 0, EA_NAME);
      }

      int brokerLimit = (int)AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
      if(CountAll(-1) < InpMaxOrders
         && (CountAll(-1) < brokerLimit || brokerLimit == 0)
         && CountBar(-1) == 0)
      {
         if(Count(POSITION_TYPE_BUY) > 0 && bullish)
            g_trade.Buy(lot, _Symbol, ask, 0, 0, EA_NAME);
         if(Count(POSITION_TYPE_SELL) > 0 && bearish)
            g_trade.Sell(lot, _Symbol, bid, 0, 0, EA_NAME);
      }
   }

   double totalLots = AllLots(-1);
   double target = totalLots * InpProfitPips;
   if(ProfitAll(-1) >= target && target != 0)
      ClosePos();
}

void OnTimer()
{
}

int CountHistBar(int type)
{
   int count = 0;
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   datetime barOpen = iTime(_Symbol, TF, 0);
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((int)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
      datetime closeTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
      if(closeTime >= barOpen)
         if(type == -1 || (int)HistoryDealGetInteger(ticket, DEAL_TYPE) == type)
            count++;
   }
   return count;
}

int CountBar(int type)
{
   int count = 0;
   int total = PositionsTotal();
   datetime barOpen = iTime(_Symbol, TF, 0);
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime >= barOpen)
         if(type == -1 || (int)PositionGetInteger(POSITION_TYPE) == type)
            count++;
   }
   return count;
}

int CountAll(int type)
{
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(type == -1 || (int)PositionGetInteger(POSITION_TYPE) == type)
         count++;
   }
   return count;
}

int Count(int type)
{
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(type == -1 || (int)PositionGetInteger(POSITION_TYPE) == type)
         count++;
   }
   return count;
}

double AllLots(int type)
{
   double lot = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(type == -1 || (int)PositionGetInteger(POSITION_TYPE) == type)
         lot += PositionGetDouble(POSITION_VOLUME);
   }
   return lot;
}

double ProfitAll(int type)
{
   double profit = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(type == -1 || (int)PositionGetInteger(POSITION_TYPE) == type)
         profit += PositionGetDouble(POSITION_PROFIT)
                 + PositionGetDouble(POSITION_SWAP)
                 + PositionGetDouble(POSITION_COMMISSION);
   }
   return profit;
}

void ClosePos()
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         g_trade.PositionClose(ticket);
   }
}

double AverageBar(int bars)
{
   double total = 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   for(int i = 1; i <= bars; i++)
      total += (iHigh(_Symbol, TF, i) - iLow(_Symbol, TF, i)) / point;
   return total / bars;
}

ulong AutoMagicID()
{
   string key = _Symbol + IntegerToString(Period()) + EA_NAME;
   uchar data[];
   StringToCharArray(key, data);
   int hash = 0;
   int len = ArraySize(data);
   for(int i = 0; i < len; i++)
      hash = hash * 31 + data[i];
   return MathAbs(hash % 90000) + 10000;
}
