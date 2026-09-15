//+------------------------------------------------------------------+
//|                                             ExecutionLite.mqh     |
//|                          ALXQuantCore - Simple Execution Engine  |
//| v2.3.0                                                            |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore Ltd."
#property version "7.11"
/*
    v.7.10 - 2026-08-16 - Add: Módulo ExecutionLite (execução simples + broker stats + human simulator).
    v.7.11 - 2026-08-17 - Fix: modos FIX interpretados em pontos brutos (x Point) via PointsToPrice();
                          human simulator desvia apenas a entrada (trailing determinístico); piso SL em pontos.
*/

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <ALXQuantCore\Core\enums.mqh>

#define BALANCE_UNIT 1000.0

//+------------------------------------------------------------------+
//| TradeParams - output structure from Calculate()                  |
//+------------------------------------------------------------------+
struct TradeParams
{
   double   lot;
   double   sl;
   double   sl_long;
   double   sl_short;
   double   tp;
   double   tp_long;
   double   tp_short;
   double   be_distance;
   double   trail_distance;
   double   trail_step;
   double   risk_pct_used;
   double   risk_usd;
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

enum ENUM_ALX_EXEC_MODE
{
   EXEC_MARKET,     // Market order
   EXEC_PENDING     // Pending order (Stop/Limit)
};

//+------------------------------------------------------------------+
//| CExecutionLite - Simple Execution + Position Sizing + Broker Stats|
//+------------------------------------------------------------------+
class CExecutionLite
{
private:
   //--- Objects ---
   CTrade         m_trade;
   CSymbolInfo    m_symbol;
   CAccountInfo   m_account;

   //--- Config ---
   ulong                m_magic;
   ENUM_ALX_EXEC_MODE   m_exec_mode;
   ENUM_ALX_LOT_MODE2   m_lot_mode;
   double               m_lot_value;
   ENUM_ALX_SL_MODE     m_sl_mode;
   double               m_sl_value;
   ENUM_ALX_TP_MODE     m_tp_mode;
   double               m_tp_value;
   int                  m_adr_days;
   ENUM_ALX_BE_MODE     m_be_mode;
   double               m_be_value;
   ENUM_ALX_TRAIL_MODE  m_trail_mode;
   double               m_trail_distance;   // pips (FIXED) ou ATR mult (ATR)
   double               m_trail_step;       // pips
   int                  m_atr_period;

   //--- Human Simulator ---
   bool     m_human_sim;
   double   m_human_max_pips;
   int      m_human_seed;
   ulong    m_human_counter;

   //--- Broker stats ---
   double   m_spread_total;
   double   m_spread_max;
   long     m_spread_samples;
   double   m_hourly_slippage[24];
   long     m_hourly_count[24];
   bool     m_broker_toxic;

   //--- State ---
   ENUM_ALX_EXEC_STATE m_state;
   ulong               m_request_order;
   uint                m_request_time;
   double              m_request_price;
   bool                m_is_busy;

   //--- Counters ---
   long     m_total_requests;
   long     m_success_count;
   long     m_reject_count;
   long     m_requote_count;
   long     m_timeout_count;
   double   m_total_slippage;
   double   m_max_slippage;
   double   m_total_latency_ms;
   double   m_max_latency_ms;

   //--- Helpers ---
   double                PipToPrice(double pips);
   double                PointsToPrice(double points);
   double                ATR(string symbol, ENUM_TIMEFRAMES period, int atr_period);
   double                CalcADR(int days);
   double                NormalizeLot(double raw_lot, string symbol, double &risk_usd_out);
   double                LotCheck(double lot, string symbol);
   double                HumanDeviationPips();
   ENUM_ALX_EXEC_RESULT  ParseRetcode(uint retcode);
   void                  ResetContext();
   bool                  ValidateVolume(double volume);
   bool                  ValidateMargin(ENUM_ORDER_TYPE type, double volume, double target_price);

public:
   //--- Constructor ---
   CExecutionLite();

   //--- Init ---
   bool                Init(string symbol, ulong magic);

