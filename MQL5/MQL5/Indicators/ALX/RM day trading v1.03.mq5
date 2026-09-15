//+------------------------------------------------------------------+
//|                                    DayTrading_H1_Enhanced.mq5   |
//|                                  Copyright 2026                  |
//|   Melhorias: Filtro HTF + ATR/BB + Horário + Volume             |
//|   Sem Repintura | Otimizado para Forex                          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property indicator_chart_window
#property indicator_buffers 5
#property indicator_plots   3

#property indicator_label1  "Bullish Arrow"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue

#property indicator_label2  "Bearish Arrow"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed

#property indicator_label3  "Stop Signal"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrOrange

//+------------------------------------------------------------------+
//| PARÂMETROS DE ENTRADA                                            |
//+------------------------------------------------------------------+

// --- Configurações Base ---
input group  "======= Configurações Base ======="
input int    MinRange        = 5;
input int    MaxRange        = 30;
input int    MaxHistoryBars  = 500;
input int    ArrowSize       = 2;
input color  ArrowUpCol      = clrLightSkyBlue;
input color  ArrowDnCol      = clrTomato;
input color  BullRectangle   = clrLightSkyBlue;
input color  BearRectangle   = clrTomato;

// --- FILTRO 1: Tendência HTF ---
input group  "======= Filtro 1: Tendência (HTF) ======="
input bool         UseHTFFilter    = true;
input ENUM_TIMEFRAMES HTF_Period   = PERIOD_H4;   // Timeframe maior
input int          HTF_MA_Fast     = 20;           // MA rápida no HTF
input int          HTF_MA_Slow     = 50;           // MA lenta no HTF
input ENUM_MA_METHOD HTF_MA_Method = MODE_EMA;
// Lógica: só compra se MA rápida > MA lenta no HTF (tendência de alta)
//         só vende se MA rápida < MA lenta no HTF (tendência de baixa)

// --- FILTRO 2: Volatilidade ATR + Bollinger Bands ---
input group  "======= Filtro 2: Volatilidade (ATR + BB) ======="
input bool   UseVolatilityFilter   = true;
input int    ATR_Period            = 14;
input double ATR_MinMultiplier     = 0.5;   // ATR atual deve ser >= X * ATR médio
input double ATR_MaxMultiplier     = 2.5;   // ATR atual deve ser <= X * ATR médio (evita news)
input int    ATR_AvgPeriod         = 50;    // Período para calcular ATR médio
input int    BB_Period             = 20;
input double BB_Deviation          = 2.0;
input double BB_SqueezeThreshold   = 0.003; // Largura mínima das BB (% do preço)
// Lógica: exige que o mercado esteve comprimido (BB squeeze) antes de romper

// --- FILTRO 3: Horário ---
input group  "======= Filtro 3: Horário ======="
input bool   UseTimeFilter         = true;
input int    Session1_Start        = 8;    // Hora início Sessão Londres (UTC)
input int    Session1_End          = 12;   // Hora fim Sessão Londres
input int    Session2_Start        = 13;   // Hora início Sessão NY (UTC)
input int    Session2_End          = 17;   // Hora fim Sessão NY
input bool   BlockFridayAfternoon  = true; // Bloqueia sexta após 17h UTC
input bool   BlockMondayMorning    = true; // Bloqueia segunda antes de 8h UTC
// Nota: ajuste os horários conforme o offset UTC do seu broker

// --- FILTRO 4: Volume ---
input group  "======= Filtro 4: Volume ======="
input bool   UseVolumeFilter       = true;
input int    Volume_MA_Period      = 20;   // MA do volume para comparação
input double Volume_MinMultiplier  = 1.2;  // Volume da barra deve ser >= X * média
// Lógica: rompimento só é válido se o tick volume for significativamente
//         acima da média — confirma força e participação do mercado

// --- Análise e Dashboard ---
input group  "======= Análise e Dashboard ======="
input bool   AnalysisEnabled  = true;
input bool   DisplayProfits   = true;
input color  AnalysisColor    = clrMagenta;
input string UrFont           = "Tahoma";
input int    UrFontSize       = 7;
input color  UrFontCol        = clrLime;

