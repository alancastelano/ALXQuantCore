//+------------------------------------------------------------------+
//|                                       AccountProtector.mqh       |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//|                       Institutional Account Protection Engine    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      ""
#property version   "12.0"
#property strict
/*
    v.12.0 - 2026-09-07 - Audit fixes (P0-P3):
                           [P0] Close_All_Positions now actually collects and
                                closes real open positions (array was never
                                populated in v11 -> protector triggered but
                                never flattened the account).
                           [P0] Magic-number filter unified across ALL deal
                                history loops (P&L, trade counting,
                                consistency rule) - was silently zeroing
                                results whenever m_magic == 0.
                           [P1] Buffer % applied in exactly one place
                                (CheckAllConditions), removed duplicated
                                buffer baked into FTMO presets.
                           [P1] Profit-target buffer direction fixed: now
                                closes slightly BEFORE the raw target
                                (consistent "safety margin" semantics for
                                both loss and profit sides).
                           [P1] Weekly P&L history window now covers weeks
                                that cross a month boundary.
                           [P1] Daily reset time normalized to midnight on
                                Init() (fixes false reset on first tick).
                           [P1] DEAL_ENTRY_OUT_BY now counted consistently
                                in trade counting and consistency rule.
                           [P1] Proper ISO-8601 week number (Thursday rule),
                                no more manual 52/53 clamp edge case.
                           [P1] DisableAuto no longer calls ExpertRemove()
                                immediately - waits until all forced closes
                                and pending-order deletions are confirmed,
                                so retries are never orphaned.
                           [P2] Consistency rule and realized P&L are now
                                cached and only recomputed when new deals
                                appear (or the day rolls over), instead of
                                rescanning full account history every tick.
                           [P2] Log file handle kept open as a class member
                                instead of reopening/closing every message.
                           [P3] GlobalVariable state now namespaced per
                                magic number (multi-instance safe) and
                                explicitly flushed to disk on every
                                critical write.
                           [P3] Equity/Balance snapshot captured at the
                                exact moment of trigger for audit purposes.
                           [P3] Consecutive close/delete failures raise an
                                Alert() after a threshold, and forced
                                closes use progressively wider slippage on
                                retry instead of a single fixed value.
*/

//+------------------------------------------------------------------+
//| Enums                                                              |
//+------------------------------------------------------------------+
enum ENUM_AP_MODE
{
   AP_MODE_POINTS    = 0,   // Points
   AP_MODE_FINANCIAL = 1,   // Financial ($)
   AP_MODE_PERCENT   = 2    // Percent (%)
};

enum ENUM_AP_PRESET
{
   AP_PRESET_MANUAL          = 0,   // Manual
   AP_PRESET_FTPMO_PHASE1    = 1,   // FTMO Phase 1
   AP_PRESET_FTPMO_PHASE2    = 2,   // FTMO Phase 2
   AP_PRESET_REAL            = 3,   // Real Account
   AP_PRESET_ALXQUANT        = 4,   // ALXQuant
   AP_PRESET_GFT_HERO        = 5,   // GFT Instant HERO
   AP_PRESET_MONETA_INSTANT  = 6    // Moneta Instant Funding
};

enum ENUM_AP_DD_MODEL
{
   AP_DD_STATIC           = 0,   // Static (balance at day start)
   AP_DD_TRAILING_EOD     = 1,   // Trailing End-of-Day
   AP_DD_TRAILING_INTRA   = 2,   // Trailing Intraday
   AP_DD_STATIC_MONTHLY   = 3,   // Static Monthly
   AP_DD_LIFETIME         = 4    // Lifetime Trailing (Moneta)
};

enum ENUM_AP_CLOSE_MODE
{
   AP_CLOSE_DEFAULT       = 0,   // Default (ticket order)
   AP_CLOSE_MOST_DISTANT  = 1,   // Most Distant First (by points from open)
   AP_CLOSE_NEAREST       = 2,   // Nearest First (by points from open)
   AP_CLOSE_MOST_PROF     = 3,   // Most Profitable First
   AP_CLOSE_MOST_LOSING   = 4,   // Most Losing First
   AP_CLOSE_FIFO          = 5,   // FIFO (oldest first)
   AP_CLOSE_LIFO          = 6    // LIFO (newest first)
};

enum ENUM_AP_SCOPE
{
   AP_SCOPE_NONE      = 0,
   AP_SCOPE_DAILY     = 1,
   AP_SCOPE_WEEKLY    = 2,
   AP_SCOPE_MONTHLY   = 3,
   AP_SCOPE_FLOATING  = 4,
   AP_SCOPE_CONSIST   = 5,
   AP_SCOPE_LIFETIME  = 6
};

//+------------------------------------------------------------------+
//| Inputs — Account Protector                                        |
//+------------------------------------------------------------------+
input group                "▸ Account Protector"
input bool                 InpAP_Enabled            = true;           // Protector On/Off
input ENUM_AP_PRESET       InpAP_Preset             = AP_PRESET_ALXQUANT; // Risk Preset
input ENUM_AP_MODE         InpAP_Mode               = AP_MODE_PERCENT; // Calculation Mode
input double               InpAP_BufferPct          = 0.2;            // Safety Buffer % (applied to all limits)
//---
input group                "▸ Daily Limits"
input double               InpAP_DailyLoss          = 1.5;            // Daily Max Loss % (0=off)
input double               InpAP_DailyProfit        = 2.0;            // Daily Profit Target % (0=off)
input int                  InpAP_MaxDailyTrades     = 0;              // Max Daily Trades (0=off)
input int                  InpAP_MaxDailyProfitTr   = 0;              // Max Daily Profit Trades (0=off)
input int                  InpAP_MaxDailyLossTr     = 0;              // Max Daily Loss Trades (0=off)
//---
input group                "▸ Weekly/Monthly Limits"
input double               InpAP_WeeklyLoss         = 3.0;            // Weekly Max Loss % (0=off)
input double               InpAP_WeeklyProfit       = 4.0;            // Weekly Profit Target % (0=off)
input double               InpAP_MonthlyLoss        = 6.0;            // Monthly Max Loss % (0=off)
input double               InpAP_MonthlyProfit      = 8.0;            // Monthly Profit Target % (0=off)
//---
input group                "▸ Floating & Lifetime"
input double               InpAP_FloatLoss          = 0;              // Floating Max Loss % (0=off)
input double               InpAP_FloatProfit        = 0;              // Floating Profit Target % (0=off)
input ENUM_AP_DD_MODEL     InpAP_DDModel            = AP_DD_STATIC;   // Drawdown Model
input double               InpAP_TrailingDDPct      = 5.0;            // Trailing/Lifetime DD % (0=off)
//---
input group                "▸ Consistency"
input double               InpAP_ConsistencyPct     = 15.0;           // Max % Best Day vs Total (0=off)
//---
input group                "▸ Actions on Breach"
input bool                 InpAP_ClosePos           = true;           // Close All Positions
input double               InpAP_ClosePercentage    = 100;            // % Volume to Close
input bool                 InpAP_DeletePend         = true;           // Delete All Pending Orders
input bool                 InpAP_DisableAuto        = false;          // Remove EA after breach is fully handled
input int                  InpAP_Slippage           = 2;              // Max Slippage (points, base value)
input bool                 InpAP_AsyncMode          = false;          // Async Order Send
input ENUM_AP_CLOSE_MODE   InpAP_CloseFirst         = AP_CLOSE_DEFAULT; // Close Order Priority
//---
input group                "▸ Resilience"
input int                  InpAP_FailAlertThreshold = 5;              // Consecutive Failures Before Alert
input int                  InpAP_MaxSlippageCap     = 50;             // Max Slippage Cap on Retries (points)
//---
input group                "▸ Logging"
input bool                 InpAP_Silent             = false;          // Silent Mode (no Print)
input string               InpAP_LogFile            = "ap_log.csv";   // Log File (empty=off)


