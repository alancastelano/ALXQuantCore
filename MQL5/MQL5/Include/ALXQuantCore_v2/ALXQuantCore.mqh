//+------------------------------------------------------------------+
//|                                               ALXQuantCore.mqh    |
//|                     Copyright 2026, ALXQuantCore Ltd.             |
//|                       Orquestrador do Framework v2                |
//|                                                                   |
//| v10.4.0 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      ""
#property version "10.4"
/*
    v.10.4.0 - 2026-09-06 - Refactor: TimeFilter + NewsFilter split into CTimeFilter + CNewsFilter.
                            Both classes declare their own inputs (no EA wiring needed).
                            CNewsFilter: FF CSV download, CSV fallback, GlobalVariable fallback.
                            Timezone auto-detect (live) + manual (tester).
    v.10.3.0 - 2026-09-06 - Refactor: Commission extracted to CCommission class (Commission.mqh).
                            enCommMode, inputs, state, and all commission functions removed.
                            Traling() now takes commFloor parameter (no internal CommissionDist call).
                            EA must declare commission inputs and pass to CCommission::Init().
    v.10.2.0 - 2026-08-25 - Add: Panel integration with StatsTracker & AccountProtector.
                           CPanel fully wired: Init + DrawDashboard with live data.
                           CStatsTracker added: Update() + GetAssetStats()/GetPerfStats().
                           CAccountProtector added: Equity Guard (PRESET_MONETA_INSTANT).
                           CTimefilter added: News/Time filters with visual updates.
                           Inputs: InpMaxSpreadPips, InpEquityGuardDD.
                           DrawDashboard now uses live data (Hurst, R2, Regime, Execution stats, Asset/Perf stats).
    v.10.1.2 - 2026-08-25 - Fix: Lot mode wiring (InpLotMode -> m_exec.SetLotMode). Previously hardcoded lot_risk ignored fix/min.
                           Remove lot/risk jitter from HumanBehavior (GetLotJitter, GetRiskMultiplier removed).
                           Lot sizing now fully deterministic per InpLotMode (fix/min/risk).
    v.10.1.1 - 2026-08-25 - Refactor: Input rename Tral→InpTrailingStop, TralStart→InpTrailingActivate (Inp* standard).
                           All input descriptions standardized to English. No functional change.
    v.10.1 - 2026-08-25 - Add: Commission-aware TP/trailing (net of commission measured via DEAL_COMMISSION).
                           enCommMode (In/Out|OutOnly), input commission $/lot (0=off), buffer $/lot.
                           ProfitNet/ProfitNetAll functions, CommissionDist/Total/Measure from DEAL_COMMISSION history.
                           Traling() floors breakeven at openPrice ± (TralStart + commissionDist).
                           ProfitAll() fixed: removed deprecated POSITION_COMMISSION.
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.2.00 - 2026-08-03 - Add: Orquestrador ALXQuantCore v2 (framework)
                           - Centraliza globais comuns (sets, modulos, trades)
                           - Wiring de ponteiros (regime/risk -> exec/miner)
                           - API: Init/OnTick/OnTimer/OnDeinit/OnTradeTransaction
    v.2.01 - 2026-08-06 - Fix: includes do orquestrador apontavam para modulos
                           antigos (ALXQuantCore\Core\Design, TrailingStop, Telegram,
                           Modules\DataMiner/RiskManager/Execution, Core\Timefilter)
                           enquanto enums.mqh e Panel.mqh vinham da versao v2,
                           causando redeclaracao de 'enLotMode' e ausencia de
                           'SetLotMode' em Execution.mqh antigo.
                            Normalizado: todos os modulos agora vem de ALXQuantCore.
    v.2.10 - 2026-08-06 - Change: OnTick() dividido em PreProcess() e
                           PostProcess(). O EA roda a estratégia ENTRE os
                           dois: framework.PreProcess() -> sinais do EA ->
                           framework.PostProcess(). OnTick() vira alias.
    v.2.20 - 2026-08-07 - Add: Comentário de ordens via framework.
                           GetComment()/SetEAVersion()/RefreshComment().
                           InpComment preenchido => usa; vazio => auto
                           "<ea_name>_<ea_version>_SUGESTAO".
    v.2.21 - 2026-08-07 - Change: RiskManager substituido por CAccountProtector
                            no wiring do orquestrador (protecao de conta inteira,
                            preset ALXQuant). sets.IsRiskAllowed = !IsTriggered().
    v.2.22 - 2026-08-07 - Fix: compilacao no stack nao-_v2 (InpLotMode2->enLotMode,
                            switch lot_fixed/lot_balance, Panel sem _v2,
                            comentarios stale). FRAMEWORK_VERSION v2.2.1.
    v.2.23 - 2026-08-13 - Fix: #include Execution.mqh movido para antes do grupo
                            "3. Position Size" (enLotMode agora vem deste modulo,
                            nao mais de Core\enums.mqh) - mantem o stack nao-_v2 compilavel.
*/
//+------------------------------------------------------------------+
//| Versao do framework                                              |
//+------------------------------------------------------------------+
const string FRAMEWORK_VERSION = "v10.2.0";

//+------------------------------------------------------------------+
//| DEBUG_MODE (guard)                                               |
//+------------------------------------------------------------------+
#ifndef DEBUG_MODE
#define DEBUG_MODE false
#endif


enum enEALotMode
  {
   fix=0,   // Lot fix
   min=1,   // Lot minimal
   risk=2,  // Lot Risk (%)
  };


