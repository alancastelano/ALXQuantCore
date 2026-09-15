//+------------------------------------------------------------------+
//|                                                ALXPerceptron.mqh |
//|                                  Copyright 2023, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Ltd."
#property link      "https://www.mql5.com"

input group "== ALX Perceptron =="
input int                  Inp_MA_ma_period     = 20;             // MA: averaging period 
input int                  Inp_MA_ma_shift      = 0;              // MA: horizontal shift 
input ENUM_MA_METHOD       Inp_MA_ma_method     = MODE_LWMA;      // MA: smoothing type 
input ENUM_APPLIED_PRICE   Inp_MA_applied_price = PRICE_WEIGHTED; // MA: type of price 
//---
input double   x11   = -1.00;
input double   x21   = -1.00;
input double   x31   = -1.00;
input double   x41   = -1.00;

input double   x12   = -1.00;
input double   x22   = -1.00;
input double   x32   = -1.00;
input double   x42   = -1.00;

input int   pass  = 1;

int    handle_iMA;                           // variable for storing the handle of the iMA indicator 


//+------------------------------------------------------------------+
//| Get value of buffers                                             |
//+------------------------------------------------------------------+
double iGetArray(const int handle,const int buffer,const int start_pos,const int count,double &arr_buffer[])
  {
   bool result=true;
   if(!ArrayIsDynamic(arr_buffer))
     {
      Print("This a no dynamic array!");
      return(false);
     }
   ArrayFree(arr_buffer);
//--- reset error code 
   ResetLastError();
//--- fill a part of the iBands array with values from the indicator buffer
   int copied=CopyBuffer(handle,buffer,start_pos,count,arr_buffer);
   if(copied!=count)
     {
      //--- if the copying fails, tell the error code 
      PrintFormat("Failed to copy data from the indicator, error code %d",GetLastError());
      //--- quit with zero result - it means that the indicator is considered as not calculated 
      return(false);
     }
   return(result);
  }
//+------------------------------------------------------------------+
//| Supervisor                                                       |
//+------------------------------------------------------------------+
double Supervisor()
  {
//--- return "0" if error
   if(pass==1)
     {
      double result_1=Perceptron(x11, x21, x31, x41);
      if(result_1!=0)
         return(result_1);
     }
   if(pass==2)
     {
      double result_2=Perceptron(x12, x22, x32, x42);
      if(result_2!=0)
         return(result_2);
     }
   if(pass==3)
     {
      double result_1=Perceptron(x11, x21, x31, x41);
      double result_2=Perceptron(x12, x22, x32, x42);
      if(result_1!=0 && result_2!=0)
        {
         if(result_1==result_2)
            return(result_1);
        }
     }
//---
   return (0);
  }
//+------------------------------------------------------------------+
//| Perceptron                                                       |
//+------------------------------------------------------------------+
double Perceptron(double x1,double x2,double x3,double x4)
  {
//--- return "0" if error
   double w1 = x1;
   double w2 = x2;
   double w3 = x3;
   double w4 = x4;

   MqlRates rates[];
   double   ma[];
   ArraySetAsSeries(rates,true);
   ArraySetAsSeries(ma,true);
   int buffer=0,start_pos=0,count=Inp_MA_ma_period*3+1;

   if(!iGetArray(handle_iMA,buffer,start_pos,count,ma) || CopyRates(m_symbol.Name(),Period(),start_pos,count,rates)!=count)
      return(0);

   double a1 = rates[0].close                   - ma[0];
   double a2 = rates[Inp_MA_ma_period].open     - ma[Inp_MA_ma_period];
   double a3 = rates[Inp_MA_ma_period*2].open   - ma[Inp_MA_ma_period*2];
   double a4 = rates[Inp_MA_ma_period*3].open   - ma[Inp_MA_ma_period*3];
   double result=w1*a1+w2*a2+w3*a3+w4*a4;
   if(result>0.0)
      return (1);
//---
   return(-1);
  }

