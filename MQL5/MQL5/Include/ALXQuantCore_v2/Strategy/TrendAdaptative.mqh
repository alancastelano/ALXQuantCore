//+------------------------------------------------------------------+
//|                                         TrendAdaptative.mqh      |
//|                                     Copyright 2026, ALXQuantCore |
//|               ML SuperTrend adaptativo (Hammad Dilber engine)    |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore"
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
*/
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group             "== Strategy Trend Adaptive =="

//--- Signal Mode
input int               InpTA_SignalMode               = 0;            // Signal Type (0=Reversal, 1=Breakout)
      bool              InpTA_RequireNewExtreme        = false;        // Require Fresh Pivot
      int               InpTA_MinBarsBetweenSigs       = 10;           // Signal Spacing

//--- SuperTrend
input int               InpTA_Sensitivity             = 50;            // Lookback Window
input int               InpTA_ATRPeriod               = 30;            // Smoothing Period
input double            InpTA_Multiplier              = 2.0;           // Band Width
      int               InpTA_PriceSource             = 7;             // Price Source (7=hlcc4)
      bool              InpTA_UseATR                  = true;          // True Range Mode

//--- RSI Filter
      bool              InpTA_EnableRSI               = true;          // RSI Active
      int               InpTA_RSILen                  = 14;            // RSI Length
      int               InpTA_RSILookbackTop          = 50;            // Hot Zone Memory
      int               InpTA_RSILookbackBot          = 50;            // Cold Zone Memory

//--- Volume Filter
      int               InpTA_VolLookback             = 3;             // Sample Depth
      double            InpTA_VolMultiplier           = 1.2;           // Surge Threshold
      bool              InpTA_RequireVolSpike         = false;         // Require Surge

//--- Key Levels
      bool              InpTA_MajorLevelsOnly         = false;         // Key Levels Only
      double            InpTA_MajorLevelDepth         = 4.5;           // Key Level Depth (xATR)

//--- Adaptive Master Dial
input int               InpTA_DialK                   = 5;            // Reactivity 1-20
      bool              InpTA_EnableBinLearning       = true;          // Micro-Batch Processing
      bool              InpTA_EnableTickPressure      = false;          // Live Pressure Sensor

//--- Auto-Tune
      bool              InpTA_EnableAdaptive          = true;          // Enable Auto-Tune
      bool              InpTA_UseFaintCycle           = true;          // Use Background Test Matrix
      bool              InpTA_LockATRBands            = true;          // Lock Envelope to Base

//--- Optimizer
      bool              InpTA_LearnEnabled            = true;          // Optimizer Enable
      double            InpTA_LearnRate               = 0.15;          // Step Size
      int               InpTA_RollN                   = 30;            // History Depth
      double            InpTA_WinHi                   = 0.62;          // Win Ceiling
      double            InpTA_WinLo                   = 0.38;          // Win Floor
      bool              InpTA_UseATRNorm              = true;          // Normalize Returns by ATR
      double            InpTA_SmoothAlpha             = 0.35;          // Momentum Smoothing
      int               InpTA_ParamUpdateEvery        = 5;             // Update Cooldown (bars)
      double            InpTA_DeadbandMult            = 0.01;          // Deadband Width
      double            InpTA_DeadbandLen             = 0.25;          // Deadband Period
      double            InpTA_QuantStepMult           = 0.05;          // Quant Step Width
      double            InpTA_QuantStepStop           = 0.02;          // Quant Step Guard
      double            InpTA_QuantStepTP             = 0.02;          // Quant Step Target
      double            InpTA_QuantStepBrk            = 0.01;          // Quant Step Edge
      int               InpTA_RevertEvery             = 200;           // Anchor Revert Interval
      double            InpTA_RevertStep              = 0.01;          // Anchor Revert Strength

//--- Cognitive Map
      bool              InpTA_UseCognitiveMap         = true;          // Enable Regime Grid
      int               InpTA_MapGridX                = 8;             // Regime Bins
      int               InpTA_MapGridY                = 8;             // Volatility Bins
      double            InpTA_MapSigma                = 0.8;           // Neighbor Blend Radius
      int               InpTA_MapHalfLife             = 50;            // Decay Half-Life (trades)
      int               InpTA_MapConfScale            = 20;            // Confidence Ramp (trades)
      double            InpTA_MapWeightMax            = 0.65;          // Max Grid Influence

//--- Decay Traces
      bool              InpTA_UseSTM                  = true;          // Enable Trace Buffer
      int               InpTA_STMSize                 = 30;            // Buffer Depth
      double            InpTA_STMDecay                = 0.02;          // Fade Rate per Bar
      int               InpTA_STMConsolidateEvery     = 200;           // Merge Interval bars
      double            InpTA_STMMAETailThr           = 0.8;           // Adverse Move Threshold
      double            InpTA_STMTailTightenCap       = 0.02;          // Guard Tighten Cap

//--- Risk Guard
input int               InpTA_MaxTradesPerSession     = 2;            // Max Entries Per Session
input double            InpTA_MaxSessionLoss          = -1000.0;       // Session Loss Limit USD
      int               InpTA_BaseCooldownBars        = 5;             // Base Pause After Loss
      int               InpTA_MaxConsecLosses         = 5;             // Streak Limit
      bool              InpTA_DynamicCooldown         = true;          // Scale Pause by Loss Size

//--- Display (minimal)
      int               InpTA_RSITop                  = 70;            // RSI Hot Level
      int               InpTA_RSIBot                  = 30;            // RSI Cold Level
      double            InpTA_TradeSizeUSD            = 1000.0;        // Sim Position USD

//+------------------------------------------------------------------+
//| Structs                                                          |
//+------------------------------------------------------------------+
struct SProbeTA
{
   double entry;
   int    bar;
   int    dir;
   bool   active;
   double atr_val;
};

struct SGridCellTA
{
   double mean_atr_ret;
   double down_ewm;
   int    count;
   double conf;
   double d_mult, d_len, d_stop, d_tp, d_brk;
};

struct SDecayTraceTA
{
   double atr_ret, mae_atr, regime, vol_norm, energy;
   int    dir;
};

struct SBatchSampleTA
{
   double atr_ret, mae_atr, pnl_usd, conf;
};

//+------------------------------------------------------------------+
//| Classe CTrendAdaptative                                          |
//+------------------------------------------------------------------+
class CTrendAdaptative
{
private:
   CTrade            m_trade;
   ulong             m_magic;
   string            m_symbol;

   //--- Dual SuperTrend state
   double            m_plot_up, m_plot_dn;
   int               m_plot_trend;
   double            m_plot_rma;
   double            m_sig_up, m_sig_dn;
   int               m_sig_trend, m_sig_trend_prev;
   double            m_sig_rma;

   //--- Adaptive params
   double            m_mult, m_atrLen, m_stopMult, m_tpMult, m_brkBuf, m_sensitivity;

   //--- Regime
   double            m_regime;
   int               m_lastRegBar;

   //--- Signal flags
   int               m_topFlag, m_topFlagPrev, m_botFlag, m_botFlagPrev;
   int               m_lastSigBar;

   //--- Rolling queues
   double            m_highs[], m_lows[], m_rsis[], m_vols[], m_pressureLog[];

   //--- Test probes
   SProbeTA          m_probesL[], m_probesS[];

