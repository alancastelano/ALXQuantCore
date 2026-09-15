//+------------------------------------------------------------------+
//|                                              DayTrading_H1.mq5   |
//|                                  Copyright 2026, Gemini AI User  |
//|                                             Converted from MQL4  |
//|                          CORRIGIDO: Setas de compra/venda        |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property indicator_chart_window
#property indicator_buffers 5
#property indicator_plots   3

// Definição dos Plots (Setas e Sinais)
#property indicator_label1  "Bullish Arrow"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue

#property indicator_label2  "Bearish Arrow"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed

#property indicator_label3  "Stop Signal"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrRed

// Parâmetros de Entrada
input string St_Ex           = "------- Indicator Settings";
input bool   Verbose          = false;
input int    MinRange         = 5;
input int    MaxRange         = 30;
input int    HighLowFilter    = 10;
input int    MaxHistoryBars   = 500;

input string AN_Ex            = "------- Trade Analysis";
input string AN_Ex2           = ">> Analyzes the performance of signals";
input bool   AnalysisEnabled  = true;
input bool   DisplayProfits   = true;
input color  AnalysisColor    = clrMagenta;
input color  AnalysisLabel    = clrAqua;

input int    ArrowSize        = 2;
input color  ArrowUpCol       = clrLightSkyBlue;
input color  ArrowDnCol       = clrTomato;

input string UrFont           = "Tahoma";
input int    UrFontSize       = 7;
input color  UrFontCol        = clrLime;

input string Se_Ex3           = "------- Drawing Boxes";
input color  BullRectangle    = clrLightSkyBlue;
input color  BearRectangle    = clrTomato;

input string Alerts_ex        = "------- Alerts";
input string AlertCaption     = "DayTrading Alert";
input bool   DisplayAlerts    = true;
input bool   EmailAlerts      = false;
input bool   SoundAlerts      = true;
input bool   PushAlerts       = true;
input string SoundFile        = "alert.wav";

// Buffers do Indicador
double G_ibuf_188[]; // Setas de Compra
double G_ibuf_192[]; // Setas de Venda
double G_ibuf_196[]; // Sinais de Stop
double G_ibuf_200[]; // Auxiliar de Sinal (Alerta)
double G_ibuf_204[]; // Estado da Tendência

