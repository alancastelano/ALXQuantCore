//+------------------------------------------------------------------+
//|                                              Gold Pro Vision.mq5 |
//|                                          Copyright 2026, ALX Fund|
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALX Fund."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   3

// Definição dos Plots
#property indicator_label1  "Sinal de Compra"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrTeal
#property indicator_width1  1

#property indicator_label2  "Sinal de Venda"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrCrimson
#property indicator_width2  1

#property indicator_label3  "Alvo de Saída"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrBlue
#property indicator_width3  1

//--- Buffers
double BufferBuy[];
double BufferSell[];
double BufferExit[];

//--- Parâmetros de Entrada (Iguais ao seu EA)
input int      InpDistance   = 300;    // Distância em Pontos
input bool     SetAverageBar = true;   // Usar Média de Barra
input int      InpHowBar     = 100;    // Quantidade de Barras
input double   InpExpBar     = 1.0;    // Expansão da Barra
input double   InpMinProfit  = 0.5;    // Lucro Mínimo para Saída (%)

//--- Variáveis Internas
double g_tickValue;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   SetIndexBuffer(0, BufferBuy, INDICATOR_DATA);
   PlotIndexSetInteger(0, PLOT_ARROW, 233); // Seta para cima

   SetIndexBuffer(1, BufferSell, INDICATOR_DATA);
   PlotIndexSetInteger(1, PLOT_ARROW, 234); // Seta para baixo

   SetIndexBuffer(2, BufferExit, INDICATOR_DATA);
   PlotIndexSetInteger(2, PLOT_ARROW, 252); // Ponto/Círculo para saída

   // Cálculo do multiplicador de pontos (ajuste para 5 casas)
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_tickValue = (digits == 5 || digits == 3) ? point * 10 : point;

   IndicatorSetString(INDICATOR_SHORTNAME, "Gold Pro Vision");
   
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
   int limit = rates_total - prev_calculated;
   if(limit > 1) limit = rates_total - InpHowBar - 1;

   for(int i = limit; i >= 0; i--)
   {
      BufferBuy[i]  = EMPTY_VALUE;
      BufferSell[i] = EMPTY_VALUE;
      BufferExit[i] = EMPTY_VALUE;

      if(i >= rates_total - InpHowBar) continue;

      //--- Lógica do Filtro AverageBar
      bool entryAllowed = true;
      if(SetAverageBar)
      {
         double avgRange = 0;
         for(int j = 1; j <= InpHowBar; j++)
         {
            avgRange += (high[i+j] - low[i+j]);
         }
         avgRange = (avgRange / InpHowBar) * InpExpBar;
         double currentRange = MathAbs(open[i] - close[i]);
         if(currentRange < avgRange) entryAllowed = false;
      }

      if(!entryAllowed) continue;

      //--- Simulação das Linhas do EA
      // No EA, as linhas seguem o preço. No indicador histórico, usamos o fechamento da barra anterior como base.
      double lineBuy  = close[i+1] + (InpDistance * _Point); // Simplificado para visualização
      double lineSell = close[i+1] - (InpDistance * _Point);

      //--- Sinal de VENDA (Baseado no seu código: open > close e ask <= lineSell)
      if(open[i] > close[i] && low[i] <= lineSell)
      {
         BufferSell[i] = high[i] + (10 * _Point);
         // Cálculo teórico de saída baseado no MinProfit
         BufferExit[i] = close[i] - (InpDistance * _Point * InpMinProfit * 2); 
      }

      //--- Sinal de COMPRA (Baseado no seu código: open < close e bid >= lineBuy)
      if(open[i] < close[i] && high[i] >= lineBuy)
      {
         BufferBuy[i] = low[i] - (10 * _Point);
         // Cálculo teórico de saída baseado no MinProfit
         BufferExit[i] = close[i] + (InpDistance * _Point * InpMinProfit * 2);
      }
   }

   return(rates_total);
}//+------------------------------------------------------------------+