//+------------------------------------------------------------------+
//| #Include - API MQL5                                              |
//+------------------------------------------------------------------+
#include <Trade\PositionInfo.mqh>  // trade position object
#include <Trade\Trade.mqh>         // trading object
#include <Trade\SymbolInfo.mqh>    // symbol info object
#include <Trade\AccountInfo.mqh>   // account info wrapper
#include <Trade\DealInfo.mqh>      // deals object
#include <Trade\OrderInfo.mqh>     // pending orders object
#include <ALXQuantCore\Core\enums.mqh>
#include <ALXQuantCore\Core\Core.mqh>

   CCore          m_core;
   CPositionInfo  m_position;
   CTrade         m_trade;
   CSymbolInfo    m_symbol;
   CAccountInfo   m_account;


//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group                "➜ EA Config"
input string               InpSetDescription       = "";              // Set description
input int                  InpTime                 = 10;              // Timer refresh interval (seconds)
input ENUM_TIMEFRAMES      InpEATimeframe          = PERIOD_M1;       // EA timeframe (validated in Init)
input int                  InpMaxSpreadPips        = 30;              // Max spread (pips, 0=off)
input int                  InpMaxSlippage          = 30;              // Max slippage (points)
//+------------------------------------------------------------------+  
input group                "➜ Position Size"
input enEALotMode          InpLotMode              = risk;            // Lot mode: Fixed / Min / Risk%
input double               InpLotValue             = 0.1;             // Lot value (fixed) or risk % (risk mode)
input double               InpStopLossPerc         = 0.8;             // Global Stop Loss % of equity (gross, 0=off)
input int                  InpTakeProfit           = 25;              // Global Take Profit per lot, NET of commission (USD)
//+------------------------------------------------------------------+  
input group                "➜ Trailing Stop"
input double               InpTrailingStop         = 12.0;            // Trailing distance (points, raw Point)
input double               InpTrailingActivate     = 6.0;             // Trailing activation above entry (points)
//+------------------------------------------------------------------+  
//input group                "➜ Time filter"
//input int                  InpTimeStart          = 2;               // Session start hour (0-23, server time)
//input int                  InpTimeEnd            = 19;              // Session end hour (0-23, server time)
//input bool                 InpTradeFriday        = true;            // Allow trading on Friday
//+------------------------------------------------------------------+  
input group                "➜ Strategy"
input double               PipsStep                = 26.0;            // Entry step (pips)

//+------------------------------------------------------------------+
//| Inputs de comissão migrados para Commission.mqh                  |
//| (enum enCommMode + InpCommMode/InpCommissionUSDperLot/InpCommBufferUSDperLot) |
//| O EA declara os inputs e passa para CCommission::Init()           |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------
#include <ALXQuantCore\Modules\HumanBehavior.mqh>     HumanBehavior        g_human;
#include <ALXQuantCore\Modules\MacroRegimeEngine.mqh> CMacroRegimeEngine   m_regime;
#include <ALXQuantCore\Modules\RiskSentiment.mqh>     CRiskSentiment       m_risk_sentiment;
#include <ALXQuantCore\Modules\SessionProfile.mqh>    CSessionProfile      m_session_profile;
#include <ALXQuantCore\Modules\DataMiner.mqh>         CDataMinerBuffered   m_miner;
#include <ALXQuantCore\Modules\Execution.mqh>         CExecution           m_exec;
#include <ALXQuantCore\Modules\StatsTracker.mqh>      CStatsTracker        m_stats;
#include <ALXQuantCore\Modules\AccountProtector.mqh>  CAccountProtector    m_protector;
#include <ALXQuantCore\Core\Timefilter.mqh>           CTimeFilter          m_timefilter;
#include <ALXQuantCore\Core\NewsFilter.mqh>           CNewsFilter          m_newsfilter;
#include <ALXQuantCore\Core\Panel.mqh>                CPanel               m_panel;
#include <ALXQuantCore\Core\Design.mqh>               CDesign              m_design;


//+------------------------------------------------------------------+
//| # Variáveis Globais                                              |
//+------------------------------------------------------------------+
   struct Setting
   {
      string   m_ea_name;
      string   m_ea_version;
      ulong    m_magic;
      int      m_max_slippage;
      string   m_comment;
      double   m_adjusted_point;
      double   ExtStopLoss;
      double   ExtTakeProfit;
      double   ExtBreakeven;
      double   ExtTrailingStop;
      double   ExtTrailingStep;
      double   freeze_level;
      double   stop_level;
      int      digits_adjust;
      string   m_status;
      
      datetime m_last_trade_bar_time; 
      int      count_buys;
      int      count_sells;
      int      count_total;
      double   long_lot;
      double   short_lot;
      
      double   price_open;
      datetime time_open;
      datetime time_new;
      double   cached_step_points;       
      datetime last_bar_time;             
      
      bool     IsTimeAllowed;
      bool     IsNewsAllowed;
      bool     IsRiskAllowed;
      bool     IsBusy;
      int      Isglobal_risk;
      double   Isglobal_risk_factor;
      bool     m_can_open_trade;
      
int      market_direction;
       int      combined_dir;

    } sets;



class CALXQuantCore
  {
public:
                     CALXQuantCore()  { ZeroMemory(sets); }
                    ~CALXQuantCore()  {}

   //--- Ciclo de vida
   bool             Init(string ea_name, string ea_version);
   void             OnTick(void);
   void             PreProcess(void);
   void             PostProcess(void);
   void             OnTimer(void);
   void             OnDeinit(const int reason);
   void             OnTradeTransaction(const MqlTradeTransaction &trans,
                                       const MqlTradeRequest &request,
                                       const MqlTradeResult &result);

   //--- Getters (conveniencia para o EA / estrategias)
   //ulong            GetMagic(void)          { return sets.m_magic;          }
   //string           GetSymbol(void)         { return m_symbol.Name();       }
   //double           GetAdjustedPoint(void)  { return sets.m_adjusted_point; }
   //uchar            GetMaxSlippage(void)    { return sets.m_max_slippage;   }
   //bool             CanOpenTrade(void)      { return sets.m_can_open_trade; }
   //int              GetCombinedDir(void)    { return sets.combined_dir;     }
   //int              GetGlobalRisk(void)     { return sets.Isglobal_risk;    }
   //bool             GetIsTime(void)         { return sets.IsTimeAllowed;    }
   //bool             GetIsNews(void)         { return sets.IsNewsAllowed;    }
   //bool             GetIsRisk(void)         { return sets.IsRiskAllowed;    }
   //bool             GetIsBusy(void)         { return sets.IsBusy;           }

   //--- Comentário de ordens (InpComment ou auto "<ea>_<ver>_SUGESTAO")
   //string           GetComment(void)        { return sets.m_comment;        }
   //void             SetEAVersion(const string v)
   //   {
   //    sets.m_ea_version = v;
   //    RefreshComment();
   //   }

protected:
//---
//---


   //--- Helpers internos
   ulong            AutoMagicID(void);


   void             CalculateAllPositions(void);
   void             DailyResetCounters(void);
   void             RefreshComment(void);
  };


