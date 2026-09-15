//+------------------------------------------------------------------+
//|                                              DataMiner.mqh        |
//|                          ALXQuant Core - Institutional Grade v5.1|
//|                  Multi-TF, RegimeName, SL/TP, DD, Macro real     |
//|                  News Flags, Regime Semantic, Schema v5.1        |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore v5.0"
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
    v.7.13 - 2026-07-29 - Refactor: class CDataMinerBuffered_v5 → CDataMinerBuffered.
    v.7.14 - 2026-08-22 - Institutional upgrade v5.1:
                         C1: SpreadAtEntry em pips (conversão pontos→pips por dígitos)
                         C2: captureRatio em R-múltiplos (netProfit/initialRisk / mfeR)
                         C3: durationBars no timeframe M5 fixo (não _Period)
                         C4: InitialRisk valida entrySL>0, fallback ATR×2 documentado
                         C7: profitFactorTrade REMOVIDO (inválido por trade)
                         C8: Schema version header no CSV (#SCHEMA_VERSION=5.1)
                         ADD: News flags (high/medium active, minutes to next, blocking event)
                         ADD: Regime semantic flags (trend_strong_bull/bear, range_tight, chaos, breakout)
                         ADD: SessionName14 (14 sessões detalhadas)
*/

#include "MacroRegimeEngine.mqh"
#include "RiskSentiment.mqh"
#include "SessionProfile.mqh"
#include <ALXQuantCore\Core\NewsFilter.mqh>
#include <WinAPI\fileapi.mqh>
#include <WinAPI\handleapi.mqh>
#include <WinAPI\winbase.mqh>

// Overload WriteFile to accept uchar[] (UTF-8) instead of ushort[] (UTF-16)
#import "kernel32.dll"
int WriteFile(long hFile, uchar &buffer[], uint bytesToWrite, uint &written, long overlapped);
#import


//+------------------------------------------------------------------+
//| #Inputs default                                                  |
//+------------------------------------------------------------------+
input group             "▸ QuantCore Data Miner "
input bool              InpEnableDataMiner      = false;                    // DataMiner On/Off
input string            InpDataMinerPath        = "C:\\ALXQuant\\data\\";   // DataMiner output directory
//input string            InpDataMinerFile        = "IS_Green_Lab";         // Base filename (symbol + _miner.csv appended)
input int               InpCatThreshold         = 10;                       // Catastrophic MAE threshold (R-multiples)


//+------------------------------------------------------------------+


struct STradeRecord_v5
{
   // Identificação
   ulong    ticket;
   ulong    magic;
   string   symbol;
   string   direction;
   datetime entryTime;
   double   entryPrice;
   double   volume;
   double   spreadAtEntry;

   // Regime Engine (features)
   double   hurst, confidence_r2, strength, slope, slopeNorm;
   double   dirScore, momState, atr, distVWAP, distVWAP_ATR;
   double   spreadAnomaly, relVol, liqState, volBurst;
   int      trending, meanRev, bullish, bearish, highVol, lowVol;
   int      strongMom, possRev, liqSafe, chaos;
   int      trendHab, breakoutHab, mrHab;

   // Regime name (NOVO)
   string   regimeName;

   // Regime Semantic (INSTITUCIONAL v5.1)
   int      regimeTrendStrongBull;   // trending+bullish+strongMom+hurst>0.6+dirScore>0.5
   int      regimeTrendStrongBear;   // trending+bearish+strongMom+hurst>0.6+dirScore<-0.5
   int      regimeTrendWeakBull;     // trending+bullish+(!strongMom || hurst<0.55)
   int      regimeTrendWeakBear;     // trending+bearish+(!strongMom || hurst<0.55)
   int      regimeRangeTight;        // meanRev+lowVol+!chaos+distVWAP_ATR<0.5
   int      regimeRangeVolatile;     // meanRev+highVol+!liqSafe
   int      regimeChaos;             // chaos || volBurst || spreadAnomaly>2
   int      regimeReversalImminent;  // possRev && (trendHab || breakoutHab)
   int      regimeBreakoutForming;   // breakoutHab+volBurst+dirScore!=0

   // SL/TP at entry (NOVO)
   double   entrySL, entryTP;

   // Risk & Macro (expandido)
   double   riskScore, lotMult;
   double   vix, dxy, sp500, yield2y, yield10y;
   double   vixPctChange, dxyPctChange, sp500PctChange;
   double   yield2yPctChange, yield10yPctChange;
   double   yieldCurve;
   int      isHighVIX, riskDir;
   string   macroProfile;

   // Session (NOVO)
   string   sessionName;
   string   sessionName14;           // 14 sessões detalhadas

   // News Flags (INSTITUCIONAL v5.1)
   int      newsHighActive;          // Notícia HIGH na janela ±30min
   int      newsMediumActive;        // Notícia MEDIUM na janela ±30min
   int      minutesToNextHighNews;   // Minutos para próxima notícia HIGH
   string   blockingNewsEvent;       // Nome do evento que bloqueia (se houver)
   int      newsImpactScore;         // 0=none, 1=low, 2=medium, 3=high

   // Temporal
   int      hour, minute, dayOfWeek, weekOfMonth, month, quarter;

   // Microestrutura
   double   bid, ask, pointVal, tickVal, tickSize, contractSize;
   double   spreadAtExit;

   // Account
   double   balance, equity, freeMargin, marginLvl;
   double   ddAbsolute, ddRelative;
   int      openPos;

   // Multi-Timeframe (agora preenchido)
   double   c_m5, c_m15, c_h1, c_h4, c_d1;
   double   ret_m5, ret_m15, ret_h1, ret_h4, ret_d1;

   // MAE/MFE
   double   mfePoints, maePoints;

   // Exit
   datetime exitTime;
   double   exitPrice, grossProfit, netProfit, commission, swap;
   int      durationMin, durationBars;
   string   exitReason, outcome;
   int      catastrophic;

   // Regime at exit (NOVO)
   string   regimeAtExit;

   // Derived
   double   initialRisk, resultR, resultPct;
   double   mfeR, maeR, captureRatio;
};

class CDataMinerBuffered
{
private:
    ulong              m_magic;
    string             m_fileName;
    string             m_dataPath;
    string             m_vixSymbol;
    string             m_dxySymbol;
    int                m_catThreshold;
    CMacroRegimeEngine *m_regimePtr;
    CRiskSentiment     *m_riskPtr;
    CNewsFilter        *m_newsPtr;
    CSessionProfile    m_session;
    bool               m_enabled;

    STradeRecord_v5    m_buffer[];
    int                m_bufferSize;

    struct SActiveTrade {
       bool     isActive;
       ulong    ticket;
       double   entryPrice;
       string   direction;
       double   currentMFE;
       double   currentMAE;
       int      bufferIdx;
       double   entryCommission;
       double   entryVolume;
       double   closedVolume;
    };
   SActiveTrade m_activeTrades[];

   bool WriteAll();
   string BuildCSVLine(int idx);
   void   SnapshotRegime(STradeRecord_v5 &r);
   void   SnapshotMacro(STradeRecord_v5 &r);
   void   SnapshotMultiTF(STradeRecord_v5 &r);

public:
   CDataMinerBuffered() : m_bufferSize(0) { ArrayResize(m_buffer, 0); }
   ~CDataMinerBuffered() { WriteAll(); }

    void Init(ulong magic, string fileName, string dataPath,
              int catThreshold, CMacroRegimeEngine *regime,
              CRiskSentiment *risk);

    void SetNewsFilter(CNewsFilter *ptr);

    void OnTransaction(const MqlTradeTransaction &trans);
   void Tick();

   void FlushToDisk() { if(m_enabled) WriteAll(); }
};

void CDataMinerBuffered::Init(ulong magic, string fileName, string dataPath,
                              int catThreshold, CMacroRegimeEngine *regime,
                              CRiskSentiment *risk)
{
    m_enabled = InpEnableDataMiner;

    if(!m_enabled)
    {
        return;
    }

    m_magic = magic;
    m_fileName = fileName;
    m_dataPath = dataPath;
    m_catThreshold = catThreshold;
    m_regimePtr = regime;
    m_riskPtr = risk;
    m_newsPtr = NULL;
    m_bufferSize = 0;
    ArrayResize(m_buffer, 0);
    ArrayResize(m_activeTrades, 0);
}

void CDataMinerBuffered::SetNewsFilter(CNewsFilter *ptr)
{
   m_newsPtr = ptr;
}

void CDataMinerBuffered::SnapshotRegime(STradeRecord_v5 &r)
{
   if(m_regimePtr == NULL) return;

   m_regimePtr.Get(1);
   r.hurst = m_regimePtr.GetLastHurst();
   r.confidence_r2 = m_regimePtr.GetConfidence();
   r.strength = m_regimePtr.GetStrength();
   r.slope = m_regimePtr.GetSlope();
   r.slopeNorm = m_regimePtr.GetSlopeNormalized();
   r.dirScore = m_regimePtr.GetDirection();
   r.momState = m_regimePtr.GetMomentumState();
   r.atr = m_regimePtr.CustomATR(r.symbol, _Period, 14);
   r.distVWAP = m_regimePtr.DistanceVWAP();
   r.distVWAP_ATR = m_regimePtr.DistanceVWAP_ATR();
   r.spreadAnomaly = m_regimePtr.GetSpreadAnomaly();
   r.relVol = m_regimePtr.GetRelativeVolume();
   r.liqState = m_regimePtr.GetLiquidityState();
   r.volBurst = m_regimePtr.IsVolatilityBurst() ? 1.0 : 0.0;
   r.trending = m_regimePtr.isTrending() ? 1 : 0;
   r.meanRev = m_regimePtr.isMeanReverting() ? 1 : 0;
   r.bullish = m_regimePtr.isBullish() ? 1 : 0;
   r.bearish = m_regimePtr.isBearish() ? 1 : 0;
   r.highVol = m_regimePtr.isHighVol() ? 1 : 0;
   r.lowVol = m_regimePtr.isLowVol() ? 1 : 0;
   r.strongMom = m_regimePtr.hasStrongMomentum() ? 1 : 0;
   r.possRev = m_regimePtr.possibleReversal() ? 1 : 0;
   r.liqSafe = m_regimePtr.isLiquiditySafe() ? 1 : 0;
   r.chaos = m_regimePtr.IsChaosRegime() ? 1 : 0;
   r.trendHab = m_regimePtr.IsTrendFollowingRegime() ? 1 : 0;
   r.breakoutHab = m_regimePtr.IsBreakoutRegime() ? 1 : 0;
   r.mrHab = m_regimePtr.IsMeanReversionRegime() ? 1 : 0;
   r.regimeName = m_regimePtr.GetLabel();

   // Regime Semantic Classification (INSTITUCIONAL v5.1)
   r.regimeTrendStrongBull   = (r.trending && r.bullish && r.strongMom && r.hurst > 0.6 && r.dirScore > 0.5) ? 1 : 0;
   r.regimeTrendStrongBear   = (r.trending && r.bearish && r.strongMom && r.hurst > 0.6 && r.dirScore < -0.5) ? 1 : 0;
   r.regimeTrendWeakBull     = (r.trending && r.bullish && (!r.strongMom || r.hurst < 0.55)) ? 1 : 0;
   r.regimeTrendWeakBear     = (r.trending && r.bearish && (!r.strongMom || r.hurst < 0.55)) ? 1 : 0;
   r.regimeRangeTight        = (r.meanRev && r.lowVol && !r.chaos && r.distVWAP_ATR < 0.5) ? 1 : 0;
   r.regimeRangeVolatile     = (r.meanRev && r.highVol && !r.liqSafe) ? 1 : 0;
   r.regimeChaos             = (r.chaos || r.volBurst || r.spreadAnomaly > 2.0) ? 1 : 0;
   r.regimeReversalImminent  = (r.possRev && (r.trendHab || r.breakoutHab)) ? 1 : 0;
   r.regimeBreakoutForming   = (r.breakoutHab && r.volBurst && r.dirScore != 0.0) ? 1 : 0;
}

void CDataMinerBuffered::SnapshotMacro(STradeRecord_v5 &r)
{
   if(m_riskPtr == NULL) return;

   r.riskScore = m_riskPtr.GetRiskScore();
   r.riskDir = m_riskPtr.GetTradeDirection(r.symbol);
   r.macroProfile = m_riskPtr.GetRiskLabel();

   // Macro valores reais
   r.vix = m_riskPtr.GetVIX();
   r.dxy = m_riskPtr.GetDXY();
   r.sp500 = m_riskPtr.GetSP500();
   r.yield2y = m_riskPtr.GetYield2Y();
   r.yield10y = m_riskPtr.GetYield10Y();
   r.yieldCurve = m_riskPtr.GetYieldCurve();

   // Variação % day real
   r.vixPctChange = m_riskPtr.GetVIX_PctChange();
   r.dxyPctChange = m_riskPtr.GetDXY_PctChange();
   r.sp500PctChange = m_riskPtr.GetSP500_PctChange();
   r.yield2yPctChange = m_riskPtr.GetYield2Y_PctChange();
   r.yield10yPctChange = m_riskPtr.GetYield10Y_PctChange();

   r.isHighVIX = (r.vix > 25) ? 1 : 0;
}

void CDataMinerBuffered::SnapshotMultiTF(STradeRecord_v5 &r)
{
   string sym = r.symbol;
   r.c_m5  = iClose(sym, PERIOD_M5, 0);
   r.c_m15 = iClose(sym, PERIOD_M15, 0);
   r.c_h1  = iClose(sym, PERIOD_H1, 0);
   r.c_h4  = iClose(sym, PERIOD_H4, 0);
   r.c_d1  = iClose(sym, PERIOD_D1, 0);

   double prev_m5  = iClose(sym, PERIOD_M5, 1);
   double prev_m15 = iClose(sym, PERIOD_M15, 1);
   double prev_h1  = iClose(sym, PERIOD_H1, 1);
   double prev_h4  = iClose(sym, PERIOD_H4, 1);
   double prev_d1  = iClose(sym, PERIOD_D1, 1);

   r.ret_m5  = (prev_m5  > 0) ? (r.c_m5  - prev_m5)  / prev_m5  * 100.0 : 0;
   r.ret_m15 = (prev_m15 > 0) ? (r.c_m15 - prev_m15) / prev_m15 * 100.0 : 0;
   r.ret_h1  = (prev_h1  > 0) ? (r.c_h1  - prev_h1)  / prev_h1  * 100.0 : 0;
   r.ret_h4  = (prev_h4  > 0) ? (r.c_h4  - prev_h4)  / prev_h4  * 100.0 : 0;
   r.ret_d1  = (prev_d1  > 0) ? (r.c_d1  - prev_d1)  / prev_d1  * 100.0 : 0;
}

void CDataMinerBuffered::OnTransaction(const MqlTradeTransaction &trans)
{
    if(!m_enabled) return;

    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

    ulong dealTicket = trans.deal;
    if(dealTicket == 0) return;
    if(!HistoryDealSelect(dealTicket)) return;

    long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
    if(dealMagic != m_magic) return;

   ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   ulong posId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

   if(dealEntry == DEAL_ENTRY_IN || dealEntry == DEAL_ENTRY_INOUT)
   {
      STradeRecord_v5 record;
      record.ticket = posId;
      record.magic = m_magic;
      record.symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      record.direction = (HistoryDealGetInteger(dealTicket, DEAL_TYPE) == DEAL_TYPE_BUY) ? "BUY" : "SELL";
      record.entryTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      record.entryPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
      record.volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      record.spreadAtEntry = (double)SymbolInfoInteger(record.symbol, SYMBOL_SPREAD);

      // SL/TP da ordem
      record.entrySL = HistoryDealGetDouble(dealTicket, DEAL_SL);
      record.entryTP = HistoryDealGetDouble(dealTicket, DEAL_TP);
      record.lotMult = 1.0;

      // Snapshot Regime
      SnapshotRegime(record);

      // Snapshot Macro (VIX, DXY, SP500, yields, var%)
      SnapshotMacro(record);

      // Session name
      record.sessionName = m_session.GetActiveSessionName(record.entryTime);
      record.sessionName14 = m_session.GetActiveSessionName14(record.entryTime);

       // News Flags (INSTITUCIONAL v5.1) - via CNewsFilter (dados reais) se conectado
       if(m_newsPtr != NULL && m_newsPtr.NewsLoaded())
       {
          datetime nnow = record.entryTime;
          record.newsHighActive = m_newsPtr.IsHighNewsActiveNow(nnow) ? 1 : 0;
          record.newsMediumActive = m_newsPtr.IsMediumNewsActiveNow(nnow) ? 1 : 0;
          record.minutesToNextHighNews = m_newsPtr.MinutesToNextHighNews(nnow);
          record.blockingNewsEvent = m_newsPtr.GetActiveNewsEvent(nnow);
          record.newsImpactScore = m_newsPtr.GetNewsImpactScore(nnow);
       }
       else
       {
          // Sem CNewsFilter conectado: marca indisponivel (nao grava neutro falso como real)
          record.newsHighActive = -1;
          record.newsMediumActive = -1;
          record.minutesToNextHighNews = -1;
          record.blockingNewsEvent = "";
          record.newsImpactScore = -1;
       }

      // Temporal
      MqlDateTime dt;
      TimeToStruct(record.entryTime, dt);
      record.hour = dt.hour;
      record.minute = dt.min;
      record.dayOfWeek = dt.day_of_week;
      record.weekOfMonth = (int)MathCeil((double)dt.day / 7.0);
      record.month = dt.mon;
      record.quarter = (int)MathCeil((double)dt.mon / 3.0);

      // Microestrutura
      record.bid = SymbolInfoDouble(record.symbol, SYMBOL_BID);
      record.ask = SymbolInfoDouble(record.symbol, SYMBOL_ASK);
      record.pointVal = SymbolInfoDouble(record.symbol, SYMBOL_POINT);
      record.tickVal = SymbolInfoDouble(record.symbol, SYMBOL_TRADE_TICK_VALUE);
      record.tickSize = SymbolInfoDouble(record.symbol, SYMBOL_TRADE_TICK_SIZE);
      record.contractSize = SymbolInfoDouble(record.symbol, SYMBOL_TRADE_CONTRACT_SIZE);

      // Account + DD real
      record.balance = AccountInfoDouble(ACCOUNT_BALANCE);
      record.equity = AccountInfoDouble(ACCOUNT_EQUITY);
      record.freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      record.marginLvl = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      record.ddAbsolute = (record.balance > 0) ? (record.balance - record.equity) : 0;
      record.ddRelative = (record.balance > 0) ? ((record.balance - record.equity) / record.balance) * 100.0 : 0;
      record.openPos = PositionsTotal();

      // Multi-TF real
      SnapshotMultiTF(record);

      // Initial Risk (C4: valida entrySL>0, fallback ATR×2 documentado)
      double sl = record.entrySL;
      double priceRisk;
      if(sl > 0)
      {
         priceRisk = MathAbs(record.entryPrice - sl);
      }
      else
      {
         // SL=0 (sem stop): fallback documentado = ATR × 2.0
         // ATENÇÃO: risco real desconhecido sem stop loss definido
         priceRisk = record.atr * 2.0;
      }
      record.initialRisk = (record.tickSize > 0)
         ? priceRisk / record.tickSize * record.tickVal * record.volume
         : 0;

      // Adiciona ao buffer
      m_bufferSize++;
      ArrayResize(m_buffer, m_bufferSize);
      m_buffer[m_bufferSize - 1] = record;

       // Track para MAE/MFE
       SActiveTrade active;
       active.isActive = true;
       active.ticket = posId;
       active.entryPrice = record.entryPrice;
       active.direction = record.direction;
       active.currentMFE = 0;
       active.currentMAE = 0;
       active.bufferIdx = m_bufferSize - 1;
       active.entryCommission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
       active.entryVolume = record.volume;
       active.closedVolume = 0;

       // Inicializa acumuladores (fechamentos em multiplos deals somam)
       record.grossProfit = 0;
       record.swap = 0;
       record.commission = active.entryCommission;

       int activeSize = ArraySize(m_activeTrades);
      ArrayResize(m_activeTrades, activeSize + 1);
      m_activeTrades[activeSize] = active;
   }

    if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_INOUT)
    {
       for(int i = 0; i < ArraySize(m_activeTrades); i++)
       {
          if(m_activeTrades[i].ticket == posId && m_activeTrades[i].isActive)
          {
             int bufIdx = m_activeTrades[i].bufferIdx;

             // Acumula TODOS os deals de fechamento (fechamentos parciais/escalonados somam)
             double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
             double dealComm   = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
             double dealSwap   = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
             double dealVol    = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);

             m_buffer[bufIdx].grossProfit += dealProfit;
             m_buffer[bufIdx].commission  += dealComm;
             m_buffer[bufIdx].swap        += dealSwap;
             m_buffer[bufIdx].netProfit    = m_buffer[bufIdx].grossProfit
                                         + m_buffer[bufIdx].commission
                                         + m_buffer[bufIdx].swap;

             m_buffer[bufIdx].exitTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
             m_buffer[bufIdx].exitPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
             m_buffer[bufIdx].spreadAtExit = (double)SymbolInfoInteger(m_buffer[bufIdx].symbol, SYMBOL_SPREAD);

             m_activeTrades[i].closedVolume += dealVol;

             // Duração (C3: timeframe M5 fixo, não _Period)
             long durationSec = (long)(m_buffer[bufIdx].exitTime - m_buffer[bufIdx].entryTime);
             m_buffer[bufIdx].durationMin = (int)(durationSec / 60);
             m_buffer[bufIdx].durationBars = Bars(m_buffer[bufIdx].symbol, PERIOD_M5,
                                                   m_buffer[bufIdx].entryTime,
                                                   m_buffer[bufIdx].exitTime);

             // MAE/MFE finais
             m_buffer[bufIdx].mfePoints = m_activeTrades[i].currentMFE;
             m_buffer[bufIdx].maePoints = m_activeTrades[i].currentMAE;

             // Regime at exit
             if(m_regimePtr != NULL)
             {
                m_regimePtr.Get(1);
                m_buffer[bufIdx].regimeAtExit = m_regimePtr.GetLabel();
             }

             bool fullyClosed = (m_activeTrades[i].closedVolume >= m_activeTrades[i].entryVolume - 1e-9);

             if(fullyClosed)
             {
                // Derived metrics (só no fechamento TOTAL da posição)
                double initRisk = m_buffer[bufIdx].initialRisk;
                m_buffer[bufIdx].resultR = (initRisk > 0) ? (m_buffer[bufIdx].netProfit / initRisk) : 0;
                m_buffer[bufIdx].resultPct = (m_buffer[bufIdx].entryPrice > 0 && m_buffer[bufIdx].volume > 0)
                   ? (m_buffer[bufIdx].netProfit / (m_buffer[bufIdx].entryPrice
                      * m_buffer[bufIdx].volume * m_buffer[bufIdx].contractSize)) * 100 : 0;

                // C7: profitFactorTrade REMOVIDO (inválido por trade - só faz sentido no portfolio)

                m_buffer[bufIdx].mfeR = (initRisk > 0) ? (m_buffer[bufIdx].mfePoints / initRisk) : 0;
                m_buffer[bufIdx].maeR = (initRisk > 0) ? (m_buffer[bufIdx].maePoints / initRisk) : 0;
                // C2: captureRatio em R-múltiplos = (netProfit/initialRisk) / mfeR = resultR / mfeR
                m_buffer[bufIdx].captureRatio = (m_buffer[bufIdx].mfeR != 0)
                   ? (m_buffer[bufIdx].resultR / m_buffer[bufIdx].mfeR) : 0;

                // Exit reason
                ulong reason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
                if(reason == DEAL_REASON_SL) m_buffer[bufIdx].exitReason = "STOP_LOSS";
                else if(reason == DEAL_REASON_TP) m_buffer[bufIdx].exitReason = "TAKE_PROFIT";
                else if(reason == DEAL_REASON_EXPERT) m_buffer[bufIdx].exitReason = "EXPERT_CLOSE";
                else m_buffer[bufIdx].exitReason = "OTHER";

                // Outcome
                if(m_buffer[bufIdx].netProfit > 0.01) m_buffer[bufIdx].outcome = "WIN";
                else if(m_buffer[bufIdx].netProfit < -0.01) m_buffer[bufIdx].outcome = "LOSS";
                else m_buffer[bufIdx].outcome = "BREAKEVEN";

                // Catastrophic
                m_buffer[bufIdx].catastrophic = (m_buffer[bufIdx].maeR <= -m_catThreshold
                   || m_buffer[bufIdx].netProfit < -(initRisk * m_catThreshold)) ? 1 : 0;

                m_activeTrades[i].isActive = false;
             }
             break;
          }
       }
   }
}