   //--- Rolling stats
   double            m_rollUSD_L[], m_rollATR_L[], m_rollRet_L[];
   double            m_rollUSD_S[], m_rollATR_S[], m_rollRet_S[];
   double            m_gp_L, m_gl_L, m_gp_S, m_gl_S;
   int               m_tot_L, m_win_L, m_tot_S, m_win_S;
   double            m_consecLoss_L, m_consecLoss_S;
   double            m_sharpe_L, m_sortino_L, m_sharpe_S, m_sortino_S;

   //--- Actual signal counters
   int               m_sig_tot_L, m_sig_win_L, m_sig_tot_S, m_sig_win_S;

   //--- Grid
   SGridCellTA       m_grid[];

   //--- Decay traces
   SDecayTraceTA     m_decay[];

   //--- Micro-batch
   SBatchSampleTA    m_batchL[], m_batchS[];
   bool              m_firedL, m_firedS;
   double            m_muBL, m_muBS;
   double            m_dMultBL, m_dLenBL, m_dStopBL, m_dTPBL, m_dBrkBL;
   double            m_dMultBS, m_dLenBS, m_dStopBS, m_dTPBS, m_dBrkBS;

   //--- Optimizer
   int               m_lastParamBar;

   //--- Risk guard
   int               m_cooldownUntil, m_tradesSession, m_consecLosses;
   double            m_sessionPnL;
   int               m_lastSessionDay;
   int               m_lastGuardBar;

   //--- Pressure sensor
   double            m_pressure, m_bullFlow, m_bearFlow;

   //--- Bar tracking
   datetime          m_lastBarTime;

   //--- Session day
   datetime          m_lastSessionDayTime;

   //==================================================================
   // Helper: clamp
   //==================================================================
   double Clamp(double v, double lo, double hi)    { return MathMax(lo, MathMin(hi, v)); }
   int    IClamp(int v, int lo, int hi)            { return MathMax(lo, MathMin(hi, v)); }
   double Quantize(double x, double step)           { return step == 0 ? x : MathRound(x / step) * step; }

   //==================================================================
   // Queue helpers
   //==================================================================
   void QPush(double &arr[], double val, int cap)
   {
      int sz = ArraySize(arr);
      if(sz >= cap) { for(int i = 0; i < sz - 1; i++) arr[i] = arr[i + 1]; arr[sz - 1] = val; }
      else          { ArrayResize(arr, sz + 1); arr[sz] = val; }
   }

   void QPushB(SBatchSampleTA &arr[], SBatchSampleTA &val, int cap)
   {
      int sz = ArraySize(arr);
      if(sz >= cap) { for(int i = 0; i < sz - 1; i++) arr[i] = arr[i + 1]; arr[sz - 1] = val; }
      else          { ArrayResize(arr, sz + 1); arr[sz] = val; }
   }

   double QAvg(double &arr[], int n)
   {
      int sz = ArraySize(arr); if(sz == 0 || n <= 0) return 0;
      double s = 0; int c = 0;
      for(int i = MathMax(0, sz - n); i < sz; i++) { s += arr[i]; c++; }
      return c > 0 ? s / c : 0;
   }

   double QAvgFull(double &arr[])
   {
      int sz = ArraySize(arr); if(sz == 0) return 0;
      double s = 0; for(int i = 0; i < sz; i++) s += arr[i]; return s / sz;
   }

   double QWinRate(double &arr[])
   {
      int sz = ArraySize(arr); if(sz == 0) return 0.5;
      double w = 0; for(int i = 0; i < sz; i++) if(arr[i] > 0) w++; return w / sz;
   }

   double QMax(double &arr[], int n)
   {
      int sz = ArraySize(arr); if(sz == 0 || n <= 0) return -1e18;
      double m = arr[MathMax(0, sz - n)];
      for(int i = MathMax(0, sz - n) + 1; i < sz; i++) if(arr[i] > m) m = arr[i];
      return m;
   }

   double QMin(double &arr[], int n)
   {
      int sz = ArraySize(arr); if(sz == 0 || n <= 0) return 1e18;
      double m = arr[MathMax(0, sz - n)];
      for(int i = MathMax(0, sz - n) + 1; i < sz; i++) if(arr[i] < m) m = arr[i];
      return m;
   }

   double QSortino(double &arr[])
   {
      int sz = ArraySize(arr); if(sz == 0) return 0;
      double mean = QAvgFull(arr), ddSum = 0; int ddCnt = 0;
      for(int i = 0; i < sz; i++) if(arr[i] < 0) { ddSum += arr[i] * arr[i]; ddCnt++; }
      if(ddCnt == 0) return 0;
      double dd = MathSqrt(ddSum / ddCnt);
      return dd > 0 ? mean / dd : 0;
   }

   double QSharpe(double &arr[])
   {
      int sz = ArraySize(arr); if(sz < 2) return 0;
      double mean = QAvgFull(arr), ssq = 0;
      for(int i = 0; i < sz; i++) ssq += (arr[i] - mean) * (arr[i] - mean);
      double sd = MathSqrt(ssq / sz);
      return sd > 0 ? mean / sd : 0;
   }

   //==================================================================
   // RSI interno
   //==================================================================
   double CalcRSI(int shift)
   {
      int len = InpTA_RSILen;
      if(len <= 0) return 50.0;
      double gain = 0, loss = 0;
      for(int i = shift; i < shift + len; i++)
      {
         double d = iClose(m_symbol, PERIOD_CURRENT, i) - iClose(m_symbol, PERIOD_CURRENT, i + 1);
         if(d > 0) gain += d; else loss -= d;
      }
      if(gain + loss == 0) return 50.0;
      double rs = (gain / len) / (loss / len);
      return 100.0 - (100.0 / (1.0 + rs));
   }

   //==================================================================
   // ATR interno
   //==================================================================
   double CalcATR(int period, int shift)
   {
      if(period <= 0) return 0.0001;
      double sum = 0; int c = 0;
      for(int i = shift; i < shift + period; i++)
      {
         double h = iHigh(m_symbol, PERIOD_CURRENT, i);
         double l = iLow(m_symbol, PERIOD_CURRENT, i);
         double cp = iClose(m_symbol, PERIOD_CURRENT, i + 1);
         if(h == 0 || l == 0) continue;
         double tr = MathMax(h - l, MathMax(MathAbs(h - cp), MathAbs(l - cp)));
         sum += tr; c++;
      }
      return c > 0 ? sum / c : 0.0001;
   }

   //==================================================================
   // ADX simplificado (DX baseado em +DI/-DI)
   //==================================================================
   double CalcADX(int shift)
   {
      int period = 14;
      double plusDI = 0, minusDI = 0;
      for(int i = shift; i < shift + period; i++)
      {
         double upMove  = iHigh(m_symbol, PERIOD_CURRENT, i) - iHigh(m_symbol, PERIOD_CURRENT, i + 1);
         double downMove = iLow(m_symbol, PERIOD_CURRENT, i + 1) - iLow(m_symbol, PERIOD_CURRENT, i);
         double atr = CalcATR(period, i);
         if(atr <= 0) continue;
         if(upMove > downMove && upMove > 0) plusDI  += upMove / atr;
         if(downMove > upMove && downMove > 0) minusDI += downMove / atr;
      }
      double sum = plusDI + minusDI;
      if(sum == 0) return 25.0;
      double dx = MathAbs(plusDI - minusDI) / sum * 100.0;
      return dx;
   }

