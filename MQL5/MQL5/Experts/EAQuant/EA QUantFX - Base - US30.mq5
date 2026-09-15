//+------------------------------------------------------------------+
//|                                                   EA QUantFX.mq5 |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property version   "10.2"

const string EA_NAME    = "QuantFX";
const string EA_VERSION = "v10.2.0";

//+------------------------------------------------------------------+
//| #Include - API MQL5                                              |
//+------------------------------------------------------------------+
#include <Trade\PositionInfo.mqh>  // trade position object
#include <Trade\Trade.mqh>         // trading object
#include <Trade\SymbolInfo.mqh>    // symbol info object
#include <Trade\AccountInfo.mqh>   // account info wrapper
#include <Trade\DealInfo.mqh>      // deals object
#include <Trade\OrderInfo.mqh>     // pending orders object
#include <ALXQuantCore\Core\Design.mqh>
#include <ALXQuantCore\Modules\StatsTracker.mqh>
#include "CPropGuard.mqh"
#include "CSimplePanel.mqh"

CPositionInfo  m_position;
CTrade         m_trade;
CSymbolInfo    m_symbol;
CAccountInfo   m_account;
CDesign        m_design;
CPropGuard     m_guard;
CSimplePanel   m_panel;
CStatsTracker  m_stats;

enum enCommMode
  {
   comm_round_trip = 0,   // Round trip (in+out total, e.g. $7/lot total)
   comm_out_only   = 1,   // Out only (per side, e.g. $3.50 per side)
  };

enum ENUM_SL_MODE
  {
   SL_FIXED,       // Fixed pips
   SL_ATR          // ATR multiple
  };


//+------------------------------------------------------------------+
//| #Inputs                                                          |
//+------------------------------------------------------------------+
input group                "➜ EA Config"  
input string               InpSetDescription       = "";              // Set description
input int                  InpTime                 = 10;              // Timer refresh interval (seconds)
input ENUM_TIMEFRAMES      InpEATimeframe          = PERIOD_M1;       // EA timeframe (validated in Init)
input int                  InpMaxSpreadPips        = 30;              // Max spread (pips, 0=off)
input int                  InpMaxSlippage          = 30;              // Max slippage (points)
//+------------------------------------------------------------------+
input group                "➜ Position Size"  
input double               StopLossProcent         = 0.8;             // Fallback SL % (0=off)
input double               InpLotRisk              = 0.001;           // Lote risk %   
input int                  TakeProfit              = 1200;            // Take profit (pips)  
//+------------------------------------------------------------------+
input group                "➜ Stop Loss"
input ENUM_SL_MODE         InpSLMode               = SL_ATR;          // Stop mode
input double               InpSLValue              = 2.0;             // Stop value (pips ou Kv)
input int                  InpATRStopsLen          = 10;              // ATRStops: Length
input int                  InpATRStopsPeriod       = 5;               // ATRStops: ATR period
//+------------------------------------------------------------------+
input group                "➜ Trailling Stop"  
input double               InpTraillingStep        = 110.0;           // Trailing distance (pts) 
input double               InpTraliingStart        = 60.0;            // Trailing start (pts)
//+------------------------------------------------------------------+
input group                "➜ Strategy"  
input double               InpTimeAnalise          = 1;              // Time (sec)  
input double               InpPipsStep             = 70.0;           // Pip Step (pips)  
//+------------------------------------------------------------------+
input group                "➜ Commission"
input enCommMode           InpCommMode             = comm_round_trip;// Commission mode
input double               InpCommissionUSDperLot  = 7.0;            // Commission per lot (USD, 0=off)
input double               InpCommBufferUSDperLot  = 0.05;           // Extra buffer per lot (USD)
//+------------------------------------------------------------------+
input group                "➜ Time filter"  
input int                  TimeStart               = 5;              // Time start  
input int                  TimeEnd                 = 18;             // Time end
input bool                 InpTradeOnFriday        = false;          // Operar nas Sextas?
input int                  InpFridayCloseHour      = 17;             // Friday Close (server hour, 0=off)
//+------------------------------------------------------------------+
input group                "➜ Prop Firm Limits"
input double               InpMaxDailyDD           = 2.8;            // Max Daily Drawdown % (0=off)
input double               InpMaxDD                = 4.0;            // Max Total Drawdown % (0=off)
input int                  InpMaxDailyTrades       = 0;              // Max Daily Trades (0=off)
//+------------------------------------------------------------------+
#include "HumanBehavior.mqh"    CHumanBehavior     m_human;
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| #Structs                                                         |
//+------------------------------------------------------------------+
struct Setting
   {
      string   m_ea_name;
      string   m_ea_version;
      ulong    m_magic;
      double   freeze_level;
      //---
      double   stop_level;
      int      m_max_slippage;

      
      string   m_comment;
      int      digits_adjust;
      double   m_adjusted_point;

      double   ExtStopLoss;
      double   ExtTakeProfit;
      double   ExtBreakeven;
      double   ExtTrailingStop;
      double   ExtTrailingStep;
      string   m_status;
      
      datetime m_last_trade_bar_time; 
      int      count_buys;
      int      count_sells;
      int      count_total;
      double   long_lot;
      double   short_lot;
      
      //-- Strategy
      double   price_open;
      datetime time_open;
      datetime time_new;
      double   cached_step_points;       
      datetime last_bar_time;             
      
      bool     IsTimeAllowed;
      bool     IsNewsAllowed;
      bool     IsRiskAllowed;
      bool     IsBusy;
      int      Isglobal_risk;
      double   Isglobal_risk_factor;
      bool     m_can_open_trade;
      
      int      market_direction;
      int      combined_dir;
      //-- Execution Control
      bool     m_need_open_buy;
      bool     m_need_open_sell;
      bool     m_waiting_transaction;     // "true" -> it's forbidden to trade, we expect a transaction
      ulong    m_waiting_order_ticket;    // ticket of the expected order
      bool     m_transaction_confirmed;   // "true" -> transaction confirmed

      //--- Commission state ---
      double   m_commission_per_lot;    // $/lot round-trip efetivo (medido ou fallback)
      double   m_commission_buffer;     // buffer extra $/lot
      enCommMode m_comm_mode;           // round_trip / out_only
      bool     m_comm_active;           // false => filtro totalmente off (input==0)
      double   m_comm_dist_price;       // distância de preço que cobre comissão+buffer (lot-indep)
    } sets;

