//+------------------------------------------------------------------+
//|                                              ALX EURScalper      |
//|                                       Copyright 2026, ALX        |
//|                 Versão MQL5 refatorada e otimizada               |
//+------------------------------------------------------------------+
#property copyright "2026, ALX"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//============================== INPUTS ==============================
input group "=== Gestão de Lotes ==="
input double  InpLot            = 0.01;    // Lote inicial
input double  InpLotMultiplier  = 1.00;    // Multiplicador martingale
input int     InpMartingaleMode = 1;       // 0=Fixo | 1=Multiplicador | 2=Histórico
input int     InpMoneyMode      = 1;       // 1=Lote fixo | 0=Percentual do saldo
input double  InpBalanceRiskPct = 30.0;    // % do saldo p/ cálculo de lote
input int     InpLotDigits      = 2;       // Casas decimais do lote

input group "=== Grid / Martingale ==="
input double  InpTakeProfit     = 30;      // Take Profit em pontos
input double  InpStep           = 25;      // Distância entre ordens (pontos)
input int     InpAveraging      = 1;       // Nível máximo de martingale
input int     InpMaxTrades      = 8;       // Máximo de ordens simultâneas
input int     InpStopLossPts    = 0;       // Stop Loss em pontos (0 = desligado)
input int     InpSlippage       = 5;       // Slippage em pontos

input group "=== Controle de Risco ==="
input bool    InpUseDailyTarget = true;
input double  InpDailyTarget    = 10.0;    // Alvo diário (moeda da conta)
input bool    InpUseEquityStop  = false;
input double  InpEquityRiskPct  = 20.0;    // Drawdown de equity p/ fechar tudo (%)
input bool    InpUseHiddenTP    = false;
input double  InpHiddenTP       = 500.0;   // Lucro flutuante p/ fechar tudo
input bool    InpUseTrailing    = false;
input int     InpTrailStart     = 10;      // Início do trailing (pontos)
input int     InpTrailStep      = 10;      // Passo do trailing (pontos)
input bool    InpUseTimeOut     = false;
input int     InpTimeOutHours   = 48;      // Horas p/ fechamento forçado

input group "=== Filtro de Sessão ==="
input int     InpOpenHour       = 6;       // Hora de abertura
input int     InpCloseHour      = 17;      // Hora de fechamento
input bool    InpTradeThursday  = true;
input int     InpThursdayHour   = 12;
input bool    InpTradeFriday    = false;
input int     InpFridayHour     = 20;

input group "=== Filtro de Sinal ==="
input double  InpOpenRangePips  = 20;      // Raio do range de abertura (pontos)
input double  InpMaxDailyRange  = 500;     // Range diário máximo (pontos)
input bool    InpWaitLowVolume  = true;    // Esperar volume baixo (novo bar)

//============================== GLOBAIS =============================
CTrade        g_trade;
CPositionInfo g_pos;
CSymbolInfo   g_sym;

int      g_magic       = 0;
double   g_point       = 0;
int      g_digits      = 0;
double   g_initBalance = 0;
double   g_nextLot     = 0;
int      g_avgCount    = -2;
datetime g_timeOutTime = 0;
ulong    g_lastTicket  = 0;

