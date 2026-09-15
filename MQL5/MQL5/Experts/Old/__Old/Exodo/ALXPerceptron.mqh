//+------------------------------------------------------------------+
//|                                                ALXPerceptron.mqh |
//|                                      Copyright 2022, ALX Invest. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2022, ALX Invest."
#property link      "https://www.mql5.com"

//+------------------------------------------------------------------+
//| Supervisor                                                       |
//+------------------------------------------------------------------+
double SupervisorV2()
  {
//--- return "0" if error
   if(pass==1)
     {
      double result_1=Perceptronv2(x11, x21, x31, x41, x51, x61, x71, x81);
      if(result_1!=0)
         return(result_1);
     }
   if(pass==2)
     {
      double result_2=Perceptronv2(x12, x22, x32, x42, x52, x62, x72, x82);
      if(result_2!=0)
         return(result_2);
     }
   if(pass==3)
     {
      double result_1=Perceptronv2(x11, x21, x31, x41, x51, x61, x71, x81);
      double result_2=Perceptronv2(x12, x22, x32, x42, x52, x62, x72, x82);
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
double Perceptronv2(double x1,double x2,double x3,double x4,double x5,double x6,double x7,double x8)
  {
   MqlRates rates[];
   double   ma[];
   ArraySetAsSeries(rates,true);
   ArraySetAsSeries(ma,true);

   double bop[];
   if(CopyBuffer(handle_bop,0,0,7,bop)<0) PrintFormat("Falha ao copiar os dados do indicador BOP, erro codigo %d",GetLastError());
   ArraySetAsSeries(bop,true);

   int buffer=0,start_pos=0,count=Inp_MA_ma_period*3+1;

   if(!iGetArray(handle_iMA,buffer,start_pos,count,ma) || CopyRates(m_symbol.Name(),Period(),start_pos,count,rates)!=count)
      return(0);

   double a1 = rates[0].close                   - ma[0];
   double a2 = rates[Inp_MA_ma_period].open     - ma[Inp_MA_ma_period];
   double a3 = rates[Inp_MA_ma_period*2].open   - ma[Inp_MA_ma_period*2];
   double a4 = rates[Inp_MA_ma_period*3].open   - ma[Inp_MA_ma_period*3];

   double a5 = bop[0];
   double a6 = bop[1];
   double a7 = bop[2];
   double a8 = bop[3];

   double result= (x1*a1 + x2*a2 + x3*a3 + x4*a4 + x5*a5 + x6*a6 + x7*a7 + x8*a8) + biasN1;

   if(result>0.0)
      return (1);
//---
   return(-1);
  }
  
  
//+------------------------------------------------------------------+
//| Perceptron                                                       |
//+------------------------------------------------------------------+
double Perceptron(double x1,double x2,double x3,double x4)
  {
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

   double result=x1*a1+x2*a2+x3*a3+x4*a4;
   if(result>0.0)
      return (1);
//---
   return(-1);
  }
//+------------------------------------------------------------------+

  