// --- Alertas ---
input group  "======= Alertas ======="
input string AlertCaption    = "DayTrading Enhanced";
input bool   DisplayAlerts   = true;
input bool   EmailAlerts     = false;
input bool   SoundAlerts     = true;
input bool   PushAlerts      = false;
input string SoundFile       = "alert.wav";

//+------------------------------------------------------------------+
//| BUFFERS                                                          |
//+------------------------------------------------------------------+
double G_ibuf_Buy[];    // Setas de Compra
double G_ibuf_Sell[];   // Setas de Venda
double G_ibuf_Stop[];   // Sinais de Stop
double G_ibuf_Sig[];    // Auxiliar de Sinal
double G_ibuf_Trend[];  // Estado da Tendência

//+------------------------------------------------------------------+
//| HANDLES DE INDICADORES                                           |
//+------------------------------------------------------------------+
int handleATR_Main;   // ATR principal (período base)
int handleATR_Avg;    // ATR para média (período longo)
int handleHTF_Fast;   // MA rápida no HTF
int handleHTF_Slow;   // MA lenta no HTF
int handleBB;         // Bollinger Bands
int handleVolMA;      // MA do Volume

// Variáveis de controle
double   Gd_ATR_spacing;
double   G_close_Buy  = 0.0, G_close_Sell = 0.0;
datetime G_time_alert;
bool     Gi_first     = true;
double   G_high_track = 0, G_low_track = 0;
datetime G_time_high, G_time_low;
int      G_wins = 0, G_losses = 0, G_total_sig = 0;
double   G_pips_accum  = 0;
double   G_entry_price = 0.0;
int      G_entry_time  = 0;
datetime G_last_bull_t = 0, G_last_bear_t = 0;
datetime G_last_bar_time = 0; // Anti-repintura

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   // Vincula buffers
   SetIndexBuffer(0, G_ibuf_Buy,   INDICATOR_DATA);
   SetIndexBuffer(1, G_ibuf_Sell,  INDICATOR_DATA);
   SetIndexBuffer(2, G_ibuf_Stop,  INDICATOR_DATA);
   SetIndexBuffer(3, G_ibuf_Sig,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(4, G_ibuf_Trend, INDICATOR_CALCULATIONS);

   // ArraySetAsSeries em todos os buffers
   ArraySetAsSeries(G_ibuf_Buy,   true);
   ArraySetAsSeries(G_ibuf_Sell,  true);
   ArraySetAsSeries(G_ibuf_Stop,  true);
   ArraySetAsSeries(G_ibuf_Sig,   true);
   ArraySetAsSeries(G_ibuf_Trend, true);

   // Códigos de seta
   PlotIndexSetInteger(0, PLOT_ARROW, 233); // ↑ compra
   PlotIndexSetInteger(1, PLOT_ARROW, 234); // ↓ venda
   PlotIndexSetInteger(2, PLOT_ARROW, 159); // X stop

   // EMPTY_VALUE explícito
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   PlotIndexSetInteger(0, PLOT_LINE_COLOR, ArrowUpCol);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, ArrowDnCol);
   PlotIndexSetInteger(0, PLOT_LINE_WIDTH, ArrowSize);
   PlotIndexSetInteger(1, PLOT_LINE_WIDTH, ArrowSize);

   // Cria handles dos indicadores auxiliares
   handleATR_Main = iATR(_Symbol, _Period, ATR_Period);
   handleATR_Avg  = iATR(_Symbol, _Period, ATR_AvgPeriod);
   handleBB       = iBands(_Symbol, _Period, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   handleVolMA    = iMA(_Symbol, _Period, Volume_MA_Period, 0, MODE_SMA, PRICE_CLOSE);

   if(UseHTFFilter)
   {
      handleHTF_Fast = iMA(_Symbol, HTF_Period, HTF_MA_Fast, 0, HTF_MA_Method, PRICE_CLOSE);
      handleHTF_Slow = iMA(_Symbol, HTF_Period, HTF_MA_Slow, 0, HTF_MA_Method, PRICE_CLOSE);
      if(handleHTF_Fast == INVALID_HANDLE || handleHTF_Slow == INVALID_HANDLE)
      {
         Print("Erro ao criar handles HTF MA: ", GetLastError());
         return(INIT_FAILED);
      }
   }

   if(handleATR_Main == INVALID_HANDLE || handleATR_Avg == INVALID_HANDLE ||
      handleBB == INVALID_HANDLE)
   {
      Print("Erro ao criar handles de indicadores: ", GetLastError());
      return(INIT_FAILED);
   }

   IndicatorSetString(INDICATOR_SHORTNAME, "DT Enhanced [NR]");
   ClearObjects();
   ResetStats();
   G_last_bar_time = 0;

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
   ArraySetAsSeries(time,        true);
   ArraySetAsSeries(open,        true);
   ArraySetAsSeries(high,        true);
   ArraySetAsSeries(low,         true);
   ArraySetAsSeries(close,       true);
   ArraySetAsSeries(tick_volume, true);

   if(rates_total < MaxRange + ATR_AvgPeriod + 5) return(0);

   int limit;

   if(prev_calculated == 0)
   {
      limit = MathMin(rates_total - MaxRange - 2, MaxHistoryBars);
      ResetStats();
      ClearObjects();
      G_last_bar_time = 0;
      ArrayInitialize(G_ibuf_Buy,   EMPTY_VALUE);
      ArrayInitialize(G_ibuf_Sell,  EMPTY_VALUE);
      ArrayInitialize(G_ibuf_Stop,  EMPTY_VALUE);
      ArrayInitialize(G_ibuf_Sig,   EMPTY_VALUE);
      ArrayInitialize(G_ibuf_Trend, 0);
   }
   else
   {
      // ANTI-REPINTURA: só processa quando uma nova barra fechou
      if(time[1] == G_last_bar_time)
         return(rates_total);
      limit = 1;
   }

   for(int i = limit; i >= 1; i--)
   {
      // Não sobrescreve barras com sinal já confirmado
      if(G_ibuf_Buy[i] != EMPTY_VALUE || G_ibuf_Sell[i] != EMPTY_VALUE)
         continue;

      // Inicializa buffers da barra
      G_ibuf_Buy[i]   = EMPTY_VALUE;
      G_ibuf_Sell[i]  = EMPTY_VALUE;
      G_ibuf_Stop[i]  = EMPTY_VALUE;
      G_ibuf_Sig[i]   = EMPTY_VALUE;
      G_ibuf_Trend[i] = G_ibuf_Trend[i + 1];

      // Coleta ATR principal
      double atr_buf[1];
      if(CopyBuffer(handleATR_Main, 0, i, 1, atr_buf) > 0)
         Gd_ATR_spacing = atr_buf[0] / 100.0;

      // -------------------------------------------------------
      // FILTRO 3: HORÁRIO
      // -------------------------------------------------------
      if(UseTimeFilter && !IsValidSession(time[i])) continue;

      // -------------------------------------------------------
      // FILTRO 2: VOLATILIDADE (ATR)
      // -------------------------------------------------------
      if(UseVolatilityFilter && !IsValidVolatility(i)) continue;

      bool signal_found = false;

      for(int r = MinRange; r <= MaxRange && !signal_found; r++)
      {
         // --- Bullish ---
         if(f0_16(i, r, open, close, high, low) || f0_17(i, r, open, close, high, low))
         {
            // FILTRO 1: TENDÊNCIA HTF
            if(UseHTFFilter && !IsBullishTrend(i)) continue;

            // FILTRO 2: BB SQUEEZE (mercado estava comprimido)
            if(UseVolatilityFilter && !WasSqueezed(i, r)) continue;

            // FILTRO 4: VOLUME
            if(UseVolumeFilter && !IsVolumeConfirmed(i, tick_volume)) continue;

            if(G_ibuf_Trend[i] != 0.0 || (G_ibuf_Trend[i] == 0.0 && G_close_Buy > close[i]))
            {
               bool is_win = !(G_ibuf_Trend[i] == 0.0 && G_close_Buy > close[i]);
               if(DrawSignal(i, r + 1, BullRectangle, true, is_win, time, high, low, close))
               {
                  ResetTracker();
                  G_close_Buy     = close[i];
                  G_ibuf_Sig[i]   = 0;
                  G_ibuf_Trend[i] = 0;
                  signal_found    = true;
               }
            }
         }
         // --- Bearish ---
         else if(f0_7(i, r, open, close, high, low) || f0_13(i, r, open, close, high, low))
         {
            // FILTRO 1: TENDÊNCIA HTF
            if(UseHTFFilter && !IsBearishTrend(i)) continue;

            // FILTRO 2: BB SQUEEZE
            if(UseVolatilityFilter && !WasSqueezed(i, r)) continue;

            // FILTRO 4: VOLUME
            if(UseVolumeFilter && !IsVolumeConfirmed(i, tick_volume)) continue;

            if(G_ibuf_Trend[i] != 1.0 || (G_ibuf_Trend[i] == 1.0 && G_close_Sell < close[i]))
            {
               bool is_win = !(G_ibuf_Trend[i] == 1.0 && G_close_Sell < close[i]);
               if(DrawSignal(i, r + 1, BearRectangle, true, is_win, time, high, low, close))
               {
                  ResetTracker();
                  G_close_Sell    = close[i];
                  G_ibuf_Sig[i]   = 1;
                  G_ibuf_Trend[i] = 1;
                  signal_found    = true;
               }
            }
         }
      }

      if(AnalysisEnabled) TrackExtremes(i, high, low, time);
   }

   // Marca barra processada (anti-repintura)
   if(rates_total > 1) G_last_bar_time = time[1];

   // Alertas — apenas na nova barra
   if(G_time_alert != time[0])
   {
      if(!Gi_first)
      {
         if(G_ibuf_Sig[1] == 0.0) ProcessAlert("🟢 COMPRA — Bullish Breakout");
         if(G_ibuf_Sig[1] == 1.0) ProcessAlert("🔴 VENDA  — Bearish Breakout");
      }
      G_time_alert = time[0];
      Gi_first = false;
   }

   ChartRedraw();
   return(rates_total);
}

