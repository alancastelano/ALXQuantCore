//+------------------------------------------------------------------+
//|                                             RiskManager.mqh       |
//|                 Prop Firm Compliance Risk Manager v4             |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.8.00 - 2026-08-03 - Refactor: Equity PnL, Timezone, Robust Close, ALX Fix
    v.8.01 - 2026-08-07 - Fix: reset mensal nao gravava m_state.month, disparava em todo tick.
*/

#include <Trade\Trade.mqh>

//--- Max Drawdown model
enum ENUM_RM_DD_MODE
{
   RM_DD_STATIC          = 0,    
   RM_DD_TRAILING_EOD    = 1,    
   RM_DD_TRAILING_INTRADAY = 2,  
   RM_DD_STATIC_MONTHLY  = 3,    
};

//--- Daily Loss model
enum ENUM_RM_DLL_MODE
{
   RM_DLL_DAY_START = 0,    
   RM_DLL_FTMO      = 1,    
};

//--- Prop Firm Presets
enum ENUM_RM_PRESET
{
   RM_MANUAL       = 0,
   RM_FTMO_PHASE1  = 1,
   RM_FTMO_PHASE2  = 2,
   RM_CONSERVATOR  = 3,
   RM_ALXQUANT     = 4
};

//--- Razão de bloqueio
enum ENUM_RM_BLOCK_REASON
{
   RM_REASON_NONE             = 0,
   RM_REASON_DAILY_LOSS_EQUITY,
   RM_REASON_DAILY_LOSS_PNL,
   RM_REASON_MAX_DRAWDOWN,
   RM_REASON_PROFIT_TARGET,
   RM_REASON_MAX_DAILY_TRADES,
   RM_REASON_MAX_DAILY_PROFIT,
   RM_REASON_MAX_DAILY_LOSS,
   RM_REASON_DAILY_PROFIT,
   RM_REASON_WEEKLY_PROFIT,
   RM_REASON_WEEKLY_LOSS,
   RM_REASON_MONTHLY_LOSS
};

//--- Modo de interpretação dos limites
enum ENUM_RM_LIMIT_MODE
{
   RM_LIMIT_MONEY = 0,
   RM_LIMIT_PCT   = 1,
};

input group              "▸ Risk Manager Config" 
input bool               InpRM_Enabled             = true;
input ENUM_RM_PRESET     InpRM_Preset              = RM_ALXQUANT;
input ENUM_RM_LIMIT_MODE InpRM_LimitMode           = RM_LIMIT_MONEY;
input int                InpRM_ServerTimeOffsetHours= 2;          // Offset Broker vs Prop Firm (Horário de Praga)
input double             InpRM_BufferPct           = 0.2;        // Safety buffer % (aplicado em todos os limites)
input bool               InpRM_CloseOnBreach       = true;       // Close positions on breach
input double             InpRM_ConsistencyPct      = 30.0;       // Consistency Rule % (0=off)

input group              "▸ Manual Limits"
input int                InpRM_MaxDailyTrades      = 0;
input int                InpRM_MaxDailyProfit      = 0;
input int                InpRM_MaxDailyLoss        = 0;
input double             InpDailyLimitProfitValue  = 0.0;
input double             InpDailyLimitLossValue    = 0.0;
input double             InpWeeklyLimitProfitValue = 0.0;
input double             InpWeeklyLimitLossValue   = 0.0;
input double             InpMonthlyLimitProfitValue= 0.0;
input double             InpMonthlyLimitLossValue  = 0.0;

input group              "▸ ALXQuant Strategy Params"
input double             InpALX_MonthlyRiskPct     = 10.0;       // % do saldo inicial para risco mensal (ex: 10)
input double             InpALX_RiskFactor         = 1.2;        // Fator de ganho sobre perda (1.2 = 20% maior)

class CRiskManager
{
private:
   struct SRiskParams
   {
      ulong   magic;
      bool    enabled;
      double  daily_loss_pct;       
      double  max_drawdown_pct;     
      double  profit_target_pct;    
      double  consistency_pct;      
      double  buffer_pct;           
      ENUM_RM_DD_MODE  dd_mode;     
      ENUM_RM_DLL_MODE dll_mode;    
      int     max_daily_trades;
      int     max_daily_profit_trades;
      int     max_daily_loss_trades;
      bool    close_on_breach;
      double  risk_per_trade_pct;    
      ENUM_RM_LIMIT_MODE limit_mode;
      double  daily_profit_limit;     
      double  daily_loss_limit;       
      double  weekly_profit_limit;    
      double  weekly_loss_limit;      
      double  monthly_profit_limit;   
      double  monthly_loss_limit;     
   };
   SRiskParams m_params;

