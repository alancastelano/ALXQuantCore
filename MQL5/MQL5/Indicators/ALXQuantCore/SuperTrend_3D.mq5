//+------------------------------------------------------------------+
//| ALX SuperTrend 3D - Pro Edition (Anti-Whipsaw + Trend Force)     |
//| Copyright 2025, AMXFund                                          |
//+------------------------------------------------------------------+
#property copyright       "AMXFund, 2025"
#property link            "alxfund@gmail.com"
#property description     "SuperTrend 3D com Filtro de Forca Direcional"

#property indicator_chart_window
#property indicator_buffers 9
#property indicator_plots   3

#property indicator_label1  "Signal"
#property indicator_type1   DRAW_NONE
#property indicator_color1  clrNONE

#property indicator_label2  "Line_Value"
#property indicator_type2   DRAW_COLOR_LINE
#property indicator_color2  clrDimGray, clrMaroon, clrForestGreen
#property indicator_width2  7

#property indicator_label3  "Main"
#property indicator_type3   DRAW_COLOR_LINE
#property indicator_color3  clrSilver, clrRed, clrLime
#property indicator_width3  3

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
      //group               "== SuperTrend ATR =="
      int                 inpAtrPeriod       = 10;
      double              inpAtrMultiplier   = 3.0;

      //group               "== Filtros Anti-Consolidacao =="
      bool                inpUseAdxFilter    = true;
      int                 inpAdxPeriod       = 14;
      int                 inpAdxMinLevel     = 30;
      int                 inpMinBarsConfirm  = 3;

      //group               "== Filtro de Forca Direcional =="
      bool                inpUseForceFilter  = true;
      int                 inpForcePeriod     = 20;
      double              inpForceSmooth     = 3.0;
      double              inpForceUpLevel    = 0.05;
      double              inpForceDownLevel  = -0.05;

//+------------------------------------------------------------------+
//| Buffers e Globais                                                |
//+------------------------------------------------------------------+
double val_main[], valc_main[], prices[], trend[], val_border[], valc_border[], signal[];
double trendForce[], forceColor[], mma[], smma[], tdf[], tdfa[], val1[];
int atr_handle, adx_handle;
double alpha_force, alpha_smooth;
int maxPeriod;

