//+------------------------------------------------------------------+
//|                                       ALX RM indicator v1.08.mq5 |
//|                                  Copyright 2026, ALXFund.        |
//|           Restaurado: Textos de Lucro (+21, +6) nos Retângulos   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXFund."
#property version   "1.08"
#property indicator_chart_window
#property indicator_buffers 4
#property indicator_plots   2

// Plot 1: Bullish Arrow
#property indicator_label1  "Bull Signal"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2

// Plot 2: Bearish Arrow
#property indicator_label2  "Bear Signal"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  2

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "===== Indicator Settings ====="
input int    MinRange            = 3;
input int    MaxRange            = 15;
input int    HighLowFilter       = 15;
input int    MaxHistoryBars      = 500;

input group "===== Backtest Engine Settings ====="
input bool   AdvancedStats       = true;
input int    SimulatedStopPips   = 50;
input bool   UseRealProfit       = false;

input group "===== Trade Analysis ====="
input bool   AnalysisEnabled     = true;
input bool   DisplayProfits      = true;           // Isso controla se mostra o "+21" dentro do box
input color  AnalysisColor       = clrMagenta;
input color  AnalysisLabel       = clrBlack;

input group "===== Arrow Settings ====="
input int    ArrowSize           = 2;
input color  ArrowUpCol          = clrLightSkyBlue;
input color  ArrowDnCol          = clrTomato;

input group "===== Text Settings ====="
input string UrFont              = "Tahoma";
input int    UrFontSize          = 7;
input color  UrFontCol           = clrLime;

input group "===== Drawing Boxes ====="
input color  BullRectangle       = clrTeal;
input color  BearRectangle       = clrCrimson;

input group "===== Alerts ====="
input string AlertCaption        = "DayTrading Alert";
input bool   DisplayAlerts       = true;
input bool   EmailAlerts         = false;
input bool   SoundAlerts         = true;
input bool   PushAlerts          = true;

#include "ALXPanel.mqh" CALXPanel m_painel;


//+------------------------------------------------------------------+
//| Backup inputs                                                    |
//+------------------------------------------------------------------+
bool     Verbose     = false;
string   SoundFile   = "alert.wav";



//+------------------------------------------------------------------+
//| Indicator Buffers                                                |
//+------------------------------------------------------------------+
double BufferBull[];
double BufferBear[];
double BufferSignalType[];
double BufferDirection[];

bool g_needRefresh = false;
int g_MinRange, g_MaxRange, g_HighLowFilter, g_MaxHistoryBars, g_StopPips;

//+------------------------------------------------------------------+
//| Backtest Stats Variables                                         |
//+------------------------------------------------------------------+
struct TradeStats
  {
   int               totalTrades;
   int               winTrades;
   int               lossTrades;
   double            grossProfit;
   double            grossLoss;
   double            totalMAE;
   double            totalMFE;
   double            maxDrawdown;
   double            currentEquityPeak;

   int               currentStreak;
   int               maxWinStreak;
   int               maxLossStreak;
   int               winsAfterWin;
   int               winsAfterLoss;
   int               totalPairs;
  };

TradeStats g_stats;

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
bool   g_initialized = false;
double g_pointValue;
double g_lastBullClose = 0.0;
double g_lastBearClose = 0.0;
int    g_lastBullTime = 0;
int    g_lastBearTime = 0;
datetime g_lastBarTime;
bool   g_firstRun = true;

double g_highestHigh;
double g_lowestLow = 0.0;
datetime g_highTime;
datetime g_lowTime = 0;

double g_lastSignalPrice = 0.0;
int    g_lastSignalTime = 0;
int    g_lastSignalDirection;

