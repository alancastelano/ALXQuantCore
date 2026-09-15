//+------------------------------------------------------------------+
//|                                                        enums.mqh |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
    v.7.13 - 2026-08-01 - Change: TRAIL_ATR comentário p/ "Follow StopATR band".
    v.7.14 - 2026-08-07 - Change: enLotMode unificado como fonte única (4 membros, lot_fix→lot_fixed + lot_min).
    v.7.15 - 2026-08-13 - Change: enLotMode removido (dono agora é Modules\Execution.mqh) p/ evitar redeclaração.
*/

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
enum enDirection
  {
   all_direction  = 0,     // All direction
   buy_only       = 1,     // Buy only
   sell_only      = 2,     // Sell only
  };

enum enRiskMode
{
   Conservative,  // Conservative
   Moderate,      // Moderate
   Aggressive,    // Aggressive
   Manual         // Manual (Lot fix)
};

//--- Position Sizing enums ---
enum ENUM_ALX_SL_MODE
{
   SL_FIXED,       // Fixed pips
   SL_ATR          // ATR multiple
};

enum ENUM_ALX_TP_MODE
{
   TP_RISK_REWARD, // R:R ratio
   TP_FIXED,       // Fixed pips
   TP_ATR,         // ATR multiple
   TP_ADR          // ADR multiple
};

enum ENUM_ALX_BE_MODE
{
   BE_FIXED,       // Fixed pips
   BE_ATR          // ATR multiple
};

enum ENUM_ALX_TRAIL_MODE
{
   TRAIL_FIXED,    // Fixed pips
   TRAIL_ATR       // Follow StopATR band
};

enum ENUM_ALX_STRATEGY
{
   STRAT_TREND,        // Trend Following
   STRAT_BREAKOUT,     // Breakout
   STRAT_MEAN_REV,     // Mean Reversion
   STRAT_SESSION,      // Session Breakout
   STRAT_SCALP         // Scalping
};

//--- Lot Mode ---
enum ENUM_ALX_LOT_MODE2
{
   LOT_FIXED,       // Fixed lot (InpLotValue = lot size)
   LOT_BALANCE,     // Lot per $1000 (InpLotValue = lot per $1000)
   LOT_RISK,        // % of capital (InpLotValue = % risk per trade)
   LOT_RISK_PCT,    // % risk per trade (PositionSizing)
   LOT_FULL_KELLY   // Full Kelly Criterion (PositionSizing)
};

//+------------------------------------------------------------------+