//+------------------------------------------------------------------+
//| Struct — snapshot of one open position for close-ordering         |
//+------------------------------------------------------------------+
struct SPositionInfo
{
   ulong    ticket;
   double   profit;        // profit + swap
   datetime open_time;
   double   distance_pts;  // |current price - open price| / point
};

//+------------------------------------------------------------------+
//| Class CAccountProtector                                           |
//+------------------------------------------------------------------+
class CAccountProtector
{
private:
   //--- Settings (single source of truth)
   struct Settings
   {
      bool             OnOff;
      ENUM_AP_MODE     mode;
      ENUM_AP_DD_MODEL dd_model;
      double           buffer_pct;
      //--- Limits
      double           daily_loss, daily_profit;
      double           weekly_loss, weekly_profit;
      double           monthly_loss, monthly_profit;
      double           float_loss, float_profit;
      double           consistency_pct;
      double           trailing_dd_pct;
      int              max_daily_trades, max_daily_profit_trades, max_daily_loss_trades;
      //--- Actions
      bool             ClosePos, DeletePend, DisableAuto;
      double           close_percentage;
      int              slippage;
      bool             async_mode;
      ENUM_AP_CLOSE_MODE close_first;
      //--- State
      bool             Triggered;
      ENUM_AP_SCOPE    trigger_scope;
      string           TriggeredTime;
      double           trigger_equity;     // [P3] audit snapshot
      double           trigger_balance;    // [P3] audit snapshot
      bool             pending_remove;     // [P1] deferred ExpertRemove
      //--- Daily state
      double           daily_start_balance;
      double           daily_start_equity;
      datetime         daily_reset_time;
      int              daily_trade_count;
      //--- Weekly state
      double           weekly_start_balance;
      double           weekly_start_equity;
      int              weekly_reset_week;
      //--- Monthly state
      double           monthly_start_balance;
      double           monthly_start_equity;
      int              monthly_reset_month;
      //--- Peak tracking
      double           peak_equity;
      double           peak_balance;
      //--- Lifetime trailing (Moneta)
      double           trailing_initial_balance;
      double           trailing_peak_balance;
   } sets;

   //--- Trade counting
   ulong    m_magic;
   int      daily_trades, daily_profit_trades, daily_loss_trades;

   //--- P&L calculated
   double   daily_pl, weekly_pl, monthly_pl, floating_pl;

   //--- [P2] Realized P&L cache (recomputed only when history changes)
   int      m_pl_cache_deals_total;
   datetime m_pl_cache_day;
   double   m_pl_cache_daily_real, m_pl_cache_weekly_real, m_pl_cache_monthly_real;

   //--- [P2] Consistency rule cache
   int      m_consist_cache_deals_total;
   datetime m_consist_cache_day;
   double   m_consist_cache_total_realized;
   double   m_consist_cache_best_day_profit;
   double   m_consist_cache_today_realized;

   //--- [P0] Position snapshot for ordered closing
   SPositionInfo m_positions[];
   int      QuantityClosedPositions, QuantityDeletedPendingOrders;
   bool     IsANeedToContinueClosingPositions, IsANeedToContinueDeletingPendingOrders;

   //--- [P3] Resilience counters
   int      m_close_fail_streak;
   int      m_delete_fail_streak;

   //--- [P2] Persistent log file handle
   int      m_log_handle;

   //--- Helpers
   void     CollectPositions();
   void     SortPositionsForClosing();
   bool     ShouldSwap(const SPositionInfo &a, const SPositionInfo &b);
   void     Delete_All_Pending_Orders();
   int      Delete_Current_Pending_Order(ulong ticket);
   void     Close_All_Positions();
   int      Close_Current_Position(ulong ticket, int deviation);
   void     Trigger_Actions(const string title, ENUM_AP_SCOPE scope);
   void     CalculateProfitLoss();
   void     CalculateDailyTrades();
   void     CheckRolloverReset();
   bool     No_Condition();
   bool     No_Action();
   void     CheckConsistencyRule();
   void     CheckTrailingDD();
   void     CheckAllConditions();
   double   CalculateOrderLots(double lots, const string symbol);
   void     LoadPreset();
   void     LoadState();
   void     SaveState();
   void     Logging(const string message);
   int      GetISOWeek(datetime dt);
   string   StatePrefix();

public:
                     CAccountProtector();
                    ~CAccountProtector();

   void              Init();
   void              Update();
   void              SetMagic(ulong magic) { m_magic = magic; }
   bool              IsTriggered() { return sets.Triggered; }
   ENUM_AP_SCOPE     GetTriggerScope() { return sets.trigger_scope; }
   string            GetTriggerTime() { return sets.TriggeredTime; }
   string            GetStatus();
   double            GetDailyDDPercent();
   double            GetMaxDDPercent();
   double            GetDailyDollar();
   double            GetMaxDollar();
   bool              CanOpenTrade();
};

//+------------------------------------------------------------------+
//| Constructor                                                        |
//+------------------------------------------------------------------+
CAccountProtector::CAccountProtector()
{
   m_magic = 0;
   daily_trades = 0;
   daily_profit_trades = 0;
   daily_loss_trades = 0;
   daily_pl = 0; weekly_pl = 0; monthly_pl = 0; floating_pl = 0;

   m_pl_cache_deals_total  = -1;
   m_pl_cache_day          = 0;
   m_pl_cache_daily_real   = 0;
   m_pl_cache_weekly_real  = 0;
   m_pl_cache_monthly_real = 0;

   m_consist_cache_deals_total    = -1;
   m_consist_cache_day            = 0;
   m_consist_cache_total_realized = 0;
   m_consist_cache_best_day_profit= 0;
   m_consist_cache_today_realized = 0;

   QuantityClosedPositions = 0; QuantityDeletedPendingOrders = 0;
   IsANeedToContinueClosingPositions = false;
   IsANeedToContinueDeletingPendingOrders = false;

   m_close_fail_streak  = 0;
   m_delete_fail_streak = 0;
   m_log_handle         = INVALID_HANDLE;

   ZeroMemory(sets);
}

