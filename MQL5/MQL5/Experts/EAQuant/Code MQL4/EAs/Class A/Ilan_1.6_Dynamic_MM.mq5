//+------------------------------------------------------------------+
//|                                          Ilan_1.6_Dynamic_MM.mq5   |
//|                           Refactored from MQ4 by ALXQuant          |
//|                           Original: Ilan 1.6 Dynamic MM            |
//|                           Strategy: Grid/Mean Reversal (RSI-based) |
//+------------------------------------------------------------------+
#property copyright "ALXQuant - Refactored"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group           "=== Trade Settings ==="
input double          InpLots             = 0.1;          // Default Lot Size
input double          InpRisk             = 0;            // Risk (0=fixed lots, 0.01=1%)
input int             InpBalans           = 1000;         // Balance for lot calculation
input double          InpLotExponent      = 1.4;          // Lot Exponent per grid level
input int             InpMaxTrades        = 10;           // Max Grid Trades
input double          InpTakeProfit       = 10.0;         // Take Profit (points)
input double          InpStoploss         = 500.0;        // Stop Loss (points)

input group           "=== PipStep ==="
input bool            InpDynamicPips      = true;         // Use Dynamic PipStep
input int             InpDefaultPips      = 12;           // Default PipStep
input int             InpGlubina          = 24;           // Lookback for Dynamic
input int             InpDEL              = 3;            // DEL factor

input group           "=== RSI Filter ==="
input ENUM_TIMEFRAMES InpRsiTimeframe     = PERIOD_M5;    // RSI Timeframe
input int             InpRsiPeriod        = 14;           // RSI Period
input double          InpRsiMinimum       = 30.0;         // RSI Minimum
input double          InpRsiMaximum       = 70.0;         // RSI Maximum

input group           "=== CCI Timeout ==="
input double          InpCCIDrop          = 1000;         // CCI Exit Threshold

input group           "=== Equity Protection ==="
input bool            InpUseEquityStop    = false;        // Use Equity Stop
input double          InpTotalEquityRisk  = 20.0;         // Equity Risk %

input group           "=== Trailing Stop ==="
input bool            InpUseTrailingStop  = false;        // Use Trailing Stop
input double          InpTrailStart       = 10.0;         // Trail Start (points)
input double          InpTrailStopVal     = 10.0;         // Trail Stop (points)

input group           "=== Timeout ==="
input bool            InpUseTimeOut       = false;        // Use Trade Timeout
input double          InpMaxTradeOpenHours = 48.0;        // Max Open Hours

input group           "=== Common ==="
input int             InpMagicNumber      = 2222;         // Magic Number

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         m_trade;
CPositionInfo  m_position;
CSymbolInfo    m_symbol;
CAccountInfo   m_account;

double g_pips_point;
int    g_pips_digits;
datetime g_last_bar_time = 0;

// Grid state
double g_average_price;
double g_price_target;
int    g_num_trades = 0;
double g_iLots;
double g_prev_equity = 0;
double g_account_equity_high = 0;
bool   g_long_trade = false;
bool   g_short_trade = false;

// Indicator handles
int g_handle_rsi;
int g_handle_cci;

//+------------------------------------------------------------------+
//| Initialization                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!m_symbol.Name(_Symbol))
   {
      Print("Failed to initialize symbol info");
      return(INIT_FAILED);
   }

   // Pips calculation
   double ticksize = m_symbol.TickSize();
   if(ticksize == 0.00001 || ticksize == 0.001)
      g_pips_point = ticksize * 10;
   else
      g_pips_point = ticksize;
   g_pips_digits = (int)MathMax(0, -MathLog10(g_pips_point));

   // Create indicator handles
   g_handle_rsi = iRSI(_Symbol, InpRsiTimeframe, InpRsiPeriod, PRICE_CLOSE);
   g_handle_cci = iCCI(_Symbol, PERIOD_M15, 55, PRICE_CLOSE);

   if(g_handle_rsi == INVALID_HANDLE || g_handle_cci == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }

   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(30);
   m_trade.SetTypeFillingBySymbol(_Symbol);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(g_handle_rsi);
   IndicatorRelease(g_handle_cci);
}

