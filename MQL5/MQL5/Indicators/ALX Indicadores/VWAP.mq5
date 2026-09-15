//+------------------------------------------------------------------+
//|                                                     ALX VWAP.mq5 |
//|                     Copyright 2016, SOL Digital Consultoria LTDA |
//|                          http://www.soldigitalconsultoria.com.br |
//+------------------------------------------------------------------+
#property copyright         "Copyright 2016"
#property version           "2.0"

#property indicator_chart_window
#property indicator_buffers 1
#property indicator_plots   1

#property indicator_label1  "VWAP"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDeepPink
#property indicator_style1  STYLE_DASH
#property indicator_width1  1

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
enum DATE_TYPE 
  {
   DAILY,
   WEEKLY,
   MONTHLY
  };

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime CreateDateTime(DATE_TYPE nReturnType=DAILY,datetime dtDay=D'2000.01.01 00:00:00',int pHour=0,int pMinute=0,int pSecond=0) 
  {
   datetime    dtReturnDate;
   MqlDateTime timeStruct;

   TimeToStruct(dtDay,timeStruct);
   timeStruct.hour = pHour;
   timeStruct.min  = pMinute;
   timeStruct.sec  = pSecond;
   dtReturnDate=(StructToTime(timeStruct));

   return dtReturnDate;
  }
input   bool        Calc_Every_Tick     = false;

string          Indicator_Name      = "VWAP";
bool            Enable_Daily        = true;
bool            Show_Daily_Value    = false;



double          VWAP_Buffer_Daily[];
double          nPriceArr[],nTotalTPV[],nTotalVol[];
double          nSumDailyTPV = 0;
double          nSumDailyVol = 0;
int             nIdxDaily=0,nIdx=0;
bool            bIsFirstRun=true;
string          sDailyStr = "";
datetime        dtLastDay = CreateDateTime(DAILY);
ENUM_TIMEFRAMES LastTimePeriod=PERIOD_MN1;
int             nStringYDistance=40;
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int OnInit() 
  {
   IndicatorSetInteger(INDICATOR_DIGITS,_Digits);

   SetIndexBuffer(0,VWAP_Buffer_Daily,INDICATOR_DATA);

   if(Show_Daily_Value) 
     {
      ObjectCreate(0,"VWAP_Daily",OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,"VWAP_Daily",OBJPROP_CORNER,3);
      ObjectSetInteger(0,"VWAP_Daily",OBJPROP_XDISTANCE,180);
      ObjectSetInteger(0,"VWAP_Daily",OBJPROP_YDISTANCE,nStringYDistance);
      ObjectSetInteger(0,"VWAP_Daily",OBJPROP_COLOR,indicator_color1);
      ObjectSetInteger(0,"VWAP_Daily",OBJPROP_FONTSIZE,7);
      ObjectSetString(0,"VWAP_Daily",OBJPROP_FONT,"Verdana");
      ObjectSetString(0,"VWAP_Daily",OBJPROP_TEXT," ");
      nStringYDistance=nStringYDistance+20;
     }
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int pReason) 
  {
   if(Show_Daily_Value) ObjectDelete(0,"VWAP_Daily");
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int OnCalculate(const int       rates_total,
                const int       prev_calculated,
                const datetime  &time[],
                const double    &open[],
                const double    &high[],
                const double    &low[],
                const double    &close[],
                const long      &tick_volume[],
                const long      &volume[],
                const int       &spread[]) 
  {

   if(PERIOD_CURRENT!=LastTimePeriod) 
     {
      bIsFirstRun=true;
      LastTimePeriod=PERIOD_CURRENT;
     }

   if(rates_total>prev_calculated || bIsFirstRun || Calc_Every_Tick) 
     {
      ArrayResize(nPriceArr,rates_total);
      ArrayResize(nTotalTPV,rates_total);
      ArrayResize(nTotalVol,rates_total);

      if(Enable_Daily)   {nIdx = nIdxDaily;   nSumDailyTPV = 0;   nSumDailyVol = 0;}

      for(; nIdx<rates_total; nIdx++) 
        {
         VWAP_Buffer_Daily[nIdx]=EMPTY_VALUE;

         if(CreateDateTime(DAILY,time[nIdx])!=dtLastDay) 
           {
            nIdxDaily=nIdx;
            nSumDailyTPV = 0;
            nSumDailyVol = 0;
           }

         nPriceArr[nIdx] = 0;
         nTotalTPV[nIdx] = 0;
         nTotalVol[nIdx] = 0;

         nPriceArr[nIdx]=close[nIdx];

         if(tick_volume[nIdx]) 
           {
            nTotalTPV[nIdx] = (nPriceArr[nIdx] * tick_volume[nIdx]);
            nTotalVol[nIdx] = (double)tick_volume[nIdx];
              } else if(volume[nIdx]) {
            nTotalTPV[nIdx] = (nPriceArr[nIdx] * volume[nIdx]);
            nTotalVol[nIdx] = (double)volume[nIdx];
           }

         if(Enable_Daily && (nIdx>=nIdxDaily)) 
           {
            nSumDailyTPV += nTotalTPV[nIdx];
            nSumDailyVol += nTotalVol[nIdx];

            if(nSumDailyVol)
               VWAP_Buffer_Daily[nIdx]=(nSumDailyTPV/nSumDailyVol);

            if((sDailyStr!="VWAP "+(string)NormalizeDouble(VWAP_Buffer_Daily[nIdx],_Digits)) && Show_Daily_Value) 
              {
               sDailyStr="VWAP "+(string)NormalizeDouble(VWAP_Buffer_Daily[nIdx],_Digits);
               ObjectSetString(0,"VWAP_Daily",OBJPROP_TEXT,sDailyStr);
              }
           }

         dtLastDay=CreateDateTime(DAILY,time[nIdx]);
        }

      bIsFirstRun=false;
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
