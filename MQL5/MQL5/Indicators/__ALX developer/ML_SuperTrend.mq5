//+------------------------------------------------------------------+
//|  Machine Learning SuperTrend [Hammad Dilber] — MQL5 Indicator   |
//|  Author  : Hammad Dilber                                         |
//|  Version : v10.02 — Real Signal Win Rate + Dashboard Fixes      |
//+------------------------------------------------------------------+
//  CHANGELOG v10.02 (Hammad Dilber):
//  v10.02 — Win Rate now tracks real signal outcomes (5-bar exit)
//  v10.02 — Trades row shows actual arrow signals, not simulations
//  v10.01 — Dashboard was reading unpopulated signal counters
//  v10.00 — Session reset clears consecutive loss streak
//  v10.00 — Sharpe/Sortino computed from rolling ATR returns
//  v10.00 — Risk Guard applied correctly at signal generation
//  v10.00 — Full multi-column table dashboard
//+------------------------------------------------------------------+
#property copyright "Hammad Dilber — ML SuperTrend v10.02"
#property version   "10.02"
#property indicator_chart_window
#property indicator_buffers 5
#property indicator_plots   5

#property indicator_label1 "ST Bull"
#property indicator_type1  DRAW_LINE
#property indicator_color1 clrDodgerBlue
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2

#property indicator_label2 "ST Bear"
#property indicator_type2  DRAW_LINE
#property indicator_color2 clrOrangeRed
#property indicator_style2 STYLE_SOLID
#property indicator_width2 2

#property indicator_label3 "Buy"
#property indicator_type3  DRAW_ARROW
#property indicator_color3 clrLime
#property indicator_width3 3

#property indicator_label4 "Sell"
#property indicator_type4  DRAW_ARROW
#property indicator_color4 clrRed
#property indicator_width4 3

// Signal Confidence buffer — data-only (DRAW_NONE), kept in chart window as hidden buffer for EA use
#property indicator_label5 "Confidence"
#property indicator_type5  DRAW_NONE   // data only, no plot (use in EA)

double BullBuf[], BearBuf[], BuyBuf[], SellBuf[], ConfBuf[];

//==========================================================================
// ENUM: Signal Mode
//==========================================================================
enum ENUM_SIGNAL_MODE
{
   SignalReversal  = 0,  // Reversal
   SignalBreakout  = 1   // Breakout
};

//==========================================================================
// ENUM: Price Source
//==========================================================================
enum ENUM_SOURCE_TYPE
{
   SRC_OPEN   = 0, // open
   SRC_HIGH   = 1, // high
   SRC_LOW    = 2, // low
   SRC_CLOSE  = 3, // close
   SRC_HL2    = 4, // hl2
   SRC_HLC3   = 5, // hlc3
   SRC_OHLC4  = 6, // ohlc4
   SRC_HLCC4  = 7  // hlcc4
};

//==========================================================================
// GROUP 1 — SIGNAL MODE
//==========================================================================
input ENUM_SIGNAL_MODE InpSignalMode         = SignalReversal; // Signal Type
input bool   InpRequireNewExtreme            = false;          // Require Fresh Pivot
input int    InpMinBarsBetweenSigs           = 10;             // Signal Spacing

//==========================================================================
// GROUP 2 — VOLATILITY ENVELOPE
//==========================================================================
input int    InpSensitivity                  = 30;    // Lookback Window
input int    InpATRPeriod                    = 24;    // Smoothing Period
input double InpMultiplier                   = 1.4;   // Band Width
input ENUM_SOURCE_TYPE InpSourceType         = SRC_HLCC4; // Price Basis
input bool   InpUseATR                       = true;  // True Range Mode (RMA=true, EMA=false)

//==========================================================================
// GROUP 3 — MOMENTUM FILTER
//==========================================================================
input bool   InpEnableRSI                    = true;  // RSI Active
input int    InpRSILen                       = 14;    // RSI Length
input int    InpRSILookbackTop               = 50;    // Hot Zone Memory
input int    InpRSILookbackBot               = 50;    // Cold Zone Memory

//==========================================================================
// GROUP 4 — FLOW ANALYSIS
//==========================================================================
input int    InpVolLookback                  = 3;     // Sample Depth
input double InpVolMultiplier                = 1.2;   // Surge Threshold
input bool   InpRequireVolSpike              = false; // Require Surge

//==========================================================================
// GROUP 5 — SIGNAL QUALITY
//==========================================================================
input bool   InpMajorLevelsOnly              = false; // Key Levels Only
input double InpMajorLevelDepth              = 4.5;   // Key Level Depth (xATR)

//==========================================================================
// GROUP 6 — MASTER DIAL
//==========================================================================
input int    InpDialK                        = 10;    // Reactivity 1-20
input bool   InpEnableBinLearning            = true;  // Micro-Batch Processing
input bool   InpEnableTickPressure           = true;  // Live Pressure Sensor

//==========================================================================
// GROUP 7 — AUTO-TUNE ENGINE
//==========================================================================
input bool   InpEnableAdaptive               = true;  // Enable Auto-Tune
input bool   InpUseFaintCycle                = true;  // Use Background Test Matrix
input bool   InpLockATRBands                 = true;  // Lock Envelope to Base

//==========================================================================
// GROUP 8 — OPTIMIZER
//==========================================================================
input bool   InpLearnEnabled                 = true;  // Optimizer Enable
input double InpLearnRate                    = 0.25;  // Step Size
input int    InpRollN                        = 30;    // History Depth
input double InpWinHi                        = 0.62;  // Win Ceiling
input double InpWinLo                        = 0.38;  // Win Floor
input bool   InpUseATRNorm                   = true;  // Normalize Returns by ATR
input double InpSmoothAlpha                  = 0.35;  // Momentum Smoothing
input int    InpParamUpdateEvery             = 3;     // Update Cooldown (bars)
input double InpDeadbandMult                 = 0.01;  // Deadband Width
input double InpDeadbandLen                  = 0.25;  // Deadband Period
input double InpQuantStepMult                = 0.05;  // Quant Step Width
input double InpQuantStepStop                = 0.02;  // Quant Step Guard
input double InpQuantStepTP                  = 0.02;  // Quant Step Target
input double InpQuantStepBrk                 = 0.01;  // Quant Step Edge
input int    InpRevertEvery                  = 200;   // Anchor Revert Interval
input double InpRevertStep                   = 0.01;  // Anchor Revert Strength
input double InpPnLCapUSD                    = 750.0; // PnL Cap per Trade

//==========================================================================
// GROUP 9 — RISK GUARD
//==========================================================================
input int    InpMaxTradesPerSession           = 20;       // Max Entries Per Session
input double InpMaxSessionLoss                = -1000.0;  // Session Loss Limit USD
input int    InpBaseCooldownBars              = 5;        // Base Pause After Loss
input int    InpMaxConsecLosses               = 3;        // Streak Limit
input bool   InpDynamicCooldown               = true;     // Scale Pause by Loss Size

//==========================================================================
// GROUP 10 — CONTEXT MEMORY (REGIME GRID)
//==========================================================================
input bool   InpUseCognitiveMap              = true;  // Enable Regime Grid
input int    InpMapGridX                     = 8;     // Regime Bins
input int    InpMapGridY                     = 8;     // Volatility Bins
input double InpMapSigma                     = 0.8;   // Neighbor Blend Radius
input int    InpMapHalfLife                  = 50;    // Decay Half-Life (trades)
input int    InpMapConfScale                 = 20;    // Confidence Ramp (trades)
input double InpMapWeightMax                 = 0.65;  // Max Grid Influence
input double InpVolMaxRatio                  = 2.5;   // Vol Ratio Ceiling

//==========================================================================
// GROUP 11 — DECAY TRACES
//==========================================================================
input bool   InpUseSTM                       = true;  // Enable Trace Buffer
input int    InpSTMSize                      = 30;    // Buffer Depth
input double InpSTMDecay                     = 0.02;  // Fade Rate per Bar
input int    InpSTMConsolidateEvery          = 200;   // Merge Interval bars
input double InpSTMMAETailThr                = 0.8;   // Adverse Move Threshold
input double InpSTMTailTightenCap            = 0.02;  // Guard Tighten Cap

//==========================================================================
// GROUP 12 — ALERTS
//==========================================================================
input bool   InpAlertPopup                   = true;  // Popup Alert on Signal
input bool   InpAlertPush                    = false; // Push Notification on Signal
input bool   InpAlertOnce                    = true;  // Alert Once per Bar

//==========================================================================
// GROUP 13 — DISPLAY
//==========================================================================
input int    InpRSITop                       = 70;    // RSI Hot Level
input int    InpRSIBot                       = 30;    // RSI Cold Level
input double InpStopMult                     = 1.00;  // Guard xATR
input double InpTPMult                       = 2.00;  // Target xATR
input double InpBreakoutBuf                  = 0.20;  // Edge Buffer xATR
input double InpTradeSizeUSD                 = 1000.0;// Sim Position USD
input bool   InpShowDashboard                = true;  // Show Info Dashboard

//==========================================================================
// STRUCTS
//==========================================================================
struct Probe
{
   double entry;
   int    bar;
   int    dir;
   bool   active;
   double atr_val;
};

struct GridCell
{
   double mean_atr_ret;
   double down_ewm;
   int    count;
   double conf;
   double d_mult;
   double d_len;
   double d_stop;
   double d_tp;
   double d_brk;
};

struct DecayTrace
{
   double atr_ret;
   double mae_atr;
   double regime;
   double vol_norm;
   double energy;
   int    dir;
};

struct BatchSample
{
   double atr_ret;
   double mae_atr;
   double pnl_usd;
   double conf;
};

//==========================================================================
// GLOBALS
//==========================================================================
int h_atr14 = INVALID_HANDLE;
int h_atr   = INVALID_HANDLE;
int h_rsi   = INVALID_HANDLE;
int h_adx   = INVALID_HANDLE;