//+------------------------------------------------------------------+
//|====================== Inicialização ==============================|
//+------------------------------------------------------------------+
int OnInit()
{
//---
   ZeroMemory(sets);   
//--- Validação do timeframe
   if(InpEATimeframe != PERIOD_CURRENT && _Period != (int)InpEATimeframe)
     {
      PrintFormat("Timeframe inválido. Atual: %s | Esperado: %s",EnumToString(_Period),EnumToString(InpEATimeframe));
      return(false);
    }
//---
   EventSetTimer(InpTime);
//---
   if(!m_symbol.Name(_Symbol)) return(false);
   if(!RefreshRates()) return(false);
//---
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
//---
   sets.cached_step_points    = 22.0;       
   sets.last_bar_time         = 0;             
   sets.m_last_trade_bar_time = 0;

//-- Execution Control
   sets.m_need_open_buy           = false;
   sets.m_need_open_sell          = false;
   sets.m_waiting_transaction     = false;    // "true" -> it's forbidden to trade, we expect a transaction
   sets.m_waiting_order_ticket    = 0;        // ticket of the expected order
   sets.m_transaction_confirmed   = false;    // "true" -> transaction confirmed

//---
   m_trade.LogLevel(LOG_LEVEL_NO);
   m_trade.SetExpertMagicNumber(sets.m_magic);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(m_symbol.Name());
   m_trade.SetDeviationInPoints(InpMaxSlippage);
//---   
   if(m_symbol.Digits()==3 || m_symbol.Digits()==5)
       sets.digits_adjust = 10;
   sets.m_adjusted_point = m_symbol.Point() * sets.digits_adjust;

   //--- Commission initialization
   sets.m_comm_mode         = InpCommMode;
   sets.m_comm_active       = (InpCommissionUSDperLot > 0.0);
   sets.m_commission_per_lot = 0.0;
   sets.m_commission_buffer  = InpCommBufferUSDperLot;
   if(sets.m_comm_active)
   {
      sets.m_commission_per_lot = MeasureCommissionPerLot();
      if(sets.m_commission_per_lot <= 0.0)
         sets.m_commission_per_lot = InpCommissionUSDperLot;
      // Ajusta pelo modo: out_only = por lado (custo total = 2 * input), round_trip = total
      if(sets.m_comm_mode == comm_out_only)
         sets.m_commission_per_lot *= 2.0;
      // Adiciona buffer
      sets.m_commission_per_lot += sets.m_commission_buffer;

      // Distância de preço que cobre comissão+buffer (lot-indep)
      double tickSize = m_symbol.TickSize();
      double tickVal  = m_symbol.TickValue();
      if(tickSize > 0.0 && tickVal > 0.0)
         sets.m_comm_dist_price = sets.m_commission_per_lot * tickSize / tickVal;
      else
         sets.m_comm_dist_price = sets.m_commission_per_lot * m_symbol.Point() * 10.0; // fallback
   }
   else
   {
      sets.m_comm_dist_price = 0.0;
   }
   
   //--- Prop Firm Guard initialization
   m_guard.Init(_Symbol, InpMaxDailyDD, InpMaxDD, InpMaxDailyTrades);
   
   //--- StatsTracker initialization
   m_stats.Init(_Symbol, sets.m_magic);
   
   //--- Panel initialization
   m_panel.Init();
   
//---
   m_human.Init();
//---      
   m_design.Init();
//---
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//|===================== Desinicialização ============================|
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   m_panel.Clean();
   ObjectsDeleteAll(0,0, OBJ_LABEL);
   ObjectsDeleteAll(0,0, OBJ_RECTANGLE_LABEL);
}

