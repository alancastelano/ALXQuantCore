//+------------------------------------------------------------------+
//|                                                    Framework.mqh |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//|                       Orquestrador do Framework — v4.0            |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      ""
#property version   "4.00"
/*
    v.4.00 - 2026-09-06 - REWRITE: Framework modular completo.
                           - Inputs de SL/TP/Trailing vivem nas classes Core
                           - Includes + instancias globais (padrao MQL5)
                           - Init() conecta todos os modulos
                           - Sem accessors com ponteiros
    v.3.00 - 2026-09-04 - AccountProtector integrado
    v.2.00 - 2026-09-02 - Versao inicial
*/

//+------------------------------------------------------------------+
//| API MQL5                                                          |
//+------------------------------------------------------------------+
#include <Trade\PositionInfo.mqh>  CPositionInfo  m_position;
#include <Trade\Trade.mqh>         CTrade         m_trade;
#include <Trade\SymbolInfo.mqh>    CSymbolInfo    m_symbol;
#include <Trade\AccountInfo.mqh>   CAccountInfo   m_account;
#include <Trade\DealInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| Enum Lor or Risk                                                  |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES TFMigrate(int tf)
  {
   switch(tf)
     {
      case 0: return(PERIOD_CURRENT);
      case 1: return(PERIOD_M1);
      case 5: return(PERIOD_M5);
      case 15: return(PERIOD_M15);
      case 30: return(PERIOD_M30);
      case 60: return(PERIOD_H1);
      case 240: return(PERIOD_H4);
      case 1440: return(PERIOD_D1);
      case 10080: return(PERIOD_W1);
      case 43200: return(PERIOD_MN1);

      case 2: return(PERIOD_M2);
      case 3: return(PERIOD_M3);
      case 4: return(PERIOD_M4);
      case 6: return(PERIOD_M6);
      case 10: return(PERIOD_M10);
      case 12: return(PERIOD_M12);
      case 16385: return(PERIOD_H1);
      case 16386: return(PERIOD_H2);
      case 16387: return(PERIOD_H3);
      case 16388: return(PERIOD_H4);
      case 16390: return(PERIOD_H6);
      case 16392: return(PERIOD_H8);
      case 16396: return(PERIOD_H12);
      case 16408: return(PERIOD_D1);
      case 32769: return(PERIOD_W1);
      case 49153: return(PERIOD_MN1);
      default: return(PERIOD_CURRENT);
     }
  }
//+------------------------------------------------------------------+

enum enLotMode
  {
   lot_fix=0,     // lot fix
   lot_min=1,     // lot min
   lot_balance=2, // lot balance ($ 10.000)
   lot_risk=3,    // Risk %
  };
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| #Inputs — EA Level                                               |
//+------------------------------------------------------------------+
input group                "➜ EA Config"
input string               InpSetDescription       = "";              // Set description
input int                  InpTime                 = 10;              // Timer refresh interval (seconds)
input ENUM_TIMEFRAMES      InpEATimeframe          = PERIOD_M1;       // EA timeframe (validated in Init)
input int                  InpMaxSpreadPips        = 30;              // Max spread (pips, 0=off)
input int                  InpMaxSlippage          = 30;              // Max slippage (points)
//+------------------------------------------------------------------+
input group                "➜ Position Size"
input enLotMode            InpLotMode              = lot_balance;     // Lote mode
input double               InpLotValue             = 0.10;            // Lote value
input double               InpMaxLot               = 0.10;            // Max lot
input int                  InpMaxLeverage          = 10;              // Max leverage
//+------------------------------------------------------------------+
input double               StopLossProcent         = 0.8;             // Fallback SL % (0=off)

input int                  TakeProfit              = 40;              // Take profit (pips) [legacy]
//+------------------------------------------------------------------+
input group                "➜ Strategy"
input double               InpTimeAnalise          = 2;              // Time (sec)
input double               InpPipsStep             = 28.0;           // Pip Step (pips)
input ENUM_TIMEFRAMES      InphighTimeframeConfirme= PERIOD_H4;      // High timeframe confirme


//+------------------------------------------------------------------+
//| Core — Modulos de Stop Loss, Take Profit, Trailing, etc.          |
//+------------------------------------------------------------------+
#ifndef DEBUG_MODE
#define DEBUG_MODE false
#endif
#include <ALXQuantCore\Core\enums.mqh>
#include <ALXQuantCore\Core\Core.mqh>              CCore              m_core;
#include <ALXQuantCore\Core\Commission.mqh>        CCommission        m_commission;
#include <ALXQuantCore\Core\StopLoss.mqh>          CStopLoss          m_sl;
#include <ALXQuantCore\Core\TakeProfit.mqh>        CTakeProfit        m_tp;
#include <ALXQuantCore\Core\Trailling.mqh>         CTrailling         m_trailing;
#include <ALXQuantCore\Core\Timefilter.mqh>        CTimeFilter        m_timefilter;
#include <ALXQuantCore\Core\NewsFilter.mqh>        CNewsFilter        m_newsfilter;
#include <ALXQuantCore\Core\Panel.mqh>             CPanel             m_panel;