   struct SRiskState
   {
      int      day_of_year;
      int      month;
      double   initial_balance;     
      double   monthly_ref_balance; 
      double   peak_balance;        
      double   max_eod_balance;     
      double   day_start_equity;    
      double   week_start_equity;   
      double   month_start_equity;  
      int      week_key;            
      bool     blocked;
      string   block_reason;
      ENUM_RM_BLOCK_REASON block_reason_enum;
      datetime last_scan;           
      datetime last_persist;        
      // Consistency
      int      trading_days;
      int      positive_days;
      datetime last_trade_day;
      double   best_day_pnl;        
      double   total_positive_pnl;  
      // Trades count
      int      daily_trades;
      int      daily_profit_trades;
      int      daily_loss_trades;
      // PnL (Equity Based)
      double   daily_pnl;           
      double   weekly_pnl;          
      double   monthly_pnl;         
   };
   SRiskState m_state;

   CTrade       m_trade;

   void   RefreshPnL();
   void   CheckLimits();
   void   Block(ENUM_RM_BLOCK_REASON reason, string text);
   void   Unblock();
   bool   IsMaxDrawdownReason() const;
   bool   IsProfitTargetReason() const;
   bool   IsMonthlyLossReason() const;
   bool   IsDailyReason() const;
   bool   IsWeeklyReason() const;
   int    WeeklyKey(datetime t) const;
   double LimitAmount(double limit_value, double base) const;
   double GetBufferAmount(double base) const;

   void   SetPresetLimits(ENUM_RM_PRESET preset);
   void   ApplyManualLimits();

   double DDLimit()         const;
   double DailyLossLimit()  const;
   void   ConsistencyStats(double &best_day, double &total_pos, int &positive_days) const;

   string GV_Prefix() const;
   void   PersistState();
   void   RestoreState();
   string ReasonText(ENUM_RM_BLOCK_REASON reason) const;
   void   DeletePendingOrders();
   datetime GetServerTime();
   double risk ;

public:
   CRiskManager();
   ~CRiskManager() {}

   void   Init(ulong magic);
   void   Update();
   void   OnTransaction(const MqlTradeTransaction &trans);
   bool   CanOpenNewOrder();
   bool   CanOpenTrade() { return CanOpenNewOrder(); }
   void   ManagePositions();

   void   SetRiskPerTradePct(double pct);

   double GetDailyPnL()      const { return m_state.daily_pnl; }
   double GetWeeklyPnL()     const { return m_state.weekly_pnl; }
   double GetMonthlyPnL()    const { return m_state.monthly_pnl; }
   double GetDrawdownPct()   const;
   double GetDailyPct()      const;
   double GetProfitPct()     const;
   bool   IsBlocked()        const { return m_state.blocked; }
   string GetBlockReason()   const { return m_state.block_reason; }
};

CRiskManager::CRiskManager()
{
   ZeroMemory(m_params);
   ZeroMemory(m_state);
}

datetime CRiskManager::GetServerTime()
{
   return TimeCurrent() + (InpRM_ServerTimeOffsetHours * 3600);
}

void CRiskManager::Init(ulong magic)
{
   m_params.magic   = magic;
   m_params.enabled = InpRM_Enabled;
   m_trade.SetExpertMagicNumber(magic);

   if(!m_params.enabled) return;

   // 1. Capture initial balances FIRST
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   m_state.initial_balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   m_state.monthly_ref_balance = m_state.initial_balance;
   m_state.peak_balance        = equity;
   m_state.max_eod_balance     = m_state.initial_balance;
   m_state.day_start_equity    = equity;
   m_state.week_start_equity   = equity;
   m_state.month_start_equity  = equity;

   // 2. Configure limits
   if(InpRM_Preset == RM_MANUAL)
      ApplyManualLimits();
   else
      SetPresetLimits(InpRM_Preset);

   m_params.buffer_pct = MathMax(0.0, InpRM_BufferPct);
   m_params.consistency_pct = (InpRM_Preset == RM_ALXQUANT) ? 0.0 : MathMax(0.0, InpRM_ConsistencyPct);

   // 3. Init State
   MqlDateTime dt;
   TimeToStruct(GetServerTime(), dt);
   m_state.day_of_year         = dt.day_of_year;
   m_state.month               = dt.mon;
   m_state.week_key            = WeeklyKey(GetServerTime());
   m_state.blocked             = false;
   m_state.block_reason_enum   = RM_REASON_NONE;
   m_state.daily_trades        = 0;
   m_state.daily_profit_trades = 0;
   m_state.daily_loss_trades   = 0;
   m_state.trading_days        = 0;
   m_state.positive_days       = 0;
   m_state.last_trade_day      = 0;
   m_state.best_day_pnl        = 0.0;
   m_state.total_positive_pnl  = 0.0;
   m_state.last_scan           = 0;
   m_state.last_persist        = 0;

   RestoreState();
   PersistState();

   RefreshPnL();
   m_state.last_scan = TimeCurrent();

   Print("[RISK v4] Init OK | Magic:", magic, " Preset:", EnumToString(InpRM_Preset));
}

