//+------------------------------------------------------------------+
//|                                             CustomIndicators.mqh |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
*/
//+------------------------------------------------------------------+
enum enPrice
{
   PRICE_VWAP         = 1,   // VWAP
   PRICE_TWAP         = 2    // TWAP
};
//+------------------------------------------------------------------+
enum ENUM_CUSTOM_APPLIED_PRICE
{
   CUSTOM_PRICE_OPEN         = 0,   // Open
   CUSTOM_PRICE_HIGH         = 1,   // High
   CUSTOM_PRICE_LOW          = 2,   // Low
   CUSTOM_PRICE_CLOSE        = 3,   // Close
   CUSTOM_PRICE_MEDIAN       = 4,   // Median: (High + Low) / 2
   CUSTOM_PRICE_TYPICAL      = 5,   // Typical: (High + Low + Close) / 3
   CUSTOM_PRICE_WEIGHTED     = 6,   // Weighted Close: (High + Low + Close + Close) / 4
   CUSTOM_PRICE_VWAP         = 7,   // VWAP
   CUSTOM_PRICE_TWAP         = 8    // TWAP
};
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Retorna o preço baseado na enumeração para uma vela específica   |
//+------------------------------------------------------------------+
double GetCustomPrice(string symbol, ENUM_TIMEFRAMES period, int shift, ENUM_CUSTOM_APPLIED_PRICE applied_price)
{
   if(shift < 0) return 0.0;

   switch(applied_price)
   {
      case CUSTOM_PRICE_OPEN:
         return iOpen(symbol, period, shift);
         
      case CUSTOM_PRICE_HIGH:
         return iHigh(symbol, period, shift);
         
      case CUSTOM_PRICE_LOW:
         return iLow(symbol, period, shift);
         
      case CUSTOM_PRICE_CLOSE:
         return iClose(symbol, period, shift);
         
      case CUSTOM_PRICE_MEDIAN:
         return (iHigh(symbol, period, shift) + iLow(symbol, period, shift)) / 2.0;
         
      case CUSTOM_PRICE_TYPICAL:
         return (iHigh(symbol, period, shift) + iLow(symbol, period, shift) + iClose(symbol, period, shift)) / 3.0;
         
      case CUSTOM_PRICE_WEIGHTED:
         return (iHigh(symbol, period, shift) + iLow(symbol, period, shift) + iClose(symbol, period, shift) + iClose(symbol, period, shift)) / 4.0;
         
      case CUSTOM_PRICE_VWAP:
      {
         // Para VWAP de 1 vela: (High + Low + Close) / 3 * Volume (ou Tick Volume)
         // Em Forex, usamos Tick Volume. Em B3/Ações, pode ser Volume real.
         double h = iHigh(symbol, period, shift);
         double l = iLow(symbol, period, shift);
         double c = iClose(symbol, period, shift);
         long vol = iVolume(symbol, period, shift);
         if(h == 0 || l == 0 || c == 0 || vol <= 0) return 0.0;
         
         double typical_price = (h + l + c) / 3.0;
         return typical_price * vol; // Retorna Preço * Volume (O acumulado será feito na MA)
      }
      
      case CUSTOM_PRICE_TWAP:
         // TWAP é apenas a média simples do preço típico ao longo do tempo (Volume ignorado)
         return (iHigh(symbol, period, shift) + iLow(symbol, period, shift) + iClose(symbol, period, shift)) / 3.0;
         
      default:
         return iClose(symbol, period, shift); // Fallback
   }
}

