//+------------------------------------------------------------------+
//|                                                      StopATR.mqh |
//|                                      Copyright 2022, ALX Invest. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2022, ALX Invest."
#property link      "https://www.mql5.com"
#property version   "2.00"

//+------------------------------------------------------------------+
//| #Resources                                                        |
//+------------------------------------------------------------------+
#resource "\\Indicators\\ALX Indicadores\\StopATR.ex5"
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| #Inputs                                                          |
//+------------------------------------------------------------------+
input group "== Stop ATR =="
input bool                 InpSA                = true;     // StopATR On/Off
input int                  InpSAPeriodo         = 14;       // Periodo
input int                  InpSAATRPeriodo      = 5;        // Periodo ATR
input double               InpSAKv              = 2.5;      // Volatilidade ATR
input int                  InpSAShift           = 0;        // Desvio Horizontal
//+------------------------------------------------------------------+


class CStopATR
  {
private:
   int handle_satr;
   
   double NormalizePrice(double price);

public:

   bool  Init(void);
   bool  Signal(void);
   bool  GetData(int &signal,double &buyprice,double &sellprice);
   void  StopTrailing(void);

  };
//+------------------------------------------------------------------+

bool CStopATR::Init(void)
{
   if(!InpSA)
      return(true);

   handle_satr = iCustom(_Symbol,Period(),"::Indicators\\ALX Indicadores\\StopATR.ex5",InpSAPeriodo,InpSAATRPeriodo,InpSAKv,InpSAShift);
   
   if(handle_satr==INVALID_HANDLE)
      { 
         printf("Falha ao criar handle do indicador StopATR. Error: %d",GetLastError());
         return(false);
      }
   else
      {
         if(!ChartIndicatorAdd(0,1,handle_satr))
            PrintFormat("Falha ao adicionar o indicador StopATR. Erro: %d",  GetLastError());
      }

   return(true);
}

//+------------------------------------------------------------------+
//| Get Stop Data                                                    |
//+------------------------------------------------------------------+
bool CStopATR::Signal(void)
{
   uint res=0;
      
   double Up[],Down[];
   ArraySetAsSeries(Up,true);
   ArraySetAsSeries(Down,true);
   if(CopyBuffer(handle_satr,1,0,3,Down)<0) { Print("Erro ao copiar StopATR Up: "  ,GetLastError()); return(false); }
   if(CopyBuffer(handle_satr,0,0,3,Up)<0)   { Print("Erro ao copiar StopATR Down: ",GetLastError()); return(false); }

   double buyprice  = (Up[1]==DBL_MAX)   ? 0.0 : NormalizeDouble(Up[1],_Digits);
   double sellprice = (Down[1]==DBL_MAX) ? 0.0 : NormalizeDouble(Down[1],_Digits);

   if(buyprice!=0.0 && sellprice==0.0) { res=1; }
   if(buyprice==0.0 && sellprice!=0.0) { res=2; }
   
   return(res);
}

//+------------------------------------------------------------------+
//| Get Stop Data                                                    |
//+------------------------------------------------------------------+
bool CStopATR::GetData(int &signal,double &buyprice,double &sellprice)
{
   signal=0;
   buyprice=0.0;
   sellprice=0.0;
   
   double Up[],Down[];
   ArraySetAsSeries(Up,true);
   ArraySetAsSeries(Down,true);
   if(CopyBuffer(handle_satr,1,0,3,Down)<0) { Print("Erro ao copiar StopATR Up: "  ,GetLastError()); return(false); }
   if(CopyBuffer(handle_satr,0,0,3,Up)<0)   { Print("Erro ao copiar StopATR Down: ",GetLastError()); return(false); }

   buyprice  = (Up[1]==DBL_MAX)   ? 0.0 : NormalizeDouble(Up[1],_Digits);
   sellprice = (Down[1]==DBL_MAX) ? 0.0 : NormalizeDouble(Down[1],_Digits);

   if(buyprice!=0.0 && sellprice==0.0) { signal=1; }
   if(buyprice==0.0 && sellprice!=0.0) { signal=2; }
   
   return(true);
}




//+------------------------------------------------------------------+
//| Trailling StopATR Hedge                                          |
//+------------------------------------------------------------------+
void CStopATR::StopTrailing(void)
{
   double StopCurrent      = 0.0;
   double StopATRCurrent   = 0.0;

   int    signal    = 0;
   double buyprice  = 0.0;
   double sellprice = 0.0;
   GetData(signal,buyprice,sellprice);

   if(signal==1) StopATRCurrent=buyprice;
   if(signal==2) StopATRCurrent=sellprice;

   for(int i=PositionsTotal()-1;i>=0;i--) // returns the number of current positions
      if(m_position.SelectByIndex(i))     // selects the position by index for further access to its properties
         if(m_position.Symbol()==_Symbol && m_position.Magic()==m_magic)
            {
               StopCurrent = PositionGetDouble(POSITION_SL);
               if(StopCurrent==0)
                  StopCurrent = StopATRCurrent; 
               
               if(m_position.PositionType()==POSITION_TYPE_BUY && StopATRCurrent!=StopCurrent)
                  {
                     double sl         = NormalizePrice(StopATRCurrent);
                     double tp         = NormalizePrice(PositionGetDouble(POSITION_TP));

                     if(PositionGetDouble(POSITION_SL)==StopATRCurrent) //-- Returna caso Stop seja igual ao atual
                        return;

                     m_trade.PositionModify(m_position.Ticket(),sl,tp);
                  }
                  
               if(m_position.PositionType()==POSITION_TYPE_SELL && StopATRCurrent!=StopCurrent)
                  {
                     double sl = NormalizePrice(StopATRCurrent);
                     double tp = NormalizePrice(PositionGetDouble(POSITION_TP));

                     if(PositionGetDouble(POSITION_SL)==StopATRCurrent)
                        return;

                     m_trade.PositionModify(m_position.Ticket(),sl,tp);
                  }
                  
                  
            }
}

double CStopATR::NormalizePrice(double price)
  {
   double m_tick_size=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   return(NormalizeDouble(MathRound(price/m_tick_size)*m_tick_size,_Digits));
  }
