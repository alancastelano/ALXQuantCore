//+------------------------------------------------------------------+
//|                                           LifeHack Drawdown Load |
//|                              Copyright © 2016, Vladimir Karputov |
//|                                           http://wmua.ru/slesar/ |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2016, Vladimir Karputov"
#property link      "http://wmua.ru/slesar/"
#property version   "1.006"
#property description "Drawdown Load Indicators"
#property indicator_separate_window
#property indicator_buffers 2
#property indicator_plots   2
//--- plot Drawdown
#property indicator_label1  "Drawdown (line), %"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrFireBrick
#property indicator_style1  STYLE_SOLID
#property indicator_width1  1
//--- plot Load
#property indicator_label2  "Load (histogram), %"
#property indicator_type2   DRAW_HISTOGRAM
#property indicator_color2  clrGold
#property indicator_style2  STYLE_SOLID
#property indicator_width2  1
//--- indicator buffers
double         DrawdownBuffer[];
double         LoadBuffer[];
//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- indicator buffers mapping
   SetIndexBuffer(0,DrawdownBuffer,INDICATOR_DATA);
   SetIndexBuffer(1,LoadBuffer,INDICATOR_DATA);
//PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,0);
//PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,0);
   ArraySetAsSeries(DrawdownBuffer,true);
   ArraySetAsSeries(LoadBuffer,true);
//--- name for DataWindow and indicator subwindow label 
   IndicatorSetString(INDICATOR_SHORTNAME,"Drawdown Load ");
//--- construct a short indicator name based on input parameters 
   IndicatorSetInteger(INDICATOR_DIGITS,2);
//---
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
   if(prev_calculated==0)
     {
      for(int i=0;i<rates_total;i++)
        {
         DrawdownBuffer[i]=0.0;
         LoadBuffer[i]=0.0;
        }
      return(rates_total);
     }
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdown=0.0;
   if(balance>equity)
      drawdown=(balance-equity)/balance*100.0;
   else
      drawdown=0.0;
//---
   double load=0.0;
   double margin=AccountInfoDouble(ACCOUNT_MARGIN);
   load=margin/equity*100.0;
//---
   if(DrawdownBuffer[0]<drawdown)
      DrawdownBuffer[0]=drawdown;
   if(LoadBuffer[0]<load)
      LoadBuffer[0]=load;
//Print("drawdown ",drawdown,"; load ",load);
//--- return value of prev_calculated for next call
   return(rates_total);
  }
//+------------------------------------------------------------------+