//+------------------------------------------------------------------+
//| Custom MA - Cálculo puro sem indicador                           |
//| Suporta: Close, Open, Median, Typical, VWAP, TWAP, etc.         |
//+------------------------------------------------------------------+
double CustomMA(string symbol, ENUM_TIMEFRAMES period, int ma_period, int shift=1, ENUM_CUSTOM_APPLIED_PRICE applied_price=CUSTOM_PRICE_CLOSE)
{
   if(ma_period <= 0) return 0.0;
   
   // Lógica especial para VWAP (Acumula Preço*Volume / Volume Total)
   if(applied_price == CUSTOM_PRICE_VWAP)
   {
      double sum_pv = 0.0; // Soma Preço * Volume
      long sum_vol = 0;    // Soma Volume Total
      
      for(int i = shift; i < shift + ma_period; i++)
      {
         double pv = GetCustomPrice(symbol, period, i, CUSTOM_PRICE_VWAP); // Retorna Typical Price * Volume
         long vol = iVolume(symbol, period, i);
         
         if(pv > 0 && vol > 0)
         {
            sum_pv += pv;
            sum_vol += vol;
         }
      }
      
      if(sum_vol == 0) return 0.0;
      
      return (sum_pv / sum_vol); // VWAP = Soma(Preço*Volume) / Soma(Volume)
   }
   
   // Lógica padrão para as demais médias (SMA, TWAP, Median, etc.)
   double sum = 0.0;
   int valid_bars = 0;
   
   for(int i = shift; i < shift + ma_period; i++)
   {
      double price_value = GetCustomPrice(symbol, period, i, applied_price);
      
      if(price_value > 0) // Proteção contra dados vazios
      {
         sum += price_value;
         valid_bars++;
      }
   }
   
   if(valid_bars == 0) return 0.0;
   
   return (sum / valid_bars);
}

//+------------------------------------------------------------------+
//| Custom ATR - Cálculo puro sem indicador                          |
//+------------------------------------------------------------------+
double CustomATR(string symbol, ENUM_TIMEFRAMES period, int atr_period, int shift=1)
{
   if(atr_period <= 0) return 0.0;
   
   double sum_tr = 0.0;
   int valid_bars = 0;
   
   for(int i = shift; i < shift + atr_period; i++)
   {
      double high  = iHigh(symbol, period, i);
      double low   = iLow(symbol, period, i);
      double close_prev = iClose(symbol, period, i + 1); // Fechamento da vela anterior
      
      if(high == 0 || low == 0 || close_prev == 0) continue; // Proteção contra dados faltantes
      
      // Cálculo do True Range
      double tr1 = high - low;
      double tr2 = MathAbs(high - close_prev);
      double tr3 = MathAbs(low - close_prev);
      
      double true_range = MathMax(tr1, MathMax(tr2, tr3));
      
      sum_tr += true_range;
      valid_bars++;
   }
   
   if(valid_bars == 0) return 0.0;
   
   return (sum_tr / valid_bars); // Retorna a média (ATR)
}

//+------------------------------------------------------------------+
//| CustomBands - Bollinger Bands without indicator handle            |
//+------------------------------------------------------------------+
bool CustomBands(string symbol, ENUM_TIMEFRAMES tf, int period, double deviations,
                 int shift, double &mid, double &upper, double &lower)
{
   if(period <= 0) return false;

   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(symbol, tf, shift, period + shift, close) < period) return false;

   mid = 0;
   for(int i = 0; i < period; i++)
      mid += close[i];
   mid /= period;

   double variance = 0;
   for(int i = 0; i < period; i++)
   {
      double diff = close[i] - mid;
      variance += diff * diff;
   }
   double std_dev = MathSqrt(variance / period);

   upper = mid + deviations * std_dev;
   lower = mid - deviations * std_dev;
   return true;
}

//+------------------------------------------------------------------+
//| Calcula o VWAP Intra-Diário (Ancorado na abertura do dia)       |
//+------------------------------------------------------------------+
double GetDailyVWAP()
{
   MqlDateTime tm;
   TimeCurrent(tm);
   
   // Acha o horário de abertura do dia atual (00:00 ou início da sessão)
   datetime day_start = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   
   double sum_pv = 0.0;
   long sum_vol = 0;
   
   // Percorre todas as barras do dia atual
   int bars_per_day = Bars(_Symbol, _Period, day_start, TimeCurrent());
   
   for(int i = 0; i <= bars_per_day; i++)
   {
      double typical = (iHigh(_Symbol, _Period, i) + iLow(_Symbol, _Period, i) + iClose(_Symbol, _Period, i)) / 3.0;
      long vol = iVolume(_Symbol, _Period, i);
      
      sum_pv += (typical * vol);
      sum_vol += vol;
   }
   
   if(sum_vol == 0) return 0.0;
   
   return (sum_pv / sum_vol);
}

