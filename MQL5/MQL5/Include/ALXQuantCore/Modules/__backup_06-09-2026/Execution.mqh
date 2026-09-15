//+------------------------------------------------------------------+
//| Execution.mqh                                                    |
//| ALXQuantCore - Execution + Position Sizing                       |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property version "10.0"

/*
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
    v.7.13 - 2026-07-31 - Add: log de diagnostico (preco SL/TP) na Execucao de ordens.
    v.7.20 - 2026-08-01 - Add: SL_ATR por banda StopATR (high/low - Kv*ATR), SetSLValue(), per-side SL/TP.
    v.7.40 - 2026-08-01 - Change: trailing unificado (m_trail_distance + m_trail_step), TRAIL_ATR segue banda StopATR, ComputeTrailBands().
    v.7.41 - 2026-08-01 - Fix: TRAIL_ATR com m_trail_distance<=0 => fallback mult 1.0 + warning (trailing nao fica mudo).
    v.7.42 - 2026-08-07 - Refactor: enLotMode consolidado neste modulo.
    v.7.43 - 2026-08-13 - Fix: documentacao enLotMode (fonte unica eh este modulo, removido de Core\enums.mqh p/ evitar redeclaracao).
    v.7.50 - 2026-08-13 - Add: ResetState() publico p/ destravar motor apos STATE_FAILED.
    v.7.60 - 2026-08-15 - Add: SetADRPeriod() p/ ADR configurable (TP_ADR). Fix: medias de slippage/latency usam m_success_count (nao m_total_requests); clamp reject_rate em GetBrokerScore().
    v.7.61 - 2026-08-20 - Institutional fixes:
                         - Lot risk via OrderCalcProfit (multi-asset safe: Forex/XAU/BTC/OIL/Stocks)
                         - PipToPrice robusto multi-instrumento
                         - Calculate() agora sincroniza m_symbol com o symbol passado
                         - NormalizeLot com risk_usd real e leverage clamp mais inteligente
                         - ClosePartial assinatura correta
                         - Clamp de SL dinâmico (StopsLevel + proteção mínima)
                         - Melhor tratamento de edge-cases (TickValue=0, ATR=0, etc.)
                         - Logs de diagnóstico aprimorados
                         - Compatibilidade total com Painel e EA principal (nenhum método público removido)
    v.7.62 - 2026-08-20 - Fix: NormalizeLot notional_per_lot na MOEDA DA CONTA
                         ((price/tick_size)*tick_value). contract_size*price inflava
                         ~150x em instrumentos com cotacao != moeda da conta (ex.:
                         GBPJPY/USD) e o clamp de alavancagem pinava o lote no minimo,
                         tornando InpLotValue inerte.
                         - Fix: ClosePartial usava PositionClose(ticket, volume) onde
                         o 2o arg e deviation (ulong); agora PositionClosePartial()
                         (correto para fechamento parcial).
    v.7.63 - 2026-08-20 - Fix: aceita retcode 10008 (Pending) para ordens Limit/Stop além do 10009 (Done).
    v.7.64 - 2026-08-24 - Fix: NormalizeLot - variavel risk_per_lot movida para fora do switch (escopo); ordem dos argumentos corrigida (sl_dist, risk_per_lot_hint).
*/
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <ALXQuantCore\Modules\MacroRegimeEngine.mqh>
#define BALANCE_UNIT 1000.0
#define STOPATR_LOOKBACK 10
#define STOPATR_ATR_PERIOD 14
//+------------------------------------------------------------------+
//| TradeParams - output structure from Calculate()                  |
//+------------------------------------------------------------------+
struct TradeParams
{
   double lot;
   double sl;
   double sl_long;
   double sl_short;
   double tp;
   double tp_long;
   double tp_short;
   double be_distance;
   double trail_distance;
   double trail_step;
   double risk_pct_used;
   double risk_usd;
};
//+------------------------------------------------------------------+
//| ENUMS                                                            |
//+------------------------------------------------------------------+
enum ENUM_ALX_EXEC_STATE
{
   STATE_IDLE = 0,
   STATE_SENDING,
   STATE_WAITING,
   STATE_CONFIRMED,
   STATE_PARTIAL,
   STATE_REJECTED,
   STATE_TIMEOUT,
   STATE_FAILED
};
enum ENUM_ALX_EXEC_RESULT
{
   RESULT_SUCCESS = 0,
   RESULT_REQUOTE,
   RESULT_REJECTED,
   RESULT_SLIPPAGE_EXCEED,
   RESULT_INVALID_STOPS,
   RESULT_INVALID_VOLUME,
   RESULT_NO_MONEY,
   RESULT_MARKET_CLOSED,
   RESULT_TRADE_DISABLED,
   RESULT_TIMEOUT,
   RESULT_PRICE_CHANGED,
   RESULT_OFF_QUOTES,
   RESULT_BROKER_BUSY,
   RESULT_UNKNOWN
};
enum enLotMode
{
   lot_min,     // Lot min
   lot_fixed,   // Fixed lot
   lot_balance, // Lot balance
   lot_risk,    // Lot risk
};
//--- Lot Mode: fonte única deste modulo (removido de Core\enums.mqh em v7.43) ---
//+------------------------------------------------------------------+
//| MAIN CLASS                                                       |
//| Execution Engine + Position Sizing (consolidated)                |
//+------------------------------------------------------------------+
class CExecution
{
private:
   //--- Position Sizing Parameters ---
   enLotMode          m_lot_mode;
   double             m_lot_value;
  
   ENUM_ALX_SL_MODE   m_sl_mode;
   double             m_sl_value;
  
