//+------------------------------------------------------------------+
//|                                       ALX Regime Panel v1.03.mq5 |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXFund."
#property version   "1.03"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//+------------------------------------------------------------------+
//| Includes                                                         |
//+------------------------------------------------------------------+
#include <ALXQuantCore\Strategy\HurstDFA.mqh>
#include <QuantCoreMarket.mqh>

//+------------------------------------------------------------------+
//| Instances                                                        |
//+------------------------------------------------------------------+
CHurstDFA       m_hurst;   
QCFullStatus    qs;

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "===== Hurst DFA Settings ====="
input int    HurstPeriod     = 200;    // Período para cálculo do Hurst Exponent
input int    HurstMinScale   = 10;     // Escala mínima DFA
input int    HurstMaxScale   = 80;     // Escala máxima DFA

input group "===== Panel Visual ====="
input color  PanelTextColor  = clrWhite;      // Cor padrão dos textos
input color  PanelSeparator  = clrDimGray;    // Cor dos separadores

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
double g_H  = 0.5;
double g_R2 = 0.0;

string qs_regime = "";
string qs_news   = "";
string qs_session= "";

//+------------------------------------------------------------------+
//| Custom indicator initialization                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetTimer(30);
   
   // Inicializa Hurst DFA
   m_hurst.Init(HurstPeriod, HurstMinScale, HurstMaxScale);
   
   // Primeira carga do QuantCore
   UpdateQuantCore();
   
   IndicatorSetString(INDICATOR_SHORTNAME, "ALX Regime Panel");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   CleanObjects("RMDT_");
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Custom indicator iteration (Apenas atualiza o painel)            |
//+------------------------------------------------------------------+
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
   // Atualiza o painel a cada tick para manter o spread e dados sincronizados
   Dashboard();
   
   return rates_total;
}

//+------------------------------------------------------------------+
//| Timer - Atualiza dados pesados (Hurst e API)                    |
//+------------------------------------------------------------------+
void OnTimer()
{
   UpdateQuantCore();
   
   // Atualiza Hurst a cada nova barra para não sobrecarregar
   static datetime last_bar_hurst = 0;
   datetime current_bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   
   if(current_bar != last_bar_hurst)
   {
      g_H  = m_hurst.Get();
      g_R2 = m_hurst.GetConfidence();
      
      last_bar_hurst = current_bar;
   }
}

//+------------------------------------------------------------------+
//| QuantCore Update                                                 |
//+------------------------------------------------------------------+
void UpdateQuantCore()
{
   if(GetQCFullStatus(Symbol(), qs))
   {
      qs_regime = "📊 " + qs.summary;
      qs_news   = (qs.news_active ? qs.next_news_name + " (" + qs.next_news_impact + ") em " + IntegerToString(qs.next_news_minutes_away) + " min" : "Nenhuma");
      qs_session= "LSE=" + (qs.lse_open ? "ABERTA" : "FECHADA") + " | NYSE=" + (qs.nyse_open ? "ABERTA" : "FECHADA");
   }
}

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void Dashboard()
{
   uint rs   = 20;
   uint row1 = 30;
   uint col1 = 15, col2 = 140;
   uint r    = row1;

   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   //--- Title & Asset
   ALXLabel("title", col1, r, 10, "ALX Regime Dashboard v1.03", clrWhite); r += rs;
   ALXLabel("sep0",  col1, r, 8,  "─────────────────────────────────", PanelSeparator); r += rs;
   
   ALXLabel("sym_lbl", col1, r, 8, "Ativo:", PanelTextColor);
   ALXLabel("sym_val", col2, r, 8, _Symbol + " " + EnumToString(_Period), clrGold); r += rs;
   
   ALXLabel("sprd_lbl", col1, r, 8, "Spread:", PanelTextColor);
   ALXLabel("sprd_val", col2, r, 8, (string)spread + " pts", clrTeal); r += rs;

   //--- Hurst DFA Section
   ALXLabel("sep1",  col1, r, 8, "───── HURST DFA ─────", clrDarkViolet); r += rs;
   
   ALXLabel("h_lbl", col1, r, 8, "H / R²:", PanelTextColor);
   ALXLabel("h_val", col2, r, 8, DoubleToString(g_H,3) + " / " + DoubleToString(g_R2,2), clrDarkViolet); r += rs;
   
   ALXLabel("trend_lbl", col1, r, 8, "Trend:", PanelTextColor);
   ALXLabel("trend_val", col2, r, 8, m_hurst.GetTrend(), GetColorTrend()); r += rs;
   
   ALXLabel("vol_lbl", col1, r, 8, "Volatility:", PanelTextColor);
   ALXLabel("vol_val", col2, r, 8, m_hurst.GetVolatility(), GetColorVolatility()); r += rs;
   
   ALXLabel("mom_lbl", col1, r, 8, "Momentum:", PanelTextColor);
   ALXLabel("mom_val", col2, r, 8, m_hurst.GetMomentum(), GetColorMomentum()); r += rs;

/*
   ////--- QuantCore Section
   //ALXLabel("sep2",  col1, r, 8, "───── QUANTCORE ─────", clrDarkSlateGray); r += rs;
   
   ALXLabel("reg_lbl", col1, r, 8, "Regime:", PanelTextColor);
   ALXLabel("reg_val", col2, r, 8, qs_regime, clrTeal); r += rs;
   
   ALXLabel("news_lbl", col1, r, 8, "Notícia:", PanelTextColor);
   ALXLabel("news_val", col2, r, 8, qs_news, clrDarkOrange); r += rs;
   
   ALXLabel("sess_lbl", col1, r, 8, "Sessão:", PanelTextColor);
   ALXLabel("sess_val", col2, r, 8, qs_session, clrTeal); r += rs;
*/
}