   //--- Setters (sizing) ---
   void                SetLotMode(ENUM_ALX_LOT_MODE2 mode)         { m_lot_mode = mode; }
   void                SetLotValue(double val)                     { m_lot_value = val; }
   void                SetSLMode(ENUM_ALX_SL_MODE mode)            { m_sl_mode = mode; }
   void                SetSLValue(double v)                        { m_sl_value = v; }
   void                SetTPMode(ENUM_ALX_TP_MODE mode)            { m_tp_mode = mode; }
   void                SetTPValue(double r)                        { m_tp_value = r; }
   void                SetADRPeriod(int days)                      { if(days > 0) m_adr_days = days; }
   void                SetBEMode(ENUM_ALX_BE_MODE mode)            { m_be_mode = mode; }
   void                SetBEValue(double pips)                     { m_be_value = pips; }
   void                SetTrailMode(ENUM_ALX_TRAIL_MODE mode)      { m_trail_mode = mode; }
   void                SetTrailDistance(double dist)               { m_trail_distance = dist; }
   void                SetTrailStep(double step)                   { m_trail_step = step; }
   void                SetATRPeriod(int period)                    { if(period > 0) m_atr_period = period; }
   void                SetExecMode(ENUM_ALX_EXEC_MODE mode)        { m_exec_mode = mode; }

   //--- Human Simulator ---
   void                SetHumanSimulator(bool on, double max_dev_pips, int seed);

   //--- Sizing engine ---
   TradeParams         Calculate(string symbol, double sl_points = 0);

   //--- Execution ---
   bool                Execute(ENUM_ORDER_TYPE type, double volume, double sl, double tp, string comment = "");
   bool                Execute(ENUM_ORDER_TYPE type, double volume, double target_price, double sl, double tp, string comment = "");
   bool                Buy(double volume, double sl = 0, double tp = 0, string comment = "");
   bool                Sell(double volume, double sl = 0, double tp = 0, string comment = "");
   bool                Close(ulong ticket);
   bool                Modify(ulong ticket, double sl, double tp);
   void                CloseProfitPositions(ulong magic);

   //--- Broker stats (Panel contract) ---
   void                Update();
   void                UpdateSpreadStats();
   void                ProcessTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result);
   void                ResetState()                 { m_state = STATE_IDLE; m_is_busy = false; }
   bool                IsBusy()                     { return m_is_busy; }
   ENUM_ALX_EXEC_STATE GetState()                   { return m_state; }
   string              StateToString();
   double              GetAverageSlippage()         { return (m_success_count > 0) ? m_total_slippage / m_success_count : 0; }
   double              GetAverageLatency()          { return (m_success_count > 0) ? m_total_latency_ms / m_success_count : 0; }
   double              GetSuccessRate()             { return (m_total_requests > 0) ? (double)m_success_count / m_total_requests * 100.0 : 0; }
   double              GetBrokerScore();
   bool                IsBrokerToxic();
   double              GetAverageSpread();
   double              GetMaxSlippage()             { return m_max_slippage; }
   long                GetTotalRequests()           { return m_total_requests; }
   long                GetSucessCount()             { return m_success_count; }
   long                GetRejectCount()             { return m_reject_count; }
};

