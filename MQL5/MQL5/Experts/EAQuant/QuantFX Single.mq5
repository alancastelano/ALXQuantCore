//+------------------------------------------------------------------+
//|                                            QuantFX Single.mq5     |
//|                                       ALXQuantCore                |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore"
#property version   "1.10"

const string EA_NAME    = "QuantFX Single";
const string EA_VERSION = "v1.1.0";

//+------------------------------------------------------------------+
//| API MQL5                                                          |
//+------------------------------------------------------------------+
#include <Trade\PositionInfo.mqh>  CPositionInfo  m_position;
#include <Trade\Trade.mqh>         CTrade         m_trade;
#include <Trade\SymbolInfo.mqh>    CSymbolInfo    m_symbol;
#include <Trade\AccountInfo.mqh>   CAccountInfo   m_account;
#include <Trade\DealInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| #Inputs — EA Level                                               |
//+------------------------------------------------------------------+
input group                "➜ EA Config"
input string               InpSetDescription       = "";             // Set description
input int                  InpMaxSpreadPips        = 5;              // Max spread (pips)
input int                  InpMaxSlippage          = 5;              // Max slippage (pts)
//+------------------------------------------------------------------+
input group                "➜ Position Size"
input double               InpStopLossPerc         = 0.7;            // Max risk% stop (account, 0=off)
input int                  InpTakeProfit           = 60;             // Take Profit (pips, 0=off)
input double               InpLotValue             = 0.03;           // Lot value
//+------------------------------------------------------------------+
input group                "➜ Trailing Stop"
input double               InpTrailingStart        = 6.0;            // Trailing Start (pips)
input double               InpTrailingStep         = 20.0;           // Trailing Step (pips)
//+------------------------------------------------------------------+
input group                "➜ Time Filter"
input int                  InpTimeStart            = 2;              // Time start (Brasilia)
input int                  InpTimeEnd              = 17;             // Time end (Brasilia)
input bool                 InpTradeFriday          = true;           // Trade on Friday?
//+------------------------------------------------------------------+
#include <ALXQuantCore\Modules\MacroRegimeEngine.mqh>  CMacroRegimeEngine  m_regime;
//+------------------------------------------------------------------+
input group                "➜ Strategy"
input int                  InpFrequency            = 250;            // Timer frequency (ms)
input double               InpTimeAnalise          = 1;              // Time (sec)
input double               InpPipsStep             = 28.0;           // Pip Step (pips)
input ENUM_TIMEFRAMES      InphighTimeframeConfirme= PERIOD_H4;      // High timeframe confirm
//+------------------------------------------------------------------+
#include <ALXQuantCore\Core\Commission.mqh>  CCommission   m_commission;
//+------------------------------------------------------------------+
#include <ALXQuantCore\Institutional\HumanBehavior.mqh>  CHumanBehavior   m_human;
//+------------------------------------------------------------------+

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

      datetime m_last_trade_bar_time;

      //-- Strategy
      double   price_open;
      datetime time_open;
      datetime time_new;
      datetime last_bar_time;

      //-- Execution Control
      bool     m_need_open_buy;
      bool     m_need_open_sell;
      bool     m_waiting_transaction;
      ulong    m_waiting_order_ticket;
      bool     m_transaction_confirmed;
      datetime m_order_sent_time;
      datetime m_last_human_delay_time;

      //-- Time sync
      datetime g_utcOffsetSeconds;
      bool     g_syncOk;
   } sets;

//+------------------------------------------------------------------+
//|====================== Initialization =============================|
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
   sets.m_comment       = GenerateRegimeComment();

   //--- Strategy
   sets.price_open      = 0.0;
   sets.time_open       = (datetime)InpTimeAnalise;
   sets.time_new        = 0;
   sets.digits_adjust   = 1;

   //--- Time sync
   sets.g_utcOffsetSeconds = 0;
   sets.g_syncOk           = false;

   sets.last_bar_time         = 0;
   sets.m_last_trade_bar_time = 0;

   //--- Execution Control
   sets.m_need_open_buy           = false;
   sets.m_need_open_sell          = false;
   sets.m_waiting_transaction     = false;
   sets.m_waiting_order_ticket    = 0;
   sets.m_transaction_confirmed   = false;
   sets.m_order_sent_time         = 0;
   sets.m_last_human_delay_time   = 0;

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

   //--- Modules
   m_regime.Init(InpDFAPeriod, InpDFA_min_scale, InpDFA_max_scale, InpRegimeTimeframe);
   m_commission.Init(&m_symbol, 0);
   m_human.Init();

   SyncUniversalClock();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//|======================== OnTick ===================================|