//+------------------------------------------------------------------+
//|======================== OnTick ===================================|
//+------------------------------------------------------------------+
void OnTick()
{
//---
   MqlTick tick;
//---
   if(!SymbolInfoTick(Symbol(),tick))
      Print("SymbolInfoTick() failed, error = ",GetLastError());
//---
   if(sets.m_waiting_transaction)
      if(sets.m_transaction_confirmed)
        {
         sets.m_waiting_transaction   = false;
         sets.m_waiting_order_ticket  = 0;
         sets.m_transaction_confirmed = false;
        }

   //--- Atualizar guard (verifica DD)
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   m_guard.Update(equity, balance);

   //--- Verificar limites de DD (fecha tudo se violado)
   if(m_guard.IsAnyLimitBreached())
   {
      if(CalculateAllPositions() > 0)
      {
         Print("[GUARD] LIMIT BREACHED! ", m_guard.GetStatus());
         CloseAllPositions();
      }
      return; // não operar enquanto no limite
   }

   //--- Friday Close (fechar posições antes do fim do dia)
   if(IsFridayClose())
   {
      if(CalculateAllPositions() > 0)
      {
         Print("[GUARD] Friday Close ativo. Fechando posições.");
         CloseAllPositions();
      }
      return; // não operar na sexta após hora limite
   }
//---
   if(sets.time_new == 0) sets.time_new = TimeCurrent();
   if(sets.price_open == 0) sets.price_open = tick.bid;

   if(sets.time_new + sets.time_open < TimeCurrent())
   {
      sets.time_new = TimeCurrent();
      sets.price_open = tick.bid;
   }


   ENUM_TIMEFRAMES tfh = PERIOD_H4;

   bool buy_tfh  = iClose(m_symbol.Name(),tfh,0) > iOpen(m_symbol.Name(),tfh,0); 
   bool sell_tfh = iClose(m_symbol.Name(),tfh,0) < iOpen(m_symbol.Name(),tfh,0); 


   sets.m_need_open_buy  = buy_tfh  && (sets.time_new + sets.time_open >= TimeCurrent() && tick.bid - InpPipsStep * m_symbol.Point() >= sets.price_open);
   sets.m_need_open_sell = sell_tfh && (sets.time_new + sets.time_open >= TimeCurrent() && tick.bid + InpPipsStep * m_symbol.Point() <= sets.price_open);

   bool can_trade_open = CalculateAllPositions()==0 &&
                         IsTimeFilter()             &&
                         !IsNewsBlocked()           &&
                         IsSpreadOK()               &&
                         !IsFridayClose()           &&
                         m_guard.CanOpenTrade();   

   if(can_trade_open)
   {
      if(sets.m_need_open_sell) { OpenPosition(POSITION_TYPE_SELL); } ///m_trade.Sell(GetLot(), m_symbol.Name() , tick.bid, 0, 0, sets.m_comment); }
      if(sets.m_need_open_buy)  { OpenPosition(POSITION_TYPE_BUY);  } //m_trade.Buy(GetLot() , m_symbol.Name() , tick.ask, 0, 0, sets.m_comment); }
   }

   //--- Stop Loss em Porcentagem (com commission-aware)
   double sl_protection = (m_account.Balance()/100.0) * StopLossProcent * (-1.0);
   if(sl_protection!=0 && ProfitNetAll(-1) < sl_protection) { CloseAllPositions(); }
   
//--- Trailing Stop
   if(CalculateAllPositions()==1) { Traling(); }
}

