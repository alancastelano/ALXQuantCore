//+------------------------------------------------------------------+
//|                                      ALX Global Risk Manager.mq5 |
//|                                      Copyright 2022, ALX Invest. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2022, ALX Invest."
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//| defines                                                          |
//+------------------------------------------------------------------+
/*
   Risk Manager Global:
                           Loss Global   |  Profit Global x (Rate) | Loss Symbol | Profit Symbol 
      1. % risk balance:
      2. Risk month ($)
      3. Risk week ($)
      4. Risk daily ($)
      5. num. operation
      6. risk operation
      7. n. symbols
*/
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| #inputs                                                          |
//+------------------------------------------------------------------+
input double      InpCapitalReference  = 10000;    //-- % risk max. month
input double      InpRiskMaxMonth      = 10;       //-- % risk max. month
input int         InpLifeTimeMonths    = 1;        //-- Numeros de meses de vida
input double      InpProfitRatio       = 3;        //-- Profit ratio vs loss
input int         InpQtdeSymbols       = 8;       //-- Qtde numeros bots Symbols
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| defines globais                                                  |
//+------------------------------------------------------------------+
double _equity_global             = InpCapitalReference;                               //-- Equity global reference
double _risk_global               = (double)(_equity_global * (InpRiskMaxMonth/100));   //-- % risk global
//+------------------------------------------------------------------+
double _global_Loss_month    = (double)(_risk_global / InpLifeTimeMonths);    //-- % risk global month
double _global_Loss_week     = (double)(_global_Loss_month / 4);              //-- % risk global week
double _global_Loss_daily    = (double)(_global_Loss_week  / 5);              //-- % risk global daily
//+------------------------------------------------------------------+
double _global_profit_month  = (double)(_global_Loss_month * InpProfitRatio); //-- % risk global month
double _global_profit_week   = (double)(_global_Loss_week  * InpProfitRatio); //-- % risk global week
double _global_profit_daily  = (double)(_global_Loss_daily * InpProfitRatio); //-- % risk global daily
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| defines globais                                                  |
//+------------------------------------------------------------------+
double _global_Loss_month_symbol   = (double)(_global_Loss_month   / InpQtdeSymbols);   //-- % risk global month
double _global_Loss_week_symbol    = (double)(_global_Loss_week    / InpQtdeSymbols);   //-- % risk global week
double _global_Loss_daily_symbol   = (double)(_global_Loss_daily   / InpQtdeSymbols);   //-- % risk global daily
//+----------------------------------------------------------------+
double _global_profit_month_symbol = (double)(_global_profit_month / InpQtdeSymbols);   //-- % risk global month
double _global_profit_week_symbol  = (double)(_global_profit_week  / InpQtdeSymbols);   //-- % risk global week
double _global_profit_daily_symbol = (double)(_global_profit_daily / InpQtdeSymbols);   //-- % risk global daily
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- create timer
   EventSetTimer(60);

   if(!CreateVarGlobal("1_equity_global",InpCapitalReference))        return(INIT_FAILED); //-- Equity Global reference
   if(!CreateVarGlobal("1_risk_global",_risk_global))                 return(INIT_FAILED); //-- Risk Global reference
   
   if(!CreateVarGlobal("2_global_Loss_month" , _global_Loss_month ))  return(INIT_FAILED); //-- Global loss month
   if(!CreateVarGlobal("2_global_Loss_week"  , _global_Loss_week  ))  return(INIT_FAILED); //-- Global loss week
   if(!CreateVarGlobal("2_global_Loss_daily" , _global_Loss_daily ))  return(INIT_FAILED); //-- Global loss daily

   if(!CreateVarGlobal("3_global_profit_month" , _global_profit_month ))  return(INIT_FAILED); //-- Global profit month
   if(!CreateVarGlobal("3_global_profit_week"  , _global_profit_week  ))  return(INIT_FAILED); //-- Global profit week
   if(!CreateVarGlobal("3_global_profit_daily" , _global_profit_daily ))  return(INIT_FAILED); //-- Global profit daily





   if(!CreateVarGlobal("4_global_Loss_month_symbol"  , _global_Loss_month_symbol ))  return(INIT_FAILED); //-- Global profit month
   if(!CreateVarGlobal("4_global_Loss_week_symbol"  , _global_Loss_week_symbol  ))  return(INIT_FAILED); //-- Global profit week
   if(!CreateVarGlobal("4_global_Loss_daily_symbol" , _global_Loss_daily_symbol ))  return(INIT_FAILED); //-- Global profit daily

   if(!CreateVarGlobal("5_global_profit_month_symbol" , _global_profit_month_symbol ))  return(INIT_FAILED); //-- Global profit month
   if(!CreateVarGlobal("5_global_profit_week_symbol"  , _global_profit_week_symbol  ))  return(INIT_FAILED); //-- Global profit week
   if(!CreateVarGlobal("5_global_profit_daily_symbol" , _global_profit_daily_symbol ))  return(INIT_FAILED); //-- Global profit daily



   
//---
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
bool CreateVarGlobal(string var,double value)
{
   if(GlobalVariableCheck(var))
      GlobalVariableDel(var);

   if(!GlobalVariableSet(var,NormalizeDouble(value,1)))
      {
         PrintFormat("Falha ao criar variavel %s. Erro: %d",var,GetLastError());
         return(false);
      }

   return(true);
}




//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- destroy timer
   EventKillTimer();
   
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
//---
   
  }
//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
  {
//---
   
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