// Adaptive params
double g_mult, g_atrLen, g_stopMult, g_tpMult, g_brkBuf, g_sensitivity;

// ST state (plot)
double g_st_up=0, g_st_dn=0; int g_st_trend=1; double g_st_rma=0;
// ST state (signal engine - adaptive)
double g_sig_up=0, g_sig_dn=0; int g_sig_trend=1; double g_sig_rma=0;
int    g_sig_trend_prev=1;

// Signal flags
int g_topFlag=0, g_topFlagPrev=0;
int g_botFlag=0, g_botFlagPrev=0;
int g_lastSigBar=-9999;

// Regime
double g_regime=0.5;
int    g_lastRegBar=-99;

// Rolling queues
double g_highs[], g_lows[], g_rsis[], g_vols[];

// Test matrix
Probe g_probesL[], g_probesS[];

// Rolling stats
double g_rollUSD_L[], g_rollATR_L[], g_rollRet_L[];
double g_rollUSD_S[], g_rollATR_S[], g_rollRet_S[];
double g_gp_L=0,g_gl_L=0,g_gp_S=0,g_gl_S=0;
int    g_tot_L=0,g_win_L=0,g_tot_S=0,g_win_S=0;  // probe/simulation counters (optimizer use)
double g_consecLoss_L=0, g_consecLoss_S=0;
double g_sharpe_L=0, g_sortino_L=0;
double g_sharpe_S=0, g_sortino_S=0;

// Actual signal counters — populated by direct 5-bar exit comparison on historical bars
// These track only real Buy/Sell arrow signals, not background simulation probes
int    g_sig_tot_L=0, g_sig_win_L=0;   // actual Long signals fired
int    g_sig_tot_S=0, g_sig_win_S=0;   // actual Short signals fired

// Regime grid
GridCell g_grid[];

// Decay traces
DecayTrace g_decay[];

// Micro-batch
BatchSample g_batchL[], g_batchS[];
bool   g_firedL=false, g_firedS=false;
double g_muBL=0, g_muBS=0;
double g_dMultBL=0,g_dLenBL=0,g_dStopBL=0,g_dTPBL=0,g_dBrkBL=0;
double g_dMultBS=0,g_dLenBS=0,g_dStopBS=0,g_dTPBS=0,g_dBrkBS=0;

// Optimizer state
int    g_lastParamBar=-1;

// Risk guard
int    g_cooldownUntil=0;
int    g_tradesSession=0;
double g_sessionPnL=0;
int    g_consecLosses=0;

// Pressure sensor
double g_pressure=0, g_bullFlow=0, g_bearFlow=0;
double g_pressureLog[];

// Alert tracking — prevents duplicate alerts on same bar
int    g_lastAlertBar = -9999;

// Session reset tracking — stores last reset day
datetime g_lastSessionDay = 0;

// Dashboard label name
string DASH_OBJ = "MLST_Dashboard";

//==========================================================================
// UTILITIES
//==========================================================================
double Clamp(double v,double lo,double hi){return MathMax(lo,MathMin(hi,v));}
double Quantize(double x,double step){return step==0?x:MathRound(x/step)*step;}

void QPush(double &arr[],double val,int cap)
{
   int sz=ArraySize(arr);
   if(sz>=cap){for(int i=0;i<sz-1;i++)arr[i]=arr[i+1];arr[sz-1]=val;}
   else{ArrayResize(arr,sz+1);arr[sz]=val;}
}
void QPushB(BatchSample &arr[], BatchSample &val, int cap)
{
   int sz=ArraySize(arr);
   if(sz>=cap){for(int i=0;i<sz-1;i++)arr[i]=arr[i+1];arr[sz-1]=val;}
   else{ArrayResize(arr,sz+1);arr[sz]=val;}
}

double QAvg(double &arr[],int n)
{
   int sz=ArraySize(arr); if(sz==0||n<=0)return 0;
   double s=0;int c=0;
   for(int i=MathMax(0,sz-n);i<sz;i++){s+=arr[i];c++;}
   return c>0?s/c:0;
}
double QMax(double &arr[],int n)
{
   int sz=ArraySize(arr);if(sz==0||n<=0)return -1e18;
   double m=arr[MathMax(0,sz-n)];
   for(int i=MathMax(0,sz-n)+1;i<sz;i++)if(arr[i]>m)m=arr[i];
   return m;
}
double QMin(double &arr[],int n)
{
   int sz=ArraySize(arr);if(sz==0||n<=0)return 1e18;
   double m=arr[MathMax(0,sz-n)];
   for(int i=MathMax(0,sz-n)+1;i<sz;i++)if(arr[i]<m)m=arr[i];
   return m;
}
double QAvgFull(double &arr[])
{
   int sz=ArraySize(arr);if(sz==0)return 0;
   double s=0;for(int i=0;i<sz;i++)s+=arr[i];return s/sz;
}
double QWinRate(double &arr[])
{
   int sz=ArraySize(arr);if(sz==0)return 0.5;
   double w=0;for(int i=0;i<sz;i++)if(arr[i]>0)w++;return w/sz;
}
double QSortino(double &arr[])
{
   int sz=ArraySize(arr);if(sz==0)return 0;
   double mean=QAvgFull(arr),ddSum=0;int ddCnt=0;
   for(int i=0;i<sz;i++)if(arr[i]<0){ddSum+=arr[i]*arr[i];ddCnt++;}
   if(ddCnt==0)return 0;
   double dd=MathSqrt(ddSum/ddCnt);
   return dd>0?mean/dd:0;
}

// Compute Sharpe ratio from rolling return array
double QSharpe(double &arr[])
{
   int sz=ArraySize(arr);if(sz<2)return 0;
   double mean=QAvgFull(arr);
   double ssq=0;
   for(int i=0;i<sz;i++)ssq+=(arr[i]-mean)*(arr[i]-mean);
   double sd=MathSqrt(ssq/sz);
   return sd>0?mean/sd:0;
}

// Update Sharpe and Sortino from rolling ATR returns
void UpdateSharpeSortino()
{
   g_sharpe_L  = QSharpe(g_rollATR_L);
   g_sortino_L = QSortino(g_rollATR_L);
   g_sharpe_S  = QSharpe(g_rollATR_S);
   g_sortino_S = QSortino(g_rollATR_S);
}

//==========================================================================
// SUPERTREND UPDATE
//==========================================================================
void ST_Step(double src,double mult,int period,bool useRMA,
             double prevClose,double curClose,double tr,
             double &up,double &dn,int &trend,double &rmaVal)
{
   double alpha=1.0/MathMax(1,period);
   if(useRMA) rmaVal=(rmaVal==0)?tr:rmaVal+alpha*(tr-rmaVal);
   else       rmaVal=(rmaVal==0)?tr:(2.0/(period+1))*tr+(1.0-2.0/(period+1))*rmaVal;

   double band=mult*rmaVal;
   double newUp=src-band, newDn=src+band;
   if(up!=0) newUp=(prevClose>up)?MathMax(newUp,up):newUp;
   if(dn!=0) newDn=(prevClose<dn)?MathMin(newDn,dn):newDn;
   up=newUp; dn=newDn;
   if(trend==-1&&curClose>dn)trend=1;
   else if(trend==1&&curClose<up)trend=-1;
}

//==========================================================================
// HURST EXPONENT
//==========================================================================
double CalcHurst(const double &close[],int idx,int total,int len)
{
   int L=MathMax(len,16);
   if(idx+L>=total)return 0.5;
   double mean=0;
   for(int i=0;i<L;i++)mean+=close[idx+i];
   mean/=L;
   double cum=0,maxC=0,minC=0,ssq=0;
   for(int i=0;i<L;i++)
   {
      double dev=close[idx+i]-mean;
      cum+=dev;
      if(cum>maxC)maxC=cum;
      if(cum<minC)minC=cum;
      ssq+=dev*dev;
   }
   double R=maxC-minC;
   double S=MathSqrt(ssq/L);
   if(S==0||L<=1)return 0.5;
   return Clamp(MathLog(R/S)/MathLog(L),0.0,1.0);
}

//==========================================================================
// ENTROPY
//==========================================================================
double CalcEntropy(const double &close[],int idx,int total,int len)
{
   int L=MathMax(len,16);
   if(idx+L>=total)return 0.0;
   double ups=0,dns=0;
   for(int i=1;i<=L;i++)
   {
      double d=close[idx+i-1]-close[idx+i];
      if(d>0)ups++;else if(d<0)dns++;
   }
   double tot=ups+dns;if(tot==0)return 0;
   double p1=ups/tot,p2=dns/tot,H=0;
   if(p1>0)H-=p1*MathLog(p1);
   if(p2>0)H-=p2*MathLog(p2);
   return Clamp(H/MathLog(2.0),0.0,1.0);
}

//==========================================================================
// REGIME DETECTION (Hurst + Entropy + ADX)
//==========================================================================
double DetectRegime(const double &close[],int idx,int total,double adxVal)
{
   double H=CalcHurst(close,idx,total,64);
   double Ent=CalcEntropy(close,idx,total,64);
   double trend_str=Clamp(adxVal/50.0,0,1);
   return Clamp(0.35*(1-Ent)+0.35*Clamp((H-0.5)*2,0,1)+0.30*trend_str,0.0,1.0);
}

//==========================================================================
// GRID FUNCTIONS
//==========================================================================
int GridIdx(int ix,int iy){return ix*InpMapGridY+iy;}
double Gauss(int dx,int dy,double s){return MathExp(-(dx*dx+dy*dy)/(2*s*s));}
int Bucket(double x,int bins){return(int)Clamp((int)MathFloor(x*bins),0,bins-1);}