//--- Magic numbers por símbolo (mantendo padrão original)
int SymbolToMagic(const string symbol)
{
   string s = symbol;
   StringToLower(s);
   s = StringSubstr(s, 0, 6);

   static const string sym[] = {
      "AUDCAD","AUDJPY","AUDNZD","AUDUSD","CHFJPY","EURAUD","EURCAD","EURCHF",
      "EURGBP","EURJPY","EURUSD","GBPCHF","GBPJPY","GBPUSD","NZDJPY","NZDUSD",
      "USDCHF","USDJPY","USDCAD"
   };
   for(int i = 0; i < ArraySize(sym); i++)
      if(s == sym[i])
         return 101101 + i;
   return 999999;
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   g_magic       = SymbolToMagic(_Symbol);
   g_point       = _Point;
   g_digits      = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_initBalance = 0;
   g_nextLot     = 0;
   g_avgCount    = -2;
   g_timeOutTime = 0;

   if(!g_sym.Name(_Symbol))
      return INIT_FAILED;

   g_trade.SetExpertMagicNumber(g_magic);
   g_trade.SetDeviationInPoints((ulong)InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
}

//+------------------------------------------------------------------+
//| OnTick - Ponto de entrada principal                              |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_sym.RefreshRates()) return;

   UpdateDashboard();

   //--- 1. Alvo diário atingido
   if(InpUseDailyTarget && DailyTargetReached())
   {
      CloseAllPositions();
      Print("Alvo diário atingido - todas as posições fechadas.");
      return;
   }

   //--- 2. Hidden TP
   if(InpUseHiddenTP && PositionsTotalProfit() >= InpHiddenTP)
   {
      CloseAllPositions();
      Print("Hidden TP atingido - todas as posições fechadas.");
      return;
   }

   //--- 3. Time-out
   if(InpUseTimeOut && g_timeOutTime > 0 && TimeCurrent() >= g_timeOutTime)
   {
      CloseAllPositions();
      g_timeOutTime = 0;
      Print("Time-out atingido - posições fechadas.");
      return;
   }

   //--- 4. Equity Stop
   if(InpUseEquityStop && CheckEquityStop())
   {
      CloseAllPositions();
      Print("Equity Stop atingido - posições fechadas.");
      return;
   }

   //--- 5. Reset de estado quando sem posições
   int totalPos = CountPositions(POSITION_TYPE_BUY) + CountPositions(POSITION_TYPE_SELL);
   if(totalPos == 0)
   {
      g_avgCount = -2;
      if(g_initBalance != AccountInfoDouble(ACCOUNT_BALANCE))
      {
         g_initBalance = 0;
         g_nextLot     = 0;
      }
   }

   //--- 6. Calcular lote da próxima ordem
   if(g_initBalance == 0)
      g_initBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(InpMoneyMode == 1)
   {
      g_nextLot = InpLot;
   }
   else if(g_nextLot == -1)
   {
      g_nextLot = NormalizeDouble(
         (AccountInfoDouble(ACCOUNT_BALANCE) * InpBalanceRiskPct / 100.0) / 10000.0,
         InpLotDigits);
   }
   else if(g_avgCount == InpAveraging && InpMartingaleMode == 1)
   {
      g_nextLot *= InpLotMultiplier;
   }
   else if(g_avgCount == InpAveraging && InpMartingaleMode != 1)
   {
      g_nextLot += InpLot;
   }

   if(g_avgCount >= InpAveraging) g_avgCount = -2;

   //--- 7. Detectar direção atual, última ordem e lote
   bool   isBuy          = false;
   bool   isSell         = false;
   double lastBuyLots    = 0;
   double lastSellLots   = 0;
   double lastBuyPrice   = 0;
   double lastSellPrice  = 0;
   GetLastOrders(isBuy, isSell, lastBuyLots, lastSellLots, lastBuyPrice, lastSellPrice);

   //--- 8. Verificar Step p/ próxima ordem do martingale
   bool placeNext = false;
   if(totalPos > 0 && totalPos <= InpMaxTrades)
   {
      double bid = g_sym.Bid();
      double ask = g_sym.Ask();
      if(!InpWaitLowVolume)
      {
         if(isBuy  && (lastBuyPrice  - ask) >= InpStep * g_point) placeNext = true;
         if(isSell && (bid - lastSellPrice) >= InpStep * g_point) placeNext = true;
      }
      else
      {
         long vol0 = iVolume(_Symbol, PERIOD_CURRENT, 0);
         if(vol0 < 5)
         {
            if(isBuy  && (lastBuyPrice  - ask) >= InpStep * g_point) placeNext = true;
            if(isSell && (bid - lastSellPrice) >= InpStep * g_point) placeNext = true;
         }
      }
   }

   //--- 9. Colocar próxima ordem do martingale
   if(placeNext)
   {
      if(isSell)
      {
         double lot = CalculateNextLot(lastSellLots);
         if(lot > 0 && IsTradeSession())
         {
            CloseSidePositions(false, true);
            if(g_avgCount == -2)
            {
               lot = (InpMartingaleMode == 1)
                     ? NormalizeDouble(InpLotMultiplier * lastSellLots, InpLotDigits)
                     : NormalizeDouble(InpLot + lastSellLots, InpLotDigits);
            }
            if(g_trade.Sell(lot, _Symbol, g_sym.Bid(), 0, 0,
                            _Symbol + "-Scalper-" + IntegerToString(totalPos)))
            {
               g_timeOutTime = TimeCurrent() + InpTimeOutHours * 3600;
               g_avgCount++;
               placeNext = false;
            }
            else Print("Erro ao abrir SELL: ", GetLastError());
         }
      }
      else if(isBuy)
      {
         double lot = CalculateNextLot(lastBuyLots);
         if(lot > 0 && IsTradeSession())
         {
            CloseSidePositions(true, false);
            if(g_avgCount == -2)
            {
               lot = (InpMartingaleMode == 1)
                     ? NormalizeDouble(InpLotMultiplier * lastBuyLots, InpLotDigits)
                     : NormalizeDouble(InpLot + lastBuyLots, InpLotDigits);
            }
            if(g_trade.Buy(lot, _Symbol, g_sym.Ask(), 0, 0,
                           _Symbol + "-Scalper-" + IntegerToString(totalPos)))
            {
               g_timeOutTime = TimeCurrent() + InpTimeOutHours * 3600;
               g_avgCount++;
               placeNext = false;
            }
            else Print("Erro ao abrir BUY: ", GetLastError());
         }
      }
   }

   //--- 10. Abrir primeira ordem (com filtro de range e sinal close[2]>close[1])
   if(totalPos == 0 && !placeNext)
   {
      if(CanOpenNewByRange() && IsTradeSession())
      {
         double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);
         double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
         if(close2 <= 0 || close1 <= 0) return;

         double lot = CalculateNextLot(0);
         if(lot <= 0) return;

         if(close2 > close1)
         {
            if(g_trade.Buy(lot, _Symbol, g_sym.Ask(), 0, 0,
                           _Symbol + "-Scalper-0"))
               g_timeOutTime = TimeCurrent() + InpTimeOutHours * 3600;
            else Print("Erro ao abrir BUY inicial: ", GetLastError());
         }
         else
         {
            if(g_trade.Sell(lot, _Symbol, g_sym.Bid(), 0, 0,
                            _Symbol + "-Scalper-0"))
               g_timeOutTime = TimeCurrent() + InpTimeOutHours * 3600;
            else Print("Erro ao abrir SELL inicial: ", GetLastError());
         }
      }
   }

   //--- 11. Atualizar TP médio em todas as posições
   UpdateAverageTakeProfit();

   //--- 12. Trailing stop
   if(InpUseTrailing)
      ApplyTrailingStop();
}

