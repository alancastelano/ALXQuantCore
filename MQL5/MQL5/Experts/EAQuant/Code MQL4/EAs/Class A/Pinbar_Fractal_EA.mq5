//+------------------------------------------------------------------+
//|                                          Pinbar_Fractal_EA.mq5    |
//|                           Refactored from MQ4 by ALXQuant         |
//|                           Original: AHARON TZADIK                 |
//+------------------------------------------------------------------+
#property copyright "ALXQuant - Refactored from AHARON TZADIK"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group           "=== Trade Management ==="
input double          InpLots              = 0.01;         // Lot Size
input double          InpMaximumRisk       = 0.02;         // Maximum Risk %
input int             InpDecreaseFactor    = 3;            // Decrease Factor
input double          InpStopLoss          = 20;           // Stop Loss (pips)
input double          InpTakeProfit        = 50;           // Take Profit (pips)
input double          InpTrailingStop      = 40;           // Trailing Stop (pips)
input int             InpMagicNumber       = 1234;         // Magic Number

input group           "=== Moving Averages ==="
input int             InpFastMA            = 6;            // Fast MA Period
input int             InpSlowMA            = 85;           // Slow MA Period

input group           "=== Break Even ==="
input bool            InpUseBreakEven      = true;         // Use Break Even
input double          InpBreakEvenPips     = 10;           // When to Move BE (pips)
input double          InpBreakEvenSLPips   = 5;            // BE Stop Loss Distance

input group           "=== Fractal Settings ==="
input int             InpFractalsLimit     = 200;          // Fractals Lookback Limit

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

// Indicator handles
int g_handle_bb;
int g_handle_macd;
int g_handle_fast_ma;
int g_handle_slow_ma;
int g_handle_atr;
int g_handle_fractals_upper;
int g_handle_fractals_lower;

// Higher timeframe
 ENUM_TIMEFRAMES g_higher_tf;

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

   // Determine higher timeframe
   g_higher_tf = GetHigherTimeframe();

   // Create indicator handles
   g_handle_bb       = iBands(_Symbol, PERIOD_CURRENT, 20, 0, 2, PRICE_CLOSE);
   g_handle_macd     = iMACD(_Symbol, PERIOD_CURRENT, 12, 26, 9, PRICE_CLOSE);
   g_handle_fast_ma  = iMA(_Symbol, PERIOD_CURRENT, InpFastMA, 0, MODE_LWMA, PRICE_TYPICAL);
   g_handle_slow_ma  = iMA(_Symbol, PERIOD_CURRENT, InpSlowMA, 0, MODE_LWMA, PRICE_TYPICAL);
   g_handle_atr      = iATR(_Symbol, PERIOD_CURRENT, 14);
   g_handle_fractals_upper = iFractals(_Symbol, g_higher_tf);
   g_handle_fractals_lower = iFractals(_Symbol, g_higher_tf);

   if(g_handle_bb == INVALID_HANDLE || g_handle_fast_ma == INVALID_HANDLE ||
      g_handle_slow_ma == INVALID_HANDLE)
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
   IndicatorRelease(g_handle_bb);
   IndicatorRelease(g_handle_macd);
   IndicatorRelease(g_handle_fast_ma);
   IndicatorRelease(g_handle_slow_ma);
   IndicatorRelease(g_handle_atr);
   if(g_handle_fractals_upper != INVALID_HANDLE) IndicatorRelease(g_handle_fractals_upper);
   if(g_handle_fractals_lower != INVALID_HANDLE) IndicatorRelease(g_handle_fractals_lower);
}

