//+------------------------------------------------------------------+
//|                                       ALX RM indicator v1.00.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXFund."
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 5
#property indicator_plots   3

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

// Plot 3: Failed Signal
#property indicator_label3  "Failed"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrRed
#property indicator_width3  1

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "===== Indicator Settings ====="
input bool   Verbose         = false;  // Modo Verboso (mostra retângulos mesmo em sinais repetidos)
input int    MinRange        = 5;// Range mínimo (em barras) para detectar breakout
input int    MaxRange        = 30;// Range máximo (em barras) para detectar breakout
input int    HighLowFilter   = 10;// Período usado para calcular o High/Low de referência
input int    MaxHistoryBars  = 500;// Máximo de barras históricas a processar (performance)

input group "===== Trade Analysis ====="
input bool   AnalysisEnabled = true;   // Ativar análise de performance dos sinais
input bool   DisplayProfits  = true;// Mostrar lucros/perdas em pips nos gráficos
input color  AnalysisColor   = clrMagenta;// Cor das linhas de resultado
input color  AnalysisLabel   = clrAqua;// Cor dos textos de pips

input group "===== Arrow Settings ====="
input int    ArrowSize       = 2;
input color  ArrowUpCol      = clrLightSkyBlue;
input color  ArrowDnCol      = clrTomato;

input group "===== Text Settings ====="
input string UrFont          = "Tahoma";
input int    UrFontSize      = 7;
input color  UrFontCol       = clrLime;

input group "===== Drawing Boxes ====="
input color  BullRectangle   = clrLightSkyBlue;
input color  BearRectangle   = clrTomato;

input group "===== Alerts ====="
input string AlertCaption    = "DayTrading Alert";
input bool   DisplayAlerts   = true;
input bool   EmailAlerts     = false;
input bool   SoundAlerts     = true;
input bool   PushAlerts      = true;
input string SoundFile       = "alert.wav";

//+------------------------------------------------------------------+
//| Indicator Buffers                                                |
//+------------------------------------------------------------------+
double BufferBull[];        // Bullish arrows
double BufferBear[];        // Bearish arrows
double BufferFailed[];      // Failed signals
double BufferSignalType[];  // Signal type (0=bull, 1=bear)
double BufferDirection[];   // Direction tracker

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

int    g_winCount = 0;
int    g_loseCount = 0;
int    g_totalPips;
int    g_signalCount = 0;
double g_lastSignalPrice = 0.0;
int    g_lastSignalTime = 0;