//+------------------------------------------------------------------+
//| FILTRO 1 — Tendência HTF                                        |
//+------------------------------------------------------------------+
bool IsBullishTrend(int shift)
{
   double fast[1], slow[1];
   if(CopyBuffer(handleHTF_Fast, 0, shift, 1, fast) <= 0) return true;
   if(CopyBuffer(handleHTF_Slow, 0, shift, 1, slow) <= 0) return true;
   return (fast[0] > slow[0]); // MA rápida acima da lenta = tendência de alta
}

bool IsBearishTrend(int shift)
{
   double fast[1], slow[1];
   if(CopyBuffer(handleHTF_Fast, 0, shift, 1, fast) <= 0) return true;
   if(CopyBuffer(handleHTF_Slow, 0, shift, 1, slow) <= 0) return true;
   return (fast[0] < slow[0]); // MA rápida abaixo da lenta = tendência de baixa
}

//+------------------------------------------------------------------+
//| FILTRO 2 — Volatilidade ATR                                     |
//+------------------------------------------------------------------+
bool IsValidVolatility(int shift)
{
   double atr_cur[1], atr_avg[1];
   if(CopyBuffer(handleATR_Main, 0, shift, 1, atr_cur) <= 0) return true;
   if(CopyBuffer(handleATR_Avg,  0, shift, 1, atr_avg) <= 0) return true;

   double ratio = (atr_avg[0] > 0) ? atr_cur[0] / atr_avg[0] : 1.0;

   // Rejeita volatilidade muito baixa (mercado morto) ou muito alta (notícias)
   return (ratio >= ATR_MinMultiplier && ratio <= ATR_MaxMultiplier);
}

