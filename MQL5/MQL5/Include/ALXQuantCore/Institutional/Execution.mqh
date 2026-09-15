//+------------------------------------------------------------------+
//| Execution.mqh                                                    |
//| ALXQuantCore - Pure Order Execution Engine                       |
//| v11.0.0 |
//+------------------------------------------------------------------+
#property version "11.0"

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
    v.7.61 - 2026-08-20 - Institutional fixes: lot sizing multi-asset (OrderCalcProfit), PipToPrice robusto,
                         Calculate() sincroniza m_symbol, NormalizeLot com risk_usd real, ClosePartial correto, clamp de SL.
    v.7.62 - 2026-08-20 - Fix: NormalizeLot notional_per_lot na moeda da conta; Fix: ClosePartial usava assinatura errada.
    v.7.63 - 2026-08-20 - Fix: aceita retcode 10008 (Pending) para ordens Limit/Stop além do 10009 (Done).
    v.7.64 - 2026-08-24 - Fix: NormalizeLot escopo de risk_per_lot; ordem dos argumentos corrigida.
    v.10.1.0 - 2026-09-06 - AUDIT FIXES:
                         - CRÍTICO: retry assíncrono era auto-deadlock (Execute() bloqueava a si mesmo
                           via m_is_busy). Corrigido com parametro interno internal_retry.
                         - CRÍTICO: _Point/_Symbol globais trocados por m_symbol.Point()/m_symbol.Name()
                           em ProcessTradeTransaction, IsBrokerToxic, UpdateSpreadStats, SaveQualityToFile.
                         - Fix: m_requote_count nunca incrementava. Fix: reject_rate contaminado por
                           rejeicoes locais (separado em m_local_reject_count). Fix: wraparound de
                           GetTickCount() na comparacao do retry.
                         - Add: ping real (TERMINAL_PING_LAST), slippage com sinal, stddev de spread,
                           contador de desconexao, SetDeviationPoints(), validacao de stops/freeze no Modify().
    v.11.0.0 - 2026-09-06 - REFATORACAO: separacao de responsabilidades. Esta classe agora cuida
                         SOMENTE de execucao de ordem (envio, retry, state machine, validacoes de
                         volume/margem) e qualidade de broker (spread/slippage/latencia/ping/score).
                         REMOVIDO por completo (deve virar modulo(s) separado(s) que calculam os
                         valores finais de sl/tp/lote e os passam prontos para Buy()/Sell()/Execute()):
                           - Calculate() e struct TradeParams (motor de position sizing)
                           - Toda logica de Stop Loss (SL_ATR/SL_FIXED, ComputeStopATRBands, SetSLMode/SetSLValue)
                           - Toda logica de Take Profit (TP_RISK_REWARD/TP_FIXED/TP_ADR, CalcADR, SetTPMode/SetTPValue/SetADRPeriod)
                           - Toda logica de Trailing Stop (TRAIL_ATR/TRAIL_FIXED, ComputeTrailBands, TrailATRMultiplier, SetTrailMode/SetTrailDistance/SetTrailStep)
                           - Toda logica de Breakeven (BE_ATR/BE_FIXED, SetBEMode/SetBEValue)
                           - Todo calculo de lote (enLotMode, NormalizeLot, GetRiskPerLot, SetLotMode/SetLotValue)
                           - PipToPrice() (so existia para converter pips->preco nos modulos acima)
                         BREAKING CHANGE: Init() nao recebe mais CMacroRegimeEngine* (so era usado
                         pelos calculos de ATR de SL/BE/Trail, que nao existem mais aqui). Remova o
                         5o argumento nas chamadas existentes. O #include de MacroRegimeEngine.mqh
                         tambem foi removido deste arquivo.
                         Mantido de proposito: LotCheck() - isso NAO decide quanto arriscar, apenas
                         arredonda/clampa um volume ja definido ao step/min/max do simbolo, exigencia
                         minima para qualquer ordem ser aceita pelo broker. Se preferir que Execute()
                         apenas rejeite volumes fora do padrao em vez de ajustar, avise para remover.
