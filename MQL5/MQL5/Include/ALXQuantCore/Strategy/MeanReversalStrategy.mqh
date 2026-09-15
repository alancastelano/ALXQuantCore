//+------------------------------------------------------------------+
//|                                         MeanReversalStrategy.mqh  |
//|                                    Based on Chan & Kitapbayev     |
//|                                          Mean Reversion Trading   |
//|                                    Refactored for ALXQuantCore    |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
*/
#property copyright "Mean Reversal Strategy"
#property link      ""

#include "CustomIndicators.mqh"

/*
input group             "▸ 5. Mean Reversal"
input double            InpMR_EntryZScore                      = 1.5;                  //.   5.1   Entry Z-score
input double            InpMR_ExitZScore                       = 0.5;                  //.   5.2   Exit Z-score
input int               InpMR_Lookback                         = 20;                   //.   5.3   Lookback period
input int               InpMR_OULookback                       = 100;                  //.   5.4   OU lookback period
input ushort            InpMaxTrades_TF                        = 99;                    //.   5.5   Max Trend Trades/Day


*/



//+------------------------------------------------------------------+
//| Structure for OU Process Parameters                              |
//+------------------------------------------------------------------+
struct OUParameters
{
   double mu;        // Mean reversion speed
   double theta;     // Long-run mean
   double sigma;     // Volatility
   double halfLife;  // Half-life of mean reversion
   double lambda;    // Regression coefficient (negative for mean reversion)
};

//+------------------------------------------------------------------+
//| Mean Reversal Strategy Class - Signal Only                       |
//+------------------------------------------------------------------+
class CMeanReversalStrategy
{
private:
   string              m_symbol;
   ENUM_TIMEFRAMES     m_timeframe;

   OUParameters        m_ouParams;
   int                 m_ouLookback;

   double              m_entryZScore;
   double              m_exitZScore;
   int                 m_lookbackPeriod;

   double              m_currentZScore;

   bool                GetOHLC(double &close[], double &high[], double &low[], int bars, int startShift);
   void                EstimateOU(double &prices[], OUParameters &params);

public:
                      CMeanReversalStrategy();
                     ~CMeanReversalStrategy();

   bool                Init(string symbol, ENUM_TIMEFRAMES tf,
                            int lookbackPeriod = 20, double entryZ = 1.5,
                            double exitZ = 0.5, int ouLookback = 100);

   int                 Signal(double &zScore);  // Returns -1, 0, 1
   double              GetZScore() { return m_currentZScore; }
   double              GetHalfLife() { return m_ouParams.halfLife; }
   double              GetTheta() { return m_ouParams.theta; }
};

//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CMeanReversalStrategy::CMeanReversalStrategy()
{
   m_symbol = "";
   m_timeframe = PERIOD_H1;

   m_ouParams.mu = 0;
   m_ouParams.theta = 0;
   m_ouParams.sigma = 0;
   m_ouParams.halfLife = 0;
   m_ouParams.lambda = -0.1;
   m_ouLookback = 100;

   m_entryZScore = 1.5;
   m_exitZScore = 0.5;
   m_lookbackPeriod = 20;
   m_currentZScore = 0;
}

//+------------------------------------------------------------------+
//| Destructor                                                       |
//+------------------------------------------------------------------+
CMeanReversalStrategy::~CMeanReversalStrategy()
{
}

//+------------------------------------------------------------------+
//| Initialize the strategy                                          |
//+------------------------------------------------------------------+
bool CMeanReversalStrategy::Init(string symbol, ENUM_TIMEFRAMES tf,
                                 int lookbackPeriod, double entryZ,
                                 double exitZ, int ouLookback)
{
   m_symbol = symbol;
   m_timeframe = tf;
   m_entryZScore = entryZ;
   m_exitZScore = exitZ;
   m_lookbackPeriod = lookbackPeriod;
   m_ouLookback = ouLookback;

   if(SymbolInfoInteger(m_symbol, SYMBOL_TIME) <= 0)
   {
      Print("[MRS] Invalid symbol: ", m_symbol);
      return false;
   }

   double close[], high[], low[];
   if(!GetOHLC(close, high, low, m_ouLookback + 1, 1))
   {
      Print("[MRS] Failed to get price history");
      return false;
   }

   EstimateOU(close, m_ouParams);

   Print("[MRS] Initialized for ", m_symbol, " | Half-life: ",
         DoubleToString(m_ouParams.halfLife, 1), " bars | Lambda: ",
         DoubleToString(m_ouParams.lambda, 4));

   return true;
}