//+------------------------------------------------------------------+
//| Init - inicializa todos os modulos (wiring de ponteiros)          |
//+------------------------------------------------------------------+
bool CALXQuantCore::Init(string ea_name, string ea_version)
  {
//--- Validação do timeframe
   if(InpEATimeframe != PERIOD_CURRENT && _Period != (int)InpEATimeframe)
     {
      PrintFormat("Timeframe inválido. Atual: %s | Esperado: %s",EnumToString(_Period),EnumToString(InpEATimeframe));
      return(false);
    }
//---
   EventSetTimer(InpTime);
//---
   if(!m_symbol.Name(_Symbol)) return(false);
   if(!RefreshRates()) return(false);
//---
   sets.m_ea_name       = ea_name;
   sets.m_ea_version    = ea_version;
   sets.m_magic         = m_core.AutoMagicID(sets.m_ea_name, sets.m_ea_version);
   sets.m_max_slippage  = InpMaxSlippage; 
   sets.m_comment       = m_core.GenerateRegimeComment();
   sets.time_open       = 1; 
   sets.time_new        = 0;
   sets.digits_adjust   = 1;
   sets.cached_step_points = 22.0;       
   sets.last_bar_time   = 0;             
   sets.m_last_trade_bar_time = 0;
   
   m_trade.LogLevel(LOG_LEVEL_NO);
   m_trade.SetExpertMagicNumber(sets.m_magic);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(m_symbol.Name());
   m_trade.SetDeviationInPoints(sets.m_max_slippage);
   
   if(m_symbol.Digits()==3 || m_symbol.Digits()==5)
       sets.digits_adjust = 10;
    sets.m_adjusted_point = m_symbol.Point() * sets.digits_adjust;

    //--- Commission initialization removed — now handled by CCommission::Init()
    //--- (EA calls m_framework.Init() with commission inputs)

    // Inicialização dos Módulos
    m_regime.Init(InpDFAPeriod, InpDFA_min_scale, InpDFA_max_scale, InpRegimeTimeframe);
    m_panel.Init(sets.m_ea_name,sets.m_ea_version);
    m_risk_sentiment.Init();
    g_human.Init();
    
    // StatsTracker
    m_stats.Init(_Symbol, sets.m_magic);
    
    // AccountProtector (Equity Guard)
    m_protector.SetPreset(PRESET_MONETA_INSTANT);
    m_protector.Init();
    
    // Timefilter (News + Time)
    m_timefilter.Init();
    m_newsfilter.Init();
   
    m_panel.Init(sets.m_ea_name,sets.m_ea_version,"_rc1");
    
    
    string fileName = sets.m_ea_name + "_" + _Symbol + "_miner.csv";
        m_miner.Init(sets.m_magic, fileName, InpDataMinerPath, InpCatThreshold, &m_regime, &m_risk_sentiment);
        
        // CExecution Engine
        m_exec.Init(_Symbol, sets.m_magic, 3, 100, 5000, &m_regime);
        // Map InpLotMode (fix=0, min=1, risk=2) -> Execution enLotMode (lot_min=0, lot_fixed=1, lot_balance=2, lot_risk=3)
        enLotMode execLotMode;
        switch(InpLotMode)
        {
           case fix:   execLotMode = lot_fixed;   break;
           case min:   execLotMode = lot_min;     break;
           case risk:  execLotMode = lot_risk;    break;
           default:    execLotMode = lot_risk;    break;
        }
        m_exec.SetLotMode(execLotMode);
        m_exec.SetLotValue(InpLotValue);
        m_exec.SetSLMode(SL_ATR);
        m_exec.SetSLValue(2.0);
        m_exec.SetTPMode(TP_RISK_REWARD);
        m_exec.SetTPValue(2.0);
        m_exec.SetTrailMode(TRAIL_ATR);
        m_exec.SetTrailDistance(100.0);
        m_exec.SetTrailStep(50.0);
  
   m_design.Init();      

   return(true);
}

//+------------------------------------------------------------------+
//| OnTimer - dashboard + sessões + notícias                          |
//+------------------------------------------------------------------+
void CALXQuantCore::OnTimer(void)
{
   // Update StatsTracker
   m_stats.Update();
   
   // Get stats for panel
   AssetStats as;
   PerfStats ps;
   m_stats.GetAssetStats(as);
   m_stats.GetPerfStats(ps);
   
   // Draw Dashboard with real data
   //if(InpMaxSpreadPips > 0 || InpEquityGuardDD > 0)
   //{
      m_panel.DrawDashboard(
         sets.m_magic,
         m_regime.GetLabel(),           // trendStr
         "",                            // volStr (not available)
         "",                            // momStr (not available)
         m_regime.GetLastHurst(),       // H
         m_regime.GetConfidence(),      // R2
         sets.IsTimeAllowed,
         sets.IsNewsAllowed,
         m_timefilter.GetBlockReasonText(),
         sets.IsRiskAllowed,
         !m_protector.IsTriggered(),    // equityGuardSafe
         InpMaxSpreadPips,              // maxSpreadPips
         sets.m_max_slippage,           // maxSlippagePts
         as, ps
      );
   //}
   
}