void CRiskManager::SetPresetLimits(ENUM_RM_PRESET preset)
{
   m_params.close_on_breach = InpRM_CloseOnBreach;
   m_params.dd_mode = RM_DD_STATIC;
   m_params.dll_mode = RM_DLL_FTMO;

   switch(preset)
   {
      case RM_FTMO_PHASE1:
         m_params.daily_loss_pct=4.0; m_params.max_drawdown_pct=8.0; m_params.profit_target_pct=8.0;
         m_params.consistency_pct=30.0;
         m_params.limit_mode = RM_LIMIT_MONEY; // FTMO usa pisos de equity, limites de janela zerados
         m_params.daily_profit_limit=0; m_params.daily_loss_limit=0;
         m_params.weekly_profit_limit=0; m_params.weekly_loss_limit=0;
         m_params.monthly_profit_limit=0; m_params.monthly_loss_limit=0;
         m_params.max_daily_trades=0; m_params.max_daily_profit_trades=0; m_params.max_daily_loss_trades=0;
         break;
      case RM_FTMO_PHASE2:
         m_params.daily_loss_pct=5.0; m_params.max_drawdown_pct=5.0; m_params.profit_target_pct=5.0;
         m_params.consistency_pct=30.0;
         m_params.limit_mode = RM_LIMIT_MONEY;
         m_params.daily_profit_limit=0; m_params.daily_loss_limit=0;
         m_params.weekly_profit_limit=0; m_params.weekly_loss_limit=0;
         m_params.monthly_profit_limit=0; m_params.monthly_loss_limit=0;
         m_params.max_daily_trades=0; m_params.max_daily_profit_trades=0; m_params.max_daily_loss_trades=0;
         break;
      case RM_CONSERVATOR:
         m_params.daily_loss_pct=5.0; m_params.max_drawdown_pct=0.9; m_params.profit_target_pct=2.2;
         m_params.dd_mode = RM_DD_STATIC_MONTHLY; m_params.dll_mode = RM_DLL_DAY_START;
         m_params.limit_mode = RM_LIMIT_MONEY;
         m_params.daily_profit_limit=0; m_params.daily_loss_limit=0;
         m_params.weekly_profit_limit=0; m_params.weekly_loss_limit=0;
         m_params.monthly_profit_limit=0; m_params.monthly_loss_limit=0;
         m_params.max_daily_trades=0; m_params.max_daily_profit_trades=0; m_params.max_daily_loss_trades=0;
         break;
      case RM_ALXQUANT:
         m_params.daily_loss_pct=3.0; m_params.max_drawdown_pct=0.9; m_params.profit_target_pct=2.2;
         m_params.dd_mode = RM_DD_STATIC_MONTHLY; m_params.dll_mode = RM_DLL_DAY_START;
         
         m_params.max_daily_trades=3; m_params.max_daily_profit_trades=2; m_params.max_daily_loss_trades=1;
         
         // ALXQuant Logic
         m_params.limit_mode = RM_LIMIT_MONEY; // Forçado Financeiro
         risk = m_state.initial_balance * (InpALX_MonthlyRiskPct / 100.0) / 3.0;
         
         m_params.monthly_loss_limit   = NormalizeDouble(risk, 2);
         m_params.monthly_profit_limit = NormalizeDouble(risk * InpALX_RiskFactor, 2);
         
         m_params.weekly_loss_limit    = NormalizeDouble(m_params.monthly_loss_limit / 4.0, 2);
         m_params.weekly_profit_limit  = NormalizeDouble(m_params.weekly_loss_limit * InpALX_RiskFactor, 2);
         
         m_params.daily_loss_limit     = NormalizeDouble(m_params.weekly_loss_limit / 4.0, 2);
         m_params.daily_profit_limit   = NormalizeDouble(m_params.daily_loss_limit * InpALX_RiskFactor, 2);
         break;
   }
}

