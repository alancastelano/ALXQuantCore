//+------------------------------------------------------------------+
//|                                                   IS Green Lab.mq5 |
//|                                       https://t.me/invest_sniper |
//+------------------------------------------------------------------+
#property copyright "https://t.me/invest_sniper"
#property link      "https://t.me/invest_sniper"
#property version   "10.0"
#property strict

const string EA_VERSION = "v10.0.0";

#include <ALXQuantCore\ALXQuantCore.mqh> CALXQuantCore m_framework;


//double _price = 0;
double NewProfProc;

//+------------------------------------------------------------------+
//| # OnInit                                                         |
//+------------------------------------------------------------------+
int OnInit()
{
    if(!m_framework.Init("EA QuantFX",EA_VERSION))
      return(INIT_FAILED);
        
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| # OnDeInit                                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   m_miner.FlushToDisk();
   EventKillTimer();
   ObjectsDeleteAll(0, 0, OBJ_LABEL);
   ObjectsDeleteAll(0, 0, OBJ_RECTANGLE_LABEL);
}

//+------------------------------------------------------------------+
//| # OnTradeTransaction                                             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
{
   m_miner.OnTransaction(trans);
   m_exec.ProcessTradeTransaction(trans, req, res);
}

int time_new = 0;
double price_open = 0.0;
datetime time_open = 0;

//+------------------------------------------------------------------+
//| # OnTick                                                         |
//+------------------------------------------------------------------+
void OnTick()
{
   m_exec.Update();
   m_miner.Tick();
   
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double bid     = tick.bid;
   double ask     = tick.ask;
   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(time_new==0)   time_new   = TimeCurrent();
   if(price_open==0) price_open = bid;

   if(time_new+time_open<TimeCurrent())
   {
      time_new   = TimeCurrent(); 
      price_open = bid;
   }

   // Regime (new M5 bar only)
   static datetime last_bar = 0;
   datetime bar = iTime(_Symbol, PERIOD_M5, 0);
   if(bar != last_bar)
   {
      m_regime.Get();
      last_bar = bar;
      g_human.NewSession();
   }

   // Entry signals
   double pipsStepMult = g_human.GetPipsStepJitter(1.0);
   double effectivePipsStep = PipsStep * pipsStepMult;
   
   bool buy_open  = (time_new + time_open >= TimeCurrent()) && (bid - effectivePipsStep * point >= price_open);
   bool sell_open = (time_new + time_open >= TimeCurrent()) && (ask + effectivePipsStep * point <= price_open);


    bool can_open_trade =     Count(-1)==0               &&
                              !m_regime.IsChaosRegime()  &&
                              m_framework.IsTimeFilter()             &&
                              //IsNewsBlocked()            &&
                              !m_exec.IsBusy()           ;
  

   if(can_open_trade)
   {
      g_human.NewTrade();
      NewProfProc = Profit(-1) / (balance / 100.0);

      //======= Abertura de Ordens Iniciais
      if(buy_open && Count(-1) == 0)
      {
         // Human Behavior: delay before execution
         g_human.SleepHuman();

         // Random order type (10% chance)
         if(g_human.ShouldUseRandomOrderType()) {
            // Use LIMIT/IOC order type
         }

        
         TradeParams tp = m_exec.Calculate(_Symbol);
         double lot = tp.lot * g_human.GetLotJitter(1.0) * g_human.GetRiskMultiplier();
         lot = m_exec.LotCheck(lot);
         m_exec.Buy(lot, 0, 0, sets.m_comment);
     }
     if(sell_open && Count(-1) == 0)
     {
        g_human.SleepHuman();

        TradeParams tp = m_exec.Calculate(_Symbol);
        double lot = tp.lot * g_human.GetLotJitter(1.0) * g_human.GetRiskMultiplier();
        lot = m_exec.LotCheck(lot);
        m_exec.Sell(lot, 0, 0, sets.m_comment);
     }
    }
   
   //--- Fechamento por Take Profit Global
   double ProfProc = AllLots(-1) * InpTakeProfit;
   if(ProfitAll(-1) >= ProfProc && ProfProc != 0 && Count(-1) > 1) { ClosePos(); }
   
   //--- Stop Loss % Global
   double LossProc = (balance / 100.0) * InpStopLossPerc * (-1.0);
   if(ProfitAll(-1) < LossProc && LossProc != 0) { ClosePos(); }
   
   //--- Trailing Stop
   if(Count(-1) == 1) { Traling(); }
}

//+------------------------------------------------------------------+
//| # Timer                                                          |
//+------------------------------------------------------------------+
void OnTimer() { m_framework.OnTimer(); }


//+------------------------------------------------------------------+
//| # Funções Auxiliares                                             |
//+------------------------------------------------------------------+
/*
double GetLot()
{
   double lot       = 0.0;
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickValue <= 0.0 || lotStep <= 0.0) return minLot;

   if(InpLotMode==fix)       { lot=InpLotValue; }
   else if(InpLotMode==min)  { lot=minLot;      }
   else if(InpLotMode==risk) { lot=(balance / 10.0 * InpLotValue) / (tickValue * 100.0 * sets.digits_adjust); }

   lot = MathFloor(lot / lotStep) * lotStep;
   
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   int volumeDigits = (int)MathRound(-MathLog10(lotStep));
   return NormalizeDouble(lot, volumeDigits);
}


// Função de qualidade
bool IsHighQualitySetup()
{
   // Só opera se:
   // 1. Hurst > 0.55 (tendência forte)
   double hurst = m_regime.GetLastHurst();
   if(hurst < 0.55) return false;
   
   // 2. R² > 0.60 (boa correlação direcional)
   double r2 = m_regime.GetConfidence();
   if(r2 < 0.60) return false;
   
   // 3. Volume do mercado acima da média (liquidez)
   //double avgVolume  = iVolume(_Symbol, PERIOD_H1, 1);
   //double currVolume = iVolume(_Symbol, PERIOD_CURRENT, 0);
   //if(currVolume < avgVolume * 0.8) return false;
   
   return true;
}


double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0.0) minLot = 0.01;
   if(maxLot <= 0.0) maxLot = 100.0;
   if(stepLot <= 0.0) stepLot = 0.01;

   if(lot > maxLot) lot = maxLot;
   lot = MathFloor((lot + 1e-8) / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;

   int digits = (int)MathRound(-MathLog10(stepLot));
   return NormalizeDouble(lot, digits);
}
*/



