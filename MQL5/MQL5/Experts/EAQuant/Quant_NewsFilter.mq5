//+------------------------------------------------------------------+
//| NI_NewsFilter.mq5                                                |
//| v4.8.1 - Fix: init Telegram envia (Startup sem Send) + %n->\n  |
//+------------------------------------------------------------------+
#property copyright "NI NewsFilter MQL5 - Mesas Proprietárias"
#property version   "4.81"

const string EA_VERSION = "v4.81";

#property strict
#property description "Filtro de notícias para mesas proprietárias"
#property description "Fonte: Forex Factory Calendar (CSV semanal)"
#property description "Exporta apenas UMA GlobalVariable: NI_CAN_TRADE"

#include <Canvas\Canvas.mqh>
#include <ALXQuantCore\Core\Telegram.mqh>   CTelegram m_telegram(m_token, m_chat_id);
#include <ALXQuantCore\Core\Design.mqh>   CDesign        m_design;

#define NI_NAME        "NI_NewsFilter"
#define NI_PREFIX      "NI_"
#define GV_PREFIX      "NI_"
#define MAX_EVENTS     200
#define DISPLAY_EVENTS 8
#define PANEL_WIDTH    700
#define HDR_HEIGHT     26
#define SES_HEIGHT     52
#define COLHDR_HEIGHT  16
#define ROW_HEIGHT     19
#define FOOT_HEIGHT    24

#define COL_DAY_X      8
#define COL_TIME_X     42
#define COL_CCY_X      88
#define COL_IMP_X      128
#define COL_EVENT_X    148
#define COL_PREV_X     480
#define COL_FCST_X     550
#define COL_ACT_X      625
#define TITLE_MAX_LEN  36
#define MAX_VLINES     20
#define MAX_MARKERS    50

#define FF_CSV_URL     "https://nfs.faireconomy.media/ff_calendar_thisweek.csv"
#define CACHE_FILE     "ALX_NewsFilter_ff_thisweek.csv"

enum ENUM_IMPACT { IMP_HOLIDAY=0, IMP_LOW=1, IMP_MED=2, IMP_HIGH=3 };

struct NewsEvent {
   string   title;
   string   country;
   string   currency;
   datetime time;
   ENUM_IMPACT impact;
   string   prev, fcst, act;
   double   prevNum, fcstNum, actNum;
   int      minUntil;
   string   eventCode;
   bool     allDay;
};

// INPUTS
input string LBL_FILT        = "";           // ========== FILTROS ==========
      string SymbolsFilter   = "";           // Moedas (EUR,USD,JPY)
      int    MinimumImpact   = 0;            // Impacto mínimo (0-3)
      bool   IncludeSpeaks   = true;         // Incluir discursos
      bool   IncludeHolidays = true;         // Incluir feriados
      string FilterKeyword   = "";           // Mostrar contendo
      string ExcludeKeyword  = "";           // Ocultar contendo
      int    DaysLookahead   = 7;            // Dias à frente

input string LBL_EA          = "";           // ========== BLOQUEIO PARA MESAS ==========
input int    BlockBeforeMin  = 30;           // Bloquear X min ANTES da notícia
input int    BlockAfterMin   = 30;           // Bloquear X min DEPOIS da notícia
input int    BlockImpact     = 3;            // Impacto para bloquear (3=HIGH apenas)
      bool   FailSafeBlock   = true;         // Se true, bloqueia operações se falhar ao baixar dados
      int    MaxCacheAgeMin  = 180;          // Idade máxima do cache (min) antes de forçar bloqueio (0=desliga)

      string LBL_VIS         = "";           // ========== VISUAL ==========
      bool   ShowNewsBox     = true;
      bool   ShowTimeLines   = true;
      bool   ShowSessions    = true;
      bool   ShowOldNews     = true;
      int    OldNewsCount    = 5;
      int    HideAfterMin    = 60;
      int    RefreshMin      = 60;           // Min refresh forex factory calandar

      string LBL_CLR         = "";           // ========== CORES ==========
      color  BgColor         = C'15,15,20';
      color  BorderColor     = C'50,50,65';
      color  HeaderColor     = C'10,25,47';
      color  HighColor       = C'229,25,45';
      color  MedColor        = C'247,164,59';
      color  LowColor        = C'236,224,49';
      color  HolidayColor    = C'160,160,160';
      color  TextColor       = C'235,235,240';
      color  DimColor        = C'100,100,110';
      color  OkColor         = C'0,200,110';
      color  BlockColor      = C'200,30,45';

input string LBL_ALRT        = "";           // ========== ALERTAS ==========
input int    NotifyBeforeMin = 30;
input bool   UsePopup        = false;
input bool   UseSound        = false;
input bool   UsePush         = false;
input bool   UseTelegram     = true;        // Enviar alerta ao Telegram

// GLOBAIS
NewsEvent g_ev[];
int       g_count = 0;
bool      g_dataOk = false;
CCanvas   g_canvas;
string    g_cvsName = NI_PREFIX + "Panel";
int       g_cvsX = 10, g_cvsY = 30;
int       g_panelH = 0;
bool      g_dragging = false;
int       g_dragOX = 0, g_dragOY = 0;
bool      g_canvas_ok = false;
datetime  g_lastRender = 0;
datetime  g_lastExport = 0;
datetime  g_lastRefresh = 0;
string    g_vlinePool[];
string    g_vlabPool[];
string    g_markPool[];
string    g_fltLow, g_excLow;
datetime  g_lastAlert = 0;
bool      g_prevCanTrade = true;   // [v4.6] último estado exportado (detecção de transição)
bool      g_stateInit = false;     // [v4.6] absorve o estado inicial sem alarme falso no OnInit
string    g_lastCsv = "";
datetime  g_lastGoodDownload = 0;   // [v4.4] hora do último download BEM-SUCEDIDO (não cache)
string    g_dataSource = "";        // [v4.8] fonte dos dados: LIVE / CACHE (memoria) / CACHE (disco) / FAIL-SAFE

// [CORREÇÃO v4.2/4.3] Offset calculado automaticamente e recalculado periodicamente
int g_timeOffsetHours = 0;

//+------------------------------------------------------------------+
uint MakeARGB(color c, uchar a=255) {
   uint r = (uint)(c & 0xFF);
   uint g = (uint)((c >> 8) & 0xFF);
   uint b = (uint)((c >> 16) & 0xFF);
   return ((uint)a << 24) | (r << 16) | (g << 8) | b;
}

