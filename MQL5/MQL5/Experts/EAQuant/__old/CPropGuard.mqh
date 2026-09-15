//+------------------------------------------------------------------+
//|                                                  CPropGuard.mqh   |
//|                     Prop Firm Compliance Guardrails               |
//|                     Daily DD + Max DD + Equity Guard              |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property strict

//+------------------------------------------------------------------+
//| CPropGuard - Guardrails de compliance para prop firms             |
//+------------------------------------------------------------------+
class CPropGuard
{
private:
   //--- Daily Drawdown
   double   m_daily_start_balance;   // Balance no início do dia
   double   m_daily_start_equity;    // Equity no início do dia
   datetime m_daily_reset_time;      // Timestamp do último reset
   
   //--- Max Drawdown
   double   m_peak_equity;          // Maior equity já visto
   datetime m_peak_time;           // Quando atingiu o pico
   
   //--- Max Daily Trades
   int      m_daily_trade_count;    // Trades executados hoje
   int      m_max_daily_trades;     // Limite diário (0=off)
   
   //--- Config
   bool     m_daily_dd_active;     // Daily DD ligado
   bool     m_max_dd_active;      // Max DD ligado
   double   m_max_daily_dd_pct;   // % limite diário (ex: 4%)
   double   m_max_dd_pct;         // % limite total (ex: 8%)
   string   m_symbol;             // Para GlobalVariable unique
   
   //--- Helpers
   string   GVKey(string suffix) { return "QFX_GUARD_" + suffix + "_" + m_symbol; }
   
public:
   //+------------------------------------------------------------------+
   //| Construtor                                                        |
   //+------------------------------------------------------------------+
   CPropGuard() : m_daily_start_balance(0),
                  m_daily_start_equity(0),
                  m_daily_reset_time(0),
                  m_peak_equity(0),
                  m_peak_time(0),
                  m_daily_trade_count(0),
                  m_max_daily_trades(0),
                  m_daily_dd_active(false),
                  m_max_dd_active(false),
                  m_max_daily_dd_pct(0),
                  m_max_dd_pct(0),
                  m_symbol("")
   {
   }
   
   //+------------------------------------------------------------------+
   //| Inicialização                                                     |
   //+------------------------------------------------------------------+
   void Init(string symbol, double max_daily_pct, double max_total_pct, int max_daily_trades=0)
   {
      m_symbol = symbol;
      m_max_daily_dd_pct  = max_daily_pct;
      m_max_dd_pct        = max_total_pct;
      m_max_daily_trades  = max_daily_trades;
      m_daily_dd_active   = (max_daily_pct > 0.0);
      m_max_dd_active     = (max_total_pct > 0.0);
      
      //--- Tenta carregar estado salvo
      LoadState();
      
      //--- Se não tem estado válido, inicializa com valores atuais
      if(m_daily_reset_time == 0)
         ResetDaily();
      
      if(m_peak_equity <= 0.0)
      {
         m_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
         m_peak_time   = TimeCurrent();
      }
   }
   
   //+------------------------------------------------------------------+
   //| Chamado a cada tick - atualiza estado e verifica limites          |
   //+------------------------------------------------------------------+
   void Update(double current_equity, double current_balance)
   {
      //--- Detecta mudança de dia (reseta contadores diários)
      MqlDateTime dt_now, dt_last;
      TimeToStruct(TimeCurrent(), dt_now);
      TimeToStruct(m_daily_reset_time, dt_last);
      
      if(dt_now.day != dt_last.day || dt_now.mon != dt_last.mon)
      {
         ResetDaily();
      }
      
      //--- Atualiza pico de equity
      if(current_equity > m_peak_equity)
      {
         m_peak_equity = current_equity;
         m_peak_time   = TimeCurrent();
      }
      
      //--- Salva estado periodicamente (a cada 60s via OnTimer)
   }
   