string g_prefix = "";
string g_lastSymbol = "";
ENUM_TIMEFRAMES g_lastTimeframe = PERIOD_CURRENT;
long g_lastChartID = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_prefix = "alx_ind_" + _Symbol;

   g_lastSymbol = _Symbol;
   g_lastTimeframe = Period();
   g_lastChartID = ChartID();

   SetIndexBuffer(0, BufferBull, INDICATOR_DATA);
   SetIndexBuffer(1, BufferBear, INDICATOR_DATA);
   SetIndexBuffer(2, BufferSignalType, INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, BufferDirection, INDICATOR_CALCULATIONS);

   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, ArrowUpCol);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, ArrowDnCol);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   ArraySetAsSeries(BufferBull, true);
   ArraySetAsSeries(BufferBear, true);
   ArraySetAsSeries(BufferSignalType, true);
   ArraySetAsSeries(BufferDirection, true);

   ArrayInitialize(BufferBull, EMPTY_VALUE);
   ArrayInitialize(BufferBear, EMPTY_VALUE);
   ArrayInitialize(BufferSignalType, 0);
   ArrayInitialize(BufferDirection, 0);

   ResetGlobals();
   ResetStats();

   IndicatorSetString(INDICATOR_SHORTNAME, "ALX RM Intraday v1.08");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   
   g_MinRange        = MinRange;
   g_MaxRange        = MaxRange;
   g_HighLowFilter   = HighLowFilter;
   g_MaxHistoryBars  = MaxHistoryBars;
   g_StopPips        = SimulatedStopPips;
   
   m_painel.Init("ALX Backtest Engine v1.08");


   CleanAllObjects();

   g_initialized = true;
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ResetStats()
  {
   g_stats.totalTrades = 0;
   g_stats.winTrades = 0;
   g_stats.lossTrades = 0;
   g_stats.grossProfit = 0;
   g_stats.grossLoss = 0;
   g_stats.totalMAE = 0;
   g_stats.totalMFE = 0;
   g_stats.maxDrawdown = 0;
   g_stats.currentEquityPeak = 0;
   g_stats.currentStreak = 0;
   g_stats.maxWinStreak = 0;
   g_stats.maxLossStreak = 0;
   g_stats.winsAfterWin = 0;
   g_stats.winsAfterLoss = 0;
   g_stats.totalPairs = 0;
  }

