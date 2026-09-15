//+------------------------------------------------------------------+
//|                                           IronScalper_Visual.mq5 |
//|                                                     ALXQuantCore |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore"
#property link      "https://www.mforex.pro"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

//--- Plot Buy
#property indicator_label1  "Buy Signal"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_style1  STYLE_SOLID
#property indicator_width1  3

//--- Plot Sell
#property indicator_label2  "Sell Signal"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  3

//--- Input parameters
input group    "== Strategy Parameters =="
input uchar    InpBar           = 0;        // Candle Index (0=current, 1=last closed)
input uchar    InpAvBar         = 80;       // Average Bar Period
input double   PipsStep         = 3.0;      // Volatility Multiplier

//--- Indicator buffers
double         BufferBuy[];
double         BufferSell[];

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   // Mapeando os buffers
   SetIndexBuffer(0, BufferBuy, INDICATOR_DATA);
   SetIndexBuffer(1, BufferSell, INDICATOR_DATA);

   // Definindo o código da seta (233 = Seta para cima, 234 = Seta para baixo)
   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);

   // Zerando valores vazios
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   return(INIT_SUCCEEDED);
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
   // Precisamos de pelo menos InpAvBar barras para calcular a média
   if(rates_total < InpAvBar + 1) return(0);

   // Otimização: calcular apenas barras novas
   int start = prev_calculated - 1;
   if(start < InpAvBar) start = InpAvBar; 

   for(int i = start; i < rates_total; i++)
   {
      BufferBuy[i]  = EMPTY_VALUE;
      BufferSell[i] = EMPTY_VALUE;

      // Não calcula na barra atual se InpBar for 1 (sinal em candle fechado)
      if(InpBar > 0 && i == rates_total - 1) continue;

      // 1. Calcular a média de volatilidade
      double avgBar = 0.0;
      int actualCount = 0;
      for(int j = 1; j <= InpAvBar; j++)
      {
         if(i - j >= 0)
         {
            double h = high[i - j];
            double l = low[i - j];
            if(h > 0 && l > 0)
            {
               avgBar += (h - l) / _Point;
               actualCount++;
            }
         }
      }
      if(actualCount > 0) avgBar /= actualCount; else avgBar = 0;

      // 2. Checar o sinal no candle alvo
      int target_idx = i - InpBar;
      if(target_idx < 0) continue;

      double open1  = open[target_idx];
      double close1 = close[target_idx];
      double point  = _Point;

      double bodySize = MathAbs(open1 - close1) / point;
      double threshold = avgBar * PipsStep;

      // 3. Sinais visuais
      if(close1 > open1 && bodySize > threshold)
      {
         BufferBuy[i] = low[i]; // Seta aparece na mínima do candle
      }
      else if(close1 < open1 && bodySize > threshold)
      {
         BufferSell[i] = high[i]; // Seta aparece na máxima do candle
      }
   }

   return(rates_total);
}
//+------------------------------------------------------------------+