void GridUpdate(int ix,int iy,double atr_ret,
                double dM,double dL,double dS,double dT,double dB)
{
   int idx=GridIdx(ix,iy);
   if(idx<0||idx>=ArraySize(g_grid))return;
   double alpha=1.0-MathExp(-MathLog(2.0)/MathMax(1,InpMapHalfLife));
   GridCell c=g_grid[idx];
   c.mean_atr_ret=c.mean_atr_ret*(1-alpha)+atr_ret*alpha;
   double dn2=atr_ret<0?atr_ret*atr_ret:0.0;
   c.down_ewm=c.down_ewm*(1-alpha)+dn2*alpha;
   c.count++;
   c.conf=1.0-MathExp(-(double)c.count/MathMax(1,InpMapConfScale));
   c.d_mult=c.d_mult*(1-alpha)+dM*alpha;
   c.d_len =c.d_len *(1-alpha)+dL*alpha;
   c.d_stop=c.d_stop*(1-alpha)+dS*alpha;
   c.d_tp  =c.d_tp  *(1-alpha)+dT*alpha;
   c.d_brk =c.d_brk *(1-alpha)+dB*alpha;
   g_grid[idx]=c;
}

void GridRecommend(int ix,int iy,
                   double &m,double &l,double &s,double &t,double &b,double &confOut)
{
   double wsum=0,wconf=0;
   m=0;l=0;s=0;t=0;b=0;confOut=0;
   for(int dx=-1;dx<=1;dx++)for(int dy=-1;dy<=1;dy++)
   {
      int nx=(int)Clamp(ix+dx,0,InpMapGridX-1);
      int ny=(int)Clamp(iy+dy,0,InpMapGridY-1);
      int idx2=GridIdx(nx,ny);
      if(idx2<0||idx2>=ArraySize(g_grid))continue;
      GridCell c=g_grid[idx2];
      if(c.count==0)continue;
      double w=Gauss(dx,dy,InpMapSigma);
      wsum+=w; double cf=c.conf; wconf+=w*cf;
      m+=w*cf*c.d_mult; l+=w*cf*c.d_len; s+=w*cf*c.d_stop;
      t+=w*cf*c.d_tp;   b+=w*cf*c.d_brk;
   }
   if(wsum==0)return;
   double den=wconf==0?wsum:wconf;
   m/=den;l/=den;s/=den;t/=den;b/=den;
   confOut=Clamp(wconf/wsum,0.0,1.0);
}

//==========================================================================
// DECAY TRACES
//==========================================================================
void DecayPush(double atr_ret,double mae_atr,double regime,double vol,int dir)
{
   int sz=ArraySize(g_decay);
   ArrayResize(g_decay,sz+1);
   g_decay[sz].atr_ret=atr_ret; g_decay[sz].mae_atr=mae_atr;
   g_decay[sz].regime=regime;   g_decay[sz].vol_norm=vol;
   g_decay[sz].energy=1.0;      g_decay[sz].dir=dir;
   while(ArraySize(g_decay)>InpSTMSize)
   { for(int i=0;i<ArraySize(g_decay)-1;i++)g_decay[i]=g_decay[i+1];
     ArrayResize(g_decay,ArraySize(g_decay)-1); }
}
void DecayStep()
{
   for(int i=ArraySize(g_decay)-1;i>=0;i--)
   {
      g_decay[i].energy*=(1.0-InpSTMDecay);
      if(g_decay[i].energy<0.05)
      {
         for(int j=i;j<ArraySize(g_decay)-1;j++)g_decay[j]=g_decay[j+1];
         ArrayResize(g_decay,ArraySize(g_decay)-1);
      }
   }
}
double DecayTailFeedback()
{
   int n=ArraySize(g_decay);if(n==0)return 0;
   double sumW=0,sumTail=0;
   for(int i=0;i<n;i++)
   {
      sumW+=g_decay[i].energy;
      if(g_decay[i].mae_atr>InpSTMMAETailThr)sumTail+=g_decay[i].energy;
   }
   double frac=sumW>0?sumTail/sumW:0;
   double k=Clamp((frac-0.25)/0.75,0.0,1.0);
   return -InpSTMTailTightenCap*k;
}

//==========================================================================
// MASTER DIAL
//==========================================================================
void MasterParams(int K,
   int &N,int &stride,double &Wmin,double &wBatch,
   double &cMult,double &cLen,double &cStop,double &cTP,double &cBrk,
   double &dbMult,double &dbLen,double &alpha)
{
   double k=((double)K-1.0)/19.0;
   N     =(int)Clamp((int)MathRound(20.0-16.0*k),4,20);
   stride=MathMax(1,(int)MathRound(N*(1.0-0.9*k)));
   Wmin  =MathMax(0.0,(double)N*(0.80-0.40*k));
   wBatch=0.25+0.35*k;
   cMult =0.02+0.06*k; cLen=0.5+1.5*k;
   cStop =0.01+0.04*k; cTP =0.01+0.03*k; cBrk=0.005+0.025*k;
   dbMult=MathMax(0.003,InpDeadbandMult*(1.0-0.6*k));
   dbLen =MathMax(0.10, InpDeadbandLen *(1.0-0.6*k));
   alpha =Clamp(0.25+0.40*k,0.20,0.65);
}

//==========================================================================
// MICRO-BATCH FIRE
//==========================================================================
bool BatchFire(BatchSample &bin[],int N,int stride,double Wmin,
               double cM,double cL,double cS,double cT,double cB,
               double &dM,double &dL,double &dS,double &dT,double &dBrk,double &muOut)
{
   dM=0;dL=0;dS=0;dT=0;dBrk=0;muOut=0;
   int sz=ArraySize(bin);if(sz<N)return false;
   double sumW=0,sumRet=0,wNeg=0,sumNegVar=0,sumMAE=0,gpW=0,glW=0;
   for(int i=0;i<N;i++)
   {
      double wC=Clamp(bin[i].conf,0,1);
      double wQ=1.0/(1.0+MathMax(0,bin[i].mae_atr));
      double w=wC*wQ; sumW+=w; sumRet+=w*bin[i].atr_ret;
      if(bin[i].atr_ret<0){wNeg+=w;sumNegVar+=w*(bin[i].atr_ret*bin[i].atr_ret);}
      sumMAE+=w*bin[i].mae_atr;
      if(bin[i].pnl_usd>0)gpW+=w*bin[i].pnl_usd;
      else if(bin[i].pnl_usd<0)glW+=w*(-bin[i].pnl_usd);
   }
   double mu=sumW>0?sumRet/sumW:0;
   double sr=(wNeg>0&&sumNegVar>0)?mu/MathSqrt(sumNegVar/wNeg):0;
   double pf=glW>0?gpW/glW:(gpW>0?9.99:0.0);
   double mae=sumW>0?sumMAE/sumW:0;
   double confF=Wmin>0?Clamp(sumW/Wmin,0.0,1.5):1.0;
   muOut=mu;
   bool good=(mu>0)&&(pf>1.15)&&(sr>0.8);
   bool bad =(mu<0)||(pf<0.95)||(sr<0.2);
   if(good){dM=-cM*confF;dL=-cL*confF;dS=-cS*confF;dT=+cT*0.5*confF;dBrk=-cB*confF;}
   if(bad) {dM=+cM*confF;dL=+cL*confF;dS=(mae>0.6?-cS:+0.5*cS)*confF;dT=-0.3*cT*confF;dBrk=+cB*confF;}
   for(int j=0;j<stride&&ArraySize(bin)>0;j++)
   {
      for(int k2=0;k2<ArraySize(bin)-1;k2++)bin[k2]=bin[k2+1];
      ArrayResize(bin,ArraySize(bin)-1);
   }
   return true;
}

//==========================================================================
// OPTIMIZER PROPOSALS
//==========================================================================
void LearnProposals(double winrate,double avgUsd,double avgAtr,
                    double sortino,double avgMAE,double pf,
                    double avgWin,double avgLoss,int sampleCount,
                    double curMult,double curLen,double sharpe,int consecLoss,
                    double &dMult,double &dLen,double &dStop,double &dTP,double &dBrk)
{
   dMult=0;dLen=0;dStop=0;dTP=0;dBrk=0;
   if(!InpLearnEnabled||!InpEnableAdaptive||sampleCount<=0)return;
   double conf=1.0/MathSqrt(MathMax(1.0,(double)sampleCount));
   double step=InpLearnRate*conf;
   double pb=ArraySize(g_pressureLog)>=5?QAvg(g_pressureLog,5):0;
   if(MathAbs(pb)>0.2)step*=(1+MathAbs(pb)*0.5);
   bool weak  =(winrate<InpWinLo)&&(InpUseATRNorm?avgAtr<0:avgUsd<0);
   bool strong=(winrate>InpWinHi)&&(InpUseATRNorm?avgAtr>0:avgUsd>0);
   if(weak)  {dMult+=+0.08*step;dLen+=+curLen*0.05*step;}
   if(strong){dMult+=-0.05*step;dLen+=-curLen*0.03*step;}
   if(avgMAE>0.60)dMult+=+0.02*step;
   if(sortino<0)  dMult+=+0.04*step;
   if(sortino>1.2)dMult+=-0.03*step;
   if(winrate>InpWinHi&&pf>0&&pf<1.2)dTP+=+0.02*step;
   if(winrate<InpWinLo&&avgLoss>avgWin*1.2)dStop+=-0.03*step;
   if(winrate<InpWinLo&&avgLoss<=avgWin*1.2)dStop+=+0.02*step;
   if(g_regime>=0.7&&(InpUseATRNorm?avgAtr>0:avgUsd>0))dBrk+=-0.02*step;
   if(g_regime<=0.3&&(InpUseATRNorm?avgAtr<0:avgUsd<0))dBrk+=+0.02*step;
   if(sharpe<0.5) dMult+=+0.02*step;
   if(sortino>1.5)dMult+=-0.02*step;
   if(consecLoss>=3)dStop+=+0.03*step;
}

