//+------------------------------------------------------------------+
//|                                            Ilan_RSI_MACD.mq5       |
//|                           Refactored from MQ4 by ALXQuant          |
//|                           Strategy: Grid/Mean Reversal (MACD+RSI)  |
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
input double          InpLotExponent      = 3.37;         // Lot Exponent
input int             InpMaxTrades        = 10;           // Max Grid Trades
input double          InpTakeProfit       = 10.0;         // Take Profit (points)
input double          InpPipStep          = 30.0;         // Pip Step
input double          InpStoploss         = 5000.0;       // Stop Loss (points)

input group           "=== RSI Filter ==="
input int             InpRsiUnderBuy      = 30;           // RSI Oversold Level (Buy)
input int             InpRsiOverSell      = 70;           // RSI Overbought Level (Sell)

input group           "=== Equity Protection ==="
input bool            InpUseEquityStop    = false;        // Use Equity Stop
input double          InpTotalEquityRisk  = 20.0;         // Equity Risk %

input group           "=== Trailing Stop ==="
input bool            InpUseTrailingStop  = false;        // Use Trailing Stop
input double          InpTrailStart       = 100.0;        // Trail Start (points)
input double          InpTrailStopVal     = 100.0;        // Trail Stop (points)

input group           "=== Timeout ==="
input bool            InpUseTimeOut       = false;        // Use Trade Timeout
input double          InpMaxTradeOpenHours = 48.0;        // Max Open Hours

input group           "=== Common ==="
input int             InpMagicNumber      = 54321;        // Magic Number

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         m_trade;
CPositionInfo  m_position;
CSymbolInfo    m_symbol;
CAccountInfo   m_account;

datetime g_last_bar_time = 0;

// Grid state
double g_average_price;
double g_price_target;
int    g_num_trades = 0;
double g_prev_equity = 0;
double g_account_equity_high = 0;
bool   g_long_trade = false;
bool   g_short_trade = false;
bool   g_new_orders_placed = false;
datetime g_expiration = 0;

