//+------------------------------------------------------------------+
//|                                                   EA QUantFX.mq5 |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property version   "3.50"

const string EA_VERSION = "v10.0.0";

#include <ALXQuantCore\ALXQuantCore.mqh> CALXQuantCore m_framework;

/*
   Indices
      US30..................

   Forex: 
      GBPUSD................


*/















double   NewProfProc = 0.0;
datetime time_open   = 0;
datetime time_new    = 0;

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
   if(sets.price_open==0) sets.price_open = bid;

   if(time_new+time_open<TimeCurrent())
   {
      time_new   = TimeCurrent(); 
      sets.price_open = bid;
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
   
   bool buy_open  = (time_new + time_open >= TimeCurrent()) && (bid - effectivePipsStep * point >= sets.price_open);
   bool sell_open = (time_new + time_open >= TimeCurrent()) && (ask + effectivePipsStep * point <= sets.price_open);



   bool can_open_trade = Count(-1)==0               &&
                         !m_regime.IsChaosRegime()  &&
                         //m_regime.GetLastHurst()>=InpLastHurstMinValue &&
                         //m_regime.GetLastHurst()<=InpLastHurstMaxValue &&
                         m_time.IsTimeTrade()       &&
                         !IsNewsBlocked()           &&
                         !m_exec.IsBusy()           ;
  
   if(can_open_trade)
   {
      g_human.NewTrade();
      NewProfProc = Profit(-1) / (balance / 100.0);

      //======= Abertura de Ordens Iniciais
      if(buy_open && Count(-1) == 0)
      {
         g_human.SleepHuman();

         // Random order type (10% chance)
         if(g_human.ShouldUseRandomOrderType()) {
            // Use LIMIT/IOC order type
         }

        
         TradeParams tp = m_exec.Calculate(_Symbol);
         double lot = m_exec.LotCheck(tp.lot);
         lot = m_exec.LotCheck(lot);
         m_exec.Buy(lot, 0, 0, sets.m_comment);
     }
     if(sell_open && Count(-1) == 0)
     {
        g_human.SleepHuman();

        TradeParams tp = m_exec.Calculate(_Symbol);
        double lot = m_exec.LotCheck(tp.lot);
        lot = m_exec.LotCheck(lot);
        m_exec.Sell(lot, 0, 0, sets.m_comment);
     }
    }
   
   //--- Fechamento por Take Profit Global (NET de comissão)
   double ProfProc = AllLots(-1) * InpTakeProfit;
   if(ProfitNetAll(-1) >= ProfProc && ProfProc != 0 && Count(-1) > 1) { ClosePos(); }
   
   //--- Stop Loss % Global (bruto — proteção de equity)
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
//| # OnDeInit                                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) { m_framework.OnDeinit(reason); }

//+------------------------------------------------------------------+
//| # OnTradeTransaction                                             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
{
   m_framework.OnTradeTransaction(trans,req,res);
}



