//+------------------------------------------------------------------+
//|                                                         Momo.mqh |
//|                                  Copyright 2021, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2021, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

   int handle_ma20;
   int handle_macd;

class CMomo
  {
private:

public:
   void Init(void);
   uint signal(void);

  };
//+------------------------------------------------------------------+

void CMomo::Init(void)
{
   handle_ma20 = iMA(_Symbol,_Period,50,0,MODE_EMA,PRICE_CLOSE);
   handle_macd = iMACD(_Symbol,_Period,12,26,9,PRICE_CLOSE);
   
   ChartIndicatorAdd(0,0,handle_ma20);
   ChartIndicatorAdd(0,0,handle_macd);
}

uint CMomo::signal(void)
{
   uint res=0;

   ResetLastError();
   
   double ma20[];
   ArraySetAsSeries(ma20,true);
   if(CopyBuffer(handle_ma20,0,0,4,ma20)<0) Print("Erro ao copiar ma 20: ",GetLastError());

   double macd[],signal[];
   ArraySetAsSeries(macd,true);
   ArraySetAsSeries(signal,true);
   if(CopyBuffer(handle_macd,0,0,4,macd)<0)   Print("Erro ao copiar macd: ",GetLastError());
   if(CopyBuffer(handle_macd,1,0,4,signal)<0) Print("Erro ao copiar signal: ",GetLastError());

   MqlTick last_tick;
   SymbolInfoTick(m_symbol.Name(),last_tick);

   double ask = last_tick.ask;
   double bid = last_tick.bid;
   
   if(macd[1]<=0 && macd[0]>0 ) res=1;
   if(macd[1]>=0 && macd[0]<0 ) res=2;
   
   return(res);
}



//   if(ask>ma20[0] && macd[1]<0.0 && macd[0]>0.0) res=1;
//   if(bid<ma20[0] && macd[1]>0.0 && macd[0]<0.0) res=2;