//+------------------------------------------------------------------+
//| Custom indicator initialization                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set buffer arrays
   SetIndexBuffer(0, BufferBull, INDICATOR_DATA);
   SetIndexBuffer(1, BufferBear, INDICATOR_DATA);
   SetIndexBuffer(2, BufferFailed, INDICATOR_DATA);
   SetIndexBuffer(3, BufferSignalType, INDICATOR_CALCULATIONS);
   SetIndexBuffer(4, BufferDirection, INDICATOR_CALCULATIONS);
   
   // Set arrow codes
   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetInteger(2, PLOT_ARROW, 108); // Stop sign
   
   // Set arrow colors
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, ArrowUpCol);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, ArrowDnCol);
   
   // Set empty values
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   
   // Initialize arrays
   ArraySetAsSeries(BufferBull, true);
   ArraySetAsSeries(BufferBear, true);
   ArraySetAsSeries(BufferFailed, true);
   ArraySetAsSeries(BufferSignalType, true);
   ArraySetAsSeries(BufferDirection, true);
   
   // Initialize buffers
   ArrayInitialize(BufferBull, EMPTY_VALUE);
   ArrayInitialize(BufferBear, EMPTY_VALUE);
   ArrayInitialize(BufferFailed, EMPTY_VALUE);
   ArrayInitialize(BufferSignalType, 0);
   ArrayInitialize(BufferDirection, 0);
   
   // Reset global variables
   ResetGlobals();
   
   // Set indicator name
   IndicatorSetString(INDICATOR_SHORTNAME, "Day Trading H1");
   
   // Set digits
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   
   // Clean old objects
   CleanOldObjects();
   
   g_initialized = true;
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   CleanOldObjects();
   Comment("");
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
   if(!g_initialized) return 0;
   
   // Set arrays as series
   ArraySetAsSeries(time, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int limit;
   if(prev_calculated == 0)
   {
      limit = rates_total - 2;
      if(limit > MaxHistoryBars) limit = MaxHistoryBars;
   }
   else
   {
      limit = rates_total - prev_calculated + 1;
   }
   
   // Calculate indicator
   for(int i = limit; i >= 1; i--)
   {
      if(i > MaxHistoryBars) continue;
      
      double highLevel = GetHighestHigh(i, HighLowFilter, high);
      double lowLevel = GetLowestLow(i, HighLowFilter, low);
      
      double atr = CustomATR(_Symbol, PERIOD_CURRENT, 50, i);
      g_pointValue = atr / 100.0;
      
      // Copy previous signal type
      BufferSignalType[i] = BufferSignalType[i + 1];
      BufferDirection[i] = EMPTY_VALUE;
      
      double currentClose = close[i];
      double signalStrength = 1;
      
      // Scan for signals
      for(int range = MinRange; range <= MaxRange; range++)
      {
         double rangeHigh = GetHighestHigh(i, range, high);
         double rangeLow = GetLowestLow(i, range, low);
         
         // Bullish breakout (verbose mode)
         if(IsBullishBreakout(i, range, open, high, low, close) && 
            Verbose && 
            BufferSignalType[i] == 0.0 && 
            (rangeHigh >= highLevel || high[i] >= highLevel))
         {
            if(DrawRectangle(i, range + 1, BullRectangle, false, false, time, high, low))
            {
               BufferDirection[i] = 0;
               BufferSignalType[i] = 0;
               break;
            }
         }
         
         // Bearish breakout (verbose mode)
         if(IsBearishBreakout(i, range, open, high, low, close) && 
            Verbose && 
            BufferSignalType[i] == 1.0 && 
            (rangeLow <= lowLevel || low[i] <= highLevel))
         {
            if(DrawRectangle(i, range + 1, BearRectangle, false, false, time, high, low))
            {
               BufferDirection[i] = 1;
               BufferSignalType[i] = 1;
               break;
            }
         }
         
         // Bullish signal (standard)
         if(IsBullishBreakout(i, range, open, high, low, close) && 
            ((BufferSignalType[i] != 0.0) || (BufferSignalType[i] == 0.0 && g_lastBullClose > currentClose)) &&
            (rangeLow <= lowLevel || low[i] <= highLevel))
         {
            if(BufferSignalType[i] == 0.0 && g_lastBullClose > currentClose)
               signalStrength = 0;
            else
               signalStrength = 1;
            
            if(DrawRectangle(i, range + 1, BullRectangle, true, signalStrength, time, high, low))
            {
               ResetHighLow();
               g_lastBullClose = currentClose;
               BufferDirection[i] = 0;
               BufferSignalType[i] = 0;
               break;
            }
         }
         
         // Bearish signal (standard)
         if(IsBearishBreakout(i, range, open, high, low, close) && 
            ((BufferSignalType[i] != 1.0) || (BufferSignalType[i] == 1.0 && g_lastBearClose < currentClose)) &&
            (rangeHigh >= highLevel || high[i] >= highLevel))
         {
            if(BufferSignalType[i] == 1.0 && g_lastBearClose < currentClose)
               signalStrength = 0;
            else
               signalStrength = 1;
            
            if(DrawRectangle(i, range + 1, BearRectangle, true, signalStrength, time, high, low))
            {
               ResetHighLow();
               g_lastBearClose = currentClose;
               BufferDirection[i] = 1;
               BufferSignalType[i] = 1;
               break;
            }
         }
         
         // Alternative bullish pattern
         if(IsBullishAlt(i, range, open, high, low, close) && 
            ((BufferSignalType[i] != 0.0) || (BufferSignalType[i] == 0.0 && g_lastBullClose > currentClose)) &&
            (rangeLow <= lowLevel || low[i] <= highLevel))
         {
            if(BufferSignalType[i] == 0.0 && g_lastBullClose > currentClose)
               signalStrength = 0;
            else
               signalStrength = 1;
            
            if(DrawRectangle(i, range + 1, BullRectangle, true, signalStrength, time, high, low))
            {
               ResetHighLow();
               g_lastBullClose = currentClose;
               BufferDirection[i] = 0;
               BufferSignalType[i] = 0;
               break;
            }
         }
         
         // Alternative bearish pattern
         if(IsBearishAlt(i, range, open, high, low, close) && 
            ((BufferSignalType[i] != 1.0) || (BufferSignalType[i] == 1.0 && g_lastBearClose < currentClose)) &&
            (rangeHigh >= highLevel || high[i] >= highLevel))
         {
            if(BufferSignalType[i] == 1.0 && g_lastBearClose < currentClose)
               signalStrength = 0;
            else
               signalStrength = 1;
            
            if(DrawRectangle(i, range + 1, BearRectangle, true, signalStrength, time, high, low))
            {
               ResetHighLow();
               g_lastBearClose = currentClose;
               BufferDirection[i] = 1;
               BufferSignalType[i] = 1;
               break;
            }
         }
      }
      
      // Update analysis
      if(AnalysisEnabled)
         UpdateAnalysis(i, high, low, time);
   }
   
   // Check for new bar alerts
   if(g_lastBarTime != time[0])
   {
      if(BufferDirection[1] == 0.0 && !g_firstRun)
      {
         if(DisplayAlerts) Alert("RM Day Trading (" + AlertCaption + ") [" + _Symbol + "] Bullish Breakout");
         if(EmailAlerts) SendMail("RM Day Trading (" + AlertCaption + ") [" + _Symbol + "]", "[" + _Symbol + "] Bullish Breakout");
         if(SoundAlerts) PlaySound(SoundFile);
         if(PushAlerts) SendNotification("Bullish Breakout " + _Symbol);
      }
      else if(BufferDirection[1] == 1.0 && !g_firstRun)
      {
         if(DisplayAlerts) Alert("RM Day Trading (" + AlertCaption + ") [" + _Symbol + "] Bearish Breakout");
         if(EmailAlerts) SendMail("RM Day Trading (" + AlertCaption + ") [" + _Symbol + "]", "[" + _Symbol + "] Bearish Breakout");
         if(SoundAlerts) PlaySound(SoundFile);
         if(PushAlerts) SendNotification("Bearish Breakout " + _Symbol);
      }
      
      g_lastBarTime = time[0];
      g_firstRun = false;
   }
   
   // Update comment
   UpdateComment();
   
   return rates_total;
}

