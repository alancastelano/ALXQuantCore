//+------------------------------------------------------------------+
//|                                                   IS Green EA.mq5 |
//|                                       https://t.me/invest_sniper |
//+------------------------------------------------------------------+
#property copyright "https://t.me/invest_sniper"
#property link      "https://t.me/invest_sniper"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//|========================= Parâmetros =============================|
//+------------------------------------------------------------------+  
input ulong    Magic            = 2001;
input double   Risk             = 0.1;

input double   StopLossProcent  = 4.0;
input int      TakeProfit       = 25;  
input double   Tral             = 10.0;   
input double   TralStart        = 2.0;  
input int      TimeStart        = 2;  
input int      TimeEnd          = 19;
input double   PipsStep         = 28.0;  
input int      MaxOrders        = 1;     // Máximo de ordens no grid (0 = ilimitado)  

//+------------------------------------------------------------------+
//|====================== Variáveis Globais ==========================|
//+------------------------------------------------------------------+
string         Commemt;
int            D;
double         Lot              = 0;
double         price            = 0;
datetime       newtime          = 0;
int            OpenTime         = 1;
double         NewProfProc;
//---




//+------------------------------------------------------------------+
//|====================== Inicialização ==============================|
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetMillisecondTimer(250);
   D = 1;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 5 || digits == 3)
   {
      D = 10;
   }
   
   Commemt = "Green" + _Symbol;
   
   // Configuração da classe CTrade
   trade.SetExpertMagicNumber(Magic);
   trade.SetDeviationInPoints(10);
   
   // Detecção automática do modo de preenchimento da corretora
   long fillType = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillType & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   //else if((fillType & SYMBOL_FILLING_RETURN) == SYMBOL_FILLING_RETURN)
   //   trade.SetTypeFilling(ORDER_FILLING_RETURN);
   else
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//|===================== Desinicialização ============================|
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0,0, OBJ_LABEL);
   ObjectsDeleteAll(0,0, OBJ_RECTANGLE_LABEL);
}

//+------------------------------------------------------------------+
//|======================== OnTick ===================================|
//+------------------------------------------------------------------+
void OnTick()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double Point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //======= Cálculo do Lote 
   Lot = NormalizeDouble((balance / 10.0 * Risk) / (tickValue * 100.0 * D), 2);
   if(Lot < minLot) Lot = minLot; 
   if(Lot > maxLot) Lot = maxLot;
   
   //======= Ponto de Entrada
   bool buy = false, GoBuy = false;
   bool sell = false, GoSell = false;

   if(newtime == 0) newtime = TimeCurrent();
   if(price == 0) price = Bid;

   if(newtime + OpenTime < TimeCurrent())
   {
      newtime = TimeCurrent();
      price = Bid;
   }

   if(newtime + OpenTime >= TimeCurrent() && Bid - PipsStep * Point >= price)
   {
      buy = true;
   }

   if(newtime + OpenTime >= TimeCurrent() && Bid + PipsStep * Point <= price) 
   {
      sell = true;
   }
      
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour >= TimeStart && dt.hour < TimeEnd)
   {    
      if(buy) GoBuy = true;
      if(sell) GoSell = true;    
   }
   
   NewProfProc = Profit(-1) / (balance / 100.0);
   
   //======= Abertura de Ordens Iniciais
   if(Count(-1) == 0 && GoSell)
   {
      trade.Sell(Lot, _Symbol, Bid, 0, 0, Commemt);
   }

   if(Count(-1) == 0 && GoBuy)
   {
      trade.Buy(Lot, _Symbol, Ask, 0, 0, Commemt);
   }    
   
   //======= Grid de Ordens
   long limitOrders = MaxOrders; //AccountInfoInteger(ACCOUNT_LIMIT_ORDERS);
   if((CountAll(-1) < limitOrders || limitOrders == 0) && CountBar(-1) == 0)
   {
      if(Count(0) > 0 && GoBuy) // 0 = BUY
      {
         trade.Buy(Lot, _Symbol, Ask, 0, 0, Commemt);
      }  

      if(Count(1) > 0 && GoSell) // 1 = SELL
      {
         trade.Sell(Lot, _Symbol, Bid, 0, 0, Commemt);
      } 
   }
   
   //======= Fechamento por Take Profit
   double ProfProc = AllLots(-1) * TakeProfit;
   if(ProfitAll(-1) >= ProfProc && ProfProc != 0 && Count(-1) > 1)
   {
      ClosePos();
   }
   
   //--- Stop Loss em Porcentagem
   double LossProc = (balance / 100.0) * StopLossProcent * (-1.0);
   if(ProfitAll(-1) < LossProc && LossProc != 0)
   {
      ClosePos();
   }
   
   //======= Trailing Stop
   if(Count(-1) == 1) 
   {
      Traling();
   }
}