//+------------------------------------------------------------------+
//|========================== Funções ================================|
//+------------------------------------------------------------------+
double GetLot(void)
{
   double min  = m_symbol.LotsMin();
   double max  = m_symbol.LotsMax();
   double step = m_symbol.LotsStep();

   // Cálculo bruto
   double lot = (m_account.Balance() / 10.0 * InpLotRisk) / 
                (m_symbol.TickValue() * 100.0 * sets.digits_adjust);

   // 1. Limita primeiro
   lot = MathMax(min, MathMin(max, lot));

   // 2. Ajusta para o step a partir do mínimo (método mais robusto)
   if(step > 0.0)
   {
      double steps = MathFloor((lot - min) / step + 1e-8);
      lot = min + steps * step;
   }

   // 3. Proteção final
   if(lot < min) lot = min;
   if(lot > max) lot = max;

   return(lot);
}

//+------------------------------------------------------------------+
//| Calcula o preço do Stop Loss (Fixo / ATR / Fallback %)           |
//+------------------------------------------------------------------+
double GetStopLossPrice(ENUM_POSITION_TYPE type, double open_price, double lots)
{
   double dist = 0.0;
   double stop_min = m_symbol.StopsLevel() * m_symbol.Point();
   if(stop_min <= 0.0)
      stop_min = (m_symbol.Ask() - m_symbol.Bid()) * 3.0;
   stop_min *= 1.1;

   //--- Modo ATR
   if(InpSLMode == SL_ATR)
   {
      double atr = CustomATR(InpATRStopsPeriod, 1);
      dist = atr * InpSLValue;  // Kv
   }
   //--- Modo Fixo
   else
   {
      dist = InpSLValue * m_symbol.Point() * 10.0;  // pips → pontos
   }

   //--- Fallback: StopLossProcent (se dist == 0)
   if(dist <= 0.0 && StopLossProcent > 0.0 && lots > 0.0)
   {
      double risk_money = m_account.Balance() * StopLossProcent / 100.0;
      double tick_value = m_symbol.TickValue();
      double tick_size  = m_symbol.TickSize();
      if(tick_value > 0.0 && tick_size > 0.0)
         dist = (risk_money / (tick_value * lots)) * tick_size;
   }

   if(dist <= 0.0) return 0.0;

   //--- Calcula preço do SL
   double sl = 0.0;
   if(type == POSITION_TYPE_BUY)
      sl = open_price - dist;
   else
      sl = open_price + dist;

   //--- Validação StopsLevel
   if(type == POSITION_TYPE_BUY && (open_price - sl) < stop_min)
      sl = open_price - stop_min;
   if(type == POSITION_TYPE_SELL && (sl - open_price) < stop_min)
      sl = open_price + stop_min;

   return m_symbol.NormalizePrice(sl);
}


//+------------------------------------------------------------------+
//| IsTimeFilter                                                     |
//+------------------------------------------------------------------+
bool IsTimeFilter(void)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // === Filtro de Sexta-feira ===
   if(dt.day_of_week == 5) { if(!InpTradeOnFriday) { return(false); } }

   if(dt.hour >= TimeStart && dt.hour < TimeEnd) { return(true); } 
   
   return(false);
}

//+------------------------------------------------------------------+
//| IsNewsFilter                                                     |
//+------------------------------------------------------------------+
bool IsNewsBlocked(void)
{
   bool InpNewsBlockIfNoGlobal =  false;
   if(!GlobalVariableCheck("NI_CAN_TRADE"))
      return InpNewsBlockIfNoGlobal;   // false = opera livre sem news EA

   return (GlobalVariableGet("NI_CAN_TRADE") < 0.5);
}

//+------------------------------------------------------------------+
//| IsSpreadOK - Verifica se spread está dentro do limite             |
//+------------------------------------------------------------------+
bool IsSpreadOK(void)
{
   if(InpMaxSpreadPips <= 0) return true; // filtro desligado
   
   double spread_pips = (m_symbol.Ask() - m_symbol.Bid()) / m_symbol.Point() / 10.0;
   return (spread_pips <= InpMaxSpreadPips);
}

//+------------------------------------------------------------------+
//| IsFridayClose - Verifica se é hora de fechar sexta                |
//+------------------------------------------------------------------+
bool IsFridayClose(void)
{
   if(InpFridayCloseHour <= 0) return false; // filtro desligado
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   //--- Sexta-feira (day_of_week=5) com horário >= hora de fechar
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour)
      return true;
   
   return false;
}