//+------------------------------------------------------------------+
//| Color Helpers (Corrigido retorno string -> color)                |
//+------------------------------------------------------------------+
color GetColorTrend()
{
   if(g_R2 < 0.70) return clrDimGray;   // SIDEWAYS (Low Conf)
   if(g_H > 0.55)  return clrTeal;      // BULLISH 🟢
   if(g_H < 0.45)  return clrCrimson;   // BEARISH 🔴
         
   return clrGray; // SIDEWAYS 🟡
}

color GetColorVolatility()
{
   double fast_atr = CustomATR(_Symbol, _Period, 14, 1);
   double slow_atr = CustomATR(_Symbol, _Period, 100, 1);
   
   if(slow_atr == 0) return clrGray; // Evita divisão por zero
            
   if(fast_atr > slow_atr * 1.2) return clrCrimson;  // HIGH 🔴
   if(fast_atr < slow_atr * 0.8) return clrDodgerBlue; // LOW 🔵
         
   return clrTeal; // NORMAL 🟢
}

color GetColorMomentum()
{
   int mom_state = m_hurst.GetMomentumState();
         
   if(mom_state == 2)  return clrTeal;      // STRONG 💪
   if(mom_state == -1) return clrCrimson;   // WEAK 👎
   if(mom_state == -2) return clrOrange;    // REVERSAL ⚠️
         
   return clrGold;   // MODERATE 👍
}

//+------------------------------------------------------------------+
//| ALXLabel                                                         |
//+------------------------------------------------------------------+
void ALXLabel(string name, uint x, int y, int fontsize, string msg, color clr)
{
   string obj = "RMDT_" + name;
   if(ObjectFind(0, obj) < 0)
   {
      ObjectCreate(0, obj, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, obj, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, obj, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, obj, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, obj, OBJPROP_FONTSIZE,  fontsize);
      ObjectSetString(  0, obj, OBJPROP_FONT,      "Trebuchet MS");
   }
   ObjectSetString(  0, obj, OBJPROP_TEXT,  msg);
   ObjectSetInteger(0, obj, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Clean Objects                                                    |
//+------------------------------------------------------------------+
void CleanObjects(string prefix)
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, prefix) != -1)
         ObjectDelete(0, name);
   }
}

//+------------------------------------------------------------------+
//| Helper: iATR personalizado (retorna valor double)                |
//+------------------------------------------------------------------+
double CustomATR(string symbol, ENUM_TIMEFRAMES tf, int period, int shift)
{
   static int handle = INVALID_HANDLE;
   static int lastPeriod = -1;
   static ENUM_TIMEFRAMES lastTf = PERIOD_CURRENT;
   static string lastSymbol = "";

   if(handle == INVALID_HANDLE || lastPeriod != period || lastTf != tf || lastSymbol != symbol)
   {
      if(handle != INVALID_HANDLE) IndicatorRelease(handle);
      handle = iATR(symbol, tf, period);
      if(handle == INVALID_HANDLE) return 0.0;
      lastPeriod = period;
      lastTf = tf;
      lastSymbol = symbol;
   }

   double atrBuffer[];
   if(CopyBuffer(handle, 0, shift, 1, atrBuffer) <= 0) return 0.0;
   return atrBuffer[0];
}
//+------------------------------------------------------------------+