   //+------------------------------------------------------------------+
   //| Verifica se DD diário foi violado                                 |
   //+------------------------------------------------------------------+
   bool IsDailyDDBreached()
   {
      if(!m_daily_dd_active) return false;
      if(m_daily_start_balance <= 0.0) return false;
      
      double dd_pct = GetDailyDDPercent();
      return (dd_pct >= m_max_daily_dd_pct);
   }
   
   //+------------------------------------------------------------------+
   //| Verifica se DD máximo foi violado                                 |
   //+------------------------------------------------------------------+
   bool IsMaxDDBreached()
   {
      if(!m_max_dd_active) return false;
      if(m_peak_equity <= 0.0) return false;
      
      double dd_pct = GetMaxDDPercent();
      return (dd_pct >= m_max_dd_pct);
   }
   
   //+------------------------------------------------------------------+
   //| Verifica se limite diário de trades foi violado                   |
   //+------------------------------------------------------------------+
   bool IsMaxDailyTradesBreached()
   {
      if(m_max_daily_trades <= 0) return false; // filtro desligado
      return (m_daily_trade_count >= m_max_daily_trades);
   }
   
   //+------------------------------------------------------------------+
   //| Incrementa contador de trades do dia (chamar após fill)           |
   //+------------------------------------------------------------------+
   void IncrementTradeCount()
   {
      m_daily_trade_count++;
   }
   
   //+------------------------------------------------------------------+
   //| Retorna trades executados hoje                                    |
   //+------------------------------------------------------------------+
   int GetDailyTradeCount() { return m_daily_trade_count; }
   
   //+------------------------------------------------------------------+
   //| Retorna limite diário de trades                                   |
   //+------------------------------------------------------------------+
   int GetMaxDailyTrades() { return m_max_daily_trades; }
   
   //+------------------------------------------------------------------+
   //| Verifica se qualquer limite de DD foi violado                     |
   //+------------------------------------------------------------------+
   bool IsAnyLimitBreached()
   {
      return (IsDailyDDBreached() || IsMaxDDBreached());
   }
   
   //+------------------------------------------------------------------+
   //| Verifica se pode abrir novo trade (limite diário)                |
   //+------------------------------------------------------------------+
   bool CanOpenTrade()
   {
      if(m_max_daily_trades <= 0) return true; // filtro desligado
      return (m_daily_trade_count < m_max_daily_trades);
   }
   
   //+------------------------------------------------------------------+
   //| Retorna DD diário em % (positivo = perda)                         |
   //+------------------------------------------------------------------+
   double GetDailyDDPercent()
   {
      if(m_daily_start_balance <= 0.0) return 0.0;
      
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double loss   = m_daily_start_balance - equity;
      
      if(loss <= 0.0) return 0.0; // lucro, não há DD
      
      return (loss / m_daily_start_balance) * 100.0;
   }
   
   //+------------------------------------------------------------------+
   //| Retorna DD total em % (positivo = perda)                          |
   //+------------------------------------------------------------------+
   double GetMaxDDPercent()
   {
      if(m_peak_equity <= 0.0) return 0.0;
      
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double loss   = m_peak_equity - equity;
      
      if(loss <= 0.0) return 0.0; // novo pico, não há DD
      
      return (loss / m_peak_equity) * 100.0;
   }
   
   //+------------------------------------------------------------------+
   //| Retorna DD diário em $ (positivo = perda)                         |
   //+------------------------------------------------------------------+
   double GetDailyDollar()
   {
      if(m_daily_start_balance <= 0.0) return 0.0;
      
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double loss   = m_daily_start_balance - equity;
      
      return (loss > 0.0) ? loss : 0.0;
   }
   
   //+------------------------------------------------------------------+
   //| Retorna DD total em $ (positivo = perda)                          |
   //+------------------------------------------------------------------+
   double GetMaxDDollar()
   {
      if(m_peak_equity <= 0.0) return 0.0;
      
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double loss   = m_peak_equity - equity;
      
      return (loss > 0.0) ? loss : 0.0;
   }
   
