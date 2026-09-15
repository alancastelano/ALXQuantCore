//+------------------------------------------------------------------+
//|                                                         Core.mqh |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//========================= MAGIC ID =================================
ulong AutoMagicID(string ea_name, string version="1.0")
{
   ulong accountLogin = (ulong)AccountInfoInteger(ACCOUNT_LOGIN);
   string key = ea_name + "|" + version + "|" + _Symbol + "|" + IntegerToString(_Period) + "|" + IntegerToString(accountLogin);

   ulong hash = 5381;
   for(int i = 0; i < StringLen(key); i++)
      hash = ((hash << 5) + hash) + StringGetCharacter(key, i);

   return hash & 0x7FFFFFFF;
}

//========================= REGIME COMMENT ===========================
string GenerateRegimeComment()
{
   ulong accLogin = AccountInfoInteger(ACCOUNT_LOGIN);
   int uniqueSuffix = (int)(accLogin % 9999);

   double hurstVal = 0.51;//m_regime.GetLastHurst();
   double r2Val    = 0.62;//m_regime.GetConfidence();

   string hStr = DoubleToString(hurstVal, 2);
   string rStr = DoubleToString(r2Val, 2);

   return StringFormat("QFX_H%s_R%s_%04d", hStr, rStr, uniqueSuffix);
}

//========================= REFRESH RATES ============================
bool RefreshRates(void)
{
   if(!m_symbol.RefreshRates())
   {
      Print("RefreshRates error");
      return(false);
   }
   if(m_symbol.Ask()==0 || m_symbol.Bid()==0)
      return(false);
   return(true);
}

//--- Count all positions for this EA
int CalculateAllPositions(void)
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
      if(m_position.SelectByIndex(i))
         if(m_position.Symbol()==m_symbol.Name() && m_position.Magic()==sets.m_magic)
            count++;
   return(count);
}

//========================= CLOSE ====================================
void CloseAllByMagic()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == sets.m_magic)
      {
         m_trade.PositionClose(ticket);
      }
   }
}

//========================= TRAILING STOP ============================
void TrailingStop()
{
   double Point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == sets.m_magic)
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);

         if(posType == POSITION_TYPE_BUY && InpTrailingStep != 0)
         {
            if((currentSL < openPrice || currentSL == 0) && Bid - (InpTrailingStep + InpTrailingStart) * Point >= openPrice)
            {
               m_trade.PositionModify(ticket, NormalizeDouble(openPrice + InpTrailingStart * Point, digits), currentTP);
            }
            if(currentSL >= openPrice && Bid - InpTrailingStep * Point > currentSL)
            {
               m_trade.PositionModify(ticket, NormalizeDouble(Bid - InpTrailingStep * Point, digits), currentTP);
            }
         }

         if(posType == POSITION_TYPE_SELL && InpTrailingStep != 0)
         {
            if((currentSL > openPrice || currentSL == 0) && Ask + (InpTrailingStep + InpTrailingStart) * Point <= openPrice)
            {
               m_trade.PositionModify(ticket, NormalizeDouble(openPrice - InpTrailingStart * Point, digits), currentTP);
            }
            if(currentSL <= openPrice && Ask + InpTrailingStep * Point < currentSL)
            {
               m_trade.PositionModify(ticket, NormalizeDouble(Ask + InpTrailingStep * Point, digits), currentTP);
            }
         }
      }
   }
}

//--- Soma dos lotes abertos
double AllLots(int type) 
{
   double lot = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) 
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == sets.m_magic) 
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL)) 
         {
            lot += PositionGetDouble(POSITION_VOLUME);
         }
      }
   }
   return lot;
}


//======= Lucro flutuante global na conta
double ProfitAll(int type) 
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) 
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == sets.m_magic) 
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL)) 
         {
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }
   }
   return profit;
}
