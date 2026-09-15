//+------------------------------------------------------------------+
//|                                                        Trade.mqh |
//|                                       Copyright 2023, Castelano. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Castelano."
#property link      "https://www.mql5.com"

//+------------------------------------------------------------------+
//| Open positions                                                   |
//+------------------------------------------------------------------+
void OpenPosition(const ENUM_POSITION_TYPE pos_type)
  {
//--- check Freeze and Stops levels
/*
   Type of order/position  |  Activation price  |  Check
   ------------------------|--------------------|--------------------------------------------
   Buy Limit order         |  Ask               |  Ask-OpenPrice  >= SYMBOL_TRADE_FREEZE_LEVEL
   Buy Stop order          |  Ask	            |  OpenPrice-Ask  >= SYMBOL_TRADE_FREEZE_LEVEL
   Sell Limit order        |  Bid	            |  OpenPrice-Bid  >= SYMBOL_TRADE_FREEZE_LEVEL
   Sell Stop order	      |  Bid	            |  Bid-OpenPrice  >= SYMBOL_TRADE_FREEZE_LEVEL
   Buy position            |  Bid	            |  TakeProfit-Bid >= SYMBOL_TRADE_FREEZE_LEVEL 
                           |                    |  Bid-StopLoss   >= SYMBOL_TRADE_FREEZE_LEVEL
   Sell position           |  Ask	            |  Ask-TakeProfit >= SYMBOL_TRADE_FREEZE_LEVEL
                           |                    |  StopLoss-Ask   >= SYMBOL_TRADE_FREEZE_LEVEL
                           
   Buying is done at the Ask price                 |  Selling is done at the Bid price
   ------------------------------------------------|----------------------------------
   TakeProfit        >= Bid                        |  TakeProfit        <= Ask
   StopLoss          <= Bid	                     |  StopLoss          >= Ask
   TakeProfit - Bid  >= SYMBOL_TRADE_STOPS_LEVEL   |  Ask - TakeProfit  >= SYMBOL_TRADE_STOPS_LEVEL
   Bid - StopLoss    >= SYMBOL_TRADE_STOPS_LEVEL   |  StopLoss - Ask    >= SYMBOL_TRADE_STOPS_LEVEL
*/
   if(!RefreshRates() || !m_symbol.Refresh())
      return;
//--- FreezeLevel -> for pending order and modification
   double freeze_level=m_symbol.FreezeLevel()*m_symbol.Point();
   if(freeze_level==0.0)
      freeze_level=(m_symbol.Ask()-m_symbol.Bid())*3.0;
   freeze_level*=1.1;
//--- StopsLevel -> for TakeProfit and StopLoss
   double stop_level=m_symbol.StopsLevel()*m_symbol.Point();
   if(stop_level==0.0)
      stop_level=(m_symbol.Ask()-m_symbol.Bid())*3.0;
   stop_level*=1.1;

   if(freeze_level<=0.0 || stop_level<=0.0)
      return;
//---
   if(pos_type==POSITION_TYPE_BUY)
     {
      double price=m_symbol.Ask();
      double sl=(InpStopLoss==0)?0.0:price-ExtStopLoss;
      double tp=0.0;
      if(((sl!=0 && ExtStopLoss>=stop_level) || sl==0.0) && ((tp!=0 && ExtTakeProfit>=stop_level) || tp==0.0))
        {
         OpenBuy(sl,tp);
         return;
        }
     }
   if(pos_type==POSITION_TYPE_SELL)
     {
      double price=m_symbol.Bid();
      double sl=(InpStopLoss==0)?0.0:price+ExtStopLoss;
      double tp=0.0;
      if(((sl!=0 && ExtStopLoss>=stop_level) || sl==0.0) && ((tp!=0 && ExtTakeProfit>=stop_level) || tp==0.0))
        {
         OpenSell(sl,tp);
         return;
        }
     }
  }
