//+------------------------------------------------------------------+
//|                                                ALXPerceptron.mqh |
//|                                      Copyright 2022, ALX Invest. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2022, ALX Invest."
#property link      "https://www.mql5.com"
#property version   "1.00"


//+------------------------------------------------------------------+
//| #inputs                                                          |
//+------------------------------------------------------------------+
sinput group "== ALX Perceptron MA ==";
input bool                 InpMA           = true;            // MA: Signal  
input int                  InpMAPeriod     =  20;             // MA: averaging period
input int                  InpMAShift      =  0;              // MA: horizontal shift
input ENUM_MA_METHOD       InpMAMethod     =  MODE_LWMA;      // MA: smoothing type
input ENUM_APPLIED_PRICE   InpMAPrice      =  PRICE_WEIGHTED; // MA: type of price

sinput group "== RNA Perceptron MA ==";
input int   x11   = 100;
input int   x21   = 100;
input int   x31   = 100;
input int   x41   = 100;
input int   x12   = 100;
input int   x22   = 100;
input int   x32   = 100;
input int   x42   = 100;
input int   pass  = 1;
//+------------------------------------------------------------------+


class CALXPerceptron
  {
private:
   int handle_ind;
   int   Supervisor();
   int   Perceptron(int x1,int x2,int x3,int x4);
   double iGetArray(const int handle,const int buffer,const int start_pos,const int count,double &arr_buffer[]);

public:
   bool  Status(void) { return(InpMA); }

   bool  Init(void);
   int   Signal(void);

  };
//+------------------------------------------------------------------+

bool CALXPerceptron::Init(void)
{
   handle_ind=iMA(m_symbol.Name(),Period(),InpMAPeriod,InpMAShift,InpMAMethod,InpMAPrice);

   if(handle_ind==INVALID_HANDLE)
     {
         PrintFormat("Falha ao criar handle do indicador MA. Erro: %d",GetLastError());
      return(false);
     }
   else
     {
         if(!ChartIndicatorAdd(0,0,handle_ind))
            {
               PrintFormat("Falha ao adicionar o indicador MA. Erro: %d",  GetLastError());
               return(false);
            }   
     }  

   return(true);
}


//+------------------------------------------------------------------+
//| Supervisor                                                       |
//+------------------------------------------------------------------+
int CALXPerceptron::Signal()
  {
      int result=Supervisor();

      if(result<0) return(1);
      if(result>0) return(2);

   return (-1);
  }




//+------------------------------------------------------------------+
//| Supervisor                                                       |
//+------------------------------------------------------------------+
int CALXPerceptron::Supervisor()
  {
//--- return "0" if error
   if(pass==1)
     {
      int result_1=Perceptron(x11, x21, x31, x41);
      if(result_1!=0)
         return(result_1);
     }
   if(pass==2)
     {
      int result_2=Perceptron(x12, x22, x32, x42);
      if(result_2!=0)
         return(result_2);
     }
   if(pass==3)
     {
      int result_1=Perceptron(x11, x21, x31, x41);
      int result_2=Perceptron(x12, x22, x32, x42);
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
int CALXPerceptron::Perceptron(int x1,int x2,int x3,int x4)
  {
//--- return "0" if error
   double       w1 = x1 - 100.0;
   double       w2 = x2 - 100.0;
   double       w3 = x3 - 100.0;
   double       w4 = x4 - 100.0;

   MqlRates rates[];
   double   ma[];
   ArraySetAsSeries(rates,true);
   ArraySetAsSeries(ma,true);
   int buffer=0,start_pos=0,count=InpMAPeriod*3+1;

   if(!iGetArray(handle_ind,buffer,start_pos,count,ma) || CopyRates(m_symbol.Name(),Period(),start_pos,count,rates)!=count)
      return(0);

   double a1 = rates[0].close                   - ma[0];
   double a2 = rates[InpMAPeriod].open     - ma[InpMAPeriod];
   double a3 = rates[InpMAPeriod*2].open   - ma[InpMAPeriod*2];
   double a4 = rates[InpMAPeriod*3].open   - ma[InpMAPeriod*3];
   double result=w1*a1+w2*a2+w3*a3+w4*a4;
   if(result>0.0)
      return (1);
//---
   return(-1);
  }
  
//+------------------------------------------------------------------+
//| Get value of buffers                                             |
//+------------------------------------------------------------------+
double CALXPerceptron::iGetArray(const int handle,const int buffer,const int start_pos,const int count,double &arr_buffer[])
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
  
  