//+------------------------------------------------------------------+
//| OnDeinit - limpeza                                                |
//+------------------------------------------------------------------+
void CALXQuantCore::OnDeinit(const int reason)
  {
   Comment("");

   EventKillTimer();
   ObjectsDeleteAll(0, 0, OBJ_LABEL);
   ObjectsDeleteAll(0, 0, OBJ_RECTANGLE_LABEL);
   //m_design.DeleteTradeLines("alx_");
   m_miner.FlushToDisk();
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction - encaminha para os modulos                    |
//+------------------------------------------------------------------+
void CALXQuantCore::OnTradeTransaction(const MqlTradeTransaction &trans,
                                       const MqlTradeRequest &request,
                                       const MqlTradeResult &result)
  {
   m_miner.OnTransaction(trans);
   m_exec.ProcessTradeTransaction(trans, request, result);
  }






bool IsNewsBlocked(void)
{
   bool InpNewsBlockIfNoGlobal =  false;
   if(!GlobalVariableCheck("NI_CAN_TRADE"))
      return InpNewsBlockIfNoGlobal;   // false = opera livre sem news EA

   return (GlobalVariableGet("NI_CAN_TRADE") < 0.5);
}

bool IsTimeFilter(void)
{
   return m_timefilter.IsTimeTrade();
}

void ClosePos()
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
            lot += PositionGetDouble(POSITION_VOLUME);
      }
   }
   return lot;
}

int Count(int type)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == sets.m_magic) 
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL)) 
            count++;
      }
   }
   return count;
}

void Traling(double commFloor = 0.0)
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

         if(posType == POSITION_TYPE_BUY && InpTrailingStop != 0)
         {
            double firstLockPrice = NormalizeDouble(openPrice + InpTrailingActivate * Point + commFloor, digits);
            double trailPrice     = NormalizeDouble(Bid - InpTrailingStop * Point, digits);
            
            // First lock: cost floor (real breakeven)
            if((currentSL < openPrice || currentSL == 0) && Bid - (InpTrailingStop + InpTrailingActivate) * Point >= openPrice + commFloor)
               m_trade.PositionModify(ticket, firstLockPrice, currentTP);
            
            // Subsequent steps: only move if above cost floor
            if(currentSL >= openPrice + commFloor && trailPrice > currentSL)
               m_trade.PositionModify(ticket, trailPrice, currentTP);
         }

         if(posType == POSITION_TYPE_SELL && InpTrailingStop != 0)
         {
            double firstLockPrice = NormalizeDouble(openPrice - InpTrailingActivate * Point - commFloor, digits);
            double trailPrice     = NormalizeDouble(Ask + InpTrailingStop * Point, digits);
            
            if((currentSL > openPrice || currentSL == 0) && Ask + (InpTrailingStop + InpTrailingActivate) * Point <= openPrice - commFloor)
               m_trade.PositionModify(ticket, firstLockPrice, currentTP);
            
            if(currentSL <= openPrice - commFloor && trailPrice < currentSL)
               m_trade.PositionModify(ticket, trailPrice, currentTP);
         }
      }
   }
}

double Profit(int type) 
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) 
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == sets.m_magic) 
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL)) 
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }
   return profit;
}

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
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }
   return profit;
}

//--- Commission functions removed — now in CCommission class (Commission.mqh)

//+------------------------------------------------------------------+
//| Refreshes the symbol quotes data                                 |
//+------------------------------------------------------------------+
bool RefreshRates(void)
  {
//--- refresh rates
   if(!m_symbol.RefreshRates())
      return(false);
//--- check for invalid price
   if(m_symbol.Ask()==0 || m_symbol.Bid()==0)
      return(false);
//---
   return(true);
  }



