   //==================================================================
   // SuperTrend step
   //==================================================================
   void ST_Step(double src, double mult, int period, bool useRMA,
                double prevClose, double curClose, double tr,
                double &up, double &dn, int &trend, double &rmaVal)
   {
      double alpha = 1.0 / MathMax(1, period);
      if(useRMA) rmaVal = (rmaVal == 0) ? tr : rmaVal + alpha * (tr - rmaVal);
      else       rmaVal = (rmaVal == 0) ? tr : (2.0 / (period + 1)) * tr + (1.0 - 2.0 / (period + 1)) * rmaVal;

      double band = mult * rmaVal;
      double newUp = src - band, newDn = src + band;
      if(up != 0)  newUp = (prevClose > up)  ? MathMax(newUp, up)  : newUp;
      if(dn != 0)  newDn = (prevClose < dn)  ? MathMin(newDn, dn)  : newDn;
      up = newUp; dn = newDn;
      if(trend == -1 && curClose > dn) trend = 1;
      else if(trend == 1 && curClose < up) trend = -1;
   }

   //==================================================================
   // Price source selection
   //==================================================================
   double PriceSource(int mode, double o, double h, double l, double c)
   {
      switch(mode)
      {
         case 0: return o;
         case 1: return h;
         case 2: return l;
         case 3: return c;
         case 4: return (h + l) / 2.0;
         case 5: return (h + l + c) / 3.0;
         case 6: return (o + h + l + c) / 4.0;
         default: return (h + l + c * 2.0) / 4.0; // hlcc4
      }
   }

   //==================================================================
   // Hurst exponent (R/S analysis)
   //==================================================================
   double CalcHurst(int idx, int total, int len)
   {
      int L = MathMax(len, 16);
      if(idx + L >= total) return 0.5;
      double close[];
      ArrayResize(close, L);
      for(int i = 0; i < L; i++) close[i] = iClose(m_symbol, PERIOD_CURRENT, idx + i);
      double mean = 0;
      for(int i = 0; i < L; i++) mean += close[i];
      mean /= L;
      double cum = 0, maxC = 0, minC = 0, ssq = 0;
      for(int i = 0; i < L; i++)
      {
         double dev = close[i] - mean;
         cum += dev;
         if(cum > maxC) maxC = cum;
         if(cum < minC) minC = cum;
         ssq += dev * dev;
      }
      double R = maxC - minC;
      double S = MathSqrt(ssq / L);
      if(S == 0 || L <= 1) return 0.5;
      return Clamp(MathLog(R / S) / MathLog(L), 0.0, 1.0);
   }

   //==================================================================
   // Entropy
   //==================================================================
   double CalcEntropy(int idx, int total, int len)
   {
      int L = MathMax(len, 16);
      if(idx + L >= total) return 0.0;
      double ups = 0, dns = 0;
      for(int i = 1; i <= L; i++)
      {
         double d = iClose(m_symbol, PERIOD_CURRENT, idx + i - 1) - iClose(m_symbol, PERIOD_CURRENT, idx + i);
         if(d > 0) ups++; else if(d < 0) dns++;
      }
      double tot = ups + dns; if(tot == 0) return 0;
      double p1 = ups / tot, p2 = dns / tot, H = 0;
      if(p1 > 0) H -= p1 * MathLog(p1);
      if(p2 > 0) H -= p2 * MathLog(p2);
      return Clamp(H / MathLog(2.0), 0.0, 1.0);
   }

   //==================================================================
   // Regime detection
   //==================================================================
   double DetectRegime(int idx, int total, double adxVal)
   {
      double H   = CalcHurst(idx, total, 64);
      double Ent = CalcEntropy(idx, total, 64);
      double trend_str = Clamp(adxVal / 50.0, 0, 1);
      return Clamp(0.35 * (1 - Ent) + 0.35 * Clamp((H - 0.5) * 2, 0, 1) + 0.30 * trend_str, 0.0, 1.0);
   }

   //==================================================================
   // Grid helpers
   //==================================================================
   int  GridIdx(int ix, int iy) { return ix * InpTA_MapGridY + iy; }
   double Gauss(int dx, int dy, double s) { return MathExp(-(dx * dx + dy * dy) / (2 * s * s)); }
   int  Bucket(double x, int bins) { return IClamp((int)MathFloor(x * bins), 0, bins - 1); }

   void GridUpdate(int ix, int iy, double atr_ret,
                   double dM, double dL, double dS, double dT, double dB)
   {
      int idx = GridIdx(ix, iy);
      if(idx < 0 || idx >= ArraySize(m_grid)) return;
      double alpha = 1.0 - MathExp(-MathLog(2.0) / MathMax(1, InpTA_MapHalfLife));
      SGridCellTA c = m_grid[idx];
      c.mean_atr_ret = c.mean_atr_ret * (1 - alpha) + atr_ret * alpha;
      double dn2 = atr_ret < 0 ? atr_ret * atr_ret : 0.0;
      c.down_ewm = c.down_ewm * (1 - alpha) + dn2 * alpha;
      c.count++;
      c.conf = 1.0 - MathExp(-(double)c.count / MathMax(1, InpTA_MapConfScale));
      c.d_mult  = c.d_mult * (1 - alpha) + dM * alpha;
      c.d_len   = c.d_len  * (1 - alpha) + dL * alpha;
      c.d_stop  = c.d_stop * (1 - alpha) + dS * alpha;
      c.d_tp    = c.d_tp   * (1 - alpha) + dT * alpha;
      c.d_brk   = c.d_brk  * (1 - alpha) + dB * alpha;
      m_grid[idx] = c;
   }

   void GridRecommend(int ix, int iy,
                      double &m, double &l, double &s, double &t, double &b, double &confOut)
   {
      double wsum = 0, wconf = 0;
      m = 0; l = 0; s = 0; t = 0; b = 0; confOut = 0;
      for(int dx = -1; dx <= 1; dx++) for(int dy = -1; dy <= 1; dy++)
      {
         int nx = IClamp(ix + dx, 0, InpTA_MapGridX - 1);
         int ny = IClamp(iy + dy, 0, InpTA_MapGridY - 1);
         int idx = GridIdx(nx, ny);
         if(idx < 0 || idx >= ArraySize(m_grid)) continue;
         SGridCellTA c = m_grid[idx];
         if(c.count == 0) continue;
         double w = Gauss(dx, dy, InpTA_MapSigma);
         wsum += w; wconf += w * c.conf;
         m += w * c.conf * c.d_mult; l += w * c.conf * c.d_len;
         s += w * c.conf * c.d_stop; t += w * c.conf * c.d_tp; b += w * c.conf * c.d_brk;
      }
      if(wsum == 0) return;
      double den = wconf == 0 ? wsum : wconf;
      m /= den; l /= den; s /= den; t /= den; b /= den;
      confOut = Clamp(wconf / wsum, 0.0, 1.0);
   }