//+------------------------------------------------------------------+
//| Destructor — [P2] close persistent log handle                     |
//+------------------------------------------------------------------+
CAccountProtector::~CAccountProtector()
{
   if(m_log_handle != INVALID_HANDLE)
   {
      FileClose(m_log_handle);
      m_log_handle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| LoadPreset — applies prop-firm preset                             |
//| [P1] Presets now store RAW limit values only. The safety buffer   |
//|      is applied exactly once, later, inside CheckAllConditions.   |
//+------------------------------------------------------------------+
void CAccountProtector::LoadPreset()
{
   ENUM_AP_PRESET preset = InpAP_Preset;

   if(preset == AP_PRESET_MANUAL)
   {
      sets.mode           = InpAP_Mode;
      sets.buffer_pct     = InpAP_BufferPct;
      sets.daily_loss     = InpAP_DailyLoss;
      sets.daily_profit   = InpAP_DailyProfit;
      sets.weekly_loss    = InpAP_WeeklyLoss;
      sets.weekly_profit  = InpAP_WeeklyProfit;
      sets.monthly_loss   = InpAP_MonthlyLoss;
      sets.monthly_profit = InpAP_MonthlyProfit;
      sets.float_loss     = InpAP_FloatLoss;
      sets.float_profit   = InpAP_FloatProfit;
      sets.consistency_pct = InpAP_ConsistencyPct;
      sets.trailing_dd_pct = InpAP_TrailingDDPct;
      sets.dd_model       = InpAP_DDModel;
      sets.max_daily_trades      = InpAP_MaxDailyTrades;
      sets.max_daily_profit_trades = InpAP_MaxDailyProfitTr;
      sets.max_daily_loss_trades   = InpAP_MaxDailyLossTr;
   }
   else if(preset == AP_PRESET_FTPMO_PHASE1)
   {
      sets.mode           = AP_MODE_PERCENT;
      sets.buffer_pct     = InpAP_BufferPct;
      sets.daily_loss     = 5.0;    // [P1] raw value, buffer applied later
      sets.daily_profit   = 0;
      sets.weekly_loss    = 0;
      sets.weekly_profit  = 10.0;
      sets.monthly_loss   = 10.0;
      sets.monthly_profit = 10.0;
      sets.float_loss     = 0;
      sets.float_profit   = 0;
      sets.consistency_pct = 40.0;
      sets.trailing_dd_pct = 0;
      sets.dd_model       = AP_DD_STATIC;
      sets.max_daily_trades      = 0;
      sets.max_daily_profit_trades = 0;
      sets.max_daily_loss_trades   = 0;
   }
   else if(preset == AP_PRESET_FTPMO_PHASE2)
   {
      sets.mode           = AP_MODE_PERCENT;
      sets.buffer_pct     = InpAP_BufferPct;
      sets.daily_loss     = 5.0;
      sets.daily_profit   = 0;
      sets.weekly_loss    = 0;
      sets.weekly_profit  = 5.0;
      sets.monthly_loss   = 10.0;
      sets.monthly_profit = 10.0;
      sets.float_loss     = 0;
      sets.float_profit   = 0;
      sets.consistency_pct = 0;
      sets.trailing_dd_pct = 0;
      sets.dd_model       = AP_DD_STATIC;
      sets.max_daily_trades      = 0;
      sets.max_daily_profit_trades = 0;
      sets.max_daily_loss_trades   = 0;
   }
   else if(preset == AP_PRESET_REAL)
   {
      sets.mode           = AP_MODE_PERCENT;
      sets.buffer_pct     = InpAP_BufferPct;
      sets.daily_loss     = 1.0;
      sets.daily_profit   = 1.0;
      sets.weekly_loss    = 2.0;
      sets.weekly_profit  = 2.0;
      sets.monthly_loss   = 4.0;
      sets.monthly_profit = 0;
      sets.float_loss     = 0;
      sets.float_profit   = 0;
      sets.consistency_pct = 0;
      sets.trailing_dd_pct = 0;
      sets.dd_model       = AP_DD_STATIC;
      sets.max_daily_trades      = 0;
      sets.max_daily_profit_trades = 0;
      sets.max_daily_loss_trades   = 0;
   }
   else if(preset == AP_PRESET_ALXQUANT)
   {
      sets.mode                     = AP_MODE_PERCENT;
      sets.buffer_pct               = InpAP_BufferPct;
      sets.daily_loss               = 0.17;
      sets.daily_profit             = 0.20;
      sets.weekly_loss              = 0.83;
      sets.weekly_profit            = 1.0;
      sets.monthly_loss             = 3.33;
      sets.monthly_profit           = 4.0;
      sets.float_loss               = 0.06;
      sets.float_profit             = 0.07;
      sets.consistency_pct          = InpAP_ConsistencyPct;
      sets.trailing_dd_pct          = 0;
      sets.dd_model                 = AP_DD_STATIC;
      sets.max_daily_trades         = 4;
      sets.max_daily_profit_trades  = 3;
      sets.max_daily_loss_trades    = 0;
   }
   else if(preset == AP_PRESET_GFT_HERO)
   {
      sets.mode           = AP_MODE_PERCENT;
      sets.buffer_pct     = InpAP_BufferPct;
      sets.daily_loss     = 0.6;
      sets.daily_profit   = 0.5;
      sets.weekly_loss    = 0;
      sets.weekly_profit  = 0;
      sets.monthly_loss   = 2.8;
      sets.monthly_profit = 3.1;
      sets.float_loss     = 0.60;
      sets.float_profit   = 0.50;
      sets.consistency_pct = InpAP_ConsistencyPct;
      sets.trailing_dd_pct = 0;
      sets.dd_model       = AP_DD_STATIC;
      sets.max_daily_trades      = 0;
      sets.max_daily_profit_trades = 0;
      sets.max_daily_loss_trades   = 1;
   }
   else if(preset == AP_PRESET_MONETA_INSTANT)
   {
      sets.mode           = AP_MODE_PERCENT;
      sets.buffer_pct     = InpAP_BufferPct;
      sets.daily_loss     = 0.6;
      sets.daily_profit   = 0.15;
      sets.weekly_loss    = 0;
      sets.weekly_profit  = 0;
      sets.monthly_loss   = 2.2;
      sets.monthly_profit = 3.01;
      sets.float_loss     = 0.6;
      sets.float_profit   = 0.15;
      sets.consistency_pct = InpAP_ConsistencyPct;
      sets.trailing_dd_pct = InpAP_TrailingDDPct;
      sets.dd_model       = AP_DD_LIFETIME;
      sets.max_daily_trades      = 0;
      sets.max_daily_profit_trades = 0;
      sets.max_daily_loss_trades   = 0;
   }
}

//+------------------------------------------------------------------+
//| Init — initializes the protector                                  |
//+------------------------------------------------------------------+
void CAccountProtector::Init()
{
   sets.OnOff = InpAP_Enabled;

   LoadPreset();

   //--- Actions
   sets.ClosePos         = InpAP_ClosePos;
   sets.close_percentage = InpAP_ClosePercentage;
   sets.DeletePend       = InpAP_DeletePend;
   sets.DisableAuto      = InpAP_DisableAuto;
   sets.slippage         = InpAP_Slippage;
   sets.async_mode       = InpAP_AsyncMode;
   sets.close_first      = InpAP_CloseFirst;

   //--- State
   sets.Triggered       = false;
   sets.trigger_scope   = AP_SCOPE_NONE;
   sets.TriggeredTime   = "";
   sets.trigger_equity  = 0;
   sets.trigger_balance = 0;
   sets.pending_remove  = false;

   //--- Daily — [P1] normalize to midnight to avoid a spurious reset
   //--- on the very first tick after Init()
   MqlDateTime dt0;
   TimeToStruct(TimeCurrent(), dt0);
   sets.daily_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   sets.daily_start_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   sets.daily_reset_time    = StringToTime(StringFormat("%04d.%02d.%02d", dt0.year, dt0.mon, dt0.day));
   sets.daily_trade_count   = 0;

   //--- Weekly
   sets.weekly_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   sets.weekly_start_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   sets.weekly_reset_week    = GetISOWeek(TimeCurrent());

   //--- Monthly
   sets.monthly_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   sets.monthly_start_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   sets.monthly_reset_month   = dt0.mon;

   //--- Peak
   sets.peak_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   sets.peak_balance = AccountInfoDouble(ACCOUNT_BALANCE);

   //--- Lifetime trailing
   sets.trailing_initial_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   sets.trailing_peak_balance    = AccountInfoDouble(ACCOUNT_BALANCE);

   //--- [P2] Open persistent log handle once
   if(StringLen(InpAP_LogFile) > 0 && m_log_handle == INVALID_HANDLE)
   {
      m_log_handle = FileOpen(InpAP_LogFile, FILE_CSV | FILE_READ | FILE_WRITE | FILE_SHARE_READ, ',');
      if(m_log_handle != INVALID_HANDLE)
         FileSeek(m_log_handle, 0, SEEK_END);
   }

   //--- Load persisted state (per-magic namespaced, see StatePrefix())
   LoadState();

   Logging("Account Protector Initialized. Preset: " + EnumToString(InpAP_Preset) +
           " DDModel: " + EnumToString(sets.dd_model) +
           " Magic: " + IntegerToString((long)m_magic));
}

//+------------------------------------------------------------------+
//| Update — called every tick                                        |
//+------------------------------------------------------------------+
void CAccountProtector::Update()
{
   if(IsANeedToContinueClosingPositions) Close_All_Positions();
   if(IsANeedToContinueDeletingPendingOrders) Delete_All_Pending_Orders();

   //--- [P1] Deferred ExpertRemove: only pull the EA once the breach has
   //--- actually been resolved (no pending retries left).
   if(sets.pending_remove && !IsANeedToContinueClosingPositions && !IsANeedToContinueDeletingPendingOrders)
   {
      Logging("ACTION: Breach fully handled. Removing EA (DisableAuto).");
      sets.pending_remove = false;
      ExpertRemove();
      return;
   }

   CheckRolloverReset();
   CalculateProfitLoss();
   CalculateDailyTrades();

   //--- Floating trigger clear (safe zone restored)
   if(sets.Triggered && sets.trigger_scope == AP_SCOPE_FLOATING)
   {
      bool clear = false;
      if(sets.float_profit > 0 && floating_pl < sets.float_profit) clear = true;
      if(sets.float_loss > 0 && floating_pl > -sets.float_loss) clear = true;
      if(clear)
      {
         sets.Triggered    = false;
         sets.trigger_scope = AP_SCOPE_NONE;
         sets.TriggeredTime = "";
         Logging("Floating P/L safe zone restored: Trigger reset.");
         SaveState();
      }
   }

   if(!sets.OnOff) return;
   if(sets.Triggered) return;

   CheckTrailingDD();
   CheckConsistencyRule();
   CheckAllConditions();
}

//+------------------------------------------------------------------+
//| CheckRolloverReset — resets state per period                      |
//+------------------------------------------------------------------+
void CAccountProtector::CheckRolloverReset()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   int current_week = GetISOWeek(TimeCurrent());

   if(sets.Triggered && sets.trigger_scope != AP_SCOPE_FLOATING)
   {
      bool reset = false;
      if((sets.trigger_scope == AP_SCOPE_DAILY || sets.trigger_scope == AP_SCOPE_CONSIST) && today != sets.daily_reset_time)
         reset = true;
      if(sets.trigger_scope == AP_SCOPE_WEEKLY && current_week != sets.weekly_reset_week)
         reset = true;
      if(sets.trigger_scope == AP_SCOPE_MONTHLY && dt.mon != sets.monthly_reset_month)
         reset = true;

      if(reset)
      {
         sets.Triggered    = false;
         sets.trigger_scope = AP_SCOPE_NONE;
         sets.TriggeredTime = "";
         Logging("Rollover detected: Trigger state reset.");
         SaveState();
      }
   }

   //--- Daily reset
   if(today != sets.daily_reset_time)
   {
      sets.daily_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      sets.daily_start_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      sets.daily_reset_time    = today;
      sets.daily_trade_count   = 0;
      Logging("Daily reset. Balance: " + DoubleToString(sets.daily_start_balance, 2) +
              " Equity: " + DoubleToString(sets.daily_start_equity, 2));
      SaveState();
   }

   //--- Weekly reset
   if(current_week != sets.weekly_reset_week)
   {
      sets.weekly_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      sets.weekly_start_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      sets.weekly_reset_week    = current_week;
      Logging("Weekly reset. Balance: " + DoubleToString(sets.weekly_start_balance, 2));
      SaveState();
   }

   //--- Monthly reset
   if(dt.mon != sets.monthly_reset_month)
   {
      sets.monthly_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      sets.monthly_start_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      sets.monthly_reset_month   = dt.mon;
      Logging("Monthly reset. Balance: " + DoubleToString(sets.monthly_start_balance, 2));
      SaveState();
   }

   //--- Peak tracking
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(eq > sets.peak_equity)  sets.peak_equity = eq;
   if(bal > sets.peak_balance) sets.peak_balance = bal;
}

//+------------------------------------------------------------------+
//| GetISOWeek — [P1] proper ISO-8601 week number (Thursday rule)     |
//| Returns year*100+week so it is safe to compare across year edges. |
//+------------------------------------------------------------------+
int CAccountProtector::GetISOWeek(datetime dt)
{
   MqlDateTime d;
   TimeToStruct(dt, d);
   int dow = d.day_of_week;              // 0=Sunday..6=Saturday
   int isodow = (dow == 0) ? 7 : dow;    // 1=Monday..7=Sunday

   //--- The Thursday of the current ISO week always falls in the
   //--- ISO year the week belongs to.
   datetime thursday = dt - (datetime)((isodow - 4) * 86400);
   MqlDateTime dth;
   TimeToStruct(thursday, dth);

   datetime jan1 = StringToTime(StringFormat("%04d.01.01", dth.year));
   int week = (int)((thursday - jan1) / 86400) / 7 + 1;

   return dth.year * 100 + week;
}

//+------------------------------------------------------------------+
//| CalculateProfitLoss — daily/weekly/monthly/floating P&L           |
//| [P0] Magic filter unified. [P1] weekly window fixed for month     |
//| boundaries. [P2] realized part cached, recomputed only on new     |
//| deals or day rollover; floating part always fresh.                |
//+------------------------------------------------------------------+
void CAccountProtector::CalculateProfitLoss()
{
   floating_pl = 0;

   //--- 1. Floating P&L (open positions) — always recomputed, prices move every tick
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(m_magic != 0 && PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);
      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);

      if(sets.mode == AP_MODE_FINANCIAL || sets.mode == AP_MODE_PERCENT)
      {
         floating_pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
      else if(sets.mode == AP_MODE_POINTS && pt > 0)
      {
         if(type == POSITION_TYPE_BUY)
            floating_pl += (SymbolInfoDouble(sym, SYMBOL_BID) - open) / pt;
         else if(type == POSITION_TYPE_SELL)
            floating_pl += (open - SymbolInfoDouble(sym, SYMBOL_ASK)) / pt;
      }
   }

   //--- 2. Realized P&L (deals) — [P2] cached, recomputed only when the
   //---    total deal count or the current day changes.
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime start_of_today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   int dow = dt.day_of_week;
   if(dow == 0) dow = 7;
   datetime start_of_week  = start_of_today - (datetime)((dow - 1) * 86400);
   datetime start_of_month = StringToTime(StringFormat("%04d.%02d.01", dt.year, dt.mon));

   //--- [P1] Select from the EARLIEST of week/month start so a week that
   //---      crosses a month boundary isn't silently truncated.
   datetime select_from = MathMin(start_of_week, start_of_month);
   HistorySelect(select_from, TimeCurrent());
   int deals_total = HistoryDealsTotal();

   bool need_recompute = (deals_total != m_pl_cache_deals_total) || (start_of_today != m_pl_cache_day);

   if(need_recompute)
   {
      double daily_real = 0, weekly_real = 0, monthly_real = 0;

      for(int i = 0; i < deals_total; i++)
      {
         ulong deal_ticket = HistoryDealGetTicket(i);
         if(deal_ticket == 0) continue;
         if(m_magic != 0 && HistoryDealGetInteger(deal_ticket, DEAL_MAGIC) != (long)m_magic) continue;
         long deal_entry = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
         if(deal_entry != DEAL_ENTRY_OUT && deal_entry != DEAL_ENTRY_OUT_BY) continue;

         datetime d_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
         string sym = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
         double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);

         double profit = 0;
         if(sets.mode == AP_MODE_FINANCIAL || sets.mode == AP_MODE_PERCENT)
         {
            profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT) + HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
         }
         else if(sets.mode == AP_MODE_POINTS && pt > 0)
         {
            ulong pos_id = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
            if(HistorySelectByPosition(pos_id))
            {
               for(int j = 0; j < HistoryDealsTotal(); j++)
               {
                  ulong entry_ticket = HistoryDealGetTicket(j);
                  if(HistoryDealGetInteger(entry_ticket, DEAL_ENTRY) == DEAL_ENTRY_IN)
                  {
                     double entry_price = HistoryDealGetDouble(entry_ticket, DEAL_PRICE);
                     double exit_price  = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
                     long   d_type      = HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
                     if(d_type == DEAL_TYPE_BUY)
                        profit = (exit_price - entry_price) / pt;
                     else
                        profit = (entry_price - exit_price) / pt;
                     break;
                  }
               }
            }
            //--- restore the window selection for the outer loop
            HistorySelect(select_from, TimeCurrent());
         }

         if(d_time >= start_of_month) monthly_real += profit;
         if(d_time >= start_of_week)  weekly_real  += profit;
         if(d_time >= start_of_today) daily_real   += profit;
      }

      m_pl_cache_daily_real   = daily_real;
      m_pl_cache_weekly_real  = weekly_real;
      m_pl_cache_monthly_real = monthly_real;
      m_pl_cache_deals_total  = deals_total;
      m_pl_cache_day          = start_of_today;
   }

   //--- 3. Combine (realized + floating)
   daily_pl   = m_pl_cache_daily_real   + floating_pl;
   weekly_pl  = m_pl_cache_weekly_real  + floating_pl;
   monthly_pl = m_pl_cache_monthly_real + floating_pl;

   //--- 4. Convert to percent if needed (equity-based)
   if(sets.mode == AP_MODE_PERCENT)
   {
      double daily_base   = sets.daily_start_equity;
      double weekly_base  = sets.weekly_start_equity;
      double monthly_base = sets.monthly_start_equity;
      double current_eq   = AccountInfoDouble(ACCOUNT_EQUITY);

      if(daily_base > 0)   daily_pl   = (daily_pl / daily_base) * 100;
      if(weekly_base > 0)  weekly_pl  = (weekly_pl / weekly_base) * 100;
      if(monthly_base > 0) monthly_pl = (monthly_pl / monthly_base) * 100;
      if(current_eq > 0)   floating_pl = (floating_pl / current_eq) * 100;
   }
}