//+------------------------------------------------------------------+
//| FILTRO 2B — BB Squeeze (mercado estava comprimido antes)        |
//+------------------------------------------------------------------+
bool WasSqueezed(int bar_signal, int range)
{
   // Verifica se houve squeeze nas N barras antes do rompimento
   int lookback = MathMin(range, BB_Period);
   for(int k = bar_signal + 1; k <= bar_signal + lookback; k++)
   {
      double bb_upper[1], bb_lower[1], bb_mid[1];
      if(CopyBuffer(handleBB, 1, k, 1, bb_upper) <= 0) return true;
      if(CopyBuffer(handleBB, 2, k, 1, bb_lower) <= 0) return true;
      if(CopyBuffer(handleBB, 0, k, 1, bb_mid)   <= 0) return true;

      if(bb_mid[0] <= 0) return true;

      double band_width = (bb_upper[0] - bb_lower[0]) / bb_mid[0];
      if(band_width < BB_SqueezeThreshold) return true; // Houve squeeze — sinal válido
   }
   return false; // Nunca houve squeeze — rejeita
}

//+------------------------------------------------------------------+
//| FILTRO 3 — Horário (Sessões Forex)                              |
//+------------------------------------------------------------------+
bool IsValidSession(datetime bar_time)
{
   MqlDateTime dt;
   TimeToStruct(bar_time, dt);

   int h    = dt.hour;
   int wday = dt.day_of_week;

   // Bloqueia sexta-feira à tarde
   if(BlockFridayAfternoon && wday == 5 && h >= 17) return false;

   // Bloqueia segunda de manhã cedo
   if(BlockMondayMorning && wday == 1 && h < Session1_Start) return false;

   // Permite apenas dentro das sessões configuradas
   bool in_session1 = (h >= Session1_Start && h < Session1_End);
   bool in_session2 = (h >= Session2_Start && h < Session2_End);

   return (in_session1 || in_session2);
}