*/
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
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
//+------------------------------------------------------------------+
//| MAIN CLASS                                                       |
//| Pure Order Execution Engine                                      |
//+------------------------------------------------------------------+
class CExecution
{
private:
   //--- Gates de execucao (nao sao "estrategia", sao protecao de execucao) ---
   double             m_max_spread_points;   // 0 = desligado; > 0 = gate
   bool               m_block_if_toxic;      // false por default; true = bloqueia se IsBrokerToxic()
   int                m_deviation_points;    // deviation/slippage tolerance configurable
   //--- Analytics de Spread ---
   double             m_spread_total;
   double             m_spread_sumsq;
   double             m_spread_max;
   long               m_spread_samples;
   double             m_hourly_slippage[24];
   long               m_hourly_count[24];
   bool               m_broker_toxic;
   // --- Ping / conectividade ---
   long               m_ping_last;
   double             m_ping_sum;
   long               m_ping_samples;
   long               m_ping_max;
   bool               m_was_connected;
   long               m_disconnect_count;
   // --- Slippage com sinal ---
   double             m_signed_slippage_total; // >0 = adverso (custo), <0 = favoravel
   long               m_favorable_slippage_count;
   long               m_adverse_slippage_count;
   // --- State Machine & Context ---
   ENUM_ALX_EXEC_STATE m_state;
   ulong              m_request_order;
   uint               m_request_time;
   double             m_request_price;
   int                m_current_retry;
   bool               m_is_busy;
   // --- Async retry state ---
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
   long               m_reject_count;       // rejeicoes de ORIGEM BROKER (retcode) - usado no score
   long               m_local_reject_count; // rejeicoes LOCAIS (spread/toxic/volume/margem) - fora do score
   long               m_requote_count;
   long               m_timeout_count;
   double             m_total_slippage;
   double             m_max_slippage;
   double             m_total_latency_ms;
   double             m_max_latency_ms;
   // --- Internal Methods ---
   ENUM_ALX_EXEC_RESULT ParseRetcode(uint retcode);
   void                 ResetContext();
   void                 SamplePingAndConnection();
public:
                        CExecution(void);
   bool                 Init(string symbol, ulong magic, int max_retries, int retry_delay, int timeout);
   // --- Setters (gates de execucao) ---
   void SetMaxSpreadPoints(double v)             { m_max_spread_points = v; }
   void SetBlockIfToxic(bool flag)               { m_block_if_toxic = flag; }
   void SetDeviationPoints(int pts)              { m_deviation_points = MathMax(0, pts); m_trade.SetDeviationInPoints(m_deviation_points); }
   // --- Execution Core ---
   double               LotCheck(double lot, string symbol = ""); // normalizacao de broker (step/min/max), NAO eh sizing
   bool                 Execute(ENUM_ORDER_TYPE type, double volume, double sl, double tp, string comment = "");
   bool                 Execute(ENUM_ORDER_TYPE type, double volume, double target_price, double sl, double tp, string comment = "", bool internal_retry = false);
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
   void                 ResetState() { m_state = STATE_IDLE; m_is_busy = false; m_current_retry = 0; m_pending_retry = false; }
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
   double               GetSpreadStdDev();
   bool                 IsBrokerToxic();
   string               StateToString();
   void                 UpdateSpreadStats();
   void                 CreatePanelBackground(string name, int x, int y, int w, int h, color bg);
   long                 GetTotalRequests()   { return m_total_requests; }
   long                 GetSucessCount()     { return m_success_count; } // mantido exatamente como está (compatibilidade)
   long                 GetRejectCount()     { return m_reject_count; }       // origem broker
   long                 GetLocalRejectCount(){ return m_local_reject_count; } // origem local
   double               GetMaxSlippage()     { return m_max_slippage; }
   double               GetMaxLatency()      { return m_max_latency_ms; }
   long                 GetRequoteCount()    { return m_requote_count; }
   long                 GetTimeoutCount()    { return m_timeout_count; }
   long                 GetPingLast()        { return m_ping_last; }
   double               GetAveragePing()     { return (m_ping_samples > 0) ? m_ping_sum / m_ping_samples : 0; }
   long                 GetMaxPing()         { return m_ping_max; }
   long                 GetDisconnectCount() { return m_disconnect_count; }
   double               GetSignedSlippageAvg(){ long n = m_favorable_slippage_count + m_adverse_slippage_count; return (n > 0) ? m_signed_slippage_total / n : 0; }
   long                 GetFavorableSlippageCount() { return m_favorable_slippage_count; }
   long                 GetAdverseSlippageCount()   { return m_adverse_slippage_count; }
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
   m_spread_sumsq   = 0;
   m_spread_max     = 0;
   m_spread_samples = 0;
   m_broker_toxic   = false;
   m_max_spread_points = 0.0;
   m_block_if_toxic = false;
   m_deviation_points = 10;
   m_local_reject_count = 0;
   m_ping_last      = -1;
   m_ping_sum       = 0;
   m_ping_samples   = 0;
   m_ping_max       = 0;
   m_was_connected  = true;
   m_disconnect_count = 0;
   m_signed_slippage_total = 0;
   m_favorable_slippage_count = 0;
   m_adverse_slippage_count = 0;
   m_pending_retry  = false;
   m_retry_after_time = 0;
   m_retry_type     = ORDER_TYPE_BUY;
   m_retry_volume   = 0;
   m_retry_target_price = 0;
   m_retry_sl       = 0;
   m_retry_tp       = 0;
   ArrayInitialize(m_hourly_slippage, 0);
   ArrayInitialize(m_hourly_count, 0);
}
//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
bool CExecution::Init(string symbol, ulong magic, int max_retries, int retry_delay, int timeout)
{
   if(!m_symbol.Name(symbol)) return false;
   if(!m_symbol.RefreshRates()) return false;
   m_magic           = magic;
   m_max_retries     = max_retries;
   m_retry_delay_ms  = retry_delay;
   m_timeout_ms      = timeout;
  
   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(symbol);
   m_trade.SetDeviationInPoints(m_deviation_points);
   m_was_connected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
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
//| internal_retry: usado APENAS pelo motor (via Update()->retry     |
//| agendado) para reenviar mesmo com m_is_busy=true. Chamadas       |
//| externas continuam bloqueadas normalmente por m_is_busy.         |
//+------------------------------------------------------------------+
bool CExecution::Execute(ENUM_ORDER_TYPE type, double volume, double target_price, double sl, double tp, string comment, bool internal_retry)
{
    if(m_is_busy && !internal_retry) return false;
    if(!m_symbol.RefreshRates()) return false;

    // gate de spread (se configurado)
    if(m_max_spread_points > 0)
    {
       double current_spread_pts = (m_symbol.Ask() - m_symbol.Bid()) / m_symbol.Point();
       if(current_spread_pts > m_max_spread_points)
       {
          if(DEBUG_MODE) Print("[ALX ERROR] Spread acima do limite: ", current_spread_pts, " > ", m_max_spread_points);
          m_local_reject_count++;
          if(!internal_retry) { m_is_busy = false; }
          return false;
       }
    }

    // gate de toxicidade (opcional, opt-in)
    if(m_block_if_toxic && IsBrokerToxic())
    {
       if(DEBUG_MODE) Print("[ALX ERROR] Broker toxic detectado. Ordem recusada.");
       m_local_reject_count++;
       if(!internal_retry) { m_is_busy = false; }
       return false;
    }

   volume = LotCheck(volume, m_symbol.Name());
     
   if(!ValidateVolume(volume))
   {
      if(DEBUG_MODE)
         Print("[ALXC ERROR] Invalid Volume: ", volume);
      m_local_reject_count++;
      if(!internal_retry) { m_is_busy = false; }
      return false;
   }
   if(!ValidateMargin(type, volume, target_price))
   {
      if(DEBUG_MODE)
         Print("[ALX ERROR] No Money for Volume: ", volume);
      m_local_reject_count++;
      if(!internal_retry) { m_is_busy = false; }
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
   // aceita 10008 (Pending) para ordens Limit/Stop além do 10009 (Done)
   bool is_pending = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT ||
                       type == ORDER_TYPE_BUY_STOP  || type == ORDER_TYPE_SELL_STOP);
   if(send_result && ((retcode == 10009) || (is_pending && retcode == 10008)))
   {
      // ordens pendentes aceitas nao ficam presas em STATE_WAITING/timeout -
      // sao consideradas "colocadas com sucesso" imediatamente; o fill (se ocorrer)
      // ainda gera evento via ProcessTradeTransaction, mas nao trava m_is_busy ate la.
      if(is_pending && retcode == 10008)
      {
         m_state          = STATE_CONFIRMED;
         m_request_order  = m_trade.ResultOrder();
         m_total_requests++;
         m_success_count++;
         m_is_busy        = false;
         m_current_retry  = 0;
         if(DEBUG_MODE)
            Print("[EXEC] Pending Order Placed. Ticket: ", m_request_order, " Type: ", EnumToString(type),
                  " Price: ", target_price, " SL: ", sl, " TP: ", tp);
         return true;
      }
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
      if(result == RESULT_REQUOTE) m_requote_count++;
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
   return Execute(type, volume, 0.0, sl, tp, comment, false);
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
//+------------------------------------------------------------------+
//| Modify - valida stops/freeze level antes de enviar               |
//| (isso eh checagem de restricao de execucao, nao "logica de SL")  |
//| Os valores de sl/tp sao dados por quem chama, esta classe so     |
//| garante que a distancia minima do broker seja respeitada.        |
//+------------------------------------------------------------------+
bool CExecution::Modify(ulong ticket, double sl, double tp)
{
   if(!PositionSelectByTicket(ticket))
   {
      if(DEBUG_MODE) Print("[ALX ERROR] Modify: posição não encontrada. Ticket: ", ticket);
      return false;
   }
   string symbol = PositionGetString(POSITION_SYMBOL);
   double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double stops_level  = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double freeze_level = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL) * point;
   double min_dist = MathMax(stops_level, freeze_level);
   if(min_dist > 0)
   {
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      bool is_buy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double ref_price = is_buy ? bid : ask;
      if((sl > 0 && MathAbs(ref_price - sl) < min_dist) ||
         (tp > 0 && MathAbs(tp - ref_price) < min_dist))
      {
         if(DEBUG_MODE)
            Print("[ALX ERROR] Modify: SL/TP muito próximo do preço (min_dist=", min_dist,
                  "). Ticket: ", ticket, " SL: ", sl, " TP: ", tp);
         return false;
      }
   }
   bool ok = m_trade.PositionModify(ticket, sl, tp);
   if(!ok && DEBUG_MODE)
      Print("[ALX ERROR] Modify falhou. Ticket: ", ticket, " Err: ", m_trade.ResultRetcodeDescription());
   return ok;
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
   // usa o point do SIMBOLO DA INSTANCIA (m_symbol), nao _Point global do grafico
   double point = m_symbol.Point();
   double slippage = MathAbs(exec_price - m_request_price) / point;
   double latency  = (double)(GetTickCount() - m_request_time);
   m_success_count++;
   m_total_slippage += slippage;
   if(slippage > m_max_slippage) m_max_slippage = slippage;
   m_total_latency_ms += latency;
   if(latency > m_max_latency_ms) m_max_latency_ms = latency;
   // slippage com sinal (adverso = custo real, favoravel = a favor)
   double adverse_slippage = (deal_type == DEAL_TYPE_BUY)
                              ? (exec_price - m_request_price) / point
                              : (m_request_price - exec_price) / point;
   m_signed_slippage_total += adverse_slippage;
   if(adverse_slippage > 0) m_adverse_slippage_count++;
   else if(adverse_slippage < 0) m_favorable_slippage_count++;
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
//| Ping / conectividade                                             |
//+------------------------------------------------------------------+
void CExecution::SamplePingAndConnection()
{
   long ping = TerminalInfoInteger(TERMINAL_PING_LAST);
   if(ping >= 0)
   {
      m_ping_last = ping;
      m_ping_sum += (double)ping;
      m_ping_samples++;
      if(ping > m_ping_max) m_ping_max = ping;
   }
   bool connected = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   if(m_was_connected && !connected) m_disconnect_count++;
   m_was_connected = connected;
}
//+------------------------------------------------------------------+
//| TIMEOUT & STATE UPDATE                                           |
//+------------------------------------------------------------------+
void CExecution::Update()
{
   UpdateSpreadStats();
   SamplePingAndConnection();
   
   // Salva quality em arquivo a cada 30 segundos
   static uint lastSaveTime = 0;
   if(GetTickCount() - lastSaveTime > 30000)
   {
      lastSaveTime = GetTickCount();
      if(m_total_requests > 0)
         SaveQualityToFile();
   }
   
   // Async retry (nao-bloqueante). Comparacao robusta a wraparound de GetTickCount()
   // (uint estoura em ~49.7 dias); internal_retry=true eh o unico jeito do motor
   // conseguir reenviar sem cair na guarda de reentrancia m_is_busy.
   if(m_pending_retry && (int)(GetTickCount() - m_retry_after_time) >= 0)
   {
      m_pending_retry = false;
      if(DEBUG_MODE) Print("[ALX RETRY] Executando ordem agendada...");
      Execute(m_retry_type, m_retry_volume, m_retry_target_price, m_retry_sl, m_retry_tp, m_retry_comment, true);
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
  
   // reject_rate usa apenas m_reject_count (origem broker), alinhado com o
   // denominador m_total_requests (tambem origem broker). Rejeicoes locais
   // (spread/toxic/volume/margem) ficam em m_local_reject_count.
   double reject_rate = (double)m_reject_count / m_total_requests * 100.0;
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
   if(GetAverageSpread() > 0 && (m_symbol.Spread() / m_symbol.Point()) > (GetAverageSpread() * 5.0)) return true;
   return false;
}
void CExecution::UpdateSpreadStats()
{
   double spread = (m_symbol.Ask() - m_symbol.Bid()) / m_symbol.Point();
   m_spread_total += spread;
   m_spread_sumsq += spread * spread;
   if(spread > m_spread_max) m_spread_max = spread;
   m_spread_samples++;
}
double CExecution::GetAverageSpread()
{
   if(m_spread_samples <= 0) return 0;
   return m_spread_total / m_spread_samples;
}
double CExecution::GetSpreadStdDev()
{
   if(m_spread_samples <= 0) return 0;
   double mean = m_spread_total / m_spread_samples;
   double variance = (m_spread_sumsq / m_spread_samples) - (mean * mean);
   return (variance > 0) ? MathSqrt(variance) : 0;
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
//| LotCheck - normalizacao de broker (step/min/max), NAO eh sizing  |
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
//| ClosePartial                                                     |
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
               if(!m_trade.PositionClose(m_position.Ticket()) && DEBUG_MODE)
                  Print("[ALX ERROR] CloseProfitPositions falhou. Ticket: ", m_position.Ticket(),
                        " Err: ", m_trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+
//| GetQualityJson - exporta metricas de qualidade como JSON          |
//+------------------------------------------------------------------+
string CExecution::GetQualityJson()
{
   string json = "{";
   json += "\"avg_spread\":" + DoubleToString(GetAverageSpread(), 2);
   json += ",\"spread_stddev\":" + DoubleToString(GetSpreadStdDev(), 2);
   json += ",\"max_spread\":" + DoubleToString(m_spread_max, 2);
   json += ",\"avg_slippage\":" + DoubleToString(GetAverageSlippage(), 2);
   json += ",\"max_slippage\":" + DoubleToString(GetMaxSlippage(), 2);
   json += ",\"signed_slippage_avg\":" + DoubleToString(GetSignedSlippageAvg(), 2);
   json += ",\"favorable_slippage_count\":" + IntegerToString(GetFavorableSlippageCount());
   json += ",\"adverse_slippage_count\":" + IntegerToString(GetAdverseSlippageCount());
   json += ",\"avg_latency_ms\":" + DoubleToString(GetAverageLatency(), 0);
   json += ",\"max_latency_ms\":" + DoubleToString(GetMaxLatency(), 0);
   json += ",\"ping_last\":" + IntegerToString(GetPingLast());
   json += ",\"ping_avg\":" + DoubleToString(GetAveragePing(), 0);
   json += ",\"ping_max\":" + IntegerToString(GetMaxPing());
   json += ",\"disconnect_count\":" + IntegerToString(GetDisconnectCount());
   json += ",\"success_rate\":" + DoubleToString(GetSuccessRate(), 2);
   json += ",\"total_requests\":" + IntegerToString(GetTotalRequests());
   json += ",\"success_count\":" + IntegerToString(GetSucessCount());
   json += ",\"reject_count\":" + IntegerToString(GetRejectCount());
   json += ",\"local_reject_count\":" + IntegerToString(GetLocalRejectCount());
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
   // usa m_symbol.Name() (simbolo da instancia), nao _Symbol global do grafico -
   // multiplas instancias de CExecution (uma por ativo) nao sobrescrevem mais o
   // mesmo arquivo.
   string filename = "mql5\\quality_" + IntegerToString(m_magic) + "_" + m_symbol.Name() + ".json";
   int handle = FileOpen(filename, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(handle != INVALID_HANDLE)
   {
      FileWriteString(handle, GetQualityJson());
      FileClose(handle);
   }
}
//+------------------------------------------------------------------+