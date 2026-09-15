//+------------------------------------------------------------------+
//|                                        Gold Pro Vision Quant.mq5 |
//|                                  Copyright 2026, AI Collaborator |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "2.80"
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   3

//--- Buffers
#property indicator_label1  "Compra GoldPro"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrTeal
#property indicator_width1  1

#property indicator_label2  "Venda GoldPro"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrCrimson
#property indicator_width2  1

#property indicator_label3  "Alvo de Lucro (TP)"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrGold
#property indicator_width3  3

//--- INPUTS
input group "=== Gold Pro (Principal) ==="
input int      InpDistance   = 300;    
input bool     SetAverageBar = true;   
input int      InpHowBar     = 100;    
input double   InpExpBar     = 1.0;    
input double   InpMinProfit  = 0.005; // Ajustado para 0.5% padrão

input group "=== Filtro Estatístico (Meal Reverse) ==="
input bool     Enable_MR_Filter       = true;  
input double   Hurst_Threshold        = 0.55;  

//--- Buffers Globais
double BufferBuy[], BufferSell[], BufferExit[];

//+------------------------------------------------------------------+
//| CLASSE QUANT SIMPLIFICADA                                        |
//+------------------------------------------------------------------+
class CMealReverseQuant {
public:
    double GetHurst(int period, int shift)
     {
        double p[]; 
        if(CopyClose(_Symbol,_Period,shift,period,p)!=period) return 0.5;
        double diffs[]; ArrayResize(diffs,period-1);
        double m_ret=0;
        for(int i=0;i<period-1;i++) { diffs[i]=p[i+1]-p[i]; m_ret+=diffs[i]; }
        m_ret/=(period-1);
        double std=0; for(int i=0;i<period-1;i++) std+=MathPow(diffs[i]-m_ret,2);
        std=MathSqrt(std/(period-1));
        if(std<=0) return 0.5;
        double mx=p[0], mn=p[0];
        for(int i=0;i<period;i++) { mx=MathMax(mx,p[i]); mn=MathMin(mn,p[i]); }
        if((mx-mn)<=0) return 0.5;
        return MathLog((mx-mn)/std)/MathLog(period);
    }
};
CMealReverseQuant quant;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit() {
   SetIndexBuffer(0, BufferBuy, INDICATOR_DATA);
   SetIndexBuffer(1, BufferSell, INDICATOR_DATA);
   SetIndexBuffer(2, BufferExit, INDICATOR_DATA);

   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetInteger(2, PLOT_ARROW, 159);

   for(int i=0; i<3; i++) PlotIndexSetDouble(i, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| DEINIT                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int r) { 
   ObjectsDeleteAll(0, "GP_INF_"); 
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| CALCULATION                                                      |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[],
                const double &close[], const long &tick_volume[], const long &volume[], const int &spread[])
{
   int limit = rates_total - prev_calculated;
   if(limit > 1) limit = rates_total - InpHowBar - 5;

   for(int i = limit; i >= 0; i--) {
      BufferBuy[i]  = EMPTY_VALUE;
      BufferSell[i] = EMPTY_VALUE;
      BufferExit[i] = EMPTY_VALUE;

      if(i >= rates_total - InpHowBar - 1) continue;

      double avgRange = 0;
      for(int j = 1; j <= InpHowBar; j++) avgRange += (high[i+j] - low[i+j]);
      avgRange = (avgRange / InpHowBar) * InpExpBar;
      
      bool volOK = (!SetAverageBar || MathAbs(open[i] - close[i]) >= avgRange);
      
      double h_val = quant.GetHurst(100, i);
      bool isSafe = (!Enable_MR_Filter || h_val < Hurst_Threshold);
      
      // SINAL
      if(volOK && isSafe) {
         double dist = InpDistance * _Point;
         double profitFactor = InpMinProfit / 100.0;

         if(open[i] < close[i] && high[i] >= (close[i+1] + dist)) {
            BufferBuy[i] = low[i] - (10 * _Point);
            BufferExit[i] = close[i] * (1.0 + profitFactor);
         }
         if(open[i] > close[i] && low[i] <= (close[i+1] - dist)) {
            BufferSell[i] = high[i] + (10 * _Point);
            BufferExit[i] = close[i] - (profitFactor * close[i]);
         }
      }

      if(i == 0) SimpleLabel(isSafe, h_val);
   }
   
   // ATUALIZAÇÃO DAS LINHAS (Chamada corrigida com Redraw)
   if(rates_total > 0) {
      UpdateDynamicLines(close[rates_total-1]);
      ChartRedraw();
   }

   return(rates_total);
}

//+------------------------------------------------------------------+
//| FUNÇÕES VISUAIS                                                  |
//+------------------------------------------------------------------+
void SimpleLabel(bool safe, double h)
{
   string objName = "GP_INF_STATUS";
   string statusText = (safe ? "Mean reversion " : "⚠ TRENDING (Bloqueado)");
   string msg = "Gold Pro v2.0 HalfLife: " + statusText + " - HURST: " + DoubleToString(h, 2);
   
   if(ObjectFind(0, objName) < 0) {
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, 15);
      ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, 40);
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 12);
      ObjectSetString(0, objName, OBJPROP_FONT, "Trebuchet MS");
   }
   
   ObjectSetString(0, objName, OBJPROP_TEXT, msg);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, safe ? clrTeal : clrCrimson);
}

void UpdateDynamicLines(double referencePrice)
{
   double sellLevel = referencePrice + (InpDistance * _Point);
   double buyLevel  = referencePrice - (InpDistance * _Point);

   // Linha de Venda (Superior)
   string lineSell = "GP_INF_Line_Sell";
   if(ObjectFind(0, lineSell) < 0) {
      ObjectCreate(0, lineSell, OBJ_HLINE, 0, 0, sellLevel);
      ObjectSetInteger(0, lineSell, OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, lineSell, OBJPROP_STYLE, STYLE_DOT);
   } else {
      ObjectSetDouble(0, lineSell, OBJPROP_PRICE, sellLevel);
   }

   // Linha de Compra (Inferior)
   string lineBuy = "GP_INF_Line_Buy";
   if(ObjectFind(0, lineBuy) < 0) {
      ObjectCreate(0, lineBuy, OBJ_HLINE, 0, 0, buyLevel);
      ObjectSetInteger(0, lineBuy, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, lineBuy, OBJPROP_STYLE, STYLE_DOT);
   } else {
      ObjectSetDouble(0, lineBuy, OBJPROP_PRICE, buyLevel);
   }
}