//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick tick;

   if(!SymbolInfoTick(Symbol(),tick))
      Print("SymbolInfoTick() failed, error = ",GetLastError());

   //--- Regime (new M5 bar only)
   static datetime last_bar = 0;
   datetime bar = iTime(_Symbol, PERIOD_M5, 0);
   if(bar != last_bar)
   {
      m_regime.Get();
      last_bar = bar;
   }

   if(sets.time_new == 0) sets.time_new = TimeCurrent();
   if(sets.price_open == 0) sets.price_open = tick.bid;

   if(sets.time_new + sets.time_open < TimeCurrent())
   {
      sets.time_new = TimeCurrent();
      sets.price_open = tick.bid;
   }

   bool buy_tfh  = iClose(m_symbol.Name(),InphighTimeframeConfirme,0)>iOpen(m_symbol.Name(),InphighTimeframeConfirme,0);
   bool sell_tfh = iClose(m_symbol.Name(),InphighTimeframeConfirme,0)>iOpen(m_symbol.Name(),InphighTimeframeConfirme,0);

   sets.m_need_open_buy  = buy_tfh  && (sets.time_new + sets.time_open >= TimeCurrent() && tick.bid - InpPipsStep * m_symbol.Point() >= sets.price_open);
   sets.m_need_open_sell = sell_tfh && (sets.time_new + sets.time_open >= TimeCurrent() && tick.bid + InpPipsStep * m_symbol.Point() <= sets.price_open);

   //--- Order confirmation timeout (30s)
   if(sets.m_waiting_transaction && !sets.m_transaction_confirmed)
   {
      if(TimeCurrent() - sets.m_order_sent_time > 30)
      {
         Print("Order confirmation timeout — releasing lock");
         sets.m_waiting_transaction = false;
         sets.m_waiting_order_ticket = 0;
      }
   }

   bool can_trade_open =   CalculateAllPositions()==0
                           && !sets.m_waiting_transaction
                           && !m_regime.IsChaosRegime()
                           && IsTimeFilter();

   if(can_trade_open)
   {
      if(sets.m_need_open_buy)  { OpenPosition(POSITION_TYPE_BUY);  }
      if(sets.m_need_open_sell) { OpenPosition(POSITION_TYPE_SELL); }
   }

   //--- Trailing Stop
   if(CalculateAllPositions()==1) { TrailingStop(); }

   //--- Account Stop Loss (balance %)
   double LossProc = (m_account.Balance()/100.0) * InpStopLossPerc * (-1.0);
   if(ProfitAll(-1) < LossProc && LossProc != 0)
   {
      CloseAllByMagic();
   }
}

//+------------------------------------------------------------------+
//|===================== Deinitialization ===========================|
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0,0, OBJ_LABEL);
   ObjectsDeleteAll(0,0, OBJ_RECTANGLE_LABEL);
}

//--- Timer
void OnTimer()
{
   if(!MQL_TESTER)
      SyncUniversalClock();
}

