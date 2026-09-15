//+------------------------------------------------------------------+
//|                                            Core/NewsFilter.mqh   |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//|                       CNewsFilter — news + GV + CSV (v11.0)       |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      ""
#property version   "11.0"
/*
    v.11.0 - 2026-09-06 - Refactor: CNewsFilter unificado.
                           Fonte: Auto/GlobalVar/FF Live/CSV.
                           Timezone auto-detect (live) + manual (tester).
                           ForexFactory CSV download (do Quant_NewsFilter).
                           CSV fallback para backtest.
                           GlobalVariable NI_CAN_TRADE como fallback.
    v.7.24 - 2026-08-16 - FF WebRequest (JSON) + CSV fallback.
*/

//+------------------------------------------------------------------+
//| Definições                                                         |
//+------------------------------------------------------------------+
#ifndef NEWS_CSV_FILE
#define NEWS_CSV_FILE "Calendar.csv"
#endif

#ifndef FF_CSV_URL
#define FF_CSV_URL    "https://nfs.faireconomy.media/ff_calendar_thisweek.csv"
#endif

#ifndef ALX_MQL5_DATA_DIR
#define ALX_MQL5_DATA_DIR "C:\\ALXQuant\\data\\mql5\\"
#endif

#ifndef HANDLE
#define HANDLE long
#endif
#ifndef PVOID
#define PVOID  long
#endif
#ifndef GENERIC_READ
#define GENERIC_READ 0x80000000
#endif
#ifndef FILE_SHARE_READ
#define FILE_SHARE_READ 1
#endif
#ifndef FILE_SHARE_WRITE
#define FILE_SHARE_WRITE 2
#endif
#ifndef OPEN_EXISTING
#define OPEN_EXISTING 3
#endif
#ifndef FILE_ATTRIBUTE_NORMAL
#define FILE_ATTRIBUTE_NORMAL 0x80
#endif
#ifndef INVALID_HANDLE_VALUE
#define INVALID_HANDLE_VALUE -1
#endif

//--- Kernel32: bypass sandbox para ler CSV externo
#ifndef ALX_KERNEL32_NEWS
#define ALX_KERNEL32_NEWS
#import "kernel32.dll"
   HANDLE CreateFileW(const string file_name, uint desired_access, uint share_mode,
                      PVOID security_attributes, uint creation_disposition,
                      uint flags_and_attributes, HANDLE template_file);
   int    CloseHandle(HANDLE object);
   int    ReadFile(HANDLE file, uchar &buffer[], uint number_of_bytes_to_read,
                   uint &number_of_bytes_read, PVOID overlapped);
   uint   GetFileSize(HANDLE file, long &file_size_high);
#import
#endif

//+------------------------------------------------------------------+
//| Enum: fonte de dados de notícias                                  |
//+------------------------------------------------------------------+
enum ENUM_NEWS_SOURCE
{
   NEWS_SRC_AUTO      = 0,   // Auto: CSV no backtest, FF no live
   NEWS_SRC_GLOBALVAR = 1,   // GlobalVariable (NI_CAN_TRADE)
   NEWS_SRC_FFLIVE    = 2,   // ForexFactory CSV (download)
   NEWS_SRC_CSV       = 3    // Calendar.csv local
};

//+------------------------------------------------------------------+
//| Enum: motivo do bloqueio de notícia                               |
//+------------------------------------------------------------------+
enum ENUM_NEWS_BLOCK_REASON
{
   NEWS_BLOCK_NONE     = 0,
   NEWS_BLOCK_HIGH     = 1,
   NEWS_BLOCK_MEDIUM   = 2,
   NEWS_BLOCK_LOW      = 3,
   NEWS_BLOCK_SPEECH   = 4,
   NEWS_BLOCK_HOLIDAY  = 5
};

//+------------------------------------------------------------------+
//| Struct: notícia carregada                                         |
//+------------------------------------------------------------------+
struct NoticiaCSV
{
   datetime tempo;
   string   evento;
   string   impacto;
   string   pais;
   bool     is_high;
   bool     is_medium;
   bool     is_low;
   bool     is_speech;
   bool     is_holiday;
};

