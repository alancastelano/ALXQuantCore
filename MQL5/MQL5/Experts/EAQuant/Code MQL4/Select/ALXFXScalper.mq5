//+------------------------------------------------------------------+
//|                                                   ALXFXScalper.mq5 |
//|                                                   ALXQuantCore     |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore"
#property version   "1.02"

#include <Trade\Trade.mqh>

input group "== Money Management =="
input double   InpLot              = 0.01;
input double   InpLotMultiplier    = 1.00;
input double   InpTakeProfit       = 30;
input double   InpStep             = 25;
input int      InpAveraging        = 1;
input int      InpMaxTrades        = 8;

input group "== Daily Target =="
input bool     InpUseDailyTarget   = true;
input double   InpDailyTarget      = 10;

input group "== Equity Stop =="
input bool     InpUseEquityStop    = false;
input double   InpEquityRiskPct    = 20;

input group "== Time Filter =="
input int      InpOpenHour         = 6;
input int      InpCloseHour        = 17;
input bool     InpTradeThursday    = true;
input int      InpThursdayHour     = 12;
input bool     InpTradeFriday      = false;
input int      InpFridayHour       = 20;

input group "== Range Filter =="
input double   InpOpenRangePips    = 20;
input double   InpMaxDailyRange    = 500;

input group "== Hidden TP =="
input bool     InpHiddenTP         = false;
input double   InpHiddenTPAmount   = 500;

input group "== Slippage =="
input int      InpSlippage         = 5;

input group "== Timeout =="
input bool     InpUseTimeout       = false;
input int      InpTimeoutHours     = 48;

input group "== DFA / DataMiner =="
input int      InpDFAPeriod        = 200;
input int      InpDFAMinScale      = 4;
input int      InpDFAMaxScale      = 80;

input group "== Regime Filter =="
input bool     InpFilterRegime     = true;
input bool     InpRegimeTrending   = true;
input bool     InpRegimeMeanRev    = true;
input bool     InpRegimeQuiet      = true;
input bool     InpRegimeErratic    = true;

input group "== Macro Filter =="
input bool     InpFilterMacro      = false;
input bool     InpMacroCheckVIX    = false;
input double   InpMacroMaxVIX      = 30;
input bool     InpMacroNYsession   = false;
input bool     InpMacroNoFriday    = true;

const string   EA_NAME             = "ALXFXScalper" + _Symbol;

#include <ALXQuantCore\Modules\DataMiner.mqh>
#include <ALXQuantCore\Modules\RiskManager.mqh>

CTrade         g_trade;
CDataMinerBuffered   g_miner;
CMacroRegimeEngine      g_regime;
CRiskSentiment       g_risk;
ulong          g_magic;
int            g_digitMult;
int            g_lotDigits;
double         g_point;

int            g_martinMode;
bool           g_martinMultiply;
double         g_stepPips;
double         g_tpPips;

int            g_tradeCount;
int            g_orderCount;
bool           g_stepReached;
bool           g_hasBuy;
bool           g_hasSell;
double         g_lastBuyPrice;
double         g_lastSellPrice;
double         g_martinLot;
double         g_baseLot;
bool           g_modified;
double         g_prevBalance;
double         g_peakEquity;
datetime       g_timeoutEnd;

string         g_symbol;
int            g_digits;
int            g_spread;
double         g_bid;
double         g_ask;