void CRiskManager::ApplyManualLimits()
{
   m_params.daily_loss_pct     = 0.0;
   m_params.max_drawdown_pct   = 0.0;
   m_params.profit_target_pct  = 0.0;
   m_params.dd_mode            = RM_DD_STATIC;
   m_params.dll_mode           = RM_DLL_DAY_START;
   m_params.consistency_pct    = MathMax(0.0, InpRM_ConsistencyPct);
   m_params.max_daily_trades   = MathMax(0, InpRM_MaxDailyTrades);
   m_params.max_daily_profit_trades = MathMax(0, InpRM_MaxDailyProfit);
   m_params.max_daily_loss_trades   = MathMax(0, InpRM_MaxDailyLoss);
   m_params.limit_mode         = InpRM_LimitMode;
   
   m_params.daily_profit_limit    = MathMax(0.0, InpDailyLimitProfitValue);
   m_params.daily_loss_limit      = MathMax(0.0, InpDailyLimitLossValue);
   m_params.weekly_profit_limit   = MathMax(0.0, InpWeeklyLimitProfitValue);
   m_params.weekly_loss_limit     = MathMax(0.0, InpWeeklyLimitLossValue);
   m_params.monthly_profit_limit  = MathMax(0.0, InpMonthlyLimitProfitValue);
   m_params.monthly_loss_limit    = MathMax(0.0, InpMonthlyLimitLossValue);
   m_params.close_on_breach       = InpRM_CloseOnBreach;
}

double CRiskManager::GetBufferAmount(double base) const
{
   return base * m_params.buffer_pct / 100.0;
}

double CRiskManager::DDLimit() const
{
   double base = 0.0, amt = 0.0;
   switch(m_params.dd_mode)
   {
      case RM_DD_STATIC:           base = m_state.initial_balance; amt = base * m_params.max_drawdown_pct / 100.0; break;
      case RM_DD_STATIC_MONTHLY:   base = m_state.monthly_ref_balance; amt = base * m_params.max_drawdown_pct / 100.0; break;
      case RM_DD_TRAILING_EOD:     base = MathMax(m_state.monthly_ref_balance, m_state.max_eod_balance); amt = base * m_params.max_drawdown_pct / 100.0; break;
      case RM_DD_TRAILING_INTRADAY:base = MathMax(m_state.monthly_ref_balance, m_state.peak_balance); amt = base * m_params.max_drawdown_pct / 100.0; break;
   }
   return base - amt - GetBufferAmount(base);
}

double CRiskManager::DailyLossLimit() const
{
   double pct = m_params.daily_loss_pct / 100.0;
   double floor = 0.0;
   double base_ref = m_state.day_start_equity;

   if(m_params.dll_mode == RM_DLL_FTMO) {
      floor = m_state.day_start_equity * (1.0 - pct);
   } else {
      floor = m_state.day_start_equity * (1.0 - pct);
   }
   return floor - GetBufferAmount(base_ref);
}

void CRiskManager::RefreshPnL()
{
   // PnL calculation based on Equity drop (Prop Firm standard)
   double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   m_state.daily_pnl   = current_equity - m_state.day_start_equity;
   m_state.weekly_pnl  = current_equity - m_state.week_start_equity;
   m_state.monthly_pnl = current_equity - m_state.month_start_equity;

   // History scan only for trade counts and consistency
   MqlDateTime dt;
   TimeToStruct(GetServerTime(), dt);
   datetime day_start   = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   datetime week_start  = day_start - ((dt.day_of_week + 6) % 7) * 86400;
   datetime month_start = StringToTime(StringFormat("%04d.%02d.01", dt.year, dt.mon));
   datetime scan_from = MathMin(month_start, week_start);

   m_state.daily_trades = 0;
   m_state.daily_profit_trades = 0;
   m_state.daily_loss_trades = 0;

   if(HistorySelect(scan_from, TimeCurrent()))
   {
      int total = HistoryDealsTotal();
      ulong pos_ids[];
      ArrayResize(pos_ids, 0);

      for(int i = 0; i < total; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_params.magic) continue;

         datetime deal_time = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         ulong    pos_id    = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
         double   net       = HistoryDealGetDouble(ticket, DEAL_PROFIT) + 
                              HistoryDealGetDouble(ticket, DEAL_COMMISSION) + 
                              HistoryDealGetDouble(ticket, DEAL_SWAP);

         if(deal_time >= day_start)
         {
            int idx = -1;
            for(int p=0; p<ArraySize(pos_ids); p++) if(pos_ids[p]==pos_id) { idx=p; break; }
            if(idx < 0)
            {
               int n = ArraySize(pos_ids);
               ArrayResize(pos_ids, n+1);
               pos_ids[n] = pos_id;
               m_state.daily_trades++;
               if(net >= 0) m_state.daily_profit_trades++; else m_state.daily_loss_trades++;
         }
         }
      }
   }
}