//+------------------------------------------------------------------+
//| Calculate all positions Buy and Sell                             |
//+------------------------------------------------------------------+
int CalculateAllPositions(void)
  {
   int count=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
      if(m_position.SelectByIndex(i)) // selects the position by index for further access to its properties
         if(m_position.Symbol()==m_symbol.Name() && m_position.Magic()==sets.m_magic)
           {
               count++;
           }
//---
   return(count);
  }

//+------------------------------------------------------------------+
//| Close positions                                                  |
//+------------------------------------------------------------------+
void CloseAllPositions(void)
  {
   for(int i=PositionsTotal()-1;i>=0;i--) // returns the number of current positions
      if(m_position.SelectByIndex(i))     // selects the position by index for further access to its properties
         if(m_position.Symbol()==Symbol() && m_position.Magic()==sets.m_magic)
            m_trade.PositionClose(m_position.Ticket()); // close a position by the specified symbol
  }


void Traling()
{
   double Point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double commFloor = CommissionDist(); // cost floor (comissão+buffer) em preço

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

         if(posType == POSITION_TYPE_BUY && InpTraillingStep != 0)
         {
            double firstLockPrice = NormalizeDouble(openPrice + InpTraliingStart * Point + commFloor, digits);
            double trailPrice     = NormalizeDouble(Bid - InpTraillingStep * Point, digits);

            // First lock: cost floor (breakeven real = abertura + comissão)
            if((currentSL < openPrice || currentSL == 0) && Bid - (InpTraillingStep + InpTraliingStart) * Point >= openPrice + commFloor)
               m_trade.PositionModify(ticket, firstLockPrice, currentTP);

            // Subsequent steps: only move if above cost floor
            if(currentSL >= openPrice + commFloor && trailPrice > currentSL)
               m_trade.PositionModify(ticket, trailPrice, currentTP);
         }

         if(posType == POSITION_TYPE_SELL && InpTraillingStep != 0)
         {
            double firstLockPrice = NormalizeDouble(openPrice - InpTraliingStart * Point - commFloor, digits);
            double trailPrice     = NormalizeDouble(Ask + InpTraillingStep * Point, digits);

            if((currentSL > openPrice || currentSL == 0) && Ask + (InpTraillingStep + InpTraliingStart) * Point <= openPrice - commFloor)
               m_trade.PositionModify(ticket, firstLockPrice, currentTP);

            if(currentSL <= openPrice - commFloor && trailPrice < currentSL)
               m_trade.PositionModify(ticket, trailPrice, currentTP);
         }
      }
   }
}


//+------------------------------------------------------------------+
//| Lucro flutuante no par atual                                     |
//+------------------------------------------------------------------+
double Profit(int type)
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == sets.m_magic)
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

//+------------------------------------------------------------------+
//| Lucro flutuante global na conta                                   |
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
         {
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }
   }
   return profit;
}

//--- Timer
void OnTimer()
{
   //--- Salvar estado do guard
   m_guard.SaveState();
   
   //--- Atualizar stats
   m_stats.Update();
   
   //--- Obter stats
   AssetStats as;
   PerfStats ps;
   m_stats.GetAssetStats(as);
   m_stats.GetPerfStats(ps);
   
   //--- Atualizar painel
   m_panel.SetGuardStartBalance(m_guard.GetDailyStartBalance());
   m_panel.Draw(
      EA_NAME, EA_VERSION, sets.m_magic,
      IsTimeFilter(), InpTradeOnFriday, IsFridayClose(),
      IsNewsBlocked(), m_symbol.Ask() - m_symbol.Bid(), InpMaxSpreadPips * m_symbol.Point() * 10.0,
      m_guard.IsAnyLimitBreached(), m_guard.GetDailyDDPercent(), m_guard.GetMaxDDPercent(),
      m_guard.GetDailyTradeCount(), m_guard.GetMaxDailyTrades(),
      as, ps
   );
}

//+------------------------------------------------------------------+
//| TradeTransaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
//--- get transaction type as enumeration value 
   ENUM_TRADE_TRANSACTION_TYPE type=trans.type;