//+------------------------------------------------------------------+
//|========================== Funções ================================|
//+------------------------------------------------------------------+
bool IsTimeFilter(void)
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour >= TimeStart && dt.hour < TimeEnd)
      return(true);

   return(false);
}


//-- Fechamento de todas as posições do EA
void ClosePos()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == Magic)
      {
         trade.PositionClose(ticket);
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
      if(PositionGetInteger(POSITION_MAGIC) == Magic) 
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

//======== Contador de ordens no bar atual ================
int CountBar(int type)
{
   int count = 0;
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic) 
      {
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         long posType = PositionGetInteger(POSITION_TYPE);
         if(openTime >= barTime && (type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL))) 
         {
            count++;
         }
      }
   }
   return count;
}

//--- Contador de todas as posições na conta
int CountAll(int type)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == Magic) 
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL)) 
         {
            count++;
         }
      }
   }
   return count;
}

//======= Trailing Stop
void Traling()
{
   double Point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic)
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);

         if(posType == POSITION_TYPE_BUY && Tral != 0)
         {
            if((currentSL < openPrice || currentSL == 0) && Bid - (Tral + TralStart) * Point >= openPrice)
            {
               trade.PositionModify(ticket, NormalizeDouble(openPrice + TralStart * Point, digits), currentTP);
            }
            if(currentSL >= openPrice && Bid - Tral * Point > currentSL)
            {
               trade.PositionModify(ticket, NormalizeDouble(Bid - Tral * Point, digits), currentTP);
            }
         }

         if(posType == POSITION_TYPE_SELL && Tral != 0)
         {
            if((currentSL > openPrice || currentSL == 0) && Ask + (Tral + TralStart) * Point <= openPrice)
            {
               trade.PositionModify(ticket, NormalizeDouble(openPrice - TralStart * Point, digits), currentTP);
            }
            if(currentSL <= openPrice && Ask + Tral * Point < currentSL)
            {
               trade.PositionModify(ticket, NormalizeDouble(Ask + Tral * Point, digits), currentTP);
            }
         }
      }
   }
}

//======= Contador de posições
int Count(int type)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic) 
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL)) 
         {
            count++;
         }
      }
   }
   return count;
}

//======= Lucro flutuante no par atual
double Profit(int type) 
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) 
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic) 
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL)) 
         {
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
         }
      }
   }
   return profit;
}

//======= Lucro flutuante global na conta
double ProfitAll(int type) 
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) 
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == Magic) 
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL)) 
         {
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
         }
      }
   }
   return profit;
}

//======= Função auxiliar para somar histórico
double SumHistoryProfit(int type)
{
   double profit = 0;
   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == Magic)
      {
         long dealEntry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         long dealType = HistoryDealGetInteger(ticket, DEAL_TYPE);
         
         // Filtra apenas deals de fechamento
         if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_INOUT || dealEntry == DEAL_ENTRY_OUT_BY)
         {
            if(type == -1)
            {
               profit += HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP) + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
            }
            else
            {
               // No MQL4, fechar um BUY era tipo 0, fechar um SELL era tipo 1.
               // No MQL5, fechar um BUY gera um DEAL_TYPE_SELL, e fechar um SELL gera DEAL_TYPE_BUY.
               if((type == 0 && dealType == DEAL_TYPE_SELL) || (type == 1 && dealType == DEAL_TYPE_BUY))
               {
                  profit += HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP) + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
               }
            }
         }
      }
   }
   return profit;
}
       
//======= Lucro realizado hoje 
double ProfitDey(int type) 
{
   datetime from = iTime(_Symbol, PERIOD_D1, 0);
   datetime to = TimeCurrent();
   HistorySelect(from, to);
   return SumHistoryProfit(type);
}
       
//======= Lucro realizado ontem     
double ProfitTuDey(int type) 
{
   datetime from = iTime(_Symbol, PERIOD_D1, 1);
   datetime to = iTime(_Symbol, PERIOD_D1, 0);
   HistorySelect(from, to);
   return SumHistoryProfit(type);
}
       
//======= Lucro realizado anteontem       
double ProfitEsTuDey(int type) 
{
   datetime from = iTime(_Symbol, PERIOD_D1, 2);
   datetime to = iTime(_Symbol, PERIOD_D1, 1);
   HistorySelect(from, to);
   return SumHistoryProfit(type);
}
       
//======= Lucro realizado na semana  
double ProfitWeek(int type) 
{
   datetime from = iTime(_Symbol, PERIOD_W1, 0);
   datetime to = TimeCurrent();
   HistorySelect(from, to);
   return SumHistoryProfit(type);
}
       
//======= Lucro realizado no mês          
double ProfitMontag(int type) 
{
   datetime from = iTime(_Symbol, PERIOD_MN1, 0);
   datetime to = TimeCurrent();
   HistorySelect(from, to);
   return SumHistoryProfit(type);
}

//--- Timer
void OnTimer()
{
   OnTick();
}