//==========================================================================
// TEST MATRIX PROBE MANAGEMENT
//==========================================================================
void OpenProbe(Probe &book[],int dir,double entryPrice,double atrVal,int barNum)
{
   int free=-1;
   for(int i=0;i<ArraySize(book);i++)if(!book[i].active){free=i;break;}
   if(free==-1){ArrayResize(book,ArraySize(book)+1);free=ArraySize(book)-1;}
   book[free].entry=entryPrice;book[free].bar=barNum;
   book[free].dir=dir;book[free].active=true;book[free].atr_val=atrVal;
}
int CountActive(Probe &book[])
{
   int c=0;for(int i=0;i<ArraySize(book);i++)if(book[i].active)c++;return c;
}
bool CloseMatured(Probe &book[],int dir,double loHold,double hiHold,
                  double closePrice,int barNum,
                  double &usd,double &atrR,double &mae)
{
   usd=EMPTY_VALUE;atrR=0;mae=0;
   int oldest=INT_MAX,idx=-1;
   for(int i=0;i<ArraySize(book);i++)
   {
      if(!book[i].active)continue;
      if(barNum-book[i].bar>=5&&book[i].bar<oldest){oldest=book[i].bar;idx=i;}
   }
   if(idx<0)return false;
   Probe p=book[idx];
   double ret=(closePrice-p.entry)*p.dir;
   double pct=p.entry!=0?ret/p.entry:0;
   usd=pct*InpTradeSizeUSD;
   atrR=p.atr_val!=0?ret/p.atr_val:0;
   double maeP=dir==1?MathMax(0,p.entry-loHold):MathMax(0,hiHold-p.entry);
   mae=p.atr_val!=0?maeP/p.atr_val:0;
   book[idx].active=false;
   return true;
}

//==========================================================================
// RISK GUARD
//==========================================================================
bool CanTrade(int barNum)
{
   return barNum>g_cooldownUntil&&
          g_tradesSession<InpMaxTradesPerSession&&
          g_sessionPnL>InpMaxSessionLoss&&
          g_consecLosses<InpMaxConsecLosses;
}
void ApplyRiskGuard(double pnl,int barNum)
{
   g_tradesSession++;g_sessionPnL+=pnl;
   if(pnl<0)
   {
      g_consecLosses++;
      double lossMag=MathAbs(pnl);
      if(InpDynamicCooldown)
      {
         double sc=lossMag/(InpTradeSizeUSD*0.02);
         g_cooldownUntil=barNum+(int)MathMin(50,InpBaseCooldownBars*(1+sc));
      }
      else g_cooldownUntil=barNum+InpBaseCooldownBars;
   }
   else g_consecLosses=0;
}

//==========================================================================
// FULL TABLE DASHBOARD — Hammad Dilber
//==========================================================================
#define DASH_PREFIX   "MLST_"
#define CELL_W        135   // cell width (px)
#define CELL_H        19    // cell height (px)
#define BORDER_PX     0     // no gap between cells — full black background
#define DASH_X        10    // left margin
#define DASH_Y        20    // top margin

// Border / separator colours — all black
#define CLR_BORDER    C'0,0,0'
#define CLR_SEP       C'0,0,0'

void DashDeleteAll()
{
   int total=ObjectsTotal(0,0,-1);
   for(int i=total-1;i>=0;i--)
   {
      string nm=ObjectName(0,i,0,-1);
      if(StringFind(nm,DASH_PREFIX)==0)ObjectDelete(0,nm);
   }
}

//--- Draw one cell: background rect + text label
//    label="" => val used as full text directly
void DashCell_(int row,int col,string label,string val,color bgClr,color txtClr)
{
   // Each cell is inset by BORDER_PX inside its slot so gaps show the dark chart bg
   int slotX = DASH_X  + col*(CELL_W + BORDER_PX);
   int slotY = DASH_Y  + row*(CELL_H + BORDER_PX);
   int bx    = slotX + BORDER_PX;   // inner x
   int by    = slotY + BORDER_PX;   // inner y
   int bw    = CELL_W - BORDER_PX;  // inner width
   int bh    = CELL_H - BORDER_PX;  // inner height

   // ── background rectangle ──────────────────────────────────
   string bgNm = DASH_PREFIX+"BG_"+IntegerToString(row)+"_"+IntegerToString(col);
   if(ObjectFind(0,bgNm)<0) ObjectCreate(0,bgNm,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,bgNm,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0,bgNm,OBJPROP_XDISTANCE, bx);
   ObjectSetInteger(0,bgNm,OBJPROP_YDISTANCE, by);
   ObjectSetInteger(0,bgNm,OBJPROP_XSIZE,     bw);
   ObjectSetInteger(0,bgNm,OBJPROP_YSIZE,     bh);
   ObjectSetInteger(0,bgNm,OBJPROP_BGCOLOR,   bgClr);
   ObjectSetInteger(0,bgNm,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,bgNm,OBJPROP_COLOR,     CLR_BORDER);  // border color
   ObjectSetInteger(0,bgNm,OBJPROP_BACK,      false);
   ObjectSetInteger(0,bgNm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,bgNm,OBJPROP_ZORDER,    0);

   // ── text label ───────────────────────────────────────────
   string txt  = (label!="") ? (label+": "+val) : val;
   if(txt=="") txt=" ";  // prevent MT5 from showing default "Label" text on empty objects
   string lbNm = DASH_PREFIX+"LB_"+IntegerToString(row)+"_"+IntegerToString(col);
   if(ObjectFind(0,lbNm)<0) ObjectCreate(0,lbNm,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,lbNm,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0,lbNm,OBJPROP_XDISTANCE, bx+4);
   ObjectSetInteger(0,lbNm,OBJPROP_YDISTANCE, by+3);
   ObjectSetString (0,lbNm,OBJPROP_TEXT,      txt);
   ObjectSetInteger(0,lbNm,OBJPROP_COLOR,     txtClr);
   ObjectSetInteger(0,lbNm,OBJPROP_FONTSIZE,  8);
   ObjectSetString (0,lbNm,OBJPROP_FONT,      "Courier New");
   ObjectSetInteger(0,lbNm,OBJPROP_BACK,      false);
   ObjectSetInteger(0,lbNm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,lbNm,OBJPROP_ZORDER,    1);
}

//--- Draw a full-width horizontal separator line between rows
void DashSepLine(int afterRow)
{
   int totalW = 3*(CELL_W+BORDER_PX)+BORDER_PX;
   int y      = DASH_Y + (afterRow+1)*(CELL_H+BORDER_PX);

   string nm = DASH_PREFIX+"SEP_"+IntegerToString(afterRow);
   if(ObjectFind(0,nm)<0) ObjectCreate(0,nm,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,nm,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0,nm,OBJPROP_XDISTANCE, DASH_X);
   ObjectSetInteger(0,nm,OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0,nm,OBJPROP_XSIZE,     totalW);
   ObjectSetInteger(0,nm,OBJPROP_YSIZE,     2);           // 2px thick line
   ObjectSetInteger(0,nm,OBJPROP_BGCOLOR,   CLR_SEP);
   ObjectSetInteger(0,nm,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,nm,OBJPROP_COLOR,     CLR_SEP);
   ObjectSetInteger(0,nm,OBJPROP_BACK,      false);
   ObjectSetInteger(0,nm,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,nm,OBJPROP_ZORDER,    2);
}

