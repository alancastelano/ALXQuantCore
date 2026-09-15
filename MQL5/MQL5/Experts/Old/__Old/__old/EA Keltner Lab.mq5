//+------------------------------------------------------------------+
//|                                               EA Keltner Lab.mq5 |
//|                                  Copyright 2023, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//| #Resources                                                       |
//+------------------------------------------------------------------+
#resource "\\Indicators\\keltnerChannel.ex5"
//+------------------------------------------------------------------+

#include <Trade\PositionInfo.mqh>
#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>  
CPositionInfo  m_position;                   // trade position object
CTrade         m_trade;                      // trading object
CSymbolInfo    m_symbol;                     // symbol info object

input ulong    m_magic           = 32995373; // magic number
input double   InpLots           = 0.01;      // Lots
input ushort   InpTakeProfit     = 10;       // Take Profit (in pips)


int      handle_keltner;
double   ExtTakeProfit=0.0;
ulong    m_slippage=30;                // slippage

double   m_adjusted_point;   



//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//---
   if(!m_symbol.Name(Symbol())) // sets symbol name
      return(INIT_FAILED);
   RefreshRates();

//---
   m_trade.SetExpertMagicNumber(m_magic);
//---
   if(IsFillingTypeAllowed(SYMBOL_FILLING_FOK))
      m_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if(IsFillingTypeAllowed(SYMBOL_FILLING_IOC))
      m_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
//---
   m_trade.SetDeviationInPoints(m_slippage);
//--- tuning for 3 or 5 digits
   int digits_adjust=1;
   if(m_symbol.Digits()==3 || m_symbol.Digits()==5)
      digits_adjust=10;
   m_adjusted_point=m_symbol.Point()*digits_adjust;

   ExtTakeProfit=InpTakeProfit*m_adjusted_point;



   handle_keltner= iCustom(_Symbol,Period(),"::Indicators\\keltnerChannel.ex5",9,2.2,true,MODE_EMA,PRICE_CLOSE);

   
//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//---
   
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//---
   ResetLastError();
     
   double Upper[],Mid[],Down[];
   if(CopyBuffer(handle_keltner,0,0,3,Upper)   <0) PrintFormat("Failed to copy data from the Keltner indicator, error code %d",GetLastError());
   if(CopyBuffer(handle_keltner,1,0,3,Mid)     <0) PrintFormat("Failed to copy data from the Keltner indicator, error code %d",GetLastError());
   if(CopyBuffer(handle_keltner,2,0,3,Down)    <0) PrintFormat("Failed to copy data from the Keltner indicator, error code %d",GetLastError());

   ArraySetAsSeries(Upper,true);
   ArraySetAsSeries(Down,true);

   MqlRates rt[];
   ArraySetAsSeries(rt,true);
   if(CopyRates(_Symbol,PERIOD_CURRENT,0,3,rt)<0)
     {
      PrintFormat("Falha ao copiar rates, erro codigo %d",GetLastError());
      return;
     }


   bool buy_open  = rt[2].close < Down[2] ; 
   bool sell_open = rt[2].close > Upper[2] ;


//   bool buy_open  = rt[2].close < Down[2] && rt[1].close > Down[1]  ; 
//   bool sell_open = rt[2].close > Upper[2] && rt[1].close < Upper[1] ;


//   if(buy_open)
//     {
//       ObjectCreate(0,"R_"+rt[0].time,OBJ_ARROW_BUY,0,rt[1].time,rt[1].low);
//     }
//   else if(sell_open)
//     {
//       ObjectCreate(0,"R_"+rt[0].time,OBJ_ARROW_SELL,0,rt[1].time,rt[1].low);
//     }



   int count_buys=0;
   int count_sells=0;
   CalculatePositions(count_buys,count_sells);

   if(count_buys==0 && count_sells==0)
     {
      //--- check condition on BUY
      if(buy_open)
        {
         double tp=(InpTakeProfit==0)?0.0:m_symbol.Ask()+ExtTakeProfit;
         m_trade.Buy(0.01,m_symbol.Name(),m_symbol.Ask(),0.0,m_symbol.NormalizePrice(tp));
        }
      //--- check condition on SELL
      else if(sell_open)
        {
         double tp=(InpTakeProfit==0)?0.0:m_symbol.Bid()-ExtTakeProfit;
         m_trade.Sell(0.01,m_symbol.Name(),m_symbol.Bid(),0.0,m_symbol.NormalizePrice(tp));
        }
     }




   
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Refreshes the symbol quotes data                                 |
//+------------------------------------------------------------------+
bool RefreshRates(void)
  {
//--- refresh rates
   if(!m_symbol.RefreshRates())
     {
      Print("RefreshRates error");
      return(false);
     }
//--- protection against the return value of "zero"
   if(m_symbol.Ask()==0 || m_symbol.Bid()==0)
      return(false);
//---
   return(true);
  }
  
//+------------------------------------------------------------------+ 
//| Checks if the specified filling mode is allowed                  | 
//+------------------------------------------------------------------+ 
bool IsFillingTypeAllowed(int fill_type)
  {
//--- Obtain the value of the property that describes allowed filling modes 
   int filling=m_symbol.TradeFillFlags();
//--- Return true, if mode fill_type is allowed 
   return((filling & fill_type)==fill_type);
  } 
  
//+------------------------------------------------------------------+
//| Calculate positions Buy and Sell                                 |
//+------------------------------------------------------------------+
void CalculatePositions(int &count_buys,int &count_sells)
  {
   count_buys=0.0;
   count_sells=0.0;

   for(int i=PositionsTotal()-1;i>=0;i--)
      if(m_position.SelectByIndex(i)) // selects the position by index for further access to its properties
         if(m_position.Symbol()==m_symbol.Name() && m_position.Magic()==m_magic)
           {
            if(m_position.PositionType()==POSITION_TYPE_BUY)
               count_buys++;

            if(m_position.PositionType()==POSITION_TYPE_SELL)
               count_sells++;
           }
//---
   return;
  }   