//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CExecutionLite::CExecutionLite()
{
   m_magic       = 0;
   m_exec_mode   = EXEC_MARKET;
   m_lot_mode    = LOT_RISK;
   m_lot_value   = 1.0;
   m_sl_mode     = SL_FIXED;
   m_sl_value    = 40.0;
   m_tp_mode     = TP_RISK_REWARD;
   m_tp_value    = 2.0;
   m_adr_days    = 14;
   m_be_mode     = BE_FIXED;
   m_be_value    = 30.0;
   m_trail_mode  = TRAIL_FIXED;
   m_trail_distance = 12.0;
   m_trail_step  = 4.0;
   m_atr_period  = 14;

   m_human_sim      = false;
   m_human_max_pips = 0.5;
   m_human_seed     = 0;
   m_human_counter  = 0;

   m_spread_total = 0;
   m_spread_max   = 0;
   m_spread_samples = 0;
   for(int i = 0; i < 24; i++) { m_hourly_slippage[i] = 0; m_hourly_count[i] = 0; }
   m_broker_toxic = false;

   m_state         = STATE_IDLE;
   m_request_order = 0;
   m_request_time  = 0;
   m_request_price = 0;
   m_is_busy       = false;

   m_total_requests = 0;
   m_success_count  = 0;
   m_reject_count   = 0;
   m_requote_count  = 0;
   m_timeout_count  = 0;
   m_total_slippage = 0;
   m_max_slippage   = 0;
   m_total_latency_ms = 0;
   m_max_latency_ms   = 0;
}

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
bool CExecutionLite::Init(string symbol, ulong magic)
{
   if(!m_symbol.Name(symbol)) return false;
   if(!m_symbol.RefreshRates()) return false;

   m_magic = magic;

   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(symbol);
   m_trade.SetDeviationInPoints(10);

   if(m_human_seed != 0)
      MathSrand(m_human_seed);

   return true;
}

//+------------------------------------------------------------------+
//| Human Simulator config                                            |
//+------------------------------------------------------------------+
void CExecutionLite::SetHumanSimulator(bool on, double max_dev_pips, int seed)
{
   m_human_sim      = on;
   m_human_max_pips = MathMax(0, max_dev_pips);
   m_human_seed     = seed;
   m_human_counter  = 0;
   if(seed != 0)
      MathSrand(seed);
}

//+------------------------------------------------------------------+
//| HumanDeviationPips - desvio aleatório ±(0..max) em pips           |
//+------------------------------------------------------------------+
double CExecutionLite::HumanDeviationPips()
{
   if(!m_human_sim || m_human_max_pips <= 0) return 0;

   if(m_human_seed != 0)
      MathSrand(m_human_seed + (int)m_human_counter++);
   else
      MathSrand((uint)(GetTickCount() + TimeCurrent() + m_human_counter++));

   int r = MathRand() % 2000;
   double pips = (r / 1000.0 - 1.0) * m_human_max_pips;
   return pips;
}

//+------------------------------------------------------------------+
//| PipToPrice                                                       |
//+------------------------------------------------------------------+
double CExecutionLite::PipToPrice(double pips)
{
   int digits = (int)m_symbol.Digits();
   int adjust = (digits == 3 || digits == 5) ? 10 : 1;
   return pips * m_symbol.Point() * adjust;
}

//+------------------------------------------------------------------+
//| PointsToPrice - raw points (x Point), como o EA IS Green original|
//+------------------------------------------------------------------+
double CExecutionLite::PointsToPrice(double points)
{
   return points * m_symbol.Point();
}

//+------------------------------------------------------------------+
//| ATR - direto via iATR (sem bandas StopATR)                       |
//+------------------------------------------------------------------+
double CExecutionLite::ATR(string symbol, ENUM_TIMEFRAMES period, int atr_period)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(iATR(symbol, period, atr_period), 0, 0, 1, buf) <= 0) return 0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| CalcADR - Average Daily Range                                    |
//+------------------------------------------------------------------+
double CExecutionLite::CalcADR(int days)
{
   double sum = 0;
   int count = 0;
   for(int i = 1; i <= days * 24; i++)
   {
      double high = iHigh(m_symbol.Name(), PERIOD_H1, i);
      double low  = iLow(m_symbol.Name(), PERIOD_H1, i);
      if(high > 0 && low > 0)
      {
         sum += MathAbs(high - low);
         count++;
      }
   }
   return (count > 0) ? sum / count * 24.0 : 0;
}

