//+------------------------------------------------------------------+
//|                                         RiskManager_v2.mqh       |
//|                 Prop Firm Compliance Risk Manager v2             |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

//--- Prop Firm Presets
enum ENUM_RM_PRESET
{
   RM_MANUAL       = 0,    // Configuração manual
   RM_FTMO_PHASE1  = 1,    // FTMO Challenge (10% target, 5% daily, 10% drawdown)
   RM_FTMO_PHASE2  = 2,    // FTMO Verification (5% target, 5% daily, 10% drawdown)
   RM_MFF_PHASE1   = 3,    // MFF Phase 1
   RM_MFF_PHASE2   = 4     // MFF Phase 2
};

input group "== Risk Manager v2 =="
      bool               InpRM_Enabled          = false;           // Enable Risk Manager
input ENUM_RM_PRESET     InpRM_Preset           = RM_FTMO_PHASE1; // Prop Firm Preset
input double             InpRM_DailyLossPct     = 5.0;            // [Manual] Daily Loss %
input double             InpRM_MaxDrawdownPct   = 10.0;           // [Manual] Max Total Drawdown %
input double             InpRM_ProfitTargetPct  = 10.0;           // [Manual] Profit Target %
input int                InpRM_MinTradingDays   = 10;             // [Manual] Min Trading Days
input double             InpRM_ConsistencyPct   = 30.0;           // [Manual] Consistency Rule %
input int                InpRM_MaxDailyTrades   = 0;              // [Manual] Max Daily Trades (0=off)
input int                InpRM_MaxConsecLoss    = 5;              // [Manual] Max Consecutive Losses
input bool               InpRM_CloseOnBreach    = true;           // Close positions on breach
input double             InpRM_PositionStopUSD  = 0;              // [Manual] Per-Position Stop $

class CRiskManager_v2
{
private:
   struct SRiskParams
   {
      ulong   magic;
      bool    enabled;
      double  daily_loss_pct;       // % do day_start_equity
      double  max_drawdown_pct;     // % trailing do peak_balance
      double  profit_target_pct;    // % do initial_balance
      int     min_trading_days;
      double  consistency_pct;      // max % de 1 trade no lucro total
      int     max_daily_trades;
      int     max_consec_loss;
      bool    close_on_breach;
      double  position_stop_usd;
   };
   SRiskParams m_params;

   struct SRiskState
   {
      int      day_of_year;
      int      month;
      double   initial_balance;     // Saldo no Init() — referência fixa
      double   peak_balance;        // Maior equity atingida — trailing
      double   day_start_equity;    // Equity no início do dia
      double   daily_pnl;           // Realizado + floating do dia
      double   monthly_pnl;         // Realizado + floating do mês
      int      daily_trades;
      int      trading_days;
      datetime last_trade_day;
      double   best_day_pnl;        // Maior lucro líquido de UM dia (consistency)
      double   total_positive_pnl;  // Soma do lucro de TODOS os dias positivos
      int      consec_losses;
      bool     blocked;
      string   block_reason;
   };
   SRiskState m_state;

   CTrade       m_trade;
   CPositionInfo m_position;

   void   RefreshPnL();
   void   CheckLimits();
   void   Block(string reason);
   void   Unblock();

   void   SetPresetLimits(ENUM_RM_PRESET preset);
   void   ApplyManualLimits();

public:
   CRiskManager_v2();
   ~CRiskManager_v2() {}

   void   Init(ulong magic);
   void   Update();
   bool   CanOpenNewOrder();
   void   ManagePositions();

   double GetDailyPnL()      const { return m_state.daily_pnl; }
   double GetMonthlyPnL()    const { return m_state.monthly_pnl; }
   double GetDrawdownPct()   const;
   double GetDailyPct()      const;
   double GetProfitPct()     const;
   bool   IsBlocked()        const { return m_state.blocked; }
   string GetBlockReason()   const { return m_state.block_reason; }
   int    GetTradingDays()   const { return m_state.trading_days; }
};

CRiskManager_v2::CRiskManager_v2()
{
   ZeroMemory(m_params);
   ZeroMemory(m_state);
}