//+------------------------------------------------------------------+
//| Struct: cache de bloqueio                                         |
//+------------------------------------------------------------------+
struct NewsCache
{
   bool     is_valid;
   bool     is_blocked;
   datetime check_from;
   datetime check_to;
   ENUM_NEWS_BLOCK_REASON block_reason;
   string   block_reason_text;
   string   block_event;
   string   block_currency;
   datetime block_time;
};

//+------------------------------------------------------------------+
//| CNewsFilter — filtro de notícias                                  |
//+------------------------------------------------------------------+
class CNewsFilter
{
private:
   string            m_symbol;
   string            m_prefix;
   ENUM_NEWS_SOURCE  m_source;
   //--- News data
   NoticiaCSV        m_noticias[];
   int               m_noticias_count;
   bool              m_news_loaded;
   datetime          m_csv_mtime;
   //--- FF state
   datetime          m_ff_last_fetch;
   bool              m_ff_loaded;
   datetime          m_last_reload;
   string            m_last_csv;
   datetime          m_last_good_download;
   int               m_offset_hours;
   //--- Cache
   NewsCache         m_news_cache;
   //--- Block
   ENUM_NEWS_BLOCK_REASON m_block_reason;
   string            m_block_reason_text;
   string            m_block_event;
   string            m_block_currency;
   datetime          m_block_time;
   //--- Drawing
   double            m_cached_bottom_price;
   datetime          m_bottom_price_time;

   //--- Helpers (extraídos do Quant_NewsFilter)
   int               CalculateAutoTimeOffset();
   int               GetOffset();
   bool              DownloadFFCsv(string &outCsv);
   bool              SaveDiskCache(const string csv);
   bool              LoadDiskCache(string &outCsv);
   datetime          ParseFFDateTimeCSV(const string dateStr, const string timeStr, bool &isAllDay);
   ENUM_NEWS_BLOCK_REASON ConvertFFImpact(const string impactStr);
   bool              LoadFFCsvContent(const string csv);
   bool              LoadCalendarCSV();
   int               BuscaBinaria(datetime target);
   bool              VerificarBloqueio(int idx, datetime check_from, datetime check_to);
   bool              UsarCache(datetime now, datetime &check_from, datetime &check_to);
   void              SortNoticias();

public:
                     CNewsFilter();
                    ~CNewsFilter() { Deinit(); }

   void              Init();
   bool              IsNewsBlocked();
   void              ReloadNews();
   void              Deinit();
   bool              IsNewsEnabled() { return InpNewsEnabled; }
   ENUM_NEWS_BLOCK_REASON GetBlockReason() { return m_block_reason; }
   string            GetBlockReasonText() { return m_block_reason_text; }
   int               GetNoticiasCount() { return m_noticias_count; }
   void              DebugPrintNewsSample(int count = 5);

   //--- DataMiner compatibility (old Modules/NewsFilter API)
   bool              NewsLoaded() { return m_news_loaded; }
   bool              IsHighNewsActiveNow(datetime now = 0);
   bool              IsMediumNewsActiveNow(datetime now = 0);
   int               MinutesToNextHighNews(datetime now = 0);
   string            GetActiveNewsEvent(datetime now = 0);
   double            GetNewsImpactScore(datetime now = 0);
};

//+------------------------------------------------------------------+
//| Inputs — declarados dentro da classe                              |
//+------------------------------------------------------------------+
input group                "▸ News Filter"
input ENUM_NEWS_SOURCE     InpNewsSource         = NEWS_SRC_AUTO;     // Fonte: Auto/GlobalVar/FF/CSV
input bool                 InpNewsEnabled        = true;              // News filter (On/Off)
input int                  InpNewsMinBefore      = 30;                // Block X min BEFORE news
input int                  InpNewsMinAfter       = 30;                // Block X min AFTER news
input string               InpNewsCurrencies     = "USD,EUR,GBP,JPY,CAD,CHF,AUD,NZD"; // Currencies
input int                  InpNewsBrokerGMT      = 0;                 // Broker GMT offset (tester, live=auto)
input bool                 InpNewsHighImpact     = true;              // Block High Impact?
input bool                 InpNewsSpeakers       = false;             // Block Speeches?
input bool                 InpNewsHolidays       = false;             // Block Holidays?
input int                  InpNewsMaxDrawObjects = 100;               // Max news lines on chart
input int                  InpNewsDrawDaysAhead  = 2;                 // Days ahead to draw
input int                  InpNewsFFRefreshMinutes = 60;              // Refetch FF (min)
input int                  InpNewsMaxCacheAgeMin = 180;               // Max cache age (min, 0=off)