//+------------------------------------------------------------------+
//| TradeTransaction — confirm order execution                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   ENUM_TRADE_TRANSACTION_TYPE type=trans.type;

   if(type==TRADE_TRANSACTION_DEAL_ADD)
   {
      if(HistoryDealSelect(trans.deal))
      {
         long deal_entry  =HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
         long deal_type   =HistoryDealGetInteger(trans.deal,DEAL_TYPE);
         long deal_magic  =HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
         long deal_order  =HistoryDealGetInteger(trans.deal,DEAL_ORDER);
         string deal_symbol=HistoryDealGetString(trans.deal,DEAL_SYMBOL);

         if(deal_symbol==m_symbol.Name() && deal_magic==sets.m_magic)
         {
            if(deal_entry==DEAL_ENTRY_IN)
            {
               if(deal_type==DEAL_TYPE_BUY || deal_type==DEAL_TYPE_SELL)
               {
                  if(sets.m_waiting_transaction)
                  {
                     if(sets.m_waiting_order_ticket==deal_order)
                     {
                        Print(__FUNCTION__," Order confirmed — ticket=", deal_order);
                        sets.m_transaction_confirmed = true;
                        sets.m_waiting_transaction   = false;
                        sets.m_last_human_delay_time = TimeCurrent();
                     }
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//|========================== Functions ==============================|
//+------------------------------------------------------------------+


//========================= POSITION HELPERS =========================

//--- Count all positions for this EA
int CalculateAllPositions(void)
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(m_position.SelectByIndex(i))
         if(m_position.Symbol()==m_symbol.Name() && m_position.Magic()==sets.m_magic)
            count++;
   return(count);
}

//--- Lucro flutuante global na conta (para este EA)
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
         {
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }
   }
   return profit;
}

//--- Check if profit covers commission + swap costs
bool IsProfitAboveCosts(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;

   double profit = PositionGetDouble(POSITION_PROFIT);
   double swap   = PositionGetDouble(POSITION_SWAP);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double net    = m_commission.NetProfit(profit + swap, volume);

   return (net > 0);
}

//========================= CLOSE ====================================
void CloseAllByMagic()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == sets.m_magic)
      {
         m_trade.PositionClose(ticket);
      }
   }
}

//========================= TRAILING STOP ============================
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
            {
               m_trade.PositionModify(ticket, NormalizeDouble(openPrice + InpTrailingStart * Point, digits), currentTP);
            }
            if(currentSL >= openPrice && Bid - InpTrailingStep * Point > currentSL)
            {
               m_trade.PositionModify(ticket, NormalizeDouble(Bid - InpTrailingStep * Point, digits), currentTP);
            }
         }

         if(posType == POSITION_TYPE_SELL && InpTrailingStep != 0)
         {
            if((currentSL > openPrice || currentSL == 0) && Ask + (InpTrailingStep + InpTrailingStart) * Point <= openPrice)
            {
               m_trade.PositionModify(ticket, NormalizeDouble(openPrice - InpTrailingStart * Point, digits), currentTP);
            }
            if(currentSL <= openPrice && Ask + InpTrailingStep * Point < currentSL)
            {
               m_trade.PositionModify(ticket, NormalizeDouble(Ask + InpTrailingStep * Point, digits), currentTP);
            }
         }
      }
   }
}

//========================= MAGIC ID =================================
ulong AutoMagicID(string ea_name, string version="1.0")
{
   ulong accountLogin = (ulong)AccountInfoInteger(ACCOUNT_LOGIN);
   string key = ea_name + "|" + version + "|" + _Symbol + "|" + IntegerToString(_Period) + "|" + IntegerToString(accountLogin);

   ulong hash = 5381;
   for(int i = 0; i < StringLen(key); i++)
      hash = ((hash << 5) + hash) + StringGetCharacter(key, i);

   return hash & 0x7FFFFFFF;
}

//========================= REGIME COMMENT ===========================
string GenerateRegimeComment()
{
   ulong accLogin = AccountInfoInteger(ACCOUNT_LOGIN);
   int uniqueSuffix = (int)(accLogin % 9999);

   double hurstVal = m_regime.GetLastHurst();
   double r2Val    = m_regime.GetConfidence();

   string hStr = DoubleToString(hurstVal, 2);
   string rStr = DoubleToString(r2Val, 2);

   return StringFormat("QFX_H%s_R%s_%04d", hStr, rStr, uniqueSuffix);
}

//========================= REFRESH RATES ============================
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

//========================= HUMAN DELAY (no Sleep) ===================
bool CanTradeAfterHumanDelay()
{
   if(!m_human.IsInitialized()) return true;
   int delayMs = m_human.GetExecutionDelay();
   datetime delaySec = delayMs / 1000;
   if(delaySec < 1) delaySec = 1;
   return (TimeCurrent() - sets.m_last_human_delay_time >= delaySec);
}