//+------------------------------------------------------------------+
//| Main Tick Function                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   m_symbol.RefreshRates();

   // Trailing stop
   if(InpUseTrailingStop)
      TrailingAlls(InpTrailStart, InpTrailStopVal, g_average_price);

   // CCI timeout exit
   double cci_val = GetIndicatorValue(g_handle_cci, 0);
   if(InpUseTimeOut && ((cci_val > InpCCIDrop && g_short_trade) || (cci_val < -InpCCIDrop && g_long_trade)))
   {
      CloseAllPositions();
      Print("Closed All due to CCI Timeout");
      return;
   }

   // New bar check
   datetime bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bar_time == g_last_bar_time) return;
   g_last_bar_time = bar_time;

   // Equity stop
   if(InpUseEquityStop)
   {
      double current_profit = CalculateProfit();
      double equity_high = AccountEquityHigh();
      if(current_profit < 0.0 && MathAbs(current_profit) > InpTotalEquityRisk / 100.0 * equity_high)
      {
         CloseAllPositions();
         Print("Closed All due to Equity Stop");
         return;
      }
   }

   // Count trades
   int total = CountTrades();

   // Update direction flags
   g_long_trade = false;
   g_short_trade = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber) continue;

      if(m_position.PositionType() == POSITION_TYPE_BUY)
      {
         g_long_trade = true;
         break;
      }
      if(m_position.PositionType() == POSITION_TYPE_SELL)
      {
         g_short_trade = true;
         break;
      }
   }

   // Calculate dynamic pipstep
   int pipstep = CalculatePipStep();

   // Grid logic
   bool trade_now = false;
   double last_buy_price = FindLastBuyPrice();
   double last_sell_price = FindLastSellPrice();

   if(total > 0 && total <= InpMaxTrades)
   {
      if(g_long_trade && last_buy_price - m_symbol.Ask() >= pipstep * m_symbol.Point())
         trade_now = true;
      if(g_short_trade && m_symbol.Bid() - last_sell_price >= pipstep * m_symbol.Point())
         trade_now = true;
   }

   if(total < 1)
   {
      g_long_trade = false;
      g_short_trade = false;
      trade_now = true;
   }

   // Open new grid orders
   if(trade_now)
   {
      if(g_short_trade)
      {
         g_num_trades = total;
         g_iLots = NormalizeDouble(CalculateLot() * MathPow(InpLotExponent, g_num_trades), 2);
         if(m_trade.Sell(g_iLots, _Symbol, 0, 0, 0, "Ilan_Sell_" + IntegerToString(g_num_trades)))
         {
            Print("SELL grid opened: ", m_trade.ResultPrice());
            last_sell_price = FindLastSellPrice();
         }
         else
            Print("Error opening SELL: ", GetLastError());
      }
      else if(g_long_trade)
      {
         g_num_trades = total;
         g_iLots = NormalizeDouble(CalculateLot() * MathPow(InpLotExponent, g_num_trades), 2);
         if(m_trade.Buy(g_iLots, _Symbol, 0, 0, 0, "Ilan_Buy_" + IntegerToString(g_num_trades)))
         {
            Print("BUY grid opened: ", m_trade.ResultPrice());
            last_buy_price = FindLastBuyPrice();
         }
         else
            Print("Error opening BUY: ", GetLastError());
      }
   }

   // Initial entry (no positions)
   if(trade_now && total < 1)
   {
      double prev_close = iClose(_Symbol, PERIOD_CURRENT, 2);
      double curr_close = iClose(_Symbol, PERIOD_CURRENT, 1);
      g_num_trades = total;
      g_iLots = NormalizeDouble(CalculateLot() * MathPow(InpLotExponent, g_num_trades), 2);
      double rsi_val = GetIndicatorValue(g_handle_rsi, 1);

      if(prev_close > curr_close)
      {
         // Sell signal
         if(rsi_val > InpRsiMinimum)
         {
            if(m_trade.Sell(g_iLots, _Symbol, 0, 0, 0, "Ilan_Init_Sell"))
               Print("Initial SELL opened: ", m_trade.ResultPrice());
            else
               Print("Error opening initial SELL: ", GetLastError());
         }
      }
      else
      {
         // Buy signal
         if(rsi_val < InpRsiMaximum)
         {
            if(m_trade.Buy(g_iLots, _Symbol, 0, 0, 0, "Ilan_Init_Buy"))
               Print("Initial BUY opened: ", m_trade.ResultPrice());
            else
               Print("Error opening initial BUY: ", GetLastError());
         }
      }
   }

   // Calculate average price and update targets
   CalculateAveragePrice();
}

//+------------------------------------------------------------------+
//| Calculate Dynamic PipStep                                         |
//+------------------------------------------------------------------+
int CalculatePipStep()
{
   if(!InpDynamicPips)
      return InpDefaultPips;

   double high_val[];
   double low_val[];
   ArraySetAsSeries(high_val, true);
   ArraySetAsSeries(low_val, true);

   CopyHigh(_Symbol, PERIOD_CURRENT, 1, InpGlubina, high_val);
   CopyLow(_Symbol, PERIOD_CURRENT, 1, InpGlubina, low_val);

   double highest = high_val[ArrayMaximum(high_val)];
   double lowest  = low_val[ArrayMinimum(low_val)];

   int pipstep = (int)NormalizeDouble((highest - lowest) / InpDEL / m_symbol.Point(), 0);

   int min_pips = InpDefaultPips / InpDEL;
   int max_pips = InpDefaultPips * InpDEL;

   if(pipstep < min_pips) pipstep = min_pips;
   if(pipstep > max_pips) pipstep = max_pips;

   return pipstep;
}