CRiskManager  g_risk_mgr;
bool           g_isLimit;
double         g_balanceInit;
//+------------------------------------------------------------------+
void ResetState()
{
   g_martinMode    = 1;
   g_martinMultiply = true;
   g_stepPips      = InpStep;
   g_tpPips        = InpTakeProfit;
   g_tradeCount    = 0;
   g_orderCount    = -2;
   g_stepReached   = false;
   g_hasBuy        = false;
   g_hasSell       = false;
   g_lastBuyPrice  = 0;
   g_lastSellPrice = 0;
   g_martinLot     = 0;
   g_baseLot       = InpLot;
   g_modified      = false;
   g_prevBalance   = 0;
   g_peakEquity    = 0;
   g_timeoutEnd    = 0;
    g_isLimit       = false;
    g_balanceInit   = 0;
}

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
int OnInit()
{
   g_point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_symbol     = _Symbol;
   g_digitMult  = 1;
   if(g_digits == 5 || g_digits == 3)
      g_digitMult = 10;

   double ls = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(ls >= 1.0)      g_lotDigits = 0;
   else if(ls >= 0.1) g_lotDigits = 1;
   else                g_lotDigits = 2;

   g_magic = AutoMagicID();
   g_trade.SetExpertMagicNumber(g_magic);
   g_trade.SetDeviationInPoints(InpSlippage);

   ResetState();

   g_regime.Init(InpDFAPeriod, InpDFAMinScale, InpDFAMaxScale);
   g_regime.SetProfile(g_regime.DetectAssetProfile(_Symbol));
   g_risk.Init();
   g_balanceInit = AccountInfoDouble(ACCOUNT_BALANCE);
   g_risk_mgr.Init(g_magic);

   string csvName = "ALXFXScalper_" + _Symbol + "_miner.csv";
   g_miner.Init(g_magic, csvName, "C:\\ALXQuant\\app\\alpha_miner\\report\\", 3, &g_regime, &g_risk);

   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   g_miner.FlushToDisk();
   EventKillTimer();
   ObjectsDeleteAll(0, 0, OBJ_LABEL);
   ObjectsDeleteAll(0, 0, OBJ_RECTANGLE_LABEL);
}

//+------------------------------------------------------------------+
void OnTick()
{
   g_miner.Tick();
      Process();
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   g_miner.OnTransaction(trans);
}

//+------------------------------------------------------------------+
void OnTimer()
{
   //Process();
}

//+------------------------------------------------------------------+
void UpdateQuotes()
{
   g_bid    = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   g_ask    = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   g_spread = (int)SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
}

//+------------------------------------------------------------------+
double CalculateDailyPnL()
{
   HistorySelect(iTime(g_symbol, PERIOD_D1, 0), TimeCurrent());
   double pnl = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != g_symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != g_magic) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
      pnl += HistoryDealGetDouble(ticket, DEAL_PROFIT)
           + HistoryDealGetDouble(ticket, DEAL_SWAP)
           + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return pnl;
}

//+------------------------------------------------------------------+
double GetTotalPositionProfit()
{
   double profit = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      profit += PositionGetDouble(POSITION_PROFIT)
              + PositionGetDouble(POSITION_SWAP)
              + PositionGetDouble(POSITION_COMMISSION);
   }
   return profit;
}

//+------------------------------------------------------------------+
int CountPositionsByType(int type)
{
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) == type)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
double GetLastPriceByType(int type)
{
   ulong lastTicket = 0;
   double price = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != type) continue;
      if(ticket > lastTicket)
      {
         lastTicket = ticket;
         price = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return price;
}

//+------------------------------------------------------------------+
bool HasPositionOfType(int type)
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((int)PositionGetInteger(POSITION_TYPE) == type)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
double GetAverageOpenPrice()
{
   double totalPriceVolume = 0;
   double totalVolume = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY || type == POSITION_TYPE_SELL)
      {
         double vol = PositionGetDouble(POSITION_VOLUME);
         totalPriceVolume += PositionGetDouble(POSITION_PRICE_OPEN) * vol;
         totalVolume += vol;
      }
   }
   if(totalVolume == 0) return 0;
   return NormalizeDouble(totalPriceVolume / totalVolume, g_digits);
}

//+------------------------------------------------------------------+
void CloseAllByType(bool closeBuy, bool closeSell)
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if((type == POSITION_TYPE_BUY && closeBuy) ||
         (type == POSITION_TYPE_SELL && closeSell))
      {
         g_trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
double CalcLotFixed()
{
   return g_baseLot;
}

//+------------------------------------------------------------------+
double CalcLotGeometric(int tradeIndex)
{
   if(g_martinMultiply)
      return NormalizeDouble(g_baseLot * MathPow(InpLotMultiplier, tradeIndex), g_lotDigits);
   return NormalizeDouble(g_baseLot, g_lotDigits);
}

//+------------------------------------------------------------------+
double CalcLotAdaptive(int tradeIndex)
{
   double result = g_baseLot;
   int total = HistoryDealsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != g_symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != g_magic) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      if(profit < 0)
      {
         double prevLot = HistoryDealGetDouble(ticket, DEAL_VOLUME);
         if(g_martinMultiply)
            result = NormalizeDouble(prevLot * InpLotMultiplier, g_lotDigits);
         else
            result = NormalizeDouble(prevLot + InpLot, g_lotDigits);
         break;
      }
   }
   return result;
}