//+------------------------------------------------------------------+
//| NormalizeLot                                                     |
//+------------------------------------------------------------------+
double CExecutionLite::NormalizeLot(double raw_lot, string symbol, double &risk_usd_out)
{
   if(!m_symbol.RefreshRates()) return 0.0;

   double lot = raw_lot;

   if(m_account.Equity() > 0.0)
   {
      double contract_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      double price = m_symbol.Ask();
      if(contract_size > 0.0 && price > 0.0)
      {
         double max_notional = m_account.Equity() * (AccountInfoInteger(ACCOUNT_LEVERAGE) / 4);
         double notional_per_lot = contract_size * price;
         double max_lot_by_leverage = max_notional / notional_per_lot;
         lot = MathMin(lot, max_lot_by_leverage);
      }
   }

   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step > 0) lot = MathFloor(lot / step) * step;

   lot = MathMax(lot, SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN));
   lot = MathMin(lot, SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX));

   lot = NormalizeDouble(lot, 2);

   double tick_val  = m_symbol.TickValue();
   double tick_size = m_symbol.TickSize();
   if(tick_size > 0 && tick_val > 0 && lot > 0)
      risk_usd_out = lot * (PipToPrice(10) / tick_size) * tick_val;
   else
      risk_usd_out = 0;

   return lot;
}

//+------------------------------------------------------------------+
//| LotCheck                                                         |
//+------------------------------------------------------------------+
double CExecutionLite::LotCheck(double lot, string symbol)
{
   if(symbol == "") symbol = _Symbol;
   if(lot <= 0) return 0.0;

   double min_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(lot_step <= 0) lot_step = 0.01;
   if(min_lot <= 0)  min_lot = 0.01;

   lot = MathFloor(lot / lot_step) * lot_step;
   if(lot > max_lot) lot = max_lot;
   if(lot < min_lot) lot = min_lot;

   return NormalizeDouble(lot, 8);
}

//+------------------------------------------------------------------+
//| ValidateVolume                                                   |
//+------------------------------------------------------------------+
bool CExecutionLite::ValidateVolume(double volume)
{
   if(volume < m_symbol.LotsMin() || volume > m_symbol.LotsMax()) return false;
   double step = m_symbol.LotsStep();
   if(step > 0 && MathAbs(MathRound(volume/step)*step - volume) > 0.0000001) return false;
   return true;
}

//+------------------------------------------------------------------+
//| ValidateMargin                                                   |
//+------------------------------------------------------------------+
bool CExecutionLite::ValidateMargin(ENUM_ORDER_TYPE type, double volume, double target_price)
{
   double price = 0;

   if(target_price > 0) price = target_price;
   else price = (type == ORDER_TYPE_BUY || type == ORDER_TYPE_BUY_LIMIT ||
                 type == ORDER_TYPE_BUY_STOP) ? m_symbol.Ask() : m_symbol.Bid();

   double margin = m_account.MarginCheck(m_symbol.Name(), type, volume, price);

   if(margin == 0) return true;

   double free_margin = m_account.FreeMargin();
   double safety_margin = free_margin * 0.001;

   return (margin > 0 && margin <= (free_margin - safety_margin));
}