//+------------------------------------------------------------------+
//| Construtor                                                         |
//+------------------------------------------------------------------+
CNewsFilter::CNewsFilter() : m_symbol(_Symbol), m_source(NEWS_SRC_AUTO),
   m_noticias_count(0), m_news_loaded(false), m_csv_mtime(0),
   m_ff_last_fetch(0), m_ff_loaded(false), m_last_reload(0),
   m_last_good_download(0), m_offset_hours(0),
   m_block_reason(NEWS_BLOCK_NONE), m_block_reason_text(""),
   m_cached_bottom_price(0), m_bottom_price_time(0)
{
   m_prefix = "NF_";
   ZeroMemory(m_news_cache);
}

//+------------------------------------------------------------------+
//| CalculateAutoTimeOffset — broker - UTC (confiável no live)        |
//+------------------------------------------------------------------+
int CNewsFilter::CalculateAutoTimeOffset()
{
   datetime nowBroker = TimeCurrent();
   datetime nowGMT    = TimeGMT();
   return (int)MathRound((double)(nowBroker - nowGMT) / 3600.0);
}

//+------------------------------------------------------------------+
//| GetOffset — auto (live) ou manual (tester)                        |
//+------------------------------------------------------------------+
int CNewsFilter::GetOffset()
{
   if(!MQLInfoInteger(MQL_TESTER))
      return CalculateAutoTimeOffset();

   //--- Tester: tenta auto, fallback para input
   int auto_off = CalculateAutoTimeOffset();
   if(auto_off != 0) return auto_off;
   if(InpNewsBrokerGMT != 0) return InpNewsBrokerGMT;
   return 0;
}

//+------------------------------------------------------------------+
//| Init — configura tudo (chamar no OnInit do EA)                    |
//+------------------------------------------------------------------+
void CNewsFilter::Init()
{
   m_symbol = _Symbol;
   m_prefix = "NF_";
   m_offset_hours = GetOffset();

   //--- Auto-detect fonte
   if(InpNewsSource == NEWS_SRC_AUTO)
   {
      if(MQLInfoInteger(MQL_TESTER))
         m_source = NEWS_SRC_CSV;
      else
         m_source = NEWS_SRC_FFLIVE;
   }
   else
      m_source = InpNewsSource;

   //--- Carrega dados conforme fonte
   switch(m_source)
   {
      case NEWS_SRC_GLOBALVAR:
         m_news_loaded = false;
         Print("[NewsFilter] Fonte: GlobalVariable (NI_CAN_TRADE)");
         break;

      case NEWS_SRC_FFLIVE:
         ReloadNews();
         break;

      case NEWS_SRC_CSV:
         if(MQLInfoInteger(MQL_TESTER))
         {
            m_news_loaded = false;
            Print("[NewsFilter] CSV skipped in tester (parser pending). Using GV fallback.");
         }
         else
            LoadCalendarCSV();
         break;

      default:
         m_news_loaded = false;
         break;
   }

   Print("[NewsFilter] Init OK — source=", EnumToString(m_source),
         " offset=", m_offset_hours, "h noticias=", m_noticias_count);
}