//+------------------------------------------------------------------+
//| Custom indicator iteration                                       |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
 if(!g_initialized)
      return 0;

   ArraySetAsSeries(time, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   // ✅ LÓGICA CORRIGIDA PARA LIMIT
   int limit;
   if(g_firstRun || prev_calculated == 0)
   {
      // Primeira execução ou refresh: processar histórico completo
      limit = rates_total - 2;
      if(limit < 1) limit = 1;
      if(limit > g_MaxHistoryBars) limit = g_MaxHistoryBars;
      
      if(g_firstRun)
      {
         // Limpeza apenas na primeira vez após refresh
         CleanAnalysisObjects();
         CleanDashboardObjects();
         ResetStats();
         g_firstRun = false;  // ← Desmarca após preparar
         Print("🔄 Recalculando ", limit, " barras com novos parâmetros...");
      }
   }
   else
   {
      // Execução normal: só processa barras novas
      limit = rates_total - prev_calculated;
      if(limit > g_MaxHistoryBars) limit = g_MaxHistoryBars;
   }

   // Proteção contra limite inválido
   if(limit <= 0) return rates_total;


   for(int i = limit; i >= 1; i--)
     {
      if(i >= rates_total)
         continue;

      double atr = CustomATR(_Symbol, PERIOD_CURRENT, 50, i);
      g_pointValue = atr / 100.0;

      BufferSignalType[i] = BufferSignalType[i + 1];
      BufferDirection[i] = EMPTY_VALUE;

      double highLevel = GetHighestHigh(i, g_HighLowFilter, high);
      double lowLevel = GetLowestLow(i, g_HighLowFilter, low);
      double currentClose = close[i];
      double signalStrength = 1;
      bool signalFound = false;

      for(int range = g_MinRange; range <= g_MaxRange; range++)
        {
         double rangeHigh = GetHighestHigh(i, range, high);
         double rangeLow = GetLowestLow(i, range, low);

         if(Verbose && !signalFound && IsBullishBreakout(i, range, open, high, low, close) && BufferSignalType[i] == 0.0 && (rangeHigh >= highLevel || high[i] >= highLevel))
           {
            if(DrawRectangle(i, range + 1, BullRectangle, false, false, time, high, low))
              {
               signalFound = true;
               break;
              }
           }
         if(Verbose && !signalFound && IsBearishBreakout(i, range, open, high, low, close) && BufferSignalType[i] == 1.0 && (rangeLow <= lowLevel || low[i] <= lowLevel))
           {
            if(DrawRectangle(i, range + 1, BearRectangle, false, false, time, high, low))
              {
               signalFound = true;
               break;
              }
           }

         if(!signalFound && IsBullishBreakout(i, range, open, high, low, close) && ((BufferSignalType[i] != 0.0) || (BufferSignalType[i] == 0.0 && g_lastBullClose > currentClose)) && (rangeLow <= lowLevel || low[i] <= lowLevel))
           {
            if(DrawRectangle(i, range + 1, BullRectangle, true, 1, time, high, low))
              {
               ResetHighLow();
               g_lastBullClose = currentClose;
               BufferDirection[i] = 0;
               BufferSignalType[i] = 0;
               signalFound = true;
               break;
              }
           }
         if(!signalFound && IsBearishBreakout(i, range, open, high, low, close) && ((BufferSignalType[i] != 1.0) || (BufferSignalType[i] == 1.0 && g_lastBearClose < currentClose)) && (rangeHigh >= highLevel || high[i] >= highLevel))
           {
            if(DrawRectangle(i, range + 1, BearRectangle, true, 1, time, high, low))
              {
               ResetHighLow();
               g_lastBearClose = currentClose;
               BufferDirection[i] = 1;
               BufferSignalType[i] = 1;
               signalFound = true;
               break;
              }
           }
         if(!signalFound && IsBullishAlt(i, range, open, high, low, close) && ((BufferSignalType[i] != 0.0) || (BufferSignalType[i] == 0.0 && g_lastBullClose > currentClose)) && (rangeLow <= lowLevel || low[i] <= lowLevel))
           {
            if(DrawRectangle(i, range + 1, BullRectangle, true, 1, time, high, low))
              {
               ResetHighLow();
               g_lastBullClose = currentClose;
               BufferDirection[i] = 0;
               BufferSignalType[i] = 0;
               signalFound = true;
               break;
              }
           }
         if(!signalFound && IsBearishAlt(i, range, open, high, low, close) && ((BufferSignalType[i] != 1.0) || (BufferSignalType[i] == 1.0 && g_lastBearClose < currentClose)) && (rangeHigh >= highLevel || high[i] >= highLevel))
           {
            if(DrawRectangle(i, range + 1, BearRectangle, true, 1, time, high, low))
              {
               ResetHighLow();
               g_lastBearClose = currentClose;
               BufferDirection[i] = 1;
               BufferSignalType[i] = 1;
               signalFound = true;
               break;
              }
           }
        }

      if(AnalysisEnabled)
         UpdateAnalysis(i, high, low, time);
     }

   if(g_lastBarTime != time[0])
     {
      if(BufferDirection[1] == 0.0 && !g_firstRun)
        {
         if(DisplayAlerts) { Alert("🟢 COMPRA " + _Symbol); }
         if(PushAlerts)    { SendNotification("🟢 COMPRA " + _Symbol); }
        }
      else
         if(BufferDirection[1] == 1.0 && !g_firstRun)
           {
            if(DisplayAlerts) { Alert("🔴 VENDA " + _Symbol); }
            if(PushAlerts)    { SendNotification("🔴 VENDA " + _Symbol); }
           }
      g_lastBarTime = time[0];
     }

   Dashboard();

   return rates_total;
  }