//========================== HELPERS ================================

//--- Atualiza o painel de informação
void UpdateDashboard()
{
   string txt = StringFormat(
      "Euro Scalper NDD\n"
      "================================\n"
      "INFORMATION:\n"
      "  Broker        : %s\n"
      "  Account       : %I64u\n"
      "  Leverage      : 1:%d\n"
      "  Currency      : %s\n"
      "  Equity        : %.2f\n"
      "  Balance       : %.2f\n"
      "  Free Margin   : %.2f\n"
      "  Used Margin   : %.2f\n"
      "=================\n"
      "  Spread        : %d points\n"
      "  Magic         : %d",
      AccountInfoString(ACCOUNT_COMPANY),
      AccountInfoInteger(ACCOUNT_LOGIN),
      (int)AccountInfoInteger(ACCOUNT_LEVERAGE),
      AccountInfoString(ACCOUNT_CURRENCY),
      AccountInfoDouble(ACCOUNT_EQUITY),
      AccountInfoDouble(ACCOUNT_BALANCE),
      AccountInfoDouble(ACCOUNT_MARGIN_FREE),
      AccountInfoDouble(ACCOUNT_MARGIN),
      (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD),
      g_magic);
   Comment(txt);
}

//--- Conta posições do tipo e magic
int CountPositions(ENUM_POSITION_TYPE type)
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_pos.SelectByIndex(i))
         if(g_pos.Symbol() == _Symbol && g_pos.Magic() == g_magic && g_pos.PositionType() == type)
            cnt++;
   }
   return cnt;
}

//--- Pega última ordem de cada lado e respectivos lotes/preços
void GetLastOrders(bool &isBuy, bool &isSell,
                   double &lastBuyLots, double &lastSellLots,
                   double &lastBuyPrice, double &lastSellPrice)
{
   ulong  lastBuyTicket  = 0;
   ulong  lastSellTicket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != g_magic) continue;

      if(g_pos.PositionType() == POSITION_TYPE_BUY)
      {
         isBuy = true;
         if(g_pos.Ticket() > lastBuyTicket)
         {
            lastBuyTicket  = g_pos.Ticket();
            lastBuyLots    = g_pos.Volume();
            lastBuyPrice   = g_pos.PriceOpen();
         }
      }
      else if(g_pos.PositionType() == POSITION_TYPE_SELL)
      {
         isSell = true;
         if(g_pos.Ticket() > lastSellTicket)
         {
            lastSellTicket = g_pos.Ticket();
            lastSellLots   = g_pos.Volume();
            lastSellPrice  = g_pos.PriceOpen();
         }
      }
   }
}