//+------------------------------------------------------------------+
//| Modules — Logica de negocio                                       |
//+------------------------------------------------------------------+
#include <ALXQuantCore\Modules\AccountProtector.mqh>   CAccountProtector  m_protector;
#include <ALXQuantCore\Modules\MacroRegimeEngine.mqh>  CMacroRegimeEngine  m_regime;
#include <ALXQuantCore\Modules\DataMiner.mqh>          CDataMinerBuffered m_miner;
#include <ALXQuantCore\Modules\StatsTracker.mqh>       CStatsTracker       m_stats;

//+------------------------------------------------------------------+
//| Institutional — Comportamento, Execucao                           |
//+------------------------------------------------------------------+
#include <ALXQuantCore\Institutional\HumanBehavior.mqh>  CHumanBehavior   m_human;
#include <ALXQuantCore\Institutional\Execution.mqh>      CExecution      m_exec;


//+------------------------------------------------------------------+
//| #Structs                                                         |
//+------------------------------------------------------------------+
struct Setting
   {
      string   m_ea_name;
      string   m_ea_version;
      ulong    m_magic;
      double   freeze_level;
      //---
      double   stop_level;
      int      m_max_slippage;


      string   m_comment;
      int      digits_adjust;
      double   m_adjusted_point;

      double   ExtStopLoss;
      double   ExtTakeProfit;
      double   ExtBreakeven;
      double   ExtTrailingStop;
      double   ExtTrailingStep;
      string   m_status;

      datetime m_last_trade_bar_time;
      int      count_buys;
      int      count_sells;
      int      count_total;
      double   long_lot;
      double   short_lot;

      //-- Strategy
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
      //-- Execution Control
      bool     m_need_open_buy;
      bool     m_need_open_sell;
      bool     m_waiting_transaction;
      ulong    m_waiting_order_ticket;
      bool     m_transaction_confirmed;

    } sets;


//+------------------------------------------------------------------+
//| CFramework — orquestrador v4.0                                    |
//|   Conecta todos os modulos automaticamente.                       |
//|   Inputs dos modulos sao declarados nas proprias classes.         |
//|   EA so inclui Framework e chama Init().                          |
//+------------------------------------------------------------------+
class CFramework
  {
public:
                     CFramework();
                    ~CFramework();

   //--- Init: conecta todos os modulos
   bool               Init();

   //--- OnTimer: atualiza stats e desenha painel
   void               OnTimer();

   //--- Init com commission params (se EA quiser configurar comissao)
   void               InitCommission(enCommMode commMode, double commPerLot, double commBuffer);

   //--- Accessors (para EA acessar modulos)
   CCommission       *Commission() { return &m_commission; }

   //--- Limpeza
   void               DeInit(const int reason);
  };

//+------------------------------------------------------------------+
//| Construtor                                                        |
//+------------------------------------------------------------------+
CFramework::CFramework() {  ZeroMemory(sets);  }

//+------------------------------------------------------------------+
//| Destrutor                                                         |
//+------------------------------------------------------------------+
CFramework::~CFramework() { }