//+------------------------------------------------------------------+
//| Helper Functions                                                 |
//+------------------------------------------------------------------+

// Reset global variables
void ResetGlobals()
{
   g_highestHigh = 0;
   g_lowestLow = 0;
   g_highTime = 0;
   g_lowTime = 0;
   g_winCount = 0;
   g_loseCount = 0;
   g_totalPips = 0;
   g_signalCount = 0;
   g_lastBullClose = 0;
   g_lastBearClose = 0;
   g_lastBullTime = 0;
   g_lastBearTime = 0;
   g_lastSignalPrice = 0.0;
   g_lastSignalTime = 0;
}

// Reset high/low tracking
void ResetHighLow()
{
   g_highestHigh = 0;
   g_lowestLow = 0;
}

// Get highest high
double GetHighestHigh(int shift, int period, const double &high[])
{
   int maxBar = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, period, shift + 1);
   return high[maxBar];
}

// Get lowest low
double GetLowestLow(int shift, int period, const double &low[])
{
   int minBar = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, period, shift + 1);
   return low[minBar];
}

// Check if bullish candle
bool IsBullish(int shift, const double &open[], const double &close[])
{
   return close[shift] > open[shift];
}

// Check if bearish candle
bool IsBearish(int shift, const double &open[], const double &close[])
{
   return close[shift] < open[shift];
}

// Bullish breakout pattern
bool IsBullishBreakout(int shift, int range, const double &open[], const double &high[], 
                       const double &low[], const double &close[])
{
   double rangeHigh = GetHighestHigh(shift, range, high);
   
   return IsBullish(shift, open, close) && 
          close[shift] > rangeHigh && 
          open[shift] < close[shift + range + 1] && 
          close[shift] > high[shift + range + 1];
}

// Bearish breakout pattern
bool IsBearishBreakout(int shift, int range, const double &open[], const double &high[], 
                       const double &low[], const double &close[])
{
   double rangeLow = GetLowestLow(shift, range, low);
   
   return IsBearish(shift, open, close) && 
          close[shift] < rangeLow && 
          open[shift] > close[shift + range + 1] && 
          close[shift] < low[shift + range + 1];
}