//+------------------------------------------------------------------+
//| FILTRO 4 — Volume                                               |
//+------------------------------------------------------------------+
bool IsVolumeConfirmed(int shift, const long &tick_volume[])
{
   // Calcula média simples do tick volume das últimas N barras
   double vol_sum = 0;
   int count = 0;
   for(int k = shift + 1; k <= shift + Volume_MA_Period && k < ArraySize(tick_volume); k++)
   {
      vol_sum += (double)tick_volume[k];
      count++;
   }
   if(count == 0) return true;

   double vol_avg = vol_sum / count;
   double vol_cur = (double)tick_volume[shift];

   return (vol_avg > 0 && vol_cur >= vol_avg * Volume_MinMultiplier);
}

//+------------------------------------------------------------------+
//| DrawSignal — Desenha retângulo e plota seta                     |
//+------------------------------------------------------------------+
bool DrawSignal(int Ai_0, int Ai_4, color A_color, bool Ai_12, bool Ai_16,
                const datetime &time[], const double &high[], const double &low[], const double &close[])
{
   int max_idx = Ai_0 + Ai_4 - 1;
   if(max_idx >= ArraySize(time)) return false;

   datetime t_start = time[Ai_0];
   datetime t_end   = time[max_idx];
   string   name    = "RMDT_Rect_" + (string)t_end;

   if((A_color == BullRectangle && t_end <= G_last_bull_t) ||
      (A_color == BearRectangle && t_end <= G_last_bear_t)) return false;

   // Backtest operação anterior
   if(AnalysisEnabled && Ai_16 && G_entry_time > 0 && G_entry_price > 0.0)
   {
      int shift_entry = iBarShift(_Symbol, _Period, (datetime)G_entry_time);
      int shift_high  = iBarShift(_Symbol, _Period, G_time_high);
      int shift_low   = iBarShift(_Symbol, _Period, G_time_low);

      if(shift_entry >= 0 && shift_entry < ArraySize(high))
      {
         if(G_ibuf_Trend[Ai_0] == 0.0) // Long anterior
         {
            if(G_high_track > high[shift_entry])
            {
               int pips = (int)(MathAbs(G_high_track - G_entry_price) / _Point / 10);
               DrawTrendLine("RMDT_Res_" + (string)G_entry_time,
                             (datetime)G_entry_time, G_time_high,
                             G_entry_price, G_high_track);
               DrawText("+" + (string)pips, shift_high, 1, low, high);
               G_pips_accum += pips;
               G_wins++;
            }
            else
            {
               if(shift_entry < ArraySize(G_ibuf_Stop))
                  G_ibuf_Stop[shift_entry] = high[shift_entry];
               G_losses++;
            }
         }
         else // Short anterior
         {
            if(G_low_track < low[shift_entry])
            {
               int pips = (int)(MathAbs(G_entry_price - G_low_track) / _Point / 10);
               DrawTrendLine("RMDT_Res_" + (string)G_entry_time,
                             (datetime)G_entry_time, G_time_low,
                             G_entry_price, G_low_track);
               DrawText("+" + (string)pips, shift_low, 0, low, high);
               G_pips_accum += pips;
               G_wins++;
            }
            else
            {
               if(shift_entry < ArraySize(G_ibuf_Stop))
                  G_ibuf_Stop[shift_entry] = low[shift_entry];
               G_losses++;
            }
         }
      }
   }

   if(Ai_12) { G_entry_time = (int)t_start; G_entry_price = close[Ai_0]; }

   // Calcula extremos do range para o retângulo
   int    idx_h = iHighestIdx(high, Ai_0 + 1, Ai_4 - 1);
   int    idx_l = iLowestIdx(low,  Ai_0 + 1, Ai_4 - 1);
   double h_val = high[idx_h];
   double l_val = low[idx_l];

   if(ObjectCreate(0, name, OBJ_RECTANGLE, 0, t_start, l_val, t_end, h_val))
   {
      ObjectSetInteger(0, name, OBJPROP_COLOR, A_color);
      ObjectSetInteger(0, name, OBJPROP_BACK,  true);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   }

   // Plota seta no buffer correto
   if(A_color == BullRectangle)
   {
      G_ibuf_Buy[Ai_0] = l_val;
      G_last_bull_t    = t_end;
   }
   else
   {
      G_ibuf_Sell[Ai_0] = h_val;
      G_last_bear_t     = t_end;
   }

   G_total_sig++;
   Dashboard();
   return true;
}

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void Dashboard()
{
   if(!AnalysisEnabled) return;

   uint rs   = 18;
   uint row1 = 30;
   uint col1 = 15, col2 = 110;

   double total = G_wins + G_losses;
   double win_pc  = (total > 0) ? MathRound((G_wins / total) * 100) : 0;
   double loss_pc = (total > 0) ? MathRound((G_losses / total) * 100) : 0;
   double avg_pip = (G_total_sig > 0) ? MathCeil(G_pips_accum / G_total_sig) : 0;
   int    spread  = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   string htf_status = UseHTFFilter      ? TimeframeToString(HTF_Period) + " MA" + (string)HTF_MA_Fast + "/" + (string)HTF_MA_Slow : "OFF";
   string vol_status = UseVolatilityFilter? "ATR(" + (string)ATR_Period + ") + BB(" + (string)BB_Period + ")" : "OFF";
   string tim_status = UseTimeFilter      ? (string)Session1_Start + "h-" + (string)Session1_End + "h / " + (string)Session2_Start + "h-" + (string)Session2_End + "h UTC" : "OFF";
   string volm_status= UseVolumeFilter    ? "Vol x" + DoubleToString(Volume_MinMultiplier, 1) : "OFF";

   ALXLabel("title",    col1, row1,          10, "◆ DT Enhanced [NR] v1.03",                        clrBlack);
   ALXLabel("sep1",     col1, row1 + rs,     8,  "────────────────────────────────",                clrDimGray);
   ALXLabel("f1_lbl",   col1, row1 + rs*2,   8,  "Tendência HTF:",                                  clrBlack);
   ALXLabel("f1_val",   col2, row1 + rs*2,   8,  htf_status,                                        UseHTFFilter    ? clrTeal : clrGray);
   ALXLabel("f2_lbl",   col1, row1 + rs*3,   8,  "Volatilidade:",                                   clrBlack);
   ALXLabel("f2_val",   col2, row1 + rs*3,   8,  vol_status,                                        UseVolatilityFilter ? clrTeal : clrGray);
   ALXLabel("f3_lbl",   col1, row1 + rs*4,   8,  "Horário:",                                        clrBlack);
   ALXLabel("f3_val",   col2, row1 + rs*4,   8,  tim_status,                                        UseTimeFilter   ? clrTeal : clrGray);
   ALXLabel("f4_lbl",   col1, row1 + rs*5,   8,  "Volume:",                                         clrBlack);
   ALXLabel("f4_val",   col2, row1 + rs*5,   8,  volm_status,                                       UseVolumeFilter ? clrTeal : clrGray);
   ALXLabel("sep2",     col1, row1 + rs*6,   8,  "────────────────────────────────",                clrDimGray);
   ALXLabel("win_lbl",  col1, row1 + rs*7,   8,  "Winrate:",                                        clrBlack);
   ALXLabel("win_val",  col2, row1 + rs*7,   8,  (string)win_pc + "% (" + (string)G_wins + "/" + (string)(int)total + ")",  clrTeal);
   ALXLabel("loss_lbl", col1, row1 + rs*8,   8,  "Erros:",                                          clrBlack);
   ALXLabel("loss_val", col2, row1 + rs*8,   8,  (string)loss_pc + "% (" + (string)G_losses + "/" + (string)(int)total + ")", clrCrimson);
   ALXLabel("avg_lbl",  col1, row1 + rs*9,   8,  "Média Sinal:",                                    clrBlack);
   ALXLabel("avg_val",  col2, row1 + rs*9,   8,  (string)avg_pip + " pips",                         clrTeal);
   ALXLabel("sprd_lbl", col1, row1 + rs*10,  8,  "Spread:",                                         clrBlack);
   ALXLabel("sprd_val", col2, row1 + rs*10,  8,  (string)spread + " pips",                          clrTeal);
}