//+------------------------------------------------------------------+
int OnInit()
{
    atr_handle = iATR(_Symbol, _Period, inpAtrPeriod);
    adx_handle = iADX(_Symbol, _Period, inpAdxPeriod);

    if(atr_handle == INVALID_HANDLE || adx_handle == INVALID_HANDLE)
        return(INIT_FAILED);

    SetIndexBuffer(0, signal, INDICATOR_DATA);
    SetIndexBuffer(1, val_border, INDICATOR_DATA);
    SetIndexBuffer(2, valc_border, INDICATOR_COLOR_INDEX);
    SetIndexBuffer(3, val_main, INDICATOR_DATA);
    SetIndexBuffer(4, valc_main, INDICATOR_COLOR_INDEX);
    SetIndexBuffer(5, prices, INDICATOR_CALCULATIONS);
    SetIndexBuffer(6, trend, INDICATOR_CALCULATIONS);

    SetIndexBuffer(7, trendForce, INDICATOR_DATA);
    SetIndexBuffer(8, forceColor, INDICATOR_COLOR_INDEX);

    ArrayResize(mma, 0);
    ArrayResize(smma, 0);
    ArrayResize(tdf, 0);
    ArrayResize(tdfa, 0);
    ArrayResize(val1, 0);

    alpha_force = 2.0 / (1.0 + inpForcePeriod);
    alpha_smooth = 2.0 / (1.0 + MathSqrt(inpForceSmooth > 1 ? inpForceSmooth : 1));
    maxPeriod = 3 * inpForcePeriod;

    IndicatorSetString(INDICATOR_SHORTNAME, "ALX_SuperTrend3D");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(atr_handle);
    IndicatorRelease(adx_handle);
}

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
    if(rates_total < 2) return 0;

    ArrayResize(mma, rates_total);
    ArrayResize(smma, rates_total);
    ArrayResize(tdf, rates_total);
    ArrayResize(tdfa, rates_total);
    ArrayResize(val1, rates_total);

    double atr_b[], adx_b[];
    ArrayResize(atr_b, rates_total);
    ArrayResize(adx_b, rates_total);

    if(CopyBuffer(atr_handle, 0, 0, rates_total, atr_b) <= 0) return 0;
    if(CopyBuffer(adx_handle, 0, 0, rates_total, adx_b) <= 0) return 0;

    int start = (prev_calculated == 0) ? 1 : prev_calculated - 1;
    double forcePrev = 0;

    for(int i = start; i < rates_total && !IsStopped(); i++)
    {
        double price = (high[i] + low[i]) / 2.0;
        double ub = price + inpAtrMultiplier * atr_b[i];
        double lb = price - inpAtrMultiplier * atr_b[i];

        int potential_trend = trend[i-1];
        if(price > val_main[i-1]) potential_trend = 1;
        else if(price < val_main[i-1]) potential_trend = -1;

        bool is_changing = (potential_trend != trend[i-1]);
        bool filter_pass = true;

        if(is_changing)
        {
            if(inpUseAdxFilter && adx_b[i] < inpAdxMinLevel)
                filter_pass = false;

            if(filter_pass && inpMinBarsConfirm > 1)
            {
                for(int b=0; b<inpMinBarsConfirm; b++)
                {
                    if(i-b < 0) { filter_pass = false; break; }
                    double check_p = (high[i-b] + low[i-b]) / 2.0;
                    if(potential_trend == 1 && check_p < val_main[i-1]) filter_pass = false;
                    if(potential_trend == -1 && check_p > val_main[i-1]) filter_pass = false;
                }
            }
        }

        double force = 0;
        if(i >= 1)
        {
            mma[i] = mma[i-1] + alpha_force * (close[i] - mma[i-1]);
            smma[i] = smma[i-1] + alpha_force * (mma[i] - smma[i-1]);

            double impetmma  = mma[i] - mma[i-1];
            double impetsmma = smma[i] - smma[i-1];
            double divma = MathAbs(mma[i] - smma[i]);
            double averimpet = (impetmma + impetsmma) / 2.0;

            tdf[i] = divma * averimpet * averimpet * averimpet;
            tdfa[i] = MathAbs(tdf[i]);

            int startIdx = i - maxPeriod + 1; if(startIdx < 0) startIdx = 0;
            int searchCount = MathMin(maxPeriod, rates_total - startIdx);
            int maxIdx = ArrayMaximum(tdfa, startIdx, searchCount);
            double absMax = (maxIdx >= 0) ? tdfa[maxIdx] : 0;
            double rawForce = (absMax > 0) ? tdf[i] / absMax : 0;

            val1[i] = (i>0) ? val1[i-1] + alpha_smooth * (rawForce - val1[i-1]) : rawForce;
            force = (i>0) ? forcePrev + alpha_smooth * (val1[i] - forcePrev) : val1[i];
        }
        else
        {
            mma[i] = close[i];
            smma[i] = close[i];
            tdf[i] = 0;
            tdfa[i] = 0;
            val1[i] = 0;
            force = 0;
        }
        trendForce[i] = force;
        forcePrev = force;

        if(force > inpForceUpLevel) forceColor[i] = 2;
        else if(force < inpForceDownLevel) forceColor[i] = 1;
        else forceColor[i] = 0;

        bool forceOk = true;
        if(inpUseForceFilter && is_changing)
        {
            if(force >= inpForceDownLevel && force <= inpForceUpLevel)
                forceOk = false;
        }

        if(filter_pass && forceOk) trend[i] = potential_trend;
        else trend[i] = trend[i-1];

        if(trend[i] == 1) val_main[i] = MathMax(lb, val_main[i-1]);
        else if(trend[i] == -1) val_main[i] = MathMin(ub, val_main[i-1]);
        else val_main[i] = val_main[i-1];

        val_border[i] = val_main[i];
        int col = (trend[i] == 1) ? 2 : 1;
        valc_main[i] = col;
        valc_border[i] = col;
        signal[i] = (col == 2) ? 1 : 2;
    }

    return(rates_total);
}