// Alternative bullish pattern
bool IsBullishAlt(int shift, int range, const double &open[], const double &high[], 
                  const double &low[], const double &close[])
{
   double rangeHigh = GetHighestHigh(shift, range, high);
   
   return IsBullish(shift, open, close) && 
          close[shift] > rangeHigh && 
          IsBearish(shift + range + 1, open, close);
}

// Alternative bearish pattern
bool IsBearishAlt(int shift, int range, const double &open[], const double &high[], 
                  const double &low[], const double &close[])
{
   double rangeLow = GetLowestLow(shift, range, low);
   
   return IsBearish(shift, open, close) && 
          close[shift] < rangeLow && 
          IsBullish(shift + range + 1, open, close);
}

// Draw rectangle
bool DrawRectangle(int shift, int period, color rectColor, bool analyze, double strength,
                   const datetime &time[], const double &high[], const double &low[])
{
   datetime startTime = time[shift];
   datetime endTime = time[shift + period - 1];
   
   string name = "RMDT_Rect-" + IntegerToString(period) + TimeToString(endTime);
   
   // Check time validity
   if((rectColor == BullRectangle && endTime <= g_lastBearTime) || endTime > startTime)
      return false;
   if((rectColor == BearRectangle && endTime <= g_lastBullTime) || endTime > startTime)
      return false;
   
   // Analysis
   if(AnalysisEnabled && strength > 0 && g_lastSignalTime > 0 && g_lastSignalPrice > 0.0)
   {
      AnalyzeSignal(shift, rectColor, time, high, low);
   }
   
   // Update signal tracking
   if(AnalysisEnabled && analyze)
   {
      g_lastSignalTime = (int)startTime;
      g_lastSignalPrice = (rectColor == BullRectangle) ? low[shift] : high[shift];
   }
   
   // Get range high/low
   int endShift = shift + period;
   int maxBar = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, period - 1, shift + 1);
   int minBar = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, period - 1, shift + 1);
   
   double rangeHigh = high[maxBar];
   double rangeLow = low[minBar];
   
   // Create rectangle
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, startTime, rangeLow, endTime, rangeHigh);
   ObjectSetInteger(0, name, OBJPROP_COLOR, rectColor);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   
   // Set arrow
   if(rectColor == BullRectangle)
   {
      BufferBull[shift] = rangeLow;
      g_lastBearTime = (int)endTime;
   }
   else
   {
      BufferBear[shift] = rangeHigh;
      g_lastBullTime = (int)endTime;
   }
   
   g_signalCount++;
   
   return true;
}

// Analyze signal performance
void AnalyzeSignal(int shift, color rectColor, const datetime &time[], 
                   const double &high[], const double &low[])
{
   int signalBar = iBarShift(_Symbol, PERIOD_CURRENT, (datetime)g_lastSignalTime);
   int highBar = iBarShift(_Symbol, PERIOD_CURRENT, g_highTime);
   int lowBar = iBarShift(_Symbol, PERIOD_CURRENT, g_lowTime);
   
   string lineName = "RMDT_Rect-" + TimeToString((datetime)g_lastSignalTime) + "-res";
   int pips = 0;
   
   if(BufferSignalType[shift] == 0.0) // Bullish
   {
      if(g_highestHigh > high[signalBar])
      {
         pips = (int)MathAbs((g_highestHigh - g_lastSignalPrice) / _Point);
         
         // Draw result line
         CreateTrendLine(lineName, (datetime)g_lastSignalTime, g_highTime, 
                        g_lastSignalPrice, g_highestHigh, AnalysisColor);
         
         // Draw profit label
         DrawText("+" + IntegerToString(pips / 10), highBar, 1, AnalysisLabel, 25);
         
         g_totalPips += pips / 10;
         g_winCount++;
      }
      else
      {
         BufferFailed[signalBar] = high[signalBar];
         g_loseCount++;
      }
   }
   else // Bearish
   {
      if(g_lowestLow < low[signalBar])
      {
         pips = (int)MathAbs((g_lastSignalPrice - g_lowestLow) / _Point);
         
         // Draw result line
         CreateTrendLine(lineName, (datetime)g_lastSignalTime, g_lowTime, 
                        g_lastSignalPrice, g_lowestLow, AnalysisColor);
         
         // Draw profit label
         DrawText("+" + IntegerToString(pips / 10), lowBar, 0, AnalysisLabel, 5);
         
         g_totalPips += pips / 10;
         g_winCount++;
      }
      else
      {
         BufferFailed[signalBar] = low[signalBar];
         g_loseCount++;
      }
   }
}

