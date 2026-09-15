//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|                                      Copyright 2022, ALX Invest. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2022, ALX Invest."
#property link      "https://www.mql5.com"


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
input double      InpRiskMaxMonth      = 2;        //-- % risk max. month
input int         InpLifeTimeMonths    = 6;        //-- Numeros de meses de vida
input double      InpProfitRatio       = 3;        //-- Profit ratio vs loss
input int         InpQtdeSymbols       = 10;       //-- Qtde numeros bots Symbols
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| defines globais                                                  |
//+------------------------------------------------------------------+
double equity_global             = InpCapitalReference;                               //-- Equity global reference
double risk_global               = (double)(equity_global * (InpRiskMaxMonth/100));   //-- % risk global
//+------------------------------------------------------------------+
double risk_global_Loss_month    = (double)(risk_global / InpLifeTimeMonths);         //-- % risk global month
double risk_global_Loss_week     = (double)(risk_global_Loss_month / 4);              //-- % risk global week
double risk_global_Loss_daily    = (double)(risk_global_Loss_week  / 5);              //-- % risk global daily
//+------------------------------------------------------------------+
double risk_global_profit_month  = (double)(risk_global_Loss_month * InpProfitRatio); //-- % risk global month
double risk_global_profit_week   = (double)(risk_global_Loss_week  * InpProfitRatio); //-- % risk global week
double risk_global_profit_daily  = (double)(risk_global_Loss_daily * InpProfitRatio); //-- % risk global daily
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| defines globais                                                  |
//+------------------------------------------------------------------+
double risk_global_Loss_month_symbol   = (double)(risk_global_Loss_month   / InpQtdeSymbols);   //-- % risk global month
double risk_global_Loss_week_symbol    = (double)(risk_global_Loss_week    / InpQtdeSymbols);   //-- % risk global week
double risk_global_Loss_daily_symbol   = (double)(risk_global_Loss_daily   / InpQtdeSymbols);   //-- % risk global daily
//+------------------------------------------------------------------+
double risk_global_profit_month_symbol = (double)(risk_global_profit_month / InpQtdeSymbols);   //-- % risk global month
double risk_global_profit_week_symbol  = (double)(risk_global_Loss_week    / InpQtdeSymbols);   //-- % risk global week
double risk_global_profit_daily_symbol = (double)(risk_global_Loss_daily   / InpQtdeSymbols);   //-- % risk global daily
//+------------------------------------------------------------------+