//+------------------------------------------------------------------+
//| Calcula as VWAP Bands (Desvio Padrão baseado em Volume)          |
//+------------------------------------------------------------------+
void GetVWAPBands(double &upper_band, double &lower_band, double multiplier = 1.0)
{
   double vwap = GetDailyVWAP();
   if(vwap == 0.0) { upper_band = 0; lower_band = 0; return; }
   
   MqlDateTime tm;
   TimeCurrent(tm);
   datetime day_start = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   int bars_per_day = Bars(_Symbol, _Period, day_start, TimeCurrent());
   
   double sum_sq_diff_vol = 0.0;
   long sum_vol = 0;
   
   for(int i = 0; i <= bars_per_day; i++)
   {
      double typical = (iHigh(_Symbol, _Period, i) + iLow(_Symbol, _Period, i) + iClose(_Symbol, _Period, i)) / 3.0;
      long vol = iVolume(_Symbol, _Period, i);
      
      double diff = typical - vwap;
      sum_sq_diff_vol += (diff * diff * vol); // Variância ponderada pelo volume
      sum_vol += vol;
   }
   
   if(sum_vol == 0) { upper_band = 0; lower_band = 0; return; }
   
   double std_dev = MathSqrt(sum_sq_diff_vol / sum_vol); // Desvio padrão do VWAP
   
   upper_band = vwap + (std_dev * multiplier);
   lower_band = vwap - (std_dev * multiplier);
}


//+------------------------------------------------------------------+
//| SuperTrend (usando CopyBuffer)                                   |
//+------------------------------------------------------------------+
int SuperTrendSignal(ENUM_TIMEFRAMES tf, int shift, int atr_period, double mult)
  {
   int handle = iATR(_Symbol, tf, atr_period);
   if(handle == INVALID_HANDLE) return 0;

   double atr[], high[], low[], close[];
   ArraySetAsSeries(atr, true); ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true); ArraySetAsSeries(close, true);

   if(CopyHigh(_Symbol,tf,0,atr_period+10,high) <= 0) return 0;
   if(CopyLow(_Symbol,tf,0,atr_period+10,low) <= 0) return 0;
   if(CopyClose(_Symbol,tf,0,atr_period+10,close) <= 0) return 0;
   if(CopyBuffer(handle,0,0,atr_period+10,atr) <= 0) return 0;

   double up[], dn[];
   ArrayResize(up, 10); ArrayResize(dn, 10);
   int trend = 1;
   up[0] = (high[0]+low[0])/2 + mult*atr[0];
   dn[0] = (high[0]+low[0])/2 - mult*atr[0];

   for(int i=1; i<10; i++)
     {
      double median = (high[i]+low[i])/2;
      up[i] = median + mult*atr[i];
      dn[i] = median - mult*atr[i];

      if(close[i] > up[i-1]) trend = 1;
      else if(close[i] < dn[i-1]) trend = -1;

      if(trend==1 && dn[i]<dn[i-1]) dn[i]=dn[i-1];
      if(trend==-1 && up[i]>up[i-1]) up[i]=up[i-1];
     }
   IndicatorRelease(handle);
   return (trend==1)?1:2;
  }
  
double CustomKeltner(string sym, ENUM_TIMEFRAMES tf, int per, double dev, int mode, int sh)
{
   double sum_c = 0, sum_tr = 0;
   for(int i=0; i<per; i++) {
      sum_c += iClose(sym, tf, sh+i);
      double h = iHigh(sym, tf, sh+i), l = iLow(sym, tf, sh+i), pc = iClose(sym, tf, sh+i+1);
      sum_tr += MathMax(h-l, MathMax(MathAbs(h-pc), MathAbs(l-pc)));
   }
   double ema = sum_c / per;
   double atr = sum_tr / per;
   return (mode==1) ? (ema+(dev*atr)) : (ema-(dev*atr));
}

double CustomiRSI(string sym, ENUM_TIMEFRAMES tf, int per, int sh) {
   double pos=0, neg=0;
   int look = 100;
   for(int i=look; i>=sh; i--) {
      double diff = iClose(sym, tf, i) - iClose(sym, tf, i+1);
      double rP = (diff>0)?diff:0; double rN = (diff<0)?-diff:0;
      pos=(pos*(per-1)+rP)/per; neg=(neg*(per-1)+rN)/per;
   }
   return (neg==0) ? 100.0 : (100.0-(100.0/(1.0+pos/neg)));
}  
  