void DrawDashboard(double confVal, int lastBarNum)
{
   if(!InpShowDashboard){ DashDeleteAll(); return; }

   // Clear all existing dashboard objects to prevent stale ghost text
   DashDeleteAll();

   // Draw solid black background behind the entire table
   int totalW = 3*(CELL_W+BORDER_PX)+BORDER_PX;
   int totalH = 13*(CELL_H+BORDER_PX)+BORDER_PX+4; // 13 rows + separators
   string bgMain = DASH_PREFIX+"MAINBG";
   if(ObjectFind(0,bgMain)<0) ObjectCreate(0,bgMain,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,bgMain,OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0,bgMain,OBJPROP_XDISTANCE, DASH_X);
   ObjectSetInteger(0,bgMain,OBJPROP_YDISTANCE, DASH_Y);
   ObjectSetInteger(0,bgMain,OBJPROP_XSIZE,     totalW);
   ObjectSetInteger(0,bgMain,OBJPROP_YSIZE,     totalH);
   ObjectSetInteger(0,bgMain,OBJPROP_BGCOLOR,   clrBlack);
   ObjectSetInteger(0,bgMain,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,bgMain,OBJPROP_COLOR,     clrBlack);
   ObjectSetInteger(0,bgMain,OBJPROP_BACK,      false);
   ObjectSetInteger(0,bgMain,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,bgMain,OBJPROP_ZORDER,    0);

   //── colour palette ─────────────────────────────────────────
   color clrHeader  = C'0,0,0';
   color clrColHdr  = C'0,0,0';
   color clrRowA    = C'0,0,0';
   color clrRowB    = C'0,0,0';
   color clrBull    = C'0,0,0';
   color clrBear    = C'0,0,0';

   color txtWhite   = clrWhite;
   color txtGray    = C'160,160,170';
   color txtGreen   = C'60,220,90';
   color txtRed     = C'220,70,70';
   color txtYellow  = C'230,205,55';
   color txtCyan    = C'60,200,225';

   //── derived values  (keep SHORT so they fit in CELL_W=120) ─
   string regime_str; color regClr;
   if(g_regime>0.65)      { regime_str="TREND";  regClr=txtGreen;  }
   else if(g_regime<0.35) { regime_str="RANGE";  regClr=txtYellow; }
   else                   { regime_str="MIXED";  regClr=txtGray;   }

   bool   isBull   = (g_sig_trend==1);
   string trendStr = isBull ? "BULL ▲" : "BEAR ▼";
   color  trendClr = isBull ? txtGreen : txtRed;
   color  trendBg  = isBull ? clrBull  : clrBear;

   // Profit Factor: shows "N/A" until both wins and losses exist, avoiding misleading 9.99 display
   double pfL  = g_gl_L>0 ? g_gp_L/g_gl_L : 0.0;
   double pfS  = g_gl_S>0 ? g_gp_S/g_gl_S : 0.0;
   string pfLStr, pfSStr;
   color  pfLClr, pfSClr;
   if(g_gl_L > 0 && g_gp_L > 0)
      { pfLStr=DoubleToString(pfL,2); pfLClr=(pfL>=1.0)?txtGreen:txtRed; }
   else if(g_gp_L > 0 && g_gl_L == 0)
      { pfLStr="Win Only";            pfLClr=txtGreen; }
   else
      { pfLStr="N/A";                 pfLClr=txtGray; }

   if(g_gl_S > 0 && g_gp_S > 0)
      { pfSStr=DoubleToString(pfS,2); pfSClr=(pfS>=1.0)?txtGreen:txtRed; }
   else if(g_gp_S > 0 && g_gl_S == 0)
      { pfSStr="Win Only";            pfSClr=txtGreen; }
   else
      { pfSStr="N/A";                 pfSClr=txtGray; }

   bool   riskOk  = CanTrade(lastBarNum);  // Pass current barNum so cooldown state is accurate
   string riskStr = riskOk ? "ACTIVE" : "PAUSED";
   color  riskClr = riskOk ? txtGreen : txtRed;

   // Cooldown: g_cooldownUntil is stored as barNum index, so remaining bars = difference
   int barsLeft = g_cooldownUntil - lastBarNum;
   string coolStr = (barsLeft > 0) ? IntegerToString(barsLeft)+" b" : "--";

   // Real signal win rate — populated from historical bars using 5-bar exit price comparison
   // The most recent 5 bars are excluded as exit data is not yet available
   double actualWRL = (g_sig_tot_L > 0) ? (double)g_sig_win_L / g_sig_tot_L : 0.0;
   double actualWRS = (g_sig_tot_S > 0) ? (double)g_sig_win_S / g_sig_tot_S : 0.0;
   string wrLStr = (g_sig_tot_L > 0) ? DoubleToString(actualWRL*100,1)+"%" : "N/A";
   string wrSStr = (g_sig_tot_S > 0) ? DoubleToString(actualWRS*100,1)+"%" : "N/A";

   // Trades: W/Total format — real arrow signals only, excludes last 5 unsettled bars
   string trLStr = (g_sig_tot_L > 0) ? IntegerToString(g_sig_win_L)+"/"+IntegerToString(g_sig_tot_L) : "--";
   string trSStr = (g_sig_tot_S > 0) ? IntegerToString(g_sig_win_S)+"/"+IntegerToString(g_sig_tot_S) : "--";

   // Session: trades this session / max
   string sessStr = IntegerToString(g_tradesSession)+"/"+IntegerToString(InpMaxTradesPerSession);

   // Symbol trimmed to 6 chars max
   string symStr  = StringSubstr(_Symbol,0,6);

   // ATR period rounded
   string atrStr  = DoubleToString(g_atrLen,0);

   //──────────────────────────────────────────────────────────
   // ROW 0 — Title
   //──────────────────────────────────────────────────────────
   // ROW 0 — Title
   //──────────────────────────────────────────────────────────
   DashCell_(0,0,"","  ML SuperTrend v10", clrHeader, txtCyan);
   DashCell_(0,1,"","  Hammad Dilber",     clrHeader, txtCyan);
   DashCell_(0,2,""," ",                   clrHeader, txtCyan);

   //──────────────────────────────────────────────────────────
   // ROW 1 — Column headers
   //──────────────────────────────────────────────────────────
   DashCell_(1,0,"","  SIGNAL",    clrColHdr, txtGray);
   DashCell_(1,1,"","  OPTIMIZER", clrColHdr, txtGray);
   DashCell_(1,2,"","  RISK GUARD",clrColHdr, txtGray);
   DashSepLine(1);

   //──────────────────────────────────────────────────────────
   // ROW 2
   //──────────────────────────────────────────────────────────
   DashCell_(2,0,"Trend", trendStr,              trendBg, trendClr);
   DashCell_(2,1,"Mult",  DoubleToString(g_mult,3), clrRowA, txtWhite);
   DashCell_(2,2,"Status",riskStr,               clrRowA, riskClr);

   //──────────────────────────────────────────────────────────
   // ROW 3
   //──────────────────────────────────────────────────────────
   DashCell_(3,0,"Regime",regime_str,            clrRowB, regClr);
   DashCell_(3,1,"ATR",   atrStr,                clrRowB, txtWhite);
   DashCell_(3,2,"Session",sessStr,              clrRowB, txtWhite);

   //──────────────────────────────────────────────────────────
   // ROW 4
   //──────────────────────────────────────────────────────────
   DashCell_(4,0,"Conf",  DoubleToString(confVal*100,0)+"%", clrRowA, txtYellow);
   DashCell_(4,1,"Stop x",DoubleToString(g_stopMult,2),      clrRowA, txtWhite);
   DashCell_(4,2,"PnL",   DoubleToString(g_sessionPnL,0)+"$",clrRowA, g_sessionPnL>=0?txtGreen:txtRed);

   //──────────────────────────────────────────────────────────
   // ROW 5
   //──────────────────────────────────────────────────────────
   DashCell_(5,0,"Symbol",symStr,                clrRowB, txtCyan);
   DashCell_(5,1,"TP x",  DoubleToString(g_tpMult,2), clrRowB, txtWhite);
   DashCell_(5,2,"Streak",IntegerToString(g_consecLosses)+"L",clrRowB,g_consecLosses>0?txtRed:txtGreen);

   //──────────────────────────────────────────────────────────
   // ROW 6
   //──────────────────────────────────────────────────────────
   DashCell_(6,0,"TF",    EnumToString(_Period), clrRowA, txtCyan);
   DashCell_(6,1,"Brk",   DoubleToString(g_brkBuf,2), clrRowA, txtWhite);
   DashCell_(6,2,"Cooldown",coolStr,             clrRowA, barsLeft>0?txtYellow:txtGreen);
   DashSepLine(6);

   //──────────────────────────────────────────────────────────
   // ROW 7 — Performance section header
   //──────────────────────────────────────────────────────────
   DashCell_(7,0,"","  PERFORMANCE", clrHeader, txtGray);
   DashCell_(7,1,""," ",             clrHeader, txtGray);
   DashCell_(7,2,""," ",             clrHeader, txtGray);

   //──────────────────────────────────────────────────────────
   // ROW 8 — Column labels: Metric / Long / Short
   //──────────────────────────────────────────────────────────
   DashCell_(8,0,""," METRIC",  clrColHdr, txtGray);
   DashCell_(8,1,""," LONG",    clrColHdr, txtGreen);
   DashCell_(8,2,""," SHORT",   clrColHdr, txtRed);
   DashSepLine(8);

   DashCell_(9,0,""," Win Rate", clrRowA, txtGray);
   DashCell_(9,1,""," "+wrLStr,  clrRowA, (g_sig_tot_L>0&&actualWRL>=0.5)?txtGreen:((g_sig_tot_L==0)?txtGray:txtRed));
   DashCell_(9,2,""," "+wrSStr,  clrRowA, (g_sig_tot_S>0&&actualWRS>=0.5)?txtGreen:((g_sig_tot_S==0)?txtGray:txtRed));

   DashCell_(10,0,""," Prof Fac",  clrRowB, txtGray);
   DashCell_(10,1,""," "+pfLStr,   clrRowB, pfLClr);
   DashCell_(10,2,""," "+pfSStr,   clrRowB, pfSClr);

   DashCell_(11,0,""," Sharpe",    clrRowA, txtGray);
   DashCell_(11,1,""," "+DoubleToString(g_sharpe_L,2), clrRowA, g_sharpe_L>=0.5?txtGreen:txtRed);
   DashCell_(11,2,""," "+DoubleToString(g_sharpe_S,2), clrRowA, g_sharpe_S>=0.5?txtGreen:txtRed);

   DashCell_(12,0,""," Trades",    clrRowB, txtGray);
   DashCell_(12,1,""," "+trLStr,   clrRowB, txtWhite);
   DashCell_(12,2,""," "+trSStr,   clrRowB, txtWhite);
   DashSepLine(12);

   ChartRedraw(0);
}

//==========================================================================
// SEND ALERT — fires popup and/or push notification on signal
//==========================================================================
void SendSignalAlert(bool isBuy, int barNum)
{
   if(!InpAlertPopup && !InpAlertPush) return;
   if(InpAlertOnce && barNum==g_lastAlertBar) return;
   g_lastAlertBar = barNum;

   string dir = isBuy ? "BUY" : "SELL";
   string msg = "ML ST [Hammad Dilber] — "+dir+" signal on "+_Symbol+" "+
                EnumToString(_Period)+" @ "+DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_BID),_Digits);

   if(InpAlertPopup)  Alert(msg);
   if(InpAlertPush)   SendNotification(msg);
}

//==========================================================================
// SESSION RESET — resets trade counters and PnL at start of each new day
//==========================================================================
void CheckSessionReset(datetime barTime)
{
   MqlDateTime dt_now, dt_last;
   TimeToStruct(barTime,     dt_now);
   TimeToStruct(g_lastSessionDay, dt_last);

   if(g_lastSessionDay==0 || dt_now.day!=dt_last.day || dt_now.mon!=dt_last.mon)
   {
      g_tradesSession  = 0;
      g_sessionPnL     = 0;
      g_consecLosses   = 0;   // Reset daily loss streak on new session
      g_lastSessionDay = barTime;
   }
}