   ENUM_ALX_TP_MODE   m_tp_mode;
   double             m_tp_value;
   int                m_adr_days;
   ENUM_ALX_BE_MODE   m_be_mode;
   double             m_be_value;
   ENUM_ALX_TRAIL_MODE m_trail_mode;
   double             m_trail_distance; // pips (FIXED) ou ATR mult (ATR)
   double             m_trail_step;     // pips (ambos os modos)
   bool               m_trail_warned;   // warn 1x p/ distance<=0 no modo ATR
   //--- Analytics de Spread ---
   double             m_spread_total;
   double             m_spread_max;
   long               m_spread_samples;
   double             m_hourly_slippage[24];
   long               m_hourly_count[24];
   bool               m_broker_toxic;
   double             m_max_spread_points;   // 0 = desligado; > 0 = gate
   bool               m_block_if_toxic;      // false por default; true = bloqueia se IsBrokerToxic()
   // --- State Machine & Context ---
   ENUM_ALX_EXEC_STATE m_state;
   ulong              m_request_order;
    uint               m_request_time;
    double             m_request_price;
    int                m_current_retry;
    bool               m_is_busy;
    // --- Async retry state (v7.64) ---
    bool               m_pending_retry;
    uint               m_retry_after_time;
    ENUM_ORDER_TYPE    m_retry_type;
    double             m_retry_volume;
    double             m_retry_target_price;
    double             m_retry_sl;
    double             m_retry_tp;
    string             m_retry_comment;
   // --- Config ---
   ulong              m_magic;
   int                m_max_retries;
   int                m_retry_delay_ms;
   int                m_timeout_ms;
   // --- Analytics ---
   long               m_total_requests;
   long               m_success_count;
   long               m_reject_count;
   long               m_requote_count;
   long               m_timeout_count;
   double             m_total_slippage;
   double             m_max_slippage;
   double             m_total_latency_ms;
   double             m_max_latency_ms;
   //--- Dependencies ---
   CMacroRegimeEngine *m_regime;
   // --- Internal Methods ---
   ENUM_ALX_EXEC_RESULT ParseRetcode(uint retcode);
   void                 ResetContext();
   double               PipToPrice(double pips);
   double               CalcADR(int days = 14);
   double               NormalizeLot(double raw_lot, string symbol, double sl_dist, double risk_per_lot_hint, double &risk_usd_out);
   bool                 ComputeStopATRBands(string symbol, ENUM_TIMEFRAMES period, int atr_period,
                                            int length, double kv, double &support, double &resistance);
   double               TrailATRMultiplier();
   double               GetRiskPerLot(string symbol, double sl_dist); // v7.61 - OrderCalcProfit based
public:
                        CExecution(void);
   bool                 Init(string symbol, ulong magic, int max_retries, int retry_delay, int timeout, CMacroRegimeEngine *regime);
   // --- Position Sizing Setters ---
   void SetLotMode(enLotMode mode)               { m_lot_mode = mode; }
   void SetLotValue(double val)                  { m_lot_value = val; }
   void SetSLMode(ENUM_ALX_SL_MODE mode)         { m_sl_mode = mode; }
   void SetSLValue(double v)                     { m_sl_value = v; }
   void SetTPMode(ENUM_ALX_TP_MODE mode)         { m_tp_mode = mode; }
   void SetTPValue(double r)                     { m_tp_value = r; }
   void SetADRPeriod(int days)                   { if(days > 0) m_adr_days = days; }
   void SetBEMode(ENUM_ALX_BE_MODE mode)         { m_be_mode = mode; }
   void SetBEValue(double pips)                  { m_be_value = pips; }
   void SetTrailMode(ENUM_ALX_TRAIL_MODE mode)   { m_trail_mode = mode; }
   void SetTrailDistance(double dist)            { m_trail_distance = dist; }
   void SetTrailStep(double step)                { m_trail_step = step; }
   void SetMaxSpreadPoints(double v)             { m_max_spread_points = v; }
   void SetBlockIfToxic(bool flag)               { m_block_if_toxic = flag; }
   // --- Core Calculation ---
   TradeParams          Calculate(string symbol, double sl_points = 0);
   // --- Trailing band (TRAIL_ATR segue a linha StopATR) ---
   bool                 ComputeTrailBands(double &support, double &resistance);
   // --- Execution Core ---
   double               LotCheck(double lot, string symbol = "");
   bool                 Execute(ENUM_ORDER_TYPE type, double volume, double sl, double tp, string comment = "");
   bool                 Execute(ENUM_ORDER_TYPE type, double volume, double target_price, double sl, double tp, string comment = "");
   bool                 Buy(double volume, double sl = 0, double tp = 0, string comment = "");
   bool                 Sell(double volume, double sl = 0, double tp = 0, string comment = "");
   bool                 Close(ulong ticket);
   bool                 Modify(ulong ticket, double sl, double tp);
   bool                 ClosePartial(ulong ticket, double volume_to_close);
   void                 CloseProfitPositions(ulong magic);
   // --- Validations ---
   bool                 ValidateVolume(double volume);
   bool                 ValidateMargin(ENUM_ORDER_TYPE type, double volume, double target_price = 0);
   // --- State control ---
   void                 ResetState() { m_state = STATE_IDLE; m_is_busy = false; m_current_retry = 0; }
   // --- Transaction & Timeout Engines ---
   void                 ProcessTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result);
   void                 Update();
   // --- Analytics & Getters ---
   double               GetAverageSlippage() { return (m_success_count > 0) ? m_total_slippage / m_success_count : 0; }
   double               GetAverageLatency()  { return (m_success_count > 0) ? m_total_latency_ms / m_success_count : 0; }
   double               GetSuccessRate()     { return (m_total_requests > 0) ? (double)m_success_count / m_total_requests * 100.0 : 0; }
   double               GetBrokerScore();
   bool                 IsBusy()             { return m_is_busy; }
   ENUM_ALX_EXEC_STATE  GetState()           { return m_state; }
   double               GetAverageSpread();
   bool                 IsBrokerToxic();
   string               StateToString();
   void                 UpdateSpreadStats();
   void                 CreatePanelBackground(string name, int x, int y, int w, int h, color bg);
    long                 GetTotalRequests()   { return m_total_requests; }
    long                 GetSucessCount()     { return m_success_count; } // mantido exatamente como está (compatibilidade)
    long                 GetRejectCount()     { return m_reject_count; }
    double               GetMaxSlippage()     { return m_max_slippage; }
    double               GetMaxLatency()      { return m_max_latency_ms; }
    long                 GetRequoteCount()    { return m_requote_count; }
    long                 GetTimeoutCount()    { return m_timeout_count; }
    string               GetQualityJson();
    void                 SaveQualityToFile();
   //--- Objetos Nativos ---
   CPositionInfo        m_position;
   CTrade               m_trade;
   CSymbolInfo          m_symbol;
   CAccountInfo         m_account;
   CDealInfo            m_deal;
   COrderInfo           m_order;
};
//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CExecution::CExecution(void) : m_state(STATE_IDLE), m_request_order(0), m_request_time(0),
                                m_request_price(0), m_current_retry(0), m_is_busy(false),
                                m_magic(0), m_max_retries(3), m_retry_delay_ms(100), m_timeout_ms(5000),
                                m_total_requests(0), m_success_count(0), m_reject_count(0),
                                m_requote_count(0), m_timeout_count(0), m_total_slippage(0),
                                m_max_slippage(0), m_total_latency_ms(0), m_max_latency_ms(0)
{
   m_spread_total   = 0;
   m_spread_max     = 0;
   m_spread_samples = 0;
   m_broker_toxic   = false;
   m_max_spread_points = 0.0;
   m_block_if_toxic = false;
   m_regime         = NULL;
   m_pending_retry  = false;
   m_retry_after_time = 0;
   m_retry_type     = ORDER_TYPE_BUY;
   m_retry_volume   = 0;
   m_retry_target_price = 0;
   m_retry_sl       = 0;
   m_retry_tp       = 0;
   m_pending_retry  = false;
   m_retry_after_time = 0;
   m_retry_type     = ORDER_TYPE_BUY;
   m_lot_mode       = lot_min;
   m_lot_value      = 0.5;
   m_sl_mode        = SL_ATR;
   m_sl_value       = 2.0;
   m_tp_mode        = TP_RISK_REWARD;
   m_tp_value       = 2.0;
   m_adr_days       = 14;
   m_be_mode        = BE_ATR;
   m_be_value       = 10.0;
   m_trail_mode     = TRAIL_ATR;
   m_trail_distance = 100.0;
   m_trail_step     = 50.0;
   m_trail_warned   = false;
   ArrayInitialize(m_hourly_slippage, 0);
   ArrayInitialize(m_hourly_count, 0);
}
//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
bool CExecution::Init(string symbol, ulong magic, int max_retries, int retry_delay, int timeout, CMacroRegimeEngine *regime)
{
   if(!m_symbol.Name(symbol)) return false;
   if(!m_symbol.RefreshRates()) return false;
   m_magic           = magic;
   m_max_retries     = max_retries;
   m_retry_delay_ms  = retry_delay;
   m_timeout_ms      = timeout;
   m_regime          = regime;
  
   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(symbol);
   m_trade.SetDeviationInPoints(10);
   if(DEBUG_MODE)
      Print("[ALX EXEC] Engine Initialized. Symbol: ", symbol, " Magic: ", magic);
   return true;
}
//+------------------------------------------------------------------+
//| Reset Context                                                    |
//+------------------------------------------------------------------+
void CExecution::ResetContext()
{
   m_state         = STATE_IDLE;
   m_request_order = 0;
   m_request_time  = 0;
   m_request_price = 0;
   m_current_retry = 0;
   m_is_busy       = false;
}
//+------------------------------------------------------------------+
//| VALIDATIONS                                                      |
//+------------------------------------------------------------------+
bool CExecution::ValidateVolume(double volume)
{
   if(volume < m_symbol.LotsMin() || volume > m_symbol.LotsMax()) return false;
   double step = m_symbol.LotsStep();
   if(step > 0 && MathAbs(MathRound(volume / step) * step - volume) > 0.0000001) return false;
   return true;
}
bool CExecution::ValidateMargin(ENUM_ORDER_TYPE type, double volume, double target_price)
{
   double price = 0;
  
   if(target_price > 0) price = target_price;
   else price = (type == ORDER_TYPE_BUY || type == ORDER_TYPE_BUY_LIMIT ||
                 type == ORDER_TYPE_BUY_STOP) ? m_symbol.Ask() : m_symbol.Bid();
  
   double margin = m_account.MarginCheck(m_symbol.Name(), type, volume, price);
  
   if(margin == 0)
   {
      return true; // Permite que o broker decida se faltar margem
   }
  
   double free_margin   = m_account.FreeMargin();
   double safety_margin = free_margin * 0.001;
  
   return (margin > 0 && margin <= (free_margin - safety_margin));
}
//+------------------------------------------------------------------+
//| EXECUTION ENGINE (Com Preço Alvo - Limit/Stop/Market)            |
//+------------------------------------------------------------------+
bool CExecution::Execute(ENUM_ORDER_TYPE type, double volume, double target_price, double sl, double tp, string comment)
{
    if(m_is_busy) return false;
    if(!m_symbol.RefreshRates()) return false;

    // gate de spread (se configurado)
    if(m_max_spread_points > 0)
    {
       double current_spread_pts = (m_symbol.Ask() - m_symbol.Bid()) / m_symbol.Point();
       if(current_spread_pts > m_max_spread_points)
       {
          if(DEBUG_MODE) Print("[ALX ERROR] Spread acima do limite: ", current_spread_pts, " > ", m_max_spread_points);
          m_reject_count++;
          return false;
       }
    }

    // gate de toxicidade (opcional, opt-in)
    if(m_block_if_toxic && IsBrokerToxic())
    {
       if(DEBUG_MODE) Print("[ALX ERROR] Broker toxic detectado. Ordem recusada.");
       m_reject_count++;
       return false;
    }

   volume = LotCheck(volume, m_symbol.Name());
     
   if(!ValidateVolume(volume))
   {
      if(DEBUG_MODE)
         Print("[ALXC ERROR] Invalid Volume: ", volume);
      m_reject_count++;
      return false;
   }
   if(!ValidateMargin(type, volume, target_price))
   {
      if(DEBUG_MODE)
         Print("[ALX ERROR] No Money for Volume: ", volume);
      m_reject_count++;
      return false;
   }
  
   m_state        = STATE_SENDING;
   m_request_time = GetTickCount();
  
   bool send_result = false;
  
   switch(type)
   {
      case ORDER_TYPE_BUY:
         m_request_price = m_symbol.Ask();
         send_result = m_trade.Buy(volume, m_symbol.Name(), m_symbol.Ask(), sl, tp, comment);
         break;
        
      case ORDER_TYPE_SELL:
         m_request_price = m_symbol.Bid();
         send_result = m_trade.Sell(volume, m_symbol.Name(), m_symbol.Bid(), sl, tp, comment);
         break;
     
      case ORDER_TYPE_BUY_LIMIT:
         m_request_price = target_price;
         send_result = m_trade.BuyLimit(volume, target_price, m_symbol.Name(), sl, tp, ORDER_TIME_GTC, 0, comment);
         break;
        
      case ORDER_TYPE_SELL_LIMIT:
         m_request_price = target_price;
         send_result = m_trade.SellLimit(volume, target_price, m_symbol.Name(), sl, tp, ORDER_TIME_GTC, 0, comment);
         break;
        
      case ORDER_TYPE_BUY_STOP:
         m_request_price = target_price;
         send_result = m_trade.BuyStop(volume, target_price, m_symbol.Name(), sl, tp, ORDER_TIME_GTC, 0, comment);
         break;
        
      case ORDER_TYPE_SELL_STOP:
         m_request_price = target_price;
         send_result = m_trade.SellStop(volume, target_price, m_symbol.Name(), sl, tp, ORDER_TIME_GTC, 0, comment);
         break;
        
      default:
         if(DEBUG_MODE)
            Print("[ALX ERROR] Unsupported Order Type: ", EnumToString(type));
         m_is_busy = false;
         return false;
   }
  
   uint retcode = m_trade.ResultRetcode();
   ENUM_ALX_EXEC_RESULT result = ParseRetcode(retcode);
   // v7.63: aceita 10008 (Pending) para ordens Limit/Stop além do 10009 (Done)
   bool is_pending = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT ||
                       type == ORDER_TYPE_BUY_STOP  || type == ORDER_TYPE_SELL_STOP);
   if(send_result && ((retcode == 10009) || (is_pending && retcode == 10008)))
   {
      m_state         = STATE_WAITING;
      m_request_order = m_trade.ResultOrder();
      m_is_busy       = true;
      m_total_requests++;
      Print("[EXEC] Order Sent. Ticket: ", m_request_order, " Type: ", EnumToString(type),
            " Price: ", m_request_price, " SL: ", sl, " TP: ", tp, " Comment: ", comment);
      return true;
   }
   else
   {
      m_state = STATE_FAILED;
      m_reject_count++;
      m_total_requests++;
      if(DEBUG_MODE)
         Print("[ALX ERROR] Reject. Retcode: ", retcode, " ", m_trade.ResultRetcodeDescription());
     
      if(result == RESULT_REQUOTE || result == RESULT_OFF_QUOTES || result == RESULT_BROKER_BUSY)
       {
          if(m_current_retry < m_max_retries)
          {
             m_current_retry++;
             if(DEBUG_MODE)
                Print("[ALX RETRY] Attempt ", m_current_retry, " in ", m_retry_delay_ms, "ms");
             m_pending_retry = true;
             m_retry_after_time = GetTickCount() + m_retry_delay_ms;
             m_retry_type = type;
             m_retry_volume = volume;
             m_retry_target_price = target_price;
             m_retry_sl = sl;
             m_retry_tp = tp;
             m_retry_comment = comment;
             m_is_busy = true; // continua ocupado ate o retry disparar
             return true;
          }
       }
     
      m_current_retry = 0;
      m_is_busy       = false;
      return false;
   }
}
//+------------------------------------------------------------------+
//| EXECUTION ENGINE (Apenas Market - Simples)                       |
//+------------------------------------------------------------------+
bool CExecution::Execute(ENUM_ORDER_TYPE type, double volume, double sl, double tp, string comment)
{
   // Redireciona para a função principal passando preço 0 (que vira Ask/Bid)
   return Execute(type, volume, 0.0, sl, tp, comment);
}
//+------------------------------------------------------------------+
//| High Level API                                                   |
//+------------------------------------------------------------------+
bool CExecution::Buy(double volume, double sl, double tp, string comment)
{
   return Execute(ORDER_TYPE_BUY, volume, sl, tp, comment);
}
bool CExecution::Sell(double volume, double sl, double tp, string comment)
{
   return Execute(ORDER_TYPE_SELL, volume, sl, tp, comment);
}
bool CExecution::Close(ulong ticket)
{
   return m_trade.PositionClose(ticket);
}
bool CExecution::Modify(ulong ticket, double sl, double tp)
{
   return m_trade.PositionModify(ticket, sl, tp);
}
//+------------------------------------------------------------------+
//| TRANSACTION ENGINE (LIMPO - SEM GRID TP)                         |
//+------------------------------------------------------------------+
void CExecution::ProcessTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest &request,
   const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   long   deal_magic  = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   string deal_symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   long   deal_order  = HistoryDealGetInteger(trans.deal, DEAL_ORDER);
   long   deal_entry  = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   long   deal_type   = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   double exec_price  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double exec_volume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   ulong  deal_ticket = HistoryDealGetInteger(trans.deal, DEAL_TICKET);
   if(deal_magic != m_magic) return;
   if(deal_symbol != m_symbol.Name()) return;
   if(deal_entry != DEAL_ENTRY_IN) return;
   // A partir daqui, apenas medição de latência e slippage
   if(m_state != STATE_WAITING) return;
   if(m_request_order != deal_order) return;
   m_state = STATE_CONFIRMED;
   double slippage = MathAbs(exec_price - m_request_price) / _Point;
   double latency  = (double)(GetTickCount() - m_request_time);
   m_success_count++;
   m_total_slippage += slippage;
   if(slippage > m_max_slippage) m_max_slippage = slippage;
   m_total_latency_ms += latency;
   if(latency > m_max_latency_ms) m_max_latency_ms = latency;
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   int h = tm.hour;
   m_hourly_slippage[h] += slippage;
   m_hourly_count[h]++;
   m_broker_toxic = IsBrokerToxic();
   m_is_busy      = false;
   m_current_retry = 0;
   string side = (deal_type == DEAL_TYPE_BUY) ? "BUY" : "SELL";
   if(DEBUG_MODE)
      Print("[ALX EXECUTION CONFIRMED] ", side,
         " | Ticket=", deal_ticket,
         " | Order=", deal_order,
         " | Volume=", DoubleToString(exec_volume, 2),
         " | Price=", DoubleToString(exec_price, _Digits),
         " | Slippage=", DoubleToString(slippage, 1), " pts",
         " | Latency=", DoubleToString(latency, 0), " ms");
   SaveQualityToFile();
   ResetContext();
}
//+------------------------------------------------------------------+
//| TIMEOUT & STATE UPDATE                                           |
//+------------------------------------------------------------------+
void CExecution::Update()
{
   UpdateSpreadStats();
   
   // Salva quality em arquivo a cada 30 segundos
   static uint lastSaveTime = 0;
   if(GetTickCount() - lastSaveTime > 30000)
   {
      lastSaveTime = GetTickCount();
      if(m_total_requests > 0)
         SaveQualityToFile();
   }
   
   // v7.64: Async retry (nao-bloqueante)
   if(m_pending_retry && GetTickCount() >= m_retry_after_time)
   {
      m_pending_retry = false;
      if(DEBUG_MODE) Print("[ALX RETRY] Executando ordem agendada...");
      Execute(m_retry_type, m_retry_volume, m_retry_target_price, m_retry_sl, m_retry_tp, m_retry_comment);
   }
   if(m_state == STATE_WAITING)
   {
      double elapsed_ms = (double)(GetTickCount() - m_request_time);
      if(elapsed_ms > m_timeout_ms)
      {
         m_state = STATE_TIMEOUT;
         m_timeout_count++;
         m_is_busy = false;
         if(DEBUG_MODE)
            Print("[ALX ERROR] Execution Timeout! Order: ", m_request_order);
         ResetContext();
      }
   }
}
//+------------------------------------------------------------------+
//| Calculate - Position Sizing Engine (consolidated) - v7.61        |
//+------------------------------------------------------------------+
TradeParams CExecution::Calculate(string symbol, double sl_points)
{
   TradeParams result;
   ZeroMemory(result);
   //--- v7.61: Sincroniza o símbolo interno (multi-asset safe)
   if(m_symbol.Name() != symbol)
   {
      if(!m_symbol.Name(symbol))
      {
         if(DEBUG_MODE) Print("[EXEC] Calculate: falha ao setar symbol ", symbol);
         return result;
      }
   }
   if(!m_symbol.RefreshRates()) return result;
   //--- Step 1: Determine SL distance(s) ---
   double sl_long = 0;
   double sl_short = 0;
   double sl_dist = 0;
   if(m_sl_mode == SL_ATR)
   {
      double support = 0, resistance = 0;
      if(ComputeStopATRBands(m_symbol.Name(), PERIOD_CURRENT, STOPATR_ATR_PERIOD, STOPATR_LOOKBACK, m_sl_value, support, resistance))
      {
         double ask = m_symbol.Ask();
         double bid = m_symbol.Bid();
         if(support > 0 && ask > support) sl_long = ask - support;
         if(resistance > 0 && resistance > bid) sl_short = resistance - bid;
      }
if(sl_long <= 0 && sl_short <= 0)
          sl_dist = (CheckPointer(m_regime) != POINTER_INVALID ? m_regime.CustomATR(m_symbol.Name(), PERIOD_CURRENT, 14, 1) : 0) * m_sl_value;
      else
         sl_dist = MathMax(sl_long, sl_short);
   }
   else if(sl_points > 0)
      sl_dist = sl_points;
   else
      sl_dist = PipToPrice(m_sl_value);
   if(sl_dist <= 0)
   {
      if(DEBUG_MODE) Print("[EXEC] Calculate: sl_dist <= 0 para ", symbol);
      return result;
   }
   //--- Clamp mínimo de SL (dinâmico e multi-asset)
   double broker_stop_level = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(symbol, SYMBOL_POINT);
   double min_sl = MathMax(broker_stop_level * 1.5, m_symbol.Point() * 10); // proteção mínima de 10 points
   if(sl_dist < min_sl)
   {
      if(DEBUG_MODE) Print("[EXEC] SL clamped: ", sl_dist, " -> ", min_sl, " (", symbol, ")");
      sl_dist = min_sl;
   }
   // resolve per-side distances with broker min clamp
   if(sl_long > 0 && sl_long < min_sl) sl_long = min_sl;
   if(sl_short > 0 && sl_short < min_sl) sl_short = min_sl;
   if(sl_long <= 0)  sl_long  = sl_dist;
   if(sl_short <= 0) sl_short = sl_dist;
   //--- Step 2: Calculate TP ---
   double tp_dist = 0;
   double tp_long = 0;
   double tp_short = 0;
   if(m_tp_mode == TP_RISK_REWARD)
   {
      tp_dist  = sl_dist  * m_tp_value;
      tp_long  = sl_long  * m_tp_value;
      tp_short = sl_short * m_tp_value;
   }
   else if(m_tp_mode == TP_FIXED)
   {
      tp_dist  = PipToPrice(m_tp_value);
      tp_long  = tp_short = tp_dist;
   }
   else if(m_tp_mode == TP_ADR)
   {
      tp_dist  = CalcADR(m_adr_days) * m_tp_value;
      tp_long  = tp_short = tp_dist;
   }
   //--- Step 3: Breakeven distance ---
   double be_dist = 0;
if(m_be_mode == BE_ATR)
       be_dist = (CheckPointer(m_regime) != POINTER_INVALID ? m_regime.CustomATR(m_symbol.Name(), PERIOD_CURRENT, 14, 1) : 0) * m_be_value;
   else
      be_dist = PipToPrice(m_be_value);
   //--- Step 4: Trailing distances ---
   double trail_dist = 0;
   double trail_step = 0;
   if(m_trail_mode == TRAIL_ATR)
   {
      double kv = TrailATRMultiplier();
      double support = 0, resistance = 0;
      if(ComputeStopATRBands(m_symbol.Name(), PERIOD_CURRENT, STOPATR_ATR_PERIOD, STOPATR_LOOKBACK, kv, support, resistance))
      {
         double ask = m_symbol.Ask();
         double bid = m_symbol.Bid();
         if(support > 0 && ask > support) trail_dist = ask - support;
         if(resistance > 0 && resistance > bid) trail_dist = MathMax(trail_dist, resistance - bid);
      }
if(trail_dist <= 0)
          trail_dist = (CheckPointer(m_regime) != POINTER_INVALID ? m_regime.CustomATR(m_symbol.Name(), PERIOD_CURRENT, 14, 1) : 0) * kv;
      trail_step = PipToPrice(m_trail_step);
   }
   else
   {
      trail_dist = PipToPrice(m_trail_distance);
      trail_step = PipToPrice(m_trail_step);
   }
   //--- Step 5: Calculate lot ---
   double lot_raw = 0;
   double risk_usd = 0;
   double risk_per_lot = 0.0; // v7.64: escopo movido p/ fora do switch (era declarado dentro do case lot_risk)
   switch(m_lot_mode)
   {
      case lot_min:
         lot_raw = SymbolInfoDouble(m_symbol.Name(), SYMBOL_VOLUME_MIN);
         if(lot_raw <= 0) return result;
         break;
  
      case lot_fixed:
         lot_raw = m_lot_value;
         if(lot_raw <= 0) return result;
         break;
      case lot_balance:
         lot_raw = (m_account.Balance() / BALANCE_UNIT) * m_lot_value;
         if(lot_raw <= 0) return result;
         break;
      case lot_risk:
      {
         // v7.61 - Institutional: OrderCalcProfit based risk
         double risk_money = m_account.Equity() * (m_lot_value / 100.0);
         risk_per_lot = GetRiskPerLot(symbol, sl_dist);
         if(risk_per_lot > 0.0)
            lot_raw = risk_money / risk_per_lot;
         else
         {
            // Fallback clássico (caso OrderCalcProfit falhe)
            double tick_val  = m_symbol.TickValue();
            double tick_size = m_symbol.TickSize();
            if(tick_size > 0 && tick_val > 0)
            {
               double risk_per_lot_fb = (sl_dist / tick_size) * tick_val;
               if(risk_per_lot_fb > 0)
                  lot_raw = risk_money / risk_per_lot_fb;
            }
         }
         if(lot_raw <= 0)
         {
            if(DEBUG_MODE) Print("[EXEC] lot_risk: lot_raw <= 0 (risk_per_lot=", risk_per_lot, ")");
            return result;
         }
         break;
      }
   }
   //--- Step 6: Normalize lot (agora recebe sl_dist para risk_usd correto)
   result.lot = NormalizeLot(lot_raw, symbol, sl_dist, risk_per_lot, risk_usd);
   if(result.lot <= 0) return result;
   //--- Step 7: Output ---
   result.sl             = sl_dist;
   result.sl_long        = sl_long;
   result.sl_short       = sl_short;
   result.tp             = tp_dist;
   result.tp_long        = tp_long;
   result.tp_short       = tp_short;
   result.be_distance    = be_dist;
   result.trail_distance = trail_dist;
   result.trail_step     = trail_step;
   result.risk_usd       = risk_usd;
   result.risk_pct_used  = m_lot_value;
   if(DEBUG_MODE)
   {
      Print("[EXEC] Calculate OK | ", symbol,
            " | Lot=", DoubleToString(result.lot, 2),
            " | SL=", DoubleToString(sl_dist, m_symbol.Digits()),
            " | RiskUSD=", DoubleToString(risk_usd, 2),
            " | Mode=", EnumToString(m_lot_mode));
   }
   return result;
}
//+------------------------------------------------------------------+
//| GetRiskPerLot - Institutional (OrderCalcProfit) - v7.61          |
//+------------------------------------------------------------------+
double CExecution::GetRiskPerLot(string symbol, double sl_dist)
{
   if(sl_dist <= 0) return 0.0;
   double price = m_symbol.Ask();
   if(price <= 0) return 0.0;
   double profit = 0.0;
   // Simula perda de 1 lote com SL na distância fornecida (BUY)
   if(!OrderCalcProfit(ORDER_TYPE_BUY, symbol, 1.0, price, price - sl_dist, profit))
   {
      // Fallback: tenta com SELL
      if(!OrderCalcProfit(ORDER_TYPE_SELL, symbol, 1.0, price, price + sl_dist, profit))
         return 0.0;
   }
   return MathAbs(profit);
}
//+------------------------------------------------------------------+
//| ComputeStopATRBands - banda StopATR (referencia ATRStops_v1)     |
//+------------------------------------------------------------------+
bool CExecution::ComputeStopATRBands(string symbol, ENUM_TIMEFRAMES period, int atr_period,
                                     int length, double kv, double &support, double &resistance)
{
   support = 0;
   resistance = 0;
   if(length <= 0 || atr_period <= 0 || kv <= 0) return false;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, period, 0, length + atr_period, rates);
   if(copied <= 0) return false;
   for(int i = 0; i < length; i++)
   {
      double sum_tr = 0.0;
      int n = 0;
      for(int j = 0; j < atr_period; j++)
      {
         int a = i + j;
         int b = a + 1;
         if(b >= copied) break;
         double h  = rates[a].high;
         double l  = rates[a].low;
         double cp = rates[b].close;
         if(h <= 0 || l <= 0 || cp <= 0) continue;
         double tr = MathMax(h - l, MathMax(MathAbs(h - cp), MathAbs(l - cp)));
         sum_tr += tr;
         n++;
      }
      double atr = (n > 0) ? sum_tr / (double)n : 0.0;
      if(atr <= 0) continue;
      double s = rates[i].high - kv * atr;
      double r = rates[i].low  + kv * atr;
      if(support <= 0 && resistance <= 0)
      {
         support = s;
         resistance = r;
      }
      else
      {
         support    = MathMax(support, s);
         resistance = MathMin(resistance, r);
      }
   }
   // v7.63: Validação de sanidade - support < resistance
   if(support > 0 && resistance > 0 && support >= resistance)
   {
      if(DEBUG_MODE)
         Print("[EXEC] ComputeStopATRBands: banda invertida/corrompida (support=", support,
               " resistance=", resistance, ", symbol=", symbol, ")");
      support = 0;
      resistance = 0;
      return false;
   }
   return (support > 0 && resistance > 0);
}
//+------------------------------------------------------------------+
//| ComputeTrailBands - banda StopATR p/ trailing (modo TRAIL_ATR)   |
//+------------------------------------------------------------------+
bool CExecution::ComputeTrailBands(double &support, double &resistance)
{
   return ComputeStopATRBands(m_symbol.Name(), PERIOD_CURRENT, STOPATR_ATR_PERIOD, STOPATR_LOOKBACK, TrailATRMultiplier(), support, resistance);
}
//+------------------------------------------------------------------+
//| TrailATRMultiplier - mult efetivo da banda no modo ATR           |
//+------------------------------------------------------------------+
double CExecution::TrailATRMultiplier()
{
   if(m_trail_distance > 0) return m_trail_distance;
   if(!m_trail_warned)
   {
      m_trail_warned = true;
      Print("[EXEC] WARNING: InpTrailDistance=", m_trail_distance,
            " no modo TRAIL_ATR (mult da banda) => usando fallback 1.0. Configure distance > 0 para a banda StopATR.");
   }
   return 1.0;
}
//+------------------------------------------------------------------+
//| PipToPrice - Robust multi-instrument (v7.61)                     |
//+------------------------------------------------------------------+
double CExecution::PipToPrice(double pips)
{
   if(pips <= 0) return 0.0;
   double point  = m_symbol.Point();
   int    digits = (int)m_symbol.Digits();
   // Forex clássico 3/5 dígitos e pares de 2 dígitos (JPY em alguns brokers)
   if(digits == 3 || digits == 5 || digits == 2)
      return pips * point * 10.0;
   // XAUUSD, BTCUSD, OIL, Stocks, Índices → 1 pip = 1 point (mais seguro e previsível)
   return pips * point;
}
//+------------------------------------------------------------------+
//| CalcADR                                                          |
//+------------------------------------------------------------------+
double CExecution::CalcADR(int days)
{
   double sum = 0;
   int count = 0;
   for(int i = 1; i <= days; i++)
   {
      double high = iHigh(m_symbol.Name(), PERIOD_D1, i);
      double low  = iLow(m_symbol.Name(), PERIOD_D1, i);
      if(high > 0 && low > 0)
      {
         sum += (high - low);
         count++;
      }
   }
   return (count > 0) ? sum / count : 0;
}
//+------------------------------------------------------------------+
//| NormalizeLot - v7.61 (risk_usd real + leverage inteligente)      |
//+------------------------------------------------------------------+
double CExecution::NormalizeLot(double raw_lot, string symbol, double sl_dist, double risk_per_lot_hint, double &risk_usd_out)
{
    if(!m_symbol.RefreshRates()) return 0.0;
    double lot = raw_lot;
   //--- Limitação por alavancagem / notional (mais conservadora e configurável)
   if(m_account.Equity() > 0.0)
   {
      double contract_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      double price         = m_symbol.Ask();
      long   leverage      = AccountInfoInteger(ACCOUNT_LEVERAGE);
      if(contract_size > 0.0 && price > 0.0 && leverage > 0)
      {
         // Usa no máximo 25% da margem teórica disponível (fator 4)
         // Pode ser ajustado para 2 ou 3 se quiser mais agressivo
         double max_notional = m_account.Equity() * ((double)leverage / 4.0);
         // v7.62: notional na MOEDA DA CONTA. contract_size*price so era valido
         // quando a cotacao == moeda da conta; em pares JPY (ex.: GBPJPY, conta USD)
         // o nocional ficava ~150x inflado e o clamp de alavancagem pinava o lote
         // no minimo independente do InpLotValue.
         double tick_val  = m_symbol.TickValue();
         double tick_size = m_symbol.TickSize();
         double notional_per_lot = (tick_size > 0 && tick_val > 0)
                                   ? (price / tick_size) * tick_val
                                   : contract_size * price;
         if(notional_per_lot > 0)
         {
            double max_lot_by_leverage = max_notional / notional_per_lot;
            lot = MathMin(lot, max_lot_by_leverage);
         }
      }
   }
   //--- Normalização de step / min / max
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathFloor(lot / step) * step;
   lot = MathMax(lot, SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN));
   lot = MathMin(lot, SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX));
   lot = NormalizeDouble(lot, 8); // precisão alta para depois o LotCheck ajustar
   //--- Risk USD real (usando hint se fornecido; senão recalcula)
   risk_usd_out = 0.0;
   if(lot > 0 && sl_dist > 0)
   {
      double risk_per_lot = (risk_per_lot_hint > 0) ? risk_per_lot_hint : GetRiskPerLot(symbol, sl_dist);
      if(risk_per_lot > 0)
         risk_usd_out = lot * risk_per_lot;
      else
      {
         // Fallback clássico
         double tick_val  = m_symbol.TickValue();
         double tick_size = m_symbol.TickSize();
         if(tick_size > 0 && tick_val > 0)
            risk_usd_out = lot * (sl_dist / tick_size) * tick_val;
      }
   }
   return lot;
}
//+------------------------------------------------------------------+
//| RETCODE PARSER                                                   |
//+------------------------------------------------------------------+
ENUM_ALX_EXEC_RESULT CExecution::ParseRetcode(uint retcode)
{
   switch(retcode)
   {
      case 10009: return RESULT_SUCCESS;
      case 10010: return RESULT_SUCCESS;
      case 10011: return RESULT_REQUOTE;
      case 10012: return RESULT_PRICE_CHANGED;
      case 10013: return RESULT_REJECTED;
      case 10014: return RESULT_INVALID_STOPS;
      case 10015: return RESULT_INVALID_VOLUME;
      case 10018: return RESULT_MARKET_CLOSED;
      case 10019: return RESULT_NO_MONEY;
      case 10020: return RESULT_SLIPPAGE_EXCEED;
      case 10021: return RESULT_TRADE_DISABLED;
      case 10025: return RESULT_OFF_QUOTES;
      case 10026: return RESULT_BROKER_BUSY;
      default:    return RESULT_UNKNOWN;
   }
}
//+------------------------------------------------------------------+
//| BROKER QUALITY SCORE                                             |
//+------------------------------------------------------------------+
double CExecution::GetBrokerScore()
{
   if(m_total_requests <= 0) return 100.0;
   double success_score  = GetSuccessRate();
   double latency_score  = MathMax(0, 100.0 - (GetAverageLatency() / 100.0));
   double slippage_score = MathMax(0, 100.0 - (GetAverageSlippage() * 5.0));
  
   double reject_rate = (m_total_requests > 0) ? (double)m_reject_count / m_total_requests * 100.0 : 0;
   reject_rate = MathMin(reject_rate, 100.0);
   double reject_score = MathMax(0, 100.0 - (reject_rate * 0.2));
   return NormalizeDouble((success_score * 0.40 + latency_score * 0.20 + slippage_score * 0.25 + reject_score * 0.15), 1);
}
bool CExecution::IsBrokerToxic()
{
   if(m_total_requests <= 0) return false;
   if(GetAverageSlippage() > 2.0) return true;
   if(GetAverageLatency() > 1000) return true;
   if(GetSuccessRate() < 85) return true;
   if(GetAverageSpread() > 0 && (m_symbol.Spread() / _Point) > (GetAverageSpread() * 5.0)) return true;
   return false;
}
void CExecution::UpdateSpreadStats()
{
   double spread = (m_symbol.Ask() - m_symbol.Bid()) / _Point;
   m_spread_total += spread;
   if(spread > m_spread_max) m_spread_max = spread;
   m_spread_samples++;
}
double CExecution::GetAverageSpread()
{
   if(m_spread_samples <= 0) return 0;
   return m_spread_total / m_spread_samples;
}
void CExecution::CreatePanelBackground(string name, int x, int y, int w, int h, color bg)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrBlack);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }
}
string CExecution::StateToString()
{
   switch(m_state)
   {
      case STATE_IDLE:      return "IDLE";
      case STATE_SENDING:   return "SENDING";
      case STATE_WAITING:   return "WAITING";
      case STATE_CONFIRMED: return "CONFIRMED";
      case STATE_PARTIAL:   return "PARTIAL";
      case STATE_REJECTED:  return "REJECTED";
      case STATE_TIMEOUT:   return "TIMEOUT";
      case STATE_FAILED:    return "FAILED";
      default:              return "UNKNOWN";
   }
}
//+------------------------------------------------------------------+
//| LotCheck                                                         |
//+------------------------------------------------------------------+
double CExecution::LotCheck(double lot, string symbol)
{
   if(symbol == "") symbol = _Symbol;
   if(lot <= 0) return 0.0;
  
   double min_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  
   if(lot_step <= 0) lot_step = 0.01;
   if(min_lot <= 0)  min_lot  = 0.01;
  
   lot = MathFloor(lot / lot_step) * lot_step;
   if(lot > max_lot) lot = max_lot;
   if(lot < min_lot) lot = min_lot;
  
   return NormalizeDouble(lot, 8);
}
//+------------------------------------------------------------------+
//| ClosePartial - CORRIGIDO (v7.61)                                 |
//+------------------------------------------------------------------+
bool CExecution::ClosePartial(ulong ticket, double volume_to_close)
{
   if(!PositionSelectByTicket(ticket))
   {
      if(DEBUG_MODE)
         Print("[ALX ERROR] ClosePartial: Posição não encontrada. Ticket: ", ticket);
      return false;
   }
  
   double current_vol = PositionGetDouble(POSITION_VOLUME);
   string symbol      = PositionGetString(POSITION_SYMBOL);
   double min_vol     = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double step_vol    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  
   if(step_vol <= 0) step_vol = min_vol;
   volume_to_close = MathFloor(volume_to_close / step_vol) * step_vol;
  
   if(volume_to_close < min_vol && volume_to_close < current_vol)
   {
      if(DEBUG_MODE)
         Print("[ALX ERROR] ClosePartial: Volume a fechar é menor que o mínimo do broker.");
      return false;
   }
  
   double remaining_vol = NormalizeDouble(current_vol - volume_to_close, 8);
  
   if(remaining_vol > 0 && remaining_vol < min_vol)
   {
      volume_to_close = current_vol; // fecha tudo para não deixar resto inválido
   }
  
   if(volume_to_close >= current_vol)
      return m_trade.PositionClose(ticket);
  
   // Close parcial correto: PositionClosePartial(ticket, volume)
   // (PositionClose(ticket, volume) tratava o volume como deviation - ulong)
   if(!m_trade.PositionClosePartial(ticket, volume_to_close))
   {
      if(DEBUG_MODE)
         Print("[ALX ERROR] ClosePartial Falhou. Err: ", m_trade.ResultRetcodeDescription());
      return false;
   }
  
   uint retcode = m_trade.ResultRetcode();
   return (retcode == 10009 || retcode == 10008);
}
//+------------------------------------------------------------------+
//| Close profit positions                                           |
//+------------------------------------------------------------------+
void CExecution::CloseProfitPositions(ulong magic)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(m_position.SelectByIndex(i))
         if(m_position.Symbol() == m_symbol.Name() && m_position.Magic() == magic)
            if(m_position.Commission() + m_position.Swap() + m_position.Profit() > 0.0)
               m_trade.PositionClose(m_position.Ticket());
}
//+------------------------------------------------------------------+
//| GetQualityJson - exporta metricas de qualidade como JSON          |
//+------------------------------------------------------------------+
string CExecution::GetQualityJson()
{
   string json = "{";
   json += "\"avg_spread\":" + DoubleToString(GetAverageSpread(), 2);
   json += ",\"max_spread\":" + DoubleToString(m_spread_max, 2);
   json += ",\"avg_slippage\":" + DoubleToString(GetAverageSlippage(), 2);
   json += ",\"max_slippage\":" + DoubleToString(GetMaxSlippage(), 2);
   json += ",\"avg_latency_ms\":" + DoubleToString(GetAverageLatency(), 0);
   json += ",\"max_latency_ms\":" + DoubleToString(GetMaxLatency(), 0);
   json += ",\"success_rate\":" + DoubleToString(GetSuccessRate(), 2);
   json += ",\"total_requests\":" + IntegerToString(GetTotalRequests());
   json += ",\"success_count\":" + IntegerToString(GetSucessCount());
   json += ",\"reject_count\":" + IntegerToString(GetRejectCount());
   json += ",\"requote_count\":" + IntegerToString(GetRequoteCount());
   json += ",\"timeout_count\":" + IntegerToString(GetTimeoutCount());
   json += ",\"broker_score\":" + DoubleToString(GetBrokerScore(), 1);
   json += ",\"is_toxic\":" + (IsBrokerToxic() ? "true" : "false");
   json += "}";
   return json;
}
//+------------------------------------------------------------------+
//| SaveQualityToFile - salva quality em JSON p/ ALXAccountManager    |
//+------------------------------------------------------------------+
void CExecution::SaveQualityToFile()
{
   string filename = "quality_" + IntegerToString(m_magic) + "_" + _Symbol + ".json";
   int handle = FileOpen("mql5\\" + filename, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(handle != INVALID_HANDLE)
   {
      FileWriteString(handle, GetQualityJson());
      FileClose(handle);
   }
}
//+------------------------------------------------------------------+