//--- if transaction is result of addition of the transaction in history
   if(type==TRADE_TRANSACTION_DEAL_ADD)
     {
      long     deal_ticket       =0;
      long     deal_order        =0;
      long     deal_time         =0;
      long     deal_time_msc     =0;
      long     deal_type         =-1;
      long     deal_entry        =-1;
      long     deal_magic        =0;
      long     deal_reason       =-1;
      long     deal_position_id  =0;
      double   deal_volume       =0.0;
      double   deal_price        =0.0;
      double   deal_commission   =0.0;
      double   deal_swap         =0.0;
      double   deal_profit       =0.0;
      string   deal_symbol       ="";
      string   deal_comment      ="";
      string   deal_external_id  ="";
      if(HistoryDealSelect(trans.deal))
        {
         deal_ticket       =HistoryDealGetInteger(trans.deal,DEAL_TICKET);
         deal_order        =HistoryDealGetInteger(trans.deal,DEAL_ORDER);
         deal_time         =HistoryDealGetInteger(trans.deal,DEAL_TIME);
         deal_time_msc     =HistoryDealGetInteger(trans.deal,DEAL_TIME_MSC);
         deal_type         =HistoryDealGetInteger(trans.deal,DEAL_TYPE);
         deal_entry        =HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
         deal_magic        =HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
         deal_reason       =HistoryDealGetInteger(trans.deal,DEAL_REASON);
         deal_position_id  =HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);

         deal_volume       =HistoryDealGetDouble(trans.deal,DEAL_VOLUME);
         deal_price        =HistoryDealGetDouble(trans.deal,DEAL_PRICE);
         deal_commission   =HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
         deal_swap         =HistoryDealGetDouble(trans.deal,DEAL_SWAP);
         deal_profit       =HistoryDealGetDouble(trans.deal,DEAL_PROFIT);

         deal_symbol       =HistoryDealGetString(trans.deal,DEAL_SYMBOL);
         deal_comment      =HistoryDealGetString(trans.deal,DEAL_COMMENT);
         deal_external_id  =HistoryDealGetString(trans.deal,DEAL_EXTERNAL_ID);
        }
      else
         return;
       if(deal_symbol==m_symbol.Name() && deal_magic==sets.m_magic)
          if(deal_entry==DEAL_ENTRY_IN)
             if(deal_type==DEAL_TYPE_BUY || deal_type==DEAL_TYPE_SELL)
               {
                if(sets.m_waiting_transaction)
                   if(sets.m_waiting_order_ticket==deal_order)
                     {
                      sets.m_transaction_confirmed=true;
                      m_guard.IncrementTradeCount();
                     }
              }
     }
  }

//+------------------------------------------------------------------+
//| Refreshes the symbol quotes data                                 |
//+------------------------------------------------------------------+
bool RefreshRates(void)
  {
//--- refresh rates
   if(!m_symbol.RefreshRates())
      return(false);
//--- check for invalid price
   if(m_symbol.Ask()==0 || m_symbol.Bid()==0)
      return(false);
//---
   return(true);
  }

//+------------------------------------------------------------------+
//| Custom ATR - Cálculo puro sem indicador                          |
//+------------------------------------------------------------------+
double CustomATR(int atr_period, int shift=1)
{
   if(atr_period <= 0) return 0.0;
   
   double sum_tr = 0.0;
   int valid_bars = 0;
   
   for(int i = shift; i < shift + atr_period; i++)
   {
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      double l = iLow(_Symbol, PERIOD_CURRENT, i);
      double c = iClose(_Symbol, PERIOD_CURRENT, i + 1);
      
      if(h == 0 || l == 0 || c == 0) continue;
      
      double tr = MathMax(h - l, MathMax(MathAbs(h - c), MathAbs(l - c)));
      sum_tr += tr;
      valid_bars++;
   }
   
   return (valid_bars > 0) ? sum_tr / valid_bars : 0.0;
}

//+------------------------------------------------------------------+
//| Mede comissão real $/lot dos últimos 30 dias de deals             |
//+------------------------------------------------------------------+
double MeasureCommissionPerLot()
{
   if(!HistorySelect(TimeCurrent() - 30*86400, TimeCurrent())) return 0.0;

   double totalComm = 0.0;
   double totalVol  = 0.0;
   int count = HistoryDealsTotal();
   for(int i = count - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != sets.m_magic) continue;

      // Apenas deals de entrada (DEAL_ENTRY_IN) contam comissão já paga
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;

      double comm = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      double vol  = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      if(vol > 0.0 && comm < 0.0) // comissão é negativa
      {
         totalComm += -comm; // valor absoluto
         totalVol  += vol;
      }
   }

   if(totalVol <= 0.0) return 0.0;
   return totalComm / totalVol; // $/lot round-trip real
}
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
//| Comissão efetiva $/lot (com buffer)                               |
//+------------------------------------------------------------------+
double CommissionCostPerLot()
{
   if(!sets.m_comm_active) return 0.0;
   return sets.m_commission_per_lot;
}