//+------------------------------------------------------------------+
//| Get OHLC data into arrays                                       |
//+------------------------------------------------------------------+
bool CMeanReversalStrategy::GetOHLC(double &close[], double &high[],
                                    double &low[], int bars, int startShift)
{
   ArrayResize(close, bars);
   ArrayResize(high, bars);
   ArrayResize(low, bars);

   ArraySetAsSeries(close, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);

   int got = CopyClose(m_symbol, m_timeframe, startShift, bars, close);
   if(got < bars) return false;

   got = CopyHigh(m_symbol, m_timeframe, startShift, bars, high);
   if(got < bars) return false;

   got = CopyLow(m_symbol, m_timeframe, startShift, bars, low);
   if(got < bars) return false;

   return true;
}

//+------------------------------------------------------------------+
//| Ornstein-Uhlenbeck parameter estimation                          |
//| Based on Chan Eq. 2.1 - Linear regression: deltaY = lambda*y_lag |
//+------------------------------------------------------------------+
void CMeanReversalStrategy::EstimateOU(double &prices[], OUParameters &params)
{
   int n = ArraySize(prices);
   if(n < 10) return;

   double y_lag[], deltaY[];
   ArrayResize(y_lag, n - 1);
   ArrayResize(deltaY, n - 1);

   for(int i = 0; i < n - 1; i++)
   {
      y_lag[i] = prices[i];
      deltaY[i] = prices[i + 1] - prices[i];
   }

   double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
   for(int i = 0; i < n - 1; i++)
   {
      sumX += y_lag[i];
      sumY += deltaY[i];
      sumXY += y_lag[i] * deltaY[i];
      sumX2 += y_lag[i] * y_lag[i];
   }

   double nCount = (double)(n - 1);
   double denom = nCount * sumX2 - sumX * sumX;
   if(MathAbs(denom) < 1e-7) return;

   double lambda = (nCount * sumXY - sumX * sumY) / denom;
   double mu = (sumY - lambda * sumX) / nCount;

   params.lambda = lambda;
   params.mu = MathAbs(lambda);
   params.theta = (lambda != 0) ? -mu / lambda : 0;

   if(lambda < 0)
      params.halfLife = -MathLog(2) / lambda;
   else
      params.halfLife = 99999;

   double resSumSq = 0;
   for(int i = 0; i < n - 1; i++)
   {
      double res = deltaY[i] - (lambda * y_lag[i] + mu);
      resSumSq += res * res;
   }
   params.sigma = (nCount > 2) ? MathSqrt(resSumSq / (nCount - 2)) : 0;
}

//+------------------------------------------------------------------+
//| Generate trading signal based on Z-score                         |
//| Returns: -1 = Short, 0 = Neutral, +1 = Long                     |
//+------------------------------------------------------------------+
int CMeanReversalStrategy::Signal(double &zScore)
{
   zScore = 0;
   m_currentZScore = 0;

   double close[];
   ArraySetAsSeries(close, true);
   int copied = CopyClose(m_symbol, m_timeframe, 0, m_lookbackPeriod + 1, close);
   if(copied < m_lookbackPeriod + 1) return 0;

   double currentPrice = close[0];

   double mean = CustomMA(m_symbol, m_timeframe, m_lookbackPeriod, 1, CUSTOM_PRICE_CLOSE);
   if(mean <= 0) return 0;

   double variance = 0;
   for(int i = 1; i <= m_lookbackPeriod; i++)
   {
      double diff = close[i] - mean;
      variance += diff * diff;
   }
   double stdDev = MathSqrt(variance / m_lookbackPeriod);
   if(stdDev < 1e-8) return 0;

   zScore = (currentPrice - mean) / stdDev;
   m_currentZScore = zScore;

   if(zScore > m_entryZScore)
      return -1;  // Price too high → Short

   if(zScore < -m_entryZScore)
      return 1;   // Price too low → Long

   return 0;
}