void CRiskManager_v2::Init(ulong magic)
{
   m_params.magic   = magic;
   m_params.enabled = InpRM_Enabled;
   m_trade.SetExpertMagicNumber(magic);

   if(!m_params.enabled) return;

   if(InpRM_Preset == RM_MANUAL)
      ApplyManualLimits();
   else
      SetPresetLimits(InpRM_Preset);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   m_state.initial_balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   m_state.peak_balance      = equity;
   m_state.day_start_equity  = equity;
   m_state.day_of_year       = 0;
   m_state.month             = 0;
   m_state.blocked           = false;
   m_state.trading_days      = 0;
   m_state.last_trade_day    = 0;
   m_state.daily_trades      = 0;
   m_state.best_day_pnl       = 0.0;
   m_state.total_positive_pnl = 0.0;
   m_state.consec_losses     = 0;

   Print("[RISK v2] Init OK | Magic:", magic,
         " Balance:", DoubleToString(m_state.initial_balance, 2),
         " DailyLoss:", DoubleToString(m_params.daily_loss_pct, 1), "%",
         " Drawdown:", DoubleToString(m_params.max_drawdown_pct, 1), "%",
         " Target:", DoubleToString(m_params.profit_target_pct, 1), "%");
}

void CRiskManager_v2::SetPresetLimits(ENUM_RM_PRESET preset)
{
   switch(preset)
   {
      case RM_FTMO_PHASE1:
         m_params.daily_loss_pct     = 5.0;
         m_params.max_drawdown_pct   = 10.0;
         m_params.profit_target_pct  = 10.0;
         m_params.min_trading_days   = 10;
         m_params.consistency_pct    = 30.0;
         m_params.max_daily_trades   = 0;
         m_params.max_consec_loss    = 5;
         break;
      case RM_FTMO_PHASE2:
         m_params.daily_loss_pct     = 5.0;
         m_params.max_drawdown_pct   = 10.0;
         m_params.profit_target_pct  = 5.0;
         m_params.min_trading_days   = 10;
         m_params.consistency_pct    = 30.0;
         m_params.max_daily_trades   = 0;
         m_params.max_consec_loss    = 5;
         break;
      case RM_MFF_PHASE1:
         m_params.daily_loss_pct     = 5.0;
         m_params.max_drawdown_pct   = 12.0;
         m_params.profit_target_pct  = 10.0;
         m_params.min_trading_days   = 10;
         m_params.consistency_pct    = 0;
         m_params.max_daily_trades   = 0;
         m_params.max_consec_loss    = 5;
         break;
      case RM_MFF_PHASE2:
         m_params.daily_loss_pct     = 5.0;
         m_params.max_drawdown_pct   = 12.0;
         m_params.profit_target_pct  = 5.0;
         m_params.min_trading_days   = 10;
         m_params.consistency_pct    = 0;
         m_params.max_daily_trades   = 0;
         m_params.max_consec_loss    = 5;
         break;
      default:
         ApplyManualLimits();
         break;
   }
   m_params.position_stop_usd = InpRM_PositionStopUSD;
   m_params.close_on_breach   = InpRM_CloseOnBreach;
}

void CRiskManager_v2::ApplyManualLimits()
{
   m_params.daily_loss_pct     = MathMax(0.1, InpRM_DailyLossPct);
   m_params.max_drawdown_pct   = MathMax(0.1, InpRM_MaxDrawdownPct);
   m_params.profit_target_pct  = MathMax(0.0, InpRM_ProfitTargetPct);
   m_params.min_trading_days   = MathMax(0,   InpRM_MinTradingDays);
   m_params.consistency_pct    = MathMax(0.0, InpRM_ConsistencyPct);
   m_params.max_daily_trades   = MathMax(0,   InpRM_MaxDailyTrades);
   m_params.max_consec_loss    = MathMax(0,   InpRM_MaxConsecLoss);
   m_params.position_stop_usd  = MathMax(0,   InpRM_PositionStopUSD);
   m_params.close_on_breach    = InpRM_CloseOnBreach;
}