//+------------------------------------------------------------------+
//| CalculateDailyTrades — counts today's closed trades                |
//| [P0] Magic filter unified. [P1] DEAL_ENTRY_OUT_BY now counted too. |
//+------------------------------------------------------------------+
void CAccountProtector::CalculateDailyTrades()
{
   daily_trades = 0; daily_profit_trades = 0; daily_loss_trades = 0;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime start_of_today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));

   if(!HistorySelect(start_of_today, TimeCurrent())) return;

   ulong pos_ids[];
   ArrayResize(pos_ids, 0);
   int total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(m_magic != 0 && HistoryDealGetInteger(t, DEAL_MAGIC) != (long)m_magic) continue;
      long entry = HistoryDealGetInteger(t, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;

      ulong pos_id = HistoryDealGetInteger(t, DEAL_POSITION_ID);
      bool found = false;
      for(int p = 0; p < ArraySize(pos_ids); p++)
      {
         if(pos_ids[p] == pos_id) { found = true; break; }
      }
      if(!found)
      {
         int sz = ArraySize(pos_ids);
         ArrayResize(pos_ids, sz + 1);
         pos_ids[sz] = pos_id;
         daily_trades++;
         double prof = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP);
         if(prof >= 0) daily_profit_trades++;
         else daily_loss_trades++;
      }
   }
}

