//+------------------------------------------------------------------+
//|                                               ICT_Wyckoff_OB.mq5 |
//|                                        Adaptado de AR_Order_Block|
//+------------------------------------------------------------------+
#property copyright "Adaptado de AR_Order_Block"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

// --- Input Parameters ---
input int                OB_Lookback        = 50;        // Lookback Bars for OB search
input bool               Draw_FVG           = true;      // Draw Fair Value Gaps?
input color              FVG_Color          = clrSteelBlue; // FVG Color
input bool               Draw_OB            = true;      // Draw Order Blocks?
input color              Bullish_OB_Color   = clrGreen;  // Bullish OB Color
input color              Bearish_OB_Color   = clrRed;     // Bearish OB Color

//+------------------------------------------------------------------+
//| Custom function to detect a Fair Value Gap (FVG)                |
//+------------------------------------------------------------------+
bool IsFairValueGap(int index, string &fvgType, double &fvgHigh, double &fvgLow) {
   // FVG detection based on 3-candle pattern:
   // Bullish FVG: Low of candle 'index+1' > High of candle 'index-1'
   // Bearish FVG: High of candle 'index+1' < Low of candle 'index-1'
   double highPrev = iHigh(_Symbol, Period(), index-1);
   double lowPrev  = iLow(_Symbol, Period(), index-1);
   double highCurr = iHigh(_Symbol, Period(), index);
   double lowCurr  = iLow(_Symbol, Period(), index);
   double highNext = iHigh(_Symbol, Period(), index+1);
   double lowNext  = iLow(_Symbol, Period(), index+1);

   // Bullish FVG
   if(lowNext > highPrev) {
      fvgType = "Bullish";
      fvgHigh = lowNext;
      fvgLow  = highPrev;
      return true;
   }
   // Bearish FVG
   if(highNext < lowPrev) {
      fvgType = "Bearish";
      fvgHigh = lowPrev;
      fvgLow  = highNext;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Custom function to detect a potential Order Block (OB)          |
//+------------------------------------------------------------------+
bool IsOrderBlock(int index, string &obType, double &obHigh, double &obLow) {
   // Simplified OB detection: looks for a strong move and defines the OB as the last candle before it.
   // Bullish OB: A significant bearish candle (index) followed by 3 bullish candles that break its high.
   // Bearish OB: A significant bullish candle (index) followed by 3 bearish candles that break its low.

   double bodyCandle = MathAbs(iClose(_Symbol, Period(), index) - iOpen(_Symbol, Period(), index));
   double rangeCandle = iHigh(_Symbol, Period(), index) - iLow(_Symbol, Period(), index);

   // Avoid small, indecisive candles
   if(rangeCandle == 0 || (bodyCandle / rangeCandle) < 0.3) return false;

   // Bullish OB logic
   if(iClose(_Symbol, Period(), index) < iOpen(_Symbol, Period(), index)) { // Current candle is bearish
      double highOfCandle = iHigh(_Symbol, Period(), index);
      // Check if the next 3 candles break above this high
      if(iHigh(_Symbol, Period(), index-1) > highOfCandle &&
         iHigh(_Symbol, Period(), index-2) > highOfCandle &&
         iHigh(_Symbol, Period(), index-3) > highOfCandle) {
         obType = "Bullish";
         obHigh = highOfCandle;
         obLow = iLow(_Symbol, Period(), index);
         return true;
      }
   }

   // Bearish OB logic
   if(iClose(_Symbol, Period(), index) > iOpen(_Symbol, Period(), index)) { // Current candle is bullish
      double lowOfCandle = iLow(_Symbol, Period(), index);
      // Check if the next 3 candles break below this low
      if(iLow(_Symbol, Period(), index-1) < lowOfCandle &&
         iLow(_Symbol, Period(), index-2) < lowOfCandle &&
         iLow(_Symbol, Period(), index-3) < lowOfCandle) {
         obType = "Bearish";
         obHigh = iHigh(_Symbol, Period(), index);
         obLow = lowOfCandle;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
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
   // We need at least 4 bars to work with our logic
   if(rates_total < 4) return(0);

   // --- Clean up previous drawings at the start of a new run ---
   if(prev_calculated == 0) {
      ObjectsDeleteAll(0, "ICT_OB_");
      ObjectsDeleteAll(0, "ICT_FVG_");
   }

   // --- Loop through bars to find FVGs and OBs ---
   int start = prev_calculated - 3; // Avoid recalculating everything if not necessary
   if(start < 1) start = 1;

   for(int i = start; i < rates_total - 2 && !IsStopped(); i++) {
      string objName;
      string fvgType, obType;
      double fvgHigh, fvgLow, obHigh, obLow;
      datetime time1 = iTime(_Symbol, Period(), i+1);
      datetime time2 = iTime(_Symbol, Period(), i-1);

      // --- Draw Fair Value Gaps ---
      if(Draw_FVG && IsFairValueGap(i, fvgType, fvgHigh, fvgLow)) {
         objName = "ICT_FVG_" + (string)i;
         if(ObjectFind(0, objName) < 0) {
            if(!ObjectCreate(0, objName, OBJ_RECTANGLE, 0, time1, fvgHigh, time2, fvgLow)) {
               Print("Error creating FVG object: ", GetLastError());
            } else {
               ObjectSetInteger(0, objName, OBJPROP_COLOR, FVG_Color);
               ObjectSetInteger(0, objName, OBJPROP_FILL, true);
               ObjectSetInteger(0, objName, OBJPROP_BACK, true);
               ObjectSetInteger(0, objName, OBJPROP_WIDTH, 1);
            }
         }
      }

      // --- Draw Order Blocks ---
      if(Draw_OB && IsOrderBlock(i, obType, obHigh, obLow)) {
         objName = "ICT_OB_" + (string)i;
         if(ObjectFind(0, objName) < 0) {
            if(!ObjectCreate(0, objName, OBJ_RECTANGLE, 0, time[i], obHigh, time[i], obLow)) {
               Print("Error creating OB object: ", GetLastError());
            } else {
               ObjectSetInteger(0, objName, OBJPROP_COLOR, (obType == "Bullish") ? Bullish_OB_Color : Bearish_OB_Color);
               ObjectSetInteger(0, objName, OBJPROP_FILL, true);
               ObjectSetInteger(0, objName, OBJPROP_BACK, true);
               ObjectSetInteger(0, objName, OBJPROP_WIDTH, 1);
               // Extend the rectangle to the right
               ObjectSetDouble(0, objName, OBJPROP_PRICE, 1, obHigh);
               ObjectSetInteger(0, objName, OBJPROP_TIME, 1, TimeCurrent());
            }
         }
      }
   }

   // --- Force chart redraw ---
   ChartRedraw(0);

   return(rates_total);
}
//+------------------------------------------------------------------+