//+------------------------------------------------------------------+
//| Main Tick Function                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   m_symbol.RefreshRates();

   // Break even
   if(InpUseBreakEven)
      MoveToBreakEven();

   // Trailing stop
   TrailStop();

   // Pre-checks
   if(Bars(_Symbol, PERIOD_CURRENT) < 100) return;

   // Get indicator values
   double bb_upper = GetIndicatorValue(g_handle_bb, 1, 1); // upper band
   double bb_lower = GetIndicatorValue(g_handle_bb, 1, 2); // lower band
   double bb_main  = GetIndicatorValue(g_handle_bb, 1, 0); // main
   double macd_main   = GetIndicatorValue(g_handle_macd, 1, 0);
   double macd_signal = GetIndicatorValue(g_handle_macd, 1, 1);
   double fast_ma     = GetIndicatorValue(g_handle_fast_ma, 0, 0);
   double slow_ma     = GetIndicatorValue(g_handle_slow_ma, 0, 0);
   double atr         = GetIndicatorValue(g_handle_atr, 0, 0);

   if(fast_ma == 0 || slow_ma == 0) return;

   // Get higher timeframe OHLC
   double htf_open  = iOpen(_Symbol, g_higher_tf, 1);
   double htf_close = iClose(_Symbol, g_higher_tf, 1);
   double htf_high  = iHigh(_Symbol, g_higher_tf, 1);
   double htf_low   = iLow(_Symbol, g_higher_tf, 1);

   // Count current positions
   int current_positions = CountPositions();

   // Exit logic
   if(current_positions > 0)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(!m_position.SelectByIndex(i)) continue;
         if(m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber) continue;

         ulong ticket = m_position.Ticket();
         double open_price = m_position.PriceOpen();

         if(m_position.PositionType() == POSITION_TYPE_BUY)
         {
            bool close_signal = (m_symbol.Bid() < open_price - atr) ||
                               (macd_main > 0 && macd_main < macd_signal) ||
                               (macd_main < 0 && MathAbs(macd_main) > MathAbs(macd_signal)) ||
                               (m_symbol.Bid() >= bb_upper);
            if(close_signal)
               m_trade.PositionClose(ticket);
         }
         else if(m_position.PositionType() == POSITION_TYPE_SELL)
         {
            bool close_signal = (m_symbol.Ask() > open_price + atr) ||
                               (macd_main > 0 && macd_main > macd_signal) ||
                               (macd_main < 0 && MathAbs(macd_main) < MathAbs(macd_signal)) ||
                               (m_symbol.Ask() <= bb_lower);
            if(close_signal)
               m_trade.PositionClose(ticket);
         }
      }
      return;
   }

   // Entry logic - only on new bar
   datetime bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bar_time == g_last_bar_time) return;
   g_last_bar_time = bar_time;

   // Pinbar / Hanging Man detection on higher TF
   double body = MathAbs(htf_close - htf_open);
   double total_range = htf_high - htf_low;
   double upper_wick = htf_high - MathMax(htf_open, htf_close);
   double lower_wick = MathMin(htf_open, htf_close) - htf_low;

   bool is_pinbar_buy  = (total_range > 0 && lower_wick / total_range >= 0.50);
   bool is_pinbar_sell = (total_range > 0 && upper_wick / total_range >= 0.50);

   // Fractal check
   int fractal_signal = FindFractals();

   // BUY signal
   if((is_pinbar_buy || is_pinbar_sell) && (fractal_signal == 1 || fractal_signal == 2))
   {
      if(is_pinbar_buy && fast_ma > slow_ma && fractal_signal >= 1)
      {
         double sl = m_symbol.Ask() - InpStopLoss * g_pips_point;
         double tp = m_symbol.Ask() + InpTakeProfit * g_pips_point;
         sl = AdjustPrice(sl);
         tp = AdjustPrice(tp);

         double lots = NormalizeLot(CalculateLot());
         if(lots > 0 && m_trade.Buy(lots, _Symbol, 0, sl, tp, "Pinbar_Buy"))
            Print("BUY opened: ", m_trade.ResultPrice());
         return;
      }

      // SELL signal
      if(is_pinbar_sell && fast_ma < slow_ma && fractal_signal >= 1)
      {
         double sl = m_symbol.Bid() + InpStopLoss * g_pips_point;
         double tp = m_symbol.Bid() - InpTakeProfit * g_pips_point;
         sl = AdjustPrice(sl);
         tp = AdjustPrice(tp);

         double lots = NormalizeLot(CalculateLot());
         if(lots > 0 && m_trade.Sell(lots, _Symbol, 0, sl, tp, "Pinbar_Sell"))
            Print("SELL opened: ", m_trade.ResultPrice());
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Find Fractals on higher timeframe                                 |
//| Returns: 1=Upper fractal, 2=Lower fractal, 0=None                |
//+------------------------------------------------------------------+
int FindFractals()
{
   double upper_val[];
   double lower_val[];
   ArraySetAsSeries(upper_val, true);
   ArraySetAsSeries(lower_val, true);

   if(g_handle_fractals_upper != INVALID_HANDLE)
      CopyBuffer(g_handle_fractals_upper, 0, 0, InpFractalsLimit, upper_val);
   if(g_handle_fractals_lower != INVALID_HANDLE)
      CopyBuffer(g_handle_fractals_lower, 0, 0, InpFractalsLimit, lower_val);

   for(int i = ArraySize(upper_val) - 1; i >= 0; i--)
   {
      bool has_upper = (i < ArraySize(upper_val) && upper_val[i] > 0);
      bool has_lower = (i < ArraySize(lower_val) && lower_val[i] > 0);

      if(has_upper && !has_lower)
         return 1; // Upper fractal found
      if(has_lower && !has_upper)
         return 2; // Lower fractal found
      if(has_upper && has_lower)
         return 0; // Both, skip
   }
   return 0;
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
//| Get higher timeframe                                              |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES GetHigherTimeframe()
{
   switch(Period())
   {
      case PERIOD_M1:  return PERIOD_M5;
      case PERIOD_M5:  return PERIOD_M15;
      case PERIOD_M15: return PERIOD_H1;
      case PERIOD_M30: return PERIOD_H4;
      case PERIOD_H1:  return PERIOD_D1;
      case PERIOD_H4:  return PERIOD_W1;
      case PERIOD_D1:  return PERIOD_MN1;
      default:         return PERIOD_H1;
   }
}

//+------------------------------------------------------------------+
//| Count open positions                                              |
//+------------------------------------------------------------------+
int CountPositions()
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
//| Trailing Stop                                                     |
//+------------------------------------------------------------------+
void TrailStop()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber) continue;

      ulong ticket = m_position.Ticket();
      double open_price = m_position.PriceOpen();
      double current_sl = m_position.StopLoss();
      double current_tp = m_position.TakeProfit();

      if(m_position.PositionType() == POSITION_TYPE_BUY)
      {
         if(InpTrailingStop > 0 && m_symbol.Bid() - open_price > InpTrailingStop * g_pips_point)
         {
            double new_sl = m_symbol.Bid() - InpTrailingStop * g_pips_point;
            new_sl = AdjustPrice(new_sl);
            if(current_sl < new_sl || current_sl == 0)
            {
               if(MathAbs(current_sl - new_sl) > m_symbol.Point())
               {
                  double new_tp = current_tp + InpTrailingStop * g_pips_point;
                  m_trade.PositionModify(ticket, new_sl, new_tp);
               }
            }
         }
      }
      else if(m_position.PositionType() == POSITION_TYPE_SELL)
      {
         if(InpTrailingStop > 0 && open_price - m_symbol.Ask() > InpTrailingStop * g_pips_point)
         {
            double new_sl = m_symbol.Ask() + InpTrailingStop * g_pips_point;
            new_sl = AdjustPrice(new_sl);
            if(current_sl > new_sl || current_sl == 0)
            {
               if(MathAbs(current_sl - new_sl) > m_symbol.Point())
               {
                  double new_tp = current_tp - InpTrailingStop * g_pips_point;
                  m_trade.PositionModify(ticket, new_sl, new_tp);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Move to Break Even                                                |
//+------------------------------------------------------------------+
void MoveToBreakEven()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i)) continue;
      if(m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber) continue;

      ulong ticket = m_position.Ticket();
      double open_price = m_position.PriceOpen();
      double current_sl = m_position.StopLoss();
      double current_tp = m_position.TakeProfit();

      if(m_position.PositionType() == POSITION_TYPE_BUY)
      {
         if(m_symbol.Bid() - open_price > InpBreakEvenPips * g_pips_point)
         {
            if(open_price > current_sl || current_sl == 0)
            {
               double new_sl = open_price + InpBreakEvenSLPips * g_pips_point;
               new_sl = AdjustPrice(new_sl);
               m_trade.PositionModify(ticket, new_sl, current_tp);
            }
         }
      }
      else if(m_position.PositionType() == POSITION_TYPE_SELL)
      {
         if(open_price - m_symbol.Ask() > InpBreakEvenPips * g_pips_point)
         {
            if(open_price < current_sl || current_sl == 0)
            {
               double new_sl = open_price - InpBreakEvenSLPips * g_pips_point;
               new_sl = AdjustPrice(new_sl);
               m_trade.PositionModify(ticket, new_sl, current_tp);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                  |
//+------------------------------------------------------------------+
double CalculateLot()
{
   double lot = InpLots;

   if(InpMaximumRisk > 0)
      lot = NormalizeDouble(m_account.FreeMargin() * InpMaximumRisk / 1000.0, 1);

   if(InpDecreaseFactor > 0)
   {
      int losses = 0;
      int orders = HistoryTotal();
      for(int i = orders - 1; i >= 0; i--)
      {
         if(!HistorySelect(i, TimeCurrent())) continue;
         if(HistoryOrderGetSymbol(i) != _Symbol) continue;
         if(HistoryOrderGetDouble(i, ORDER_PROFIT) > 0) break;
         if(HistoryOrderGetDouble(i, ORDER_PROFIT) < 0) losses++;
      }
      if(losses > 1)
         lot = NormalizeDouble(lot - lot * losses / InpDecreaseFactor, 1);
   }

   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Normalize lot size                                                |
//+------------------------------------------------------------------+
double NormalizeLot(double lots)
{
   double min_lot = m_symbol.LotsMin();
   double max_lot = m_symbol.LotsMax();
   double lot_step = m_symbol.LotsStep();

   lots = MathMax(lots, min_lot);
   lots = MathMin(lots, max_lot);

   int ratio = (int)MathRound(lots / lot_step);
   lots = ratio * lot_step;

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Adjust price for symbol digits                                    |
//+------------------------------------------------------------------+
double AdjustPrice(double price)
{
   return NormalizeDouble(price, m_symbol.Digits());
}
//+------------------------------------------------------------------+
