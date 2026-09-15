//+------------------------------------------------------------------+
//|                                          PositionSizing.mqh      |
//|                ALXQuantCore - Institutional Position Sizing      |
//|                                           v1.00 - Multi-Factor   |
//| v7.1.2                                                            |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore Ltd."
#property version "7.12"
/*
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
*/

#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Dependencies: RiskOn, RiskManager, MacroRegimeEngine must be included before this file
//+------------------------------------------------------------------+
//| TradeParams - output structure from Calculate()                  |
//+------------------------------------------------------------------+
struct TradeParams
{
   double   lot;
   double   sl;                // Stop Loss price (0 = no SL)
   double   tp;                // Take Profit price (0 = no TP)
   double   be_distance;       // Breakeven trigger distance (in price)
   double   trail_distance;    // Trailing stop distance (in price)
   double   trail_step;        // Trailing step (in price)
   double   risk_pct_used;     // % equity actually used
   double   risk_usd;          // Risk in dollars
};

//+------------------------------------------------------------------+
//| Kelly trade record                                               |
//+------------------------------------------------------------------+
struct KellyTrade
{
   double   r_multiple;
   int      outcome;           // 1 = WIN, -1 = LOSS, 0 = BREAKEVEN
};

//+------------------------------------------------------------------+
//| CPositionSizing - Institutional Position Sizing Engine           |
//+------------------------------------------------------------------+
class CPositionSizing
{
private:
   //--- Dependencies (pointers) ---
   CRiskSentiment     *m_risksentiment;
   CRiskManager       *m_risk_mgr;
   CMacroRegimeEngine *m_regime;
   CSymbolInfo        *m_symbol;
   CAccountInfo        m_account;

   //--- Parameters ---
   ENUM_ALX_LOT_MODE2  m_lot_mode;
   double   m_lot_fixed;
   double   m_base_risk_pct;
   double   m_kelly_fraction;
   int      m_min_kelly_trades;
   double   m_strategy_weight[5];

   //--- SL/TP/BE/Trail modes ---
   ENUM_ALX_SL_MODE    m_sl_mode;
   double              m_sl_fixed;
   double              m_sl_atr_mult;
   ENUM_ALX_TP_MODE    m_tp_mode;
   double              m_tp_ratio;
   double              m_tp_fixed;
   double              m_tp_adr_mult;
   ENUM_ALX_BE_MODE    m_be_mode;
   double              m_be_fixed;
   double              m_be_atr_mult;
   ENUM_ALX_TRAIL_MODE m_trail_mode;
   double              m_trail_fixed;
   double              m_trail_atr_mult;
   double              m_trail_step_fixed;
   double              m_trail_step_atr_mult;

   //--- Kelly history rolling array ---
   KellyTrade  m_kelly_trades[100];
   int         m_kelly_count;
   int         m_kelly_head;

   //--- Cache ---
   datetime    m_last_adr_time;
   double      m_cached_adr;

   //--- Helpers ---
   double      PipToPrice(double pips);

   //--- Private methods ---
   double      CalcADR(int days = 14);
   double      CalcKellyFactor();
   double      CalcMacroFactor();
   double      CalcVolFactor();
   double      CalcLiqFactor();
   double      CalcDDFactor();
   double      CalcStratFactor(ENUM_ALX_STRATEGY strategy, double confidence);
   double      NormalizeLot(double raw_lot, string symbol, double &risk_usd_out);

public:
   //--- Constructor ---
   CPositionSizing();

   //--- Init ---
   void        Init(CRiskSentiment *risksentiment, CRiskManager *risk_mgr,
                     CMacroRegimeEngine *regime, CSymbolInfo *symbol);

   //--- Parameters setters ---
   void        SetLotMode(ENUM_ALX_LOT_MODE2 mode)   { m_lot_mode = mode; }
   void        SetLotFixed(double lot)                { m_lot_fixed = lot; }
   void        SetBaseRiskPct(double pct)             { m_base_risk_pct = pct; }
   void        SetKellyFraction(double f)             { m_kelly_fraction = f; }
   void        SetMinKellyTrades(int n)               { m_min_kelly_trades = n; }
   void        SetStrategyWeight(ENUM_ALX_STRATEGY s, double w) { m_strategy_weight[s] = w; }