//+------------------------------------------------------------------+
double CalculateMartingaleLot(int tradeIndex)
{
   if(g_martinMode == 0)
      return CalcLotFixed();
   if(g_martinMode == 1)
      return CalcLotGeometric(tradeIndex);
   return CalcLotAdaptive(tradeIndex);
}

//+------------------------------------------------------------------+
bool SendBuyOrder(double lot)
{
   UpdateQuotes();
   string comment = g_symbol + "-ALXFXScalper-" + IntegerToString(g_tradeCount);
   double sl = 0;
   double tp = (g_tpPips > 0) ? (g_ask + g_tpPips * g_point) : 0;
   if(g_trade.Buy(lot, g_symbol, g_ask, sl, tp, comment))
   {
      g_orderCount++;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool SendSellOrder(double lot)
{
   UpdateQuotes();
   string comment = g_symbol + "-ALXFXScalper-" + IntegerToString(g_tradeCount);
   double sl = 0;
   double tp = (g_tpPips > 0) ? (g_bid - g_tpPips * g_point) : 0;
   if(g_trade.Sell(lot, g_symbol, g_bid, sl, tp, comment))
   {
      g_orderCount++;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void ApplySLTPToAll()
{
   double avgPrice = GetAverageOpenPrice();
   if(avgPrice == 0) return;
   double tp = (g_tpPips > 0) ? (avgPrice + g_tpPips * g_point) : 0;

   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != g_magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
         g_trade.PositionModify(ticket, PositionGetDouble(POSITION_SL), tp);
      else if(type == POSITION_TYPE_SELL)
      {
         double tpSell = (g_tpPips > 0) ? (avgPrice - g_tpPips * g_point) : 0;
         g_trade.PositionModify(ticket, PositionGetDouble(POSITION_SL), tpSell);
      }
   }
}

//+------------------------------------------------------------------+
bool CheckTimeFilter()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(!InpTradeThursday && dt.day_of_week == 4) return false;
   if(InpTradeThursday && dt.day_of_week == 4 && dt.hour > InpThursdayHour) return false;
   if(!InpTradeFriday && dt.day_of_week == 5) return false;
   if(InpTradeFriday && dt.day_of_week == 5 && dt.hour > InpFridayHour) return false;

   int openH = (InpOpenHour == 24) ? 0 : InpOpenHour;
   int closeH = (InpCloseHour == 24) ? 0 : InpCloseHour;

   if(openH < closeH)
   {
      if(dt.hour < openH || dt.hour >= closeH) return false;
   }
   else if(openH > closeH)
   {
      if(dt.hour < openH && dt.hour >= closeH) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
bool CheckRangeFilter()
{
   if(InpOpenRangePips <= 0 || InpMaxDailyRange <= 0)
      return true;

   int dayOfYear = 0;
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      dayOfYear = dt.day_of_year;
   }

   double openPrice = 0;
   int bars = iBars(g_symbol, PERIOD_CURRENT);
   for(int i = 0; i < bars; i++)
   {
      datetime t = iTime(g_symbol, PERIOD_CURRENT, i);
      MqlDateTime dt;
      TimeToStruct(t, dt);
      if(dt.day_of_year == dayOfYear)
         openPrice = iOpen(g_symbol, PERIOD_CURRENT, i);
      else break;
   }

   if(openPrice == 0) return false;

   double upperBound  = openPrice + InpOpenRangePips * g_point;
   double lowerBound  = openPrice - InpOpenRangePips * g_point;
   double maxUpper    = upperBound + InpMaxDailyRange * g_point;
   double maxLower    = lowerBound - InpMaxDailyRange * g_point;

   UpdateQuotes();
   return (g_bid > upperBound && g_bid < maxUpper) ||
          (g_bid < lowerBound && g_bid > maxLower);
}

//+------------------------------------------------------------------+
bool CheckRegimeFilter()
{
   if(!InpFilterRegime) return true;

   g_regime.Get(1);
   double hurst = g_regime.GetLastHurst();
   double conf  = g_regime.GetConfidence();

   bool trending    = g_regime.isTrending();
   bool meanRev     = g_regime.isMeanReverting();
   bool quiet       = (hurst >= 0.48 && hurst <= 0.52 && conf >= 0.60);
   bool erratic     = (conf < 0.60);
   bool chaos       = g_regime.IsChaosRegime();

   if(chaos && !InpRegimeErratic) return false;

   return (trending && InpRegimeTrending) ||
          (meanRev  && InpRegimeMeanRev)  ||
          (quiet    && InpRegimeQuiet)    ||
          (erratic  && InpRegimeErratic);
}

//+------------------------------------------------------------------+
bool CheckMacroFilter()
{
   if(!InpFilterMacro) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(InpMacroCheckVIX)
   {
      double vix = g_risk.GetVIX();
      if(vix > 0 && vix > InpMacroMaxVIX) return false;
   }

   if(InpMacroNYsession)
   {
      if(dt.hour >= 16 || dt.hour < 2) return false;
   }

   if(InpMacroNoFriday && dt.day_of_week == 5) return false;

   return true;
}

//+------------------------------------------------------------------+
void DrawInfoPanel()
{
   ObjectCreate(0, "j", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "j", OBJPROP_CORNER, 4);
   ObjectSetInteger(0, "j", OBJPROP_XDISTANCE, 4);
   ObjectSetInteger(0, "j", OBJPROP_YDISTANCE, 10);
   ObjectSetString(0, "j", OBJPROP_TEXT, "ALX FX Scalper");
   ObjectSetInteger(0, "j", OBJPROP_FONTSIZE, 19);
   ObjectSetString(0, "j", OBJPROP_FONT, "Times New Roman Bold");
   ObjectSetInteger(0, "j", OBJPROP_COLOR, 65280);

   string info = "\n================================";
   info += "\nACC INFORMATION:";
   info += "\n  Account : " + IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN));
   info += "\n  Leverage: " + IntegerToString((int)AccountInfoInteger(ACCOUNT_LEVERAGE));
   info += "\n  Currency: " + AccountInfoString(ACCOUNT_CURRENCY);
   info += "\n  Equity  : " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2);
   info += "\n  Balance : " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2);
   info += "\n  Spread  : " + IntegerToString(g_spread);
   Comment("\n", info);
}

