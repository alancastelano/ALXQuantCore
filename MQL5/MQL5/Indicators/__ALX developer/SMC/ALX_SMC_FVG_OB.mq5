//+------------------------------------------------------------------+
//|                                             ALX_SMC_FVG_OB.mq5   |
//|                         ALX Quantum Core - SMC Confluence v1.00  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXFund."
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

// Plot 1: Bullish Confluence Arrow
#property indicator_label1  "Bull Confluence"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2

// Plot 2: Bearish Confluence Arrow
#property indicator_label2  "Bear Confluence"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  2

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "===== FVG Settings ====="
input int    MinFVGSizePips   = 2;      // Tamanho mínimo do FVG em Pips (filtra ruído)
input int    MaxBarsLookback  = 300;    // Máximo de barras para análise (performance)

input group "===== Order Block Settings ====="
input int    OBLookback       = 5;      // Quantas barras procurar atrás do FVG para achar o OB

input group "===== Visual Settings ====="
input color  BullFVGColor     = clrDodgerBlue;  // Cor do FVG de Alta
input color  BearFVGColor     = clrCrimson;     // Cor do FVG de Baixa
input color  BullOBColor      = clrMediumSeaGreen; // Cor do OB de Alta
input color  BearOBColor      = clrOrangeRed;      // Cor do OB de Baixa
input bool   ShowPureFVG      = true;   // Mostrar FVGs que não tem confluência com OB
input bool   ShowPureOB       = false;  // Mostrar OBs que não tem confluência com FVG

//+------------------------------------------------------------------+
//| Indicator Buffers                                                |
//+------------------------------------------------------------------+
double BufferBullConf[];
double BufferBearConf[];