   void        SetSLMode(ENUM_ALX_SL_MODE mode)     { m_sl_mode = mode; }
   void        SetSLFixed(double pips)               { m_sl_fixed = pips; }
   void        SetSLATR(double mult)                 { m_sl_atr_mult = mult; }

   void        SetTPMode(ENUM_ALX_TP_MODE mode)     { m_tp_mode = mode; }
   void        SetTPRatio(double r)                  { m_tp_ratio = r; }
   void        SetTPFixed(double pips)               { m_tp_fixed = pips; }
   void        SetTPADR(double mult)                 { m_tp_adr_mult = mult; }

   void        SetBEMode(ENUM_ALX_BE_MODE mode)     { m_be_mode = mode; }
   void        SetBEFixed(double pips)               { m_be_fixed = pips; }
   void        SetBEATR(double mult)                 { m_be_atr_mult = mult; }

   void        SetTrailMode(ENUM_ALX_TRAIL_MODE mode) { m_trail_mode = mode; }
   void        SetTrailFixed(double dist, double step) { m_trail_fixed = dist; m_trail_step_fixed = step; }
   void        SetTrailATR(double dist, double step) { m_trail_atr_mult = dist; m_trail_step_atr_mult = step; }

   //--- Kelly history ---
   void        LoadKellyHistory(string csv_path);
   void        AddKellyTrade(double r_multiple, int outcome);

   //--- Core calculation ---
   TradeParams Calculate(ENUM_ALX_STRATEGY strategy, double confidence,
                         double sl_points, string symbol);

   //--- Getters ---
   int         GetKellyCount() { return m_kelly_count; }
   double      GetKellyFactorResult() { return CalcKellyFactor(); }
};

//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CPositionSizing::CPositionSizing()
{
   m_risksentiment = NULL;
   m_risk_mgr = NULL;
   m_regime   = NULL;
   m_symbol   = NULL;

   m_lot_mode         = LOT_RISK_PCT;
   m_lot_fixed        = 0.10;
   m_base_risk_pct    = 0.5;
   m_kelly_fraction   = 0.25;
   m_min_kelly_trades = 20;
   for(int i = 0; i < 5; i++) m_strategy_weight[i] = 0.8;

   m_sl_mode     = SL_FIXED;
   m_sl_fixed    = 150;
   m_sl_atr_mult = 1.5;

   m_tp_mode     = TP_RISK_REWARD;
   m_tp_ratio    = 2.0;
   m_tp_fixed    = 300;
   m_tp_adr_mult = 0.5;

   m_be_mode     = BE_FIXED;
   m_be_fixed    = 160;
   m_be_atr_mult = 0.8;

   m_trail_mode       = TRAIL_FIXED;
   m_trail_fixed      = 160;
   m_trail_atr_mult   = 0.8;
   m_trail_step_fixed = 80;
   m_trail_step_atr_mult = 0.4;

   m_kelly_count = 0;
   m_kelly_head  = 0;
   for(int i = 0; i < 100; i++) { m_kelly_trades[i].r_multiple = 0; m_kelly_trades[i].outcome = 0; }

   m_last_adr_time = 0;
   m_cached_adr    = 0;
}

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
void CPositionSizing::Init(CRiskSentiment *risksentiment, CRiskManager *risk_mgr,
                           CMacroRegimeEngine *regime, CSymbolInfo *symbol)
{
   m_risksentiment = risksentiment;
   m_risk_mgr = risk_mgr;
   m_regime   = regime;
   m_symbol   = symbol;
}

//+------------------------------------------------------------------+
//| PipToPrice - convert pips to price units (handles 3/5-digit FX) |
//+------------------------------------------------------------------+
double CPositionSizing::PipToPrice(double pips)
{
   if(m_symbol == NULL) return pips * 0.0001;
   int digits = (int)m_symbol.Digits();
   int adjust = (digits == 3 || digits == 5) ? 10 : 1;
   return pips * m_symbol.Point() * adjust;
}