//+------------------------------------------------------------------+
//| CheckConsistencyRule — best day / total profit ratio               |
//| [P0] Magic filter unified. [P1] DEAL_ENTRY_OUT_BY counted.         |
//| [P2] Full-history scan cached, only rerun when a new deal exists   |
//|      or the calendar day rolled over.                              |
//+------------------------------------------------------------------+
void CAccountProtector::CheckConsistencyRule()
{
   if(sets.consistency_pct <= 0) return;

   MqlDateTime dt_now;
   TimeToStruct(TimeCurrent(), dt_now);
   datetime start_of_today = StringToTime(StringFormat("%04d.%02d.%02d", dt_now.year, dt_now.mon, dt_now.day));

   HistorySelect(0, TimeCurrent());
   int total_deals = HistoryDealsTotal();

   bool need_recompute = (total_deals != m_consist_cache_deals_total) || (start_of_today != m_consist_cache_day);

   if(need_recompute)
   {
      double total_realized = 0;
      double best_day_profit = 0;
      double current_day_profit = 0;
      datetime current_day = 0;

      for(int i = 0; i < total_deals; i++)
      {
         ulong t = HistoryDealGetTicket(i);
         if(t == 0) continue;
         if(m_magic != 0 && HistoryDealGetInteger(t, DEAL_MAGIC) != (long)m_magic) continue;
         long entry = HistoryDealGetInteger(t, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) continue;

         datetime d_time = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
         double p = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP);

         MqlDateTime dt1;
         TimeToStruct(d_time, dt1);
         datetime day_start = StringToTime(StringFormat("%04d.%02d.%02d", dt1.year, dt1.mon, dt1.day));

         if(day_start != current_day)
         {
            if(current_day != start_of_today && current_day != 0)
            {
               if(current_day_profit > best_day_profit)
                  best_day_profit = current_day_profit;
            }
            current_day_profit = 0;
            current_day = day_start;
         }
         current_day_profit += p;
         total_realized += p;
      }

      if(current_day != start_of_today && current_day_profit > best_day_profit)
         best_day_profit = current_day_profit;

      double today_realized = 0;
      if(current_day == start_of_today) today_realized = current_day_profit;

      m_consist_cache_total_realized  = total_realized;
      m_consist_cache_best_day_profit = best_day_profit;
      m_consist_cache_today_realized  = today_realized;
      m_consist_cache_deals_total     = total_deals;
      m_consist_cache_day             = start_of_today;
   }

   double best_day_profit_c  = m_consist_cache_best_day_profit;
   double today_realized_c   = m_consist_cache_today_realized;
   double total_realized_c   = m_consist_cache_total_realized;

   if(best_day_profit_c > 0 && today_realized_c >= best_day_profit_c && today_realized_c > 0 && total_realized_c > 0)
   {
      double ratio = (today_realized_c / total_realized_c) * 100.0;
      if(ratio >= sets.consistency_pct)
      {
         Logging("Consistency Rule: Today ratio " + DoubleToString(ratio, 1) + "% >= " + DoubleToString(sets.consistency_pct, 1) + "%");
         Trigger_Actions("Consistency Rule Limit", AP_SCOPE_CONSIST);
      }
   }
}

//+------------------------------------------------------------------+
//| CheckTrailingDD — trailing/lifetime drawdown                       |
//+------------------------------------------------------------------+
void CAccountProtector::CheckTrailingDD()
{
   if(sets.trailing_dd_pct <= 0) return;

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double current_peak = MathMax(bal, eq);

   //--- Update peak
   if(current_peak > sets.trailing_peak_balance)
   {
      sets.trailing_peak_balance = current_peak;
      SaveState();
   }

   //--- Calculate floor
   double dd_amount = (sets.trailing_dd_pct / 100.0) * sets.trailing_initial_balance;
   double floor_val = MathMin(sets.trailing_initial_balance,
                              sets.trailing_peak_balance - dd_amount);

   //--- Check breach
   if(MathMin(bal, eq) <= floor_val)
   {
      Logging("Trailing DD Limit: bal=" + DoubleToString(bal, 2) +
              " eq=" + DoubleToString(eq, 2) + " floor=" + DoubleToString(floor_val, 2));
      Trigger_Actions("Lifetime Trailing DD Limit", AP_SCOPE_LIFETIME);
   }
}