//+------------------------------------------------------------------+
//| [CORREÇÃO CRÍTICA v4.4] O feed público do Forex Factory           |
//| (ff_calendar_thisweek.csv/.xml, sem login/cookie) já vem em       |
//| horário UTC/GMT — NÃO em horário de Nova York, ao contrário do    |
//| que a v4.2/4.3 assumiam. Confirmado comparando os horários crus   |
//| do feed com o calendário oficial ajustado para um fuso conhecido: |
//| p.ex. "German PPI" cru=06:00 == 03:00 em UTC-3, batendo exatamente|
//| com o horário exibido no site para esse fuso. Por isso, NÃO existe|
//| mais cálculo de DST americano nem offset NY: basta converter      |
//| UTC -> hora do servidor da corretora.                             |
//+------------------------------------------------------------------+
int CalculateAutoTimeOffset() {
   // Offset do servidor da corretora em relação ao UTC real (recalculado a cada chamada,
   // portanto acompanha qualquer mudança de DST do próprio corretor).
   datetime nowBroker = TimeCurrent();
   datetime nowGMT = TimeGMT();
   int brokerOffsetHours = (int)MathRound((double)(nowBroker - nowGMT) / 3600.0);

   return brokerOffsetHours;
}

//+------------------------------------------------------------------+
int OnInit() {
   Print(NI_NAME, " v4.8.1 inicializando...");
   Print(NI_NAME, " URL: ", FF_CSV_URL);
   Print(NI_NAME, " Fail-Safe Ativo: ", FailSafeBlock ? "SIM (Bloqueia se falhar)" : "NÃO (Risco!)");
   Print(NI_NAME, " Lembre-se de permitir WebRequest para https://nfs.faireconomy.media");

   g_timeOffsetHours = CalculateAutoTimeOffset();

   ArrayResize(g_ev, MAX_EVENTS);
   ArrayResize(g_vlinePool, MAX_VLINES);
   ArrayResize(g_vlabPool, MAX_VLINES);
   ArrayResize(g_markPool, MAX_MARKERS);

   for(int i=0;i<MAX_VLINES;i++){
      g_vlinePool[i] = NI_PREFIX+"VL_"+IntegerToString(i);
      g_vlabPool[i]  = NI_PREFIX+"VLT_"+IntegerToString(i);
   }
   for(int i=0;i<MAX_MARKERS;i++)
      g_markPool[i] = NI_PREFIX+"MK_"+IntegerToString(i);

   g_fltLow = FilterKeyword; StringToLower(g_fltLow);
   g_excLow = ExcludeKeyword; StringToLower(g_excLow);

   LoadPanelPos();

   if(!g_canvas.CreateBitmapLabel(g_cvsName, g_cvsX, g_cvsY, PANEL_WIDTH, 400, COLOR_FORMAT_ARGB_NORMALIZE)) {
      Print(NI_NAME, ": ❌ FALHA canvas. Erro ", GetLastError());
      g_canvas_ok = false;
   } else {
      g_canvas_ok = true;
      ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   }

   LoadForexFactoryCalendar(true);

   // [v4.4] Garante que a GlobalVariable NI_CAN_TRADE já nasce correta,
   // sem depender de esperar o primeiro tick (evita ler valor "preso" de sessão anterior).
   UpdateTiming();
   ExportCanTrade();

   MqlDateTime dtCheck; TimeToStruct(TimeCurrent(), dtCheck);
   if(dtCheck.day_of_week >= 5) {
      Print(NI_NAME, ": ⚠️ ATENÇÃO: Fim de semana. O CSV 'thisweek' pode não conter notícias de Segunda-feira.");
   }

   // [v4.4] Timer mais curto (15s) porque ele agora também é responsável por manter
   // NI_CAN_TRADE atualizado quando não há ticks (símbolos ilíquidos, gaps, fim de semana).
   EventSetTimer(15);
   ChartRedraw(0);

   Print(NI_NAME, " pronto. ", g_count, " eventos carregados.");

   if(!m_design.Init())
      return(INIT_FAILED);

   // [v4.7] Aviso de inicialização no Telegram (estado já absorvido pelo ExportCanTrade acima)
   if(UseTelegram)
      m_telegram.Startup("Quant NewsFilter " + EA_VERSION ," - INICIADO!");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(g_canvas_ok) g_canvas.Destroy();
   EventKillTimer();
   for(int i=ObjectsTotal(0)-1;i>=0;i--){
      string n = ObjectName(0,i);
      if(StringFind(n, NI_PREFIX)==0) ObjectDelete(0,n);
   }
   if(reason == REASON_REMOVE) {
      GlobalVariableDel(GV_PREFIX+"CAN_TRADE");
      GlobalVariableDel(NI_PREFIX+"PX_"+Symbol());
      GlobalVariableDel(NI_PREFIX+"PY_"+Symbol());
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
// [v4.4] O timer agora é a fonte de verdade "à prova de falta de tick":
// ele atualiza o cronômetro dos eventos e exporta NI_CAN_TRADE independentemente
// de o gráfico estar recebendo ticks ou não (ex.: símbolo parado, fim de semana,
// falha de feed). Antes, isso só acontecia dentro de OnTick(), o que podia deixar
// a variável de bloqueio "presa" em um valor desatualizado.
//+------------------------------------------------------------------+
void OnTimer() {
   if(TimeCurrent() - g_lastRefresh >= RefreshMin*60) {
      LoadForexFactoryCalendar(false);
   } else {
      // Ainda assim recalcula o offset de fuso periodicamente (barato) para
      // acompanhar eventuais mudanças de DST do corretor/NY durante a sessão.
      g_timeOffsetHours = CalculateAutoTimeOffset();
   }
   UpdateTiming();
   ExportCanTrade();
}

//+------------------------------------------------------------------+
void OnTick() {
   UpdateTiming();

   datetime nowSec = TimeCurrent();
   if(nowSec != g_lastRender) {
      g_lastRender = nowSec;
      if(ShowNewsBox && g_canvas_ok) RenderPanel();
      if(ShowTimeLines) DrawTimeLines();
      if(ShowOldNews)   DrawOldMarkers();
   }

   if(TimeCurrent()-g_lastExport >= 1) {
      g_lastExport = TimeCurrent();
      ExportCanTrade();
   }
   ProcessAlerts();
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam) {
   if(!g_canvas_ok) return;
   if(id == CHARTEVENT_MOUSE_MOVE) {
      int x=(int)lparam, y=(int)dparam;
      uint btn=(uint)sparam;
      bool left = ((btn&1)==1);
      if(left) {
         if(!g_dragging && x>=g_cvsX && x<=g_cvsX+PANEL_WIDTH && y>=g_cvsY && y<=g_cvsY+HDR_HEIGHT) {
            g_dragging=true;
            g_dragOX=x-g_cvsX;
            g_dragOY=y-g_cvsY;
            ChartSetInteger(0, CHART_MOUSE_SCROLL, false);
         } else if(g_dragging) {
            g_cvsX=x-g_dragOX;
            g_cvsY=y-g_dragOY;
            if(g_cvsX<0)g_cvsX=0;
            if(g_cvsY<0)g_cvsY=0;
            ObjectSetInteger(0,g_cvsName,OBJPROP_XDISTANCE,g_cvsX);
            ObjectSetInteger(0,g_cvsName,OBJPROP_YDISTANCE,g_cvsY);
         }
      } else if(g_dragging) {
         g_dragging=false;
         ChartSetInteger(0, CHART_MOUSE_SCROLL, true);
         SavePanelPos();
      }
   }
}

//+------------------------------------------------------------------+
bool DownloadFFCsv(string &outCsv) {
   char   post[];
   char   result[];
   string headers = "";
   string result_headers;
   int    timeout = 10000;

   ResetLastError();
   int res = WebRequest("GET", FF_CSV_URL, headers, timeout, post, result, result_headers);

   if(res == -1) {
      int err = GetLastError();
      Print(NI_NAME, ": ❌ WebRequest falhou. Erro ", err);
      if(err == 4060) Print(NI_NAME, ": Adicione https://nfs.faireconomy.media em Ferramentas → Opções → Expert Advisors");
      return false;
   }
   if(res != 200) {
      Print(NI_NAME, ": ❌ HTTP status ", res);
      return false;
   }

   outCsv = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(StringLen(outCsv) < 50) {
      Print(NI_NAME, ": ❌ CSV muito curto ou inválido");
      return false;
   }
   if(StringFind(outCsv, "<!DOCTYPE") >= 0 || StringFind(outCsv, "rate limited") >= 0) {
      Print(NI_NAME, ": ❌ Rate-limit ou erro HTML do Forex Factory.");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
// [v4.8] Persiste o CSV baixado em disco (sandbox \Files\ do terminal),
// preservando UTF-8. Uma 1ª linha com o timestamp do download (epoch)
// permite validar a idade do cache sem depender de FILE_MTIME.
//+------------------------------------------------------------------+
bool SaveDiskCache(const string csv) {
   string payload = StringFormat("%I64d\n", (long)TimeCurrent()) + csv;
   uchar bytes[];
   int len = StringToCharArray(payload, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   if(len <= 1) return false;
   ArrayResize(bytes, len-1);
   int h = FileOpen(CACHE_FILE, FILE_WRITE|FILE_BIN);
   if(h == INVALID_HANDLE) return false;
   bool ok = FileWriteArray(h, bytes);
   FileClose(h);
   return ok;
}

//+------------------------------------------------------------------+
// [v4.8] Lê o cache persistido em disco. Só retorna true se o arquivo
// existir, tiver timestamp válido, estiver dentro de MaxCacheAgeMin e
// com conteúdo válido. Define g_lastGoodDownload = timestamp do cache.
//+------------------------------------------------------------------+
bool LoadDiskCache(string &outCsv) {
   int h = FileOpen(CACHE_FILE, FILE_READ|FILE_BIN);
   if(h == INVALID_HANDLE) return false;

   ulong fsize = FileSize(h);
   if(fsize < 55) {
      FileClose(h);
      return false;
   }

   uchar bytes[];
   ArrayResize(bytes, (int)fsize);
   if(FileReadArray(h, bytes, 0, (int)fsize) != (int)fsize) {
      FileClose(h);
      return false;
   }
   FileClose(h);

   string payload = CharArrayToString(bytes, 0, WHOLE_ARRAY, CP_UTF8);
   int nl = StringFind(payload, "\n");
   if(nl < 0) return false;
   long ts = (long)StringToInteger(StringSubstr(payload, 0, nl));
   if(ts <= 0) return false;

   // [v4.8] Não confia em cache velho (mesma política do MaxCacheAgeMin).
   if(MaxCacheAgeMin > 0 && (TimeCurrent() - ts) > (long)MaxCacheAgeMin*60) return false;

   outCsv = StringSubstr(payload, nl+1);
   if(StringLen(outCsv) < 50) return false;
   g_lastGoodDownload = (datetime)ts;
   return true;
}

//+------------------------------------------------------------------+
// [v4.4] Trata "All Day" (feriados/eventos sem hora) como meia-noite (NY) do dia
// informado, em vez de descartar o evento. Isso permite que feriados apareçam no
// painel quando IncludeHolidays=true (antes eram sempre descartados na filtragem).
//+------------------------------------------------------------------+
datetime ParseFFDateTime(const string dateStr, const string timeStr, bool &isAllDay) {
   isAllDay = false;
   string parts[];
   if(StringSplit(dateStr, '-', parts) != 3) return 0;

   int month = (int)StringToInteger(parts[0]);
   int day   = (int)StringToInteger(parts[1]);
   int year  = (int)StringToInteger(parts[2]);

   if(StringFind(timeStr, "All Day") >= 0 || StringLen(timeStr) < 4) {
      isAllDay = true;
      string dtStr0 = StringFormat("%04d.%02d.%02d 00:00", year, month, day);
      datetime dt0 = StringToTime(dtStr0);
      dt0 = dt0 + (g_timeOffsetHours * 3600);
      return dt0;
   }

   string t = timeStr;
   StringToLower(t);
   StringReplace(t, " ", "");

   bool isPM = (StringFind(t, "pm") >= 0);
   bool isAM = (StringFind(t, "am") >= 0);
   StringReplace(t, "am", "");
   StringReplace(t, "pm", "");

   string hm[];
   if(StringSplit(t, ':', hm) < 2) return 0;

   int hour = (int)StringToInteger(hm[0]);
   int minu = (int)StringToInteger(hm[1]);

   if(isPM && hour < 12) hour += 12;
   if(isAM && hour == 12) hour = 0;

   string dtStr = StringFormat("%04d.%02d.%02d %02d:%02d", year, month, day, hour, minu);
   datetime dt = StringToTime(dtStr);

   // [CORREÇÃO v4.4] O horário cru do feed já é UTC (ver nota em CalculateAutoTimeOffset).
   // Somamos apenas o offset UTC->corretora. Resultado: "dt" fica na MESMA convenção que
   // TimeCurrent() (hora do servidor da corretora), e por isso deve SEMPRE ser comparado
   // com TimeCurrent(), nunca com TimeGMT(). Ver LoadForexFactoryCalendar/UpdateTiming.
   dt = dt + (g_timeOffsetHours * 3600);
   return dt;
}

//+------------------------------------------------------------------+
ENUM_IMPACT ConvertFFImpact(const string impactStr) {
   string s = impactStr;
   StringToLower(s);
   if(StringFind(s, "high") >= 0)     return IMP_HIGH;
   if(StringFind(s, "medium") >= 0 || StringFind(s, "med") >= 0) return IMP_MED;
   if(StringFind(s, "low") >= 0)      return IMP_LOW;
   if(StringFind(s, "holiday") >= 0 || StringFind(s, "non-economic") >= 0) return IMP_HOLIDAY;
   return IMP_LOW;
}

//+------------------------------------------------------------------+
double ParseNumber(const string s) {
   if(StringLen(s) == 0 || s == "—" || s == "-") return EMPTY_VALUE;
   string t = s;
   StringReplace(t, "%", ""); StringReplace(t, "K", ""); StringReplace(t, "M", "");
   StringReplace(t, "B", ""); StringReplace(t, "T", ""); StringReplace(t, ",", "");
   double v = StringToDouble(t);
   if(!MathIsValidNumber(v)) return EMPTY_VALUE;
   return v;
}

//+------------------------------------------------------------------+
void LoadForexFactoryCalendar(const bool skipIfFreshDisk) {
   g_lastRefresh = TimeCurrent();
   g_count = 0;
   g_dataOk = false;

   // [v4.4] Recalcula o offset de fuso a cada atualização do calendário (não só no OnInit),
   // para acompanhar mudanças de DST do corretor/NY se o EA ficar rodando por semanas.
   g_timeOffsetHours = CalculateAutoTimeOffset();

   string csv;
   bool usedDisk = false;
   bool freshDownload = false;

   // [v4.8] No OnInit, se já existe cache fresco em disco, usa SEM WebRequest
   // (evita depender da rede no startup e o falso bloqueio de inicialização).
   if(skipIfFreshDisk) {
      if(LoadDiskCache(csv)) usedDisk = true;
   }

   if(!usedDisk) {
      freshDownload = DownloadFFCsv(csv);
   }

   if(!freshDownload && !usedDisk) {
      if(StringLen(g_lastCsv) > 50) {
         Print(NI_NAME, ": ⚠️ Falha no download. Usando cache anterior (memória).");
         csv = g_lastCsv;
         g_dataSource = "CACHE (memoria)";
      } else if(LoadDiskCache(csv)) {
         Print(NI_NAME, ": ⚠️ Falha no download. Usando cache em disco.");
         usedDisk = true;
         g_dataSource = "CACHE (disco)";
      } else {
         Print(NI_NAME, ": ❌ Falha crítica no download e sem cache. Ativando Fail-Safe.");
         g_dataSource = "FAIL-SAFE";
         return;
      }
   }

   if(freshDownload) {
      g_lastCsv = csv;
      g_lastGoodDownload = TimeCurrent();
      SaveDiskCache(csv);
      g_dataSource = "LIVE";
   } else if(usedDisk) {
      g_dataSource = "CACHE (disco)";
   }

   // [v4.4] Se o cache está sendo reutilizado há tempo demais, força fail-safe:
   // preferimos bloquear operações a confiar em um calendário potencialmente desatualizado
   // (eventos podem ter sido reagendados pelo Forex Factory).
   if(MaxCacheAgeMin > 0 && g_lastGoodDownload > 0 &&
      (TimeCurrent() - g_lastGoodDownload) > MaxCacheAgeMin*60) {
      Print(NI_NAME, ": ❌ Cache do calendário excedeu ", MaxCacheAgeMin, " min sem download novo. Ativando Fail-Safe.");
      g_dataSource = "FAIL-SAFE";
      return;
   }

   string filterCcy[];
   int nCcy = 0;
   if(StringLen(SymbolsFilter) > 0)
      nCcy = StringSplit(SymbolsFilter, ',', filterCcy);
   for(int i=0;i<nCcy;i++){ StringTrimLeft(filterCcy[i]); StringTrimRight(filterCcy[i]); StringToUpper(filterCcy[i]); }

   string lines[];
   int nLines = StringSplit(csv, '\n', lines);
   if(nLines < 2) {
      Print(NI_NAME, ": ❌ CSV sem linhas de dados");
      return;
   }

   // [CORREÇÃO CRÍTICA v4.4] "now" precisa estar na MESMA convenção que e.time (evtTime),
   // que é calculado na hora do SERVIDOR da corretora (ver ParseFFDateTime). Usar TimeGMT()
   // aqui (como na v4.2) introduzia um erro igual ao offset UTC da corretora (tipicamente
   // 2-3+ horas) no cálculo de "quanto falta para a notícia", fazendo o bloqueio abrir/fechar
   // na hora errada.
   datetime now = TimeCurrent();
   datetime from = now - 1*86400;
   datetime to   = now + DaysLookahead*86400;

   int filteredOut = 0;
   int futureCount = 0;

   for(int i=1; i<nLines && g_count<MAX_EVENTS; i++) {
      string line = lines[i];
      StringTrimLeft(line); StringTrimRight(line);
      if(StringLen(line) < 10) continue;
      StringReplace(line, "\r", "");

      string cols[];
      int nCols = StringSplit(line, ',', cols);
      if(nCols < 7) continue;

      // Parser robusto para títulos com vírgulas.
      // Formato real do feed (confirmado via ff_calendar_thisweek.xml) = 8 colunas quando
      // o título NÃO tem vírgula: Title,Country,Date,Time,Impact,Forecast,Previous,URL.
      // Cada vírgula extra dentro do título soma +1 coluna. Fórmula:
      //   titleFields = nCols - 7   (7 = colunas fixas após o título, incluindo URL)
      //   offset      = titleFields - 1 = nCols - 8
      string title = "";
      int offset = 0;
      if(nCols > 8) {
         int titleFields = nCols - 7;
         for(int k=0; k < titleFields; k++) {
            title += (k==0 ? "" : ",") + cols[k];
         }
         offset = titleFields - 1;
      } else {
         title = cols[0];
      }

      string currency = cols[1 + offset];
      string dateStr  = cols[2 + offset];
      string timeStr  = cols[3 + offset];
      string impactS  = cols[4 + offset];
      string fcstStr  = (5 + offset < nCols) ? cols[5 + offset] : "";
      string prevStr  = (6 + offset < nCols) ? cols[6 + offset] : "";

      StringTrimLeft(title); StringTrimRight(title);
      StringTrimLeft(currency); StringTrimRight(currency);
      StringToUpper(currency);

      if(nCcy > 0) {
         bool ok = false;
         for(int c=0; c<nCcy; c++) if(currency == filterCcy[c]) { ok = true; break; }
         if(!ok) { filteredOut++; continue; }
      }

      bool isAllDay = false;
      datetime evtTime = ParseFFDateTime(dateStr, timeStr, isAllDay);
      if(evtTime == 0) { filteredOut++; continue; }
      if(evtTime < from || evtTime > to) { filteredOut++; continue; }

      int minUntil = (int)((evtTime - now)/60);
      if(minUntil < -HideAfterMin) { filteredOut++; continue; }

      ENUM_IMPACT imp = ConvertFFImpact(impactS);
      if(isAllDay && imp != IMP_HOLIDAY) imp = IMP_HOLIDAY; // eventos "All Day" sem hora são tratados como feriado/não-econômico
      if(!PassFilter(title, currency, imp, "")) { filteredOut++; continue; }

      double prevNum = ParseNumber(prevStr);
      double fcstNum = ParseNumber(fcstStr);
      double actNum  = EMPTY_VALUE;
      string actStr  = "—";

      if(StringLen(prevStr)==0) prevStr = "—";
      if(StringLen(fcstStr)==0) fcstStr = "—";

      NewsEvent ne;
      ne.title     = title;
      ne.country   = currency;
      ne.currency  = currency;
      ne.time      = evtTime;
      ne.impact    = imp;
      ne.prev      = prevStr;
      ne.fcst      = fcstStr;
      ne.act       = actStr;
      ne.prevNum   = prevNum;
      ne.fcstNum   = fcstNum;
      ne.actNum    = actNum;
      ne.minUntil  = minUntil;
      ne.eventCode = "";
      ne.allDay    = isAllDay;

      g_ev[g_count++] = ne;
      if(minUntil >= 0) futureCount++;
   }

   SortByTime();
   g_dataOk = (g_count > 0);

   Print(NI_NAME, ": ✅ ", g_count, " eventos carregados (", filteredOut, " filtrados, ", futureCount, " futuros)");
}

//+------------------------------------------------------------------+
bool PassFilter(const string &title, const string &currency, ENUM_IMPACT imp, const string &code) {
   if((int)imp < MinimumImpact) return false;
   if(imp==IMP_HOLIDAY && !IncludeHolidays) return false;
   if(!IncludeSpeaks && (StringFind(title,"Speaks")>=0 || StringFind(title,"Speech")>=0)) return false;

   if(StringLen(g_fltLow)>0){
      string t=title; StringToLower(t);
      if(StringFind(t,g_fltLow)<0) return false;
   }
   if(StringLen(g_excLow)>0){
      string t=title; StringToLower(t);
      if(StringFind(t,g_excLow)>=0) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
void SortByTime() {
   for(int i=1;i<g_count;i++){
      NewsEvent tmp=g_ev[i];
      int j=i-1;
      while(j>=0 && g_ev[j].time>tmp.time){
         g_ev[j+1]=g_ev[j];
         j--;
      }
      g_ev[j+1]=tmp;
   }
}

//+------------------------------------------------------------------+
// [CORREÇÃO CRÍTICA v4.4] Igual à LoadForexFactoryCalendar(): "now" precisa usar
// TimeCurrent() (hora do servidor), pois e.time está nessa mesma convenção.
//+------------------------------------------------------------------+
void UpdateTiming() {
   datetime now = TimeCurrent();
   for(int i=0;i<g_count;i++)
      g_ev[i].minUntil = (int)((g_ev[i].time-now)/60);
}

//+------------------------------------------------------------------+
color ImpColor(ENUM_IMPACT i) {
   if(i==IMP_HIGH) return HighColor;
   if(i==IMP_MED)  return MedColor;
   if(i==IMP_HOLIDAY) return HolidayColor;
   return LowColor;
}

//+------------------------------------------------------------------+
bool IsEventPassed(const NewsEvent &e) {
   return (e.minUntil < 0);
}

//+------------------------------------------------------------------+
void ExportCanTrade() {
   bool canTrade = true;
   NewsEvent blocker;
   bool hasBlocker = false;

   if(!g_dataOk) {
      canTrade = FailSafeBlock ? false : true;
      g_prevCanTrade = canTrade;   // mantém estado sincronizado; fail-safe não notifica (v4.6)
      GlobalVariableSet(GV_PREFIX+"CAN_TRADE", canTrade ? 1.0 : 0.0);
      return;
   }

   for(int i=0;i<g_count;i++){
      const NewsEvent e=g_ev[i];
      if(e.allDay) continue; // feriados "dia inteiro" não entram no cálculo de bloqueio por horário
      if((int)e.impact >= BlockImpact) {
         if(e.minUntil >= -BlockAfterMin && e.minUntil <= BlockBeforeMin) {
            canTrade = false;
            blocker = e;
            hasBlocker = true;
            break;
         }
      }
   }
   GlobalVariableSet(GV_PREFIX+"CAN_TRADE", canTrade ? 1.0 : 0.0);

   if(!g_stateInit) {            // [v4.6] absorve o estado inicial (OnInit) sem alarme falso
      g_prevCanTrade = canTrade;
      g_stateInit = true;
      return;
   }

   if(canTrade && !g_prevCanTrade)      NotifyReleased();
   else if(!canTrade && g_prevCanTrade) NotifyBlocked(blocker, hasBlocker);
   g_prevCanTrade = canTrade;
}

//+------------------------------------------------------------------+
// [v4.6] Alerta Telegram: operação ficou PARADA por notícia bloqueante.
//+------------------------------------------------------------------+
void NotifyBlocked(const NewsEvent &e, bool hasBlocker) {
   if(!UseTelegram) return;
   string msg = "OPERACAO PARADA";
   if(hasBlocker) {
      string imp = (e.impact==IMP_HIGH) ? "ALTA" : (e.impact==IMP_MED) ? "MEDIA" : "BAIXA";
      msg += StringFormat("\nNoticia: %s [%s]\nImpacto: %s\nHorario: %s\nFcst: %s\nOperacao bloqueada (NI_CAN_TRADE=0)",
         e.title, e.currency, imp, TimeToString(e.time, TIME_MINUTES), e.fcst);
   }
   if(e.impact==IMP_HIGH) m_telegram.Critical("NewsFilter - PARADO", msg);
   else m_telegram.Warning("NewsFilter - PARADO", msg);
}

//+------------------------------------------------------------------+
// [v4.6] Alerta Telegram: operação LIBERADA (fim da janela de bloqueio).
//+------------------------------------------------------------------+
void NotifyReleased() {
   if(!UseTelegram) return;
   string msg = "OPERACAO LIBERADA";
   for(int i=0;i<g_count;i++){
      const NewsEvent e=g_ev[i];
      if(e.allDay) continue;
      if((int)e.impact >= BlockImpact && e.minUntil >= 0 && e.minUntil <= BlockBeforeMin) {
         string imp = (e.impact==IMP_HIGH) ? "ALTA" : (e.impact==IMP_MED) ? "MEDIA" : "BAIXA";
         msg += StringFormat("\nProxima noticia: %s [%s] em %d min (impacto %s)",
            e.title, e.currency, e.minUntil, imp);
         break;
      }
   }
   if(StringLen(msg) == StringLen("OPERACAO LIBERADA"))
      msg += "\nSem noticias bloqueantes proximas";
   m_telegram.Info("NewsFilter - LIBERADO", msg);
}

//+------------------------------------------------------------------+
void RenderPanel() {
   int rows=0;
   for(int i=0;i<g_count && rows<DISPLAY_EVENTS;i++)
      if(g_ev[i].minUntil + HideAfterMin >= 0) rows++;

   if(rows==0) rows=1;
   int h = HDR_HEIGHT + (ShowSessions?SES_HEIGHT:0) + COLHDR_HEIGHT + rows*ROW_HEIGHT + FOOT_HEIGHT;
   g_panelH = h;
   g_canvas.Erase(MakeARGB(BgColor,240));
   g_canvas.Rectangle(0,0,PANEL_WIDTH-1,h-1,MakeARGB(BorderColor));
   g_canvas.FillRectangle(0,0,PANEL_WIDTH-1,HDR_HEIGHT-1,MakeARGB(HeaderColor));
   g_canvas.FontSet("Arial Bold",-90);
   g_canvas.TextOut(8,6,"QuantCore - News filter (v4.8.1)",MakeARGB(HighColor));

   MqlDateTime g; TimeToStruct(TimeGMT(),g);
   string gmtS = StringFormat("GMT %02d:%02d", g.hour, g.min);
   MqlDateTime b; TimeToStruct(TimeCurrent(),b);
   string brkS = StringFormat("BRK %02d:%02d", b.hour, b.min);
   g_canvas.FontSet("Arial",-85);
   g_canvas.TextOut(PANEL_WIDTH-145,7,gmtS,MakeARGB(TextColor));
   g_canvas.TextOut(PANEL_WIDTH-75,7,brkS,MakeARGB(DimColor));

   int y = HDR_HEIGHT;
   if(ShowSessions) { DrawSessions(y); y += SES_HEIGHT; }

   g_canvas.FontSet("Arial",-80);
   uint hc = MakeARGB(DimColor);
   g_canvas.TextOut(COL_DAY_X,y+3,"DAY",hc);
   g_canvas.TextOut(COL_TIME_X,y+3,"TIME",hc);
   g_canvas.TextOut(COL_CCY_X,y+3,"CUR",hc);
   g_canvas.TextOut(COL_EVENT_X,y+3,"EVENT",hc);
   g_canvas.TextOut(COL_PREV_X,y+3,"PREV",hc);
   g_canvas.TextOut(COL_FCST_X,y+3,"FCST",hc);
   g_canvas.TextOut(COL_ACT_X,y+3,"ACT",hc);
   g_canvas.LineHorizontal(4,PANEL_WIDTH-5,y+COLHDR_HEIGHT-2,MakeARGB(BorderColor,140));
   y += COLHDR_HEIGHT;

   g_canvas.FontSet("Arial",-85);
   string days[]={"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
   int drawn=0;
   for(int i=0;i<g_count && drawn<DISPLAY_EVENTS;i++){
      if(g_ev[i].minUntil + HideAfterMin < 0) continue;
      const NewsEvent e = g_ev[i];
      if(drawn==0 && e.minUntil>=0)
         g_canvas.FillRectangle(2,y,PANEL_WIDTH-3,y+ROW_HEIGHT-1,MakeARGB(C'35,50,70',120));

      datetime loc = e.time;
      MqlDateTime dt; TimeToStruct(loc,dt);
      bool passed = IsEventPassed(e);
      uint tc = passed ? MakeARGB(DimColor) : MakeARGB(TextColor);
      uint ic = passed ? MakeARGB(DimColor) : MakeARGB(ImpColor(e.impact));

      g_canvas.TextOut(COL_DAY_X,y+3,days[dt.day_of_week],tc);
      g_canvas.TextOut(COL_TIME_X,y+3, e.allDay ? "All Day" : StringFormat("%02d:%02d",dt.hour,dt.min),tc);
      g_canvas.TextOut(COL_CCY_X,y+3,e.currency,ic);
      g_canvas.FillRectangle(COL_IMP_X,y+5,COL_IMP_X+9,y+13,ic);

      string t=e.title;
      if(StringLen(t)>TITLE_MAX_LEN) t=StringSubstr(t,0,TITLE_MAX_LEN-2)+"..";
      g_canvas.TextOut(COL_EVENT_X,y+3,t,tc);
      g_canvas.TextOut(COL_PREV_X,y+3,e.prev,tc);

      uint fc=tc;
      if(!passed && e.fcstNum!=EMPTY_VALUE && e.prevNum!=EMPTY_VALUE){
         if(e.fcstNum>e.prevNum) fc=MakeARGB(OkColor);
         else if(e.fcstNum<e.prevNum) fc=MakeARGB(HighColor);
      }
      g_canvas.TextOut(COL_FCST_X,y+3,e.fcst,fc);

      uint ac=tc;
      if(!passed && StringLen(e.act)>0 && e.act!="—" && e.actNum!=EMPTY_VALUE && e.fcstNum!=EMPTY_VALUE){
         if(e.actNum>e.fcstNum) ac=MakeARGB(OkColor);
         else if(e.actNum<e.fcstNum) ac=MakeARGB(HighColor);
      }
      g_canvas.TextOut(COL_ACT_X,y+3,e.act,ac);
      y+=ROW_HEIGHT; drawn++;
   }

   if(drawn==0){
      g_canvas.TextOut(20,y+5, !g_dataOk ? "⚠️ DADOS INDISPONIVEIS (BLOQUEADO)" : "Sem eventos no periodo", MakeARGB(!g_dataOk ? BlockColor : DimColor));
      y+=ROW_HEIGHT;
   }
   DrawFooter(y);
   g_canvas.Update(false);
}

//+------------------------------------------------------------------+
void DrawSessions(int y0) {
   string nm[]={"SYD","TOK","LON","NY"};
   int op[] ={21,0,8,13};
   int cl[] ={6,9,17,22};
   color cs[] ={C'0,150,136',C'255,152,0',C'33,150,243',C'156,39,176'};
   int tx=45, tw=PANEL_WIDTH-tx-12;
   double hw=(double)tw/24.0;
   MqlDateTime g; TimeToStruct(TimeGMT(),g);
   double nowH = g.hour + g.min/60.0;
   g_canvas.FontSet("Arial",-75);
   for(int i=0;i<4;i++){
      int ry=y0+4+i*12;
      g_canvas.TextOut(8,ry,nm[i],MakeARGB(DimColor));
      g_canvas.FillRectangle(tx,ry+2,tx+tw,ry+8,MakeARGB(C'35,35,45'));
      bool openNow=false;
      if(op[i]<cl[i]) {
         g_canvas.FillRectangle(tx+(int)(op[i]*hw),ry+2,tx+(int)(cl[i]*hw),ry+8,MakeARGB(cs[i],180));
         openNow = (nowH>=op[i] && nowH<cl[i]);
      } else {
         g_canvas.FillRectangle(tx+(int)(op[i]*hw),ry+2,tx+tw,ry+8,MakeARGB(cs[i],180));
         g_canvas.FillRectangle(tx,ry+2,tx+(int)(cl[i]*hw),ry+8,MakeARGB(cs[i],180));
         openNow = (nowH>=op[i] || nowH<cl[i]);
      }
      if(openNow) g_canvas.TextOut(tx+tw+2,ry,"*",MakeARGB(cs[i]));
      int nx=tx+(int)(nowH*hw);
      g_canvas.LineVertical(nx,ry+1,ry+9,MakeARGB(TextColor,200));
   }
}

//+------------------------------------------------------------------+
void DrawFooter(int y) {
   if(!g_dataOk) {
      g_canvas.FillRectangle(0,y,PANEL_WIDTH-1,y+FOOT_HEIGHT-1,MakeARGB(BlockColor,220));
      g_canvas.FontSet("Arial Bold",-90);
      g_canvas.TextOut(8,y+6, "⚠️ BLOQUEADO: FALHA AO BAIXAR DADOS", MakeARGB(clrWhite));
      return;
   }

   bool blocked = false;
   int bMin=9999; string bCcy="", bTitle="";
   int nextHighMin=9999;
   for(int i=0;i<g_count;i++){
      const NewsEvent e=g_ev[i];
      if(e.allDay) continue;
      if((int)e.impact>=BlockImpact) {
         if(e.minUntil>=-BlockAfterMin && e.minUntil<=BlockBeforeMin){
            blocked=true;
            if(e.minUntil<bMin){bMin=e.minUntil;bCcy=e.currency;bTitle=e.title;}
         }
      }
      if((int)e.impact>=IMP_HIGH && e.minUntil>=0 && e.minUntil<nextHighMin)
         nextHighMin=e.minUntil;
   }

   if(blocked) {
      g_canvas.FillRectangle(0,y,PANEL_WIDTH-1,y+FOOT_HEIGHT-1,MakeARGB(BlockColor,220));
      g_canvas.FontSet("Arial Bold",-90);
      string s = StringFormat("X BLOQUEADO - %s %s em %d min", bCcy, bTitle, bMin);
      g_canvas.TextOut(8,y+6,s,MakeARGB(clrWhite));
   } else {
      g_canvas.FillRectangle(0,y,PANEL_WIDTH-1,y+FOOT_HEIGHT-1,MakeARGB(C'10,60,40',220));
      g_canvas.FontSet("Arial Bold",-90);
      string s = "OK PODE OPERAR";
      if(nextHighMin<9999)
         s += StringFormat(" | Proximo HIGH em %dh %02dm", nextHighMin/60, nextHighMin%60);
      g_canvas.TextOut(8,y+6,s,MakeARGB(OkColor));
   }
}

//+------------------------------------------------------------------+
void DrawTimeLines() {
   for(int i=0;i<MAX_VLINES;i++){
      if(ObjectFind(0,g_vlinePool[i])>=0) ObjectSetInteger(0,g_vlinePool[i],OBJPROP_TIMEFRAMES,OBJ_NO_PERIODS);
      if(ObjectFind(0,g_vlabPool[i])>=0) ObjectSetInteger(0,g_vlabPool[i],OBJPROP_TIMEFRAMES,OBJ_NO_PERIODS);
   }
   int n=0;
   for(int i=0;i<g_count && n<MAX_VLINES;i++){
      const NewsEvent e=g_ev[i];
      if(e.minUntil < -HideAfterMin) continue;
      datetime loc = e.time;
      bool passed = IsEventPassed(e);
      color c = passed ? DimColor : ImpColor(e.impact);

      if(ObjectFind(0,g_vlinePool[n])<0){
         ObjectCreate(0,g_vlinePool[n],OBJ_VLINE,0,loc,0);
         ObjectSetInteger(0,g_vlinePool[n],OBJPROP_STYLE,STYLE_DOT);
         ObjectSetInteger(0,g_vlinePool[n],OBJPROP_WIDTH,1);
         ObjectSetInteger(0,g_vlinePool[n],OBJPROP_BACK,true);
         ObjectSetInteger(0,g_vlinePool[n],OBJPROP_SELECTABLE,false);
      }
      ObjectMove(0,g_vlinePool[n],0,loc,0);
      ObjectSetInteger(0,g_vlinePool[n],OBJPROP_COLOR,c);
      ObjectSetInteger(0,g_vlinePool[n],OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);
      ObjectSetString(0,g_vlinePool[n],OBJPROP_TOOLTIP,e.title+" ("+e.currency+")");

      if(ObjectFind(0,g_vlabPool[n])<0){
         ObjectCreate(0,g_vlabPool[n],OBJ_TEXT,0,loc,0);
         ObjectSetInteger(0,g_vlabPool[n],OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
         ObjectSetInteger(0,g_vlabPool[n],OBJPROP_SELECTABLE,false);
      }
      MqlDateTime dt; TimeToStruct(loc,dt);
      double price = iHigh(Symbol(),Period(),0);
      if(price == 0) price = ChartGetDouble(0, CHART_PRICE_MAX);
      ObjectMove(0,g_vlabPool[n],0,loc, price + 20*Point());

      string label = e.currency + " " + (e.allDay ? "All Day" : StringFormat("%02d:%02d",dt.hour,dt.min));
      ObjectSetString(0,g_vlabPool[n],OBJPROP_TEXT, label);
      ObjectSetInteger(0,g_vlabPool[n],OBJPROP_COLOR,c);
      ObjectSetInteger(0,g_vlabPool[n],OBJPROP_FONTSIZE,7);
      ObjectSetString(0,g_vlabPool[n],OBJPROP_FONT,"Arial");
      ObjectSetInteger(0,g_vlabPool[n],OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);
      n++;
   }
}

//+------------------------------------------------------------------+
void DrawOldMarkers() {
   int used=0;
   for(int i=0;i<MAX_MARKERS;i++)
      if(ObjectFind(0,g_markPool[i])>=0) ObjectSetInteger(0,g_markPool[i],OBJPROP_TIMEFRAMES,OBJ_NO_PERIODS);

   for(int i=0;i<g_count && used<MathMin(OldNewsCount,MAX_MARKERS);i++){
      const NewsEvent e=g_ev[i];
      if(e.minUntil>=0) continue;
      if(e.minUntil < -(OldNewsCount*1440)) continue;
      datetime loc=e.time;

      datetime t0=iTime(Symbol(),Period(),0);
      if(t0==0) continue;
      int ps=PeriodSeconds();
      if(ps<=0) continue;
      int sh=(int)MathRound((double)(t0-loc)/ps);
      if(sh<0 || sh>=Bars(Symbol(),Period())) continue;

      double price=iHigh(Symbol(),Period(),sh);
      if(price == 0) price = ChartGetDouble(0, CHART_PRICE_MAX);
      price += 15*Point()*((Digits()==3||Digits()==5)?10:1);

      if(ObjectFind(0,g_markPool[used])<0){
         ObjectCreate(0,g_markPool[used],OBJ_TEXT,0,loc,price);
         ObjectSetInteger(0,g_markPool[used],OBJPROP_ANCHOR,ANCHOR_BOTTOM);
         ObjectSetInteger(0,g_markPool[used],OBJPROP_SELECTABLE,false);
      }
      ObjectMove(0,g_markPool[used],0,loc,price);
      ObjectSetString(0,g_markPool[used],OBJPROP_TEXT,"n");
      ObjectSetString(0,g_markPool[used],OBJPROP_FONT,"Wingdings 3");
      ObjectSetInteger(0,g_markPool[used],OBJPROP_FONTSIZE,9);
      ObjectSetInteger(0,g_markPool[used],OBJPROP_COLOR,DimColor);
      ObjectSetInteger(0,g_markPool[used],OBJPROP_TIMEFRAMES,OBJ_ALL_PERIODS);
      ObjectSetString(0,g_markPool[used],OBJPROP_TOOLTIP,
         StringFormat("%s (%s) | Act: %s | Fcst: %s",e.title,e.currency,
            (StringLen(e.act)>0 && e.act!="—")?e.act:"n/a",e.fcst));
      used++;
   }
}

//+------------------------------------------------------------------+
void ProcessAlerts() {
   if(!UsePopup && !UseSound && !UsePush && !UseTelegram) return;
   if(TimeCurrent()-g_lastAlert < 60) return;

   for(int i=0;i<g_count;i++){
      const NewsEvent e=g_ev[i];
      if(e.allDay) continue;
      if((int)e.impact<BlockImpact) continue;
      if(e.minUntil==NotifyBeforeMin){
         string msg=StringFormat("NI: %s [%s] em %d min | Fcst: %s", e.title, e.currency, e.minUntil, e.fcst);
         if(UsePopup) Alert(msg);
         if(UseSound) PlaySound("alert2.wav");
         if(UsePush) SendNotification(msg);
         if(UseTelegram){
            string impLabel = (e.impact==IMP_HIGH) ? "ALTA" : (e.impact==IMP_MED) ? "MEDIA" : "BAIXA";
            string tgMsg = StringFormat("Noticia iminente: %s [%s]\nImpacto: %s\nEm %d min\nPrevisao (Fcst): %s",
               e.title, e.currency, impLabel, e.minUntil, e.fcst);
            if(e.minUntil <= BlockBeforeMin) tgMsg += "\nOperacao sera bloqueada";
            if(e.impact==IMP_HIGH) m_telegram.Critical("NOTICIA HIGH IMPACT", tgMsg);
            else m_telegram.Warning("NOTICIA", tgMsg);
         }
         g_lastAlert=TimeCurrent();
         break;
      }
   }
}

//+------------------------------------------------------------------+
void SavePanelPos() {
   GlobalVariableSet(NI_PREFIX+"PX_"+Symbol(), g_cvsX);
   GlobalVariableSet(NI_PREFIX+"PY_"+Symbol(), g_cvsY);
}

void LoadPanelPos() {
   if(GlobalVariableCheck(NI_PREFIX+"PX_"+Symbol()))
      g_cvsX=(int)GlobalVariableGet(NI_PREFIX+"PX_"+Symbol());
   if(GlobalVariableCheck(NI_PREFIX+"PY_"+Symbol()))
      g_cvsY=(int)GlobalVariableGet(NI_PREFIX+"PY_"+Symbol());
}
//+------------------------------------------------------------------+