//+------------------------------------------------------------------+
//|                                                    ALXPropA1.mq5 |
//|                                       Copyright 2023, Castelano. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#define   _version "2.00"
#property version _version

#property description "ALX Keltner Prop."
#property description "2.00 - Projeto Optimizado (Todo codigo)."

#include <ALXFramework\Core\Core.mqh> CCore m_core;

//+------------------------------------------------------------------+
//| # Strategy                                                       |
//+------------------------------------------------------------------+
#include <ALXFramework\Strategy\Keltner.mqh> CKeltner m_keltner;
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
    if(!m_core.Init())
      return(INIT_FAILED);
      
    if(!m_keltner.Init())
      return(INIT_FAILED);  

//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)  { m_core.DeInit(); }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   uint Signal = m_keltner.Signal();
   bool buy_signal  = (Signal==1);
   bool sell_signal = (Signal==2);
   
   m_core.Processor(buy_signal,sell_signal);


}
//+------------------------------------------------------------------+
//| TradeTransaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
  {
//---
   
  }
//+------------------------------------------------------------------+
//| Tester function                                                  |
//+------------------------------------------------------------------+
double OnTester()
  {
//---
   double ret=0.0;
//---

//---
   return(ret);
  }
//+------------------------------------------------------------------+