//==========================================================================
// OnInit
//==========================================================================
int OnInit()
{
   SetIndexBuffer(0,BullBuf, INDICATOR_DATA);
   SetIndexBuffer(1,BearBuf, INDICATOR_DATA);
   SetIndexBuffer(2,BuyBuf,  INDICATOR_DATA);
   SetIndexBuffer(3,SellBuf, INDICATOR_DATA);
   SetIndexBuffer(4,ConfBuf, INDICATOR_DATA);  // Confidence buffer — hidden data channel for EAs

   PlotIndexSetInteger(2,PLOT_ARROW,233);
   PlotIndexSetInteger(3,PLOT_ARROW,234);
   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,0.0);
   PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,0.0);
   PlotIndexSetDouble(2,PLOT_EMPTY_VALUE,0.0);
   PlotIndexSetDouble(3,PLOT_EMPTY_VALUE,0.0);
   PlotIndexSetDouble(4,PLOT_EMPTY_VALUE,0.0);

   h_atr  =iATR(_Symbol,_Period,InpATRPeriod);
   h_atr14=iATR(_Symbol,_Period,14);
   h_rsi  =iRSI(_Symbol,_Period,InpRSILen,PRICE_CLOSE);
   h_adx  =iADX(_Symbol,_Period,14);

   // Validate all indicator handles before proceeding
   if(h_atr==INVALID_HANDLE||h_rsi==INVALID_HANDLE||h_atr14==INVALID_HANDLE)
   {Alert("ML ST: Handle creation failed! Check symbol/period.");return INIT_FAILED;}

   g_mult=InpMultiplier; g_atrLen=InpATRPeriod;
   g_stopMult=InpStopMult; g_tpMult=InpTPMult;
   g_brkBuf=InpBreakoutBuf; g_sensitivity=InpSensitivity;

   int cells=InpMapGridX*InpMapGridY;
   ArrayResize(g_grid,cells);
   for(int i=0;i<cells;i++)
   {
      g_grid[i].mean_atr_ret=0;g_grid[i].down_ewm=0;g_grid[i].count=0;
      g_grid[i].conf=0;g_grid[i].d_mult=0;g_grid[i].d_len=0;
      g_grid[i].d_stop=0;g_grid[i].d_tp=0;g_grid[i].d_brk=0;
   }
   IndicatorSetString(INDICATOR_SHORTNAME,"ML ST [Hammad Dilber] v10.02");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(h_atr  !=INVALID_HANDLE)IndicatorRelease(h_atr);
   if(h_atr14!=INVALID_HANDLE)IndicatorRelease(h_atr14);
   if(h_rsi  !=INVALID_HANDLE)IndicatorRelease(h_rsi);
   if(h_adx  !=INVALID_HANDLE)IndicatorRelease(h_adx);
   DashDeleteAll(); // Remove all dashboard objects from chart on deinit
}