void CRiskManager::ConsistencyStats(double &best_day, double &total_pos, int &positive_days) const
{
   best_day       = m_state.best_day_pnl;
   total_pos      = m_state.total_positive_pnl;
   positive_days  = m_state.positive_days;
   
   double today_pnl = m_state.daily_pnl;
   if(today_pnl > 0)
   {
      total_pos += today_pnl;
      if(today_pnl > best_day) best_day = today_pnl;
      positive_days = (m_state.daily_pnl > 0) ? positive_days + 1 : positive_days; // simplistic approximation for current day
   }
}

void CRiskManager::Update()
{
   if(!m_params.enabled) return;

   datetime server_time = GetServerTime();
   MqlDateTime dt;
   TimeToStruct(server_time, dt);

   //--- Rollover diário
   if(dt.day_of_year != m_state.day_of_year)
   {
      double balance_now = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity_now = AccountInfoDouble(ACCOUNT_EQUITY);
      
      // Consistency save before reset
      if(m_state.daily_pnl > 0) {
         m_state.total_positive_pnl += m_state.daily_pnl;
         if(m_state.daily_pnl > m_state.best_day_pnl) m_state.best_day_pnl = m_state.daily_pnl;
         m_state.positive_days++;
      }
      
      m_state.max_eod_balance = MathMax(m_state.max_eod_balance, balance_now);
      m_state.day_start_equity = equity_now;
      m_state.daily_trades     = 0;
      m_state.daily_profit_trades = 0;
      m_state.daily_loss_trades   = 0;
      m_state.day_of_year      = dt.day_of_year;

      if(m_state.peak_balance < equity_now) m_state.peak_balance = equity_now;

      if(m_state.blocked && IsDailyReason()) Unblock();

      PersistState();
      m_state.last_scan = 0;
      Print("[RISK v4] Daily reset | Start Equity: ", DoubleToString(m_state.day_start_equity, 2));
   }

   //--- Rollover semanal
   int wk = WeeklyKey(server_time);
   if(wk != m_state.week_key)
   {
      m_state.week_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      m_state.week_key = wk;

      if(m_state.blocked && IsWeeklyReason()) Unblock();

      PersistState();
      m_state.last_scan = 0;
      Print("[RISK v4] Weekly reset | Start Equity: ", DoubleToString(m_state.week_start_equity, 2));
   }

   //--- Rollover mensal
   if(dt.mon != m_state.month)
   {
      double balance_now = AccountInfoDouble(ACCOUNT_BALANCE);
      m_state.month_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      m_state.monthly_ref_balance = balance_now;
      m_state.max_eod_balance = balance_now;
      m_state.peak_balance = AccountInfoDouble(ACCOUNT_EQUITY);
      m_state.month = dt.mon;

      if(m_state.blocked)
      {
         bool unblock_profit = IsProfitTargetReason();
         bool unblock_dd     = IsMaxDrawdownReason() && (m_params.dd_mode != RM_DD_STATIC);
         bool unblock_mloss  = IsMonthlyLossReason();
         if(unblock_profit || unblock_dd || unblock_mloss) Unblock();
      }

      PersistState();
      m_state.last_scan = 0;
      Print("[RISK v4] Monthly reset | Start Equity: ", DoubleToString(m_state.month_start_equity, 2));
   }

   if(TimeCurrent() - m_state.last_scan >= 30 || m_state.last_scan == 0)
   {
      RefreshPnL();
      m_state.last_scan = TimeCurrent();
   }

   if(TimeCurrent() - m_state.last_persist >= 60 || m_state.last_persist == 0)
   {
      PersistState();
      m_state.last_persist = TimeCurrent();
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > m_state.peak_balance) m_state.peak_balance = equity;

   CheckLimits();

   // Re-tentativa de fechamento se bloqueado e close_on_breach ativo
   if(m_state.blocked && m_params.close_on_breach)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == m_params.magic)
         {
            Print("[RISK v4] Retrying close position ", ticket);
            for(int attempt=0; attempt<3; attempt++)
            {
               if(m_trade.PositionClose(ticket)) break;
               Sleep(200);
            }
         }
      }
   }
}

void CRiskManager::OnTransaction(const MqlTradeTransaction &trans)
{
   if(!m_params.enabled) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   m_state.last_scan = 0;
}

