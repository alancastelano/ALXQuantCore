//+------------------------------------------------------------------+
//|                                                 QuantFX Lite.mq5 |
//|                                                     ALXQuantCore |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore"
#property version   "1.10"

const string EA_NAME    = "Quant Lite";
const string EA_VERSION = "v1.1.0";

#include "QuantFramework_lite.mqh";
#include <ALXQuantCore\Modules\MacroRegimeEngine.mqh>
#include <ALXQuantCore\Modules\MacroOverlayReader.mqh>

CMacroRegimeEngine g_engine;
CMacroOverlayReader g_macro;

//+------------------------------------------------------------------+
//| #Inputs — EA Level                                               |
//+------------------------------------------------------------------+
input group                "EA Config"
input int                  InpMaxSpreadPips        = 5;              // Max spread (pips)
input int                  InpMaxSlippage          = 5;              // Max slippage (pts)
//+------------------------------------------------------------------+
input group                "Position Size"
input double               InpLotValue             = 0.01;           // Lote fixo
input double               InpMaxLot               = 0.10;           // Max lote por trade
input int                  InpTakeProfit           = 60;             // Take Profit (pips, 0=off)
//+------------------------------------------------------------------+
input group                "Account Protector"
input double               InpStopLossPerc         = 0.7;            // Max drawdown % (0=off)
input double               InpMaxDailyDrawdownPct  = 2.2;            // Max daily drawdown % (0=off)
//+------------------------------------------------------------------+
input group                "Trailing Stop"
input double               InpTrailingStart        = 6.0;            // Trailing Start (pips)
input double               InpTrailingStep         = 20.0;           // Trailing Step (pips)
//+------------------------------------------------------------------+
input group                "Time Filter"
input int                  InpTimeStart            = 2;              // Time start (Brasilia)
input int                  InpTimeEnd              = 17;             // Time end (Brasilia)
input bool                 InpTradeFriday          = true;           // Trade on Friday?
//+------------------------------------------------------------------+
input group                "Strategy"
input int                  InpFrequency            = 250;            // Timer frequency (ms)
input double               InpTimeAnalise          = 1;              // Time (sec)
input double               InpPipsStep             = 28.0;           // Pip Step (pips)
input ENUM_TIMEFRAMES      InphighTimeframeConfirme= PERIOD_H4;      // High timeframe confirm
//+------------------------------------------------------------------+
input group                "Macro Regime"
input bool                 InpUseMacroRegime    = true;        // Use Macro Regime filter?
input bool                 InpUseMacroOverlay   = true;        // Use Macro Overlay?
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| # OnInit                                                         |
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetMillisecondTimer(InpFrequency);

   if(!m_symbol.Name(Symbol()))
      return(false);

   if(!RefreshRates()) return(false);

   sets.m_ea_name       = EA_NAME;
   sets.m_ea_version    = EA_VERSION;
   sets.m_magic         = AutoMagicID(sets.m_ea_name, sets.m_ea_version);
   sets.m_max_slippage  = InpMaxSlippage;

   //--- Strategy
   sets.price_open      = 0.0;
   sets.time_open       = (datetime)InpTimeAnalise;
   sets.time_new        = 0;
   sets.digits_adjust   = 1;

   //--- Daily Drawdown
   sets.m_day_start_balance = m_account.Balance();
   sets.m_last_day_reset    = 0;

   m_trade.LogLevel(LOG_LEVEL_NO);
   m_trade.SetExpertMagicNumber(sets.m_magic);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(m_symbol.Name());
   m_trade.SetDeviationInPoints(InpMaxSlippage);

   //--- Detecta se o simbolo e do tipo Forex
   ENUM_SYMBOL_CALC_MODE calc_mode = (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_CALC_MODE);
   bool is_forex_like = (calc_mode == SYMBOL_CALC_MODE_FOREX || calc_mode == SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE);

   if(is_forex_like && (m_symbol.Digits()==3 || m_symbol.Digits()==5))
      sets.digits_adjust = 10;
   sets.m_adjusted_point = m_symbol.Point() * sets.digits_adjust;

   CommInit(&m_symbol, sets.m_magic);
   
   m_design.Init();

   //--- Macro Regime
   if(InpUseMacroRegime)
   {
      g_engine.Init(200, 4, 60, PERIOD_H4);
   }
   if(InpUseMacroOverlay)
   {
      g_macro.Init(_Symbol);
   }

   Print("[", EA_NAME, "] Init OK — magic=", sets.m_magic,
         " balance=", DoubleToString(m_account.Balance(), 2));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| # OnDeInit                                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| # OnTick                                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Trailing Stop
   if(CalculateAllPositions()==1) { TrailingStop(); }

   //--- Account Stop Loss (balance %) — net after commission
   double LossProc = (m_account.Balance()/100.0) * InpStopLossPerc * (-1.0);
   if(LossProc != 0)
   {
      double profit = ProfitAll(-1);
      double lots   = AllLots(-1);
      double net    = CommNetProfit(profit, lots);

      if(net < LossProc)
         CloseAllByMagic();
   }

   //--- Daily Drawdown Protection
   if(IsDailyDrawdownExceeded())
   {
      CloseAllByMagic();
      Print("[DAILY DD] Drawdown excedido — fechando tudo");
   }
}