//+------------------------------------------------------------------+
//| Open Buy position                                                |
//+------------------------------------------------------------------+
void OpenBuy(double sl,double tp)
  {
   sl=m_symbol.NormalizePrice(sl);
   tp=m_symbol.NormalizePrice(tp);

   double long_lot=0.0;
   if(IntLotOrRisk==risk)
     {
      long_lot=m_money.CheckOpenLong(m_symbol.Ask(),sl);
      Print("sl=",DoubleToString(sl,m_symbol.Digits()),
            ", CheckOpenLong: ",DoubleToString(long_lot,2),
            ", Balance: ",    DoubleToString(m_account.Balance(),2),
            ", Equity: ",     DoubleToString(m_account.Equity(),2),
            ", FreeMargin: ", DoubleToString(m_account.FreeMargin(),2));
      if(long_lot==0.0)
        {
         Print(__FUNCTION__,", ERROR: method CheckOpenLong returned the value of \"0.0\"");
         return;
        }
     }
   else if(IntLotOrRisk==lot)
      long_lot=InpVolumeLorOrRisk;
   else
      return;
//--- check volume before OrderSend to avoid "not enough money" error (CTrade)
   double free_margin_check= m_account.FreeMarginCheck(m_symbol.Name(),ORDER_TYPE_BUY,long_lot,m_symbol.Ask());
   double margin_check     = m_account.MarginCheck(m_symbol.Name(),ORDER_TYPE_SELL,long_lot,m_symbol.Bid());
   if(free_margin_check>margin_check)
     {
      if(m_trade.Buy(long_lot,m_symbol.Name(),m_symbol.Ask(),sl,tp))
        {
         if(m_trade.ResultDeal()==0)
           {
            if(m_trade.ResultRetcode()==10009)
              {
               m_waiting_transaction=true;  // "true" -> it's forbidden to trade, we expect a transaction
               m_waiting_order_ticket=m_trade.ResultOrder();
              }
            Print("#1 Buy -> false. Result Retcode: ",m_trade.ResultRetcode(),
                  ", description of result: ",m_trade.ResultRetcodeDescription());
            PrintResultTrade(m_trade,m_symbol);
           }
         else
           {
            if(m_trade.ResultRetcode()==10009)
              {
               m_waiting_transaction=true;  // "true" -> it's forbidden to trade, we expect a transaction
               m_waiting_order_ticket=m_trade.ResultOrder();
              }
            Print("#2 Buy -> true. Result Retcode: ",m_trade.ResultRetcode(),
                  ", description of result: ",m_trade.ResultRetcodeDescription());
            PrintResultTrade(m_trade,m_symbol);
           }
        }
      else
        {
         Print("#3 Buy -> false. Result Retcode: ",m_trade.ResultRetcode(),
               ", description of result: ",m_trade.ResultRetcodeDescription());
         PrintResultTrade(m_trade,m_symbol);
        }
     }
   else
     {
      Print(__FUNCTION__,", ERROR: method CAccountInfo::FreeMarginCheck returned the value ",DoubleToString(free_margin_check,2));
      return;
     }
//---
  }
//+------------------------------------------------------------------+
//| Open Sell position                                               |
//+------------------------------------------------------------------+
void OpenSell(double sl,double tp)
  {
   sl=m_symbol.NormalizePrice(sl);
   tp=m_symbol.NormalizePrice(tp);

   double short_lot=0.0;
   if(IntLotOrRisk==risk)
     {
      short_lot=m_money.CheckOpenShort(m_symbol.Bid(),sl);
      Print("sl=",DoubleToString(sl,m_symbol.Digits()),
            ", CheckOpenLong: ",DoubleToString(short_lot,2),
            ", Balance: ",    DoubleToString(m_account.Balance(),2),
            ", Equity: ",     DoubleToString(m_account.Equity(),2),
            ", FreeMargin: ", DoubleToString(m_account.FreeMargin(),2));
      if(short_lot==0.0)
        {
         Print(__FUNCTION__,", ERROR: method CheckOpenShort returned the value of \"0.0\"");
         return;
        }
     }
   else if(IntLotOrRisk==lot)
      short_lot=InpVolumeLorOrRisk;
   else
      return;
//--- check volume before OrderSend to avoid "not enough money" error (CTrade)
   double free_margin_check= m_account.FreeMarginCheck(m_symbol.Name(),ORDER_TYPE_SELL,short_lot,m_symbol.Bid());
   double margin_check     = m_account.MarginCheck(m_symbol.Name(),ORDER_TYPE_SELL,short_lot,m_symbol.Bid());
   if(free_margin_check>margin_check)
     {
      if(m_trade.Sell(short_lot,m_symbol.Name(),m_symbol.Bid(),sl,tp))
        {
         if(m_trade.ResultDeal()==0)
           {
            if(m_trade.ResultRetcode()==10009)
              {
               m_waiting_transaction=true;  // "true" -> it's forbidden to trade, we expect a transaction
               m_waiting_order_ticket=m_trade.ResultOrder();
              }
            Print("#1 Sell -> false. Result Retcode: ",m_trade.ResultRetcode(),
                  ", description of result: ",m_trade.ResultRetcodeDescription());
            PrintResultTrade(m_trade,m_symbol);
           }
         else
           {
            if(m_trade.ResultRetcode()==10009)
              {
               m_waiting_transaction=true;  // "true" -> it's forbidden to trade, we expect a transaction
               m_waiting_order_ticket=m_trade.ResultOrder();
              }
            Print("#2 Sell -> true. Result Retcode: ",m_trade.ResultRetcode(),
                  ", description of result: ",m_trade.ResultRetcodeDescription());
            PrintResultTrade(m_trade,m_symbol);
           }
        }
      else
        {
         Print("#3 Sell -> false. Result Retcode: ",m_trade.ResultRetcode(),
               ", description of result: ",m_trade.ResultRetcodeDescription());
         PrintResultTrade(m_trade,m_symbol);
        }
     }
   else
     {
      Print(__FUNCTION__,", ERROR: method CAccountInfo::FreeMarginCheck returned the value ",DoubleToString(free_margin_check,2));
      return;
     }
//---
  }