string TimeframeToString(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      default:         return "TF?";
   }
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
      ObjectSetString( 0, obj, OBJPROP_FONT,      "Trebuchet MS");
   }
   ObjectSetString( 0, obj, OBJPROP_TEXT,  msg);
   ObjectSetInteger(0, obj, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Helpers Visuais                                                  |
//+------------------------------------------------------------------+
void ProcessAlert(string msg)
{
   string full = "DT Enhanced [" + _Symbol + "] " + msg;
   if(DisplayAlerts) Alert(full);
   if(EmailAlerts)   SendMail(AlertCaption, full);
   if(PushAlerts)    SendNotification(msg + " " + _Symbol);
   if(SoundAlerts)   PlaySound(SoundFile);
}

void DrawTrendLine(string name, datetime t1, datetime t2, double p1, double p2)
{
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     AnalysisColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE,     STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
}

void DrawText(string txt, int shift, int type, const double &low[], const double &high[])
{
   if(!DisplayProfits) return;
   string name  = "RMDT_Txt_" + (string)MathRand();
   double price = (type == 0) ? low[shift]  - Gd_ATR_spacing * 5
                               : high[shift] + Gd_ATR_spacing * 25;
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
   double r_h = h[iHighestIdx(h, i + 1, r)];
   return (c[i] > o[i] && c[i] > r_h && o[i] < c[i+r+1] && c[i] > h[i+r+1]);
}
bool f0_7(int i, int r, const double &o[], const double &c[], const double &h[], const double &l[])
{
   double r_l = l[iLowestIdx(l, i + 1, r)];
   return (c[i] < o[i] && c[i] < r_l && o[i] > c[i+r+1] && c[i] < l[i+r+1]);
}
bool f0_17(int i, int r, const double &o[], const double &c[], const double &h[], const double &l[])
{
   return (c[i] > o[i] && c[i] > h[iHighestIdx(h, i+1, r)] && c[i+r+1] < o[i+r+1]);
}
bool f0_13(int i, int r, const double &o[], const double &c[], const double &h[], const double &l[])
{
   return (c[i] < o[i] && c[i] < l[iLowestIdx(l, i+1, r)] && c[i+r+1] > o[i+r+1]);
}

//+------------------------------------------------------------------+
//| iHighestIdx / iLowestIdx                                        |
//+------------------------------------------------------------------+
int iHighestIdx(const double &arr[], int start, int count)
{
   int best = start, lim = start + count, sz = ArraySize(arr);
   if(lim > sz) lim = sz;
   for(int i = start + 1; i < lim; i++)
      if(arr[i] > arr[best]) best = i;
   return best;
}
int iLowestIdx(const double &arr[], int start, int count)
{
   int best = start, lim = start + count, sz = ArraySize(arr);
   if(lim > sz) lim = sz;
   for(int i = start + 1; i < lim; i++)
      if(arr[i] < arr[best]) best = i;
   return best;
}

//+------------------------------------------------------------------+
//| Utilitários                                                      |
//+------------------------------------------------------------------+
void ClearObjects()    { ObjectsDeleteAll(0, "RMDT"); }
void ResetTracker()    { G_high_track = 0; G_low_track = 0; }
void ResetStats()      { G_wins = 0; G_losses = 0; G_total_sig = 0; G_pips_accum = 0; }

void TrackExtremes(int i, const double &h[], const double &l[], const datetime &t[])
{
   if(h[i] > G_high_track || G_high_track == 0) { G_high_track = h[i]; G_time_high = t[i]; }
   if(l[i] < G_low_track  || G_low_track  == 0) { G_low_track  = l[i]; G_time_low  = t[i]; }
}

void OnDeinit(const int reason) { ClearObjects(); Comment(""); }