// Variáveis Globais de Controle e Estatística
int    handleATR;
double Gd_212;
double G_close_220 = 0.0, G_close_228 = 0.0;
datetime G_time_244;
bool   Gi_248 = true;
double G_high_252 = 0, G_low_260 = 0;
datetime G_time_268, G_time_272;
int    G_count_276 = 0, G_count_280 = 0, G_count_288 = 0;
double Gi_284 = 0;
double Gd_292 = 0.0;
int    Gi_300 = 0;
datetime G_datetime_236 = 0, G_datetime_240 = 0;

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   // --- Vinculação dos Buffers ---
   SetIndexBuffer(0, G_ibuf_188, INDICATOR_DATA);
   SetIndexBuffer(1, G_ibuf_192, INDICATOR_DATA);
   SetIndexBuffer(2, G_ibuf_196, INDICATOR_DATA);
   SetIndexBuffer(3, G_ibuf_200, INDICATOR_CALCULATIONS);
   SetIndexBuffer(4, G_ibuf_204, INDICATOR_CALCULATIONS);

   // CORREÇÃO 1: ArraySetAsSeries nos buffers para alinhar com os arrays de preço
   ArraySetAsSeries(G_ibuf_188, true);
   ArraySetAsSeries(G_ibuf_192, true);
   ArraySetAsSeries(G_ibuf_196, true);
   ArraySetAsSeries(G_ibuf_200, true);
   ArraySetAsSeries(G_ibuf_204, true);

   // Códigos de seta: 233 = seta cima, 234 = seta baixo, 159 = X/stop
   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetInteger(2, PLOT_ARROW, 159);

   // CORREÇÃO 2: Declarar EMPTY_VALUE explicitamente para cada plot
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   PlotIndexSetInteger(0, PLOT_LINE_COLOR, ArrowUpCol);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, ArrowDnCol);
   PlotIndexSetInteger(0, PLOT_LINE_WIDTH, ArrowSize);
   PlotIndexSetInteger(1, PLOT_LINE_WIDTH, ArrowSize);

   handleATR = iATR(_Symbol, _Period, 50);
   if(handleATR == INVALID_HANDLE)
   {
      Print("Erro ao criar handle ATR: ", GetLastError());
      return(INIT_FAILED);
   }

   IndicatorSetString(INDICATOR_SHORTNAME, "Day Trading H1");

   f0_12(); // Limpa objetos antigos
   ResetStats();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
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
   // Garante que os arrays de preço também são séries
   ArraySetAsSeries(time,  true);
   ArraySetAsSeries(open,  true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);

   // Garante mínimo de barras disponíveis
   if(rates_total < MaxRange + 2) return(0);

   int limit;
   if(prev_calculated == 0)
   {
      limit = MathMin(rates_total - MaxRange - 2, MaxHistoryBars);
      ResetStats();
      f0_12();
   }
   else
   {
      limit = rates_total - prev_calculated;
      if(limit <= 0) limit = 1;
   }

   for(int i = limit; i >= 1; i--)
   {
      // CORREÇÃO 3: Inicializa buffers de seta com EMPTY_VALUE a cada barra
      G_ibuf_188[i] = EMPTY_VALUE;
      G_ibuf_192[i] = EMPTY_VALUE;
      G_ibuf_196[i] = EMPTY_VALUE;
      G_ibuf_200[i] = EMPTY_VALUE;

      // Cálculo do ATR para espaçamento de objetos
      double atr_val[1];
      if(CopyBuffer(handleATR, 0, i, 1, atr_val) > 0)
         Gd_212 = atr_val[0] / 100.0;

      // Propaga o estado da tendência da barra anterior
      G_ibuf_204[i] = G_ibuf_204[i + 1];

      bool signal_found = false;

      for(int r = MinRange; r <= MaxRange && !signal_found; r++)
      {
         // --- Lógica Bullish (Compra) ---
         if(f0_16(i, r, open, close, high, low) || f0_17(i, r, open, close, high, low))
         {
            if(G_ibuf_204[i] != 0.0 || (G_ibuf_204[i] == 0.0 && G_close_220 > close[i]))
            {
               bool is_win = !(G_ibuf_204[i] == 0.0 && G_close_220 > close[i]);
               if(f0_0(i, r + 1, BullRectangle, true, is_win, time, high, low, close))
               {
                  f0_5();
                  G_close_220    = close[i];
                  G_ibuf_200[i]  = 0;
                  G_ibuf_204[i]  = 0;
                  signal_found   = true;
               }
            }
         }
         // --- Lógica Bearish (Venda) ---
         else if(f0_7(i, r, open, close, high, low) || f0_13(i, r, open, close, high, low))
         {
            if(G_ibuf_204[i] != 1.0 || (G_ibuf_204[i] == 1.0 && G_close_228 < close[i]))
            {
               bool is_win = !(G_ibuf_204[i] == 1.0 && G_close_228 < close[i]);
               if(f0_0(i, r + 1, BearRectangle, true, is_win, time, high, low, close))
               {
                  f0_5();
                  G_close_228    = close[i];
                  G_ibuf_200[i]  = 1;
                  G_ibuf_204[i]  = 1;
                  signal_found   = true;
               }
            }
         }
      }

      if(AnalysisEnabled) f0_3(i, high, low, time);
   }

   // --- Gestão de Alertas (Barra 0) ---
   if(G_time_244 != time[0])
   {
      if(!Gi_248)
      {
         if(G_ibuf_200[1] == 0.0) ProcessAlert("Bullish Breakout");
         if(G_ibuf_200[1] == 1.0) ProcessAlert("Bearish Breakout");
      }
      G_time_244 = time[0];
      Gi_248 = false;
   }

   ChartRedraw();
   return(rates_total);
}