//--- Lucro total das posições abertas
double PositionsTotalProfit()
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_pos.SelectByIndex(i))
         if(g_pos.Symbol() == _Symbol && g_pos.Magic() == g_magic)
            profit += g_pos.Profit() + g_pos.Swap() + g_pos.Commission();
   }
   return profit;
}

//--- Fecha todas as posições deste EA
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_pos.SelectByIndex(i))
         if(g_pos.Symbol() == _Symbol && g_pos.Magic() == g_magic)
            g_trade.PositionClose(g_pos.Ticket());
   }
}

//--- Fecha posições por lado
void CloseSidePositions(bool closeBuy, bool closeSell)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != g_magic) continue;

      if(closeBuy  && g_pos.PositionType() == POSITION_TYPE_BUY)  g_trade.PositionClose(g_pos.Ticket());
      if(closeSell && g_pos.PositionType() == POSITION_TYPE_SELL) g_trade.PositionClose(g_pos.Ticket());
   }
}

//--- Verifica se alvo diário foi atingido (somando trades fechados hoje)
bool DailyTargetReached()
{
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   if(dayStart == 0) return false;

   double total = 0;
   if(!HistorySelect(dayStart, TimeCurrent())) return false;

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != g_magic) continue;
      total += HistoryDealGetDouble(ticket, DEAL_PROFIT)
             + HistoryDealGetDouble(ticket, DEAL_SWAP)
             + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return total >= InpDailyTarget;
}

//--- Verifica Equity Stop
bool CheckEquityStop()
{
   double loss = MathAbs(PositionsTotalProfit());
   if(loss <= 0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double limit  = (InpEquityRiskPct / 100.0) * equity;
   return loss > limit;
}

//--- Calcula lote da próxima ordem conforme modo martingale
double CalculateNextLot(double lastLots)
{
   double lot = 0;

   if(InpMartingaleMode == 0)
      lot = g_nextLot;

   else if(InpMartingaleMode == 1)
   {
      if(InpMoneyMode == 1)
         lot = NormalizeDouble(g_nextLot * MathPow(InpLotMultiplier, CountAllPositions()), InpLotDigits);
      else
         lot = NormalizeDouble(g_nextLot, InpLotDigits);
   }
   else if(InpMartingaleMode == 2)
   {
      lot = g_nextLot;
      datetime lastCloseTime = 0;
      if(HistorySelect(0, TimeCurrent()))
      {
         int deals = HistoryDealsTotal();
         for(int i = deals - 1; i >= 0; i--)
         {
            ulong ticket = HistoryDealGetTicket(i);
            if(ticket == 0) continue;
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
            if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != g_magic) continue;
            datetime t = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
            if(t > lastCloseTime)
            {
               lastCloseTime = t;
               double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
               if(profit < 0)
               {
                  double dealVol = HistoryDealGetDouble(ticket, DEAL_VOLUME);
                  lot = (InpMoneyMode == 1)
                        ? NormalizeDouble(dealVol * InpLotMultiplier, InpLotDigits)
                        : NormalizeDouble(dealVol + InpLot, InpLotDigits);
               }
               else
                  lot = g_nextLot;
            }
         }
      }
   }

   if(GetLastError() == 134) return -2;  // ERR_NOT_ENOUGH_MONEY
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return lot;
}

//--- Total de posições do EA
int CountAllPositions()
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_pos.SelectByIndex(i))
         if(g_pos.Symbol() == _Symbol && g_pos.Magic() == g_magic) cnt++;
   }
   return cnt;
}