   //==================================================================
   // Decay traces
   //==================================================================
   void DecayPush(double atr_ret, double mae_atr, double regime, double vol, int dir)
   {
      int sz = ArraySize(m_decay);
      ArrayResize(m_decay, sz + 1);
      m_decay[sz].atr_ret = atr_ret; m_decay[sz].mae_atr = mae_atr;
      m_decay[sz].regime  = regime;  m_decay[sz].vol_norm = vol;
      m_decay[sz].energy  = 1.0;     m_decay[sz].dir = dir;
      while(ArraySize(m_decay) > InpTA_STMSize)
      {
         for(int i = 0; i < ArraySize(m_decay) - 1; i++) m_decay[i] = m_decay[i + 1];
         ArrayResize(m_decay, ArraySize(m_decay) - 1);
      }
   }

   void DecayStep()
   {
      for(int i = ArraySize(m_decay) - 1; i >= 0; i--)
      {
         m_decay[i].energy *= (1.0 - InpTA_STMDecay);
         if(m_decay[i].energy < 0.05)
         {
            for(int j = i; j < ArraySize(m_decay) - 1; j++) m_decay[j] = m_decay[j + 1];
            ArrayResize(m_decay, ArraySize(m_decay) - 1);
         }
      }
   }

   double DecayTailFeedback()
   {
      int n = ArraySize(m_decay); if(n == 0) return 0;
      double sumW = 0, sumTail = 0;
      for(int i = 0; i < n; i++)
      {
         sumW += m_decay[i].energy;
         if(m_decay[i].mae_atr > InpTA_STMMAETailThr) sumTail += m_decay[i].energy;
      }
      double frac = sumW > 0 ? sumTail / sumW : 0;
      double k = Clamp((frac - 0.25) / 0.75, 0.0, 1.0);
      return -InpTA_STMTailTightenCap * k;
   }

   //==================================================================
   // Master Dial
   //==================================================================
   void MasterParams(int K, int &N, int &stride, double &Wmin, double &wBatch,
                     double &cMult, double &cLen, double &cStop, double &cTP, double &cBrk,
                     double &dbMult, double &dbLen, double &alpha)
   {
      double k = ((double)K - 1.0) / 19.0;
      N       = IClamp((int)MathRound(20.0 - 16.0 * k), 4, 20);
      stride  = MathMax(1, (int)MathRound(N * (1.0 - 0.9 * k)));
      Wmin    = MathMax(0.0, (double)N * (0.80 - 0.40 * k));
      wBatch  = 0.25 + 0.35 * k;
      cMult   = 0.02 + 0.06 * k; cLen = 0.5 + 1.5 * k;
      cStop   = 0.01 + 0.04 * k; cTP  = 0.01 + 0.03 * k; cBrk = 0.005 + 0.025 * k;
      dbMult  = MathMax(0.003, InpTA_DeadbandMult * (1.0 - 0.6 * k));
      dbLen   = MathMax(0.10,  InpTA_DeadbandLen  * (1.0 - 0.6 * k));
      alpha   = Clamp(0.25 + 0.40 * k, 0.20, 0.65);
   }

   //==================================================================
   // Micro-batch fire
   //==================================================================
   bool BatchFire(SBatchSampleTA &bin[], int N, int stride, double Wmin,
                  double cM, double cL, double cS, double cT, double cB,
                  double &dM, double &dL, double &dS, double &dT, double &dBrk, double &muOut)
   {
      dM = 0; dL = 0; dS = 0; dT = 0; dBrk = 0; muOut = 0;
      int sz = ArraySize(bin); if(sz < N) return false;
      double sumW = 0, sumRet = 0, wNeg = 0, sumNegVar = 0, sumMAE = 0, gpW = 0, glW = 0;
      for(int i = 0; i < N; i++)
      {
         double wC = Clamp(bin[i].conf, 0, 1);
         double wQ = 1.0 / (1.0 + MathMax(0, bin[i].mae_atr));
         double w = wC * wQ; sumW += w; sumRet += w * bin[i].atr_ret;
         if(bin[i].atr_ret < 0) { wNeg += w; sumNegVar += w * (bin[i].atr_ret * bin[i].atr_ret); }
         sumMAE += w * bin[i].mae_atr;
         if(bin[i].pnl_usd > 0) gpW += w * bin[i].pnl_usd;
         else if(bin[i].pnl_usd < 0) glW += w * (-bin[i].pnl_usd);
      }
      double mu = sumW > 0 ? sumRet / sumW : 0;
      double sr = (wNeg > 0 && sumNegVar > 0) ? mu / MathSqrt(sumNegVar / wNeg) : 0;
      double pf = glW > 0 ? gpW / glW : (gpW > 0 ? 9.99 : 0.0);
      double confF = Wmin > 0 ? Clamp(sumW / Wmin, 0.0, 1.5) : 1.0;
      muOut = mu;
      bool good = (mu > 0) && (pf > 1.15) && (sr > 0.8);
      bool bad  = (mu < 0) || (pf < 0.95) || (sr < 0.2);
      if(good) { dM = -cM * confF; dL = -cL * confF; dS = -cS * confF; dT = +cT * 0.5 * confF; dBrk = -cB * confF; }
      if(bad)  { dM = +cM * confF; dL = +cL * confF; dS = (sumMAE / sumW > 0.6 ? -cS : +0.5 * cS) * confF; dT = -0.3 * cT * confF; dBrk = +cB * confF; }
      for(int j = 0; j < stride && ArraySize(bin) > 0; j++)
      {
         for(int k = 0; k < ArraySize(bin) - 1; k++) bin[k] = bin[k + 1];
         ArrayResize(bin, ArraySize(bin) - 1);
      }
      return true;
   }

   //==================================================================
   // Optimizer proposals
   //==================================================================
   void LearnProposals(double winrate, double avgUsd, double avgAtr,
                       double sortino, double avgMAE, double pf,
                       double avgWin, double avgLoss, int sampleCount,
                       double curMult, double curLen, double sharpe, int consecLoss,
                       double &dMult, double &dLen, double &dStop, double &dTP, double &dBrk)
   {
      dMult = 0; dLen = 0; dStop = 0; dTP = 0; dBrk = 0;
      if(!InpTA_LearnEnabled || !InpTA_EnableAdaptive || sampleCount <= 0) return;
      double conf = 1.0 / MathSqrt(MathMax(1.0, (double)sampleCount));
      double step = InpTA_LearnRate * conf;
      double pb = ArraySize(m_pressureLog) >= 5 ? QAvg(m_pressureLog, 5) : 0;
      if(MathAbs(pb) > 0.2) step *= (1 + MathAbs(pb) * 0.5);
      bool weak   = (winrate < InpTA_WinLo) && (InpTA_UseATRNorm ? avgAtr < 0 : avgUsd < 0);
      bool strong = (winrate > InpTA_WinHi) && (InpTA_UseATRNorm ? avgAtr > 0 : avgUsd > 0);
      if(weak)   { dMult += +0.08 * step; dLen += +curLen * 0.05 * step; }
      if(strong) { dMult += -0.05 * step; dLen += -curLen * 0.03 * step; }
      if(avgMAE > 0.60)  dMult += +0.02 * step;
      if(sortino < 0)    dMult += +0.04 * step;
      if(sortino > 1.2)  dMult += -0.03 * step;
      if(winrate > InpTA_WinHi && pf > 0 && pf < 1.2) dTP  += +0.02 * step;
      if(winrate < InpTA_WinLo && avgLoss > avgWin * 1.2) dStop += -0.03 * step;
      if(winrate < InpTA_WinLo && avgLoss <= avgWin * 1.2) dStop += +0.02 * step;
      if(m_regime >= 0.7 && (InpTA_UseATRNorm ? avgAtr > 0 : avgUsd > 0)) dBrk += -0.02 * step;
      if(m_regime <= 0.3 && (InpTA_UseATRNorm ? avgAtr < 0 : avgUsd < 0)) dBrk += +0.02 * step;
      if(sharpe < 0.5)   dMult += +0.02 * step;
      if(sortino > 1.5)  dMult += -0.02 * step;
      if(consecLoss >= 3) dStop += +0.03 * step;
   }

