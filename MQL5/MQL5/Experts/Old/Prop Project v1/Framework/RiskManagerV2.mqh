//+------------------------------------------------------------------+
//|                                                RiskManagerV2.mqh |
//|                                       Copyright 2023, Castelano. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Castelano."
#property link      "https://www.mql5.com"
#property version   "1.00"

/*
  1. Risk Manager Module
   1.1 Lot Size
   1.2 Max Leverage  MaxLeverage = (Capital * Leverage)/100.000
   1.3 





*/

enum enHistoryPeriod
   {
      Daily = PERIOD_D1;
      Week  = PERIOD_W1;
      Month = PERIOD_MN1;
   };


class CRiskManagerV2
  {
private:

public:
                     CRiskManagerV2();
                    ~CRiskManagerV2();
     double LotRisk(double dbStopLoss, double dbRiskRatio,int Leverage);               
  };
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
CRiskManagerV2::CRiskManagerV2()
  {
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
CRiskManagerV2::~CRiskManagerV2()
  {
  }
//+------------------------------------------------------------------+


/*
   1. Historico diario/semanal/mensal/Total
      1.1 Count ordens
      1.2 count Ordens profit
      1.3 Count Ordens loss
      1.4 Profit $ / Profit %
      1.5 Loss $ / Loss %
      1.6 Result $ / Result %
      1.7 Risk/Reward
*/

void CRiskManagerV2::CheckResult(enHistoryPeriod _HistoryPeriod)
{
   int count         = 0;
   int count_profit  = 0;
   int count_loss    = 0;
   
   double profit_value = 0.0; double profit_perc_value = 0.0;
   double loss_value   = 0.0; double loss_perc_value   = 0.0;
   double result_value = 0.0; double result_perc_value = 0.0;
    
   double RiskReward = 0;

   HistorySelect(iTime(_Symbol,_HistoryPeriod,0),TimeCurrent());
   ulong ticket = 0 ;
   for(int i=0;i<HistoryDealsTotal();i++) 
      {
         if((ticket=HistoryDealGetTicket(i))>0)
            if(HistoryDealGetInteger(ticket,DEAL_ENTRY)==DEAL_ENTRY_OUT)
               if(HistoryDealGetString(ticket,DEAL_SYMBOL)==Symbol() && HistoryDealGetInteger(ticket,DEAL_MAGIC)==id_magic)   
                  { 
                     count++;                                
                     double tmp_profit += HistoryDealGetDouble(ticket,DEAL_PROFIT) + HistoryDealGetDouble(ticket,DEAL_SWAP) + HistoryDealGetDouble(ticket,DEAL_COMMISSION) ;
                    
                     if(tmp_profit>=0) { count_profit++; profit_value+=tmp_profit;  }
                     if(tmp_profit<0)  { count_loss++;   loss_value+=tmp_profit;    }
                  }
        }



}








// Calculate Max Lot Size based on Maximum Risk
double CRiskManagerV2::LotRisk(double dbStopLoss, double dbRiskRatio,int Leverage)
{
   double LotMin    = SymbolInfoDouble( _Symbol, SYMBOL_VOLUME_MIN );
   double LotMax    = SymbolInfoDouble( _Symbol, SYMBOL_VOLUME_MAX );
   double LotStep   = SymbolInfoDouble( _Symbol, SYMBOL_VOLUME_STEP);
   double TickSize  = SymbolInfoDouble( _Symbol, SYMBOL_TRADE_TICK_SIZE);
   double TickValue = SymbolInfoDouble( _Symbol, SYMBOL_TRADE_TICK_VALUE);
      
   double ValueAccount = fmin( fmin(AccountInfoDouble(ACCOUNT_EQUITY),AccountInfoDouble(ACCOUNT_BALANCE)),AccountInfoDouble(ACCOUNT_MARGIN_FREE));

   double LotMaxLeverage = (ValueAccount*Leverage)/SymbolInfoDouble( _Symbol,SYMBOL_TRADE_CONTRACT_SIZE);


   double ValueRisk    = ValueAccount * dbRiskRatio;
   double LossOrder    = dbStopLoss * TickValue / TickSize;
   double CalcLot      = fmin(LotMaxLeverage,            // Prevent too smaller volume max leverage
                         fmin(LotMax,                    // Prevent too greater volume
                         fmax(LotMin,                    // Prevent too smaller volume
                         round(ValueRisk/LossOrder       // Calculate stop risk
                              / LotStep)*LotStep ) ) );  // Align to step value

   return(CalcLot);
};