//+------------------------------------------------------------------+
//| f0_0 — Desenha retângulo e plota a seta no buffer correto        |
//+------------------------------------------------------------------+
bool f0_0(int Ai_0, int Ai_4, color A_color_8, bool Ai_12, bool Ai_16,
          const datetime &time[], const double &high[], const double &low[], const double &close[])
{
   datetime t_start = time[Ai_0];
   datetime t_end   = time[Ai_0 + Ai_4 - 1];
   string   name    = "RMDT_Rect_" + (string)t_end;

   if((A_color_8 == BullRectangle && t_end <= G_datetime_240) ||
      (A_color_8 == BearRectangle && t_end <= G_datetime_236)) return false;

   // Backtest da operação anterior
   if(AnalysisEnabled && Ai_16 && Gi_300 > 0 && Gd_292 > 0.0)
   {
      int shift_entry = iBarShift(_Symbol, _Period, (datetime)Gi_300);
      int shift_high  = iBarShift(_Symbol, _Period, G_time_268);
      int shift_low   = iBarShift(_Symbol, _Period, G_time_272);

      int pips = 0;
      if(G_ibuf_204[Ai_0] == 0.0) // Long anterior
      {
         if(G_high_252 > high[shift_entry])
         {
            pips = (int)(MathAbs(G_high_252 - Gd_292) / _Point / 10);
            CreateTrendLine("RMDT_Res_" + (string)Gi_300, (datetime)Gi_300, G_time_268, Gd_292, G_high_252);
            CreateText("+" + (string)pips, shift_high, 1, low, high);
            Gi_284 += pips;
            G_count_276++;
         }
         else
         {
            G_ibuf_196[shift_entry] = high[shift_entry];
            G_count_280++;
         }
      }
      else // Short anterior
      {
         if(G_low_260 < low[shift_entry])
         {
            pips = (int)(MathAbs(Gd_292 - G_low_260) / _Point / 10);
            CreateTrendLine("RMDT_Res_" + (string)Gi_300, (datetime)Gi_300, G_time_272, Gd_292, G_low_260);
            CreateText("+" + (string)pips, shift_low, 0, low, high);
            Gi_284 += pips;
            G_count_276++;
         }
         else
         {
            G_ibuf_196[shift_entry] = low[shift_entry];
            G_count_280++;
         }
      }
   }

   if(Ai_12) { Gi_300 = (int)t_start; Gd_292 = close[Ai_0]; }

   // Calcula high/low do range para o retângulo
   // CORREÇÃO 4: iHighest/iLowest corrigidos retornam índice relativo;
   //             aqui usamos as funções já corrigidas abaixo.
   int    idx_h = iHighestIdx(high, Ai_0 + 1, Ai_4 - 1);
   int    idx_l = iLowestIdx(low,  Ai_0 + 1, Ai_4 - 1);
   double h     = high[idx_h];
   double l     = low[idx_l];

   // Desenha retângulo
   if(ObjectCreate(0, name, OBJ_RECTANGLE, 0, t_start, l, t_end, h))
   {
      ObjectSetInteger(0, name, OBJPROP_COLOR, A_color_8);
      ObjectSetInteger(0, name, OBJPROP_BACK,  false);
   }

   // PLOTAGEM DA SETA: atribui o preço ao buffer correto
   if(A_color_8 == BullRectangle)
   {
      G_ibuf_188[Ai_0] = l;        // Seta de COMPRA na mínima do range
      G_datetime_240   = t_end;
   }
   else
   {
      G_ibuf_192[Ai_0] = h;        // Seta de VENDA na máxima do range
      G_datetime_236   = t_end;
   }

   G_count_288++;
   Dashboard();
   return true;
}

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void Dashboard()
{
   if(!AnalysisEnabled) return;

   uint row_space = 15;
   uint row1      = 100;
   uint row2      = row1 + row_space;
   uint row3      = row2 + row_space;
   uint row4      = row3 + row_space;
   uint row5      = row4 + row_space;
   uint col1      = 15;
   uint col2      = 120;

   double total = G_count_276 + G_count_280;
   if(total > 0)
   {
      double win_pc  = MathRound((G_count_276 / total) * 100);
      double loss_pc = MathRound((G_count_280 / total) * 100);
      double avg_sig = (G_count_288 > 0) ? MathCeil(Gi_284 / G_count_288) : 0;
      int spread_pips = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

      ALXLabel("alx_dash_title",          col1, row1 - row_space, 12, "ALX RM Daytrade v1.00",                                              clrBlack);
      ALXLabel("alx_dash_winrate",        col1, row2,  8, "Winning Trades:",                                                                clrBlack);
      ALXLabel("alx_dash_winrate_value",  col2, row2,  8, (string)win_pc  + "% (" + (string)G_count_276 + " of " + (string)total + ")",    clrBlack);
      ALXLabel("alx_dash_losing",         col1, row3,  8, "Losing Trades:",                                                                 clrBlack);
      ALXLabel("alx_dash_losing_value",   col2, row3,  8, (string)loss_pc + "% (" + (string)G_count_280 + " of " + (string)total + ")",    clrBlack);
      ALXLabel("alx_dash_signal",         col1, row4,  8, "Average Signal:",                                                                clrBlack);
      ALXLabel("alx_dash_signal_value",   col2, row4,  8, (string)avg_sig + " pips",                                                        clrBlack);
      ALXLabel("alx_dash_spread",         col1, row5,  8, "Spread:",                                                                        clrBlack);
      ALXLabel("alx_dash_spread_value",   col2, row5,  8, (string)spread_pips + " pips",                                                    clrBlack);
   }
}

