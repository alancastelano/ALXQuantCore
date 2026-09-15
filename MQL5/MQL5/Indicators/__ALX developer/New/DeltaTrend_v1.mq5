//+------------------------------------------------------------------+
//|                                            DeltaTrend_v1_600.mq5 |
//|                          Refatorado de MQL4 para MQL5            |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   2

//--- plot 1: setas de alta
#property indicator_label1  "LongSignal"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrBlue
//--- plot 2: setas de baixa
#property indicator_label2  "ShortSignal"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed

//--- parâmetros de entrada
input ENUM_TIMEFRAMES InpTimeFrame    = PERIOD_CURRENT; // Timeframe (multi-TF)
input int             MainFilterFast  = 8;              // Main Filter Fast
input int             MainFilterSlow  = 16;             // Main Filter Slow
input int             SmallFilterFast = 3;              // Small Filter Fast
input int             SmallFilterSlow = 12;             // Small Filter Slow
input bool            FirstSignalOnly = true;           // Apenas o primeiro sinal
input bool            AlertMode       = true;           // Alertas ativados

//--- buffers do indicador
double signal_UP[];
double signal_DN[];
double trendBuffer[];      // buffer oculto: tendência de cada barra (-1/0/+1)

//--- variáveis globais
int    g_timeframe   = 0;                    // timeframe efetivo
int    g_atrHandle   = INVALID_HANDLE;       // handle do ATR(10)
int    g_selfHandle  = INVALID_HANDLE;       // handle deste indicador no TF superior
string TF            = "";
bool   DnTrend = false, UpTrend = false;
int    barnumber = 0;

//+------------------------------------------------------------------+
//| Inicialização                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   ENUM_TIMEFRAMES chartTF = (ENUM_TIMEFRAMES)_Period;

   //--- resolve o timeframe efetivo (igual ou superior ao do gráfico)
   g_timeframe = (InpTimeFrame == PERIOD_CURRENT) ? (int)chartTF : (int)InpTimeFrame;
   if(g_timeframe < (int)chartTF)
      g_timeframe = (int)chartTF;

   TF = TimeframeToString((ENUM_TIMEFRAMES)g_timeframe);

   //--- buffers
   SetIndexBuffer(0, signal_UP,   INDICATOR_DATA);
   SetIndexBuffer(1, signal_DN,   INDICATOR_DATA);
   SetIndexBuffer(2, trendBuffer, INDICATOR_CALCULATIONS);

   ArraySetAsSeries(signal_UP,   true);
   ArraySetAsSeries(signal_DN,   true);
   ArraySetAsSeries(trendBuffer, true);

   //--- propriedades dos plots
   PlotIndexSetInteger(0, PLOT_ARROW, 233);              // seta para cima
   PlotIndexSetInteger(1, PLOT_ARROW, 234);              // seta para baixo
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("%s[%s](%d,%d,%d,%d)",
                                   MQLInfoString(MQL_PROGRAM_NAME), TF,
                                   MainFilterFast, MainFilterSlow,
                                   SmallFilterFast, SmallFilterSlow));

   //--- handle do ATR usado para afastar as setas do candle
   g_atrHandle = iATR(_Symbol, chartTF, 10);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("DeltaTrend: falha ao criar handle do ATR");
      return(INIT_FAILED);
     }

   //--- modo multi-timeframe: handle deste mesmo indicador no TF superior
   if(g_timeframe != (int)chartTF)
     {
      g_selfHandle = iCustom(_Symbol, (ENUM_TIMEFRAMES)g_timeframe,
                             MQLInfoString(MQL_PROGRAM_NAME),
                             (ENUM_TIMEFRAMES)g_timeframe,   // a instância "filha" roda no próprio TF
                             MainFilterFast, MainFilterSlow,
                             SmallFilterFast, SmallFilterSlow,
                             FirstSignalOnly, AlertMode);
      if(g_selfHandle == INVALID_HANDLE)
        {
         Print("DeltaTrend: falha ao criar handle do TF ", TF);
         return(INIT_FAILED);
        }
     }

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Finalização                                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle  != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_selfHandle != INVALID_HANDLE) IndicatorRelease(g_selfHandle);
  }