//+------------------------------------------------------------------+
//| IsNewsBlocked — verifica se há notícia bloqueante                 |
//+------------------------------------------------------------------+
bool CNewsFilter::IsNewsBlocked()
{
   if(!InpNewsEnabled)
      return false;

   //--- Fonte GlobalVariable: lê diretamente
   if(m_source == NEWS_SRC_GLOBALVAR)
   {
      if(!GlobalVariableCheck("NI_CAN_TRADE"))
         return false;
      return (GlobalVariableGet("NI_CAN_TRADE") < 0.5);
   }

   //--- Sem dados CSV/FF: fallback para GV
   if(!m_news_loaded || m_noticias_count == 0)
   {
      if(GlobalVariableCheck("NI_CAN_TRADE"))
         return (GlobalVariableCheck("NI_CAN_TRADE") && GlobalVariableGet("NI_CAN_TRADE") < 0.5);
      return false;
   }

   //--- Verificação normal via CSV/FF
   datetime now = TimeCurrent();
   datetime check_from = now - InpNewsMinAfter * 60;
   datetime check_to   = now + InpNewsMinBefore * 60;

   if(UsarCache(now, check_from, check_to))
      return m_news_cache.is_blocked;

   int start_idx = BuscaBinaria(check_from);

   if(start_idx >= m_noticias_count || m_noticias[start_idx].tempo > check_to)
   {
      m_news_cache.is_valid   = true;
      m_news_cache.is_blocked = false;
      m_news_cache.check_from = check_from;
      m_news_cache.check_to   = check_to;
      m_block_reason = NEWS_BLOCK_NONE;
      m_block_reason_text = "";
      return false;
   }

   for(int i = start_idx; i < m_noticias_count; i++)
   {
      if(m_noticias[i].tempo > check_to) break;
      if(VerificarBloqueio(i, check_from, check_to))
      {
         m_news_cache.is_valid   = true;
         m_news_cache.is_blocked = true;
         m_news_cache.check_from = check_from;
         m_news_cache.check_to   = check_to;
         m_news_cache.block_reason      = m_block_reason;
         m_news_cache.block_reason_text = m_block_reason_text;
         m_news_cache.block_event       = m_block_event;
         m_news_cache.block_currency    = m_block_currency;
         m_news_cache.block_time        = m_block_time;
         return true;
      }
   }

   m_news_cache.is_valid   = true;
   m_news_cache.is_blocked = false;
   m_news_cache.check_from = check_from;
   m_news_cache.check_to   = check_to;
   m_block_reason = NEWS_BLOCK_NONE;
   m_block_reason_text = "";
   return false;
}