//+------------------------------------------------------------------+
//| Main processing loop called by OnTimer                          |
//+------------------------------------------------------------------+
void Process()
{
   UpdateQuotes();

   // Object cleanup
   int objTotal = ObjectsTotal(0, -1, -1);
   for(int i = objTotal - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(ObjectGetInteger(0, name, OBJPROP_TIME) > 0)
      {
         datetime objTime = (datetime)ObjectGetInteger(0, name, OBJPROP_TIME);
         if(objTime < iTime(g_symbol, PERIOD_CURRENT, 0))
            ObjectDelete(0, name);
      }
   }

   DrawInfoPanel();

   // Daily Target check
   if(InpUseDailyTarget)
   {
      double dailyPnl = CalculateDailyPnL();
      if(dailyPnl >= InpDailyTarget)
      {
         CloseAllByType(true, true);
         Print("Daily target reached: ", DoubleToString(dailyPnl, 2));
         return;
      }
   }

   // Hidden TP check
   if(InpHiddenTP)
   {
      double totalPnl = GetTotalPositionProfit();
      if(totalPnl >= InpHiddenTPAmount)
      {
         CloseAllByType(true, true);
         Print("Hidden TP reached: ", DoubleToString(totalPnl, 2));
         return;
      }
   }

   // Risk Manager daily limit check
   g_risk_mgr.Update();
   if(g_risk_mgr.IsBlocked())
   {
      g_isLimit = true;
      CloseAllByType(true, true);
      Print("RiskManager blocked: ", g_risk_mgr.GetBlockReason());
      return;
   }
   g_risk_mgr.ManagePositions();

   // Reset order counter when averaging threshold met
   if(g_orderCount >= InpAveraging)
      g_orderCount = -2;

   // Count positions and direction
   int buyCount  = CountPositionsByType(POSITION_TYPE_BUY);
   int sellCount = CountPositionsByType(POSITION_TYPE_SELL);
   g_tradeCount  = buyCount + sellCount;
   g_hasBuy      = (buyCount > 0);
   g_hasSell     = (sellCount > 0);
   g_lastBuyPrice  = GetLastPriceByType(POSITION_TYPE_BUY);
   g_lastSellPrice = GetLastPriceByType(POSITION_TYPE_SELL);

   // Reset step if no positions
   if(g_tradeCount == 0)
   {
      if(g_prevBalance != AccountInfoDouble(ACCOUNT_BALANCE))
      {
         g_prevBalance = 0;
         g_baseLot = InpLot;
      }
      g_stepReached = true;
      g_lastBuyPrice  = 0;
      g_lastSellPrice = 0;
      g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }

   // Check step distance for averaging
   if(g_tradeCount > 0 && g_tradeCount <= InpMaxTrades)
   {
      g_stepReached = false;
      if(g_hasBuy)
      {
         double dist = (g_lastBuyPrice - g_ask) / g_point;
         if(dist >= g_stepPips) g_stepReached = true;
      }
      if(g_hasSell)
      {
         double dist = (g_bid - g_lastSellPrice) / g_point;
         if(dist >= g_stepPips) g_stepReached = true;
      }
   }

   // Enter new positions (averaging)
   if(g_stepReached && g_tradeCount > 0 && g_tradeCount <= InpMaxTrades)
   {
      if(g_hasSell && g_tradeCount <= InpMaxTrades)
      {
         if(g_orderCount == -2)
            g_martinLot = CalculateMartingaleLot(g_tradeCount);
         if(g_martinLot > 0)
         {
            if(SendSellOrder(g_martinLot))
            {
               g_lastSellPrice = GetLastPriceByType(POSITION_TYPE_SELL);
               g_stepReached = false;
               g_modified = true;
            }
         }
      }
      if(g_hasBuy && g_tradeCount <= InpMaxTrades)
      {
         if(g_orderCount == -2)
            g_martinLot = CalculateMartingaleLot(g_tradeCount);
         if(g_martinLot > 0)
         {
            if(SendBuyOrder(g_martinLot))
            {
               g_lastBuyPrice = GetLastPriceByType(POSITION_TYPE_BUY);
               g_stepReached = false;
               g_modified = true;
            }
         }
      }
   }

   // Entry for first trade
   if(g_tradeCount < 1 && !g_isLimit && g_risk_mgr.CanOpenNewOrder() && CheckRegimeFilter() && CheckMacroFilter() && CheckTimeFilter() && CheckRangeFilter())
   {
      double close2 = iClose(g_symbol, PERIOD_CURRENT, 2);
      double close1 = iClose(g_symbol, PERIOD_CURRENT, 1);
      bool bearish = (close2 > close1);

      if(g_orderCount == -2)
      {
         g_martinLot = CalculateMartingaleLot(0);
         g_baseLot   = g_martinLot;
      }

      if(g_martinLot > 0)
      {
         UpdateQuotes();
         if(bearish)
         {
            if(SendSellOrder(g_martinLot))
            {
               g_lastSellPrice = GetLastPriceByType(POSITION_TYPE_SELL);
               g_stepReached = false;
               g_modified = true;
               g_prevBalance = AccountInfoDouble(ACCOUNT_BALANCE);
               if(InpUseTimeout)
                  g_timeoutEnd = TimeCurrent() + InpTimeoutHours * 3600;
            }
         }
         else
         {
            if(SendBuyOrder(g_martinLot))
            {
               g_lastBuyPrice = GetLastPriceByType(POSITION_TYPE_BUY);
               g_stepReached = false;
               g_modified = true;
               g_prevBalance = AccountInfoDouble(ACCOUNT_BALANCE);
               if(InpUseTimeout)
                  g_timeoutEnd = TimeCurrent() + InpTimeoutHours * 3600;
            }
         }
      }
   }

   // Apply SL/TP to all positions after modification
   if(g_modified)
   {
      ApplySLTPToAll();
      g_modified = false;
   }

   // Equity Stop check
   if(InpUseEquityStop)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(g_tradeCount == 0)
         g_peakEquity = equity;
      else if(equity > g_peakEquity)
         g_peakEquity = equity;

      double floatingPnL = GetTotalPositionProfit();
      if(floatingPnL < 0)
      {
         double lossPct = MathAbs(floatingPnL) / g_peakEquity;
         if(lossPct > (InpEquityRiskPct / 100.0))
         {
            CloseAllByType(true, true);
            Print("Equity stop triggered. Loss: ", DoubleToString(floatingPnL, 2));
         }
      }
   }

   // Timeout close
   if(g_timeoutEnd > 0 && TimeCurrent() >= g_timeoutEnd)
   {
      CloseAllByType(true, true);
      Print("Closed all due to timeout");
      g_timeoutEnd = 0;
   }
}