void CRiskManager::CheckLimits()
{
   if(!m_params.enabled) return;
   if(m_state.blocked) return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   // 1. Daily loss (Equity floor)
   if(m_params.daily_loss_pct > 0)
   {
      double floor = DailyLossLimit();
      if(equity <= floor)
      {
         Block(RM_REASON_DAILY_LOSS_EQUITY, "Daily Loss Equity Floor (" + DoubleToString(equity, 2) + " <= " + DoubleToString(floor, 2) + ")");
         return;
      }
   }

   // 2. Max drawdown
   if(m_params.max_drawdown_pct > 0)
   {
      double floor = DDLimit();
      if(equity <= floor)
      {
         Block(RM_REASON_MAX_DRAWDOWN, "Max Drawdown (" + DoubleToString(equity, 2) + " <= " + DoubleToString(floor, 2) + ")");
         return;
      }
   }

   // 3. Profit target (Monthly %)
   if(m_params.profit_target_pct > 0 && m_state.monthly_pnl > 0)
   {
      double profit_pct = (m_state.initial_balance > 0) ? m_state.monthly_pnl / m_state.initial_balance * 100.0 : 0.0;
      if(profit_pct >= m_params.profit_target_pct)
      {
         Block(RM_REASON_PROFIT_TARGET, "Profit Target (" + DoubleToString(profit_pct, 1) + "% >= " + DoubleToString(m_params.profit_target_pct, 1) + "%)");
         return;
      }
   }

   // 4. Max daily trades
   if(m_params.max_daily_trades > 0 && m_state.daily_trades >= m_params.max_daily_trades)
   {
      Block(RM_REASON_MAX_DAILY_TRADES, "Max Daily Trades (" + IntegerToString(m_state.daily_trades) + "/" + IntegerToString(m_params.max_daily_trades) + ")");
      return;
   }
   if(m_params.max_daily_profit_trades > 0 && m_state.daily_profit_trades >= m_params.max_daily_profit_trades)
   {
      Block(RM_REASON_MAX_DAILY_PROFIT, "Max Daily Profit Trades (" + IntegerToString(m_state.daily_profit_trades) + "/" + IntegerToString(m_params.max_daily_profit_trades) + ")");
      return;
   }
   if(m_params.max_daily_loss_trades > 0 && m_state.daily_loss_trades >= m_params.max_daily_loss_trades)
   {
      Block(RM_REASON_MAX_DAILY_LOSS, "Max Daily Loss Trades (" + IntegerToString(m_state.daily_loss_trades) + "/" + IntegerToString(m_params.max_daily_loss_trades) + ")");
      return;
   }

   // 5. Window Limits (PnL) com proteção anti-inversão de buffer
   double buf = GetBufferAmount(AccountInfoDouble(ACCOUNT_BALANCE));
   
   // Calcula limites em valor financeiro
   double daily_prof_lim = LimitAmount(m_params.daily_profit_limit, m_state.day_start_equity);
   double daily_loss_lim = LimitAmount(m_params.daily_loss_limit, m_state.day_start_equity);
   double week_prof_lim  = LimitAmount(m_params.weekly_profit_limit, m_state.week_start_equity);
   double week_loss_lim  = LimitAmount(m_params.weekly_loss_limit, m_state.week_start_equity);
   double month_prof_lim = LimitAmount(m_params.monthly_profit_limit, m_state.month_start_equity);
   double month_loss_lim = LimitAmount(m_params.monthly_loss_limit, m_state.month_start_equity);

   // Aplica buffer limitado a 50% do tamanho do limite (evita bug matemático no ALXQuant)
   if(m_params.daily_profit_limit > 0 && m_state.daily_pnl >= daily_prof_lim - MathMin(buf, daily_prof_lim * 0.5))
   { Block(RM_REASON_DAILY_PROFIT, "Daily Profit Limit"); return; }
   
   if(m_params.daily_loss_limit > 0 && m_state.daily_pnl <= -daily_loss_lim + MathMin(buf, daily_loss_lim * 0.5))
   { Block(RM_REASON_DAILY_LOSS_PNL, "Daily Loss Limit"); return; }

   if(m_params.weekly_profit_limit > 0 && m_state.weekly_pnl >= week_prof_lim - MathMin(buf, week_prof_lim * 0.5))
   { Block(RM_REASON_WEEKLY_PROFIT, "Weekly Profit Limit"); return; }

   if(m_params.weekly_loss_limit > 0 && m_state.weekly_pnl <= -week_loss_lim + MathMin(buf, week_loss_lim * 0.5))
   { Block(RM_REASON_WEEKLY_LOSS, "Weekly Loss Limit"); return; }

   if(m_params.monthly_profit_limit > 0 && m_state.monthly_pnl >= month_prof_lim - MathMin(buf, month_prof_lim * 0.5))
   { Block(RM_REASON_PROFIT_TARGET, "Monthly Profit Limit"); return; }

   if(m_params.monthly_loss_limit > 0 && m_state.monthly_pnl <= -month_loss_lim + MathMin(buf, month_loss_lim * 0.5))
   { Block(RM_REASON_MONTHLY_LOSS, "Monthly Loss Limit"); return; }
}

