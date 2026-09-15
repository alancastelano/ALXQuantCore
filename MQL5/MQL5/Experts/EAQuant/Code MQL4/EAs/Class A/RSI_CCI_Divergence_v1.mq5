//+------------------------------------------------------------------+
//|                                    RSI_CCI_Divergence_v1.mq5      |
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
input group           "=== Divergence Settings ==="
input int             InpCCI               = 14;           // CCI Period
input int             InpRSI               = 14;           // RSI Period
input int             InpCandlesToRetrace  = 10;           // Candles for Divergence

input group           "=== Moving Averages ==="
input int             InpFastMA            = 6;            // Fast MA Period
input int             InpSlowMA            = 85;           // Slow MA Period

input group           "=== Momentum ==="
input double          InpMomSell           = 0.3;          // Momentum Sell Threshold
input double          InpMomBuy            = 0.3;          // Momentum Buy Threshold

input group           "=== Trade Management ==="
input double          InpLots              = 0.01;         // Lot Size
input double          InpStopLoss          = 20;           // Stop Loss (pips)
input double          InpTakeProfit        = 50;           // Take Profit (pips)
input double          InpTrailingStop      = 40;           // Trailing Stop (pips)
input int             InpMaxTrades         = 10;           // Max Open Trades
input int             InpMagicNumber       = 1234;         // Magic Number

input group           "=== Break Even ==="
input bool            InpUseBreakEven      = true;         // Use Break Even
input double          InpBreakEvenPips     = 30;           // When to Move BE (pips)
input double          InpBreakEvenSLPips   = 30;           // BE Stop Loss Distance

input group           "=== Equity Protection ==="
input bool            InpUseEquityStop     = true;         // Use Equity Stop
input double          InpTotalEquityRisk   = 1.0;          // Equity Risk % to Close

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         m_trade;
CPositionInfo  m_position;
CSymbolInfo    m_symbol;
CAccountInfo   m_account;

int    g_pips_digits;
double g_pips_point;
double g_account_equity_high = 0;
double g_prev_equity = 0;

// Indicator handles
int    g_handle_cci;
int    g_handle_rsi;
int    g_handle_fast_ma;
int    g_handle_slow_ma;
int    g_handle_momentum;
int    g_handle_bb;
int    g_handle_macd;
int    g_handle_sar;

datetime g_last_bar_time = 0;

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
   g_handle_cci      = iCCI(_Symbol, PERIOD_CURRENT, InpCCI, PRICE_TYPICAL);
   g_handle_rsi      = iRSI(_Symbol, PERIOD_CURRENT, InpRSI, PRICE_TYPICAL);
   g_handle_fast_ma  = iMA(_Symbol, PERIOD_CURRENT, InpFastMA, 0, MODE_LWMA, PRICE_TYPICAL);
   g_handle_slow_ma  = iMA(_Symbol, PERIOD_CURRENT, InpSlowMA, 0, MODE_LWMA, PRICE_TYPICAL);
   g_handle_momentum = iMomentum(_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE);
   g_handle_bb       = iBands(_Symbol, PERIOD_CURRENT, 20, 0, 2, PRICE_CLOSE);
   g_handle_macd     = iMACD(_Symbol, PERIOD_CURRENT, 12, 26, 9, PRICE_CLOSE);
   g_handle_sar      = iSAR(_Symbol, PERIOD_CURRENT, 0.02, 0.2);

   if(g_handle_cci == INVALID_HANDLE || g_handle_rsi == INVALID_HANDLE ||
      g_handle_fast_ma == INVALID_HANDLE || g_handle_slow_ma == INVALID_HANDLE)
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
   IndicatorRelease(g_handle_cci);
   IndicatorRelease(g_handle_rsi);
   IndicatorRelease(g_handle_fast_ma);
   IndicatorRelease(g_handle_slow_ma);
   IndicatorRelease(g_handle_momentum);
   IndicatorRelease(g_handle_bb);
   IndicatorRelease(g_handle_macd);
   IndicatorRelease(g_handle_sar);
}