//+------------------------------------------------------------------+
//| Distância de preço que cobre comissão+buffer (lot-indep)          |
//+------------------------------------------------------------------+
double CommissionDist()
{
   if(!sets.m_comm_active) return 0.0;
   return sets.m_comm_dist_price;
}

//+------------------------------------------------------------------+
//| Comissão total para todas as posições abertas                     |
//+------------------------------------------------------------------+
double CommissionTotal(int type)
{
   if(!sets.m_comm_active) return 0.0;
   double lots = AllLots(type);
   if(lots <= 0.0) return 0.0;
   return lots * sets.m_commission_per_lot;
}

//+------------------------------------------------------------------+
//| Lucro líquido (profit - comissão) por símbolo                     |
//+------------------------------------------------------------------+
double ProfitNet(int type)
{
   double gross = Profit(type);
   if(!sets.m_comm_active) return gross;
   return gross - CommissionTotal(type);
}

//+------------------------------------------------------------------+
//| Lucro líquido global (profit - comissão) todas as posições        |
//+------------------------------------------------------------------+
double ProfitNetAll(int type)
{
   double gross = ProfitAll(type);
   if(!sets.m_comm_active) return gross;
   return gross - CommissionTotal(type);
}

//+------------------------------------------------------------------+
//| Gera Magic Number Único por Conta, Ativo e Timeframe             |
//+------------------------------------------------------------------+
ulong AutoMagicID(string ea_name, string version="1.0")
{
   // Adicionamos o Account Login para garantir unicidade absoluta entre contas
   ulong accountLogin = (ulong)AccountInfoInteger(ACCOUNT_LOGIN);
   string key = ea_name + "|" + version + "|" + _Symbol + "|" + IntegerToString(_Period) + "|" + IntegerToString(accountLogin);
   
   ulong hash = 5381;
   for(int i = 0; i < StringLen(key); i++)
      hash = ((hash << 5) + hash) + StringGetCharacter(key, i);

   // Mantém o mask 0x7FFFFFFF para garantir que seja um inteiro positivo válido (max ~2.14 bilhões)
   return hash & 0x7FFFFFFF;
}

//+------------------------------------------------------------------+
//| Gera Comentário da Ordem com Dados do Regime (Anti-Compliance)   |
//+------------------------------------------------------------------+
string GenerateRegimeComment()
{
   // 1. Sufixo único da conta (últimos 4 dígitos do login)
   ulong accLogin = AccountInfoInteger(ACCOUNT_LOGIN);
   int uniqueSuffix = (int)(accLogin % 9999);
   
   // 2. Obter dados do regime no exato momento da entrada
   // NOTA: Substitua 'GetHurst()' e 'GetR2()' pelos nomes reais 
   // dos métodos públicos da sua classe CMacroRegimeEngine
   double hurstVal = 0.50; //m_regime.GetLastHurst();      // Ex: 0.522
   double r2Val    = 0.50; //m_regime.GetConfidence();     // Ex: 0.64
   
   // 3. Formatar para 2 casas decimais (economiza espaço e padroniza)
   string hStr = DoubleToString(hurstVal, 2);
   string rStr = DoubleToString(r2Val, 2);
   
   // 4. Montar string compacta e profissional (Ex: "QFX_H0.52_R20.64_8492")
   // StringFormat é mais seguro e rápido que concatenação com '+'
   return StringFormat("QFX_H%s_R%s_%04d", hStr, rStr, uniqueSuffix);
}


