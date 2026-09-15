//+------------------------------------------------------------------+
//|                                                  RiskManager.mqh |
//|                                       Copyright 2023, Castelano. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Castelano."
#property link      "https://www.mql5.com"
#property version   "1.00"

/*
   Featureas:
   - Float loss >= % Equity
   - Spread <= X
   - Daily loss >= % Equity
   - Daily N. max. Ordens
   - Daily N. max. Positions
   - RRR <= 1:1
*/


class CRiskManager
  {
private:

public:
                     CRiskManager();
                    ~CRiskManager();
  };
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
CRiskManager::CRiskManager()
  {
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
CRiskManager::~CRiskManager()
  {
  }
//+------------------------------------------------------------------+
