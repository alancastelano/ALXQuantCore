//+------------------------------------------------------------------+
//|                                                   ChartColor.mqh |
//|                        Copyright 2019, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2019, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"

enum ENUM_CHART_COLOR
{
   cC0=0,  // Black/Write
   cC1=1,  // ALX Claro
   cC2=2,  // ALX Escuro
   cC3=3,  // Profit
   cC4=4,  // Tryd
   cC5=5   // ALX Forex
};

//+------------------------------------------------------------------+
//|  Canais de Keltner v1.00                                         |
//+------------------------------------------------------------------+
input group "Chart color";
input ENUM_CHART_COLOR   InpChartColor        = 0;           // Chart template 



class CChartColor
  {
private:

public:

  void ALXTemplate(ENUM_CHART_COLOR pColor);
                    
  };
  
  
void CChartColor::ALXTemplate(ENUM_CHART_COLOR pColor)
{

   ChartSetInteger(0,CHART_SHIFT,1);


   ChartSetInteger(0,CHART_MODE,CHART_CANDLES);
   ChartSetInteger(0,CHART_SHOW_ONE_CLICK,false);

   switch(pColor)
   {
      case 0:
         ChartSetInteger(0,CHART_COLOR_BACKGROUND ,clrWhite);
         ChartSetInteger(0,CHART_COLOR_FOREGROUND ,clrBlack);
         ChartSetInteger(0,CHART_COLOR_CHART_UP   ,clrBlack);
         ChartSetInteger(0,CHART_COLOR_CHART_DOWN ,clrBlack);
         ChartSetInteger(0,CHART_COLOR_CANDLE_BULL,clrWhite);
         ChartSetInteger(0,CHART_COLOR_CANDLE_BEAR,clrBlack);
      break;
      
      case 1:
         ChartSetInteger(0,CHART_COLOR_BACKGROUND ,clrWhite);
         ChartSetInteger(0,CHART_COLOR_FOREGROUND ,clrBlack);
         ChartSetInteger(0,CHART_COLOR_CHART_UP   ,clrTeal);
         ChartSetInteger(0,CHART_COLOR_CHART_DOWN ,clrCrimson);
         ChartSetInteger(0,CHART_COLOR_CANDLE_BULL,clrTeal);
         ChartSetInteger(0,CHART_COLOR_CANDLE_BEAR,clrCrimson);
      break;
      
      case 2:
         ChartSetInteger(0,CHART_COLOR_BACKGROUND,clrBlack);
         ChartSetInteger(0,CHART_COLOR_FOREGROUND,clrWhite);
         ChartSetInteger(0,CHART_COLOR_CHART_UP,clrTeal);
         ChartSetInteger(0,CHART_COLOR_CHART_DOWN,clrCrimson);
         ChartSetInteger(0,CHART_COLOR_CANDLE_BULL,clrTeal);
         ChartSetInteger(0,CHART_COLOR_CANDLE_BEAR,clrCrimson);
      break;

      case 3:
         ChartSetInteger(0,CHART_COLOR_BACKGROUND,C'5,0,50');
         ChartSetInteger(0,CHART_COLOR_FOREGROUND,clrWhite);
         ChartSetInteger(0,CHART_COLOR_CHART_UP,clrLime);
         ChartSetInteger(0,CHART_COLOR_CHART_DOWN,clrRed);
         ChartSetInteger(0,CHART_COLOR_CANDLE_BULL,clrLime);
         ChartSetInteger(0,CHART_COLOR_CANDLE_BEAR,clrRed);
      break;

      case 4:
         ChartSetInteger(0,CHART_COLOR_BACKGROUND,C'50,50,50');
         ChartSetInteger(0,CHART_COLOR_FOREGROUND,clrWhite);
         ChartSetInteger(0,CHART_COLOR_CHART_UP,clrDodgerBlue);
         ChartSetInteger(0,CHART_COLOR_CHART_DOWN,clrRed);
         ChartSetInteger(0,CHART_COLOR_CANDLE_BULL,clrDodgerBlue);
         ChartSetInteger(0,CHART_COLOR_CANDLE_BEAR,clrRed);
      break;
      
      case 5:
          ChartSetInteger(0,CHART_COLOR_BACKGROUND ,clrOldLace);
         ChartSetInteger(0,CHART_COLOR_FOREGROUND ,clrBlack);
         ChartSetInteger(0,CHART_COLOR_CHART_UP   ,clrBlack);
         ChartSetInteger(0,CHART_COLOR_CHART_DOWN ,clrBlack);
         ChartSetInteger(0,CHART_COLOR_CANDLE_BULL,clrWhite);
         ChartSetInteger(0,CHART_COLOR_CANDLE_BEAR,clrBlack);
      break;
      
      
   }
   ChartRedraw(0);
}
//+------------------------------------------------------------------+
