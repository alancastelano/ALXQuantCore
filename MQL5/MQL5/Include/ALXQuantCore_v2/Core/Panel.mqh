//+------------------------------------------------------------------+
//|                                                        Panel.mqh |
//|                                  Copyright 2026, ALXQuant Engine |
//|                                             https://www.mql5.com |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuant Engine"
#property link      "https://www.mql5.com"
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
    v.7.13 - 2026-07-29 - Refactor: class CALXQuantPanel -> CPanel, +ea_build param in Init().
    v.7.14 - 2026-08-15 - Fix: conversao pontos->pips do Avg Spread (agora usa digits 3/5 -> /10).
    v.7.15 - 2026-08-19 - Fix: m_regime.GetTrend() -> GetLabel() (metodo removido do MacroRegimeEngine).
    v.7.16 - 2026-08-20 - Fix: titulo exibia 'vv' (prefixo fixo + versao ja com 'v'); agora exibe a versao exata recebida.
    v.7.20 - 2026-08-20 - Add: dashboard profissional em secoes (Filtros/Regime/Execucao/
                         Asset Status/Performance). Novos campos: Entry Gate (rotulo honesto,
                         era 'Risk Manager'), Equity Guard (estado real), Risk Global e
                         Confluence mostram 'N/A' quando nao alimentados (0), Asset Stats e
                         Performance recebidos por parametro (AssetStats/PerfStats do
                         StatsTracker). Fundo com altura dinamica.
*/
#include <ALXQuantCore\Modules\StatsTracker.mqh>

class CPanel
  {
private:
   void  UpdateLabel(string name, int x, int y, string text, color clr, int font_size = 9);
   void  CreatePanelBackground(string name, int x, int y, int w, int h, color bg); 

   string m_ea_name;
   string m_ea_version;

public:
   void  Init(string ea_name, string ea_version, string ea_build = "");
   void  DrawDashboard(ulong magic,string trendStr, string volStr, string momStr, double H, double R2,
                       bool isTimeAllowed, bool isNewsAllowed, string NewsBlockedReason,
                       bool isRiskAllowed, bool equityGuardSafe,
                       double maxSpreadPips, double maxSlippagePts,
                       AssetStats &as, PerfStats &ps,
                       int x = 20, int y = 30);
  };

//+------------------------------------------------------------------+
//| INICIALIZACAO DO PAINEL                                          |
//+------------------------------------------------------------------+
void CPanel::Init(string ea_name, string ea_version, string ea_build = "")
{
   m_ea_name    = ea_name;
   m_ea_version = ea_version + (ea_build != "" ? " " + ea_build : "");
   Print(__FUNCTION__ + " - The initial panel module has been successfully initialized!"); 
}