//--- Filtro de range diário
bool CanOpenNewByRange()
{
   if(InpOpenRangePips <= 0 || InpMaxDailyRange <= 0) return true;

   MqlDateTime dt_now;
   TimeToStruct(TimeCurrent(), dt_now);
   int dayOfYear = dt_now.day_of_year;
   
   double dayOpen = 0;
   for(int i = 0; i < Bars(_Symbol, PERIOD_CURRENT); i++)
   {
      datetime t = iTime(_Symbol, PERIOD_CURRENT, i);
      if(t == 0) break;
      MqlDateTime dt_bar;
      TimeToStruct(t, dt_bar);
      if(dt_bar.day_of_year == dayOfYear)
         dayOpen = iOpen(_Symbol, PERIOD_CURRENT, i);
      else break;
   }
   if(dayOpen == 0) return true;

   double upper = NormalizeDouble(dayOpen + InpOpenRangePips * g_point, g_digits);
   double lower = NormalizeDouble(dayOpen - InpOpenRangePips * g_point, g_digits);
   double maxUp = NormalizeDouble(upper + InpMaxDailyRange * g_point, g_digits);
   double maxDn = NormalizeDouble(lower - InpMaxDailyRange * g_point, g_digits);

   double close0 = iClose(_Symbol, PERIOD_CURRENT, 0);
   return (close0 > upper && close0 < maxUp) || (close0 < lower && close0 > maxDn);
}

//--- Filtro de horário e dia da semana
bool IsTradeSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day_of_week == 4 && !InpTradeThursday)                              return false;
   if(dt.day_of_week == 4 && InpTradeThursday && dt.hour > InpThursdayHour)  return false;
   if(dt.day_of_week == 5 && !InpTradeFriday)                                return false;
   if(dt.day_of_week == 5 && InpTradeFriday && dt.hour > InpFridayHour)      return false;
   if(dt.day_of_week == 0 || dt.day_of_week == 6)                            return false;

   int openH  = (InpOpenHour  == 24) ? 0 : InpOpenHour;
   int closeH = (InpCloseHour == 24) ? 0 : InpCloseHour;

   if(openH < closeH)
   {
      if(dt.hour < openH || dt.hour >= closeH) return false;
   }
   else if(openH > closeH)
   {
      if(dt.hour < openH && dt.hour >= closeH) return false;
   }
   return true;
}

//--- Recalcula preço médio e aplica TP virtual comum
void UpdateAverageTakeProfit()
{
   int total = CountAllPositions();
   if(total == 0) return;

   double sumPriceLots = 0;
   double sumLots      = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != g_magic) continue;
      sumPriceLots += g_pos.PriceOpen() * g_pos.Volume();
      sumLots      += g_pos.Volume();
   }
   if(sumLots == 0) return;
   double avgPrice = NormalizeDouble(sumPriceLots / sumLots, g_digits);

   double tpPoints = InpTakeProfit * g_point;
   double slPoints = InpStopLossPts * g_point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != g_magic) continue;

      double tp = 0, sl = 0;
      if(g_pos.PositionType() == POSITION_TYPE_BUY)
      {
         tp = (tpPoints > 0) ? NormalizeDouble(avgPrice + tpPoints, g_digits) : 0;
         sl = (slPoints > 0) ? NormalizeDouble(avgPrice - slPoints, g_digits) : g_pos.StopLoss();
      }
      else
      {
         tp = (tpPoints > 0) ? NormalizeDouble(avgPrice - tpPoints, g_digits) : 0;
         sl = (slPoints > 0) ? NormalizeDouble(avgPrice + slPoints, g_digits) : g_pos.StopLoss();
      }
      g_trade.PositionModify(g_pos.Ticket(), sl, tp);
   }
}

//--- Trailing stop
void ApplyTrailingStop()
{
   if(InpTrailStep <= 0) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != _Symbol || g_pos.Magic() != g_magic) continue;

      double bid = g_sym.Bid();
      double ask = g_sym.Ask();

      if(g_pos.PositionType() == POSITION_TYPE_BUY)
      {
         int pts = (int)NormalizeDouble((bid - g_pos.PriceOpen()) / g_point, 0);
         if(pts < InpTrailStart) continue;
         double newSL = NormalizeDouble(bid - InpTrailStep * g_point, g_digits);
         if(g_pos.StopLoss() == 0 || newSL > g_pos.StopLoss())
            g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit());
      }
      else if(g_pos.PositionType() == POSITION_TYPE_SELL)
      {
         int pts = (int)NormalizeDouble((g_pos.PriceOpen() - ask) / g_point, 0);
         if(pts < InpTrailStart) continue;
         double newSL = NormalizeDouble(ask + InpTrailStep * g_point, g_digits);
         if(g_pos.StopLoss() == 0 || newSL < g_pos.StopLoss())
            g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit());
      }
   }
}
//+------------------------------------------------------------------+