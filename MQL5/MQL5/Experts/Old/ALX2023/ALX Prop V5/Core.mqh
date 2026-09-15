//+------------------------------------------------------------------+
//|                                                         Core.mqh |
//|                                  Copyright 2023, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Ltd."
#property link      "https://www.mql5.com"

//---
#include <Trade\PositionInfo.mqh>
#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>  
#include <Expert\Money\MoneyFixedMargin.mqh>
#include <Expert\Money\MoneyFixedMargin.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\OrderInfo.mqh>

CPositionInfo           m_position;                   // trade position object
CTrade                  m_trade;                      // trading object
CSymbolInfo             m_symbol;                     // symbol info object
CAccountInfo            m_account;                    // account info wrapper
CMoneyFixedMargin       *m_money;
COrderInfo     m_order;                      // pending orders object

#include "Clogger.mqh"
CLogger logger;


//+------------------------------------------------------------------+
//|  PING                                                            |
//+------------------------------------------------------------------+
bool Ping()
{
   uint ping = TerminalInfoInteger(TERMINAL_PING_LAST)/1000;
   if(ping <= InpMaxPing)
      {
         return true;
      }
   return false;
}

//+------------------------------------------------------------------+
//|  Spread                                                          |
//+------------------------------------------------------------------+
bool isSpreadPermission(int spread_max)
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread<=spread_max)
      return(true);

   return(false);
}

//+------------------------------------------------------------------+
//|   NOVO DIA                                                       |
//+------------------------------------------------------------------+
bool NewDay()
{
   static datetime PrevDay;

   if(PrevDay < iTime(NULL, PERIOD_D1, 0)) {
      PrevDay = iTime(NULL, PERIOD_D1, 0);
      Print("Novo dia identificado");
      
      m_time.Init();
      
      countdays++;
      Print("Contador de dias: " + (string)countdays );
      
      return(true);
   }
   else {
      return(false);
   }
}  
  
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
//| Check the correctness of the order volume                        |
//+------------------------------------------------------------------+
bool CheckVolumeValue(double volume,string &error_description)
  {
   double min_volume=SymbolInfoDouble(Symbol(),SYMBOL_VOLUME_MIN);
   double max_volume=SymbolInfoDouble(Symbol(),SYMBOL_VOLUME_MAX);
   double volume_step=SymbolInfoDouble(Symbol(),SYMBOL_VOLUME_STEP);

   if(volume<min_volume)
     {
      error_description=StringFormat("Volume is less than the minimal allowed SYMBOL_VOLUME_MIN=%.2f",min_volume);
      return(false);
     }

   if(volume>max_volume)
     {
      error_description=StringFormat("Volume is greater than the maximal allowed SYMBOL_VOLUME_MAX=%.2f",max_volume);
      return(false);
     }

   int ratio=(int)MathRound(volume/volume_step);
   if(MathAbs(ratio*volume_step-volume)>0.0000001)
     {
      error_description=StringFormat("Volume is not a multiple of the minimal step SYMBOL_VOLUME_STEP=%.2f, the closest correct volume is %.2f",
                                     volume_step,ratio*volume_step);
      return(false);
     }
   error_description="Correct volume value";
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
//| Get Time for specified bar index                                 | 
//+------------------------------------------------------------------+ 
datetime iTime(const int index,string symbol=NULL,ENUM_TIMEFRAMES timeframe=PERIOD_CURRENT)
  {
   if(symbol==NULL)
      symbol=Symbol();
   if(timeframe==0)
      timeframe=Period();
   datetime Time[1];
   datetime time=0;
   int copied=CopyTime(symbol,timeframe,index,1,Time);
   if(copied>0) time=Time[0];
   return(time);
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


void ChartClear(void)
{
   ObjectsDeleteAll(0,0,-1);
   DeleteAllIndicators();
}



void DeleteAllIndicators(void)
{
   int subWindows = (int)ChartGetInteger(0,CHART_WINDOWS_TOTAL);
   for(int i=subWindows-1;i>=0;i--)
     {
      int inds = ChartIndicatorsTotal(0,i);
      if(inds>=1)
        {
         for(int j=inds;j>=0;j--)
           {
            string indName = ChartIndicatorName(0,i,j);
            ChartIndicatorDelete(0,i,indName);
           }
        }
     }
}

/*
//+------------------------------------------------------------------+
//| Normalize Volume                                                 |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume)
  {
    double resultado = 0;
    double LoteMin = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
    double LoteMax = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
    double LotePasso = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
    if (volume > 0)
      {
        volume = MathMax(LoteMin,volume);
        volume = LoteMin+NormalizeDouble((volume-LoteMin)/LotePasso,0)*LotePasso;
        resultado = MathMin(LoteMax,volume);
      }
    else
      {
        resultado = LoteMin;
        double compra_margem= m_account.FreeMarginCheck(_Symbol,ORDER_TYPE_BUY,resultado,SymbolInfoDouble(_Symbol,SYMBOL_ASK));
        double venda_margem = m_account.FreeMarginCheck(_Symbol,ORDER_TYPE_SELL,resultado,SymbolInfoDouble(_Symbol,SYMBOL_BID));
        if (compra_margem < 0 || venda_margem < 0)
          {
            if (resultado > LoteMin)
              {
                resultado = resultado*m_account.FreeMargin()/(m_account.FreeMargin()-MathMin(compra_margem,venda_margem));
                resultado = NormalizeVolume(resultado);
              }
            else {resultado = 0;}
          }
      }
    return(NormalizeDouble(resultado,2));
  }
*/  