void CDataMinerBuffered::Tick()
{
    if(!m_enabled) return;

    for(int i = 0; i < ArraySize(m_activeTrades); i++)
    {
       if(!m_activeTrades[i].isActive) continue;

      ulong ticket = m_activeTrades[i].ticket;
      if(PositionSelectByTicket(ticket))
      {
         double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
         double pts = (m_activeTrades[i].direction == "BUY")
            ? (currentPrice - m_activeTrades[i].entryPrice)
            : (m_activeTrades[i].entryPrice - currentPrice);

         if(pts > m_activeTrades[i].currentMFE) m_activeTrades[i].currentMFE = pts;
         if(pts < m_activeTrades[i].currentMAE) m_activeTrades[i].currentMAE = pts;
      }
   }
}

bool CDataMinerBuffered::WriteAll()
{
    if(!m_enabled) return true;
    if(m_bufferSize == 0) return true;

    string fullPath = m_dataPath + m_fileName;
   string text = "";

   // C8: Schema version header
   text += "#SCHEMA_VERSION=5.1;#COLUMNS=121;#GENERATED=" + TimeToString(TimeCurrent()) + "\r\n";

   text += "TradeID;Ticket;MagicNumber;Symbol;Direction;EntryTime;EntryPrice;Volume;SpreadAtEntry;";
   text += "Hurst;Confidence_R2;Strength;Slope;SlopeNormalized;DirectionScore;MomentumState;ATR;";
   text += "DistanceVWAP;DistanceVWAP_ATR;SpreadAnomaly;RelativeVolume;LiquidityState;VolatilityBurst;";
   text += "Trending;MeanReverting;Bullish;Bearish;HighVol;LowVol;StrongMomentum;PossibleReversal;";
   text += "LiquiditySafe;ChaosRegime;TrendFollowingHabitat;BreakoutHabitat;MeanReversionHabitat;";
   text += "RegimeName;";
   // Regime Semantic (v5.1)
   text += "RegimeTrendStrongBull;RegimeTrendStrongBear;RegimeTrendWeakBull;RegimeTrendWeakBear;";
   text += "RegimeRangeTight;RegimeRangeVolatile;RegimeChaos;RegimeReversalImminent;RegimeBreakoutForming;";
   text += "EntrySL;EntryTP;";
   text += "RiskScore;RiskDirection;LotMultiplier;";
   text += "VIX;DXY;SP500;Yield2Y;Yield10Y;";
   text += "VIX_PctChange;DXY_PctChange;SP500_PctChange;Yield2Y_PctChange;Yield10Y_PctChange;";
   text += "YieldCurve;isHighVIX;MacroProfile;";
   text += "SessionName;SessionName14;";
   // News Flags (v5.1)
   text += "NewsHighActive;NewsMediumActive;MinutesToNextHighNews;BlockingNewsEvent;NewsImpactScore;";
   text += "EntryHour;EntryMinute;DayOfWeek;WeekOfMonth;Month;Quarter;";
   text += "Bid;Ask;SpreadAtExit;PointValue;TickValue;TickSize;ContractSize;";
   text += "CurrentBalance;CurrentEquity;CurrentFreeMargin;CurrentMarginLevel;";
   text += "DDAbsolute;DDRelative;OpenPositionsCount;";
   text += "Close_M5;Close_M15;Close_H1;Close_H4;Close_D1;";
   text += "Return_M5;Return_M15;Return_H1;Return_H4;Return_D1;";
   text += "MFE_Points;MAE_Points;";
   text += "ExitTime;ExitPrice;GrossProfit;NetProfit;Commission;Swap;";
   text += "TradeDurationMinutes;TradeDurationBars;";
   text += "InitialRisk;ResultR;ResultPercent;MFE_R;MAE_R;CaptureRatio;";
   text += "ExitReason;TradeOutcome;CatastrophicTrade;";
   text += "RegimeAtExit\r\n";

    for(int i = 0; i < m_bufferSize; i++)
    {
       // Só grava trades totalmente fechados (outcome definido); posições abertas
       // no fim do teste (fechamento parcial) são ignoradas, igual ao Strategy Tester.
       if(m_buffer[i].outcome == "" || m_buffer[i].outcome == "0") continue;
       text += BuildCSVLine(i) + "\r\n";
    }

   HANDLE hFile = CreateFileW(fullPath, 0x40000000, 1|2, 0, 2, 0x80, 0);
   if(hFile == -1)
   {
      Print("[DataMiner v5] ERRO ao abrir arquivo: ", fullPath, " error: ", GetLastError());
      return false;
   }

   uchar buffer[];
   int len = StringToCharArray(text, buffer, 0, -1, CP_UTF8) - 1;

   uint written;
   int res = WriteFile(hFile, buffer, len, written, 0);
   CloseHandle(hFile);

    if(!res)
    {
       Print("[DataMiner v5] ERRO ao escrever arquivo: ", fullPath, " error: ", GetLastError());
       return false;
    }

    return true;
}