//+------------------------------------------------------------------+
//| VerificarBloqueio — checa se evento bloqueia                      |
//+------------------------------------------------------------------+
bool CNewsFilter::VerificarBloqueio(int idx, datetime check_from, datetime check_to)
{
   if(idx < 0 || idx >= m_noticias_count) return false;

   NoticiaCSV n = m_noticias[idx];
   if(n.tempo < check_from || n.tempo > check_to) return false;

   //--- High impact
   if(n.is_high && InpNewsHighImpact)
   {
      m_block_reason      = NEWS_BLOCK_HIGH;
      m_block_reason_text = "NEWS: " + n.evento;
      m_block_event       = n.evento;
      m_block_currency    = n.pais;
      m_block_time        = n.tempo;
      return true;
   }

   //--- Speech
   if(n.is_speech && InpNewsSpeakers)
   {
      m_block_reason      = NEWS_BLOCK_SPEECH;
      m_block_reason_text = "SPEECH: " + n.evento;
      m_block_event       = n.evento;
      m_block_currency    = n.pais;
      m_block_time        = n.tempo;
      return true;
   }

   //--- Holiday
   if(n.is_holiday && InpNewsHolidays)
   {
      m_block_reason      = NEWS_BLOCK_HOLIDAY;
      m_block_reason_text = "HOLIDAY: " + n.evento;
      m_block_event       = n.evento;
      m_block_currency    = n.pais;
      m_block_time        = n.tempo;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| UsarCache — verifica se pode usar cache                           |
//+------------------------------------------------------------------+
bool CNewsFilter::UsarCache(datetime now, datetime &check_from, datetime &check_to)
{
   if(!m_news_cache.is_valid) return false;
   if(m_news_cache.check_from != check_from || m_news_cache.check_to != check_to) return false;
   return true;
}

//+------------------------------------------------------------------+
//| BuscaBinaria — encontra índice inicial para check_from            |
//+------------------------------------------------------------------+
int CNewsFilter::BuscaBinaria(datetime target)
{
   if(m_noticias_count == 0) return 0;
   int lo = 0, hi = m_noticias_count - 1;
   while(lo < hi)
   {
      int mid = (lo + hi) / 2;
      if(m_noticias[mid].tempo < target) lo = mid + 1;
      else hi = mid;
   }
   return lo;
}

//+------------------------------------------------------------------+
//| ReloadNews — hot-reload do calendário                             |
//+------------------------------------------------------------------+
void CNewsFilter::ReloadNews()
{
   if(MQLInfoInteger(MQL_TESTER)) return;
   datetime now = TimeCurrent();
   if(now - m_last_reload < 60) return;  // throttle 1x/min
   m_last_reload = now;

   m_offset_hours = GetOffset();

   string csv;
   bool freshDownload = DownloadFFCsv(csv);

   if(!freshDownload)
   {
      if(StringLen(m_last_csv) > 50)
      {
         csv = m_last_csv;
      }
      else if(LoadDiskCache(csv))
      {
         // ok
      }
      else
      {
         Print("[NewsFilter] Falha no download e sem cache.");
         m_news_loaded = false;
         return;
      }
   }
   else
   {
      m_last_csv = csv;
      m_last_good_download = now;
      SaveDiskCache(csv);
   }

   //--- Cache velho → fail-safe
   if(InpNewsMaxCacheAgeMin > 0 && m_last_good_download > 0 &&
      (now - m_last_good_download) > InpNewsMaxCacheAgeMin * 60)
   {
      Print("[NewsFilter] Cache excedeu ", InpNewsMaxCacheAgeMin, " min.");
      m_news_loaded = false;
      return;
   }

   LoadFFCsvContent(csv);
}

//+------------------------------------------------------------------+
//| DownloadFFCsv — WebRequest ForexFactory CSV                       |
//+------------------------------------------------------------------+
bool CNewsFilter::DownloadFFCsv(string &outCsv)
{
   if(MQLInfoInteger(MQL_TESTER)) return false;

   char   post[];
   char   result[];
   string headers = "";
   string result_headers;

   ResetLastError();
   int res = WebRequest("GET", FF_CSV_URL, headers, 10000, post, result, result_headers);

   if(res == -1)
   {
      int err = GetLastError();
      if(err == 4060)
         Print("[NewsFilter] Adicione https://nfs.faireconomy.media em Ferramentas → Opções → Expert Advisors");
      return false;
   }
   if(res != 200) return false;

   outCsv = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(StringLen(outCsv) < 50) return false;
   if(StringFind(outCsv, "<!DOCTYPE") >= 0 || StringFind(outCsv, "rate limited") >= 0) return false;

   m_ff_last_fetch = TimeCurrent();
   m_ff_loaded = true;
   return true;
}

//+------------------------------------------------------------------+
//| SaveDiskCache — persiste CSV em disco                             |
//+------------------------------------------------------------------+
bool CNewsFilter::SaveDiskCache(const string csv)
{
   string fname = "ALX_NewsFilter_ff_cache.csv";
   string payload = StringFormat("%I64d\n", (long)TimeCurrent()) + csv;
   uchar bytes[];
   int len = StringToCharArray(payload, bytes, 0, WHOLE_ARRAY, CP_UTF8);
   if(len <= 1) return false;
   ArrayResize(bytes, len - 1);
   int h = FileOpen(fname, FILE_WRITE | FILE_BIN);
   if(h == INVALID_HANDLE) return false;
   bool ok = FileWriteArray(h, bytes);
   FileClose(h);
   return ok;
}

//+------------------------------------------------------------------+
//| LoadDiskCache — lê CSV do disco                                  |
//+------------------------------------------------------------------+
bool CNewsFilter::LoadDiskCache(string &outCsv)
{
   string fname = "ALX_NewsFilter_ff_cache.csv";
   int h = FileOpen(fname, FILE_READ | FILE_BIN);
   if(h == INVALID_HANDLE) return false;

   ulong fsize = FileSize(h);
   if(fsize < 55) { FileClose(h); return false; }

   uchar bytes[];
   ArrayResize(bytes, (int)fsize);
   if(FileReadArray(h, bytes, 0, (int)fsize) != (int)fsize) { FileClose(h); return false; }
   FileClose(h);

   string payload = CharArrayToString(bytes, 0, WHOLE_ARRAY, CP_UTF8);
   int nl = StringFind(payload, "\n");
   if(nl < 0) return false;
   long ts = (long)StringToInteger(StringSubstr(payload, 0, nl));
   if(ts <= 0) return false;

   if(InpNewsMaxCacheAgeMin > 0 && (TimeCurrent() - ts) > (long)InpNewsMaxCacheAgeMin * 60) return false;

   outCsv = StringSubstr(payload, nl + 1);
   if(StringLen(outCsv) < 50) return false;
   m_last_good_download = (datetime)ts;
   return true;
}

//+------------------------------------------------------------------+
//| ParseFFDateTimeCSV — data "M-D-YYYY" + hora "8:30am" → server    |
//+------------------------------------------------------------------+
datetime CNewsFilter::ParseFFDateTimeCSV(const string dateStr, const string timeStr, bool &isAllDay)
{
   isAllDay = false;
   string parts[];
   if(StringSplit(dateStr, '-', parts) != 3) return 0;

   int month = (int)StringToInteger(parts[0]);
   int day   = (int)StringToInteger(parts[1]);
   int year  = (int)StringToInteger(parts[2]);

   if(StringFind(timeStr, "All Day") >= 0 || StringLen(timeStr) < 4)
   {
      isAllDay = true;
      string dtStr = StringFormat("%04d.%02d.%02d 00:00", year, month, day);
      datetime dt = StringToTime(dtStr);
      return dt + m_offset_hours * 3600;
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

   //--- CSV é UTC → converte para server time
   return dt + m_offset_hours * 3600;
}

//+------------------------------------------------------------------+
//| ConvertFFImpact — string → enum                                   |
//+------------------------------------------------------------------+
ENUM_NEWS_BLOCK_REASON CNewsFilter::ConvertFFImpact(const string impactStr)
{
   string s = impactStr;
   StringToLower(s);
   if(StringFind(s, "high") >= 0)     return NEWS_BLOCK_HIGH;
   if(StringFind(s, "med") >= 0)      return NEWS_BLOCK_MEDIUM;
   if(StringFind(s, "low") >= 0)      return NEWS_BLOCK_LOW;
   if(StringFind(s, "holiday") >= 0 || StringFind(s, "non-economic") >= 0) return NEWS_BLOCK_HOLIDAY;
   return NEWS_BLOCK_LOW;
}

//+------------------------------------------------------------------+
//| LoadFFCsvContent — parse CSV → m_noticias[]                      |
//+------------------------------------------------------------------+
bool CNewsFilter::LoadFFCsvContent(const string csv)
{
   m_noticias_count = 0;
   string lines[];
   int nLines = StringSplit(csv, '\n', lines);
   if(nLines < 2) return false;

   //--- Filtro de moedas
   string filterCcy[];
   int nCcy = 0;
   if(StringLen(InpNewsCurrencies) > 0)
   {
      string ccy_str = InpNewsCurrencies;
      StringReplace(ccy_str, " ", "");
      nCcy = StringSplit(ccy_str, ',', filterCcy);
      for(int i = 0; i < nCcy; i++) StringToUpper(filterCcy[i]);
   }

   datetime now     = TimeCurrent();
   datetime from    = now - 86400;
   datetime to      = now + InpNewsDrawDaysAhead * 86400;
   int capacity     = 1000;
   ArrayResize(m_noticias, capacity);

   for(int i = 1; i < nLines && m_noticias_count < capacity; i++)
   {
      string line = lines[i];
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) < 10) continue;
      StringReplace(line, "\r", "");

      string cols[];
      int nCols = StringSplit(line, ',', cols);
      if(nCols < 7) continue;

      //--- Parser robusto para títulos com vírgulas
      string title = "";
      int offset = 0;
      if(nCols > 8)
      {
         int titleFields = nCols - 7;
         for(int k = 0; k < titleFields; k++)
            title += (k == 0 ? "" : ",") + cols[k];
         offset = titleFields - 1;
      }
      else
         title = cols[0];

      string currency = cols[1 + offset];
      string dateStr  = cols[2 + offset];
      string timeStr  = cols[3 + offset];
      string impactS  = cols[4 + offset];

      StringTrimLeft(currency);
      StringTrimRight(currency);
      StringToUpper(currency);

      //--- Filtro por moeda
      if(nCcy > 0)
      {
         bool ok = false;
         for(int c = 0; c < nCcy; c++)
            if(currency == filterCcy[c]) { ok = true; break; }
         if(!ok) continue;
      }

      //--- Parse data/hora
      bool isAllDay = false;
      datetime evtTime = ParseFFDateTimeCSV(dateStr, timeStr, isAllDay);
      if(evtTime == 0) continue;
      if(evtTime < from || evtTime > to) continue;

      //--- Filtro de impacto
      ENUM_NEWS_BLOCK_REASON imp = ConvertFFImpact(impactS);
      if(isAllDay && imp == NEWS_BLOCK_HOLIDAY && !InpNewsHolidays) continue;
      if(imp == NEWS_BLOCK_HIGH && !InpNewsHighImpact) continue;

      //--- Filtro de speakers
      string titleUpper = title;
      StringToUpper(titleUpper);
      if(!InpNewsSpeakers && (StringFind(titleUpper, "SPEAK") >= 0 || StringFind(titleUpper, "SPEECH") >= 0))
         continue;

      //--- Monta struct
      if(m_noticias_count >= capacity)
      {
         ArrayResize(m_noticias, capacity + 500);
         capacity += 500;
      }

      m_noticias[m_noticias_count].tempo      = evtTime;
      m_noticias[m_noticias_count].evento     = title;
      m_noticias[m_noticias_count].impacto    = impactS;
      m_noticias[m_noticias_count].pais       = currency;
      m_noticias[m_noticias_count].is_high    = (imp == NEWS_BLOCK_HIGH);
      m_noticias[m_noticias_count].is_medium  = (imp == NEWS_BLOCK_MEDIUM);
      m_noticias[m_noticias_count].is_low     = (imp == NEWS_BLOCK_LOW);
      m_noticias[m_noticias_count].is_speech  = (StringFind(titleUpper, "SPEAK") >= 0 || StringFind(titleUpper, "SPEECH") >= 0);
      m_noticias[m_noticias_count].is_holiday = (imp == NEWS_BLOCK_HOLIDAY);
      m_noticias_count++;
   }

   SortNoticias();
   ArrayResize(m_noticias, m_noticias_count);
   m_news_loaded = (m_noticias_count > 0);
   m_last_reload = TimeCurrent();

   Print("[NewsFilter] ", m_noticias_count, " notícias carregadas (offset=", m_offset_hours, "h)");
   return m_news_loaded;
}

//+------------------------------------------------------------------+
//| LoadCalendarCSV — fallback via FILE_COMMON (tester) ou Kernel32   |
//+------------------------------------------------------------------+
bool CNewsFilter::LoadCalendarCSV()
{
   string content = "";

   //--- Tester: FILE_COMMON
   if(MQLInfoInteger(MQL_TESTER))
   {
      int handle = FileOpen(NEWS_CSV_FILE, FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI, CP_UTF8);
      if(handle == INVALID_HANDLE) return false;

      while(!FileIsEnding(handle))
      {
         string line = FileReadString(handle);
         if(StringLen(line) == 0 && FileIsEnding(handle)) break;
         content += line + "\n";
      }
      FileClose(handle);
   }
   else
   {
      //--- Live: Kernel32
      string fullPath = ALX_MQL5_DATA_DIR + NEWS_CSV_FILE;
      HANDLE hFile = CreateFileW(fullPath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                 NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
      if(hFile == INVALID_HANDLE_VALUE) return false;

      long sizeHi = 0;
      uint fileSize = GetFileSize(hFile, sizeHi);
      if(fileSize == 0 || fileSize > 64 * 1024 * 1024) { CloseHandle(hFile); return false; }

      uchar buffer[];
      ArrayResize(buffer, fileSize);
      uint bytesRead = 0;
      ReadFile(hFile, buffer, fileSize, bytesRead, NULL);
      CloseHandle(hFile);

      if(bytesRead == 0) return false;
      content = CharArrayToString(buffer, 0, bytesRead, CP_UTF8);
   }

   if(StringLen(content) < 50) return false;

   //--- Parse CSV Calendar (formato diferente do FF CSV)
   //--- Calendar.csv: "DateTime","Currency","Event","Impact"," etc
   //--- Precisa de parser próprio, mas por agora retorna false
   //--- (usar FF CSV como primário)
   Print("[NewsFilter] Calendar.csv carregado, mas parser pendente. Use FF CSV.");
   return false;
}

//+------------------------------------------------------------------+
//| SortNoticias — insertion sort por tempo                           |
//+------------------------------------------------------------------+
void CNewsFilter::SortNoticias()
{
   for(int i = 1; i < m_noticias_count; i++)
   {
      NoticiaCSV tmp = m_noticias[i];
      int j = i - 1;
      while(j >= 0 && m_noticias[j].tempo > tmp.tempo)
      {
         m_noticias[j + 1] = m_noticias[j];
         j--;
      }
      m_noticias[j + 1] = tmp;
   }
}

//+------------------------------------------------------------------+
//| Deinit — limpa gráfico                                            |
//+------------------------------------------------------------------+
void CNewsFilter::Deinit()
{
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_VLINE);
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_TEXT);
}