//+------------------------------------------------------------------+
//| Open positions - Versão limpa e integrada                        |
//+------------------------------------------------------------------+
void OpenPosition(const ENUM_POSITION_TYPE pos_type)
{
   if(!RefreshRates() || !m_symbol.Refresh())
      return;

   //--- StopsLevel
   double stop_level = m_symbol.StopsLevel() * m_symbol.Point();
   if(stop_level == 0.0)
      stop_level = (m_symbol.Ask() - m_symbol.Bid()) * 3.0;
   stop_level *= 1.1;

   //==============================================================
   // 1. Human Behavior
   //==============================================================
   m_human.NewTrade();

   if(m_human.ShouldSkipTrade())
   {
      return;
   }

   //==============================================================
   // 2. Lote
   //==============================================================
   double lots = GetLot();
   if(lots <= 0.0) return;

   //==============================================================
   // 3. Preço de entrada + Jitter
   //==============================================================
   double price = (pos_type == POSITION_TYPE_BUY) ? m_symbol.Ask() : m_symbol.Bid();
   price += m_human.GetEntryJitter();
   price = m_symbol.NormalizePrice(price);

   //==============================================================
   // 4. SL e TP
   //==============================================================
   double sl = 0.0, tp = 0.0;

   if(pos_type == POSITION_TYPE_BUY)
   {
      sl = GetStopLossPrice(POSITION_TYPE_BUY, price, lots);
      tp = GetTakeProfitPrice(ORDER_TYPE_BUY, price, 1.0);
   }
   else
   {
      sl = GetStopLossPrice(POSITION_TYPE_SELL, price, lots);
      tp = GetTakeProfitPrice(ORDER_TYPE_SELL, price, 1.0);
   }

   //--- Validação StopsLevel
   if(pos_type == POSITION_TYPE_BUY)
   {
      if(sl > 0.0 && (m_symbol.Bid() - sl) < stop_level)
         sl = m_symbol.Bid() - stop_level;
      if(tp > 0.0 && (tp - m_symbol.Bid()) < stop_level)
         tp = m_symbol.Bid() + stop_level;
   }
   else
   {
      if(sl > 0.0 && (sl - m_symbol.Ask()) < stop_level)
         sl = m_symbol.Ask() + stop_level;
      if(tp > 0.0 && (m_symbol.Ask() - tp) < stop_level)
         tp = m_symbol.Ask() - stop_level;
   }

   if(sl > 0.0) sl = m_symbol.NormalizePrice(sl);
   if(tp > 0.0) tp = m_symbol.NormalizePrice(tp);

   //==============================================================
   // 5. Delay humano
   //==============================================================
   m_human.SleepHuman();

   //==============================================================
   // 6. Envia ordem
   //==============================================================
   bool result = false;

   if(pos_type == POSITION_TYPE_BUY)
      result = m_trade.Buy(lots, m_symbol.Name(), price, sl, tp, sets.m_comment);
   else
      result = m_trade.Sell(lots, m_symbol.Name(), price, sl, tp, sets.m_comment);

   if(result)
   {
      if(m_trade.ResultRetcode() == 10009) // TRADE_RETCODE_PLACED
      {
         sets.m_waiting_transaction   = true;
         sets.m_waiting_order_ticket  = m_trade.ResultOrder();
      }
   }
   else
   {
      Print("Falha ao enviar ordem. Retcode: ", m_trade.ResultRetcode(),
            " | ", m_trade.ResultRetcodeDescription());
   }
}

 

//+------------------------------------------------------------------+
//| Calcula o ADR dos últimos 7 dias                                 |
//+------------------------------------------------------------------+
double GetADR(int days = 7)
{
   double sum = 0.0;
   int    count = 0;

   for(int i = 1; i <= days; i++)   // começa do 1 (ontem) para não usar o dia atual incompleto
   {
      double high = iHigh(_Symbol, PERIOD_D1, i);
      double low  = iLow(_Symbol, PERIOD_D1, i);

      if(high > 0 && low > 0)
      {
         sum += (high - low);
         count++;
      }
   }

   if(count == 0) return 0.0;
   return sum / count;
}

//+------------------------------------------------------------------+
//| Retorna o preço do Take Profit (menor entre ADR e pips)           |
//+------------------------------------------------------------------+
double GetTakeProfitPrice(ENUM_ORDER_TYPE type, double open_price, double adr_multiplier = 1.0)
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0.0) return 0.0;
   
   double tp_price = 0.0;
   
   //--- 1. Distância via ADR
   double adr = GetADR(7);
   double dist_adr = (adr > 0.0) ? adr * adr_multiplier : 0.0;
   
   //--- 2. Distância via pips (input)
   double dist_pips = 0.0;
   if(TakeProfit > 0)
      dist_pips = TakeProfit * 10.0 * m_symbol.Point(); // pips → pontos
   
   //--- 3. Usa a menor distância (ou ADR se pips=0, ou pips se ADR=0)
   double distance = 0.0;
   if(dist_adr > 0.0 && dist_pips > 0.0)
      distance = MathMin(dist_adr, dist_pips); // menor dos dois
   else if(dist_adr > 0.0)
      distance = dist_adr;
   else if(dist_pips > 0.0)
      distance = dist_pips;
   else
      return 0.0; // sem TP
   
   //--- Calcula preço
   if(type == ORDER_TYPE_BUY)
      tp_price = open_price + distance;
   else if(type == ORDER_TYPE_SELL)
      tp_price = open_price - distance;
   
   // Normaliza para o tick size
   tp_price = NormalizeDouble(tp_price / tick_size, 0) * tick_size;
   
   return tp_price;
}