//+------------------------------------------------------------------+
//| CheckAllConditions — checks every configured limit                |
//| [P1] Buffer applied exactly once here, same direction (safety     |
//|      margin) for both loss and profit sides.                      |
//+------------------------------------------------------------------+
void CAccountProtector::CheckAllConditions()
{
   if(No_Condition() || No_Action()) return;

   double buf = sets.buffer_pct / 100.0;

   //--- Loss limits: trigger a bit BEFORE the raw loss cap (safety margin)
   double dl = sets.daily_loss   * (1.0 - buf);
   double wl = sets.weekly_loss  * (1.0 - buf);
   double ml = sets.monthly_loss * (1.0 - buf);
   double fl = sets.float_loss   * (1.0 - buf);

   //--- [P1] Profit targets: trigger a bit BEFORE the raw target too, so
   //---      execution slippage never lets the realized result overshoot
   //---      past what the plan/strategy intended.
   double dp = sets.daily_profit   * (1.0 - buf);
   double wp = sets.weekly_profit  * (1.0 - buf);
   double mp = sets.monthly_profit * (1.0 - buf);
   double fp = sets.float_profit   * (1.0 - buf);

   //--- Daily Trades Limits
   if(sets.max_daily_trades > 0 && daily_trades >= sets.max_daily_trades)
      Trigger_Actions("Max Daily Trades (" + IntegerToString(daily_trades) + "/" + IntegerToString(sets.max_daily_trades) + ")", AP_SCOPE_DAILY);
   else if(sets.max_daily_profit_trades > 0 && daily_profit_trades >= sets.max_daily_profit_trades)
      Trigger_Actions("Max Daily Profit Trades (" + IntegerToString(daily_profit_trades) + "/" + IntegerToString(sets.max_daily_profit_trades) + ")", AP_SCOPE_DAILY);
   else if(sets.max_daily_loss_trades > 0 && daily_loss_trades >= sets.max_daily_loss_trades)
      Trigger_Actions("Max Daily Loss Trades (" + IntegerToString(daily_loss_trades) + "/" + IntegerToString(sets.max_daily_loss_trades) + ")", AP_SCOPE_DAILY);

   //--- Daily P/L Limits
   else if(dl > 0 && daily_pl <= -dl)
      Trigger_Actions("Daily Loss Limit (" + DoubleToString(daily_pl, 2) + "%)", AP_SCOPE_DAILY);
   else if(dp > 0 && daily_pl >= dp)
      Trigger_Actions("Daily Profit Target (" + DoubleToString(daily_pl, 2) + "%)", AP_SCOPE_DAILY);

   //--- Weekly Limits
   else if(wl > 0 && weekly_pl <= -wl)
      Trigger_Actions("Weekly Loss Limit (" + DoubleToString(weekly_pl, 2) + "%)", AP_SCOPE_WEEKLY);
   else if(wp > 0 && weekly_pl >= wp)
      Trigger_Actions("Weekly Profit Target (" + DoubleToString(weekly_pl, 2) + "%)", AP_SCOPE_WEEKLY);

   //--- Monthly Limits
   else if(ml > 0 && monthly_pl <= -ml)
      Trigger_Actions("Monthly Loss Limit (" + DoubleToString(monthly_pl, 2) + "%)", AP_SCOPE_MONTHLY);
   else if(mp > 0 && monthly_pl >= mp)
      Trigger_Actions("Monthly Profit Target (" + DoubleToString(monthly_pl, 2) + "%)", AP_SCOPE_MONTHLY);

   //--- Floating Limits
   else if(fl > 0 && floating_pl <= -fl)
      Trigger_Actions("Floating Loss Limit (" + DoubleToString(floating_pl, 2) + "%)", AP_SCOPE_FLOATING);
   else if(fp > 0 && floating_pl >= fp)
      Trigger_Actions("Floating Profit Target (" + DoubleToString(floating_pl, 2) + "%)", AP_SCOPE_FLOATING);
}

//+------------------------------------------------------------------+
//| Trigger_Actions — executes actions when a limit is breached        |
//| [P3] Snapshots equity/balance BEFORE closing, for audit purposes.  |
//| [P1] DisableAuto is deferred until closes/deletes are confirmed.   |
//+------------------------------------------------------------------+
void CAccountProtector::Trigger_Actions(const string title, ENUM_AP_SCOPE scope)
{
   Logging("TRIGGER: " + title);

   //--- [P3] Audit snapshot at the exact moment of breach
   sets.trigger_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   sets.trigger_balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(sets.ClosePos)
   {
      Logging("ACTION: Close all positions.");
      Close_All_Positions();
   }
   if(sets.DeletePend)
   {
      Logging("ACTION: Delete all pending orders.");
      Delete_All_Pending_Orders();
   }
   if(sets.DisableAuto)
   {
      //--- [P1] Defer instead of calling ExpertRemove() immediately -
      //--- if a close/delete needs a retry next tick, the EA must
      //--- still be alive to attempt it.
      sets.pending_remove = true;
      Logging("ACTION: EA removal scheduled (pending close/delete confirmation).");
   }

   sets.Triggered    = true;
   sets.trigger_scope = scope;
   sets.TriggeredTime = TimeToString(TimeLocal(), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
   SaveState();
}

//+------------------------------------------------------------------+
//| CollectPositions — [P0] snapshot of open positions to close        |
//+------------------------------------------------------------------+
void CAccountProtector::CollectPositions()
{
   int total = PositionsTotal();
   ArrayResize(m_positions, 0);

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(m_magic != 0 && PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      long   type = PositionGetInteger(POSITION_TYPE);
      double cur_price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID)
                                                       : SymbolInfoDouble(sym, SYMBOL_ASK);

      SPositionInfo info;
      info.ticket       = ticket;
      info.profit       = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      info.open_time    = (datetime)PositionGetInteger(POSITION_TIME);
      info.distance_pts = (pt > 0) ? MathAbs(cur_price - open_price) / pt : 0.0;

      int sz = ArraySize(m_positions);
      ArrayResize(m_positions, sz + 1);
      m_positions[sz] = info;
   }
}

//+------------------------------------------------------------------+
//| ShouldSwap — comparison rule for SortPositionsForClosing           |
//+------------------------------------------------------------------+
bool CAccountProtector::ShouldSwap(const SPositionInfo &a, const SPositionInfo &b)
{
   switch(sets.close_first)
   {
      case AP_CLOSE_MOST_DISTANT: return a.distance_pts < b.distance_pts; // largest distance first
      case AP_CLOSE_NEAREST:      return a.distance_pts > b.distance_pts; // smallest distance first
      case AP_CLOSE_MOST_PROF:    return a.profit < b.profit;             // highest profit first
      case AP_CLOSE_MOST_LOSING:  return a.profit > b.profit;             // lowest (most negative) profit first
      case AP_CLOSE_FIFO:         return a.open_time > b.open_time;       // oldest first
      case AP_CLOSE_LIFO:         return a.open_time < b.open_time;       // newest first
      default:                    return false;                          // AP_CLOSE_DEFAULT: ticket order
   }
}

//+------------------------------------------------------------------+
//| SortPositionsForClosing — [P0] insertion sort (small N, N<=few100) |
//+------------------------------------------------------------------+
void CAccountProtector::SortPositionsForClosing()
{
   if(sets.close_first == AP_CLOSE_DEFAULT) return;

   int n = ArraySize(m_positions);
   for(int i = 1; i < n; i++)
   {
      SPositionInfo key = m_positions[i];
      int j = i - 1;
      while(j >= 0 && ShouldSwap(m_positions[j], key))
      {
         m_positions[j + 1] = m_positions[j];
         j--;
      }
      m_positions[j + 1] = key;
   }
}