//+------------------------------------------------------------------+
//| Calculate Average Price and Update Targets                        |
//+------------------------------------------------------------------+
void CalculateAveragePrice()
{
   int total = CountTrades();
   if(total == 0)
   {
      g_average_price = 0;
      return;
   }

   double sum = 0;
   double count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber) continue;

      sum += m_position.PriceOpen() * m_position.Volume();
      count += m_position.Volume();
   }

   if(count > 0)
      g_average_price = NormalizeDouble(sum / count, m_symbol.Digits());
   else
      g_average_price = 0;

   // Update TP/SL for all positions
   if(g_average_price > 0)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!m_position.SelectByIndex(i)) continue;
         if(m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber) continue;

         ulong ticket = m_position.Ticket();
         double current_tp = m_position.TakeProfit();

         double new_tp;
         if(m_position.PositionType() == POSITION_TYPE_BUY)
            new_tp = g_average_price + InpTakeProfit * m_symbol.Point();
         else
            new_tp = g_average_price - InpTakeProfit * m_symbol.Point();

         new_tp = NormalizeDouble(new_tp, m_symbol.Digits());

         if(MathAbs(current_tp - new_tp) > m_symbol.Point())
            m_trade.PositionModify(ticket, m_position.StopLoss(), new_tp);
      }
   }
}

//+------------------------------------------------------------------+
//| Get indicator value                                               |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle, int shift)
{
   double value[1];
   if(CopyBuffer(handle, 0, shift, 1, value) == 1)
      return value[0];
   return 0;
}

//+------------------------------------------------------------------+
//| Count trades                                                      |
//+------------------------------------------------------------------+
int CountTrades()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Find Last Buy Price                                               |
//+------------------------------------------------------------------+
double FindLastBuyPrice()
{
   double price = 0;
   int highest_ticket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber) continue;
      if(m_position.PositionType() != POSITION_TYPE_BUY) continue;

      int ticket = (int)m_position.Ticket();
      if(ticket > highest_ticket)
      {
         price = m_position.PriceOpen();
         highest_ticket = ticket;
      }
   }
   return price;
}

//+------------------------------------------------------------------+
//| Find Last Sell Price                                              |
//+------------------------------------------------------------------+
double FindLastSellPrice()
{
   double price = 0;
   int highest_ticket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber) continue;
      if(m_position.PositionType() != POSITION_TYPE_SELL) continue;

      int ticket = (int)m_position.Ticket();
      if(ticket > highest_ticket)
      {
         price = m_position.PriceOpen();
         highest_ticket = ticket;
      }
   }
   return price;
}

//+------------------------------------------------------------------+
//| Calculate Profit                                                  |
//+------------------------------------------------------------------+
double CalculateProfit()
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber) continue;
      profit += m_position.Profit() + m_position.Swap();
   }
   return profit;
}

//+------------------------------------------------------------------+
//| Account Equity High                                               |
//+------------------------------------------------------------------+
double AccountEquityHigh()
{
   if(CountTrades() == 0)
      g_account_equity_high = m_account.Equity();

   if(g_account_equity_high < g_prev_equity)
      g_account_equity_high = g_prev_equity;
   else
      g_account_equity_high = m_account.Equity();

   g_prev_equity = m_account.Equity();
   return g_account_equity_high;
}

//+------------------------------------------------------------------+
//| Trailing All                                                      |
//+------------------------------------------------------------------+
void TrailingAlls(double trail_start, double trail_stop, double avg_price)
{
   if(trail_stop == 0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber) continue;

      ulong ticket = m_position.Ticket();
      double current_sl = m_position.StopLoss();
      double current_tp = m_position.TakeProfit();
      double open_price = m_position.PriceOpen();

      if(m_position.PositionType() == POSITION_TYPE_BUY)
      {
         int profit_pts = (int)NormalizeDouble((m_symbol.Bid() - avg_price) / m_symbol.Point(), 0);
         if(profit_pts < trail_start) continue;

         double new_sl = m_symbol.Bid() - trail_stop * m_symbol.Point();
         new_sl = NormalizeDouble(new_sl, m_symbol.Digits());

         if(current_sl == 0 || new_sl > current_sl)
            m_trade.PositionModify(ticket, new_sl, current_tp);
      }
      else if(m_position.PositionType() == POSITION_TYPE_SELL)
      {
         int profit_pts = (int)NormalizeDouble((avg_price - m_symbol.Ask()) / m_symbol.Point(), 0);
         if(profit_pts < trail_start) continue;

         double new_sl = m_symbol.Ask() + trail_stop * m_symbol.Point();
         new_sl = NormalizeDouble(new_sl, m_symbol.Digits());

         if(current_sl == 0 || new_sl < current_sl)
            m_trade.PositionModify(ticket, new_sl, current_tp);
      }
   }
}

//+------------------------------------------------------------------+
//| Close All Positions                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber) continue;

      ulong ticket = m_position.Ticket();
      m_trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size                                                |
//+------------------------------------------------------------------+
double CalculateLot()
{
   double lot = InpLots;

   if(InpRisk > 0)
   {
      lot = NormalizeDouble(m_account.Balance() * InpRisk / 100.0 / InpBalans, 2);
   }

   double min_lot = m_symbol.LotsMin();
   double max_lot = m_symbol.LotsMax();

   lot = MathMax(lot, min_lot);
   lot = MathMin(lot, max_lot);

   return NormalizeDouble(lot, 2);
}
//+------------------------------------------------------------------+