//+------------------------------------------------------------------+
//| Calculate - Position Sizing Engine (simple)                      |
//+------------------------------------------------------------------+
TradeParams CExecutionLite::Calculate(string symbol, double sl_points)
{
   TradeParams result;
   ZeroMemory(result);

   if(!m_symbol.RefreshRates()) return result;

   //--- Step 1: SL distance (ATR direto, sem bandas) ---
   double sl_dist = 0;
   if(m_sl_mode == SL_ATR)
      sl_dist = ATR(m_symbol.Name(), PERIOD_CURRENT, m_atr_period) * m_sl_value;
   else if(sl_points > 0)
      sl_dist = sl_points;
   else
      sl_dist = PointsToPrice(m_sl_value);

   if(sl_dist <= 0) return result;

   double broker_stop_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(symbol, SYMBOL_POINT);
   double min_sl = MathMax(broker_stop_level * 2, PointsToPrice(10));
   if(sl_dist < min_sl)
   {
      Print("[EXECLITE] SL clamped: ", sl_dist, " -> ", min_sl);
      sl_dist = min_sl;
   }

   double sl_long  = sl_dist;
   double sl_short = sl_dist;

   //--- Step 2: TP distance ---
   double tp_dist  = 0;
   double tp_long  = 0;
   double tp_short = 0;
   if(m_tp_mode == TP_RISK_REWARD)
   {
      tp_dist  = sl_dist * m_tp_value;
      tp_long  = sl_long  * m_tp_value;
      tp_short = sl_short * m_tp_value;
   }
   else if(m_tp_mode == TP_FIXED)
   {
      tp_dist = PointsToPrice(m_tp_value);
      tp_long = tp_short = tp_dist;
   }
   else if(m_tp_mode == TP_ADR)
   {
      tp_dist = CalcADR(m_adr_days) * m_tp_value;
      tp_long = tp_short = tp_dist;
   }

   //--- Step 3: Breakeven distance ---
   double be_dist = 0;
   if(m_be_mode == BE_ATR)
      be_dist = ATR(m_symbol.Name(), PERIOD_CURRENT, m_atr_period) * m_be_value;
   else
      be_dist = PointsToPrice(m_be_value);

   //--- Step 4: Trailing distances ---
   double trail_dist = 0;
   double trail_step = 0;
   if(m_trail_mode == TRAIL_ATR)
   {
      double atr = ATR(m_symbol.Name(), PERIOD_CURRENT, m_atr_period);
      trail_dist = (m_trail_distance > 0) ? atr * m_trail_distance : atr;
      trail_step = PointsToPrice(m_trail_step);
   }
   else
   {
      trail_dist = PointsToPrice(m_trail_distance);
      trail_step = PointsToPrice(m_trail_step);
   }

   //--- Trailing determinístico (sem desvio human sim, como EA original) ---

   //--- Step 5: Lot ---
   double lot_raw = 0;
   double risk_usd = 0;

   switch(m_lot_mode)
   {
      case LOT_FIXED:
         lot_raw = m_lot_value;
         if(lot_raw <= 0) return result;
         break;

      case LOT_BALANCE:
         lot_raw = (m_account.Balance() / BALANCE_UNIT) * m_lot_value;
         if(lot_raw <= 0) return result;
         break;

      case LOT_RISK:
      {
         double risk_money = m_account.Equity() * (m_lot_value / 100.0);
         double tick_val  = m_symbol.TickValue();
         double tick_size = m_symbol.TickSize();
         if(tick_size > 0 && tick_val > 0)
         {
            double risk_per_lot = (sl_dist / tick_size) * tick_val;
            if(risk_per_lot > 0)
               lot_raw = risk_money / risk_per_lot;
         }
         if(lot_raw <= 0) return result;
         break;
      }
   }

   //--- Step 6: Normalize lot ---
   result.lot = NormalizeLot(lot_raw, symbol, risk_usd);
   if(result.lot <= 0) return result;

   //--- Step 7: Output ---
   result.sl              = sl_dist;
   result.sl_long         = sl_long;
   result.sl_short        = sl_short;
   result.tp              = tp_dist;
   result.tp_long         = tp_long;
   result.tp_short        = tp_short;
   result.be_distance     = be_dist;
   result.trail_distance  = trail_dist;
   result.trail_step      = trail_step;
   result.risk_usd        = risk_usd;
   result.risk_pct_used   = m_lot_value;

   return result;
}

//+------------------------------------------------------------------+
//| Execute - Market (simples)                                       |
//+------------------------------------------------------------------+
bool CExecutionLite::Execute(ENUM_ORDER_TYPE type, double volume, double sl, double tp, string comment)
{
   return Execute(type, volume, 0.0, sl, tp, comment);
}