   //+------------------------------------------------------------------+
   //| Reseta contadores diários                                         |
   //+------------------------------------------------------------------+
   void ResetDaily()
   {
      m_daily_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      m_daily_start_equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      m_daily_reset_time    = TimeCurrent();
      m_daily_trade_count   = 0; // reseta contador de trades
   }
   
   //+------------------------------------------------------------------+
   //| Salva estado em GlobalVariables                                   |
   //+------------------------------------------------------------------+
   void SaveState()
   {
      GlobalVariableSet(GVKey("BAL"),     m_daily_start_balance);
      GlobalVariableSet(GVKey("EQ"),      m_daily_start_equity);
      GlobalVariableSet(GVKey("DT"),      (double)m_daily_reset_time);
      GlobalVariableSet(GVKey("PEAK"),    m_peak_equity);
      GlobalVariableSet(GVKey("TRADES"),  (double)m_daily_trade_count);
   }
   
   //+------------------------------------------------------------------+
   //| Carrega estado de GlobalVariables                                 |
   //+------------------------------------------------------------------+
   void LoadState()
   {
      if(GlobalVariableCheck(GVKey("BAL")))
         m_daily_start_balance = GlobalVariableGet(GVKey("BAL"));
      
      if(GlobalVariableCheck(GVKey("EQ")))
         m_daily_start_equity = GlobalVariableGet(GVKey("EQ"));
      
      if(GlobalVariableCheck(GVKey("DT")))
         m_daily_reset_time = (datetime)GlobalVariableGet(GVKey("DT"));
      
      if(GlobalVariableCheck(GVKey("PEAK")))
         m_peak_equity = GlobalVariableGet(GVKey("PEAK"));
      
      if(GlobalVariableCheck(GVKey("TRADES")))
         m_daily_trade_count = (int)GlobalVariableGet(GVKey("TRADES"));
   }
   
   //+------------------------------------------------------------------+
   //| Status formatado para log                                         |
   //+------------------------------------------------------------------+
   string GetStatus()
   {
      string status = "";
      
      //--- Daily DD
      if(m_daily_dd_active)
      {
         double dd_pct  = GetDailyDDPercent();
         double dd_dol  = GetDailyDollar();
         double dd_left = m_max_daily_dd_pct - dd_pct;
         
         status += StringFormat("Daily: %.1f%%/$%.0f (limite: %.1f%%,resta: %.1f%%)",
                               dd_pct, dd_dol, m_max_daily_dd_pct, dd_left);
      }
      
      //--- Max DD
      if(m_max_dd_active)
      {
         double dd_pct  = GetMaxDDPercent();
         double dd_dol  = GetMaxDDollar();
         double dd_left = m_max_dd_pct - dd_pct;
         
         if(StringLen(status) > 0) status += " | ";
         status += StringFormat("MaxDD: %.1f%%/$%.0f (limite: %.1f%%,resta: %.1f%%)",
                               dd_pct, dd_dol, m_max_dd_pct, dd_left);
      }
      
      //--- Daily Trades
      if(m_max_daily_trades > 0)
      {
         if(StringLen(status) > 0) status += " | ";
         status += StringFormat("Trades: %d/%d", m_daily_trade_count, m_max_daily_trades);
      }
      
      //--- Pico
      status += StringFormat(" | Peak: $%.0f", m_peak_equity);
      
      //--- Balance inicial do dia
      status += StringFormat(" | DailyStart: $%.0f", m_daily_start_balance);
      
      return status;
   }
   
   //+------------------------------------------------------------------+
   //| Getter para Equity inicial do dia (usado no OnTick)               |
   //+------------------------------------------------------------------+
   double GetDailyStartBalance() { return m_daily_start_balance; }
   double GetDailyStartEquity()  { return m_daily_start_equity;  }
   double GetPeakEquity()        { return m_peak_equity;          }
};