//========================= OPEN POSITION ============================
void OpenPosition(const ENUM_POSITION_TYPE pos_type)
{
   if(!RefreshRates() || !m_symbol.Refresh())
      return;

   //--- Check order confirmation
   if(sets.m_waiting_transaction)
      return;

   //--- Human delay (non-blocking)
   if(!CanTradeAfterHumanDelay())
      return;

   //--- StopsLevel
   double stop_level = m_symbol.StopsLevel() * m_symbol.Point();
   if(stop_level == 0.0)
      stop_level = (m_symbol.Ask() - m_symbol.Bid()) * 3.0;
   stop_level *= 1.1;

   // 1. Human Behavior
   m_human.NewTrade();
   if(m_human.ShouldSkipTrade())
      return;

   // 2. Lot
   double lots = InpLotValue;
   if(lots <= 0.0) return;

   // 3. Entry price + Jitter
   double price = (pos_type == POSITION_TYPE_BUY) ? m_symbol.Ask() : m_symbol.Bid();
   price += m_human.GetEntryJitter();
   price = m_symbol.NormalizePrice(price);

    // 4. TP only (SL is account-level via InpStopLossPerc)
   double sl = 0.0;
   double tp = 0.0;

   if(InpTakeProfit > 0)
   {
      if(pos_type == POSITION_TYPE_BUY)
         tp = NormalizeDouble(price + InpTakeProfit * m_symbol.Point() * sets.digits_adjust, m_symbol.Digits());
      else
         tp = NormalizeDouble(price - InpTakeProfit * m_symbol.Point() * sets.digits_adjust, m_symbol.Digits());
   }

   //--- StopsLevel validation
   if(tp > 0.0)
   {
      if(pos_type == POSITION_TYPE_BUY && (tp - m_symbol.Bid()) < stop_level)
         tp = m_symbol.Bid() + stop_level;
      if(pos_type == POSITION_TYPE_SELL && (m_symbol.Ask() - tp) < stop_level)
         tp = m_symbol.Ask() - stop_level;
   }

   if(tp > 0.0) tp = m_symbol.NormalizePrice(tp);

   // 5. Set waiting state BEFORE sending order
   sets.m_waiting_transaction  = true;
   sets.m_transaction_confirmed = false;
   sets.m_waiting_order_ticket = 0;
   sets.m_order_sent_time      = TimeCurrent();

   // 6. Send order
   bool result = false;

   if(pos_type == POSITION_TYPE_BUY)
      result = m_trade.Buy(lots,m_symbol.Name(),m_symbol.Ask(),sl, tp, sets.m_comment);
   else
      result = m_trade.Sell(lots,m_symbol.Name(),m_symbol.Bid(),sl, tp, sets.m_comment);

   if(result)
   {
      sets.m_last_trade_bar_time = iTime(_Symbol, _Period, 0);
      // Store the order ticket for confirmation
      if(m_trade.ResultOrder() > 0)
         sets.m_waiting_order_ticket = m_trade.ResultOrder();
   }
   else
   {
      Print("Order send failed: ", GetLastError());
      sets.m_waiting_transaction = false;
   }
}


//===================================================================================
input group "=== Filtros ==="
input int    InpMinTrades            = 30;
input double InpMinProfitFactor      = 1.2;
input double InpMaxDrawdownPct       = 30.0;
input double InpMaxLossToAvgWinRatio = 5.0;  // <<< O FILTRO PRA SEU PROBLEMA: maior perda não pode passar de Nx o ganho médio

input group "=== Pesos ==="
input double InpPesoSortino       = 2.5;
input double InpPesoProfitFactor  = 1.0;
input double InpPesoUlcer         = 2.0;  // penalidade (subtrai do score)
input double InpPesoPayoff        = 1.5;
input double InpPesoWinRate       = 0.3;