//+------------------------------------------------------------------+
//| Init — conecta todos os modulos                                   |
//|   Chamar no OnInit() do EA.                                       |
//|   Cada modulo declara seus proprios inputs.                       |
//+------------------------------------------------------------------+
bool CFramework::Init()
  {
//--- Validacao do timeframe
   if(InpEATimeframe != PERIOD_CURRENT && _Period != (int)InpEATimeframe)
     {
      PrintFormat("Timeframe invalido. Atual: %s | Esperado: %s",EnumToString(_Period),EnumToString(InpEATimeframe));
      return(false);
     }
//---
   EventSetTimer(InpTime);
//---
   if(!m_symbol.Name(Symbol())) // sets symbol name
      return(false);

   if(!RefreshRates()) return(false);
//---
   sets.m_ea_name       = EA_NAME;
   sets.m_ea_version    = EA_VERSION;
   sets.m_magic         = m_core.AutoMagicID(sets.m_ea_name, sets.m_ea_version);
   sets.m_max_slippage  = InpMaxSlippage;
   sets.m_comment       = m_core.GenerateRegimeComment();

//--- Strategy
   sets.price_open      = 0.0;
   sets.time_open       = (datetime)InpTimeAnalise;
   sets.time_new        = 0;
   sets.digits_adjust   = 1;
//---
   sets.cached_step_points    = 22.0;
   sets.last_bar_time         = 0;
   sets.m_last_trade_bar_time = 0;

//-- Execution Control
   sets.m_need_open_buy           = false;
   sets.m_need_open_sell          = false;
   sets.m_waiting_transaction     = false;
   sets.m_waiting_order_ticket    = 0;
   sets.m_transaction_confirmed   = false;

//---
   m_trade.LogLevel(LOG_LEVEL_NO);
   m_trade.SetExpertMagicNumber(sets.m_magic);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(m_symbol.Name());
   m_trade.SetDeviationInPoints(InpMaxSlippage);
//---

//--- Detecta se o simbolo e do tipo Forex "classico"
   ENUM_SYMBOL_CALC_MODE calc_mode = (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_CALC_MODE);
   bool is_forex_like = (calc_mode == SYMBOL_CALC_MODE_FOREX || calc_mode == SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE);

   if(is_forex_like && (m_symbol.Digits()==3 || m_symbol.Digits()==5))
       sets.digits_adjust = 10;
   sets.m_adjusted_point = m_symbol.Point() * sets.digits_adjust;

//--- Core: Commission
   m_commission.Init(&m_symbol, 0);

//--- Core: Stop Loss (le InpSLMode, InpSLValue, etc.)
   m_sl.Init(_Symbol, _Period, sets.m_adjusted_point);

//--- Core: Take Profit (le InpTPMode, InpTPValue, etc.)
   m_tp.Init(_Symbol, _Period, sets.m_adjusted_point);

//--- Core: Trailing & Breakeven (le InpTrailDistance, etc.)
   m_trailing.Init(_Symbol, sets.m_magic, &m_commission);

//--- Modules: MacroRegimeEngine (le InpDFAPeriod, etc.)
   m_regime.Init(InpDFAPeriod, InpDFA_min_scale, InpDFA_max_scale, InpRegimeTimeframe);

//--- Institutional: HumanBehavior
   m_human.Init();

//--- Core: TimeFilter (le InpTimeEnabled, InpTimeStart, etc.)
   m_timefilter.Init();

//--- Core: NewsFilter (le InpNewsSource, InpNewsEnabled, etc.)
   m_newsfilter.Init();

//--- Modules: AccountProtector (equity guard, DD limits, consistency)
   m_protector.SetMagic(sets.m_magic);
   m_protector.Init();

//--- Modules: StatsTracker
   m_stats.Init(_Symbol, sets.m_magic);

//--- Modules: DataMiner
   if(InpEnableDataMiner)
      m_miner.Init(sets.m_magic, "trades_" + _Symbol + ".csv",
                   InpDataMinerPath, InpCatThreshold, &m_regime, NULL);

//--- Institutional: Execution
   m_exec.Init(_Symbol, sets.m_magic, 3, 100, 5000);

//--- Panel (dashboard visual)
   string ea_name = (sets.m_ea_name != "") ? sets.m_ea_name : "ALXQuant";
   string ea_ver  = (sets.m_ea_version != "") ? sets.m_ea_version : "4.0";
   m_panel.Init(ea_name, ea_ver);

//---
   Print("[FRAMEWORK] Init OK — modules connected");

   return(true);
  }


//+------------------------------------------------------------------+
//| InitCommission — configura comissao (se EA usar)                  |
//|   Chamar no OnInit() apos Init() se precisar de comissao.        |
//+------------------------------------------------------------------+
void CFramework::InitCommission(enCommMode commMode, double commPerLot, double commBuffer)
  {
   m_commission.Init(&m_symbol, 0);
  }

//+------------------------------------------------------------------+
//| OnTimer — atualiza stats e desenha dashboard                      |
//+------------------------------------------------------------------+
void CFramework::OnTimer()
  {
   m_stats.Update();

   AssetStats as;
   PerfStats  ps;
   m_stats.GetAssetStats(as);
   m_stats.GetPerfStats(ps);

   m_panel.DrawDashboard(
      sets.m_magic,
      m_regime.GetLabel(),
      "",
      "",
      m_regime.GetLastHurst(),
      m_regime.GetConfidence(),
      sets.IsTimeAllowed,
      sets.IsNewsAllowed,
      m_newsfilter.GetBlockReasonText(),
      sets.IsRiskAllowed,
      !m_protector.IsTriggered(),
      InpMaxSpreadPips,
      sets.m_max_slippage,
      as, ps
   );
  }

//+------------------------------------------------------------------+
//| DeInit — limpa tudo                                               |
//+------------------------------------------------------------------+
void CFramework::DeInit(const int reason)
  {
   m_timefilter.Deinit();
   m_newsfilter.Deinit();

   EventKillTimer();
   ObjectsDeleteAll(0,0, OBJ_LABEL);
   ObjectsDeleteAll(0,0, OBJ_RECTANGLE_LABEL);
  }
//+------------------------------------------------------------------+