//+------------------------------------------------------------------+
//| Main Tick Function                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // New bar check
   datetime bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(bar_time == g_last_bar_time) return;
   g_last_bar_time = bar_time;

   m_symbol.RefreshRates();

   // Equity stop
   if(InpUseEquityStop)
   {
      double profit = CalculateProfit();
      if(profit < 0.0 && MathAbs(profit) > InpTotalEquityRisk / 100.0 * GetAccountEquityHigh())
      {
         CloseAllPositions();
         Print("Closed all due to Equity Stop");
         return;
      }
   }

   // Break even
   if(InpUseBreakEven)
      MoveToBreakEven();

   // Trailing stop
   TrailStop();

   // Pre-checks
   if(Bars(_Symbol, PERIOD_CURRENT) < 100) return;

   // Get indicator values
   double cci_current = GetIndicatorValue(g_handle_cci, 1);
   double rsi_current = GetIndicatorValue(g_handle_rsi, 1);
   double fast_ma     = GetIndicatorValue(g_handle_fast_ma, 0);
   double slow_ma     = GetIndicatorValue(g_handle_slow_ma, 0);
   double momentum    = MathAbs(100.0 - GetIndicatorValue(g_handle_momentum, 1));
   double momentum1   = MathAbs(100.0 - GetIndicatorValue(g_handle_momentum, 2));
   double momentum2   = MathAbs(100.0 - GetIndicatorValue(g_handle_momentum, 3));

   if(fast_ma == 0 || slow_ma == 0) return;

   // Count current positions
   int current_positions = CountPositions();
   if(current_positions >= InpMaxTrades) return;

   // Check for BUY signal
   if(current_positions < InpMaxTrades)
   {
      int cci_signal = GetCCISignal();
      int rsi_signal = GetRSISignal();

      if((cci_signal == 1 || rsi_signal == 1) && fast_ma > slow_ma)
      {
         if(momentum < InpMomBuy || momentum1 < InpMomBuy || momentum2 < InpMomBuy)
         {
            double sl = m_symbol.Ask() - InpStopLoss * g_pips_point;
            double tp = m_symbol.Ask() + InpTakeProfit * g_pips_point;
            sl = AdjustPrice(sl);
            tp = AdjustPrice(tp);

            double lots = NormalizeLot(InpLots);
            if(lots > 0 && m_trade.Buy(lots, _Symbol, 0, sl, tp, "RSI_CCI_Buy"))
            {
               Print("BUY opened: ", m_trade.ResultPrice());
            }
            return;
         }
      }
   }

   // Check for SELL signal
   if(current_positions < InpMaxTrades)
   {
      int cci_signal = GetCCISignal();
      int rsi_signal = GetRSISignal();

      if((cci_signal == 2 || rsi_signal == 2) && fast_ma < slow_ma)
      {
         if(momentum < InpMomSell || momentum1 < InpMomSell || momentum2 < InpMomSell)
         {
            double sl = m_symbol.Bid() + InpStopLoss * g_pips_point;
            double tp = m_symbol.Bid() - InpTakeProfit * g_pips_point;
            sl = AdjustPrice(sl);
            tp = AdjustPrice(tp);

            double lots = NormalizeLot(InpLots);
            if(lots > 0 && m_trade.Sell(lots, _Symbol, 0, sl, tp, "RSI_CCI_Sell"))
            {
               Print("SELL opened: ", m_trade.ResultPrice());
            }
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CCI Divergence Signal                                             |
//| Returns: 1=Buy, 2=Sell, 0=None                                   |
//+------------------------------------------------------------------+
int GetCCISignal()
{
   double cci_values[];
   ArraySetAsSeries(cci_values, true);
   if(CopyBuffer(g_handle_cci, 0, 0, InpCandlesToRetrace + 2, cci_values) < InpCandlesToRetrace + 2)
      return 0;

   double high_values[];
   ArraySetAsSeries(high_values, true);
   CopyHigh(_Symbol, PERIOD_CURRENT, 0, InpCandlesToRetrace + 2, high_values);

   for(int i = InpCandlesToRetrace; i >= 0; i--)
   {
      // Buy divergence: CCI rising but price making lower high
      if(cci_values[1] > cci_values[i] && high_values[1] < high_values[i])
         return 1;

      // Sell divergence: CCI falling but price making higher high
      if(cci_values[1] < cci_values[i] && high_values[1] > high_values[i])
         return 2;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| RSI Divergence Signal                                             |
//| Returns: 1=Buy, 2=Sell, 0=None                                   |
//+------------------------------------------------------------------+
int GetRSISignal()
{
   double rsi_values[];
   ArraySetAsSeries(rsi_values, true);
   if(CopyBuffer(g_handle_rsi, 0, 0, InpCandlesToRetrace + 2, rsi_values) < InpCandlesToRetrace + 2)
      return 0;

   double high_values[];
   ArraySetAsSeries(high_values, true);
   CopyHigh(_Symbol, PERIOD_CURRENT, 0, InpCandlesToRetrace + 2, high_values);

   for(int i = InpCandlesToRetrace; i >= 0; i--)
   {
      // Buy divergence: RSI rising but price making lower high
      if(rsi_values[1] > rsi_values[i] && high_values[1] < high_values[i])
         return 1;

      // Sell divergence: RSI falling but price making higher high
      if(rsi_values[1] < rsi_values[i] && high_values[1] > high_values[i])
         return 2;
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Get indicator value at shift                                      |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle, int shift)
{
   double value[1];
   if(CopyBuffer(handle, 0, shift, 1, value) == 1)
      return value[0];
   return 0;
}

//+------------------------------------------------------------------+
//| Count open positions for this EA                                  |
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
//| Calculate floating profit                                         |
//+------------------------------------------------------------------+
double CalculateProfit()
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
            profit += m_position.Profit() + m_position.Swap();
      }
   }
   return profit;
}

//+------------------------------------------------------------------+
//| Get account equity high watermark                                 |
//+------------------------------------------------------------------+
double GetAccountEquityHigh()
{
   if(CountPositions() == 0)
      g_account_equity_high = m_account.Equity();

   if(g_account_equity_high < g_prev_equity)
      g_account_equity_high = g_prev_equity;
   else
      g_account_equity_high = m_account.Equity();

   g_prev_equity = m_account.Equity();
   return g_account_equity_high;
}

//+------------------------------------------------------------------+
//| Close all positions for this EA                                   |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i))
      {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
         {
            ulong ticket = m_position.Ticket();
            m_trade.PositionClose(ticket);
            Sleep(500);
         }
      }
   }
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
         if(InpTrailingStop > 0)
         {
            if(m_symbol.Bid() - open_price > InpTrailingStop * g_pips_point)
            {
               if(current_sl < m_symbol.Bid() - InpTrailingStop * g_pips_point || current_sl == 0)
               {
                  double new_sl = m_symbol.Bid() - InpTrailingStop * g_pips_point;
                  new_sl = AdjustPrice(new_sl);
                  if(MathAbs(current_sl - new_sl) > m_symbol.Point())
                     m_trade.PositionModify(ticket, new_sl, current_tp);
               }
            }
         }
      }
      else if(m_position.PositionType() == POSITION_TYPE_SELL)
      {
         if(InpTrailingStop > 0)
         {
            if(open_price - m_symbol.Ask() > InpTrailingStop * g_pips_point)
            {
               if(current_sl > m_symbol.Ask() + InpTrailingStop * g_pips_point || current_sl == 0)
               {
                  double new_sl = m_symbol.Ask() + InpTrailingStop * g_pips_point;
                  new_sl = AdjustPrice(new_sl);
                  if(MathAbs(current_sl - new_sl) > m_symbol.Point())
                     m_trade.PositionModify(ticket, new_sl, current_tp);
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
//| Adjust price for symbol digits                                    |
//+------------------------------------------------------------------+
double AdjustPrice(double price)
{
   return NormalizeDouble(price, m_symbol.Digits());
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