//+------------------------------------------------------------------+
double OnTester()
{
   int totalTrades = (int)TesterStatistics(STAT_TRADES);
   if(totalTrades < InpMinTrades) return 0.0;

   double netProfit = TesterStatistics(STAT_PROFIT);
   if(netProfit <= 0.0) return 0.0;

   double grossProfit  = TesterStatistics(STAT_GROSS_PROFIT);
   double grossLoss    = TesterStatistics(STAT_GROSS_LOSS);
   int    winTrades    = (int)TesterStatistics(STAT_PROFIT_TRADES);
   int    lossTrades   = (int)TesterStatistics(STAT_LOSS_TRADES);
   double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
   double maxDDPercent = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double maxLossTrade = MathAbs(TesterStatistics(STAT_MAX_LOSSTRADE));

   if(profitFactor == DBL_MAX || profitFactor > 10.0)
      profitFactor = 10.0;

   if(maxDDPercent > InpMaxDrawdownPct)
      return 0.0;

   double avgWin  = (winTrades  > 0) ? grossProfit / winTrades         : 0.0;
   double avgLoss = (lossTrades > 0) ? MathAbs(grossLoss) / lossTrades : 0.0;

   //--- FILTRO CRÍTICO: descarta estratégias com risco de "cauda gorda"
   //--- Ex.: ganho médio $2, maior perda $38 -> razão 19x -> descartada
   if(avgWin > 0.0 && (maxLossTrade / avgWin) > InpMaxLossToAvgWinRatio)
      return 0.0;

   double payoffRatio = (avgLoss > 0.0) ? avgWin / avgLoss : 0.0;
   double winRate      = (double)winTrades / totalTrades;

   //--- Reconstrói a série de trades para calcular Sortino e Ulcer Index
   double tradeReturns[];
   double equityCurve[];
   if(!BuildTradeSeries(tradeReturns, equityCurve))
      return 0.0;

   double sortino        = CalcSortino(tradeReturns);
   double sortinoClamped = MathMax(-3.0, MathMin(sortino, 5.0));
   double ulcer          = CalcUlcerIndex(equityCurve);

   double score = 0.0;
   score += sortinoClamped   * InpPesoSortino;
   score += profitFactor     * InpPesoProfitFactor;
   score += payoffRatio      * InpPesoPayoff;
   score += winRate * 10.0   * InpPesoWinRate;
   score -= ulcer            * InpPesoUlcer;   // Ulcer é penalidade, não bônus

   return MathMax(score, 0.0);
}

//+------------------------------------------------------------------+
//| Reconstrói o histórico de deals de saída em duas séries:          |
//| retorno por trade (p/ Sortino) e capital acumulado (p/ Ulcer)     |
//+------------------------------------------------------------------+
bool BuildTradeSeries(double &returns[], double &equity[])
{
   if(!HistorySelect(0, TimeCurrent()))
      return false;

   int total = HistoryDealsTotal();
   ArrayResize(returns, 0);
   ArrayResize(equity, 0);
   double cumProfit = 0.0;

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      //--- só nos interessam deals de FECHAMENTO de posição
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      double dealProfit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                         + HistoryDealGetDouble(ticket, DEAL_SWAP)
                         + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      int n = ArraySize(returns);
      ArrayResize(returns, n + 1);
      returns[n] = dealProfit;

      cumProfit += dealProfit;
      int m = ArraySize(equity);
      ArrayResize(equity, m + 1);
      equity[m] = cumProfit;
   }

   return (ArraySize(returns) > 0);
}

//+------------------------------------------------------------------+
//| Sortino: retorno médio / desvio padrão SÓ dos retornos negativos   |
//+------------------------------------------------------------------+
double CalcSortino(const double &returns[])
{
   int n = ArraySize(returns);
   if(n == 0) return 0.0;

   double meanReturn = 0.0;
   for(int i = 0; i < n; i++)
      meanReturn += returns[i];
   meanReturn /= n;

   double sumSqDownside = 0.0;
   int    downsideCount = 0;
   for(int i = 0; i < n; i++)
   {
      if(returns[i] < 0.0)
      {
         sumSqDownside += returns[i] * returns[i];
         downsideCount++;
      }
   }

   if(downsideCount == 0)
      return 5.0; // nenhuma perda na amostra -> valor teto (evita div/0, mas suspeito)

   double downsideDeviation = MathSqrt(sumSqDownside / downsideCount);
   return (downsideDeviation > 0.0) ? meanReturn / downsideDeviation : 0.0;
}

//+------------------------------------------------------------------+
//| Ulcer Index: raiz da média dos quadrados do drawdown percentual   |
//| ao longo de toda a curva de capital acumulado (pune DD prolongado)|
//+------------------------------------------------------------------+
double CalcUlcerIndex(const double &equity[])
{
   int n = ArraySize(equity);
   if(n == 0) return 0.0;

   double peak     = equity[0];
   double sumSqDD  = 0.0;

   for(int i = 0; i < n; i++)
   {
      if(equity[i] > peak)
         peak = equity[i];

      double ddPct = (peak != 0.0) ? ((peak - equity[i]) / MathAbs(peak)) * 100.0 : 0.0;
      sumSqDD += ddPct * ddPct;
   }

   return MathSqrt(sumSqDD / n);
}