bool CRiskManager::CanOpenNewOrder()
{
   if(!m_params.enabled) return true;
   if(m_state.blocked) return false;

   if(m_params.consistency_pct > 0)
   {
      double best_day, total_pos;
      int positive_days;
      ConsistencyStats(best_day, total_pos, positive_days);

      if(positive_days >= 2 && total_pos > 0)
      {
         double ratio = best_day / total_pos * 100.0;
         if(ratio > m_params.consistency_pct) return false;
      }
   }
   return true;
}

void CRiskManager::ManagePositions() { /* Implementação de fechamento preventivo pode ser adicionada aqui se necessário */ }

void CRiskManager::Block(ENUM_RM_BLOCK_REASON reason, string text)
{
   m_state.blocked            = true;
   m_state.block_reason       = text;
   m_state.block_reason_enum  = reason;
   Print("[RISK v4] BLOCKED: ", text);
   PersistState();

   DeletePendingOrders(); // Sempre remove pendentes

   if(!m_params.close_on_breach) return;

   // Fechamento robusto com retry
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == m_params.magic)
      {
         for(int attempt=0; attempt<3; attempt++)
         {
            if(m_trade.PositionClose(ticket)) break;
            Print("[RISK v4] Close attempt ", attempt+1, " failed for ", ticket, " retcode=", m_trade.ResultRetcode());
            Sleep(200);
         }
      }
   }
}

void CRiskManager::DeletePendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != m_params.magic) continue;

      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action = TRADE_ACTION_REMOVE;
      req.order  = ticket;
      OrderSend(req, res);
   }
}

void CRiskManager::Unblock()
{
   m_state.blocked           = false;
   m_state.block_reason      = "";
   m_state.block_reason_enum = RM_REASON_NONE;
   Print("[RISK v4] UNBLOCKED");
   PersistState();
}

bool CRiskManager::IsMaxDrawdownReason() const { return (m_state.block_reason_enum == RM_REASON_MAX_DRAWDOWN); }
bool CRiskManager::IsProfitTargetReason() const { return (m_state.block_reason_enum == RM_REASON_PROFIT_TARGET); }
bool CRiskManager::IsMonthlyLossReason() const { return (m_state.block_reason_enum == RM_REASON_MONTHLY_LOSS); }

bool CRiskManager::IsDailyReason() const
{
   switch(m_state.block_reason_enum)
   {
      case RM_REASON_DAILY_LOSS_EQUITY:
      case RM_REASON_DAILY_LOSS_PNL:
      case RM_REASON_MAX_DAILY_TRADES:
      case RM_REASON_MAX_DAILY_PROFIT:
      case RM_REASON_MAX_DAILY_LOSS:
      case RM_REASON_DAILY_PROFIT: return true;
      default: return false;
   }
}

bool CRiskManager::IsWeeklyReason() const
{
   switch(m_state.block_reason_enum)
   {
      case RM_REASON_WEEKLY_PROFIT:
      case RM_REASON_WEEKLY_LOSS: return true;
      default: return false;
   }
}