//+------------------------------------------------------------------+
//| ALXLabel                                                         |
//+------------------------------------------------------------------+
void ALXLabel(string name, uint x, int y, int fontsize, string msg, color clr)
{
   string objName = "RMDT" + name;
   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE,  fontsize);
      ObjectSetString( 0, objName, OBJPROP_FONT,      "Trebuchet MS");
   }
   ObjectSetString( 0, objName, OBJPROP_TEXT,  msg);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Helpers de Alerta e Objetos                                      |
//+------------------------------------------------------------------+
void ProcessAlert(string msg)
{
   string fullMsg = "RM Day Trading (" + AlertCaption + ") [" + _Symbol + "] " + msg;
   if(DisplayAlerts) Alert(fullMsg);
   if(EmailAlerts)   SendMail(AlertCaption, fullMsg);
   if(PushAlerts)    SendNotification(msg + " " + _Symbol);
   if(SoundAlerts)   PlaySound(SoundFile);
}

void CreateTrendLine(string name, datetime t1, datetime t2, double p1, double p2)
{
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     AnalysisColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE,     STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
}

void CreateText(string txt, int shift, int type, const double &low[], const double &high[])
{
   if(!DisplayProfits) return;
   string name  = "RMDT_Txt_" + (string)MathRand();
   double price = (type == 0) ? low[shift]  - Gd_212 * 5
                               : high[shift] + Gd_212 * 25;
   ObjectCreate(0, name, OBJ_TEXT, 0, iTime(_Symbol, _Period, shift), price);
   ObjectSetString( 0, name, OBJPROP_TEXT,     txt);
   ObjectSetString( 0, name, OBJPROP_FONT,     UrFont);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, UrFontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR,    UrFontCol);
}

//+------------------------------------------------------------------+
//| Funções Lógicas de Padrão                                        |
//+------------------------------------------------------------------+
bool f0_16(int i, int r, const double &o[], const double &c[], const double &h[], const double &l[])
{
   int idx = iHighestIdx(h, i + 1, r);
   double r_h = h[idx];
   return (c[i] > o[i] && c[i] > r_h && o[i] < c[i + r + 1] && c[i] > h[i + r + 1]);
}

bool f0_7(int i, int r, const double &o[], const double &c[], const double &h[], const double &l[])
{
   int idx = iLowestIdx(l, i + 1, r);
   double r_l = l[idx];
   return (c[i] < o[i] && c[i] < r_l && o[i] > c[i + r + 1] && c[i] < l[i + r + 1]);
}

bool f0_17(int i, int r, const double &o[], const double &c[], const double &h[], const double &l[])
{
   int idx = iHighestIdx(h, i + 1, r);
   return (c[i] > o[i] && c[i] > h[idx] && c[i + r + 1] < o[i + r + 1]);
}

bool f0_13(int i, int r, const double &o[], const double &c[], const double &h[], const double &l[])
{
   int idx = iLowestIdx(l, i + 1, r);
   return (c[i] < o[i] && c[i] < l[idx] && c[i + r + 1] > o[i + r + 1]);
}

//+------------------------------------------------------------------+
//| CORREÇÃO 4: iHighestIdx / iLowestIdx                             |
//| Retornam o ÍNDICE ABSOLUTO do elemento extremo no array série.   |
//| O array é série (índice 0 = barra mais recente), então valores   |
//| maiores de índice = barras mais antigas.                         |
//+------------------------------------------------------------------+
int iHighestIdx(const double &array[], int start, int count)
{
   int best  = start;
   int limit = start + count;
   int sz    = ArraySize(array);
   if(limit > sz) limit = sz;
   for(int i = start + 1; i < limit; i++)
      if(array[i] > array[best]) best = i;
   return best;
}

int iLowestIdx(const double &array[], int start, int count)
{
   int best  = start;
   int limit = start + count;
   int sz    = ArraySize(array);
   if(limit > sz) limit = sz;
   for(int i = start + 1; i < limit; i++)
      if(array[i] < array[best]) best = i;
   return best;
}

//+------------------------------------------------------------------+
//| Utilitários                                                      |
//+------------------------------------------------------------------+
void f0_12()  { ObjectsDeleteAll(0, "RMDT"); }
void f0_5()   { G_high_252 = 0; G_low_260 = 0; }
void ResetStats() { G_count_276 = 0; G_count_280 = 0; G_count_288 = 0; Gi_284 = 0; }

void f0_3(int i, const double &h[], const double &l[], const datetime &t[])
{
   if(h[i] > G_high_252 || G_high_252 == 0) { G_high_252 = h[i]; G_time_268 = t[i]; }
   if(l[i] < G_low_260  || G_low_260  == 0) { G_low_260  = l[i]; G_time_272 = t[i]; }
}

void OnDeinit(const int reason) { f0_12(); Comment(""); }