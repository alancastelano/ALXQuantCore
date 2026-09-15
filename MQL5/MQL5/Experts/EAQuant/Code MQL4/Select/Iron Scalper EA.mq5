//+------------------------------------------------------------------+
//|                                            Iron Scalper EA.mq5   |
//|                                          Clean MQL5 Port v1.00   |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

input double    InpRisk             = 0.01;    // Risk % per trade
input double    InpStopLossProcent  = 20;      // Max total loss % of balance
input double    InpTral             = 20;      // Trailing stop distance (pips)
input double    InpTralStart        = 3;       // Trailing start offset (pips)
input int       InpTimeStart        = 6;       // Trade start hour
input int       InpTimeEnd          = 17;      // Trade end hour
input double    InpPipsStep         = 4;       // Min body: avgBar multiplier
input double    InpMaxSpreadPips    = 0;       // Max spread filter (0=off)
input bool      InpInfo             = true;    // Show info panel

struct settings
{
   ulong    m_magic;
   int      m_slippage;
   bool     IsTime;
   double   balanceInit;

} sets;

const string    EA_NAME      = "IronScalper" + _Symbol;
const ENUM_TIMEFRAMES TF    = PERIOD_CURRENT;

int    D_factor;
CTrade g_trade;
CPositionInfo g_position;

int OnInit()
{
   EventSetTimer(1);

   sets.m_magic = AutoMagicID();
   sets.m_slippage = 30;
   sets.IsTime = true;
   sets.balanceInit = AccountInfoDouble(ACCOUNT_BALANCE);

   D_factor = (_Digits == 5 || _Digits == 3) ? 10 : 1;

   g_trade.SetExpertMagicNumber(sets.m_magic);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, 0, OBJ_LABEL);
   ObjectsDeleteAll(0, 0, OBJ_RECTANGLE_LABEL);
}

void OnTick()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   sets.IsTime = (dt.hour >= InpTimeStart && dt.hour < InpTimeEnd);
   if(!sets.IsTime) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pipSize = (_Digits % 2 == 1) ? _Point * 10 : _Point;
   if(InpMaxSpreadPips > 0 && ((ask - bid) / pipSize) > InpMaxSpreadPips) return;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue == 0) return;

   double lot = NormalizeDouble(
      AccountInfoDouble(ACCOUNT_BALANCE) / 10.0 * InpRisk
      / (tickValue * 100.0 * D_factor), 2);
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lot = MathMax(MathMin(lot, mx), mn);

   double open0  = iOpen(_Symbol, TF, 0);
   double close0 = iClose(_Symbol, TF, 0);
   double avgBar = AverageBar(1000);
   double bodyPts = MathAbs(open0 - close0) / _Point;

   bool bearish = (open0 > close0) && (bodyPts > avgBar * InpPipsStep);
   bool bullish = (open0 < close0) && (bodyPts > avgBar * InpPipsStep);

   double lossProc = (AccountInfoDouble(ACCOUNT_BALANCE) / 100.0) * InpStopLossProcent * (-1);
   if(InpStopLossProcent != 0 && ProfitAll(-1) < lossProc)
   {
      ClosePos();
      return;
   }

   if(CountHistBar(-1) == 0 && CountBar(-1) == 0)
   {
      if(Count(POSITION_TYPE_BUY) == 0 && bearish)
         g_trade.Sell(lot, _Symbol, bid, 0, 0, EA_NAME);
      if(Count(POSITION_TYPE_SELL) == 0 && bullish)
         g_trade.Buy(lot, _Symbol, ask, 0, 0, EA_NAME);
   }

   if(Count(-1) > 0 && InpTral != 0)
      Trailing();
}

void OnTimer()
{
   if(InpInfo)
      DrawInfoPanel();
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
      if((int)HistoryDealGetInteger(ticket, DEAL_MAGIC) != (int)sets.m_magic) continue;
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
      if((int)PositionGetInteger(POSITION_MAGIC) != (int)sets.m_magic) continue;
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime >= barOpen)
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
      if((int)PositionGetInteger(POSITION_MAGIC) != (int)sets.m_magic) continue;
      if(type == -1 || (int)PositionGetInteger(POSITION_TYPE) == type)
         count++;
   }
   return count;
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
      if((int)PositionGetInteger(POSITION_MAGIC) != (int)sets.m_magic) continue;
      if(type == -1 || (int)PositionGetInteger(POSITION_TYPE) == type)
         profit += PositionGetDouble(POSITION_PROFIT)
                 + PositionGetDouble(POSITION_SWAP)
                 + PositionGetDouble(POSITION_COMMISSION);
   }
   return profit;
}

double Profit(int type)
{
   double profit = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != (int)sets.m_magic) continue;
      if(type == -1 || (int)PositionGetInteger(POSITION_TYPE) == type)
         profit += PositionGetDouble(POSITION_PROFIT)
                 + PositionGetDouble(POSITION_SWAP)
                 + PositionGetDouble(POSITION_COMMISSION);
   }
   return profit;
}

double ProfitDey(int type)
{
   double profit = 0;
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(dayStart, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((int)HistoryDealGetInteger(ticket, DEAL_MAGIC) != (int)sets.m_magic) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
      if(type == -1 || (int)HistoryDealGetInteger(ticket, DEAL_TYPE) == type)
         profit += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return profit;
}

double ProfitTuDey(int type)
{
   double profit = 0;
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 1);
   datetime dayEnd   = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(dayStart, dayEnd);
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((int)HistoryDealGetInteger(ticket, DEAL_MAGIC) != (int)sets.m_magic) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
      if(type == -1 || (int)HistoryDealGetInteger(ticket, DEAL_TYPE) == type)
         profit += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return profit;
}