//+------------------------------------------------------------------+
//| DebugPrintNewsSample — imprime primeiras notícias                  |
//+------------------------------------------------------------------+
void CNewsFilter::DebugPrintNewsSample(int count)
{
   int n = MathMin(count, m_noticias_count);
   Print("[NewsFilter] === Amostra (", n, " de ", m_noticias_count, ") ===");
   for(int i = 0; i < n; i++)
   {
      Print("  ", TimeToString(m_noticias[i].tempo, TIME_DATE | TIME_MINUTES),
            " | ", m_noticias[i].pais,
            " | ", m_noticias[i].impacto,
            " | ", m_noticias[i].evento);
   }
}

//+------------------------------------------------------------------+
//| DataMiner compatibility — old Modules/NewsFilter API              |
//+------------------------------------------------------------------+
bool CNewsFilter::IsHighNewsActiveNow(datetime now)
{
   if(now == 0) now = TimeCurrent();
   if(!InpNewsEnabled || m_noticias_count == 0 || !m_news_loaded) return false;
   for(int i = 0; i < m_noticias_count; i++)
   {
      datetime t = m_noticias[i].tempo;
      if(t > now + InpNewsMinAfter * 60) break;
      if(m_noticias[i].is_high && now >= t - InpNewsMinBefore * 60 && now <= t + InpNewsMinAfter * 60)
         return true;
   }
   return false;
}