//+------------------------------------------------------------------+
//| Close_All_Positions                                                |
//| [P0] Now actually collects real open positions before closing.    |
//| [P3] Dynamic slippage on retries + failure-streak alerting.        |
//+------------------------------------------------------------------+
void CAccountProtector::Close_All_Positions()
{
   QuantityClosedPositions = 0;
   IsANeedToContinueClosingPositions = false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return;

   CollectPositions();
   SortPositionsForClosing();

   int total = ArraySize(m_positions);
   for(int i = 0; i < total; i++)
   {
      ulong ticket = m_positions[i].ticket;
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(SymbolInfoInteger(sym, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      { IsANeedToContinueClosingPositions = true; continue; }

      //--- [P3] Widen slippage progressively on repeated failures,
      //---      capped at InpAP_MaxSlippageCap.
      int deviation = sets.slippage * (1 + m_close_fail_streak);
      if(deviation > InpAP_MaxSlippageCap) deviation = InpAP_MaxSlippageCap;

      int error = Close_Current_Position(ticket, deviation);
      if(error != 0)
      {
         m_close_fail_streak++;
         Logging("PositionClose failed. Error #" + IntegerToString(error) +
                 " (fail streak=" + IntegerToString(m_close_fail_streak) + ")");

         if(m_close_fail_streak >= InpAP_FailAlertThreshold)
         {
            string msg = "AccountProtector: " + IntegerToString(m_close_fail_streak) +
                         " consecutive failures closing position #" + IntegerToString((int)ticket) +
                         ". Manual intervention may be required.";
            Alert(msg);
            Logging("CRITICAL: " + msg);
         }
      }
      else
      {
         m_close_fail_streak = 0;
         QuantityClosedPositions++;
      }
   }
}

//+------------------------------------------------------------------+
//| Close_Current_Position                                             |
//+------------------------------------------------------------------+
int CAccountProtector::Close_Current_Position(ulong ticket, int deviation)
{
   if(!PositionSelectByTicket(ticket)) return -1;

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   string position_symbol = PositionGetString(POSITION_SYMBOL);
   double volume = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   request.action    = TRADE_ACTION_DEAL;
   request.position  = ticket;
   request.symbol     = position_symbol;
   request.volume     = CalculateOrderLots(volume, position_symbol);
   request.deviation  = deviation;
   request.magic      = PositionGetInteger(POSITION_MAGIC);

   long type_filling = SymbolInfoInteger(position_symbol, SYMBOL_FILLING_MODE);
   if(type_filling == 1) request.type_filling = ORDER_FILLING_FOK;
   else if(type_filling == 2) request.type_filling = ORDER_FILLING_IOC;

   if(type == POSITION_TYPE_BUY) { request.price = SymbolInfoDouble(position_symbol, SYMBOL_BID); request.type = ORDER_TYPE_SELL; }
   else { request.price = SymbolInfoDouble(position_symbol, SYMBOL_ASK); request.type = ORDER_TYPE_BUY; }

   if(sets.async_mode)
   {
      if(!OrderSendAsync(request, result)) { IsANeedToContinueClosingPositions = true; return GetLastError(); }
   }
   else
   {
      if(!OrderSend(request, result)) { IsANeedToContinueClosingPositions = true; return GetLastError(); }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Delete_All_Pending_Orders                                          |
//| [P3] Failure-streak alerting added.                                |
//+------------------------------------------------------------------+
void CAccountProtector::Delete_All_Pending_Orders()
{
   QuantityDeletedPendingOrders = 0;
   IsANeedToContinueDeletingPendingOrders = false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0) continue;
      if(m_magic != 0 && OrderGetInteger(ORDER_MAGIC) != (long)m_magic) continue;

      int error = Delete_Current_Pending_Order(ticket);
      if(error != 0)
      {
         m_delete_fail_streak++;
         Logging("OrderDelete failed. Error #" + IntegerToString(error) +
                 " (fail streak=" + IntegerToString(m_delete_fail_streak) + ")");

         if(m_delete_fail_streak >= InpAP_FailAlertThreshold)
         {
            string msg = "AccountProtector: " + IntegerToString(m_delete_fail_streak) +
                         " consecutive failures deleting pending order #" + IntegerToString((int)ticket) +
                         ". Manual intervention may be required.";
            Alert(msg);
            Logging("CRITICAL: " + msg);
         }
      }
      else
      {
         m_delete_fail_streak = 0;
         Logging("Pending order #" + IntegerToString((int)ticket) + " deleted.");
         QuantityDeletedPendingOrders++;
      }
   }
}

//+------------------------------------------------------------------+
//| Delete_Current_Pending_Order                                       |
//+------------------------------------------------------------------+
int CAccountProtector::Delete_Current_Pending_Order(ulong ticket)
{
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_REMOVE;
   request.order  = ticket;
   if(!OrderSend(request, result)) { IsANeedToContinueDeletingPendingOrders = true; return GetLastError(); }
   return 0;
}

//+------------------------------------------------------------------+
//| CalculateOrderLots — volume with percentage                        |
//+------------------------------------------------------------------+
double CAccountProtector::CalculateOrderLots(double lots, const string symbol)
{
   if(sets.close_percentage >= 100) return lots;
   double vol_min  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double vol_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double volume   = lots * sets.close_percentage / 100.0;
   if(volume < vol_min) return vol_min;
   if(vol_step > 0)
   {
      double steps = MathFloor(volume / vol_step);
      volume = steps * vol_step;
   }
   return volume;
}

//+------------------------------------------------------------------+
//| Logging — [P2] reuses a persistent file handle                    |
//+------------------------------------------------------------------+
void CAccountProtector::Logging(const string message)
{
   if(!InpAP_Silent) Print("[AP] ", message);

   if(m_log_handle != INVALID_HANDLE)
   {
      FileWrite(m_log_handle, TimeToString(TimeLocal(), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                message, EnumToString(sets.trigger_scope));
      FileFlush(m_log_handle);
   }
}

//+------------------------------------------------------------------+
//| No_Condition — no limit configured                                 |
//+------------------------------------------------------------------+
bool CAccountProtector::No_Condition()
{
   if(sets.daily_loss <= 0 && sets.daily_profit <= 0 &&
      sets.weekly_loss <= 0 && sets.weekly_profit <= 0 &&
      sets.monthly_loss <= 0 && sets.monthly_profit <= 0 &&
      sets.float_loss <= 0 && sets.float_profit <= 0 &&
      sets.consistency_pct <= 0 && sets.trailing_dd_pct <= 0 &&
      sets.max_daily_trades <= 0 && sets.max_daily_profit_trades <= 0 && sets.max_daily_loss_trades <= 0)
      return true;
   return false;
}

//+------------------------------------------------------------------+
//| No_Action — no action configured                                   |
//+------------------------------------------------------------------+
bool CAccountProtector::No_Action()
{
   if(!sets.ClosePos && !sets.DeletePend && !sets.DisableAuto) return true;
   return false;
}

//+------------------------------------------------------------------+
//| StatePrefix — [P3] namespaced by login AND magic number,          |
//| so two EA instances on the same account never collide.            |
//+------------------------------------------------------------------+
string CAccountProtector::StatePrefix()
{
   ulong login = AccountInfoInteger(ACCOUNT_LOGIN);
   return "AP_" + IntegerToString(login) + "_" + IntegerToString((long)m_magic) + "_";
}

//+------------------------------------------------------------------+
//| LoadState — loads state from GlobalVariables                       |
//+------------------------------------------------------------------+
void CAccountProtector::LoadState()
{
   string prefix = StatePrefix();

   if(GlobalVariableCheck(prefix + "TRIGGERED"))
      sets.Triggered = (GlobalVariableGet(prefix + "TRIGGERED") > 0.5);

   if(GlobalVariableCheck(prefix + "SCOPE"))
      sets.trigger_scope = (ENUM_AP_SCOPE)(int)GlobalVariableGet(prefix + "SCOPE");

   if(GlobalVariableCheck(prefix + "TRIG_TIME"))
      sets.TriggeredTime = TimeToString((datetime)GlobalVariableGet(prefix + "TRIG_TIME"), TIME_DATE | TIME_MINUTES | TIME_SECONDS);

   if(GlobalVariableCheck(prefix + "TRIG_EQ"))
      sets.trigger_equity = GlobalVariableGet(prefix + "TRIG_EQ");

   if(GlobalVariableCheck(prefix + "TRIG_BAL"))
      sets.trigger_balance = GlobalVariableGet(prefix + "TRIG_BAL");

   if(GlobalVariableCheck(prefix + "DAILY_BAL"))
      sets.daily_start_balance = GlobalVariableGet(prefix + "DAILY_BAL");

   if(GlobalVariableCheck(prefix + "DAILY_EQ"))
      sets.daily_start_equity = GlobalVariableGet(prefix + "DAILY_EQ");

   if(GlobalVariableCheck(prefix + "DAILY_RST"))
      sets.daily_reset_time = (datetime)GlobalVariableGet(prefix + "DAILY_RST");

   if(GlobalVariableCheck(prefix + "DAILY_CNT"))
      sets.daily_trade_count = (int)GlobalVariableGet(prefix + "DAILY_CNT");

   if(GlobalVariableCheck(prefix + "WEEK_BAL"))
      sets.weekly_start_balance = GlobalVariableGet(prefix + "WEEK_BAL");

   if(GlobalVariableCheck(prefix + "WEEK_EQ"))
      sets.weekly_start_equity = GlobalVariableGet(prefix + "WEEK_EQ");

   if(GlobalVariableCheck(prefix + "WEEK_RST"))
      sets.weekly_reset_week = (int)GlobalVariableGet(prefix + "WEEK_RST");

   if(GlobalVariableCheck(prefix + "MON_BAL"))
      sets.monthly_start_balance = GlobalVariableGet(prefix + "MON_BAL");

   if(GlobalVariableCheck(prefix + "MON_EQ"))
      sets.monthly_start_equity = GlobalVariableGet(prefix + "MON_EQ");

   if(GlobalVariableCheck(prefix + "MON_RST"))
      sets.monthly_reset_month = (int)GlobalVariableGet(prefix + "MON_RST");

   if(GlobalVariableCheck(prefix + "PEAK_EQ"))
      sets.peak_equity = GlobalVariableGet(prefix + "PEAK_EQ");

   if(GlobalVariableCheck(prefix + "PEAK_BAL"))
      sets.peak_balance = GlobalVariableGet(prefix + "PEAK_BAL");

   if(GlobalVariableCheck(prefix + "TRAIL_INIT"))
      sets.trailing_initial_balance = GlobalVariableGet(prefix + "TRAIL_INIT");

   if(GlobalVariableCheck(prefix + "TRAIL_PEAK"))
      sets.trailing_peak_balance = GlobalVariableGet(prefix + "TRAIL_PEAK");
}

//+------------------------------------------------------------------+
//| SaveState — saves state to GlobalVariables                         |
//| [P3] Explicit flush to disk after every write so state survives   |
//| a terminal crash between the write and the next auto-flush.       |
//+------------------------------------------------------------------+
void CAccountProtector::SaveState()
{
   string prefix = StatePrefix();

   GlobalVariableSet(prefix + "TRIGGERED", sets.Triggered ? 1.0 : 0.0);
   GlobalVariableSet(prefix + "SCOPE",     (double)sets.trigger_scope);
   GlobalVariableSet(prefix + "TRIG_TIME", (double)StringToTime(sets.TriggeredTime));
   GlobalVariableSet(prefix + "TRIG_EQ",   sets.trigger_equity);
   GlobalVariableSet(prefix + "TRIG_BAL",  sets.trigger_balance);
   GlobalVariableSet(prefix + "DAILY_BAL", sets.daily_start_balance);
   GlobalVariableSet(prefix + "DAILY_EQ",  sets.daily_start_equity);
   GlobalVariableSet(prefix + "DAILY_RST", (double)sets.daily_reset_time);
   GlobalVariableSet(prefix + "DAILY_CNT", (double)sets.daily_trade_count);
   GlobalVariableSet(prefix + "WEEK_BAL",  sets.weekly_start_balance);
   GlobalVariableSet(prefix + "WEEK_EQ",   sets.weekly_start_equity);
   GlobalVariableSet(prefix + "WEEK_RST",  (double)sets.weekly_reset_week);
   GlobalVariableSet(prefix + "MON_BAL",   sets.monthly_start_balance);
   GlobalVariableSet(prefix + "MON_EQ",    sets.monthly_start_equity);
   GlobalVariableSet(prefix + "MON_RST",   (double)sets.monthly_reset_month);
   GlobalVariableSet(prefix + "PEAK_EQ",   sets.peak_equity);
   GlobalVariableSet(prefix + "PEAK_BAL",  sets.peak_balance);
   GlobalVariableSet(prefix + "TRAIL_INIT", sets.trailing_initial_balance);
   GlobalVariableSet(prefix + "TRAIL_PEAK", sets.trailing_peak_balance);

   GlobalVariablesFlush(); // [P3] persist to disk immediately
}

//+------------------------------------------------------------------+
//| GetStatus — formatted status                                      |
//+------------------------------------------------------------------+
string CAccountProtector::GetStatus()
{
   string s = "";

   if(sets.Triggered)
      s += "TRIGGERED [" + EnumToString(sets.trigger_scope) + "] | ";

   if(sets.daily_loss > 0)
   {
      double dd = GetDailyDDPercent();
      s += StringFormat("Daily: %.2f%%/%.1f%% | ", dd, sets.daily_loss);
   }
   if(sets.weekly_loss > 0)
      s += StringFormat("Weekly: %.2f%%/%.1f%% | ", weekly_pl, sets.weekly_loss);
   if(sets.monthly_loss > 0)
      s += StringFormat("Monthly: %.2f%%/%.1f%% | ", monthly_pl, sets.monthly_loss);
   if(sets.trailing_dd_pct > 0)
      s += StringFormat("TrailDD: %.2f%%/%.1f%% | ", GetMaxDDPercent(), sets.trailing_dd_pct);

   s += StringFormat("Peak: $%.0f | Trades: %d", sets.peak_equity, sets.daily_trade_count);
   return s;
}

//+------------------------------------------------------------------+
//| GetDailyDDPercent — daily DD based on start equity                |
//+------------------------------------------------------------------+
double CAccountProtector::GetDailyDDPercent()
{
   if(sets.daily_start_equity <= 0) return 0.0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss = sets.daily_start_equity - eq;
   return (loss > 0) ? (loss / sets.daily_start_equity) * 100.0 : 0.0;
}

//+------------------------------------------------------------------+
//| GetMaxDDPercent — total DD based on peak equity                   |
//+------------------------------------------------------------------+
double CAccountProtector::GetMaxDDPercent()
{
   if(sets.peak_equity <= 0) return 0.0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss = sets.peak_equity - eq;
   return (loss > 0) ? (loss / sets.peak_equity) * 100.0 : 0.0;
}

//+------------------------------------------------------------------+
//| GetDailyDollar — daily DD in $                                    |
//+------------------------------------------------------------------+
double CAccountProtector::GetDailyDollar()
{
   if(sets.daily_start_equity <= 0) return 0.0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss = sets.daily_start_equity - eq;
   return (loss > 0) ? loss : 0.0;
}

//+------------------------------------------------------------------+
//| GetMaxDollar — total DD in $                                       |
//+------------------------------------------------------------------+
double CAccountProtector::GetMaxDollar()
{
   if(sets.peak_equity <= 0) return 0.0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss = sets.peak_equity - eq;
   return (loss > 0) ? loss : 0.0;
}

//+------------------------------------------------------------------+
//| CanOpenTrade — whether a new trade can be opened                  |
//+------------------------------------------------------------------+
bool CAccountProtector::CanOpenTrade()
{
   if(sets.Triggered) return false;
   if(sets.max_daily_trades <= 0) return true;
   return (sets.daily_trade_count < sets.max_daily_trades);
}
//+------------------------------------------------------------------+