double ProfitWeek(int type)
{
   double profit = 0;
   datetime weekStart = iTime(_Symbol, PERIOD_W1, 0);
   HistorySelect(weekStart, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((int)HistoryDealGetInteger(ticket, DEAL_MAGIC) != (int)sets.m_magic) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
      if(type == -1 || (int)HistoryDealGetInteger(ticket, DEAL_TYPE) == type)
         profit += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return profit;
}

double ProfitMontag(int type)
{
   double profit = 0;
   datetime monthStart = iTime(_Symbol, PERIOD_MN1, 0);
   HistorySelect(monthStart, TimeCurrent());
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if((int)HistoryDealGetInteger(ticket, DEAL_MAGIC) != (int)sets.m_magic) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
      if(type == -1 || (int)HistoryDealGetInteger(ticket, DEAL_TYPE) == type)
         profit += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                 + HistoryDealGetDouble(ticket, DEAL_SWAP)
                 + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return profit;
}

double AverageBar(int bars)
{
   double total = 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   for(int i = 1; i <= bars; i++)
      total += (iHigh(_Symbol, TF, i) - iLow(_Symbol, TF, i)) / point;
   return total / bars;
}

void ClosePos()
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) == (int)sets.m_magic)
         g_trade.PositionClose(ticket);
   }
}

void Trailing()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != (int)sets.m_magic) continue;

      double price = PositionGetDouble(POSITION_PRICE_OPEN);
      double stop  = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if((int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         double newSL = 0;
         if((stop < price || stop == 0) && bid - (InpTral + InpTralStart) * _Point >= price)
            newSL = price + InpTralStart * _Point;
         if(stop >= price && bid - InpTral * _Point > stop)
            newSL = bid - InpTral * _Point;
         if(newSL > 0 && newSL != stop)
            g_trade.PositionModify(ticket, newSL, tp);
      }
      else if((int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
      {
         double newSL = 0;
         if((stop > price || stop == 0) && ask + (InpTral + InpTralStart) * _Point <= price)
            newSL = price - InpTralStart * _Point;
         if(stop <= price && ask + InpTral * _Point < stop)
            newSL = ask + InpTral * _Point;
         if(newSL > 0 && newSL != stop)
            g_trade.PositionModify(ticket, newSL, tp);
      }
   }
}

void PutLabel(string name, int x, int y, string text)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, 1);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 7);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
}

void PutLabel_(string name, int x, int y, string text)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, 1);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 7);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
}

bool RectLabelCreate3(string name, int x, int y, int width, int height, color back_clr)
{
   ResetLastError();
   if(!ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0))
      return false;
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, back_clr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_SUNKEN);
   ObjectSetInteger(0, name, OBJPROP_CORNER, 1);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrBlue);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
   return true;
}

void DrawInfoPanel()
{
   double stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pipSize = (_Digits % 2 == 1) ? _Point * 10 : _Point;
   double spread = (ask - bid) / pipSize;

   RectLabelCreate3("INFO_fon", 220, 20, 200, 225, clrBlack);

   PutLabel("INFO_LOGO",    165, 24, "IRON SCALPER");
   PutLabel("INFO_Line",    215, 27, "___________________________");
   PutLabel_("INFO_txt1",   215, 45, "Account information");
   PutLabel("INFO_Line2",   215, 47, "___________________________");
   PutLabel("INFO_txt2",    215, 65, "Minimum stop:");
   PutLabel("INFO_txt3",    215, 80, "Spread:");
   PutLabel("INFO_txt4",    215, 95, "Balance:");
   PutLabel("INFO_txt5",    215, 110, "Equity:");
   PutLabel("INFO_Line3",   215, 112, "___________________________");
   PutLabel_("INFO_txt6",   215, 130, "Profit on account");
   PutLabel("INFO_Line4",   215, 132, "___________________________");
   PutLabel("INFO_txt7",    215, 150, "Profit on pair:");
   PutLabel("INFO_txt8",    215, 165, "Total profit:");
   PutLabel("INFO_txt9",    215, 180, "Profit for today:");
   PutLabel("INFO_txt10",   215, 195, "Profit for yesterday:");
   PutLabel("INFO_txt11",   215, 210, "Profit for week:");
   PutLabel("INFO_txt12",   215, 225, "Profit for month:");

   PutLabel_("INFO_txt13",  85, 65, (string)stopLevel);
   PutLabel_("INFO_txt14",  85, 80, (string)spread);
   PutLabel_("INFO_txt15",  85, 95, (string)AccountInfoDouble(ACCOUNT_BALANCE));
   PutLabel_("INFO_txt16",  85, 110, (string)AccountInfoDouble(ACCOUNT_EQUITY));
   PutLabel_("INFO_txt17",  85, 150, (string)Profit(-1));
   PutLabel_("INFO_txt18",  85, 165, (string)ProfitAll(-1));
   PutLabel_("INFO_txt19",  85, 180, (string)ProfitDey(-1));
   PutLabel_("INFO_txt20",  85, 195, (string)ProfitTuDey(-1));
   PutLabel_("INFO_txt21",  85, 210, (string)ProfitWeek(-1));
   PutLabel_("INFO_txt22",  85, 225, (string)ProfitMontag(-1));
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
   return (ulong)MathAbs(hash);
}