//+------------------------------------------------------------------+
//| Cálculo principal                                                |
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
   if(rates_total < 2)
      return(0);

   ArraySetAsSeries(time,  true);
   ArraySetAsSeries(open,  true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);

   //--- barras a (re)calcular (equivalente ao IndicatorCounted do MQL4)
   int limit;
   if(prev_calculated <= 0)
     {
      limit = rates_total - 1;
      trendBuffer[limit] = 0.0;                 // semente da barra mais antiga
      signal_UP[limit]   = EMPTY_VALUE;
      signal_DN[limit]   = EMPTY_VALUE;
      limit--;
     }
   else
      limit = rates_total - prev_calculated;

   //================================================================
   // MODO MULTI-TIMEFRAME: copia os sinais do TF superior
   //================================================================
   if(g_timeframe != (int)_Period)
     {
      int ratio = (int)(PeriodSeconds((ENUM_TIMEFRAMES)g_timeframe) / PeriodSeconds(PERIOD_CURRENT));
      limit = MathMax(limit, ratio);
      limit = MathMin(limit, rates_total - 1);

      for(int shift = 0; shift <= limit; shift++)
        {
         int y = iBarShift(_Symbol, (ENUM_TIMEFRAMES)g_timeframe, time[shift]);
         double up, dn;

         if(y < 0 || !BufferValue(g_selfHandle, 0, y, up) || !BufferValue(g_selfHandle, 1, y, dn))
            return(0);                          // dados do TF superior ainda não prontos

         signal_UP[shift] = up;
         signal_DN[shift] = dn;
        }
      return(rates_total);
     }

   //================================================================
   // MODO TIMEFRAME DO GRÁFICO
   //================================================================
   double atr[];
   ArraySetAsSeries(atr, true);
   int atrCopied = CopyBuffer(g_atrHandle, 0, 0, limit + 1, atr);
   if(atrCopied <= 0)
      return(prev_calculated);                  // ATR ainda não disponível

   for(int i = limit; i >= 0; i--)
     {
      double prevTrend = (i < rates_total - 1) ? trendBuffer[i + 1] : 0.0;

      //--- por padrão a tendência se mantém da barra anterior
      trendBuffer[i] = prevTrend;

      //--- filtro principal
      if(ROC(1, MainFilterFast, i, open, close) > ROC(1, MainFilterSlow, i, open, close))
        {
         double roc  = ROC(0, SmallFilterFast, i, open, close);
         double aroc = ROC(1, SmallFilterSlow, i, open, close);

         if(roc >  aroc) trendBuffer[i] =  1.0;
         else
         if(roc < -aroc) trendBuffer[i] = -1.0;
        }

      //--- sem sinal por padrão
      signal_UP[i] = EMPTY_VALUE;
      signal_DN[i] = EMPTY_VALUE;

      double offset = (i < atrCopied) ? atr[i] : 0.0;

      if(trendBuffer[i] > 0)
        {
         if(!FirstSignalOnly || prevTrend < 0)
            signal_UP[i] = low[i] - offset;
        }
      else
      if(trendBuffer[i] < 0)
        {
         if(!FirstSignalOnly || prevTrend > 0)
            signal_DN[i] = high[i] + offset;
        }
     }

   //--- alertas (apenas na instância do próprio timeframe)
   if(AlertMode)
     {
      if(signal_UP[0] != EMPTY_VALUE && signal_UP[0] != 0.0 && DnTrend && rates_total > barnumber)
        {
         barnumber = rates_total;
         DnTrend   = false;
         Alert("DeltaTrend going Up on ", _Symbol, " ", TF);
        }

      if(!DnTrend && (signal_UP[0] == EMPTY_VALUE || signal_UP[0] == 0.0))
         DnTrend = true;

      if(signal_DN[0] != EMPTY_VALUE && signal_DN[0] != 0.0 && UpTrend && rates_total > barnumber)
        {
         barnumber = rates_total;
         UpTrend   = false;
         Alert("DeltaTrend going Down on ", _Symbol, " ", TF);
        }

      if(!UpTrend && (signal_DN[0] == EMPTY_VALUE || signal_DN[0] == 0.0))
         UpTrend = true;
     }

   return(rates_total);
  }

//+------------------------------------------------------------------+
//| ROC com suavização EMA (equivalente à versão MQL4)               |
//+------------------------------------------------------------------+
double ROC(const int mode, const int length, const int bar,
           const double &open[], const double &close[])
  {
   if(length <= 0)
      return(0.0);

   int guard = length + bar + 1;
   if(guard >= ArraySize(close) || close[guard] == 0.0)
      return(0.0);

   double mom[];
   ArrayResize(mom, length);

   for(int i = 0; i < length; i++)
     {
      double m = close[bar + i] - open[bar + i];   // iMA(period=1) == preço puro
      mom[length - 1 - i] = (mode == 0) ? m : MathAbs(m);
     }

   double alpha  = 2.0 / (length + 1);
   double result = mom[0];
   for(int i = 1; i < length; i++)
      result = mom[i] * alpha + result * (1.0 - alpha);

   return(result);
  }

//+------------------------------------------------------------------+
//| Lê um valor de buffer de outro indicador                         |
//+------------------------------------------------------------------+
bool BufferValue(const int handle, const int buffer_index, const int shift, double &value)
  {
   double tmp[];
   if(handle == INVALID_HANDLE || shift < 0)
      return(false);
   if(CopyBuffer(handle, buffer_index, shift, 1, tmp) != 1)
      return(false);
   value = tmp[0];
   return(true);
  }

//+------------------------------------------------------------------+
//| Converte ENUM_TIMEFRAMES em texto ("H1", "M15"...)               |
//+------------------------------------------------------------------+
string TimeframeToString(ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : tf);
   StringReplace(s, "PERIOD_", "");
   return(s);
  }