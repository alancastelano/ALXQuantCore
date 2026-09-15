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
//===================================================================================
//input group "=== Filtros ==="
int    InpMinTrades            = 30;
double InpMinProfitFactor      = 1.2;
double InpMaxDrawdownPct       = 30.0;
double InpMaxLossToAvgWinRatio = 5.0;  // <<< O FILTRO PRA SEU PROBLEMA: maior perda não pode passar de Nx o ganho médio

//input group "=== Pesos ==="
double InpPesoSortino       = 2.5;
double InpPesoProfitFactor  = 1.0;
double InpPesoUlcer         = 2.0;  // penalidade (subtrai do score)
double InpPesoPayoff        = 1.5;
double InpPesoWinRate       = 0.3;

//+------------------------------------------------------------------+
double OnTester()
{
   int totalTrades = (int)TesterStatistics(STAT_TRADES);
   if(totalTrades < InpMinTrades) return 0.0;

   double netProfit = TesterStatistics(STAT_PROFIT);
   if(netProfit <= 0.0) return 0.0;

   double grossProfit  = TesterStatistics(STAT_GROSS_PROFIT);
   double grossLoss    = TesterStatistics(STAT_GROSS_LOSS);
   int    winTrades    = (int)TesterStatistics(STAT_PROFIT_TRADES);
   int    lossTrades   = (int)TesterStatistics(STAT_LOSS_TRADES);
   double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
   double maxDDPercent = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double maxLossTrade = MathAbs(TesterStatistics(STAT_MAX_LOSSTRADE));

   if(profitFactor == DBL_MAX || profitFactor > 10.0)
      profitFactor = 10.0;

   if(maxDDPercent > InpMaxDrawdownPct)
      return 0.0;

   double avgWin  = (winTrades  > 0) ? grossProfit / winTrades         : 0.0;
   double avgLoss = (lossTrades > 0) ? MathAbs(grossLoss) / lossTrades : 0.0;

   //--- FILTRO CRÍTICO: descarta estratégias com risco de "cauda gorda"
   //--- Ex.: ganho médio $2, maior perda $38 -> razão 19x -> descartada
   if(avgWin > 0.0 && (maxLossTrade / avgWin) > InpMaxLossToAvgWinRatio)
      return 0.0;

   double payoffRatio = (avgLoss > 0.0) ? avgWin / avgLoss : 0.0;
   double winRate      = (double)winTrades / totalTrades;

   //--- Reconstrói a série de trades para calcular Sortino e Ulcer Index
   double tradeReturns[];
   double equityCurve[];
   if(!BuildTradeSeries(tradeReturns, equityCurve))
      return 0.0;

   double sortino        = CalcSortino(tradeReturns);
   double sortinoClamped = MathMax(-3.0, MathMin(sortino, 5.0));
   double ulcer          = CalcUlcerIndex(equityCurve);

   double score = 0.0;
   score += sortinoClamped   * InpPesoSortino;
   score += profitFactor     * InpPesoProfitFactor;
   score += payoffRatio      * InpPesoPayoff;
   score += winRate * 10.0   * InpPesoWinRate;
   score -= ulcer            * InpPesoUlcer;   // Ulcer é penalidade, não bônus

   return MathMax(score, 0.0);
}

//+------------------------------------------------------------------+
//| Reconstrói o histórico de deals de saída em duas séries:          |
//| retorno por trade (p/ Sortino) e capital acumulado (p/ Ulcer)     |
//+------------------------------------------------------------------+
bool BuildTradeSeries(double &returns[], double &equity[])
{
   if(!HistorySelect(0, TimeCurrent()))
      return false;

   int total = HistoryDealsTotal();
   ArrayResize(returns, 0);
   ArrayResize(equity, 0);
   double cumProfit = 0.0;

   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      //--- só nos interessam deals de FECHAMENTO de posição
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      double dealProfit = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                         + HistoryDealGetDouble(ticket, DEAL_SWAP)
                         + HistoryDealGetDouble(ticket, DEAL_COMMISSION);

      int n = ArraySize(returns);
      ArrayResize(returns, n + 1);
      returns[n] = dealProfit;

      cumProfit += dealProfit;
      int m = ArraySize(equity);
      ArrayResize(equity, m + 1);
      equity[m] = cumProfit;
   }

   return (ArraySize(returns) > 0);
}

//+------------------------------------------------------------------+
//| Sortino: retorno médio / desvio padrão SÓ dos retornos negativos   |
//+------------------------------------------------------------------+
double CalcSortino(const double &returns[])
{
   int n = ArraySize(returns);
   if(n == 0) return 0.0;

   double meanReturn = 0.0;
   for(int i = 0; i < n; i++)
      meanReturn += returns[i];
   meanReturn /= n;

   double sumSqDownside = 0.0;
   int    downsideCount = 0;
   for(int i = 0; i < n; i++)
   {
      if(returns[i] < 0.0)
      {
         sumSqDownside += returns[i] * returns[i];
         downsideCount++;
      }
   }

   if(downsideCount == 0)
      return 5.0; // nenhuma perda na amostra -> valor teto (evita div/0, mas suspeito)

   double downsideDeviation = MathSqrt(sumSqDownside / downsideCount);
   return (downsideDeviation > 0.0) ? meanReturn / downsideDeviation : 0.0;
}

//+------------------------------------------------------------------+
//| Ulcer Index: raiz da média dos quadrados do drawdown percentual   |
//| ao longo de toda a curva de capital acumulado (pune DD prolongado)|
//+------------------------------------------------------------------+
double CalcUlcerIndex(const double &equity[])
{
   int n = ArraySize(equity);
   if(n == 0) return 0.0;

   double peak     = equity[0];
   double sumSqDD  = 0.0;

   for(int i = 0; i < n; i++)
   {
      if(equity[i] > peak)
         peak = equity[i];

      double ddPct = (peak != 0.0) ? ((peak - equity[i]) / MathAbs(peak)) * 100.0 : 0.0;
      sumSqDD += ddPct * ddPct;
   }

   return MathSqrt(sumSqDD / n);
}