// Update analysis tracking
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
}

// Draw text label
void DrawText(string text, int shift, int direction, color clr, int offset)
{
   if(!DisplayProfits) return;
   
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, shift);
   datetime prevTime = iTime(_Symbol, PERIOD_CURRENT, shift + 1);
   
   double price;
   if(direction == 0)
      price = iLow(_Symbol, PERIOD_CURRENT, shift) - g_pointValue * offset;
   else
      price = iHigh(_Symbol, PERIOD_CURRENT, shift) + g_pointValue * offset;
   
   string name = "RMDT-" + text + "-" + TimeToString(prevTime);
   
   ObjectCreate(0, name, OBJ_TEXT, 0, barTime, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, UrFont);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, UrFontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, UrFontCol);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

// Create trend line
void CreateTrendLine(string name, datetime time1, datetime time2, 
                     double price1, double price2, color clr)
{
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

// Update comment

void UpdateComment()
{
   double totalSignals = g_winCount + g_loseCount;
   if(totalSignals == 0) return;
   
   int winPercent = (int)MathRound(100.0 * g_winCount / totalSignals);
   int losePercent = (int)MathFloor(100.0 * g_loseCount / totalSignals);
   int avgPips = (int)MathCeil((double)g_totalPips / g_signalCount);
   
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   
   Comment("\n" +
           "Winning Trades:  " + IntegerToString(winPercent) + "% (" + 
           IntegerToString(g_winCount) + " of " + IntegerToString((int)totalSignals) + ")\n" +
           "Losing Trades:   " + IntegerToString(losePercent) + "% (" + 
           IntegerToString(g_loseCount) + " of " + IntegerToString((int)totalSignals) + ")\n" +
           "Average Signal:  " + IntegerToString(avgPips) + " pips\n" +
           "Spread:          " + DoubleToString(spread / 10.0, 1) + " pips");
}














// Clean old objects
void CleanOldObjects()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, "RMDT") != -1)
         ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//| Helper: iATR personalizado (sem buffer externo)                  |
//+------------------------------------------------------------------+
double CustomATR(string symbol, ENUM_TIMEFRAMES tf, int period, int shift)
{
   static int handle = INVALID_HANDLE;
   static int lastPeriod = -1;
   static ENUM_TIMEFRAMES lastTf = PERIOD_CURRENT;
   static string lastSymbol = "";

   if(handle == INVALID_HANDLE || lastPeriod != period || lastTf != tf || lastSymbol != symbol)
   {
      if(handle != INVALID_HANDLE) IndicatorRelease(handle);
      handle = iATR(symbol, tf, period);
      if(handle == INVALID_HANDLE) return 0.0;
      lastPeriod = period;
      lastTf = tf;
      lastSymbol = symbol;
   }

   double atrBuffer[];
   if(CopyBuffer(handle, 0, shift, 1, atrBuffer) <= 0) return 0.0;
   return atrBuffer[0];
}
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| Função simples para ler o JSON do Python                         |
//+------------------------------------------------------------------+
void ReadMacroSignal(string &out_signal, double &out_confidence, string &out_regime)
{
   out_signal    = "NEUTRAL";
   out_confidence = 0.0;
   out_regime    = "UNKNOWN";

   int handle = FileOpen("macro_signal.json", FILE_READ|FILE_TXT|FILE_COMMON);
   if(handle == INVALID_HANDLE) return;

   string json = FileReadString(handle);
   FileClose(handle);
   if(StringLen(json) < 20) return;

   // Extrai signal
   int p = StringFind(json, "\"signal\": \"");
   if(p > 0) {
      p += 10;
      int e = StringFind(json, "\"", p);
      if(e > p) out_signal = StringSubstr(json, p, e - p);
   }

   // Extrai confidence
   p = StringFind(json, "\"confidence\": ");
   if(p > 0) {
      p += 14;
      int e = StringFind(json, ",", p);
      if(e == -1) e = StringFind(json, "}", p);
      if(e > p) out_confidence = StringToDouble(StringSubstr(json, p, e - p));
   }

   // Extrai regime
   p = StringFind(json, "\"regime\": \"");
   if(p > 0) {
      p += 11;
      int e = StringFind(json, "\"", p);
      if(e > p) out_regime = StringSubstr(json, p, e - p);
   }
}