//==========================================================================
// OnCalculate
//==========================================================================
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total<InpATRPeriod*3+100)return 0;

   ArraySetAsSeries(BullBuf,true);ArraySetAsSeries(BearBuf,true);
   ArraySetAsSeries(BuyBuf,true); ArraySetAsSeries(SellBuf,true);
   ArraySetAsSeries(ConfBuf,true);
   ArraySetAsSeries(high,true);   ArraySetAsSeries(low,true);
   ArraySetAsSeries(close,true);  ArraySetAsSeries(open,true);
   ArraySetAsSeries(tick_volume,true);
   ArraySetAsSeries(time,true);

   double atr[],rsi[],atr14[],adx[];
   ArraySetAsSeries(atr,true);  ArraySetAsSeries(rsi,true);
   ArraySetAsSeries(atr14,true);ArraySetAsSeries(adx,true);

   // Incremental buffer copy — only fetch bars needed since last calculation
   int copyBars = (prev_calculated==0) ? rates_total : (rates_total-prev_calculated+2);
   copyBars = MathMax(copyBars, InpATRPeriod*3+10);
   copyBars = MathMin(copyBars, rates_total);

   if(CopyBuffer(h_atr,  0,0,copyBars,atr)  <=0)return 0;
   if(CopyBuffer(h_rsi,  0,0,copyBars,rsi)  <=0)return 0;
   if(CopyBuffer(h_atr14,0,0,copyBars,atr14)<=0)return 0;
   if(h_adx!=INVALID_HANDLE)CopyBuffer(h_adx,0,0,copyBars,adx);

   // Full reset
   if(prev_calculated==0)
   {
      g_mult=InpMultiplier;g_atrLen=InpATRPeriod;
      g_stopMult=InpStopMult;g_tpMult=InpTPMult;
      g_brkBuf=InpBreakoutBuf;g_sensitivity=InpSensitivity;
      g_st_up=0;g_st_dn=0;g_st_trend=1;g_st_rma=0;
      g_sig_up=0;g_sig_dn=0;g_sig_trend=1;g_sig_rma=0;g_sig_trend_prev=1;
      g_topFlag=0;g_botFlag=0;g_topFlagPrev=0;g_botFlagPrev=0;
      g_lastSigBar=-InpMinBarsBetweenSigs-1;
      g_regime=0.5;g_lastRegBar=-99;
      g_gp_L=0;g_gl_L=0;g_gp_S=0;g_gl_S=0;
      g_tot_L=0;g_win_L=0;g_tot_S=0;g_win_S=0;
      g_sig_tot_L=0;g_sig_win_L=0;g_sig_tot_S=0;g_sig_win_S=0; // Reset real signal counters on full recalculation
      g_consecLoss_L=0;g_consecLoss_S=0;
      g_sharpe_L=0;g_sortino_L=0;g_sharpe_S=0;g_sortino_S=0;
      g_lastParamBar=-1;
      g_cooldownUntil=0;g_tradesSession=0;g_sessionPnL=0;g_consecLosses=0;
      g_pressure=0;g_bullFlow=0;g_bearFlow=0;
      g_lastAlertBar=-9999;
      g_lastSessionDay=0;
      ArrayResize(g_highs,0);ArrayResize(g_lows,0);
      ArrayResize(g_rsis,0); ArrayResize(g_vols,0);
      ArrayResize(g_probesL,0);ArrayResize(g_probesS,0);
      ArrayResize(g_rollUSD_L,0);ArrayResize(g_rollATR_L,0);ArrayResize(g_rollRet_L,0);
      ArrayResize(g_rollUSD_S,0);ArrayResize(g_rollATR_S,0);ArrayResize(g_rollRet_S,0);
      ArrayResize(g_decay,0);
      ArrayResize(g_batchL,0);ArrayResize(g_batchS,0);
      ArrayResize(g_pressureLog,0);
      int cells=InpMapGridX*InpMapGridY;
      ArrayResize(g_grid,cells);
      for(int gi=0;gi<cells;gi++)
      {
         g_grid[gi].mean_atr_ret=0;g_grid[gi].down_ewm=0;g_grid[gi].count=0;
         g_grid[gi].conf=0;g_grid[gi].d_mult=0;g_grid[gi].d_len=0;
         g_grid[gi].d_stop=0;g_grid[gi].d_tp=0;g_grid[gi].d_brk=0;
      }
      ArrayInitialize(BullBuf,0.0);ArrayInitialize(BearBuf,0.0);
      ArrayInitialize(BuyBuf,0.0); ArrayInitialize(SellBuf,0.0);
      ArrayInitialize(ConfBuf,0.0);
   }

   int startIdx=(prev_calculated==0)?(rates_total-2):(rates_total-prev_calculated);
   if(startIdx>=rates_total)startIdx=rates_total-2;

   // For dashboard
   double dashWRL=0.5, dashWRS=0.5, dashConf=0.0;
   int    dashLastBarNum=0; // track last barNum for cooldown calc

   //==========================================================================
   // MAIN LOOP
   //==========================================================================
   for(int i=startIdx;i>=0;i--)
   {
      int barNum=rates_total-1-i;

      // Daily session reset check
      if(i<ArraySize(time))
         CheckSessionReset(time[i]);

      double h_=high[i],l_=low[i],c_=close[i];
      double c1=(i+1<rates_total)?close[i+1]:c_;
      double o_=open[i];
      double tv=(double)tick_volume[i];

      // Safe buffer access (incremental copy offset)
      int bi=i; // index into copied arrays
      double cATR =(bi<ArraySize(atr))  ?atr[bi]  :0.0001;
      double cRSI =(bi<ArraySize(rsi))  ?rsi[bi]  :50.0;
      double cATR14=(bi<ArraySize(atr14))?atr14[bi]:0.0001;
      double cADX =(ArraySize(adx)>0&&bi<ArraySize(adx))?adx[bi]:25.0;

      double tr=MathMax(h_-l_,MathMax(MathAbs(h_-c1),MathAbs(l_-c1)));

      // Price source selection via enum
      double src;
      switch(InpSourceType)
      {
         case SRC_OPEN:  src=o_;                      break;
         case SRC_HIGH:  src=h_;                      break;
         case SRC_LOW:   src=l_;                      break;
         case SRC_CLOSE: src=c_;                      break;
         case SRC_HL2:   src=(h_+l_)/2.0;             break;
         case SRC_HLC3:  src=(h_+l_+c_)/3.0;         break;
         case SRC_OHLC4: src=(o_+h_+l_+c_)/4.0;      break;
         default:        src=(h_+l_+c_*2.0)/4.0;     break; // hlcc4
      }

      // Plot SuperTrend
      int   pLen =(int)(InpLockATRBands?InpATRPeriod:Clamp(g_atrLen,5,100));
      double pMult=InpLockATRBands?InpMultiplier:Clamp(g_mult,0.5,5.0);
      ST_Step(src,pMult,pLen,InpUseATR,c1,c_,tr,g_st_up,g_st_dn,g_st_trend,g_st_rma);
      if(g_st_trend==1){BullBuf[i]=g_st_up;BearBuf[i]=0.0;}
      else             {BearBuf[i]=g_st_dn;BullBuf[i]=0.0;}

      // Signal SuperTrend
      int   sLen=(int)Clamp(g_atrLen,5,100);
      double sMult=Clamp(g_mult,0.5,5.0);
      ST_Step(src,sMult,sLen,InpUseATR,c1,c_,tr,g_sig_up,g_sig_dn,g_sig_trend,g_sig_rma);

      // Regime detection
      if(barNum-g_lastRegBar>=7)
      {
         g_regime=DetectRegime(close,i,rates_total,cADX);
         g_lastRegBar=barNum;
      }

      // Vol norm
      double volNorm=0.5;
      {
         double aAvg=0;int ac=0;
         for(int vi=i;vi<MathMin(i+100,ArraySize(atr14));vi++){aAvg+=atr14[vi];ac++;}
         if(ac>0){aAvg/=ac;volNorm=aAvg>0?Clamp((cATR14/aAvg)/InpVolMaxRatio,0,1):0.5;}
      }

      QPush(g_highs,h_,500);QPush(g_lows,l_,500);
      QPush(g_rsis,cRSI,500);
      if(tv>0)QPush(g_vols,tv,500);

      // Pressure sensor
      if(InpEnableTickPressure)
      {
         if(c_>c1)g_bullFlow+=tv;else if(c_<c1)g_bearFlow+=tv;
         double tf=g_bullFlow+g_bearFlow;
         g_pressure=tf>0?(g_bullFlow-g_bearFlow)/tf:0;
         QPush(g_pressureLog,g_pressure,20);
         if(i==0){g_bullFlow=0;g_bearFlow=0;}
      }

      //=== BACKGROUND TEST MATRIX ===
      if(InpEnableAdaptive&&InpUseFaintCycle&&barNum>5)
      {
         double loHold=l_,hiHold=h_;
         for(int hb=1;hb<5&&(i+hb)<rates_total;hb++)
         {if(low[i+hb]<loHold)loHold=low[i+hb];if(high[i+hb]>hiHold)hiHold=high[i+hb];}

         double lUsd,lAtr,lMae,sUsd,sAtr,sMae;
         bool lClosed=CloseMatured(g_probesL,+1,loHold,hiHold,c_,barNum,lUsd,lAtr,lMae);
         bool sClosed=CloseMatured(g_probesS,-1,loHold,hiHold,c_,barNum,sUsd,sAtr,sMae);

         if(lClosed&&lUsd!=EMPTY_VALUE)
         {
            g_tot_L++;if(lUsd>0){g_win_L++;g_consecLoss_L=0;}else g_consecLoss_L++;
            if(lUsd>=0)g_gp_L+=lUsd;else g_gl_L+=(-lUsd);
            double cap=Clamp(lUsd,-InpPnLCapUSD,InpPnLCapUSD);
            QPush(g_rollUSD_L,cap,InpRollN);QPush(g_rollATR_L,lAtr,InpRollN);
            if(InpUseSTM)DecayPush(lAtr,lMae,g_regime,volNorm,+1);
            if(InpEnableBinLearning)
            {
               double gm,gl2,gs,gt,gb,gc;
               GridRecommend(Bucket(g_regime,InpMapGridX),Bucket(volNorm,InpMapGridY),gm,gl2,gs,gt,gb,gc);
               BatchSample bs;bs.atr_ret=lAtr;bs.mae_atr=lMae;bs.pnl_usd=lUsd;bs.conf=gc;
               QPushB(g_batchL,bs,200);
            }
         }
         if(sClosed&&sUsd!=EMPTY_VALUE)
         {
            g_tot_S++;if(sUsd>0){g_win_S++;g_consecLoss_S=0;}else g_consecLoss_S++;
            if(sUsd>=0)g_gp_S+=sUsd;else g_gl_S+=(-sUsd);
            double cap=Clamp(sUsd,-InpPnLCapUSD,InpPnLCapUSD);
            QPush(g_rollUSD_S,cap,InpRollN);QPush(g_rollATR_S,sAtr,InpRollN);
            if(InpUseSTM)DecayPush(sAtr,sMae,g_regime,volNorm,-1);
            if(InpEnableBinLearning)
            {
               double gm,gl2,gs,gt,gb,gc;
               GridRecommend(Bucket(g_regime,InpMapGridX),Bucket(volNorm,InpMapGridY),gm,gl2,gs,gt,gb,gc);
               BatchSample bs;bs.atr_ret=sAtr;bs.mae_atr=sMae;bs.pnl_usd=sUsd;bs.conf=gc;
               QPushB(g_batchS,bs,200);
            }
         }

         // Decay + consolidate
         if(InpUseSTM)
         {
            DecayStep();
            if(barNum%InpSTMConsolidateEvery==0&&ArraySize(g_decay)>0&&InpUseCognitiveMap)
            {
               double dSD=DecayTailFeedback();
               int posIdx=-1,negIdx=-1;double posMag=-1,negMag=-1;
               for(int di=0;di<ArraySize(g_decay);di++)
               {
                  double mag=MathAbs(g_decay[di].atr_ret)*g_decay[di].energy;
                  if(g_decay[di].atr_ret>=0&&mag>posMag){posMag=mag;posIdx=di;}
                  if(g_decay[di].atr_ret< 0&&mag>negMag){negMag=mag;negIdx=di;}
               }
               if(posIdx>=0)GridUpdate(Bucket(g_decay[posIdx].regime,InpMapGridX),Bucket(g_decay[posIdx].vol_norm,InpMapGridY),g_decay[posIdx].atr_ret,0,0,dSD,0,0);
               if(negIdx>=0)GridUpdate(Bucket(g_decay[negIdx].regime,InpMapGridX),Bucket(g_decay[negIdx].vol_norm,InpMapGridY),g_decay[negIdx].atr_ret,0,0,dSD,0,0);
            }
         }

         if(CountActive(g_probesL)<5)OpenProbe(g_probesL,+1,o_,cATR,barNum);
         if(CountActive(g_probesS)<5)OpenProbe(g_probesS,-1,o_,cATR,barNum);

         //=== OPTIMIZER ===
         int lc=ArraySize(g_rollATR_L),sc2=ArraySize(g_rollATR_S);
         if((lc>=5||sc2>=5)&&(g_lastParamBar<0||barNum-g_lastParamBar>=InpParamUpdateEvery))
         {
            double wrL=QWinRate(g_rollUSD_L),auL=QAvgFull(g_rollUSD_L);
            double wrS=QWinRate(g_rollUSD_S),auS=QAvgFull(g_rollUSD_S);
            double aaL=QAvgFull(g_rollATR_L),aaS=QAvgFull(g_rollATR_S);
            double soL=QSortino(g_rollATR_L),soS=QSortino(g_rollATR_S);
            UpdateSharpeSortino(); // Recalculate Sharpe and Sortino from latest rolling returns
            double pfL=g_gl_L>0?g_gp_L/g_gl_L:(g_gp_L>0?9.99:0.0);
            double pfS=g_gl_S>0?g_gp_S/g_gl_S:(g_gp_S>0?9.99:0.0);
            double awL=g_win_L>0?g_gp_L/g_win_L:0;
            double alL=(g_tot_L-g_win_L)>0?g_gl_L/(g_tot_L-g_win_L):0;
            double awS=g_win_S>0?g_gp_S/g_win_S:0;
            double alS=(g_tot_S-g_win_S)>0?g_gl_S/(g_tot_S-g_win_S):0;

            double dML,dLL,dSL,dTL,dBL,dMS,dLS,dSS,dTS,dBS;
            LearnProposals(wrL,auL,aaL,soL,0,pfL,awL,alL,lc,g_mult,g_atrLen,g_sharpe_L,(int)g_consecLoss_L,dML,dLL,dSL,dTL,dBL);
            LearnProposals(wrS,auS,aaS,soS,0,pfS,awS,alS,sc2,g_mult,g_atrLen,g_sharpe_S,(int)g_consecLoss_S,dMS,dLS,dSS,dTS,dBS);

            double netM=(lc>0?dML:0)+(sc2>0?dMS:0);
            double netL2=(lc>0?dLL:0)+(sc2>0?dLS:0);
            double netS2=(lc>0?dSL:0)+(sc2>0?dSS:0);
            double netT=(lc>0?dTL:0)+(sc2>0?dTS:0);
            double netB=(lc>0?dBL:0)+(sc2>0?dBS:0);

            int ix=Bucket(g_regime,InpMapGridX),iy=Bucket(volNorm,InpMapGridY);
            double gm,gl3,gs,gt,gb,gc;
            GridRecommend(ix,iy,gm,gl3,gs,gt,gb,gc);
            double wg=Clamp(gc,0,InpMapWeightMax);

            double tMult_MG=InpMultiplier*(1+gm)*wg+g_mult*(1+netM)*(1-wg);
            double tLen_MG =(double)InpATRPeriod+gl3*wg+(g_atrLen+netL2)*(1-wg);
            double tStop_MG=InpStopMult*(1+gs)*wg+g_stopMult*(1+netS2)*(1-wg);
            double tTP_MG  =InpTPMult*(1+gt)*wg+g_tpMult*(1+netT)*(1-wg);
            double tBrk_MG =InpBreakoutBuf*(1+gb)*wg+g_brkBuf*(1+netB)*(1-wg);

            int N_b,str_b;double Wmin_b,wb2,cM,cL2,cS2,cT2,cB2,dbM,dbL2,aE;
            MasterParams(InpDialK,N_b,str_b,Wmin_b,wb2,cM,cL2,cS2,cT2,cB2,dbM,dbL2,aE);
            if(InpEnableBinLearning)
            {
               double mu2;
               g_firedL=BatchFire(g_batchL,N_b,str_b,Wmin_b,cM,cL2,cS2,cT2,cB2,g_dMultBL,g_dLenBL,g_dStopBL,g_dTPBL,g_dBrkBL,mu2);g_muBL=mu2;
               g_firedS=BatchFire(g_batchS,N_b,str_b,Wmin_b,cM,cL2,cS2,cT2,cB2,g_dMultBS,g_dLenBS,g_dStopBS,g_dTPBS,g_dBrkBS,mu2);g_muBS=mu2;
            }
            double wb3=(g_firedL||g_firedS)?wb2:0.0;
            double wL3=(g_firedL&&(!g_firedS||MathAbs(g_muBL)>=MathAbs(g_muBS)))?0.7:(g_firedL&&g_firedS?0.3:(g_firedL?1.0:0.0));
            double wS3=(g_firedS&&(!g_firedL||MathAbs(g_muBS)> MathAbs(g_muBL)))?0.7:(g_firedL&&g_firedS?0.3:(g_firedS?1.0:0.0));
            double tMult_b=g_mult*(1+wL3*g_dMultBL+wS3*g_dMultBS);
            double tLen_b =g_atrLen+(wL3*g_dLenBL+wS3*g_dLenBS);
            double tStop_b=g_stopMult*(1+wL3*g_dStopBL+wS3*g_dStopBS);
            double tTP_b  =g_tpMult*(1+wL3*g_dTPBL+wS3*g_dTPBS);
            double tBrk_b =g_brkBuf*(1+wL3*g_dBrkBL+wS3*g_dBrkBS);

            double tMf=tMult_MG*(1-wb3)+tMult_b*wb3;
            double tLf=tLen_MG *(1-wb3)+tLen_b *wb3;
            double tSf=tStop_MG*(1-wb3)+tStop_b*wb3;
            double tTf=tTP_MG  *(1-wb3)+tTP_b  *wb3;
            double tBf=tBrk_MG *(1-wb3)+tBrk_b *wb3;

            if(MathAbs(tMf-g_mult)>dbM||MathAbs(tLf-g_atrLen)>dbL2)
            {
               g_mult     +=aE*(Clamp(Quantize(tMf,InpQuantStepMult),0.5,5.0)-g_mult);
               g_atrLen   +=aE*(Clamp(MathRound(tLf),5,100)-g_atrLen);
               g_stopMult +=aE*(Clamp(Quantize(tSf,InpQuantStepStop),0.3,3.0)-g_stopMult);
               g_tpMult   +=aE*(Clamp(Quantize(tTf,InpQuantStepTP),0.5,5.0)-g_tpMult);
               g_brkBuf   +=aE*(Clamp(Quantize(tBf,InpQuantStepBrk),0.0,3.0)-g_brkBuf);
               g_lastParamBar=barNum;
            }

            if(InpRevertEvery>0&&barNum%InpRevertEvery==0)
            {
               g_mult   +=InpRevertStep*(InpMultiplier-g_mult);
               g_atrLen +=InpRevertStep*((double)InpATRPeriod-g_atrLen);
            }

            if(InpUseCognitiveMap)
            {
               if(lClosed&&lUsd!=EMPTY_VALUE)GridUpdate(ix,iy,lAtr,netM,netL2,netS2,netT,netB);
               if(sClosed&&sUsd!=EMPTY_VALUE)GridUpdate(ix,iy,sAtr,netM,netL2,netS2,netT,netB);
            }

            // Update dashboard vars
            dashWRL=wrL; dashWRS=wrS; dashConf=gc;
            dashLastBarNum=barNum;
         }
      }

      //==========================================================================
      // SIGNAL GENERATION
      //==========================================================================
      int szH=ArraySize(g_highs),szL=ArraySize(g_lows);
      int sens=(int)Clamp(g_sensitivity,2,MathMin(100.0,(double)(szH-1)));
      int lb  =MathMax(1,(int)(g_sensitivity/10.0));

      BuyBuf[i]=0.0;SellBuf[i]=0.0;ConfBuf[i]=0.0;
      if(szH<sens+lb){g_sig_trend_prev=g_sig_trend;continue;}

      double hiNow=QMax(g_highs,sens);
      double hiPrev=QMax(g_highs,sens+lb);
      double loNow=QMin(g_lows,sens);
      double loPrev=QMin(g_lows,sens+lb);

      bool isNewHigh=(hiNow!=hiPrev&&hiNow>hiPrev);
      bool isNewLow =(loNow!=loPrev&&loNow<loPrev);

      if(InpMajorLevelsOnly)
      {
         double atrLvl=cATR*InpMajorLevelDepth;
         isNewHigh=isNewHigh&&(h_-QMin(g_lows,sens))>atrLvl;
         isNewLow =isNewLow &&(QMax(g_highs,sens)-l_)>atrLvl;
      }

      bool rsiCold=true,rsiHot=true;
      if(InpEnableRSI)
      {
         int szR=ArraySize(g_rsis);
         bool fc=false,fh=false;
         for(int ri=szR-1;ri>=MathMax(0,szR-InpRSILookbackBot);ri--)
            if(g_rsis[ri]<InpRSIBot){fc=true;break;}
         for(int ri=szR-1;ri>=MathMax(0,szR-InpRSILookbackTop);ri--)
            if(g_rsis[ri]>InpRSITop){fh=true;break;}
         rsiCold=fc;rsiHot=fh;
      }

      bool volSurge=true;
      if(InpRequireVolSpike)
      {
         int szV=ArraySize(g_vols);
         double vAvg=szV>0?QAvg(g_vols,InpVolLookback):1;
         volSurge=tv>InpVolMultiplier*vAvg;
      }

      bool buyF =rsiCold&&volSurge;
      bool sellF=rsiHot &&volSurge;
      bool canSig=(barNum-g_lastSigBar)>=InpMinBarsBetweenSigs && CanTrade(barNum); // Risk Guard check before allowing signal

      bool doBuy=false,doSell=false;

      // Signal mode: Reversal logic
      if(InpSignalMode==SignalReversal&&canSig)
      {
         g_topFlagPrev=g_topFlag;
         g_botFlagPrev=g_botFlag;
         if(g_sig_trend==-1)                       g_topFlag=0;
         else if(isNewHigh&&g_sig_trend==1)         g_topFlag=1;
         if(g_sig_trend==1)                        g_botFlag=0;
         else if(isNewLow&&g_sig_trend==-1)        g_botFlag=1;

         bool rSell=(g_topFlagPrev==1&&g_topFlag==0)||(!InpRequireNewExtreme&&g_sig_trend_prev==1&&g_sig_trend==-1);
         bool rBuy =(g_botFlagPrev==1&&g_botFlag==0)||(!InpRequireNewExtreme&&g_sig_trend_prev==-1&&g_sig_trend==1);

         if(rSell&&sellF)doSell=true;
         else if(rBuy&&buyF)doBuy=true;
      }

      if(InpSignalMode==SignalBreakout&&canSig)
      {
         if(isNewHigh&&g_sig_trend==1 &&sellF)doSell=true;
         if(isNewLow &&g_sig_trend==-1&&buyF) doBuy =true;
      }

      // Compute confidence score for this bar's signal
      double confScore = 0.0;
      {
         // Base: grid confidence
         int ix2=Bucket(g_regime,InpMapGridX),iy2=Bucket(volNorm,InpMapGridY);
         double gm2,gl2x,gs2,gt2,gb2,gc2;
         GridRecommend(ix2,iy2,gm2,gl2x,gs2,gt2,gb2,gc2);
         confScore = gc2;
         // Boost if RSI confirms direction
         if(doBuy  && cRSI<InpRSIBot+20) confScore=MathMin(1.0,confScore+0.2);
         if(doSell && cRSI>InpRSITop-20) confScore=MathMin(1.0,confScore+0.2);
         // Boost on vol surge
         if(volSurge && InpRequireVolSpike) confScore=MathMin(1.0,confScore+0.1);
         // Regime alignment
         if(doBuy  && g_sig_trend==1 && g_regime>0.5) confScore=MathMin(1.0,confScore+0.1);
         if(doSell && g_sig_trend==-1&& g_regime>0.5) confScore=MathMin(1.0,confScore+0.1);
      }

      // Write buffers
      if(doSell)
      {
         SellBuf[i]=h_+cATR*0.5;BuyBuf[i]=0.0;
         ConfBuf[i]=confScore*100.0;
         g_lastSigBar=barNum;
         if(i==0)
         {
            ApplyRiskGuard(0.0, barNum);
            SendSignalAlert(false, barNum);
         }
         // Win/loss evaluation: compare entry close to close 5 bars ahead
         // Loop iterates oldest-to-newest, so index i-5 is 5 bars into the future
         if(i>=5)
         {
            g_sig_tot_S++;
            double entryPx = c_;           // sell entry = current close
            double exitPx  = close[i-5];   // close 5 bars later
            if(exitPx < entryPx) g_sig_win_S++;  // price went down = short win
         }
      }
      else if(doBuy)
      {
         BuyBuf[i]=l_-cATR*0.5;SellBuf[i]=0.0;
         ConfBuf[i]=confScore*100.0;
         g_lastSigBar=barNum;
         if(i==0)
         {
            ApplyRiskGuard(0.0, barNum);
            SendSignalAlert(true, barNum);
         }
         // Win/loss evaluation: compare entry close to close 5 bars ahead
         if(i>=5)
         {
            g_sig_tot_L++;
            double entryPx = c_;           // buy entry = current close
            double exitPx  = close[i-5];   // close 5 bars later
            if(exitPx > entryPx) g_sig_win_L++;  // price went up = long win
         }
      }
      else{BuyBuf[i]=0.0;SellBuf[i]=0.0;ConfBuf[i]=0.0;}

      g_sig_trend_prev=g_sig_trend;
      dashLastBarNum=barNum; // always track last processed bar

   } // end main loop

   // Update dashboard after processing all bars
   DrawDashboard(dashConf, dashLastBarNum);

   return rates_total;
}
//+------------------------------------------------------------------+