   //==================================================================
   // Test probe management
   //==================================================================
   void OpenProbe(SProbeTA &book[], int dir, double entryPrice, double atrVal, int barNum)
   {
      int free = -1;
      for(int i = 0; i < ArraySize(book); i++) if(!book[i].active) { free = i; break; }
      if(free == -1) { ArrayResize(book, ArraySize(book) + 1); free = ArraySize(book) - 1; }
      book[free].entry  = entryPrice;
      book[free].bar    = barNum;
      book[free].dir    = dir;
      book[free].active = true;
      book[free].atr_val = atrVal;
   }

   int CountActive(SProbeTA &book[])
   {
      int c = 0; for(int i = 0; i < ArraySize(book); i++) if(book[i].active) c++;
      return c;
   }

   bool CloseMatured(SProbeTA &book[], int dir, double loHold, double hiHold,
                     double closePrice, int barNum,
                     double &usd, double &atrR, double &mae)
   {
      usd = EMPTY_VALUE; atrR = 0; mae = 0;
      int oldest = INT_MAX, idx = -1;
      for(int i = 0; i < ArraySize(book); i++)
      {
         if(!book[i].active) continue;
         if(barNum - book[i].bar >= 5 && book[i].bar < oldest) { oldest = book[i].bar; idx = i; }
      }
      if(idx < 0) return false;
      SProbeTA p = book[idx];
      double ret = (closePrice - p.entry) * p.dir;
      double pct = p.entry != 0 ? ret / p.entry : 0;
      usd = pct * InpTA_TradeSizeUSD;
      atrR = p.atr_val != 0 ? ret / p.atr_val : 0;
      double maeP = dir == 1 ? MathMax(0, p.entry - loHold) : MathMax(0, hiHold - p.entry);
      mae = p.atr_val != 0 ? maeP / p.atr_val : 0;
      book[idx].active = false;
      return true;
   }

   //==================================================================
   // Risk guard
   //==================================================================
   bool CanTrade(int barNum)
   {
      if(m_cooldownUntil > 0 && barNum <= m_cooldownUntil) return false;
      if(m_tradesSession >= InpTA_MaxTradesPerSession)    return false;
      if(m_sessionPnL <= InpTA_MaxSessionLoss)             return false;
      if(m_consecLosses >= InpTA_MaxConsecLosses)          return false;
      return true;
   }

   void ApplyRiskGuard(double pnl, int barNum)
   {
      if(barNum == m_lastGuardBar) return;
      m_lastGuardBar = barNum;
      m_tradesSession++; m_sessionPnL += pnl;
      if(pnl < 0)
      {
         m_consecLosses++;
         double lossMag = MathAbs(pnl);
         if(InpTA_DynamicCooldown)
         {
            double sc = lossMag / (InpTA_TradeSizeUSD * 0.02);
            m_cooldownUntil = barNum + (int)MathMin(50, InpTA_BaseCooldownBars * (1 + sc));
         }
         else m_cooldownUntil = barNum + InpTA_BaseCooldownBars;
      }
      else m_consecLosses = 0;
   }

   //==================================================================
   // Session reset
   //==================================================================
   void CheckSessionReset(datetime barTime)
   {
      MqlDateTime dtNow, dtLast;
      TimeToStruct(barTime, dtNow);
      TimeToStruct(m_lastSessionDayTime, dtLast);
      if(m_lastSessionDayTime == 0 || dtNow.day != dtLast.day || dtNow.mon != dtLast.mon)
      {
         m_tradesSession   = 0;
         m_sessionPnL      = 0;
         m_consecLosses    = 0;
         m_cooldownUntil   = 0;
         m_lastGuardBar    = -1;
         m_lastSessionDayTime = barTime;
      }
   }

public:
   //+------------------------------------------------------------------+
   //| Constructor / Destructor                                        |
   //+------------------------------------------------------------------+
   CTrendAdaptative()
   {
      m_plot_up = 0; m_plot_dn = 0; m_plot_trend = 1; m_plot_rma = 0;
      m_sig_up = 0; m_sig_dn = 0; m_sig_trend = 1; m_sig_rma = 0; m_sig_trend_prev = 1;
      m_mult = InpTA_Multiplier; m_atrLen = InpTA_ATRPeriod;
      m_stopMult = 1.0; m_tpMult = 2.0; m_brkBuf = 0.20; m_sensitivity = InpTA_Sensitivity;
      m_regime = 0.5; m_lastRegBar = -99;
      m_topFlag = 0; m_topFlagPrev = 0; m_botFlag = 0; m_botFlagPrev = 0;
      m_lastSigBar = -InpTA_MinBarsBetweenSigs - 1;
      m_gp_L = 0; m_gl_L = 0; m_gp_S = 0; m_gl_S = 0;
      m_tot_L = 0; m_win_L = 0; m_tot_S = 0; m_win_S = 0;
      m_sig_tot_L = 0; m_sig_win_L = 0; m_sig_tot_S = 0; m_sig_win_S = 0;
      m_consecLoss_L = 0; m_consecLoss_S = 0;
      m_sharpe_L = 0; m_sortino_L = 0; m_sharpe_S = 0; m_sortino_S = 0;
      m_lastParamBar = -1;
      m_cooldownUntil = 0; m_tradesSession = 0; m_sessionPnL = 0; m_consecLosses = 0; m_lastGuardBar = -1;
      m_pressure = 0; m_bullFlow = 0; m_bearFlow = 0;
      m_lastBarTime = 0;
      m_firedL = false; m_firedS = false;
      m_muBL = 0; m_muBS = 0;
      m_dMultBL = 0; m_dLenBL = 0; m_dStopBL = 0; m_dTPBL = 0; m_dBrkBL = 0;
      m_dMultBS = 0; m_dLenBS = 0; m_dStopBS = 0; m_dTPBS = 0; m_dBrkBS = 0;
      m_lastSessionDayTime = 0;

      int cells = InpTA_MapGridX * InpTA_MapGridY;
      ArrayResize(m_grid, cells);
      for(int i = 0; i < cells; i++) { ZeroMemory(m_grid[i]); }

      ArrayResize(m_decay, 0);
      ArrayResize(m_batchL, 0); ArrayResize(m_batchS, 0);
      ArrayResize(m_highs, 0); ArrayResize(m_lows, 0);
      ArrayResize(m_rsis, 0); ArrayResize(m_vols, 0);
      ArrayResize(m_pressureLog, 0);
      ArrayResize(m_probesL, 0); ArrayResize(m_probesS, 0);
      ArrayResize(m_rollUSD_L, 0); ArrayResize(m_rollATR_L, 0); ArrayResize(m_rollRet_L, 0);
      ArrayResize(m_rollUSD_S, 0); ArrayResize(m_rollATR_S, 0); ArrayResize(m_rollRet_S, 0);
   }

   ~CTrendAdaptative() {}