void CRiskManager_v2::RefreshPnL()
{
   m_state.daily_pnl    = 0.0;
   m_state.monthly_pnl  = 0.0;
   m_state.daily_trades = 0;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   datetime day_start   = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   datetime month_start = StringToTime(StringFormat("%04d.%02d.01", dt.year, dt.mon));

   if(HistorySelect(month_start, TimeCurrent()))
   {
      int total = HistoryDealsTotal();
      m_state.trading_days       = 0;
      m_state.last_trade_day     = 0;
      m_state.best_day_pnl       = 0.0;
      m_state.total_positive_pnl = 0.0;

      double day_profit  = 0.0;
      datetime day_profit_date = 0;

      for(int i = 0; i < total; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_params.magic) continue;

         double profit     = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         double swap       = HistoryDealGetDouble(ticket, DEAL_SWAP);
         double net        = profit + commission + swap;

         m_state.monthly_pnl += net;

         datetime deal_time = HistoryDealGetInteger(ticket, DEAL_TIME);
         if(deal_time >= day_start)
         {
            m_state.daily_pnl += net;
            m_state.daily_trades++;
         }

         //--- Daily profit tracking para consistency
         datetime deal_date = deal_time - (deal_time % 86400);
         if(deal_date != day_profit_date)
         {
            if(day_profit > 0)
            {
               m_state.total_positive_pnl += day_profit;
               if(day_profit > m_state.best_day_pnl)
                  m_state.best_day_pnl = day_profit;
            }
            day_profit_date = deal_date;
            day_profit = 0.0;
         }
         day_profit += net;

         //--- Contagem de dias únicos com trade
         if(deal_date != m_state.last_trade_day)
         {
            m_state.last_trade_day = deal_date;
            m_state.trading_days++;
         }
      }

      //--- Último dia processado
      if(day_profit > 0)
      {
         m_state.total_positive_pnl += day_profit;
         if(day_profit > m_state.best_day_pnl)
            m_state.best_day_pnl = day_profit;
      }
   }

   double daily_float = 0.0, monthly_float = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != m_params.magic) continue;

      double pnl = PositionGetDouble(POSITION_PROFIT) +
                   PositionGetDouble(POSITION_SWAP) +
                   PositionGetDouble(POSITION_COMMISSION);

      daily_float   += pnl;
      monthly_float += pnl;
   }

   m_state.daily_pnl   += daily_float;
   m_state.monthly_pnl += monthly_float;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > m_state.peak_balance)
      m_state.peak_balance = equity;
}