//+------------------------------------------------------------------+
//| # OnTimer                                                        |
//+------------------------------------------------------------------+
void OnTimer() { Process(); }

//+------------------------------------------------------------------+
//| # Process                                                        |
//+------------------------------------------------------------------+
void Process(void)
{
   MqlTick tick;

   if(!SymbolInfoTick(Symbol(),tick))
      return;

   if(sets.time_new == 0) sets.time_new = TimeCurrent();
   if(sets.price_open == 0) sets.price_open = tick.bid;

   if(sets.time_new + sets.time_open < TimeCurrent())
   {
      sets.time_new = TimeCurrent();
      sets.price_open = tick.bid;
   }

   bool buy_tfh  = iClose(m_symbol.Name(),InphighTimeframeConfirme,0) > iOpen(m_symbol.Name(),InphighTimeframeConfirme,0);
   bool sell_tfh = iClose(m_symbol.Name(),InphighTimeframeConfirme,0) < iOpen(m_symbol.Name(),InphighTimeframeConfirme,0);

   sets.m_need_open_buy  = buy_tfh  && (sets.time_new + sets.time_open >= TimeCurrent() && tick.bid - InpPipsStep * m_symbol.Point() >= sets.price_open);
   sets.m_need_open_sell = sell_tfh && (sets.time_new + sets.time_open >= TimeCurrent() && tick.bid + InpPipsStep * m_symbol.Point() <= sets.price_open);

   //--- Overlay check
   bool macro_ok = true;
   if(InpUseMacroOverlay && g_macro.IsLoaded())
      macro_ok = g_macro.TradeAllowed();

   //--- Regime score
   int regime_score = 100;
   if(InpUseMacroRegime)
      regime_score = g_engine.GetRegimeScore();

   bool can_trade_open = CalculateAllPositions() == 0 &&
                         IsTimeFilter()               && 
                         IsSpreadOk()                 &&
                         CanTradeByNews()             &&
                         !IsDailyDrawdownExceeded()   &&
                         macro_ok;

   if(can_trade_open)
   {
      double lot = CalculateLot();
      if(lot <= 0) return;

      //--- Regime throttle: reduz lote em conditions adversas
      double lot_scale = regime_score / 100.0;
      if(InpUseMacroOverlay && g_macro.IsLoaded())
      {
         double risk_z = g_macro.MacroRiskZ();
         if(risk_z > 2.0) lot_scale *= 0.5;
      }
      lot = MathMin(lot * lot_scale, InpMaxLot);

      if(sets.m_need_open_buy)
         m_trade.Buy(lot, m_symbol.Name(), tick.ask, 0, 0, EA_NAME);

      if(sets.m_need_open_sell)
         m_trade.Sell(lot, m_symbol.Name(), tick.bid, 0, 0, EA_NAME);
   }
}
//+------------------------------------------------------------------+