int CRiskManager::WeeklyKey(datetime t) const
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int back = (dt.day_of_week + 6) % 7;
   datetime mon = t - back * 86400;
   TimeToStruct(mon, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

double CRiskManager::LimitAmount(double limit_value, double base) const
{
   if(m_params.limit_mode == RM_LIMIT_PCT) return base * limit_value / 100.0;
   return limit_value;
}

string CRiskManager::GV_Prefix() const
{
   return "ALX_RISK_" + IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString((int)m_params.magic) + "_";
}

void CRiskManager::PersistState()
{
   string p = GV_Prefix();
   GlobalVariableSet(p + "DOW",   m_state.day_of_year);
   GlobalVariableSet(p + "MONTH", m_state.month);
   GlobalVariableSet(p + "INITIAL",   m_state.initial_balance);
   GlobalVariableSet(p + "MONTHLY_REF", m_state.monthly_ref_balance);
   GlobalVariableSet(p + "PEAK",      m_state.peak_balance);
   GlobalVariableSet(p + "MAXEOD",    m_state.max_eod_balance);
   GlobalVariableSet(p + "DAYEQ",     m_state.day_start_equity);
   GlobalVariableSet(p + "WEEKEQ",    m_state.week_start_equity);
   GlobalVariableSet(p + "MONEQ",     m_state.month_start_equity);
   GlobalVariableSet(p + "WEEK",      m_state.week_key);
   GlobalVariableSet(p + "BLOCKED",   m_state.blocked ? 1.0 : 0.0);
   GlobalVariableSet(p + "REASON",    (double)m_state.block_reason_enum);
   GlobalVariableSet(p + "BESTDAY",   m_state.best_day_pnl);
   GlobalVariableSet(p + "TOTPOS",    m_state.total_positive_pnl);
   GlobalVariableSet(p + "PDAYS",     m_state.positive_days);
}

void CRiskManager::RestoreState()
{
   string p = GV_Prefix();
   double v;

   if(!GlobalVariableCheck(p + "DOW")) return;

   v = GlobalVariableGet(p + "DOW");     m_state.day_of_year       = (int)v;
   v = GlobalVariableGet(p + "MONTH");   m_state.month             = (int)v;
   v = GlobalVariableGet(p + "INITIAL"); if(v > 0) m_state.initial_balance     = v;
   v = GlobalVariableGet(p + "MONTHLY_REF"); if(v > 0) m_state.monthly_ref_balance = v;
   v = GlobalVariableGet(p + "PEAK");    if(v > 0) m_state.peak_balance        = v;
   v = GlobalVariableGet(p + "MAXEOD");  if(v > 0) m_state.max_eod_balance     = v;
   v = GlobalVariableGet(p + "DAYEQ");   if(v > 0) m_state.day_start_equity    = v;
   v = GlobalVariableGet(p + "WEEKEQ");  if(v > 0) m_state.week_start_equity   = v;
   v = GlobalVariableGet(p + "MONEQ");   if(v > 0) m_state.month_start_equity  = v;
   v = GlobalVariableGet(p + "WEEK");    m_state.week_key = (int)v;
   v = GlobalVariableGet(p + "BLOCKED"); m_state.blocked = (v > 0);
   v = GlobalVariableGet(p + "REASON");  m_state.block_reason_enum = (ENUM_RM_BLOCK_REASON)(int)v;
   v = GlobalVariableGet(p + "BESTDAY"); m_state.best_day_pnl = v;
   v = GlobalVariableGet(p + "TOTPOS");  m_state.total_positive_pnl = v;
   v = GlobalVariableGet(p + "PDAYS");   m_state.positive_days = (int)v;

   if(m_state.blocked) m_state.block_reason = "Restored: " + ReasonText(m_state.block_reason_enum);
}

string CRiskManager::ReasonText(ENUM_RM_BLOCK_REASON reason) const
{
   switch(reason)
   {
      case RM_REASON_DAILY_LOSS_EQUITY: return "Daily Loss (Equity)";
      case RM_REASON_DAILY_LOSS_PNL:    return "Daily Loss (PnL Limit)";
      case RM_REASON_MAX_DRAWDOWN:      return "Max Drawdown";
      case RM_REASON_PROFIT_TARGET:     return "Profit Target";
      case RM_REASON_MAX_DAILY_TRADES:  return "Max Daily Trades";
      case RM_REASON_MAX_DAILY_PROFIT:  return "Max Daily Profit Trades";
      case RM_REASON_MAX_DAILY_LOSS:    return "Max Daily Loss Trades";
      case RM_REASON_DAILY_PROFIT:      return "Daily Profit Limit";
      case RM_REASON_WEEKLY_PROFIT:     return "Weekly Profit Limit";
      case RM_REASON_WEEKLY_LOSS:       return "Weekly Loss Limit";
      case RM_REASON_MONTHLY_LOSS:      return "Monthly Loss Limit";
   }
   return "";
}

double CRiskManager::GetDrawdownPct() const
{
   double base = (m_params.dd_mode == RM_DD_STATIC) ? m_state.initial_balance : m_state.monthly_ref_balance;
   if(m_params.dd_mode == RM_DD_TRAILING_EOD) base = MathMax(base, m_state.max_eod_balance);
   if(m_params.dd_mode == RM_DD_TRAILING_INTRADAY) base = MathMax(base, m_state.peak_balance);
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return (base > 0) ? MathMax(0.0, (base - equity) / base * 100.0) : 0.0;
}

double CRiskManager::GetDailyPct() const
{
   double ref = m_state.day_start_equity;
   return (ref > 0) ? MathMax(0.0, (ref - AccountInfoDouble(ACCOUNT_EQUITY)) / ref * 100.0) : 0.0;
}

double CRiskManager::GetProfitPct() const
{
   return (m_state.initial_balance > 0) ? m_state.monthly_pnl / m_state.initial_balance * 100.0 : 0.0;
}

void CRiskManager::SetRiskPerTradePct(double pct) { /* Mantido para compatibilidade */ }