//+------------------------------------------------------------------+
//| Execute - Market ou Pending (controlado por ENUM_ALX_EXEC_MODE)  |
//+------------------------------------------------------------------+
bool CExecutionLite::Execute(ENUM_ORDER_TYPE type, double volume, double target_price, double sl, double tp, string comment)
{
   if(m_is_busy) return false;
   if(!m_symbol.RefreshRates()) return false;

   volume = LotCheck(volume, m_symbol.Name());

   if(!ValidateVolume(volume))
   {
      m_reject_count++;
      return false;
   }
   if(!ValidateMargin(type, volume, target_price))
   {
      m_reject_count++;
      return false;
   }

   //--- Human Simulator: desvio aleatório apenas na entrada (fidelidade v2.1.0) ---
   double dev_entry = PipToPrice(HumanDeviationPips());
   double sl_final  = sl;
   double tp_final  = tp;

   m_state = STATE_SENDING;
   m_request_time = GetTickCount();

   bool send_result = false;
   double entry_price = 0;

   if(m_exec_mode == EXEC_PENDING && target_price > 0 &&
      (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT ||
       type == ORDER_TYPE_BUY_STOP  || type == ORDER_TYPE_SELL_STOP))
   {
      //--- Pending order ---
      m_request_price = target_price;
      switch(type)
      {
         case ORDER_TYPE_BUY_LIMIT:
            send_result = m_trade.BuyLimit(volume, target_price + dev_entry, m_symbol.Name(), sl_final, tp_final, ORDER_TIME_GTC, 0, comment);
            break;
         case ORDER_TYPE_SELL_LIMIT:
            send_result = m_trade.SellLimit(volume, target_price + dev_entry, m_symbol.Name(), sl_final, tp_final, ORDER_TIME_GTC, 0, comment);
            break;
         case ORDER_TYPE_BUY_STOP:
            send_result = m_trade.BuyStop(volume, target_price + dev_entry, m_symbol.Name(), sl_final, tp_final, ORDER_TIME_GTC, 0, comment);
            break;
         case ORDER_TYPE_SELL_STOP:
            send_result = m_trade.SellStop(volume, target_price + dev_entry, m_symbol.Name(), sl_final, tp_final, ORDER_TIME_GTC, 0, comment);
            break;
      }
   }
   else
   {
      //--- Market order ---
      switch(type)
      {
         case ORDER_TYPE_BUY:
            entry_price = m_symbol.Ask() + dev_entry;
            m_request_price = m_symbol.Ask();
            send_result = m_trade.Buy(volume, m_symbol.Name(), entry_price, sl_final, tp_final, comment);
            break;

         case ORDER_TYPE_SELL:
            entry_price = m_symbol.Bid() + dev_entry;
            m_request_price = m_symbol.Bid();
            send_result = m_trade.Sell(volume, m_symbol.Name(), entry_price, sl_final, tp_final, comment);
            break;

         default:
            m_state = STATE_FAILED;
            return false;
      }
   }

   uint retcode = m_trade.ResultRetcode();
   ENUM_ALX_EXEC_RESULT result = ParseRetcode(retcode);

   if(send_result && (retcode == 10009 || retcode == 10008))
   {
      m_state = STATE_WAITING;
      m_request_order = m_trade.ResultOrder();
      m_is_busy = true;
      m_total_requests++;
      return true;
   }
   else
   {
      if(result == RESULT_REQUOTE || result == RESULT_OFF_QUOTES || result == RESULT_BROKER_BUSY)
      {
         m_requote_count++;
         m_reject_count++;
         m_total_requests++;
         m_state = STATE_FAILED;
         return false;
      }

      m_state = STATE_FAILED;
      m_reject_count++;
      m_total_requests++;
      return false;
   }
}

//+------------------------------------------------------------------+
//| High Level API                                                   |
//+------------------------------------------------------------------+
bool CExecutionLite::Buy(double volume, double sl, double tp, string comment)
{
   return Execute(ORDER_TYPE_BUY, volume, sl, tp, comment);
}

bool CExecutionLite::Sell(double volume, double sl, double tp, string comment)
{
   return Execute(ORDER_TYPE_SELL, volume, sl, tp, comment);
}

bool CExecutionLite::Close(ulong ticket)
{
   return m_trade.PositionClose(ticket);
}

bool CExecutionLite::Modify(ulong ticket, double sl, double tp)
{
   return m_trade.PositionModify(ticket, sl, tp);
}