//+------------------------------------------------------------------+
//| LoadKellyHistory - load from alxquant_miner.csv at OnInit        |
//+------------------------------------------------------------------+
void CPositionSizing::LoadKellyHistory(string csv_path)
{
   int handle = FileOpen(csv_path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(handle == INVALID_HANDLE)
   {
      // Try sandbox (FILE_LOCAL) as fallback
      handle = FileOpen(csv_path, FILE_READ | FILE_TXT | FILE_ANSI);
      if(handle == INVALID_HANDLE)
      {
         Print("[PS] Kelly history file not found in Common or Sandbox: ", csv_path);
         return;
      }
   }

   // Skip header line
   if(!FileIsEnding(handle)) FileReadString(handle);

   while(!FileIsEnding(handle) && m_kelly_count < 100)
   {
      string line = FileReadString(handle);
      if(line == "") continue;

      string parts[];
      int n = StringSplit(line, ';', parts);
      if(n < 88) continue;

      string outcome_str = parts[87];
      double resultR = StringToDouble(parts[85]);

      int outcome = 0;
      if(outcome_str == "WIN")       outcome = 1;
      else if(outcome_str == "LOSS") outcome = -1;

      AddKellyTrade(resultR, outcome);
   }

   FileClose(handle);
   Print("[PS] Kelly history loaded: ", m_kelly_count, " trades");
}

//+------------------------------------------------------------------+
//| AddKellyTrade - add trade to rolling array                       |
//+------------------------------------------------------------------+
void CPositionSizing::AddKellyTrade(double r_multiple, int outcome)
{
   if(m_kelly_count < 100) m_kelly_count++;

   m_kelly_trades[m_kelly_head].r_multiple = r_multiple;
   m_kelly_trades[m_kelly_head].outcome    = outcome;

   m_kelly_head = (m_kelly_head + 1) % 100;
}

//+------------------------------------------------------------------+
//| CalcADR - Average Daily Range (last 14 days)                    |
//+------------------------------------------------------------------+
double CPositionSizing::CalcADR(int days)
{
   datetime now = TimeCurrent();
   if(now - m_last_adr_time < 86400 && m_cached_adr > 0)
      return m_cached_adr;

   double high_buf[], low_buf[];
   ArraySetAsSeries(high_buf, true);
   ArraySetAsSeries(low_buf, true);

   if(CopyHigh(m_symbol.Name(), PERIOD_D1, 1, days, high_buf) <= 0) return 0;
   if(CopyLow(m_symbol.Name(), PERIOD_D1, 1, days, low_buf) <= 0) return 0;

   double total_range = 0;
   for(int i = 0; i < days && i < ArraySize(high_buf) && i < ArraySize(low_buf); i++)
      total_range += high_buf[i] - low_buf[i];

   m_cached_adr = total_range / days;
   m_last_adr_time = now;
   return m_cached_adr;
}

//+------------------------------------------------------------------+
//| KellyFactor - Kelly Criterion fracionario                       |
//+------------------------------------------------------------------+
double CPositionSizing::CalcKellyFactor()
{
   if(m_kelly_count < m_min_kelly_trades || m_kelly_fraction <= 0)
      return 1.0;

   int wins = 0, losses = 0;
   double total_win = 0, total_loss = 0;

   for(int i = 0; i < m_kelly_count; i++)
   {
      if(m_kelly_trades[i].outcome == 1)
      {
         wins++;
         total_win += m_kelly_trades[i].r_multiple;
      }
      else if(m_kelly_trades[i].outcome == -1)
      {
         losses++;
         total_loss += MathAbs(m_kelly_trades[i].r_multiple);
      }
   }

   if(wins + losses == 0) return 1.0;

   double win_rate = (double)wins / (wins + losses);
   double avg_win  = (wins > 0)  ? total_win / wins  : 0;
   double avg_loss = (losses > 0) ? total_loss / losses : 1;
   double ratio    = (avg_loss > 0) ? avg_win / avg_loss : 1;

   // Kelly% = WR - (1-WR) / R
   double kelly = win_rate - (1 - win_rate) / ratio;
   if(kelly <= 0) return 0.3; // Kelly negativo = reduz ao mínimo
   if(kelly > 1)  kelly = 1;

   return 1.0 - m_kelly_fraction + m_kelly_fraction * kelly;
   // range: (1 - kelly_fraction) ... 1.0
   // ex: fraction=0.25, kelly=0.5 → 0.75 + 0.125 = 0.875
}

//+------------------------------------------------------------------+
//| MacroFactor - based on RiskOn::GetRiskScore()                   |
//+------------------------------------------------------------------+
double CPositionSizing::CalcMacroFactor()
{
   if(m_risksentiment == NULL) return 1.0;

   double score = m_risksentiment.GetRiskScore();
   double multiplier = 0.5;

   if(score >= 0.5)
      multiplier = 1.0;               // Risk On - full size
   else if(score >= 0.1)
      multiplier = 0.5 + (score * 0.5); // 0.55..0.95
   else if(score >= -0.1)
      multiplier = 0.5;               // Neutral
   else if(score >= -0.5)
      multiplier = 0.3 + (score + 0.5) * 0.4; // 0.3..0.46
   else
      multiplier = 0.3;               // Risk Off - heavy reduction

   return multiplier;
}

//+------------------------------------------------------------------+
//| VolFactor - Hurst + VolBurst                                    |
//+------------------------------------------------------------------+
double CPositionSizing::CalcVolFactor()
{
   if(m_regime == NULL) return 1.0;

   double H = m_regime.GetLastHurst();
   bool vol_burst = m_regime.IsVolatilityBurst();

   double factor = 1.0;
   if(H >= 0.55)
      factor = 1.0;
   else if(H >= 0.48)
      factor = 0.8;
   else
      factor = 0.6;

   if(vol_burst)
      factor *= 0.5;

   return MathMax(factor, 0.1);
}

//+------------------------------------------------------------------+
//| LiqFactor - based on spread anomaly                             |
//+------------------------------------------------------------------+
double CPositionSizing::CalcLiqFactor()
{
   if(m_regime == NULL) return 1.0;

   double anomaly = m_regime.GetSpreadAnomaly();
   double factor = 1.0;

   if(anomaly < 1.0)
      factor = 1.0;
   else if(anomaly < 2.0)
      factor = 0.7;
   else if(anomaly < 3.0)
      factor = 0.4;
   else
      factor = 0.15;

   return factor;
}

//+------------------------------------------------------------------+
//| DDFactor - current drawdown reduction                           |
//+------------------------------------------------------------------+
double CPositionSizing::CalcDDFactor()
{
   if(m_risk_mgr == NULL) return 1.0;

   // Get current drawdown from account
   double balance = m_account.Balance();
   double equity  = m_account.Equity();
   if(balance <= 0) return 1.0;

   double dd_pct = (balance - equity) / balance * 100;
   if(dd_pct < 0) dd_pct = 0;

   double factor = 1.0;
   if(dd_pct <= 3.0)
      factor = 1.0;
   else if(dd_pct <= 6.0)
      factor = 0.8;
   else if(dd_pct <= 10.0)
      factor = 0.5;
   else if(dd_pct <= 15.0)
      factor = 0.25;
   else
      factor = 0.0; // DD > 15% = no trading

   return factor;
}

//+------------------------------------------------------------------+
//| StratFactor - strategy weight × signal confidence               |
//+------------------------------------------------------------------+
double CPositionSizing::CalcStratFactor(ENUM_ALX_STRATEGY strategy, double confidence)
{
   double weight = m_strategy_weight[strategy];
   if(weight < 0.01) weight = 0.01;
   if(weight > 1.0)  weight = 1.0;

   double conf = confidence;
   if(conf < 0.01) conf = 0.01;
   if(conf > 1.0)  conf = 1.0;

   return weight * conf;
}

//+------------------------------------------------------------------+
//| NormalizeLot - round to step, clamp min/max, leverage cap      |
//+------------------------------------------------------------------+
double CPositionSizing::NormalizeLot(double raw_lot, string symbol, double &risk_usd_out)
{
   if(!m_symbol.RefreshRates())
   {
      risk_usd_out = 0;
      return 0;
   }

   double step = m_symbol.LotsStep();
   double lot  = raw_lot;

   if(step > 0)
      lot = MathFloor(lot / step) * step;

   lot = MathMax(lot, m_symbol.LotsMin());
   lot = MathMin(lot, m_symbol.LotsMax());

   // Leverage cap (max 25% of equity as notional)
   double balance = m_account.Balance();
   double contract_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double price = m_symbol.Ask();
   if(contract_size > 0 && price > 0 && balance > 0)
   {
      double max_notional = balance * 5; // 5x leverage max
      double notional_per_lot = contract_size * price;
      if(notional_per_lot > 0)
      {
         double max_lot = max_notional / notional_per_lot;
         lot = MathMin(lot, max_lot);
      }
   }

   // Recalculate risk in USD
   double tick_val  = m_symbol.TickValue();
   double tick_size = m_symbol.TickSize();
   if(tick_size > 0 && tick_val > 0)
      risk_usd_out = lot * tick_val / tick_size; // approximate per-lot risk
   else
      risk_usd_out = 0;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Calculate - main entry point: returns TradeParams                |
//|                                                                  |
//| Parameters:                                                      |
//|   strategy  - strategy enum                                      |
//|   confidence - signal confidence 0.0-1.0                         |
//|   sl_points - stop loss in PRICE units (0 = use fallback ATR)   |
//|   symbol    - trading symbol                                     |
//+------------------------------------------------------------------+
TradeParams CPositionSizing::Calculate(ENUM_ALX_STRATEGY strategy,
                                       double confidence,
                                       double sl_points,
                                       string symbol)
{
   TradeParams result;
   ZeroMemory(result);

   if(m_symbol == NULL) return result;
   if(!m_symbol.RefreshRates()) return result;

   //--- Step 1: Determine SL distance (mode takes priority over parameter) ---
   double sl_dist = 0;
   if(m_sl_mode == SL_ATR)
      sl_dist = (m_regime != NULL ? m_regime.CustomATR(m_symbol.Name(), PERIOD_CURRENT, 14, 1) : 0) * m_sl_atr_mult;
   else if(sl_points > 0)
      sl_dist = sl_points;
   else
      sl_dist = PipToPrice(m_sl_fixed);

   if(sl_dist <= 0) return result; // Can't trade without SL

   // Clamp to minimum: broker stop level * 2, or 10 pips, whichever is larger
   double broker_stop_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(symbol, SYMBOL_POINT);
   double min_sl = MathMax(broker_stop_level * 2, PipToPrice(10));
   if(sl_dist < min_sl)
   {
      Print("[PS] SL clamped: ", sl_dist, " -> ", min_sl);
      sl_dist = min_sl;
   }

   //--- Step 2: Calculate TP ---
   double tp_dist = 0;
   if(m_tp_mode == TP_RISK_REWARD)
      tp_dist = sl_dist * m_tp_ratio;
   else if(m_tp_mode == TP_FIXED)
      tp_dist = PipToPrice(m_tp_fixed);
   else if(m_tp_mode == TP_ADR)
      tp_dist = CalcADR() * m_tp_adr_mult;

   //--- Step 3: Breakeven distance ---
   double be_dist = 0;
   if(m_be_mode == BE_ATR)
      be_dist = (m_regime != NULL ? m_regime.CustomATR(m_symbol.Name(), PERIOD_CURRENT, 14, 1) : 0) * m_be_atr_mult;
   else
      be_dist = PipToPrice(m_be_fixed);

   //--- Step 4: Trailing distances ---
   double trail_dist = 0;
   double trail_step = 0;
   if(m_trail_mode == TRAIL_ATR)
   {
      double atr = (m_regime != NULL ? m_regime.CustomATR(m_symbol.Name(), PERIOD_CURRENT, 14, 1) : 0);
      trail_dist = atr * m_trail_atr_mult;
      trail_step = atr * m_trail_step_atr_mult;
   }
   else
   {
      trail_dist = PipToPrice(m_trail_fixed);
      trail_step = PipToPrice(m_trail_step_fixed);
   }

   //--- Step 5: Calculate lot (mode-dependent) ---
   double lot_raw = 0;
   double risk_usd = 0;

   switch(m_lot_mode)
   {
      case LOT_FIXED:
      {
         // Fixed lot, no factors
         lot_raw = m_lot_fixed;
         if(lot_raw <= 0) return result;
         result.lot = NormalizeLot(lot_raw, symbol, risk_usd);
         if(result.lot <= 0) return result;
         result.risk_pct_used = 0;
         break;
      }

      case LOT_BALANCE:
      {
         // Balance-proportional: risk% without most factors
         double risk_money   = m_account.Balance() * (m_base_risk_pct / 100.0);
         double tick_val     = m_symbol.TickValue();
         double tick_size    = m_symbol.TickSize();
         if(tick_size > 0 && tick_val > 0)
         {
            double risk_per_lot = (sl_dist / tick_size) * tick_val;
            if(risk_per_lot > 0)
               lot_raw = risk_money / risk_per_lot;
         }
         double strat_factor = CalcStratFactor(strategy, confidence);
         lot_raw *= strat_factor;
         result.lot = NormalizeLot(lot_raw, symbol, risk_usd);
         if(result.lot <= 0) return result;
         result.risk_pct_used = m_base_risk_pct * strat_factor;
         break;
      }

      case LOT_RISK_PCT:
      {
         // Full multi-factor (current default behavior)
         double risk_money   = m_account.Balance() * (m_base_risk_pct / 100.0);
         double tick_val     = m_symbol.TickValue();
         double tick_size    = m_symbol.TickSize();
         if(tick_size > 0 && tick_val > 0)
         {
            double risk_per_lot = (sl_dist / tick_size) * tick_val;
            if(risk_per_lot > 0)
               lot_raw = risk_money / risk_per_lot;
         }

         double kelly_factor = CalcKellyFactor();
         double macro_factor = CalcMacroFactor();
         double vol_factor   = CalcVolFactor();
         double liq_factor   = CalcLiqFactor();
         double dd_factor    = CalcDDFactor();
         double strat_factor = CalcStratFactor(strategy, confidence);

         double combined = kelly_factor * macro_factor * vol_factor *
                           liq_factor * dd_factor * strat_factor;

         lot_raw *= combined;

         result.lot = NormalizeLot(lot_raw, symbol, risk_usd);
         if(result.lot <= 0) return result;
         result.risk_pct_used = m_base_risk_pct * combined;
         break;
      }

      case LOT_FULL_KELLY:
      {
         // Kelly provides the base risk% instead of being a factor
         double kelly = CalcKellyFactor();
         double base_risk = m_base_risk_pct * kelly;
         double risk_money   = m_account.Balance() * (base_risk / 100.0);
         double tick_val     = m_symbol.TickValue();
         double tick_size    = m_symbol.TickSize();
         if(tick_size > 0 && tick_val > 0)
         {
            double risk_per_lot = (sl_dist / tick_size) * tick_val;
            if(risk_per_lot > 0)
               lot_raw = risk_money / risk_per_lot;
         }

         double macro_factor = CalcMacroFactor();
         double vol_factor   = CalcVolFactor();
         double liq_factor   = CalcLiqFactor();
         double dd_factor    = CalcDDFactor();
         double strat_factor = CalcStratFactor(strategy, confidence);

         double combined = macro_factor * vol_factor *
                           liq_factor * dd_factor * strat_factor;

         lot_raw *= combined;

         result.lot = NormalizeLot(lot_raw, symbol, risk_usd);
         if(result.lot <= 0) return result;
         result.risk_pct_used = base_risk * combined;
         break;
      }
   }

   //--- Step 8: Set SL/TP prices ---
   // Direction not known here - caller must set sl/tp based on entry
   // We return distances; caller applies to buy/sell
   result.sl             = sl_dist;
   result.tp             = tp_dist;
   result.be_distance    = be_dist;
   result.trail_distance = trail_dist;
   result.trail_step     = trail_step;
   result.risk_usd       = risk_usd;

   return result;
}
