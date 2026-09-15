//+------------------------------------------------------------------+
//|                                              CSimplePanel.mqh     |
//|                     Painel Simples para EA QUantFX - Base          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property strict
#include <ALXQuantCore\Modules\StatsTracker.mqh>

//+------------------------------------------------------------------+
//| CSimplePanel - Dashboard leve no canto superior esquerdo           |
//+------------------------------------------------------------------+
class CSimplePanel
{
private:
   string m_prefix;
   int    m_x;
   int    m_y;
   int    m_step;
   int    m_col2;

   void CreateLabel(string name, int x, int y, string text, color clr, int size=9)
   {
      string full = m_prefix + name;
      ObjectCreate(0, full, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, full, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetString(0, full, OBJPROP_TEXT, text);
      ObjectSetInteger(0, full, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, full, OBJPROP_FONTSIZE, size);
      ObjectSetString(0, full, OBJPROP_FONT, "Consolas");
   }

   void CreateBg(string name, int x, int y, int w, int h)
   {
      string full = m_prefix + name;
      ObjectCreate(0, full, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, full, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, full, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, full, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, full, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, full, OBJPROP_YSIZE, h);
      ObjectSetInteger(0, full, OBJPROP_BGCOLOR, C'18,18,18');
      ObjectSetInteger(0, full, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, full, OBJPROP_COLOR, C'40,40,40');
      ObjectSetInteger(0, full, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, full, OBJPROP_BACK, false);
      ObjectSetInteger(0, full, OBJPROP_SELECTABLE, false);
   }

   color DDColor(double pct, double warn, double danger)
   {
      if(pct >= danger) return clrRed;
      if(pct >= warn)   return clrOrange;
      return clrLime;
   }

   color PlColor(double val) { return (val >= 0) ? clrLime : clrRed; }

   string SignStr(double val, bool with_dollar=true)
   {
      string prefix = (val >= 0) ? "+" : "";
      return prefix + (with_dollar ? "$" : "") + DoubleToString(val, 2);
   }

public:
   CSimplePanel() : m_prefix("qfxp_"), m_x(20), m_y(30), m_step(15), m_col2(200) {}

   void Init(int x=20, int y=30)
   {
      m_x = x;
      m_y = y;
      m_col2 = x + 180;
   }

   void Clean() { ObjectsDeleteAll(0, m_prefix); }

   void Draw(
      string ea_name, string ea_version, ulong magic,
      bool isTimeAllowed, bool isFridayEnabled, bool isFridayClose,
      bool isNewsBlocked, double spread_current, double spread_limit,
      bool isGuardBreach, double dailyDD_pct, double maxDD_pct, int dailyTrades, int maxDailyTrades,
      AssetStats &as,
      PerfStats &ps
   )
   {
      if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
         return;

      int y = m_y;
      int step = m_step;
      int col2 = m_col2;

      CreateBg("bg", m_x - 10, m_y - 10, 380, 100);

      //=================================================================
      // HEADER
      //=================================================================
      string title = ea_name + " " + ea_version + " | Magic: " + IntegerToString(magic);
      CreateLabel("title", m_x, y, title, clrDeepSkyBlue, 10);
      y += 16;
      CreateLabel("sep1", m_x, y, "──────────────────────────────────────────", clrDimGray, 8);
      y += 12;

      //=================================================================
      // FILTROS
      //=================================================================
      CreateLabel("s_flt", m_x, y, ">> FILTROS", clrDarkOrange, 9);
      y += step;

      //--- Time Filter
      string time_str = isTimeAllowed ? "ALLOWED" : "BLOCKED";
      if(isFridayEnabled)
         time_str += isFridayClose ? " (Sexta: desatualizado)" : " (Sexta: ativo)";
      CreateLabel("lb_time", m_x, y, "Time Filter:", clrLightGray);
      CreateLabel("vl_time", col2, y, time_str, isTimeAllowed ? clrLime : clrRed);
      y += step;

      //--- News Filter
      CreateLabel("lb_news", m_x, y, "News Filter:", clrLightGray);
      CreateLabel("vl_news", col2, y, isNewsBlocked ? "BLOCKED" : "CLEAR", isNewsBlocked ? clrRed : clrLime);
      y += step;

      //--- Spread
      double sprd_pips = spread_current / 10.0;
      double limit_pips = spread_limit / 10.0;
      bool sprd_ok = (spread_limit <= 0.0) || (spread_current <= spread_limit);
      string sprd_str = DoubleToString(sprd_pips, 1) + " (" + DoubleToString(limit_pips, 1) + ")";
      CreateLabel("lb_sprd", m_x, y, "Spread:", clrLightGray);
      CreateLabel("vl_sprd", col2, y, sprd_str, sprd_ok ? clrLime : clrRed);
      y += step;

      //=================================================================
      // EQUITY GUARD
      //=================================================================
      CreateLabel("sep2", m_x, y, "──────────────────────────────────────────", clrDimGray, 8);
      y += 12;
      CreateLabel("s_guard", m_x, y, ">> EQUITY GUARD", clrDarkOrange, 9);
      y += step;

      CreateLabel("lb_dday", m_x, y, "Daily DD:", clrLightGray);
      CreateLabel("vl_dday", col2, y, StringFormat("%.1f%%", dailyDD_pct), DDColor(dailyDD_pct, 2.0, 3.5));
      y += step;

      CreateLabel("lb_dmax", m_x, y, "Max DD:", clrLightGray);
      CreateLabel("vl_dmax", col2, y, StringFormat("%.1f%%", maxDD_pct), DDColor(maxDD_pct, 4.0, 6.0));
      y += step;

      string trades_str = (maxDailyTrades > 0) ? StringFormat("%d/%d", dailyTrades, maxDailyTrades) : IntegerToString(dailyTrades);
      color  trades_clr = (maxDailyTrades > 0 && dailyTrades >= maxDailyTrades) ? clrRed : clrLime;
      CreateLabel("lb_trdcnt", m_x, y, "Trades Today:", clrLightGray);
      CreateLabel("vl_trdcnt", col2, y, trades_str, trades_clr);
      y += step;

      //=================================================================
      // ASSET STATUS
      //=================================================================
      CreateLabel("sep3", m_x, y, "──────────────────────────────────────────", clrDimGray, 8);
      y += 12;
      CreateLabel("s_asset", m_x, y, ">> ASSET STATUS", clrDarkOrange, 9);
      y += step;

      //--- Ganho Diário
      double daily_pct = (as.daily_gain != 0.0 && m_guard_start_bal > 0.0) ? (as.daily_gain / m_guard_start_bal * 100.0) : 0.0;
      string gain_str = SignStr(as.daily_gain) + " (" + (daily_pct >= 0 ? "+" : "") + DoubleToString(daily_pct, 1) + "%)";
      CreateLabel("lb_gain", m_x, y, "Ganho Diário:", clrLightGray);
      CreateLabel("vl_gain", col2, y, gain_str, PlColor(as.daily_gain));
      y += step;

      //--- Posições Abertas
      CreateLabel("lb_pos", m_x, y, "Posições Abertas:", clrLightGray);
      CreateLabel("vl_pos", col2, y, IntegerToString(as.open_positions), clrWhite);
      y += step;

      //--- Lotes Abertos
      CreateLabel("lb_lots", m_x, y, "Lotes Abertos:", clrLightGray);
      CreateLabel("vl_lots", col2, y, DoubleToString(as.open_lots, 2), clrWhite);
      y += step;

      //--- PL Acumulado
      CreateLabel("lb_apl", m_x, y, "PL Acumulado:", clrLightGray);
      CreateLabel("vl_apl", col2, y, SignStr(as.cumulative_pnl), PlColor(as.cumulative_pnl));
      y += step;

      //=================================================================
      // PERFORMANCE
      //=================================================================
      CreateLabel("sep4", m_x, y, "──────────────────────────────────────────", clrDimGray, 8);
      y += 12;
      CreateLabel("s_perf", m_x, y, ">> PERFORMANCE", clrDarkOrange, 9);
      y += step;

      //--- Trades Fechados
      CreateLabel("lb_tc", m_x, y, "Trades Fechados:", clrLightGray);
      CreateLabel("vl_tc", col2, y, IntegerToString(ps.closed_trades), clrWhite);
      y += step;

      //--- Winrate
      color wr_clr = (ps.win_rate >= 50.0) ? clrLime : (ps.win_rate >= 40.0) ? clrOrange : clrRed;
      CreateLabel("lb_wr", m_x, y, "Winrate:", clrLightGray);
      CreateLabel("vl_wr", col2, y, DoubleToString(ps.win_rate, 1) + "%", wr_clr);
      y += step;

      //--- Profit Factor
      color pf_clr = (ps.profit_factor >= 1.5) ? clrLime : (ps.profit_factor >= 1.0) ? clrOrange : clrRed;
      CreateLabel("lb_pf", m_x, y, "Profit Factor:", clrLightGray);
      CreateLabel("vl_pf", col2, y, DoubleToString(ps.profit_factor, 2), pf_clr);
      y += step;

      //--- RRR
      color rrr_clr = (ps.rrr >= 1.5) ? clrLime : (ps.rrr >= 1.0) ? clrOrange : clrRed;
      CreateLabel("lb_rrr", m_x, y, "RRR:", clrLightGray);
      CreateLabel("vl_rrr", col2, y, DoubleToString(ps.rrr, 2), rrr_clr);
      y += step;

      //--- Expectancy
      color exp_clr = (ps.expectancy > 0) ? clrLime : clrRed;
      CreateLabel("lb_exp", m_x, y, "Expectancy:", clrLightGray);
      CreateLabel("vl_exp", col2, y, SignStr(ps.expectancy), exp_clr);
      y += step;

      //--- Z-Score
      color zs_clr = (MathAbs(ps.z_score) >= 2.0) ? clrLime : clrOrange;
      CreateLabel("lb_zs", m_x, y, "Z-Score:", clrLightGray);
      CreateLabel("vl_zs", col2, y, DoubleToString(ps.z_score, 2), zs_clr);
      y += step;

      //--- Streak
      string streak_str;
      color  streak_clr;
      if(ps.max_consec_wins > ps.max_consec_losses)
      { streak_str = IntegerToString(ps.max_consec_wins) + "W"; streak_clr = clrLime; }
      else if(ps.max_consec_losses > 0)
      { streak_str = IntegerToString(ps.max_consec_losses) + "L"; streak_clr = clrRed; }
      else
      { streak_str = "0"; streak_clr = clrGray; }
      CreateLabel("lb_stk", m_x, y, "Streak:", clrLightGray);
      CreateLabel("vl_stk", col2, y, streak_str, streak_clr);
      y += step;

      //=================================================================
      // AJUSTAR ALTURA DO BACKGROUND
      //=================================================================
      int bg_h = (y - m_y) + 15;
      ObjectSetInteger(0, m_prefix + "bg", OBJPROP_YSIZE, bg_h);
   }

   //--- Guard start balance para cálculo de ganho diário %
   double m_guard_start_bal;
   void SetGuardStartBalance(double bal) { m_guard_start_bal = bal; }
};
