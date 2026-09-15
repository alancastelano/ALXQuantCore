//+------------------------------------------------------------------+
//|                                                     ALXTrade.mqh |
//|                                  Copyright 2023, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//| #Resources                                                       |
//+------------------------------------------------------------------+
#resource "\\Indicators\\ALX Indicadores\\StopATR.ex5"
//+------------------------------------------------------------------+

#include <Trade\Trade.mqh>

enum enStopType
   {
      stop_fix,    // Stop fixo
      stop_atr,    // Stop ATR
   };


sinput group "== Position Size Trend =="
input enStopType        InpStopType             = stop_atr; // Stop Type
input ushort            InpStopLoss             = 600;      // StopLoss fixo (in pips)
input int               InpSAPeriodo            = 14;       // StopATR - Periodo
input int               InpSAATRPeriodo         = 5;        // StopATR - Periodo ATR
input double            InpSAKv                 = 2.5;      // StopATR - Volatilidade ATR
input int               InpSAShift              = 0;        // StopATR - Desvio Horizontal
int handle_satr;

input ushort            InpTakeProfit           = 0;        // Take Profit 0 (in pips)
input ushort            InpTakeProfit1          = 0;        // Take Profit 1 (in pips)
input ushort            InpTakeProfit2          = 0;        // Take Profit 2 (in pips)

input double            InpLotValue             = 1.0;      // Position 0 (Risk %)
input double            InpLotValue1            = 1.0;      // Position 1 (Risk %)
input double            InpLotValue2            = 1.0;      // Position 2 (Risk %)


class CALXTrade
  {
private:
   double LotCalc(double percRisk,ushort sl);
   double NormalizeVolume(double volume);


public:

         CALXTrade(void);
         
   void  OpenPosition(const ENUM_POSITION_TYPE pos_type);
   void  OpenBuy(double sl,double tp);
   void  OpenSell(double sl,double tp);

  };
//+------------------------------------------------------------------+

CALXTrade::CALXTrade(void)
{
      if(m_alxtrade!=NULL)
         delete m_alxtrade;

      m_alxtrade=new CTrade;


     // if(m_money!=NULL)
     //   {
     //    if(!m_money.Init(GetPointer(m_symbol),Period(),m_symbol.Point()*digits_adjust))
     //       return(INIT_FAILED);
     //    m_money.Percent(InpVolumeLorOrRisk);
     //   }

}







//+------------------------------------------------------------------+
//| Open positions                                                   |
//+------------------------------------------------------------------+
void CALXTrade::OpenPosition(const ENUM_POSITION_TYPE pos_type)
  {

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
      double sl  = (InpStopLoss==0)    ? 0.0 : price - ExtStopLoss;
      double tp  = (InpTakeProfit==0)  ? 0.0 : price + ExtTakeProfit;
      if(((sl!=0 && ExtStopLoss>=stop_level) || sl==0.0) && ((tp!=0 && ExtTakeProfit>=stop_level) || tp==0.0))
        {
         OpenBuy(sl,tp);
         return;
        }
     }
   if(pos_type==POSITION_TYPE_SELL)
     {
      double price=m_symbol.Bid();
      double sl = (InpStopLoss==0)     ? 0.0 : price + ExtStopLoss;
      double tp = (InpTakeProfit==0)   ? 0.0 : price - ExtTakeProfit;
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
void CALXTrade::OpenBuy(double sl,double tp)
  {
   sl  = m_symbol.NormalizePrice(priceStopATR);
   tp  = m_symbol.NormalizePrice(tp);
   
   double long_lot  = LotCalc(InpLotValue,(ushort)stopatr_pontos);

   double free_margin_check = m_account.FreeMarginCheck(m_symbol.Name(),ORDER_TYPE_BUY,long_lot,m_symbol.Ask());
   double margin_check      = m_account.MarginCheck(m_symbol.Name(),ORDER_TYPE_SELL,long_lot,m_symbol.Bid());
   if(free_margin_check>margin_check)
      m_trade.Buy(long_lot,m_symbol.Name(),m_symbol.Ask(),sl,tp,"");
  }

//+------------------------------------------------------------------+
//| Open Sell position                                               |
//+------------------------------------------------------------------+
void CALXTrade::OpenSell(double sl,double tp)
  {
   sl=m_symbol.NormalizePrice(priceStopATR);
   tp=m_symbol.NormalizePrice(tp);

   double short_lot  = LotCalc(InpLotValue,(ushort)stopatr_pontos); 

   double free_margin_check= m_account.FreeMarginCheck(m_symbol.Name(),ORDER_TYPE_SELL,short_lot,m_symbol.Bid());
   double margin_check     = m_account.MarginCheck(m_symbol.Name(),ORDER_TYPE_SELL,short_lot,m_symbol.Bid());
   if(free_margin_check>margin_check)
      m_trade.Sell(short_lot,m_symbol.Name(),m_symbol.Bid(),sl,tp,"");
  }

double CALXTrade::LotCalc(double percRisk,ushort sl)
{
  double PipValue = (((SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE))*_Point)/(SymbolInfoDouble(Symbol(),SYMBOL_TRADE_TICK_SIZE)));
  double lots = (percRisk/100) * AccountInfoDouble(ACCOUNT_BALANCE) / (PipValue * sl);
  
  return(NormalizeVolume(lots));
}

//+------------------------------------------------------------------+
//| Normalize Volume                                                 |
//+------------------------------------------------------------------+
double CALXTrade::NormalizeVolume(double volume)
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