// Indicator handles
int g_handle_macd;
int g_handle_rsi;

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

   // Create indicator handles
   g_handle_macd = iMACD(_Symbol, PERIOD_CURRENT, 12, 26, 9, PRICE_CLOSE);
   g_handle_rsi  = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);

   if(g_handle_macd == INVALID_HANDLE || g_handle_rsi == INVALID_HANDLE)
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
   IndicatorRelease(g_handle_macd);
   IndicatorRelease(g_handle_rsi);
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

   // Timeout exit
   if(InpUseTimeOut && TimeCurrent() >= g_expiration && g_expiration > 0)
   {
      CloseAllPositions();
      Print("Closed All due to Timeout");
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

   // Get MACD values
   double macd_current  = GetIndicatorValue(g_handle_macd, 0, 0);
   double macd_previous = GetIndicatorValue(g_handle_macd, 1, 0);
   double sig_current   = GetIndicatorValue(g_handle_macd, 0, 1);
   double sig_previous  = GetIndicatorValue(g_handle_macd, 1, 1);

   // Get RSI value
   double rsi_val = GetIndicatorValue(g_handle_rsi, 1);

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
         if(m_position.TakeProfit() == 0) g_new_orders_placed = true;
         g_long_trade = true;
         break;
      }
      if(m_position.PositionType() == POSITION_TYPE_SELL)
      {
         if(m_position.TakeProfit() == 0) g_new_orders_placed = true;
         g_short_trade = true;
         break;
      }
   }

   // Grid logic
   bool trade_now = false;
   double last_buy_price = FindLastBuyPrice();
   double last_sell_price = FindLastSellPrice();

   if(total > 0 && total <= InpMaxTrades)
   {
      if(g_long_trade && last_buy_price - m_symbol.Ask() >= InpPipStep * m_symbol.Point())
         trade_now = true;
      if(g_short_trade && m_symbol.Bid() - last_sell_price >= InpPipStep * m_symbol.Point())
         trade_now = true;
   }

   if(total < 1)
   {
      g_short_trade = false;
      g_long_trade = false;
      trade_now = true;
   }

   // Open grid orders
   if(trade_now)
   {
      last_buy_price = FindLastBuyPrice();
      last_sell_price = FindLastSellPrice();

      if(g_short_trade)
      {
         g_num_trades = total;
         double lots = NormalizeDouble(InpLots * MathPow(InpLotExponent, g_num_trades), 2);
         if(m_trade.Sell(lots, _Symbol, 0, 0, 0, "Ilan_Sell_" + IntegerToString(g_num_trades)))
         {
            Print("SELL grid opened: ", m_trade.ResultPrice());
            last_sell_price = FindLastSellPrice();
         }
         else
         {
            Print("Error: ", GetLastError());
            return;
         }
         trade_now = false;
         g_new_orders_placed = true;
      }
      else if(g_long_trade)
      {
         g_num_trades = total;
         double lots = NormalizeDouble(InpLots * MathPow(InpLotExponent, g_num_trades), 2);
         if(m_trade.Buy(lots, _Symbol, 0, 0, 0, "Ilan_Buy_" + IntegerToString(g_num_trades)))
         {
            Print("BUY grid opened: ", m_trade.ResultPrice());
            last_buy_price = FindLastBuyPrice();
         }
         else
         {
            Print("Error: ", GetLastError());
            return;
         }
         trade_now = false;
         g_new_orders_placed = true;
      }
   }

   // Initial entry with MACD + RSI
   if(trade_now && total < 1)
   {
      double prev_close = iClose(_Symbol, PERIOD_CURRENT, 2);
      double curr_close = iClose(_Symbol, PERIOD_CURRENT, 1);
      double sell_limit = m_symbol.Bid();
      double buy_limit = m_symbol.Ask();

      g_num_trades = total;
      double lots = NormalizeDouble(InpLots * MathPow(InpLotExponent, g_num_trades), 2);

      // Sell signal: MACD bearish cross + RSI > 30
      if(macd_current > 0 && macd_current < sig_current &&
         macd_previous > sig_previous && rsi_val > InpRsiUnderBuy)
      {
         if(m_trade.Sell(lots, _Symbol, 0, 0, 0, "Ilan_Init_Sell"))
         {
            Print("Initial SELL opened: ", m_trade.ResultPrice());
            g_new_orders_placed = true;
         }
         else
         {
            Print("Error: ", GetLastError());
            return;
         }
      }

      // Buy signal: MACD bullish cross + RSI < 70
      if(macd_current < 0 && macd_current > sig_current &&
         macd_previous < sig_previous && rsi_val < InpRsiOverSell)
      {
         if(m_trade.Buy(lots, _Symbol, 0, 0, 0, "Ilan_Init_Buy"))
         {
            Print("Initial BUY opened: ", m_trade.ResultPrice());
            g_new_orders_placed = true;
         }
         else
         {
            Print("Error: ", GetLastError());
            return;
         }
      }

      if(g_new_orders_placed)
         g_expiration = TimeCurrent() + (long)(InpMaxTradeOpenHours * 3600);

      trade_now = false;
   }

   // Calculate average price and update targets
   CalculateAveragePrice();
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

   // Update TP for all positions
   if(g_average_price > 0 && g_new_orders_placed)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!m_position.SelectByIndex(i)) continue;
         if(m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber) continue;

         ulong ticket = m_position.Ticket();

         double new_tp;
         if(m_position.PositionType() == POSITION_TYPE_BUY)
            new_tp = g_average_price + InpTakeProfit * m_symbol.Point();
         else
            new_tp = g_average_price - InpTakeProfit * m_symbol.Point();

         new_tp = NormalizeDouble(new_tp, m_symbol.Digits());

         m_trade.PositionModify(ticket, m_position.StopLoss(), new_tp);
      }
      g_new_orders_placed = false;
   }
}

//+------------------------------------------------------------------+
//| Get indicator value                                               |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle, int shift, int buffer = 0)
{
   double value[1];
   if(CopyBuffer(handle, buffer, shift, 1, value) == 1)
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