string CDataMinerBuffered::BuildCSVLine(int idx)
{
   STradeRecord_v5 r = m_buffer[idx];
   string line = "";

   line += IntegerToString(idx + 1) + ";";
   line += IntegerToString(r.ticket) + ";";
   line += IntegerToString(r.magic) + ";";   // FIXED: agora é o magic real
   line += r.symbol + ";" + r.direction + ";";
   line += TimeToString(r.entryTime) + ";";
   line += DoubleToString(r.entryPrice, 5) + ";";
   line += DoubleToString(r.volume, 2) + ";";
   // C1: SpreadAtEntry em pips (conversão pontos→pips por dígitos do símbolo)
   {
      int digits = (int)SymbolInfoInteger(r.symbol, SYMBOL_DIGITS);
      int pipFactor = (digits <= 3) ? 1 : 10;
      double spreadPips = r.spreadAtEntry / pipFactor;
      line += DoubleToString(spreadPips, 1) + ";";
   }

   // Regime contínuo
   line += DoubleToString(r.hurst, 5) + ";" + DoubleToString(r.confidence_r2, 5) + ";";
   line += DoubleToString(r.strength, 5) + ";" + DoubleToString(r.slope, 5) + ";";
   line += DoubleToString(r.slopeNorm, 5) + ";" + DoubleToString(r.dirScore, 5) + ";";
   line += DoubleToString(r.momState, 5) + ";" + DoubleToString(r.atr, 5) + ";";
   line += DoubleToString(r.distVWAP, 5) + ";" + DoubleToString(r.distVWAP_ATR, 5) + ";";
   line += DoubleToString(r.spreadAnomaly, 5) + ";" + DoubleToString(r.relVol, 5) + ";";
   line += DoubleToString(r.liqState, 5) + ";" + DoubleToString(r.volBurst, 5) + ";";

   // Regime booleano
   line += IntegerToString(r.trending) + ";" + IntegerToString(r.meanRev) + ";";
   line += IntegerToString(r.bullish) + ";" + IntegerToString(r.bearish) + ";";
   line += IntegerToString(r.highVol) + ";" + IntegerToString(r.lowVol) + ";";
   line += IntegerToString(r.strongMom) + ";" + IntegerToString(r.possRev) + ";";
   line += IntegerToString(r.liqSafe) + ";" + IntegerToString(r.chaos) + ";";
   line += IntegerToString(r.trendHab) + ";" + IntegerToString(r.breakoutHab) + ";";
   line += IntegerToString(r.mrHab) + ";";

   // Regime name
   line += r.regimeName + ";";

   // Regime Semantic (v5.1)
   line += IntegerToString(r.regimeTrendStrongBull) + ";" + IntegerToString(r.regimeTrendStrongBear) + ";";
   line += IntegerToString(r.regimeTrendWeakBull) + ";" + IntegerToString(r.regimeTrendWeakBear) + ";";
   line += IntegerToString(r.regimeRangeTight) + ";" + IntegerToString(r.regimeRangeVolatile) + ";";
   line += IntegerToString(r.regimeChaos) + ";" + IntegerToString(r.regimeReversalImminent) + ";";
   line += IntegerToString(r.regimeBreakoutForming) + ";";

   // SL/TP
   line += DoubleToString(r.entrySL, 5) + ";" + DoubleToString(r.entryTP, 5) + ";";

   // Risk & Macro
   line += DoubleToString(r.riskScore, 5) + ";" + IntegerToString(r.riskDir) + ";";
   line += DoubleToString(r.lotMult, 5) + ";";

   // Macro valores reais
   line += DoubleToString(r.vix, 2) + ";" + DoubleToString(r.dxy, 2) + ";";
   line += DoubleToString(r.sp500, 2) + ";" + DoubleToString(r.yield2y, 4) + ";";
   line += DoubleToString(r.yield10y, 4) + ";";

   // Macro var% day
   line += DoubleToString(r.vixPctChange, 2) + ";" + DoubleToString(r.dxyPctChange, 2) + ";";
   line += DoubleToString(r.sp500PctChange, 2) + ";" + DoubleToString(r.yield2yPctChange, 2) + ";";
   line += DoubleToString(r.yield10yPctChange, 2) + ";";

   // Yield curve + VIX
   line += DoubleToString(r.yieldCurve, 4) + ";" + IntegerToString(r.isHighVIX) + ";";
   line += r.macroProfile + ";";

   // Session (v5.1: SessionName + SessionName14)
   line += r.sessionName + ";" + r.sessionName14 + ";";

   // News Flags (v5.1)
   line += IntegerToString(r.newsHighActive) + ";" + IntegerToString(r.newsMediumActive) + ";";
   line += IntegerToString(r.minutesToNextHighNews) + ";" + r.blockingNewsEvent + ";";
   line += IntegerToString(r.newsImpactScore) + ";";

   // Temporal
   line += IntegerToString(r.hour) + ";" + IntegerToString(r.minute) + ";";
   line += IntegerToString(r.dayOfWeek) + ";" + IntegerToString(r.weekOfMonth) + ";";
   line += IntegerToString(r.month) + ";" + IntegerToString(r.quarter) + ";";

   // Microestrutura
   line += DoubleToString(r.bid, 5) + ";" + DoubleToString(r.ask, 5) + ";";
   line += DoubleToString(r.spreadAtExit, 0) + ";";
   line += DoubleToString(r.pointVal, 5) + ";" + DoubleToString(r.tickVal, 5) + ";";
   line += DoubleToString(r.tickSize, 5) + ";" + DoubleToString(r.contractSize, 5) + ";";

   // Account + DD
   line += DoubleToString(r.balance, 2) + ";" + DoubleToString(r.equity, 2) + ";";
   line += DoubleToString(r.freeMargin, 2) + ";" + DoubleToString(r.marginLvl, 2) + ";";
   line += DoubleToString(r.ddAbsolute, 2) + ";" + DoubleToString(r.ddRelative, 2) + ";";
   line += IntegerToString(r.openPos) + ";";

   // Multi-TF real
   line += DoubleToString(r.c_m5, 5) + ";" + DoubleToString(r.c_m15, 5) + ";";
   line += DoubleToString(r.c_h1, 5) + ";" + DoubleToString(r.c_h4, 5) + ";";
   line += DoubleToString(r.c_d1, 5) + ";";
   line += DoubleToString(r.ret_m5, 4) + ";" + DoubleToString(r.ret_m15, 4) + ";";
   line += DoubleToString(r.ret_h1, 4) + ";" + DoubleToString(r.ret_h4, 4) + ";";
   line += DoubleToString(r.ret_d1, 4) + ";";

   // MAE/MFE (sem duplicatas)
   line += DoubleToString(r.mfePoints, 5) + ";" + DoubleToString(r.maePoints, 5) + ";";

   // Exit
   line += TimeToString(r.exitTime) + ";" + DoubleToString(r.exitPrice, 5) + ";";
   line += DoubleToString(r.grossProfit, 2) + ";" + DoubleToString(r.netProfit, 2) + ";";
   line += DoubleToString(r.commission, 2) + ";" + DoubleToString(r.swap, 2) + ";";
   line += IntegerToString(r.durationMin) + ";" + IntegerToString(r.durationBars) + ";";

   // Derived (C7: profitFactorTrade REMOVIDO)
   line += DoubleToString(r.initialRisk, 5) + ";" + DoubleToString(r.resultR, 5) + ";";
   line += DoubleToString(r.resultPct, 5) + ";";
   line += DoubleToString(r.mfeR, 5) + ";" + DoubleToString(r.maeR, 5) + ";";
   line += DoubleToString(r.captureRatio, 5) + ";";

   // Exit info
   line += r.exitReason + ";" + r.outcome + ";" + IntegerToString(r.catastrophic) + ";";

   // Regime at exit
   line += r.regimeAtExit;

   return line;
}