//+------------------------------------------------------------------+
//| Custom indicator initialization                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   SetIndexBuffer(0, BufferBullConf, INDICATOR_DATA);
   SetIndexBuffer(1, BufferBearConf, INDICATOR_DATA);
   
   PlotIndexSetInteger(0, PLOT_ARROW, 233); // Seta para cima
   PlotIndexSetInteger(1, PLOT_ARROW, 234); // Seta para baixo
   
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   
   ArraySetAsSeries(BufferBullConf, true);
   ArraySetAsSeries(BufferBearConf, true);
   
   IndicatorSetString(INDICATOR_SHORTNAME, "SMC Confluence (FVG+OB)");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   CleanObjects("SMC_");
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
   // Séries temporais (0 = barra mais recente)
   ArraySetAsSeries(time, true);
   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   int limit;
   if(prev_calculated == 0) limit = MathMin(rates_total - 3, MaxBarsLookback);
   else limit = rates_total - prev_calculated + 1;
   
   // NON-REPINT: Começamos do índice 2. O FVG precisa da barra i, i+1, i+2. 
   // A barra 1 (fechada) confirma o padrão. Nunca processamos a barra 0 (em formação).
   for(int i = limit; i >= 2; i--)
   {
      //==============================================================
      // 1. DETECÇÃO DE FVG (Fair Value Gap)
      //==============================================================
      
      // FVG de Alta (Bullish): Gap entre a High da vela i+2 e a Low da vela i
      double bull_fvg_top    = iLow(_Symbol,PERIOD_CURRENT,i);
      double bull_fvg_bottom = iHigh(_Symbol,PERIOD_CURRENT,i+2);
      
      // FVG de Baixa (Bearish): Gap entre a Low da vela i+2 e a High da vela i
      double bear_fvg_top    = iLow(_Symbol,PERIOD_CURRENT,i+2);
      double bear_fvg_bottom = iHigh(_Symbol,PERIOD_CURRENT,i);
      
      bool isBullFVG = (bull_fvg_top > bull_fvg_bottom) && ((bull_fvg_top - bull_fvg_bottom) / _Point >= MinFVGSizePips * 10);
      bool isBearFVG = (bear_fvg_top > bear_fvg_bottom) && ((bear_fvg_top - bear_fvg_bottom) / _Point >= MinFVGSizePips * 10);
      
      //==============================================================
      // 2. DETECÇÃO DE OB (Order Block) E CONFLUÊNCIA
      //==============================================================
      
      if(isBullFVG)
      {
         int ob_shift = -1;
         double ob_top = 0, ob_bottom = 0;
         
         // Procurar o Order Block de Alta (Última vela de queda antes do impulso)
         // Começamos em i+1 (a vela do meio do FVG) e olhamos para trás
         for(int j = i+1; j <= i + 1 + OBLookback; j++)
         {
            if(j >= rates_total) break;
            if(close[j] < open[j]) // Vela de baixa (Origem institucional)
            {
               ob_shift = j;
               ob_top = high[j];
               ob_bottom = low[j];
               break;
            }
         }
         
         // Lógica de Confluência: O OB se sobrepõe ao FVG?
         bool hasConfluence = false;
         if(ob_shift != -1)
         {
            // Se o topo do OB é maior que o fundo do FVG E o fundo do OB é menor que o topo do FVG -> Sobreposição
            if(ob_top >= bull_fvg_bottom && ob_bottom <= bull_fvg_top)
            {
               hasConfluence = true;
               
               // Ponto exato de entrada: A interseção entre o fundo do FVG e o topo do OB
               double entry_zone = MathMax(bull_fvg_bottom, ob_bottom);
               
               // Sinal Visual de Confluência
               BufferBullConf[i] = entry_zone;
               
               // Desenhar Caixas
               DrawBox("BullFVG_"+TimeToString(time[i]), time[i+2], bull_fvg_bottom, time[i], bull_fvg_top, BullFVGColor, hasConfluence);
               DrawBox("BullOB_"+TimeToString(time[ob_shift]), time[ob_shift], ob_bottom, time[ob_shift], ob_top, BullOBColor, hasConfluence);
            }
         }
         
         // Desenhar FVG puro se não houver confluência mas estiver habilitado
         if(!hasConfluence && ShowPureFVG)
            DrawBox("BullFVG_"+TimeToString(time[i]), time[i+2], bull_fvg_bottom, time[i], bull_fvg_top, BullFVGColor, false);
      }
      
      if(isBearFVG)
      {
         int ob_shift = -1;
         double ob_top = 0, ob_bottom = 0;
         
         // Procurar o Order Block de Baixa (Última vela de alta antes do impulso)
         for(int j = i+1; j <= i + 1 + OBLookback; j++)
         {
            if(j >= rates_total) break;
            if(close[j] > open[j]) // Vela de alta (Origem institucional)
            {
               ob_shift = j;
               ob_top = high[j];
               ob_bottom = low[j];
               break;
            }
         }
         
         bool hasConfluence = false;
         if(ob_shift != -1)
         {
            if(ob_top >= bear_fvg_bottom && ob_bottom <= bear_fvg_top)
            {
               hasConfluence = true;
               
               // Ponto exato de entrada: A interseção entre o topo do FVG e o fundo do OB
               double entry_zone = MathMin(bear_fvg_top, ob_top);
               
               // Sinal Visual de Confluência
               BufferBearConf[i] = entry_zone;
               
               DrawBox("BearFVG_"+TimeToString(time[i]), time[i+2], bear_fvg_bottom, time[i], bear_fvg_top, BearFVGColor, hasConfluence);
               DrawBox("BearOB_"+TimeToString(time[ob_shift]), time[ob_shift], ob_bottom, time[ob_shift], ob_top, BearOBColor, hasConfluence);
            }
         }
         
         if(!hasConfluence && ShowPureFVG)
            DrawBox("BearFVG_"+TimeToString(time[i]), time[i+2], bear_fvg_bottom, time[i], bear_fvg_top, BearFVGColor, false);
      }
   }
   
   return rates_total;
}

//+------------------------------------------------------------------+
//| Funções Auxiliares Visuais                                       |
//+------------------------------------------------------------------+
void DrawBox(string name, datetime time1, double price1, datetime time2, double price2, color clr, bool isConfluence)
{
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, time1, price1, time2, price2);
   
   // Zonas de confluência são mais opacas (sólidas), zonas puras são transparentes
   int width = isConfluence ? 2 : 1;
   bool fill = isConfluence ? true : false; 
   
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_BACK, true); // Fundo do gráfico
   ObjectSetInteger(0, name, OBJPROP_FILL, fill);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void CleanObjects(string prefix)
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, prefix) != -1)
         ObjectDelete(0, name);
   }
}
//+------------------------------------------------------------------+