//+------------------------------------------------------------------+
//| Analysis Engine                                                  |
//+------------------------------------------------------------------+
void UpdateAnalysis(int shift, const double &high[], const double &low[], const datetime &time[])
  {
   if(high[shift] > g_highestHigh || g_highestHigh == 0.0)
     {
      g_highestHigh = high[shift];
      g_highTime = time[shift];
     }
   if(low[shift] < g_lowestLow || g_lowestLow == 0.0)
     {
      g_lowestLow = low[shift];
      g_lowTime = time[shift];
     }

   if(g_lastSignalTime > 0)
     {
      int signalBar = iBarShift(_Symbol, PERIOD_CURRENT, (datetime)g_lastSignalTime);
      if(signalBar > shift)
        {
         CheckTradeResult(shift, time, high, low);
        }
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CheckTradeResult(int currentShift, const datetime &time[], const double &high[], const double &low[])
  {
   int signalBar = iBarShift(_Symbol, PERIOD_CURRENT, (datetime)g_lastSignalTime);
   if(signalBar < 0)
      return;

   bool isWin = false;
   double profitPips = 0;
   double maePips = 0;
   double mfePips = 0;

   double minPrice = g_lastSignalPrice;
   double maxPrice = g_lastSignalPrice;

// Calcula o MAE e MFE até o candle atual
   for(int k = signalBar; k >= currentShift; k--)
     {
      if(k >= ArraySize(high))
         break;
      if(low[k] < minPrice)
         minPrice = low[k];
      if(high[k] > maxPrice)
         maxPrice = high[k];
     }

   int highBar = iBarShift(_Symbol, PERIOD_CURRENT, g_highTime);
   int lowBar = iBarShift(_Symbol, PERIOD_CURRENT, g_lowTime);

   if(highBar < 0 || lowBar < 0)
      return;

// Nome único para linha
   string lineName = g_prefix + "Line_" + TimeToString((datetime)g_lastSignalTime, TIME_SECONDS);
   int pips = 0;

   if(g_lastSignalDirection == 0)
     {
      // BUY
      if(g_highestHigh > high[signalBar])
        {
         isWin = true;
         pips = (int)MathAbs((g_highestHigh - g_lastSignalPrice) / _Point);
         profitPips = pips;

         // Desenha Linha e Texto (Restaurado)
         CreateTrendLine(lineName, (datetime)g_lastSignalTime, g_highTime, g_lastSignalPrice, g_highestHigh, AnalysisColor);
         DrawText("+" + IntegerToString(pips / 10), highBar, 1, AnalysisLabel, 25);
        }
      else
        {
         isWin = false;
         profitPips = (low[currentShift] - g_lastSignalPrice) / _Point;
        }
      maePips = (g_lastSignalPrice - minPrice) / _Point;
      mfePips = (maxPrice - g_lastSignalPrice) / _Point;
     }
   else
     {
      // SELL
      if(g_lowestLow < low[signalBar])
        {
         isWin = true;
         pips = (int)MathAbs((g_lastSignalPrice - g_lowestLow) / _Point);
         profitPips = pips;

         // Desenha Linha e Texto (Restaurado)
         CreateTrendLine(lineName, (datetime)g_lastSignalTime, g_lowTime, g_lastSignalPrice, g_lowestLow, AnalysisColor);
         DrawText("+" + IntegerToString(pips / 10), lowBar, 0, AnalysisLabel, 5);
        }
      else
        {
         isWin = false;
         profitPips = (g_lastSignalPrice - high[currentShift]) / _Point;
        }
      maePips = (minPrice - g_lastSignalPrice) / _Point;
      mfePips = (g_lastSignalPrice - maxPrice) / _Point;
     }

   g_stats.totalTrades++;
   g_stats.totalMAE += maePips;
   g_stats.totalMFE += mfePips;

   if(isWin)
     {
      g_stats.winTrades++;
      g_stats.grossProfit += profitPips;

      if(g_stats.currentStreak > 0)
        {
         g_stats.winsAfterWin++;
         g_stats.currentStreak++;
        }
      else
        {
         g_stats.winsAfterLoss++;
         g_stats.currentStreak = 1;
        }

      if(g_stats.currentStreak > g_stats.maxWinStreak)
         g_stats.maxWinStreak = g_stats.currentStreak;
     }
   else
     {
      g_stats.lossTrades++;
      g_stats.grossLoss += MathAbs(profitPips);

      g_stats.currentEquityPeak += (g_stats.currentStreak > 0) ? (g_stats.currentStreak * 10) : 0;

      if(g_stats.currentStreak < 0)
         g_stats.currentStreak--;
      else
         g_stats.currentStreak = -1;

      if(MathAbs(g_stats.currentStreak) > g_stats.maxLossStreak)
         g_stats.maxLossStreak = MathAbs(g_stats.currentStreak);
     }

   if(g_stats.totalTrades > 1)
      g_stats.totalPairs = g_stats.totalTrades - 1;
   g_lastSignalTime = 0;
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void Dashboard()
  {
   if(!AnalysisEnabled || !AdvancedStats)
      return;

   CleanDashboardObjects();

   uint rs   = 18;
   uint row1 = 30;
   uint col1 = 15, col2 = 120;

   double total   = g_stats.winTrades + g_stats.lossTrades;
   double winrate = (total > 0) ? (g_stats.winTrades / total) * 100 : 0;

   double pf = (g_stats.grossLoss > 0) ? (g_stats.grossProfit / g_stats.grossLoss) : (g_stats.grossProfit > 0 ? 99.9 : 0);
   double avgWin = (g_stats.winTrades > 0) ? (g_stats.grossProfit / g_stats.winTrades) : 0;
   double avgLoss = (g_stats.lossTrades > 0) ? (g_stats.grossLoss / g_stats.lossTrades) : 0;
   double expectancy = (total > 0) ? ((winrate/100 * avgWin) - ((100-winrate)/100 * avgLoss)) : 0;

   double avgMAE = (total > 0) ? (g_stats.totalMAE / total) : 0;
   double avgMFE = (total > 0) ? (g_stats.totalMFE / total) : 0;
   double rrr = (avgMAE > 0) ? (avgMFE / avgMAE) : 0;

   double zScore = 0;
   if(g_stats.totalPairs > 0)
     {
      double n = g_stats.totalPairs;
      double p = g_stats.winTrades / (double)total;
      if(p > 0 && p < 1)
         zScore = (g_stats.totalTrades * (2*p - 1)) / MathSqrt(g_stats.totalTrades * 4 * p * (1-p));
     }

   ALXLabel("title",    col1, row1,          10, "ALX Backtest Engine v1.08",  clrBlack);
   ALXLabel("sep1",     col1, row1 + rs,     8,  "────────────────────────────",  clrDimGray);

   ALXLabel("wr_lbl",   col1, row1 + rs*2,   8,  "Winrate:",  clrBlack);
   ALXLabel("wr_val",   col2, row1 + rs*2,   8,  DoubleToString(winrate, 1) + "%",  clrTeal);

   ALXLabel("pf_lbl",   col1, row1 + rs*3,   8,  "Profit Factor:",  clrBlack);
   ALXLabel("pf_val",   col2, row1 + rs*3,   8,  DoubleToString(pf, 2), (pf >= 1.5 ? clrTeal : (pf >= 1.0 ? clrOrange : clrCrimson)));

   ALXLabel("exp_lbl",  col1, row1 + rs*4,   8,  "Expectancy (pips):",  clrBlack);
   ALXLabel("exp_val",  col2, row1 + rs*4,   8,  DoubleToString(expectancy, 1), (expectancy > 0 ? clrTeal : clrRed));

   ALXLabel("rrr_lbl",  col1, row1 + rs*5,   8,  "Est. RRR (Risk:Rew):",       clrBlack);
   ALXLabel("rrr_val",  col2, row1 + rs*5,   8,  "1:" + DoubleToString(rrr, 2), (rrr >= 1.5 ? clrTeal : clrOrange));

   ALXLabel("z_lbl",    col1, row1 + rs*6,   8,  "Z-Score:",                    clrBlack);
   ALXLabel("z_val",    col2, row1 + rs*6,   8,  DoubleToString(zScore, 2), (zScore > 1.96 ? clrTeal : clrGray));

   ALXLabel("streak_lbl",col1, row1 + rs*7,  8,  "Max Streak (W/L):",          clrBlack);
   ALXLabel("streak_val",col2, row1 + rs*7,  8,  IntegerToString(g_stats.maxWinStreak) + " / " + IntegerToString(g_stats.maxLossStreak), clrBlack);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ResetGlobals()
  {
   g_highestHigh = 0;
   g_lowestLow = 0;
   g_highTime = 0;
   g_lowTime = 0;
   g_lastBullClose = 0;
   g_lastBearClose = 0;
   g_lastBullTime = 0;
   g_lastBearTime = 0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ResetHighLow()
  {
   g_highestHigh = 0;
   g_lowestLow = 0;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetHighestHigh(int shift, int period, const double &high[])
  {
   int maxBar = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, period, shift + 1);
   if(maxBar < 0 || maxBar >= ArraySize(high))
      return 0;
   return high[maxBar];
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetLowestLow(int shift, int period, const double &low[])
  {
   int minBar = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, period, shift + 1);
   if(minBar < 0 || minBar >= ArraySize(low))
      return 0;
   return low[minBar];
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsBullish(int shift, const double &open[], const double &close[]) { return close[shift] > open[shift]; }
bool IsBearish(int shift, const double &open[], const double &close[]) { return close[shift] < open[shift]; }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsBullishBreakout(int shift, int range, const double &open[], const double &high[], const double &low[], const double &close[])
  {
   double rangeHigh = GetHighestHigh(shift, range, high);
   int compareBar = shift + range + 1;
   if(compareBar >= ArraySize(open))
      return false;
   return IsBullish(shift, open, close) && close[shift] > rangeHigh && open[shift] < close[compareBar] && close[shift] > high[compareBar];
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsBearishBreakout(int shift, int range, const double &open[], const double &high[], const double &low[], const double &close[])
  {
   double rangeLow = GetLowestLow(shift, range, low);
   int compareBar = shift + range + 1;
   if(compareBar >= ArraySize(open))
      return false;
   return IsBearish(shift, open, close) && close[shift] < rangeLow && open[shift] > close[compareBar] && close[shift] < low[compareBar];
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsBullishAlt(int shift, int range, const double &open[], const double &high[], const double &low[], const double &close[])
  {
   double rangeHigh = GetHighestHigh(shift, range, high);
   int compareBar = shift + range + 1;
   if(compareBar >= ArraySize(open))
      return false;
   return IsBullish(shift, open, close) && close[shift] > rangeHigh && IsBearish(compareBar, open, close);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsBearishAlt(int shift, int range, const double &open[], const double &high[], const double &low[], const double &close[])
  {
   double rangeLow = GetLowestLow(shift, range, low);
   int compareBar = shift + range + 1;
   if(compareBar >= ArraySize(open))
      return false;
   return IsBearish(shift, open, close) && close[shift] < rangeLow && IsBullish(compareBar, open, close);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool DrawRectangle(int shift, int period, color rectColor, bool analyze, double strength, const datetime &time[], const double &high[], const double &low[])
  {
   if(shift + period >= ArraySize(time))
      return false;
   datetime startTime = time[shift];
   datetime endTime = time[shift + period - 1];
   string name = g_prefix + "Rect_" + IntegerToString(period) + "_" + TimeToString(startTime, TIME_SECONDS);
   if(ObjectFind(0, name) >= 0)
      return false;
   if((rectColor == BullRectangle && endTime <= g_lastBearTime) || endTime >= startTime)
      return false;
   if((rectColor == BearRectangle && endTime <= g_lastBullTime) || endTime >= startTime)
      return false;

   int endShift = shift + period;
   if(endShift >= ArraySize(high))
      return false;
   int maxBar = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, period - 1, shift + 1);
   int minBar = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, period - 1, shift + 1);
   if(maxBar < 0 || minBar < 0)
      return false;
   double rangeHigh = high[maxBar];
   double rangeLow = low[minBar];

   ObjectCreate(0, name, OBJ_RECTANGLE, 0, startTime, rangeLow, endTime, rangeHigh);
   ObjectSetInteger(0, name, OBJPROP_COLOR, rectColor);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);

   if(rectColor == BullRectangle)
     {
      BufferBull[shift] = rangeLow;
      g_lastBearTime = (int)endTime;
      if(analyze)
        {
         g_lastSignalTime = (int)startTime;
         g_lastSignalPrice = low[shift];
         g_lastSignalDirection = 0;
        }
     }
   else
     {
      BufferBear[shift] = rangeHigh;
      g_lastBullTime = (int)endTime;
      if(analyze)
        {
         g_lastSignalTime = (int)startTime;
         g_lastSignalPrice = high[shift];
         g_lastSignalDirection = 1;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawText(string text, int shift, int direction, color clr, int offset)
  {
   if(!DisplayProfits)
      return;
   if(shift < 0)
      return;

   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, shift);
   if(barTime == 0)
      return;

   double price;
   if(direction == 0)
      price = iLow(_Symbol, PERIOD_CURRENT, shift) - g_pointValue * offset;
   else
      price = iHigh(_Symbol, PERIOD_CURRENT, shift) + g_pointValue * offset;

   string name = g_prefix + "Text_" + text + "_" + TimeToString(barTime, TIME_SECONDS);

   if(ObjectFind(0, name) >= 0)
      return;

   ObjectCreate(0, name, OBJ_TEXT, 0, barTime, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, UrFont);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, UrFontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CreateTrendLine(string name, datetime time1, datetime time2,
                     double price1, double price2, color clr)
  {
   if(StringFind(name, g_prefix) < 0)
      name = g_prefix + "Line_" + TimeToString(time1, TIME_SECONDS);

   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);

   ObjectCreate(0, name, OBJ_TREND, 0, time1, price1, time2, price2);
   ObjectSetInteger(0, name, OBJPROP_RAY, false);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void ALXLabel(string name, uint x, int y, int fontsize, string msg, color clr)
  {
   string obj = g_prefix + "Lbl_" + name;
   if(ObjectFind(0, obj) < 0)
     {
      ObjectCreate(0, obj, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, obj, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, obj, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, obj, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE, fontsize);
      ObjectSetString(0, obj, OBJPROP_FONT, "Trebuchet MS");
     }
   ObjectSetString(0, obj, OBJPROP_TEXT, msg);
   ObjectSetInteger(0, obj, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CleanAllObjects()
  {
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i);
      if(StringFind(name, g_prefix) == 0)
         ObjectDelete(0, name);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CleanDashboardObjects()
  {
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i);
      if(StringFind(name, g_prefix + "Lbl_") == 0)
         ObjectDelete(0, name);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CleanAnalysisObjects()
  {
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i);
      if(StringFind(name, g_prefix + "Line") == 0 || StringFind(name, g_prefix + "Text") == 0)
         ObjectDelete(0, name);
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CustomATR(string symbol, ENUM_TIMEFRAMES tf, int period, int shift)
  {
   static int handle = INVALID_HANDLE;
   static int lastPeriod = -1;
   static ENUM_TIMEFRAMES lastTf = PERIOD_CURRENT;
   static string lastSymbol = "";
   if(handle == INVALID_HANDLE || lastPeriod != period || lastTf == tf || lastSymbol == symbol)
     {
      if(handle != INVALID_HANDLE)
         IndicatorRelease(handle);
      handle = iATR(symbol, tf, period);
      if(handle == INVALID_HANDLE)
         return 0.0;
      lastPeriod = period;
      lastTf = tf;
      lastSymbol = symbol;
     }
   double atrBuffer[];
   if(CopyBuffer(handle, 0, shift, 1, atrBuffer) <= 0)
      return 0.0;
   return atrBuffer[0];
  }

//+------------------------------------------------------------------+
//| Chart event function - VERSÃO CORRIGIDA                         |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Print para debug (pode remover depois)
   // Print("📊 [INDICADOR] OnChartEvent! id=", id, " lparam=", lparam, " sparam='", sparam, "'");
   
   // ✅ PRIMEIRO chamar o painel para processar eventos de UI
   m_painel.ChartEvent(id, lparam, dparam, sparam);
   
   // ✅ VERIFICAÇÃO CORRIGIDA: custom_id vem em (id - CHARTEVENT_CUSTOM)
   int customId = id - CHARTEVENT_CUSTOM;
   
   if(id >= CHARTEVENT_CUSTOM && customId == 1001)
   {
      Print("🔄 [INDICADOR] Evento 1001 recebido! Executando refresh...");
      
      // Atualizar variáveis dos SpinEdits
      g_MinRange       = (int)m_painel.m_spns[0].Value();
      g_MaxRange       = (int)m_painel.m_spns[1].Value();
      g_HighLowFilter  = (int)m_painel.m_spns[2].Value();
      g_MaxHistoryBars = (int)m_painel.m_spns[3].Value();
      g_StopPips       = (int)m_painel.m_spns[4].Value();
      
      // Validar relação Min/Max
      if(g_MaxRange < g_MinRange) 
         g_MaxRange = g_MinRange;
      
      Print("📊 Novos valores: Min=", g_MinRange, " Max=", g_MaxRange, " H/L=", g_HighLowFilter);
      
      // Limpar objetos visuais antigos
      CleanAnalysisObjects();
      CleanDashboardObjects();
      
      // Resetar buffers PARA RECALCULAR COM NOVOS PARÂMETROS
      ArrayInitialize(BufferBull, EMPTY_VALUE);
      ArrayInitialize(BufferBear, EMPTY_VALUE);
      ArrayInitialize(BufferSignalType, 0);
      ArrayInitialize(BufferDirection, 0);
      
      // Resetar estado do indicador
      ResetGlobals();
      ResetStats();
      
      // Forçar recálculo completo
      g_firstRun = true;
      g_lastBarTime = 0;
      
      // Atualizar visualização
      ChartRedraw();
      
      Print("✅ Refresh concluído! Indicador recalculado com novos parâmetros.");
   }
}

/*
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   m_painel.ChartEvent(id, lparam, dparam, sparam);
   if(id == CHARTEVENT_CUSTOM && lparam == 1001)
     {
      Print("Reinicializando indicador...");

      g_firstRun = true;     // FORÇA REPROCESSAMENTO
      ResetGlobals();
      ResetStats();
     
      ObjectsDeleteAll(0, g_prefix);
      ChartRedraw();
     }
  }
*/
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   m_painel.Destroy(reason);
   CleanAllObjects();
  }
///=================================================