/*
//+------------------------------------------------------------------+
//| #Include - ALXQuantCore v2 (ordem de dependencia)                |
//| 1. enums.mqh primeiro (tipos ENUM_ALX_* para os inputs)          |
//| 2. Inputs de UI ANTES de Design.mqh (DrawTradeLine usa InpUI_lines)
//| 3. Design, TrailingStop, Telegram (auto-contidos)                |
//| 4. DataMiner puxa MacroRegimeEngine + RiskSentiment + SessionProfile
//| 5. RiskManager, Execution, Timefilter                            |
//| 6. Panel.mqh SO DEPOIS dos globais (usa sets/m_regime/m_exec)    |
//+------------------------------------------------------------------+




//--- DataMiner: trace MacroRegimeEngine + RiskSentiment + SessionProfile

//+------------------------------------------------------------------+
//| #Inputs - EA Config                                               |
//+------------------------------------------------------------------+
input group             "▸ 1. EA Config"
input ENUM_TIMEFRAMES   InpEATimeframe                          = PERIOD_M5;            //.   1.1   EA Timeframe
input int               InpMaxSpread                            = 30;                   //.   1.2   Max spread (points, 0=off)
input int               InpMaxSlippage                          = 0;                    //.   1.3   Max slippage (points, 0=off)
input string            InpComment                              = "";                   //.   1.4   EA comment (""=auto)
input string            InpDataMinerFile                        = "data_miner_xauusd.csv"; //. 1.3   DataMiner output filename
input string            InpDataMinerPath                        = "C:\\ALXQuant\\data\\"; //. 1.4   DataMiner output directory
#include <ALXQuantCore\Modules\DataMiner.mqh>
#include <ALXQuantCore\Modules\Execution.mqh>
//+------------------------------------------------------------------+
//| #Inputs - Market Regime Engine                                    |
//+------------------------------------------------------------------+
input group             "▸ 2. Market Regime Engine"
input int               InpDFAPeriod                            = 200;                  //.   2.1   DFA period
input int               InpDFA_min_scale                        = 4;                    //.   2.2   DFA min scale
input int               InpDFA_max_scale                        = 60;                   //.   2.3   DFA max scale

//+------------------------------------------------------------------+
//| #Inputs - Position Size (Execution)                               |
//+------------------------------------------------------------------+
input group             "▸ 3. Position Size"
input enLotMode          InpLotMode2                             = lot_risk;             //.   3.1   Lot mode
input double            InpLotValueFix                          = 0.10;                 //.   3.2   Lot value fix (LOT_FIXED mode)
input double            InpMaxRiskUSD                           = 180.0;                //.   3.3   Max risk $ per trade (0=off)
input ushort            InpStopLoss                             = 800;                  //.   3.4   Stop Loss (pips)
input double            InpTradeRiskPct                         = 0.5;                  //.   3.5   Risk % equity per trade
input double            InpKellyFraction                        = 0.25;                 //.   3.6   Kelly fraction (0=off)
input int               InpMinKellyTrades                       = 20;                   //.   3.7   Min trades for Kelly

//+------------------------------------------------------------------+
//| #Inputs - Stop Loss / Take Profit / Breakeven / Trailing          |
//+------------------------------------------------------------------+
input group             "▸ 4. Stop Loss"
input ENUM_ALX_SL_MODE  InpSLMode                               = SL_ATR;               // SL mode
input double            InpSLValue                              = 2.0;                  // SL fixed (pips)
input group             "▸ 5. Take Profit"
input ENUM_ALX_TP_MODE  InpTPMode                               = TP_RISK_REWARD;       // TP mode
input double            InpTPRatio                              = 2.0;                  // TP R:R ratio
input double            InpTPFixed                              = 300;                  // TP fixed (pips)
input double            InpTPADR                                = 0.5;                  // TP ADR multiple
input group             "▸ 6. Breakeven"
input ENUM_ALX_BE_MODE  InpBEMode                               = BE_ATR;               // BE mode
input double            InpBEValue                              = 0.8;                  // BE fixed (pips)
input group             "▸ 7. Trailing Stop"
input ENUM_ALX_TRAIL_MODE InpTrailMode                          = TRAIL_FIXED;          // Trailing mode
input double            InpTrailFixed                           = 160;                  // Trailing distance (pips)
input double            InpTrailATR                             = 0.8;                  // Trailing ATR multiple
input double            InpTrailStepFixed                       = 80;                   // Trailing step (pips)
input double            InpTrailStepATR                         = 0.4;                  // Trailing step ATR multiple
//+------------------------------------------------------------------+
#include <ALXQuantCore\Modules\AccountProtector.mqh>
#include <ALXQuantCore\Core\Timefilter.mqh>
#include <ALXQuantCore\Core\Design.mqh>
#include <ALXQuantCore\Core\TrailingStop.mqh>

//+------------------------------------------------------------------+
//| #Inputs - UI (declarados aqui: Design.DrawTradeLine exige        |
//|            InpUI_lines antes do #include de Design.mqh)          |
//+------------------------------------------------------------------+
input group             "== ALXQuant UI =="
input bool              InpUI_panel                            = true;                 // UI Panel
input bool              InpUI_lines                            = true;                 // UI Lines: Open/SL/TP
input bool              InpUI_print_debug                      = false;                // UI Print debug
input bool              InpProfilerEnabled                     = false;                // Profile OnTick sections (us)


#include <ALXQuantCore\Core\Telegram.mqh>




//+------------------------------------------------------------------+
//| GLOBAIS COMUNS - Setting                                          |
//| Estado compartilhado entre o EA e os modulos (Panel usa:         |
//| Isglobal_risk, Isglobal_risk_factor, combined_dir).              |
//+------------------------------------------------------------------+
struct Setting
   {
   string   m_ea_name;
   string   m_ea_version;
//---
   ulong    m_magic;
   uchar    m_max_slippage;
   string   m_comment;
   double   m_adjusted_point;
   double   ExtStopLoss;
   double   ExtBreakeven;
   double   ExtTrailingStop;
   double   ExtTrailingStep;
   double   freeze_level;
   double   stop_level;
   int      digits_adjust;
   string   m_status;
//--
//-- Position Manager
   datetime m_last_trade_bar_time; //--- CONTROLE DE VELA (Uma entrada por candle)
   uint     count_buys;
   uint     count_sells;
   uint     count_total;
   double   long_lot;
   double   short_lot;
//--
   bool     IsTimeAllowed;
   bool     IsNewsAllowed;
   bool     IsRiskAllowed;
   bool     IsBusy;
   int      Isglobal_risk;
   double   Isglobal_risk_factor;
   bool     m_can_open_trade;
//---
//--- STATE REGIME
   int      market_direction;
   int      combined_dir;      // 0=Ambos, 1=Buy, -1 Sell, 99=Bloqueado
//---
//--- CONTADORES DIARIOS
   datetime m_current_day;
   int      m_daily_trades_TF;
   int      m_daily_trades_BK;
   int      m_daily_trades_SB;
   int      m_daily_trades_MR;
//---
//--- Variáveis de Profiling
   ulong    t1;
   ulong    time_process_total;
   ulong    time_update_total;
   ulong    time_levels_total;
   ulong    time_regime_total;
   ulong    time_filters_total;
   ulong    time_strategy_total;
   ulong    time_trailing_total;
   ulong    profiler_ticks;
   ulong    g_total_market_ticks;
   };
Setting sets;

//+------------------------------------------------------------------+
//| Objetos MQL5 nativos (globais p/ EA + estrategias + Panel)        |
//+------------------------------------------------------------------+
CPositionInfo  m_position;
CTrade         m_trade;
CSymbolInfo    m_symbol;
CAccountInfo   m_account;
CDealInfo      m_deal;
COrderInfo     m_order;

//+------------------------------------------------------------------+
//| Instancias dos modulos (globais comuns entre as classes)          |
//+------------------------------------------------------------------+
CDesign              m_design;
CMacroRegimeEngine   m_regime;
CRiskSentiment         m_risksentiment;
CAccountProtector      m_protector;
CExecution             m_exec;
CDataMinerBuffered   m_miner;
CTimeFilter          m_timefilter;
CNewsFilter          m_newsfilter;
CTrailingStop        m_trailing;
CTelegram            m_telegram(m_token, m_chat_id);

//+------------------------------------------------------------------+
//| Panel.mqh usa os globais acima (sets/m_regime/m_exec) ->         |
//| incluido SOMENTE depois deles estarem declarados.                |
//+------------------------------------------------------------------+
#include <ALXQuantCore\Core\Panel.mqh>
CPanel               m_panel;

//+------------------------------------------------------------------+
//| Classe principal do framework                                    |
//|                                                                  |
//| Uso no EA:                                                       |
//|   int OnInit()  { return framework.Init() ? INIT_SUCCEEDED : INIT_FAILED; }
//|   void OnTick() { framework.OnTick(); /* sinais               |
//|   void OnTimer(){ framework.OnTimer(); }                         |
//|   void OnDeinit(const int reason){ framework.OnDeinit(reason); } |
//|   void OnTradeTransaction(...){ framework.OnTradeTransaction(trans, request, result); }
//+------------------------------------------------------------------+
/*

class CALXQuantCore
  {
public:
                     CALXQuantCore()  {}
                    ~CALXQuantCore()  {}

   //--- Ciclo de vida
   bool             Init(void);
   void             OnTick(void);
   void             PreProcess(void);
   void             PostProcess(void);
   void             OnTimer(void);
   void             OnDeinit(const int reason);
   void             OnTradeTransaction(const MqlTradeTransaction &trans,
                                       const MqlTradeRequest &request,
                                       const MqlTradeResult &result);

   //--- Getters (conveniencia para o EA / estrategias)
   ulong            GetMagic(void)          { return sets.m_magic;          }
   string           GetSymbol(void)         { return m_symbol.Name();       }
   double           GetAdjustedPoint(void)  { return sets.m_adjusted_point; }
   uchar            GetMaxSlippage(void)    { return sets.m_max_slippage;   }
   bool             CanOpenTrade(void)      { return sets.m_can_open_trade; }
   int              GetCombinedDir(void)    { return sets.combined_dir;     }
   int              GetGlobalRisk(void)     { return sets.Isglobal_risk;    }
   bool             GetIsTime(void)         { return sets.IsTimeAllowed;    }
   bool             GetIsNews(void)         { return sets.IsNewsAllowed;    }
   bool             GetIsRisk(void)         { return sets.IsRiskAllowed;    }
   bool             GetIsBusy(void)         { return sets.IsBusy;           }

   //--- Comentário de ordens (InpComment ou auto "<ea>_<ver>_SUGESTAO")
   string           GetComment(void)        { return sets.m_comment;        }
   void             SetEAVersion(const string v)
      {
       sets.m_ea_version = v;
       RefreshComment();
      }

protected:
   //--- Helpers internos
   bool             RefreshRates(void);
   ulong            AutoMagicID(void);
   void             CalculateAllPositions(void);
   void             DailyResetCounters(void);
   void             RefreshComment(void);
  };

//+------------------------------------------------------------------+
//| Instancia global unica do framework                               |
//+------------------------------------------------------------------+
CALXQuantCore framework;

//+------------------------------------------------------------------+
//| Init - inicializa todos os modulos (wiring de ponteiros)          |
//+------------------------------------------------------------------+
bool CALXQuantCore::Init(void)
  {
//--- Validação do timeframe
  // if(InpEATimeframe != PERIOD_CURRENT && _Period != (int)InpEATimeframe)
  //   {
  //    PrintFormat("Timeframe inválido. Atual: %s | Esperado: %s",EnumToString(_Period),EnumToString(InpEATimeframe));
  //    return(false);
   //  }
//---
   EventSetTimer(10);
   if(!m_symbol.Name(_Symbol)) return(false);
   if(!RefreshRates()) return(false);

//--- Magic + trade object
   sets.m_magic        = AutoMagicID();
   sets.m_max_slippage = 100;
   m_trade.SetExpertMagicNumber(sets.m_magic);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(m_symbol.Name());
   m_trade.SetDeviationInPoints(sets.m_max_slippage);
   
//--- Point ajustado (XAU = 10 pontos por pip)
   sets.digits_adjust   = (m_symbol.Digits()==3 || m_symbol.Digits()==5) ? 10 : 1;
   sets.m_adjusted_point= m_symbol.Point()*sets.digits_adjust;

   sets.ExtStopLoss     = InpStopLoss      * sets.m_adjusted_point;
   sets.ExtTrailingStop = InpTrailFixed    * sets.m_adjusted_point;
   sets.ExtTrailingStep = InpTrailStepFixed* sets.m_adjusted_point;
   sets.ExtBreakeven    = InpBEValue       * sets.m_adjusted_point;

//--- Design
   m_design.Init();
   Print("### Design...");


//--- Market Regime (primeiro: dependencia de ponteiros)
   m_regime.Init(InpDFAPeriod, InpDFA_min_scale, InpDFA_max_scale);
   m_regime.SetProfile(m_regime.DetectAssetProfile(m_symbol.Name()));
   Print("### Regime...");

//--- Risk Sentiment (macro) + Risk Manager
   m_risksentiment.Init();
   m_protector.Init();
   Print("### Protector...");


//--- CExecution: position sizing + execution (consolidado)
   m_exec.SetLotMode(InpLotMode2);
   m_exec.SetSLMode(InpSLMode);
   m_exec.SetSLValue(InpSLValue);
   m_exec.SetTPMode(InpTPMode);
   m_exec.SetTPValue(InpTPRatio);
   m_exec.SetBEMode(InpBEMode);
   m_exec.SetBEValue(InpBEValue);
   m_exec.SetTrailMode(InpTrailMode);
   if(InpTrailMode == TRAIL_ATR)
     {
      m_exec.SetTrailDistance(InpTrailATR);
      m_exec.SetTrailStep(InpTrailStepATR);
     }
   else
     {
      m_exec.SetTrailDistance(InpTrailFixed);
      m_exec.SetTrailStep(InpTrailStepFixed);
     }
   switch(InpLotMode2)
     {
      case lot_fixed:
      case lot_balance:
         m_exec.SetLotValue(InpLotValueFix);
         break;
      default:
         m_exec.SetLotValue(InpTradeRiskPct);
         break;
     }
   if(!m_exec.Init(m_symbol.Name(), sets.m_magic, 3, 150, 5000, GetPointer(m_regime)))
      return(false);
   Print("### Execution...");


//--- DataMiner (buffer + snapshot regime/macro via ponteiros)
   m_miner.Init(sets.m_magic, InpDataMinerFile, InpDataMinerPath, -2,
                GetPointer(m_regime), GetPointer(m_risksentiment));
   Print("### Miner...");
 

//--- Timefilter (le as noticias do Calendar.csv)
   m_timefilter.Init();
   m_newsfilter.Init();
   Print("### Timer...");



//--- Trailing Stop profissional
   //m_trailing.Init(m_symbol.Name(), (long)sets.m_magic,
   //                sets.ExtTrailingStop, sets.ExtTrailingStop, sets.ExtTrailingStep,
   //                sets.ExtTrailingStop, sets.ExtBreakeven);

   Print("### Trailling...");
   
//--- Panel
   m_panel.Init("EA Quant", FRAMEWORK_VERSION);

//--- Comentário de ordens: nome do EA + versão via setter no OnInit do EA
   sets.m_ea_name = MQLInfoString(MQL_PROGRAM_NAME);
   RefreshComment();

//--- Estado inicial
   sets.m_current_day      = 0;
   sets.m_daily_trades_TF  = 0;
   sets.m_daily_trades_BK  = 0;
   sets.m_daily_trades_SB  = 0;
   sets.m_daily_trades_MR  = 0;
   sets.m_last_trade_bar_time = 0;
   sets.m_can_open_trade   = false;
   sets.combined_dir       = 0;
   sets.Isglobal_risk      = 0;
   sets.Isglobal_risk_factor = 1.0;

//--- VALIDAÇÃO DE INPUTS (proteção)
   double broker_min_stop_points = m_symbol.StopsLevel();
   double broker_min_stop_price  = broker_min_stop_points * m_symbol.Point();
   double min_sl_price           = MathMax(broker_min_stop_price * 2, sets.m_adjusted_point * 10);

   if(InpMaxSpread > 0 && InpMaxSpread < broker_min_stop_points)
      Print("WARNING: InpMaxSpread (", InpMaxSpread, ") < broker StopsLevel (", broker_min_stop_points, ")");

   if(InpTradeRiskPct <= 0 || InpTradeRiskPct > 10)
     {
      Print("ERROR: InpTradeRiskPct (", InpTradeRiskPct, ") must be between 0.1 and 10.");
      return(false);
     }

   if(InpSLMode == SL_FIXED)
     {
      double sl_price = InpSLValue * sets.m_adjusted_point;
      if(sl_price < min_sl_price)
        {
         Print("ERROR: InpSLFixed (", InpSLValue, " pips) too tight. Minimum is ",
               IntegerToString((int)(min_sl_price / sets.m_adjusted_point)), " pips.");
         return(false);
        }
     }

   Print("ALXQuantCore v2 | Symbol: ", m_symbol.Name(),
         " | Magic: ", sets.m_magic, " | Init OK");
   return(true);
  }

//+------------------------------------------------------------------+
//| OnTick - infraestrutura comum                                     |
//| O EA chama framework.OnTick() e depois avalia os sinais.          |
//+------------------------------------------------------------------+
void CALXQuantCore::OnTick(void)
  {
   PreProcess();
   PostProcess();
  }

//+------------------------------------------------------------------+
//| PreProcess - alimenta miner/risk/regime/time (NÃO bloqueia)       |
//| O EA roda a estratégia DEPOIS desta chamada, sem retornar cedo.   |
//+------------------------------------------------------------------+
void CALXQuantCore::PreProcess(void)
  {
   sets.g_total_market_ticks++;

//--- SECTION 1: Updates + Refresh (a cada tick)
   m_miner.Tick();
   m_exec.Update();
   m_protector.Update();
   sets.IsRiskAllowed = !m_protector.IsTriggered();

//--- Trabalhamos apenas no nascimento de nova barra
   static datetime PrevBars = 0;
   datetime time_0 = iTime(m_symbol.Name(), Period(), 0);
   if(time_0 == PrevBars)
      return;
   PrevBars = time_0;

//---
   if(!RefreshRates() || !m_symbol.Refresh()) return;

   sets.freeze_level = m_symbol.FreezeLevel()*m_symbol.Point();
   if(sets.freeze_level==0.0) sets.freeze_level=(m_symbol.Ask()-m_symbol.Bid())*3.0;
   sets.freeze_level*=1.1;
   sets.stop_level = m_symbol.StopsLevel()*m_symbol.Point();
   if(sets.stop_level==0.0) sets.stop_level=(m_symbol.Ask()-m_symbol.Bid())*3.0;
   sets.stop_level*=1.1;
   if(sets.freeze_level<=0.0 || sets.stop_level<=0.0) return;

//--- SECTION 2: Regime (nova barra) + direção macro
   m_regime.Get();
   sets.combined_dir     = m_risksentiment.GetTradeDirection(m_symbol.Name());
   sets.Isglobal_risk    = m_risksentiment.GetSentiment();
   sets.Isglobal_risk_factor = m_risksentiment.GetRiskScore();

//--- SECTION 3: Filtros + contadores
   DailyResetCounters();
   sets.IsTimeAllowed = m_timefilter.IsTimeTrade();
   sets.IsNewsAllowed = !m_newsfilter.IsNewsBlocked();
   sets.IsBusy        = !m_exec.IsBusy();
   CalculateAllPositions();

   sets.m_can_open_trade = sets.IsTimeAllowed &&
                           sets.IsNewsAllowed &&
                           sets.IsRiskAllowed &&
                           sets.IsBusy &&
                           (sets.count_buys == 0) &&
                           (sets.count_sells == 0);
  }

//+------------------------------------------------------------------+
//| PostProcess - gestão de infraestrutura (trailing)                 |
//| O EA roda a estratégia ENTRE PreProcess() e PostProcess().        |
//+------------------------------------------------------------------+
void CALXQuantCore::PostProcess(void)
  {
//--- SECTION 4: Trailing Stop (infraestrutura)
   //m_trailing.Process();
  }

//+------------------------------------------------------------------+
//| OnTimer - dashboard + sessões + notícias                          |
//+------------------------------------------------------------------+
void CALXQuantCore::OnTimer(void)
{
   if(InpUI_panel)
   {
      // Update StatsTracker
      m_stats.Update();
      
      // Get stats for panel
      AssetStats as;
      PerfStats ps;
      m_stats.GetAssetStats(as);
      m_stats.GetPerfStats(ps);
      
      m_panel.DrawDashboard(
         sets.m_magic,
         m_regime.GetTrend(),
         m_regime.GetVolatility(),
         m_regime.GetMomentum(),
         m_regime.GetLastHurst(),
         m_regime.GetConfidence(),
         sets.IsTimeAllowed,
         sets.IsNewsAllowed,
         m_timefilter.GetBlockReasonText(),
         sets.IsRiskAllowed,
         !m_protector.IsTriggered(),    // equityGuardSafe
         InpMaxSpreadPips,              // maxSpreadPips
         sets.m_max_slippage,           // maxSlippagePts
         as, ps,
         20, 30);
   }

   m_newsfilter.ReloadNews();
   m_timefilter.DrawSessionLines();
}

//+------------------------------------------------------------------+
//| OnDeinit - limpeza                                                |
//+------------------------------------------------------------------+
void CALXQuantCore::OnDeinit(const int reason)
  {
   Comment("");

   EventKillTimer();
   ObjectsDeleteAll(0, 0, OBJ_LABEL);
   ObjectsDeleteAll(0, 0, OBJ_RECTANGLE_LABEL);
   //m_design.DeleteTradeLines("alx_");
   m_miner.FlushToDisk();
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction - encaminha para os modulos                    |
//+------------------------------------------------------------------+
void CALXQuantCore::OnTradeTransaction(const MqlTradeTransaction &trans,
                                       const MqlTradeRequest &request,
                                       const MqlTradeResult &result)
  {
   m_miner.OnTransaction(trans);
   m_exec.ProcessTradeTransaction(trans, request, result);
  }

//+------------------------------------------------------------------+
//| Gera Magic Number único baseado em Symbol + Timeframe            |
//+------------------------------------------------------------------+
ulong CALXQuantCore::AutoMagicID(void)
  {
   string symbol = _Symbol;
   ENUM_TIMEFRAMES tf = _Period;

   string base  = StringSubstr(symbol, 0, 3);
   string quote = StringSubstr(symbol, 3, 3);
   int tfValue  = (int)tf;

   int hash = 0;
   for(int i = 0; i < StringLen(base); i++)
      hash += StringGetCharacter(base, i) * (i + 1);
   for(int i = 0; i < StringLen(quote); i++)
      hash += StringGetCharacter(quote, i) * (i + 10);
   hash += tfValue * 1000;

   hash = MathAbs(hash);
   return(hash % 2147483647);
  }

//+------------------------------------------------------------------+
//| Refreshes the symbol quotes data                                 |
//+------------------------------------------------------------------+
bool CALXQuantCore::RefreshRates(void)
  {
   if(!m_symbol.RefreshRates()) return(false);
   if(m_symbol.Ask()==0 || m_symbol.Bid()==0) return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Monta o comentário de ordens: InpComment ou auto                 |
//+------------------------------------------------------------------+
void CALXQuantCore::RefreshComment(void)
  {
   if(StringLen(InpComment) > 0)
      sets.m_comment = InpComment;
   else
      sets.m_comment = StringFormat("%s_%s_SUGESTAO",
                                    sets.m_ea_name, sets.m_ea_version);
  }

//+------------------------------------------------------------------+
//| Calculate all positions Buy and Sell                             |
//+------------------------------------------------------------------+
void CALXQuantCore::CalculateAllPositions(void)
  {
   sets.count_buys=0;
   sets.count_sells=0;
   sets.count_total=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
      if(m_position.SelectByIndex(i))
         if(m_position.Symbol()==m_symbol.Name() && m_position.Magic()==sets.m_magic)
           {
            sets.count_total++;
            if(m_position.PositionType()==POSITION_TYPE_BUY)
               sets.count_buys++;

            if(m_position.PositionType()==POSITION_TYPE_SELL)
               sets.count_sells++;
           }
  }

//+------------------------------------------------------------------+
//| Reset dos contadores diarios em novo dia                          |
//+------------------------------------------------------------------+
void CALXQuantCore::DailyResetCounters(void)
  {
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(today != sets.m_current_day)
     {
      sets.m_current_day     = today;
      sets.m_daily_trades_TF = 0;
      sets.m_daily_trades_BK = 0;
      sets.m_daily_trades_SB = 0;
      sets.m_daily_trades_MR = 0;
     }
  }
//+------------------------------------------------------------------+
*/