//+------------------------------------------------------------------+
//| ATUALIZACAO E DESENHO DO DASHBOARD                               |
//+------------------------------------------------------------------+
void CPanel::DrawDashboard(ulong magic,string trendStr, string volStr, string momStr, double H, double R2,
                       bool isTimeAllowed, bool isNewsAllowed, string NewsBlockedReason,
                       bool isRiskAllowed, bool equityGuardSafe,
                       double maxSpreadPips, double maxSlippagePts,
                       AssetStats &as, PerfStats &ps,
                       int x = 20, int y = 30)
{
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
      return;

   string p = "alx_unified_";

   // fundo criado primeiro (fica atras das labels); altura dinamica ajustada no fim
   CreatePanelBackground(p+"bg", x-10, y-10, 340, 700, C'18,18,18');

   int step = 16; 
   int col1 = x;
   int col2 = x + 150; 
   int y0  = y;

   // ========================================================================
   // CABECALHO & ID CORE
   // ========================================================================
   string str_title = m_ea_name + " " + m_ea_version + " | ID: " + IntegerToString(magic);
   UpdateLabel(p+"title", col1, y, str_title, clrDeepSkyBlue, 10);
   y += 15;    
   
   UpdateLabel(p+"sub", col1, y, "ALXQuantCore IA", clrGray, 8);
   y += 12;    
    
   UpdateLabel(p+"line1", col1, y, "----------------------------------------------------", clrDimGray, 8);
   y += 14;    

   // ========================================================================
   // SECAO 1: FILTROS OPERACIONAIS
   // ========================================================================
   UpdateLabel(p+"s_filter", col1, y, ">> FILTROS OPERACIONAIS", clrDarkOrange, 9);
   y += 14;

   UpdateLabel(p+"lb_flt_time", col1, y, "Time Filter:", clrLightGray, 9);
   UpdateLabel(p+"val_flt_time", col2, y, isTimeAllowed ? "ALLOWED" : "BLOCKED", isTimeAllowed ? clrLime : clrRed, 9);
   y += step;

   UpdateLabel(p+"lb_flt_news", col1, y, "News Filter:", clrLightGray, 9);
   UpdateLabel(p+"val_flt_news", col2, y, isNewsAllowed ? "CLEAN" : NewsBlockedReason, isNewsAllowed ? clrLime : clrOrangeRed, 9);
   y += step;

   UpdateLabel(p+"lb_flt_risk", col1, y, "Entry Gate:", clrLightGray, 9);
   UpdateLabel(p+"val_flt_risk", col2, y, isRiskAllowed ? "OPEN" : "CLOSED", isRiskAllowed ? clrLime : clrRed, 9);
   y += step;

   UpdateLabel(p+"lb_flt_guard", col1, y, "Equity Guard:", clrLightGray, 9);
   UpdateLabel(p+"val_flt_guard", col2, y, equityGuardSafe ? "SAFE" : "TRIGGERED", equityGuardSafe ? clrLime : clrRed, 9);
   y += step;

   // Risk-On==1 | Risk-Off==-1 | Neutro==0 | N/A quando nao alimentado
   string rgTxt = (sets.Isglobal_risk == 1) ? "RISK-ON [" + (string)sets.Isglobal_risk_factor + "]"
                : (sets.Isglobal_risk == -1) ? "RISK-OFF [" + (string)sets.Isglobal_risk_factor + "]"
                : (sets.Isglobal_risk == 0) ? "N/A" : "N/A";
   color rgClr = (sets.Isglobal_risk == 1) ? clrLime : (sets.Isglobal_risk == -1) ? clrRed : clrGray;
   UpdateLabel(p+"lb_flt_risk_gl", col1, y, "Risk Global:", clrLightGray, 9);
   UpdateLabel(p+"val_flt_risk_gl", col2, y, rgTxt, rgClr, 9);
   y += step;

   UpdateLabel(p+"lb_flt_chaos", col1, y, "Chaos:", clrLightGray, 9);
   UpdateLabel(p+"val_flt_chaos", col2, y, m_regime.IsChaosRegime() ? "CHAOS" : "SAFE", m_regime.IsChaosRegime() ? clrRed : clrLime, 9);
   y += step;

   // ========================================================================
   // SECAO 2: REGIME & MERCADO
   // ========================================================================
   UpdateLabel(p+"s_regime", col1, y, ">> REGIME & MERCADO", clrDarkOrange, 9);
   y += 14;

   double _H  = m_regime.GetLastHurst();
   double _R2 = m_regime.GetConfidence();
   int    _dir = (int)m_regime.GetDirection();

   UpdateLabel(p+"lb_hurst",      col1, y, "Hurst Exponent:", clrLightGray, 9);
   UpdateLabel(p+"val_hurst",     col2, y, DoubleToString(H, 3), 
               (H > 0.55) ? clrLime : (H < 0.45) ? clrRed : clrYellow, 9);
   y += step;
    
   UpdateLabel(p+"lb_confidence", col1, y, "Confidence (R2):", clrLightGray, 9);
   UpdateLabel(p+"val_confidence",col2, y, DoubleToString(R2, 3), 
               (R2 >= 0.70) ? clrLime : clrOrangeRed, 9);
   y += step;
   
   string dir_str = (_dir > 0) ? "BULL" : (_dir < 0) ? "BEAR" : "NEUTRO";
   color  dir_clr = (_dir > 0) ? clrLime  : (_dir < 0) ? clrRed   : clrGray;
   UpdateLabel(p+"lb_direction",  col1, y, "Direction:", clrLightGray, 9);
   UpdateLabel(p+"val_direction", col2, y, dir_str, dir_clr, 9);
   y += step;
   
   UpdateLabel(p+"lb_trend",  col1, y, "Market Trend:", clrLightGray, 9);
   UpdateLabel(p+"val_trend", col2, y, m_regime.GetLabel(), m_regime.GetRegimeColor(), 9);
   y += step;

   bool is_trend  = m_regime.IsTrendFollowingRegime(false);
   bool is_pull   = m_regime.IsTrendFollowingRegime(true);
   bool is_break  = m_regime.IsBreakoutRegime();
   bool is_meanr  = m_regime.IsMeanReversionRegime();
   bool is_chaos  = m_regime.IsChaosRegime();
   
   string regime_active = is_chaos ? "CHAOS" : is_break ? "BREAKOUT" : is_pull ? "PULLBACK"
                        : is_trend ? "TREND" : is_meanr ? "MEAN-REV" : "NENHUM";
   color regime_clr = is_break ? clrMagenta : (is_pull || is_trend) ? clrLime
                    : is_meanr ? clrYellow : is_chaos ? clrRed : clrGray;
   
   UpdateLabel(p+"lb_regime_active",  col1, y, "Active Regime:", clrLightGray, 9);
   UpdateLabel(p+"val_regime_active", col2, y, regime_active, regime_clr, 9);
   y += step;
   
   string blocks = "";
   if(_R2 < 0.70)                     blocks += "R2 ";
   if(_H >= 0.45 && _H <= 0.55)       blocks += "H~0.5 ";
   if(_dir == 0)                      blocks += "DIR=0 ";
   if(!m_regime.isLiquiditySafe())    blocks += "LIQ ";
   if(m_regime.isHighVol())           blocks += "VOL+ ";
   if(m_regime.IsVolatilityBurst())   blocks += "BURST ";
   if(m_regime.possibleReversal())    blocks += "REV ";
   if(sets.combined_dir == 99)        blocks += "CONFLITO ";
   if(blocks == "") blocks = "OK";
   
   UpdateLabel(p+"lb_blocks",  col1, y, "Blockers:", clrLightGray, 9);
   UpdateLabel(p+"val_blocks", col2, y, blocks, (blocks == "OK") ? clrLime : clrOrangeRed, 9);
   y += step;
   
   string conf_str = (sets.combined_dir == 1) ? "BUY ONLY"
                   : (sets.combined_dir == -1) ? "SELL ONLY"
                   : (sets.combined_dir == 99) ? "CONFLITO" : "N/A";
   color  conf_clr = (sets.combined_dir == 1) ? clrLime : (sets.combined_dir == -1) ? clrRed : clrGray;
   
   UpdateLabel(p+"lb_confluence",  col1, y, "Confluence:", clrLightGray, 9);
   UpdateLabel(p+"val_confluence", col2, y, conf_str, conf_clr, 9);
   y += step;

   // ========================================================================
   // SECAO 3: EXECUCAO & BROKER
   // ========================================================================
   UpdateLabel(p+"s_exec", col1, y, ">> EXECUCAO & BROKER", clrDarkOrange, 9);
   y += 14;

   UpdateLabel(p+"s1", col1, y, "Engine State:", clrLightGray, 9);
   UpdateLabel(p+"s2", col2, y, m_exec.StateToString(), clrDeepSkyBlue, 9);
   y += step;

   string reqStr = StringFormat("%d [Rej: %d]", m_exec.GetTotalRequests(), m_exec.GetRejectCount());
   UpdateLabel(p+"r1", col1, y, "Requests Total:", clrLightGray, 9);
   UpdateLabel(p+"r2", col2, y, reqStr, (m_exec.GetRejectCount() > 0 ? clrOrangeRed : clrWhite), 9);
   y += step;

   string srStr = StringFormat("%.1f %% (%d Orders)", m_exec.GetSuccessRate(), m_exec.GetSucessCount());
   UpdateLabel(p+"sr1", col1, y, "Success Rate:", clrLightGray, 9);
   UpdateLabel(p+"sr2", col2, y, srStr, (m_exec.GetSuccessRate() < 90) ? clrOrangeRed : clrLime, 9);
   y += step;

   UpdateLabel(p+"lat1", col1, y, "Avg Latency:", clrLightGray, 9);
   UpdateLabel(p+"lat2", col2, y, DoubleToString(m_exec.GetAverageLatency(), 0) + " ms", (m_exec.GetAverageLatency() > 350) ? clrYellow : clrLime, 9);
   y += step;

   double currentSpreadPts = m_exec.GetAverageSpread();
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double pts_per_pip = (digits == 3 || digits == 5) ? 10.0 : 1.0;
   double currentSpreadPips = currentSpreadPts / pts_per_pip; 
   string spreadText  = StringFormat("%.1f pips (Max %d)", currentSpreadPips, (int)maxSpreadPips);
   color  spreadColor = (currentSpreadPips > maxSpreadPips) ? clrRed : clrWhite;
   
   UpdateLabel(p+"sp1", col1, y, "Avg Spread:", clrLightGray, 9);
   UpdateLabel(p+"sp2", col2, y, spreadText, spreadColor, 9);
   y += step;

   double avgSlip = m_exec.GetAverageSlippage();
   double maxSlip = m_exec.GetMaxSlippage();
   string slipText = StringFormat("%.1f pts [Max %.1f]", avgSlip, maxSlip);
   color slipColor = (avgSlip > maxSlippagePts || maxSlip > maxSlippagePts * 2) ? clrOrangeRed : clrLime;

   UpdateLabel(p+"sl1", col1, y, "Slippage Stats:", clrLightGray, 9);
   UpdateLabel(p+"sl2", col2, y, slipText, slipColor, 9);
   y += step;

   string brokerStateStr = m_exec.IsBrokerToxic() ? "TOXIC" : "NORMAL";
   string brokerText = StringFormat("%.1f [%s]", m_exec.GetBrokerScore(), brokerStateStr);
   color brokerColor = m_exec.IsBrokerToxic() ? clrRed : ((m_exec.GetBrokerScore() < 85) ? clrYellow : clrDeepSkyBlue);

   UpdateLabel(p+"bs1", col1, y, "Broker Score/State:", clrLightGray, 9);
   UpdateLabel(p+"bs2", col2, y, brokerText, brokerColor, 9);
   y += step;

   // ========================================================================
   // SECAO 4: ASSET STATUS (EA + Symbol - nunca conta global)
   // ========================================================================
   UpdateLabel(p+"s_asset", col1, y, ">> ASSET STATUS (EA+SYMBOL)", clrDarkOrange, 9);
   y += 14;

   UpdateLabel(p+"as1", col1, y, "Ganho Diario:", clrLightGray, 9);
   UpdateLabel(p+"as2", col2, y, DoubleToString(as.daily_gain, 2), (as.daily_gain >= 0) ? clrLime : clrRed, 9);
   y += step;

   UpdateLabel(p+"as3", col1, y, "Posicoes Abertas:", clrLightGray, 9);
   UpdateLabel(p+"as4", col2, y, IntegerToString(as.open_positions), (as.open_positions > 0) ? clrDeepSkyBlue : clrGray, 9);
   y += step;

   UpdateLabel(p+"as5", col1, y, "Lotes Abertos:", clrLightGray, 9);
   UpdateLabel(p+"as6", col2, y, DoubleToString(as.open_lots, 2), (as.open_lots > 0) ? clrDeepSkyBlue : clrGray, 9);
   y += step;

   UpdateLabel(p+"as7", col1, y, "DD% (dia):", clrLightGray, 9);
   UpdateLabel(p+"as8", col2, y, DoubleToString(as.daily_dd_pct, 2) + " %", (as.daily_dd_pct > 0) ? clrOrangeRed : clrLime, 9);
   y += step;

   UpdateLabel(p+"as9", col1, y, "DD% Max (hist):", clrLightGray, 9);
   UpdateLabel(p+"as10", col2, y, DoubleToString(as.max_dd_pct, 2) + " %", (as.max_dd_pct > 0) ? clrOrangeRed : clrLime, 9);
   y += step;

   UpdateLabel(p+"as11", col1, y, "P/L Acumulado:", clrLightGray, 9);
   UpdateLabel(p+"as12", col2, y, DoubleToString(as.cumulative_pnl, 2), (as.cumulative_pnl >= 0) ? clrLime : clrRed, 9);
   y += step;

   // ========================================================================
   // SECAO 5: PERFORMANCE (trades fechados do EA no symbol)
   // ========================================================================
   UpdateLabel(p+"s_perf", col1, y, ">> PERFORMANCE", clrDarkOrange, 9);
   y += 14;

   UpdateLabel(p+"pf1", col1, y, "Trades Fechados:", clrLightGray, 9);
   UpdateLabel(p+"pf2", col2, y, IntegerToString(ps.closed_trades), clrWhite, 9);
   y += step;

   UpdateLabel(p+"pf3", col1, y, "WinRate %:", clrLightGray, 9);
   UpdateLabel(p+"pf4", col2, y, DoubleToString(ps.win_rate, 1) + " %", (ps.win_rate >= 50.0) ? clrLime : clrOrangeRed, 9);
   y += step;

   UpdateLabel(p+"pf5", col1, y, "Profit Factor:", clrLightGray, 9);
   UpdateLabel(p+"pf6", col2, y, DoubleToString(ps.profit_factor, 2), (ps.profit_factor >= 1.0) ? clrLime : clrRed, 9);
   y += step;

   UpdateLabel(p+"pf7", col1, y, "RRR (Avg W/L):", clrLightGray, 9);
   UpdateLabel(p+"pf8", col2, y, DoubleToString(ps.rrr, 2), (ps.rrr > 0.0) ? clrLime : clrGray, 9);
   y += step;

   UpdateLabel(p+"pf9", col1, y, "Expectancy:", clrLightGray, 9);
   UpdateLabel(p+"pf10", col2, y, DoubleToString(ps.expectancy, 2), (ps.expectancy >= 0) ? clrLime : clrRed, 9);
   y += step;

   UpdateLabel(p+"pf11", col1, y, "Z-Score:", clrLightGray, 9);
   UpdateLabel(p+"pf12", col2, y, DoubleToString(ps.z_score, 2), (MathAbs(ps.z_score) < 2.0) ? clrLime : clrYellow, 9);
   y += step;

   UpdateLabel(p+"pf13", col1, y, "Streak Max W/L:", clrLightGray, 9);
   UpdateLabel(p+"pf14", col2, y, StringFormat("%d / %d", ps.max_consec_wins, ps.max_consec_losses), clrWhite, 9);
   y += step;

   UpdateLabel(p+"pf15", col1, y, "DD Max (hist):", clrLightGray, 9);
   UpdateLabel(p+"pf16", col2, y, DoubleToString(ps.max_dd, 2), (ps.max_dd > 0.0) ? clrOrangeRed : clrLime, 9);
   y += step;

   //--- altura dinamica do fundo
   int panel_h = (y - y0) + 30;
   if(panel_h < 700) panel_h = 700;
   ObjectSetInteger(0, p+"bg", OBJPROP_YSIZE, panel_h);
   ObjectSetInteger(0, p+"bg", OBJPROP_XSIZE, 340);
}

//+------------------------------------------------------------------+
//| CRIACAO/ATUALIZACAO DE TEXTOS DA UI                              |
//+------------------------------------------------------------------+
void CPanel::UpdateLabel(string name, int x, int y, string text, color clr, int font_size = 9)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, font_size);
   }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| CRIACAO DO RETANGULO DE BACKGROUND (com resize)                  |
//+------------------------------------------------------------------+
void CPanel::CreatePanelBackground(string name, int x, int y, int w, int h, color bg)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_RAISED);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrBlack);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }
}