//+------------------------------------------------------------------+
//| Close profit positions                                           |
//+------------------------------------------------------------------+
void CExecutionLite::CloseProfitPositions(ulong magic)
{
   CPositionInfo position;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(position.SelectByIndex(i))
         if(position.Symbol() == m_symbol.Name() && position.Magic() == magic)
            if(position.Commission() + position.Swap() + position.Profit() > 0.0)
               m_trade.PositionClose(position.Ticket());
}

//+------------------------------------------------------------------+
//| ProcessTradeTransaction - medição de latência e slippage         |
//+------------------------------------------------------------------+
void CExecutionLite::ProcessTradeTransaction(
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

   if(deal_magic != m_magic)          return;
   if(deal_symbol != m_symbol.Name()) return;
   if(deal_entry != DEAL_ENTRY_IN)    return;

   if(m_state != STATE_WAITING)       return;
   if(m_request_order != deal_order)  return;

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
   m_is_busy = false;

   string side = (deal_type == DEAL_TYPE_BUY) ? "BUY" : "SELL";
   Print("[EXECLITE CONFIRMED] ", side,
         " | Ticket=", deal_ticket,
         " | Volume=", DoubleToString(exec_volume, 2),
         " | Price=", DoubleToString(exec_price, _Digits),
         " | Slippage=", DoubleToString(slippage, 1), " pts",
         " | Latency=", DoubleToString(latency, 0), " ms");

   ResetContext();
}

//+------------------------------------------------------------------+
//| Update - spread stats + timeout leve                             |
//+------------------------------------------------------------------+
void CExecutionLite::Update()
{
   UpdateSpreadStats();

   if(m_state == STATE_WAITING)
   {
      double elapsed_ms = (double)(GetTickCount() - m_request_time);
      if(elapsed_ms > 10000)
      {
         m_state = STATE_TIMEOUT;
         m_timeout_count++;
         m_is_busy = false;
         ResetContext();
      }
   }
}

//+------------------------------------------------------------------+
//| UpdateSpreadStats                                                |
//+------------------------------------------------------------------+
void CExecutionLite::UpdateSpreadStats()
{
   double spread = (m_symbol.Ask() - m_symbol.Bid()) / _Point;
   m_spread_total += spread;
   if(spread > m_spread_max) m_spread_max = spread;
   m_spread_samples++;
}

double CExecutionLite::GetAverageSpread()
{
   if(m_spread_samples <= 0) return 0;
   return m_spread_total / m_spread_samples;
}

//+------------------------------------------------------------------+
//| Broker quality score                                             |
//+------------------------------------------------------------------+
double CExecutionLite::GetBrokerScore()
{
   if(m_total_requests <= 0) return 100.0;

   double success_score  = GetSuccessRate();
   double latency_score  = MathMax(0, 100.0 - (GetAverageLatency() / 100.0));
   double slippage_score = MathMax(0, 100.0 - (GetAverageSlippage() * 5.0));

   double reject_rate  = (m_total_requests > 0) ? (double)m_reject_count / m_total_requests * 100.0 : 0;
   reject_rate         = MathMin(reject_rate, 100.0);
   double reject_score = MathMax(0, 100.0 - (reject_rate * 0.2));

   return NormalizeDouble((success_score * 0.40 + latency_score * 0.20 + slippage_score * 0.25 + reject_score * 0.15), 1);
}

bool CExecutionLite::IsBrokerToxic()
{
   if(m_total_requests <= 0) return false;
   if(GetAverageSlippage() > 2.0) return true;
   if(GetAverageLatency() > 1000) return true;
   if(GetSuccessRate() < 85) return true;
   if(GetAverageSpread() > 0 && (m_symbol.Spread() / _Point) > (GetAverageSpread() * 5.0)) return true;
   return false;
}

string CExecutionLite::StateToString()
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
//| ParseRetcode                                                     |
//+------------------------------------------------------------------+
ENUM_ALX_EXEC_RESULT CExecutionLite::ParseRetcode(uint retcode)
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
//| ResetContext                                                     |
//+------------------------------------------------------------------+
void CExecutionLite::ResetContext()
{
   m_state = STATE_IDLE;
   m_request_order = 0;
   m_request_time = 0;
   m_request_price = 0;
   m_is_busy = false;
}