bool CNewsFilter::IsMediumNewsActiveNow(datetime now)
{
   if(now == 0) now = TimeCurrent();
   if(!InpNewsEnabled || m_noticias_count == 0 || !m_news_loaded) return false;
   for(int i = 0; i < m_noticias_count; i++)
   {
      datetime t = m_noticias[i].tempo;
      if(t > now + InpNewsMinAfter * 60) break;
      if(m_noticias[i].is_medium && now >= t - InpNewsMinBefore * 60 && now <= t + InpNewsMinAfter * 60)
         return true;
   }
   return false;
}

int CNewsFilter::MinutesToNextHighNews(datetime now)
{
   if(now == 0) now = TimeCurrent();
   if(!InpNewsEnabled || m_noticias_count == 0 || !m_news_loaded) return -1;
   int best = -1;
   for(int i = 0; i < m_noticias_count; i++)
   {
      datetime t = m_noticias[i].tempo;
      if(t < now) continue;
      if(m_noticias[i].is_high)
      {
         int mins = (int)((t - now) / 60);
         if(best < 0 || mins < best) best = mins;
      }
   }
   return best;
}

string CNewsFilter::GetActiveNewsEvent(datetime now)
{
   if(now == 0) now = TimeCurrent();
   if(!InpNewsEnabled || m_noticias_count == 0 || !m_news_loaded) return "";
   for(int i = 0; i < m_noticias_count; i++)
   {
      datetime t = m_noticias[i].tempo;
      if(t > now + InpNewsMinAfter * 60) break;
      if(m_noticias[i].is_high && now >= t - InpNewsMinBefore * 60 && now <= t + InpNewsMinAfter * 60)
         return m_noticias[i].evento + " (" + m_noticias[i].pais + ")";
      if(m_noticias[i].is_medium && now >= t - InpNewsMinBefore * 60 && now <= t + InpNewsMinAfter * 60)
         return m_noticias[i].evento + " (" + m_noticias[i].pais + ")";
   }
   return "";
}

double CNewsFilter::GetNewsImpactScore(datetime now)
{
   if(now == 0) now = TimeCurrent();
   if(!InpNewsEnabled || m_noticias_count == 0 || !m_news_loaded) return -1.0;
   double score = 0.0;
   for(int i = 0; i < m_noticias_count; i++)
   {
      datetime t = m_noticias[i].tempo;
      if(t > now + InpNewsMinAfter * 60) break;
      if(t + InpNewsMinAfter * 60 < now - InpNewsMinBefore * 60) continue;
      double w = 0.0;
      if(m_noticias[i].is_high) w = 1.0;
      else if(m_noticias[i].is_medium) w = 0.5;
      else if(m_noticias[i].is_speech) w = 0.3;
      else if(m_noticias[i].is_low) w = 0.1;
      if(w > 0) score += w;
   }
   return score;
}
//+------------------------------------------------------------------+