   //+------------------------------------------------------------------+
   //| Init                                                            |
   //+------------------------------------------------------------------+
   bool Init(ulong magic, string symbol)
   {
      m_magic  = magic;
      m_symbol = symbol;
      m_trade.SetExpertMagicNumber(magic);
      return true;
   }

   //+------------------------------------------------------------------+
   //| Signal — retorna 0 (nada), 1 (buy), 2 (sell)                  |
   //+------------------------------------------------------------------+
   uchar Signal()
   {
      datetime barTime = iTime(m_symbol, PERIOD_CURRENT, 0);
      int totalBars = Bars(m_symbol, PERIOD_CURRENT);
      int barNum = totalBars - 1;

      //--- Só processa uma vez por barra
      if(barTime == m_lastBarTime)
      {
         if(CanTrade(barNum))
         {
            if(m_sig_trend == 1) { ApplyRiskGuard(0.0, barNum); return 1; }
            if(m_sig_trend == -1) { ApplyRiskGuard(0.0, barNum); return 2; }
         }
         return 0;
      }
      m_lastBarTime = barTime;

      //--- Session reset
      CheckSessionReset(barTime);

      //--- Precos
      double o  = iOpen(m_symbol, PERIOD_CURRENT, 0);
      double h  = iHigh(m_symbol, PERIOD_CURRENT, 0);
      double l  = iLow(m_symbol, PERIOD_CURRENT, 0);
      double c  = iClose(m_symbol, PERIOD_CURRENT, 0);
      double c1 = iClose(m_symbol, PERIOD_CURRENT, 1);
      double tv = (double)iTickVolume(m_symbol, PERIOD_CURRENT, 0);

      double atrVal  = CalcATR(InpTA_ATRPeriod, 0);
      double atrVal1 = CalcATR(InpTA_ATRPeriod, 1);
      if(atrVal <= 0) atrVal = 0.0001;
      double cATR    = atrVal;
      if(cATR == 0) cATR = 0.0001;

      double cRSI    = CalcRSI(0);
      double cADX    = CalcADX(0);

      double tr = MathMax(h - l, MathMax(MathAbs(h - c1), MathAbs(l - c1)));

      //--- Price source
      double src = PriceSource(InpTA_PriceSource, o, h, l, c);

      //--- Plot SuperTrend
      int pLen  = (int)(InpTA_LockATRBands ? InpTA_ATRPeriod : Clamp(m_atrLen, 5, 100));
      double pMult = InpTA_LockATRBands ? InpTA_Multiplier : Clamp(m_mult, 0.5, 5.0);
      ST_Step(src, pMult, pLen, InpTA_UseATR, c1, c, tr, m_plot_up, m_plot_dn, m_plot_trend, m_plot_rma);

      //--- Signal SuperTrend
      int sLen  = IClamp((int)m_atrLen, 5, 100);
      double sMult = Clamp(m_mult, 0.5, 5.0);
      ST_Step(src, sMult, sLen, InpTA_UseATR, c1, c, tr, m_sig_up, m_sig_dn, m_sig_trend, m_sig_rma);

      //--- Regime detection (a cada 7 barras)
      if(barNum - m_lastRegBar >= 7)
      {
         m_regime = DetectRegime(0, totalBars, cADX);
         m_lastRegBar = barNum;
      }

      //--- Volatilidade normalizada
      double atr14 = CalcATR(14, 0);
      double atr14Avg = 0; int ac = 0;
      for(int vi = 0; vi < MathMin(100, totalBars); vi++)
      {
         double a = CalcATR(14, vi);
         if(a > 0) { atr14Avg += a; ac++; }
      }
      if(ac > 0) atr14Avg /= ac;
      double volNorm = (atr14Avg > 0) ? Clamp((atr14 / atr14Avg) / 2.5, 0, 1) : 0.5;

      //--- Rolling queues
      QPush(m_highs, h, 500);
      QPush(m_lows, l, 500);
      QPush(m_rsis, cRSI, 500);
      if(tv > 0) QPush(m_vols, tv, 500);

      //--- Pressure sensor
      if(InpTA_EnableTickPressure)
      {
         if(c > c1) m_bullFlow += tv; else if(c < c1) m_bearFlow += tv;
         double tf = m_bullFlow + m_bearFlow;
         m_pressure = tf > 0 ? (m_bullFlow - m_bearFlow) / tf : 0;
         QPush(m_pressureLog, m_pressure, 20);
      }

      //==================================================================
      // BACKGROUND TEST MATRIX + OPTIMIZER
      //==================================================================
      if(InpTA_EnableAdaptive && InpTA_UseFaintCycle && barNum > 5)
      {
         double loHold = l, hiHold = h;
         for(int hb = 1; hb < 5 && hb < totalBars; hb++)
         {
            double hl = iLow(m_symbol, PERIOD_CURRENT, hb);
            double hh = iHigh(m_symbol, PERIOD_CURRENT, hb);
            if(hl < loHold) loHold = hl;
            if(hh > hiHold) hiHold = hh;
         }

         //--- Close matured probes
         double lUsd, lAtr, lMae, sUsd, sAtr, sMae;
         bool lClosed = CloseMatured(m_probesL, +1, loHold, hiHold, c, barNum, lUsd, lAtr, lMae);
         bool sClosed = CloseMatured(m_probesS, -1, loHold, hiHold, c, barNum, sUsd, sAtr, sMae);

         if(lClosed && lUsd != EMPTY_VALUE)
         {
            m_tot_L++; if(lUsd > 0) { m_win_L++; m_consecLoss_L = 0; } else m_consecLoss_L++;
            if(lUsd >= 0) m_gp_L += lUsd; else m_gl_L += (-lUsd);
            double cap = Clamp(lUsd, -InpTA_TradeSizeUSD, InpTA_TradeSizeUSD);
            QPush(m_rollUSD_L, cap, InpTA_RollN);
            QPush(m_rollATR_L, lAtr, InpTA_RollN);
            if(InpTA_UseSTM) DecayPush(lAtr, lMae, m_regime, volNorm, +1);
            if(InpTA_EnableBinLearning)
            {
               double gm, gl, gs, gt, gb, gc;
               GridRecommend(Bucket(m_regime, InpTA_MapGridX), Bucket(volNorm, InpTA_MapGridY), gm, gl, gs, gt, gb, gc);
               SBatchSampleTA bs; bs.atr_ret = lAtr; bs.mae_atr = lMae; bs.pnl_usd = lUsd; bs.conf = gc;
               QPushB(m_batchL, bs, 200);
            }
         }
         if(sClosed && sUsd != EMPTY_VALUE)
         {
            m_tot_S++; if(sUsd > 0) { m_win_S++; m_consecLoss_S = 0; } else m_consecLoss_S++;
            if(sUsd >= 0) m_gp_S += sUsd; else m_gl_S += (-sUsd);
            double cap = Clamp(sUsd, -InpTA_TradeSizeUSD, InpTA_TradeSizeUSD);
            QPush(m_rollUSD_S, cap, InpTA_RollN);
            QPush(m_rollATR_S, sAtr, InpTA_RollN);
            if(InpTA_UseSTM) DecayPush(sAtr, sMae, m_regime, volNorm, -1);
            if(InpTA_EnableBinLearning)
            {
               double gm, gl, gs, gt, gb, gc;
               GridRecommend(Bucket(m_regime, InpTA_MapGridX), Bucket(volNorm, InpTA_MapGridY), gm, gl, gs, gt, gb, gc);
               SBatchSampleTA bs; bs.atr_ret = sAtr; bs.mae_atr = sMae; bs.pnl_usd = sUsd; bs.conf = gc;
               QPushB(m_batchS, bs, 200);
            }
         }

         //--- Decay
         if(InpTA_UseSTM)
         {
            DecayStep();
            if(barNum % InpTA_STMConsolidateEvery == 0 && ArraySize(m_decay) > 0 && InpTA_UseCognitiveMap)
            {
               double dSD = DecayTailFeedback();
               int posIdx = -1, negIdx = -1;
               double posMag = -1, negMag = -1;
               for(int di = 0; di < ArraySize(m_decay); di++)
               {
                  double mag = MathAbs(m_decay[di].atr_ret) * m_decay[di].energy;
                  if(m_decay[di].atr_ret >= 0 && mag > posMag) { posMag = mag; posIdx = di; }
                  if(m_decay[di].atr_ret < 0 && mag > negMag) { negMag = mag; negIdx = di; }
               }
               if(posIdx >= 0) GridUpdate(Bucket(m_decay[posIdx].regime, InpTA_MapGridX), Bucket(m_decay[posIdx].vol_norm, InpTA_MapGridY), m_decay[posIdx].atr_ret, 0,0,dSD,0,0);
               if(negIdx >= 0) GridUpdate(Bucket(m_decay[negIdx].regime, InpTA_MapGridX), Bucket(m_decay[negIdx].vol_norm, InpTA_MapGridY), m_decay[negIdx].atr_ret, 0,0,dSD,0,0);
            }
         }

         //--- Open new probes
         if(CountActive(m_probesL) < 5) OpenProbe(m_probesL, +1, o, cATR, barNum);
         if(CountActive(m_probesS) < 5) OpenProbe(m_probesS, -1, o, cATR, barNum);

         //--- Optimizer
         int lc = ArraySize(m_rollATR_L), sc = ArraySize(m_rollATR_S);
         if((lc >= 5 || sc >= 5) && (m_lastParamBar < 0 || barNum - m_lastParamBar >= InpTA_ParamUpdateEvery))
         {
            double wrL = QWinRate(m_rollUSD_L), auL = QAvgFull(m_rollUSD_L);
            double wrS = QWinRate(m_rollUSD_S), auS = QAvgFull(m_rollUSD_S);
            double aaL = QAvgFull(m_rollATR_L), aaS = QAvgFull(m_rollATR_S);
            double soL = QSortino(m_rollATR_L), soS = QSortino(m_rollATR_S);
            m_sharpe_L  = QSharpe(m_rollATR_L); m_sortino_L = QSortino(m_rollATR_L);
            m_sharpe_S  = QSharpe(m_rollATR_S); m_sortino_S = QSortino(m_rollATR_S);
            double pfL  = m_gl_L > 0 ? m_gp_L / m_gl_L : (m_gp_L > 0 ? 9.99 : 0.0);
            double pfS  = m_gl_S > 0 ? m_gp_S / m_gl_S : (m_gp_S > 0 ? 9.99 : 0.0);
            double awL  = m_win_L > 0 ? m_gp_L / m_win_L : 0;
            double alL  = (m_tot_L - m_win_L) > 0 ? m_gl_L / (m_tot_L - m_win_L) : 0;
            double awS  = m_win_S > 0 ? m_gp_S / m_win_S : 0;
            double alS  = (m_tot_S - m_win_S) > 0 ? m_gl_S / (m_tot_S - m_win_S) : 0;

            double dML,dLL,dSL,dTL,dBL,dMS,dLS,dSS,dTS,dBS;
            LearnProposals(wrL,auL,aaL,soL,0,pfL,awL,alL,lc, m_mult,m_atrLen,m_sharpe_L,(int)m_consecLoss_L, dML,dLL,dSL,dTL,dBL);
            LearnProposals(wrS,auS,aaS,soS,0,pfS,awS,alS,sc, m_mult,m_atrLen,m_sharpe_S,(int)m_consecLoss_S, dMS,dLS,dSS,dTS,dBS);

            double netM  = (lc > 0 ? dML : 0) + (sc > 0 ? dMS : 0);
            double netL  = (lc > 0 ? dLL : 0) + (sc > 0 ? dLS : 0);
            double netS  = (lc > 0 ? dSL : 0) + (sc > 0 ? dSS : 0);
            double netT  = (lc > 0 ? dTL : 0) + (sc > 0 ? dTS : 0);
            double netB  = (lc > 0 ? dBL : 0) + (sc > 0 ? dBS : 0);

            int ix = Bucket(m_regime, InpTA_MapGridX), iy = Bucket(volNorm, InpTA_MapGridY);
            double gm, gl, gs, gt, gb, gc;
            GridRecommend(ix, iy, gm, gl, gs, gt, gb, gc);
            double wg = Clamp(gc, 0, InpTA_MapWeightMax);

            double tMult_MG = InpTA_Multiplier * (1 + gm) * wg + m_mult * (1 + netM) * (1 - wg);
            double tLen_MG  = (double)InpTA_ATRPeriod + gl * wg + (m_atrLen + netL) * (1 - wg);
            double tStop_MG = InpTA_ATRPeriod * (1 + gs) * wg + m_stopMult * (1 + netS) * (1 - wg);
            double tTP_MG   = 2.0 * (1 + gt) * wg + m_tpMult * (1 + netT) * (1 - wg);
            double tBrk_MG  = 0.20 * (1 + gb) * wg + m_brkBuf * (1 + netB) * (1 - wg);

            //--- Micro-batch
            int N_b, str_b; double Wmin_b, wb2, cM, cL, cS2, cT2, cB2, dbM, dbL, aE;
            MasterParams(InpTA_DialK, N_b, str_b, Wmin_b, wb2, cM, cL, cS2, cT2, cB2, dbM, dbL, aE);
            if(InpTA_EnableBinLearning)
            {
               double mu2;
               m_firedL = BatchFire(m_batchL, N_b, str_b, Wmin_b, cM, cL, cS2, cT2, cB2, m_dMultBL, m_dLenBL, m_dStopBL, m_dTPBL, m_dBrkBL, mu2); m_muBL = mu2;
               m_firedS = BatchFire(m_batchS, N_b, str_b, Wmin_b, cM, cL, cS2, cT2, cB2, m_dMultBS, m_dLenBS, m_dStopBS, m_dTPBS, m_dBrkBS, mu2); m_muBS = mu2;
            }
            double wb3  = (m_firedL || m_firedS) ? wb2 : 0.0;
            double wL3  = (m_firedL && (!m_firedS || MathAbs(m_muBL) >= MathAbs(m_muBS))) ? 0.7 : (m_firedL && m_firedS ? 0.3 : (m_firedL ? 1.0 : 0.0));
            double wS3  = (m_firedS && (!m_firedL || MathAbs(m_muBS) > MathAbs(m_muBL))) ? 0.7 : (m_firedL && m_firedS ? 0.3 : (m_firedS ? 1.0 : 0.0));
            double tMult_b = m_mult * (1 + wL3 * m_dMultBL + wS3 * m_dMultBS);
            double tLen_b  = m_atrLen + (wL3 * m_dLenBL + wS3 * m_dLenBS);
            double tStop_b = m_stopMult * (1 + wL3 * m_dStopBL + wS3 * m_dStopBS);
            double tTP_b   = m_tpMult * (1 + wL3 * m_dTPBL + wS3 * m_dTPBS);
            double tBrk_b  = m_brkBuf * (1 + wL3 * m_dBrkBL + wS3 * m_dBrkBS);

            double tMf = tMult_MG * (1 - wb3) + tMult_b * wb3;
            double tLf = tLen_MG  * (1 - wb3) + tLen_b  * wb3;
            double tSf = tStop_MG * (1 - wb3) + tStop_b * wb3;
            double tTf = tTP_MG   * (1 - wb3) + tTP_b   * wb3;
            double tBf = tBrk_MG  * (1 - wb3) + tBrk_b  * wb3;

            if(MathAbs(tMf - m_mult) > dbM || MathAbs(tLf - m_atrLen) > dbL)
            {
               m_mult     += aE * (Clamp(Quantize(tMf, InpTA_QuantStepMult), 0.5, 5.0) - m_mult);
               m_atrLen   += aE * (Clamp(MathRound(tLf), 5, 100) - m_atrLen);
               m_stopMult += aE * (Clamp(Quantize(tSf, InpTA_QuantStepStop), 0.3, 3.0) - m_stopMult);
               m_tpMult   += aE * (Clamp(Quantize(tTf, InpTA_QuantStepTP), 0.5, 5.0) - m_tpMult);
               m_brkBuf   += aE * (Clamp(Quantize(tBf, InpTA_QuantStepBrk), 0.0, 3.0) - m_brkBuf);
               m_lastParamBar = barNum;
            }

            if(InpTA_RevertEvery > 0 && barNum % InpTA_RevertEvery == 0)
            {
               m_mult   += InpTA_RevertStep * (InpTA_Multiplier - m_mult);
               m_atrLen += InpTA_RevertStep * ((double)InpTA_ATRPeriod - m_atrLen);
            }

            if(InpTA_UseCognitiveMap)
            {
               if(lClosed && lUsd != EMPTY_VALUE) GridUpdate(ix, iy, lAtr, netM, netL, netS, netT, netB);
               if(sClosed && sUsd != EMPTY_VALUE) GridUpdate(ix, iy, sAtr, netM, netL, netS, netT, netB);
            }
         }
      }

      //==================================================================
      // SIGNAL GENERATION
      //==================================================================
      int szH = ArraySize(m_highs), szL = ArraySize(m_lows);
      int sens = IClamp((int)m_sensitivity, 2, MathMin(100, szH - 1));
      int lb   = MathMax(1, (int)(m_sensitivity / 10.0));

      uchar result = 0;

      if(szH < sens + lb) { m_sig_trend_prev = m_sig_trend; return 0; }

      double hiNow  = QMax(m_highs, sens);
      double hiPrev = QMax(m_highs, sens + lb);
      double loNow  = QMin(m_lows, sens);
      double loPrev = QMin(m_lows, sens + lb);

      bool isNewHigh = (hiNow != hiPrev && hiNow > hiPrev);
      bool isNewLow  = (loNow != loPrev && loNow < loPrev);

      if(InpTA_MajorLevelsOnly)
      {
         double atrLvl = cATR * InpTA_MajorLevelDepth;
         isNewHigh = isNewHigh && (h - QMin(m_lows, sens)) > atrLvl;
         isNewLow  = isNewLow  && (QMax(m_highs, sens) - l) > atrLvl;
      }

      //--- RSI filter
      bool rsiCold = true, rsiHot = true;
      if(InpTA_EnableRSI)
      {
         int szR = ArraySize(m_rsis);
         bool fc = false, fh = false;
         for(int ri = szR - 1; ri >= MathMax(0, szR - InpTA_RSILookbackBot); ri--)
            if(m_rsis[ri] < InpTA_RSIBot) { fc = true; break; }
         for(int ri = szR - 1; ri >= MathMax(0, szR - InpTA_RSILookbackTop); ri--)
            if(m_rsis[ri] > InpTA_RSITop) { fh = true; break; }
         rsiCold = fc; rsiHot = fh;
      }

      //--- Volume filter
      bool volSurge = true;
      if(InpTA_RequireVolSpike)
      {
         int szV = ArraySize(m_vols);
         double vAvg = szV > 0 ? QAvg(m_vols, InpTA_VolLookback) : 1;
         volSurge = tv > InpTA_VolMultiplier * vAvg;
      }

      bool buyF  = rsiCold && volSurge;
      bool sellF = rsiHot  && volSurge;
      bool canSig = (barNum - m_lastSigBar) >= InpTA_MinBarsBetweenSigs && CanTrade(barNum);

      bool doBuy = false, doSell = false;

      //--- Reversal mode
      if(InpTA_SignalMode == 0 && canSig)
      {
         m_topFlagPrev = m_topFlag;
         m_botFlagPrev = m_botFlag;
         if(m_sig_trend == -1)                        m_topFlag = 0;
         else if(isNewHigh && m_sig_trend == 1)       m_topFlag = 1;
         if(m_sig_trend == 1)                         m_botFlag = 0;
         else if(isNewLow && m_sig_trend == -1)       m_botFlag = 1;

         bool rSell = (m_topFlagPrev == 1 && m_topFlag == 0) || (!InpTA_RequireNewExtreme && m_sig_trend_prev == 1 && m_sig_trend == -1);
         bool rBuy  = (m_botFlagPrev == 1 && m_botFlag == 0) || (!InpTA_RequireNewExtreme && m_sig_trend_prev == -1 && m_sig_trend == 1);

         if(rSell && sellF) doSell = true;
         else if(rBuy && buyF) doBuy = true;
      }

      //--- Breakout mode
      if(InpTA_SignalMode == 1 && canSig)
      {
         if(isNewHigh && m_sig_trend == 1 && sellF) doSell = true;
         if(isNewLow && m_sig_trend == -1 && buyF)  doBuy  = true;
      }

      //--- Atualiza flags
      if(doSell)
      {
         m_lastSigBar = barNum;
         ApplyRiskGuard(0.0, barNum);
         m_sig_trend_prev = m_sig_trend;
         result = 2;
      }
      else if(doBuy)
      {
         m_lastSigBar = barNum;
         ApplyRiskGuard(0.0, barNum);
         m_sig_trend_prev = m_sig_trend;
         result = 1;
      }

      m_sig_trend_prev = m_sig_trend;
      return result;
   }

   //+------------------------------------------------------------------+
   //| ManagePosition — trailing (placeholder)                         |
   //+------------------------------------------------------------------+
   void ManagePosition()
   {
      // Placeholder: futuro trailing adaptativo
   }

   //+------------------------------------------------------------------+
   //| Getters para acesso externo                                     |
   //+------------------------------------------------------------------+
   double GetMult()      const { return m_mult; }
   double GetATRLen()    const { return m_atrLen; }
   double GetRegime()    const { return m_regime; }
   double GetPressure()  const { return m_pressure; }
   double GetSharpeL()   const { return m_sharpe_L; }
   double GetSharpeS()   const { return m_sharpe_S; }
   int    GetTotTradesL() const { return m_tot_L; }
   int    GetTotTradesS() const { return m_tot_S; }
};