void CRiskManager_v2::Update()
{
   if(!m_params.enabled) return;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_year != m_state.day_of_year)
   {
      m_state.day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      m_state.daily_pnl        = 0.0;
      m_state.daily_trades     = 0;
      m_state.day_of_year      = dt.day_of_year;

      if(m_state.day_start_equity > m_state.peak_balance)
         m_state.peak_balance = m_state.day_start_equity;

      if(m_state.blocked &&
         m_state.block_reason != "Max Drawdown" &&
         m_state.block_reason != "Profit Target")
         Unblock();

      Print("[RISK v2] Daily reset | Equity: ", DoubleToString(m_state.day_start_equity, 2));
   }

   if(dt.mon != m_state.month)
   {
      m_state.monthly_pnl     = 0.0;
      m_state.peak_balance    = AccountInfoDouble(ACCOUNT_EQUITY);
      m_state.total_positive_pnl = 0.0;
      m_state.best_day_pnl       = 0.0;
      m_state.trading_days       = 0;
      m_state.last_trade_day  = 0;
      m_state.consec_losses   = 0;
      m_state.month           = dt.mon;

      if(m_state.blocked) Unblock();
      Print("[RISK v2] Monthly reset | Balance: ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   }

   RefreshPnL();

   CheckLimits();
}

void CRiskManager_v2::CheckLimits()
{
   if(!m_params.enabled) return;
   if(m_state.blocked) return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   // 1. Daily loss
   if(m_params.daily_loss_pct > 0)
   {
      double daily_pct = (m_state.day_start_equity > 0) ?
         MathMax(0, (m_state.day_start_equity - equity) / m_state.day_start_equity * 100.0) : 0.0;
      if(daily_pct >= m_params.daily_loss_pct)
      {
         Block("Daily Loss (" + DoubleToString(daily_pct, 1) + "% >= " + DoubleToString(m_params.daily_loss_pct, 1) + "%)");
         return;
      }
   }

   // 2. Max total drawdown (trailing from peak)
   if(m_params.max_drawdown_pct > 0)
   {
      double dd_pct = (m_state.peak_balance > 0) ?
         MathMax(0, (m_state.peak_balance - equity) / m_state.peak_balance * 100.0) : 0.0;
      if(dd_pct >= m_params.max_drawdown_pct)
      {
         Block("Max Drawdown (" + DoubleToString(dd_pct, 1) + "% >= " + DoubleToString(m_params.max_drawdown_pct, 1) + "%)");
         return;
      }
   }

   // 3. Profit target
   if(m_params.profit_target_pct > 0 && m_state.monthly_pnl > 0)
   {
      double profit_pct = (m_state.initial_balance > 0) ?
         (m_state.monthly_pnl / m_state.initial_balance) * 100.0 : 0.0;
      if(profit_pct >= m_params.profit_target_pct)
      {
         if(m_params.min_trading_days <= 0 || m_state.trading_days >= m_params.min_trading_days)
         {
            Block("Profit Target (" + DoubleToString(profit_pct, 1) + "% >= " + DoubleToString(m_params.profit_target_pct, 1) + "%)");
            return;
         }
         else
            Print("[RISK v2] Profit target reached but only ", m_state.trading_days,
                  "/", m_params.min_trading_days, " days. Continuing...");
      }
   }

   // 4. Max daily trades
   if(m_params.max_daily_trades > 0 && m_state.daily_trades >= m_params.max_daily_trades)
   {
      Block("Max Daily Trades (" + IntegerToString(m_state.daily_trades) + "/" + IntegerToString(m_params.max_daily_trades) + ")");
      return;
   }
}

bool CRiskManager_v2::CanOpenNewOrder()
{
   if(!m_params.enabled) return true;
   return !m_state.blocked;
}

void CRiskManager_v2::ManagePositions()
{
   if(!m_params.enabled) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != m_params.magic) continue;

      double pnl = PositionGetDouble(POSITION_PROFIT) +
                   PositionGetDouble(POSITION_SWAP) +
                   PositionGetDouble(POSITION_COMMISSION);

      //--- Stop loss individual por posição
      if(m_params.position_stop_usd > 0 && pnl <= -m_params.position_stop_usd)
      {
         Print("[RISK v2] Position stop. Closing: ", ticket, " PnL: ", DoubleToString(pnl, 2));
         m_trade.PositionClose(ticket);
         continue;
      }

      //--- Consistency preventiva por posição (fecha ANTES de quebrar a regra)
      //    A regra da mesa: melhor resultado / soma de todos os resultados positivos <= limite
      //    Se esta posição com lucro faria a regra quebrar, fecha só ela, sem bloquear o EA.
      if(m_params.consistency_pct > 0 && pnl > 0 &&
         m_state.total_positive_pnl > 0 && m_state.trading_days >= 3)
      {
         double month_profit_pct = (m_state.initial_balance > 0) ?
            (m_state.monthly_pnl / m_state.initial_balance) * 100.0 : 0.0;
         if(month_profit_pct >= 0.5)
         {
            double projected_total = m_state.total_positive_pnl + pnl;
            double projected_best  = MathMax(m_state.best_day_pnl, pnl);
            double projected_cons  = projected_best / projected_total * 100.0;

            if(projected_cons >= m_params.consistency_pct)
            {
               Print("[RISK v2] Consistency protect. Closing: ", ticket,
                     " PnL: ", DoubleToString(pnl, 2),
                     " (proj. ", DoubleToString(projected_cons, 1), "% >= ",
                     DoubleToString(m_params.consistency_pct, 1), "%)");
               m_trade.PositionClose(ticket);
            }
         }
      }
   }
}

void CRiskManager_v2::Block(string reason)
{
   m_state.blocked      = true;
   m_state.block_reason = reason;
   Print("[RISK v2] BLOCKED: ", reason);

   if(!m_params.close_on_breach) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == m_params.magic)
         m_trade.PositionClose(ticket);
   }
}

void CRiskManager_v2::Unblock()
{
   m_state.blocked      = false;
   m_state.block_reason = "";
   Print("[RISK v2] UNBLOCKED");
}

double CRiskManager_v2::GetDrawdownPct() const
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return (m_state.peak_balance > 0) ?
      MathMax(0, (m_state.peak_balance - equity) / m_state.peak_balance * 100.0) : 0.0;
}

double CRiskManager_v2::GetDailyPct() const
{
   return (m_state.day_start_equity > 0) ?
      (m_state.daily_pnl / m_state.day_start_equity) * 100.0 : 0.0;
}

double CRiskManager_v2::GetProfitPct() const
{
   return (m_state.initial_balance > 0) ?
      (m_state.monthly_pnl / m_state.initial_balance) * 100.0 : 0.0;
}
