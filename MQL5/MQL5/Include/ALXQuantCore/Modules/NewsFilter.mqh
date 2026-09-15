//+------------------------------------------------------------------+
//|                                                   NewsFilter.mqh |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//| v10.0 - Separated News Filter (inputs from Core)                 |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore Ltd."
#property version "10.0"
/*
    v.10.0 - 2026-08-31 - Change: Input declarations removed — use globals from Core/Timefilter.mqh
                           (InpNewsEnabled, InpNewsMinBefore, InpNewsMinAfter, InpNewsHighImpact,
                            InpNewsCurrencies, InpNewsBrokerGMT, InpNewsUseFFLive,
                            InpNewsFFRefreshMinutes, InpNewsSpeakers, InpNewsHolidays,
                            InpNewsMaxDrawObjects, InpNewsDrawDaysAhead).
    v.8.12 - 2026-08-18 - Fix: INVALID_HANDLE_VALUE nao declarado (kernel32).
                         - Fix: ArraySort(m_noticias) invalido em struct com
                           objetos -> substituido por SortNoticias() manual.
*/

#ifndef NEWS_CSV_FILE
#define NEWS_CSV_FILE "Calendar.csv"
#endif
#ifndef FF_CALENDAR_THISWEEK_URL
#define FF_CALENDAR_THISWEEK_URL "https://nfs.faireconomy.media/ff_calendar_thisweek.json"
#endif
#ifndef ALX_MQL5_DATA_DIR
#define ALX_MQL5_DATA_DIR          "C:\\ALXQuant\\data\\mql5\\"
#endif
#ifndef FF_CACHE_FILE
#define FF_CACHE_FILE              "ff_cache.json"
#endif

//--- Kernel32 definitions
#ifndef HANDLE
#define HANDLE                     long
#endif
#ifndef PVOID
#define PVOID                      long
#endif
#ifndef INVALID_HANDLE_VALUE
#define INVALID_HANDLE_VALUE      -1
#endif

#import "kernel32.dll"
   HANDLE CreateFileW(const string file_name, uint desired_access, uint share_mode, PVOID security_attributes, uint creation_disposition, uint flags_and_attributes, HANDLE template_file);
   int    CloseHandle(HANDLE object);
   int    ReadFile(HANDLE file, uchar &buffer[], uint number_of_bytes_to_read, uint &number_of_bytes_read, PVOID overlapped);
   int    WriteFile(HANDLE file, uchar &buffer[], uint number_of_bytes_to_write, uint &number_of_bytes_written, PVOID overlapped);
   uint   GetFileSize(HANDLE file, long &file_size_high);
   bool   GetFileTime(HANDLE hFile, long &creation_time[], long &last_access_time[], long &last_write_time[]);
#import

//--- Inputs declados em Core/Timefilter.mqh (fonte unica).
//--- Esta classe apenas referencia as variaveis globais.

enum ENUM_NEWS_BLOCK_REASON
{
   NEWS_BLOCK_NONE = 0,
   NEWS_BLOCK_HIGH,
   NEWS_BLOCK_MEDIUM,
   NEWS_BLOCK_LOW,
   NEWS_BLOCK_SPEECH,
   NEWS_BLOCK_HOLIDAY
};

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

class CNewsFilter
{
private:
   string            m_symbol;
   string            m_prefix;
   NoticiaCSV        m_noticias[];
   int               m_noticias_count;
   bool              m_news_loaded;
   datetime          m_last_reload;
   
   struct NewsCache {
      bool is_valid; bool is_blocked;
      datetime check_from, check_to, file_mtime;
      ENUM_NEWS_BLOCK_REASON block_reason;
      string block_reason_text, block_event, block_currency;
      datetime block_time;
   } m_news_cache;

   struct NewsDrawInfo {
      string obj_prefix; datetime event_time;
      color orig_color; string label_text;
   } m_news_draw[];
   int m_news_draw_count;
   datetime m_news_drawn_day;
   double m_cached_bottom_price;
   datetime m_bottom_price_time;

   bool   m_enabled;
   string m_currencies;
   int    m_high_before, m_high_after, m_med_before, m_med_after, m_low_before, m_low_after;
   bool   m_speakers, m_holidays, m_high_impact;
   int    m_max_draw, m_draw_days;

   ENUM_NEWS_BLOCK_REASON m_block_reason;
   string m_block_reason_text, m_block_event, m_block_currency;
   datetime m_block_time;
   datetime m_csv_mtime;              
   string  m_csv_timezone;

   datetime m_ff_last_fetch, m_ff_next_retry;
   int m_ff_fail_count;

   void ResetBlockState() { m_block_reason = NEWS_BLOCK_NONE; m_block_reason_text = ""; m_block_event = ""; m_block_currency = ""; m_block_time = 0; }
   double GetGMTtoServerOffset() { return MQLInfoInteger(MQL_TESTER) ? 0.0 : (double)(TimeCurrent() - TimeGMT()) / 3600.0; }
   string GetAutoCurrencies();
   datetime ParseFFDateTime(string iso);
   string JSONExtractField(const string &obj, const string &key);
   int JSONSplitObjects(const string &json, string &objs[]);
   bool DownloadFFThisWeek();
   bool ParseFFJSON(string json);
   bool SaveFFCache(const string &json);
   bool LoadFFCache(string &json);
   bool ReadCSVContentLive(string &content);
   int BuscaBinaria(datetime target);
   void SortNoticias(int count);
   bool VerificarBloqueio(int idx, datetime now);
   bool UsarCache(datetime now, datetime &check_from, datetime &check_to);
   bool ParseCSVLine(const string line, string &dateStr, string &horaStr, string &evento, string &impacto, string &pais);
   void ProcessCSVLine(const string line, string win_from, string win_to, double gmt_offset, int &capacity, int &count, int &skipped, bool &is_header);
   bool CarregarNoticiasCSV();
   void CreateVLineWithLabel(string name, datetime time, color clr, string line_desc, string label_text, int width = 1, ENUM_LINE_STYLE style = STYLE_DASH, bool apply_gray_past = false);
   double GetChartBottomPrice();
   void CleanupNewsObjects();

public:
   CNewsFilter(void);
   ~CNewsFilter(void) { Deinit(); }

   bool Init(ulong magic);
   bool IsNewsBlocked();
   void DrawNewsLines();
   void UpdateVisuals();
   void Deinit();
   bool ReloadNews();
   bool IsNewsEnabled() { return m_enabled; }  
   ENUM_NEWS_BLOCK_REASON GetBlockReason() { return m_block_reason; }
    string GetBlockReasonText() { return m_block_reason_text; }

    // Estado atual de noticias (para o DataMiner gravar dados reais, nao simulados)
    bool NewsLoaded() { return m_news_loaded; }
    bool IsHighNewsActiveNow(datetime now = 0);
    bool IsMediumNewsActiveNow(datetime now = 0);
    int  MinutesToNextHighNews(datetime now = 0);
    string GetActiveNewsEvent(datetime now = 0);
    double GetNewsImpactScore(datetime now = 0);
};

//+------------------------------------------------------------------+
//| Estado atual de noticias para o DataMiner (dados reais)          |
//+------------------------------------------------------------------+
bool CNewsFilter::IsHighNewsActiveNow(datetime now)
{
   if(now == 0) now = TimeCurrent();
   if(!m_enabled || m_noticias_count == 0 || !m_news_loaded) return false;
   for(int i = 0; i < m_noticias_count; i++)
   {
      datetime t = m_noticias[i].tempo;
      if(t > now + m_high_after * 60) break;
      if(m_noticias[i].is_high && now >= t - m_high_before * 60 && now <= t + m_high_after * 60)
         return true;
   }
   return false;
}

bool CNewsFilter::IsMediumNewsActiveNow(datetime now)
{
   if(now == 0) now = TimeCurrent();
   if(!m_enabled || m_noticias_count == 0 || !m_news_loaded) return false;
   for(int i = 0; i < m_noticias_count; i++)
   {
      datetime t = m_noticias[i].tempo;
      if(t > now + m_med_after * 60) break;
      if(m_noticias[i].is_medium && now >= t - m_med_before * 60 && now <= t + m_med_after * 60)
         return true;
   }
   return false;
}

int CNewsFilter::MinutesToNextHighNews(datetime now)
{
   if(now == 0) now = TimeCurrent();
   if(!m_enabled || m_noticias_count == 0 || !m_news_loaded) return -1;
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
   if(!m_enabled || m_noticias_count == 0 || !m_news_loaded) return "";
   for(int i = 0; i < m_noticias_count; i++)
   {
      datetime t = m_noticias[i].tempo;
      if(t > now + m_high_after * 60) break;
      if(m_noticias[i].is_high && now >= t - m_high_before * 60 && now <= t + m_high_after * 60)
         return m_noticias[i].evento + " (" + m_noticias[i].pais + ")";
      if(m_noticias[i].is_medium && now >= t - m_med_before * 60 && now <= t + m_med_after * 60)
         return m_noticias[i].evento + " (" + m_noticias[i].pais + ")";
   }
   return "";
}

double CNewsFilter::GetNewsImpactScore(datetime now)
{
   if(now == 0) now = TimeCurrent();
   if(!m_enabled || m_noticias_count == 0 || !m_news_loaded) return -1.0;
   double score = 0.0;
   for(int i = 0; i < m_noticias_count; i++)
   {
      datetime t = m_noticias[i].tempo;
      if(t > now + m_high_after * 60) break;
      if(t + m_high_after * 60 < now - m_high_before * 60) continue;
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
CNewsFilter::CNewsFilter(void) : m_symbol(_Symbol), m_noticias_count(0), m_news_loaded(false), 
   m_last_reload(0), m_news_draw_count(0), m_news_drawn_day(0), m_cached_bottom_price(0), 
   m_bottom_price_time(0), m_ff_last_fetch(0), m_ff_next_retry(0), m_ff_fail_count(0)
{
   ZeroMemory(m_news_cache);
   m_news_cache.is_valid = false;
   ResetBlockState();
}

//+------------------------------------------------------------------+
bool CNewsFilter::Init(ulong magic) {
   m_symbol = _Symbol;
   m_prefix = "NF_" + IntegerToString(magic) + "_"; 
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_VLINE);
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_TEXT);

   m_enabled = InpNewsEnabled;
   m_speakers = InpNewsSpeakers;
   m_holidays = InpNewsHolidays;
   m_high_impact = InpNewsHighImpact;
   m_max_draw = InpNewsMaxDrawObjects;
   m_draw_days = MathMax(1, InpNewsDrawDaysAhead);

   //--- Core usa InpNewsMinBefore/After (flat para todos os impacts)
   m_high_before = InpNewsMinBefore; m_high_after = InpNewsMinAfter;
   m_med_before = InpNewsMinBefore;  m_med_after = InpNewsMinAfter;
   m_low_before = InpNewsMinBefore;  m_low_after = InpNewsMinAfter;

   string curr_str = InpNewsCurrencies; StringToUpper(curr_str); StringReplace(curr_str, " ", "");
   if(curr_str == "AUTO") curr_str = GetAutoCurrencies();
   m_currencies = "," + curr_str + ",";

   return ReloadNews();
}

// Implementações [Private]
string CNewsFilter::GetAutoCurrencies() 
{
   string sym = _Symbol;
   if(StringLen(sym) >= 6) return StringSubstr(sym, 0, 3) + "," + StringSubstr(sym, 3, 3);
   return "USD,EUR,GBP,JPY,CAD,CHF,AUD,NZD";
}

datetime CNewsFilter::ParseFFDateTime(string iso)
{
   StringTrimLeft(iso); StringTrimRight(iso);
   if(StringLen(iso) < 19) return 0;
   MqlDateTime mdt; ZeroMemory(mdt);
   mdt.year = (int)StringToInteger(StringSubstr(iso, 0, 4));
   mdt.mon  = (int)StringToInteger(StringSubstr(iso, 5, 2));
   mdt.day  = (int)StringToInteger(StringSubstr(iso, 8, 2));
   mdt.hour = (int)StringToInteger(StringSubstr(iso, 11, 2));
   mdt.min  = (int)StringToInteger(StringSubstr(iso, 14, 2));
   mdt.sec  = (int)StringToInteger(StringSubstr(iso, 17, 2));
   datetime wall_et_as_utc = StructToTime(mdt);
   if(StringLen(iso) < 25) return wall_et_as_utc;
   int sign = 1;
   if(StringGetCharacter(iso, 19) == '-') sign = -1;
   else if(StringGetCharacter(iso, 19) != '+') return wall_et_as_utc;
   int tzH = (int)StringToInteger(StringSubstr(iso, 20, 2));
   int tzM = (int)StringToInteger(StringSubstr(iso, 23, 2));
   int tzSec = sign * (tzH * 3600 + tzM * 60);
   return (datetime)(wall_et_as_utc - tzSec);
}

bool CNewsFilter::DownloadFFThisWeek() {
   if(!m_enabled) return false;
   datetime now = TimeCurrent();
   if(m_ff_last_fetch > 0 && now < m_ff_next_retry) return false;

   string url = FF_CALENDAR_THISWEEK_URL;
   string headers = "User-Agent: ALXQuantCore/8.0\r\n";
   char postData[]; char result[]; string resultHeaders;
   ResetLastError();
   int httpCode = WebRequest("GET", url, headers, 10000, postData, result, resultHeaders);

   if(httpCode != 200) {
      m_ff_fail_count++;
      int delay = 60 * m_ff_fail_count;
      if(m_ff_fail_count > 3) delay = 3600;
      m_ff_next_retry = now + delay;
      Print("[NewsFilter] FF HTTP=", httpCode, " erro=", GetLastError(), ". Retry em ", delay, "s.");
      string json;
      if(LoadFFCache(json)) { return ParseFFJSON(json); }
      return false;
   }

   m_ff_last_fetch = now;
   m_ff_next_retry = now + InpNewsFFRefreshMinutes * 60;
   m_ff_fail_count = 0;
   string json = CharArrayToString(result, 0, ArraySize(result), CP_UTF8);
   if(StringLen(json) < 2) return false;
   SaveFFCache(json);
   return ParseFFJSON(json);
}

bool CNewsFilter::SaveFFCache(const string &json) {
   string path = ALX_MQL5_DATA_DIR + FF_CACHE_FILE;
   HANDLE hFile = CreateFileW(path, 0x40000000, 0, NULL, 2, 0x80, NULL);
   if(hFile == INVALID_HANDLE_VALUE) return false;
   uchar buffer[]; int len = StringLen(json);
   ArrayResize(buffer, len);
   StringToCharArray(json, buffer, 0, len, CP_UTF8);
   uint bytesWritten = 0;
   WriteFile(hFile, buffer, len, bytesWritten, NULL);
   CloseHandle(hFile);
   return true;
}

bool CNewsFilter::LoadFFCache(string &json) {
   string path = ALX_MQL5_DATA_DIR + FF_CACHE_FILE;
   HANDLE hFile = CreateFileW(path, 0x80000000, 1 | 2, NULL, 3, 0x80, NULL);
   if(hFile == INVALID_HANDLE_VALUE) return false;
   long sizeHi = 0;
   uint fileSize = GetFileSize(hFile, sizeHi);
   if(fileSize == 0) { CloseHandle(hFile); return false; }
   uchar buffer[]; ArrayResize(buffer, fileSize);
   uint bytesRead = 0;
   ReadFile(hFile, buffer, fileSize, bytesRead, NULL);
   CloseHandle(hFile);
   json = CharArrayToString(buffer, 0, (int)bytesRead, CP_UTF8);
   return (StringLen(json) > 0);
}

string CNewsFilter::JSONExtractField(const string &obj, const string &key) {
   string search = "\"" + key + "\"";
   int pos = StringFind(obj, search);
   if(pos < 0) return "";
   int colon = StringFind(obj, ":", pos);
   if(colon < 0) return "";
   int start = colon + 1;
   int len = StringLen(obj);
   while(start < len && (StringGetCharacter(obj, start) == ' ' || StringGetCharacter(obj, start) == '\t')) start++;
   if(start < len && StringGetCharacter(obj, start) == '"') {
      start++; int end = start;
      while(end < len) {
         ushort ch = StringGetCharacter(obj, end);
         if(ch == '\\' && end + 1 < len) { end += 2; continue; }
         if(ch == '"') break;
         end++;
      }
      return StringSubstr(obj, start, end - start);
   }
   int end = start;
   while(end < len) {
      ushort ch = StringGetCharacter(obj, end);
      if(ch == ',' || ch == '}' || ch == ']') break;
      end++;
   }
   return StringSubstr(obj, start, end - start);
}

int CNewsFilter::JSONSplitObjects(const string &json, string &objs[]) {
   ArrayResize(objs, 0);
   int len = StringLen(json); int i = 0;
   while(i < len && StringGetCharacter(json, i) != '[') i++;
   if(i >= len) return 0;
   i++;
   int count = 0;
   while(i < len) {
      while(i < len && (StringGetCharacter(json, i) == ' ' || StringGetCharacter(json, i) == '\t' || 
                        StringGetCharacter(json, i) == '\n' || StringGetCharacter(json, i) == '\r' || 
                        StringGetCharacter(json, i) == ',')) i++;
      if(i >= len) break;
      if(StringGetCharacter(json, i) != '{') {
         bool inStr = false;
         while(i < len) {
            if(StringGetCharacter(json, i) == '"') inStr = !inStr;
            else if(!inStr && (StringGetCharacter(json, i) == ',' || StringGetCharacter(json, i) == ']')) break;
            i++;
         }
         continue;
      }
      int start = i; int depth = 0; bool inStr = false;
      while(i < len) {
         ushort ch = StringGetCharacter(json, i);
         if(ch == '"' && (i == 0 || StringGetCharacter(json, i - 1) != '\\')) inStr = !inStr;
         else if(!inStr) {
            if(ch == '{') depth++;
            else if(ch == '}') { depth--; if(depth == 0) { i++; break; } }
         }
         i++;
      }
      if(depth != 0) return count;
      ArrayResize(objs, count + 1);
      objs[count] = StringSubstr(json, start, i - start);
      count++;
   }
   return count;
}

bool CNewsFilter::ParseFFJSON(string json) {
   string objs[];
   int total = JSONSplitObjects(json, objs);
   if(total <= 0) return false;
   double gmt_to_server_offset = GetGMTtoServerOffset();
   ArrayResize(m_noticias, total);
   int count = 0;
   for(int i = 0; i < total; i++) {
      string title = JSONExtractField(objs[i], "title");
      string country = JSONExtractField(objs[i], "country");
      string date = JSONExtractField(objs[i], "date");
      string impact = JSONExtractField(objs[i], "impact");
      if(StringLen(date) < 19) continue;
      datetime tempo_utc = ParseFFDateTime(date);
      if(tempo_utc == 0) continue;
      datetime tempo_server = (datetime)(tempo_utc + gmt_to_server_offset * 3600.0);
      string impUpper = impact; StringToUpper(impUpper);
      string evUpper = title; StringToUpper(evUpper);
      string paUpper = country; StringToUpper(paUpper);
      m_noticias[count].tempo = tempo_server; m_noticias[count].evento = title;
      m_noticias[count].impacto = impact; m_noticias[count].pais = paUpper;
      m_noticias[count].is_high = (StringFind(impUpper, "HIGH") >= 0);
      m_noticias[count].is_medium = (StringFind(impUpper, "MEDIUM") >= 0 || StringFind(impUpper, "MED") >= 0);
      m_noticias[count].is_low = (StringFind(impUpper, "LOW") >= 0);
      m_noticias[count].is_speech = (StringFind(evUpper, "SPEAK") >= 0) || (StringFind(evUpper, "SPEECH") >= 0) || (StringFind(evUpper, "TESTIF") >= 0);
      m_noticias[count].is_holiday = (StringFind(impUpper, "HOLIDAY") >= 0) || (StringFind(evUpper, "HOLIDAY") >= 0);
      count++;
   }
   ArrayResize(m_noticias, count);
   SortNoticias(count);
   m_noticias_count = count;
   m_news_loaded = (count > 0);
   return m_news_loaded;
}

//+------------------------------------------------------------------+
//| SortNoticias - ordena m_noticias por tempo (struct com string,   |
//| ArraySort nao aceita objetos). Insertion sort estavel: CSV chega |
//| quase ordenado (O(n) pratico) e FF e pequeno.                    |
//+------------------------------------------------------------------+
void CNewsFilter::SortNoticias(int count)
{
   for(int i = 1; i < count; i++)
   {
      NoticiaCSV key = m_noticias[i];
      int j = i - 1;
      while(j >= 0 && m_noticias[j].tempo > key.tempo)
      {
         m_noticias[j + 1] = m_noticias[j];
         j--;
      }
      m_noticias[j + 1] = key;
   }
}

bool CNewsFilter::UsarCache(datetime now, datetime &check_from, datetime &check_to) {
   if(!m_news_cache.is_valid) return false;
   int max_before = MathMax(m_high_before, MathMax(m_med_before, m_low_before));
   int max_after = MathMax(m_high_after, MathMax(m_med_after, m_low_after));
   check_from = now - max_after * 60;
   check_to = now + max_before * 60;
   if(m_news_cache.check_from != check_from || m_news_cache.check_to != check_to) {
      m_news_cache.is_valid = false; return false;
   }
   m_block_reason = m_news_cache.block_reason; m_block_reason_text = m_news_cache.block_reason_text;
   m_block_event = m_news_cache.block_event; m_block_currency = m_news_cache.block_currency;
   m_block_time = m_news_cache.block_time;
   return true;
}

bool CNewsFilter::ReadCSVContentLive(string &content) {
   content = "";
   string fullPath = ALX_MQL5_DATA_DIR + NEWS_CSV_FILE;
   HANDLE hFile = CreateFileW(fullPath, 0x80000000, 1 | 2, NULL, 3, 0x80, NULL);
   if(hFile == INVALID_HANDLE_VALUE) return false;
   long sizeHi = 0;
   uint fileSize = GetFileSize(hFile, sizeHi);
   if(fileSize == 0 || fileSize > 64 * 1024 * 1024) { CloseHandle(hFile); return false; }
   uchar buffer[];
   if(ArrayResize(buffer, fileSize) < 0) { CloseHandle(hFile); return false; }
   uint bytesRead = 0;
   ReadFile(hFile, buffer, fileSize, bytesRead, NULL);
   long creation[1], last_access[1], last_write[1];
   if(GetFileTime(hFile, creation, last_access, last_write)) {
      m_csv_mtime = (datetime)(last_write[0] / 10000000 - 11644473600);
   }
   CloseHandle(hFile);
   content = CharArrayToString(buffer, 0, (int)bytesRead, CP_UTF8);
   return (StringLen(content) > 0);
}

bool CNewsFilter::ReloadNews() {
   datetime now = TimeCurrent();
   if(m_last_reload > 0 && now - m_last_reload < InpNewsFFRefreshMinutes * 60) return m_news_loaded;
   m_last_reload = now;
   m_news_cache.is_valid = false;
   if(!MQLInfoInteger(MQL_TESTER) && InpNewsUseFFLive) {
      if(DownloadFFThisWeek()) return true;
   }
   return CarregarNoticiasCSV();
}

bool CNewsFilter::ParseCSVLine(const string line, string &dateStr, string &horaStr, string &evento, string &impacto, string &pais) {
   string fields[8]; int fieldCount = 0;
   int len = StringLen(line); bool inQuotes = false; int segStart = 0;
   for(int i = 0; i < len; i++) {
      ushort ch = StringGetCharacter(line, i);
      if(ch == '"') inQuotes = !inQuotes;
      else if(ch == ',' && !inQuotes) {
         if(fieldCount >= 8) return false;
         fields[fieldCount++] = StringSubstr(line, segStart, i - segStart);
         segStart = i + 1;
      }
   }
   if(fieldCount >= 8) return false;
   fields[fieldCount++] = StringSubstr(line, segStart, len - segStart);
   if(fieldCount < 5) return false;
   dateStr = fields[0]; StringTrimLeft(dateStr); StringTrimRight(dateStr);
   horaStr = fields[1]; StringTrimLeft(horaStr); StringTrimRight(horaStr);
   evento = fields[2]; StringTrimLeft(evento); StringTrimRight(evento);
   impacto = fields[3]; StringTrimLeft(impacto); StringTrimRight(impacto);
   pais = fields[4]; StringTrimLeft(pais); StringTrimRight(pais);
   return true;
}

void CNewsFilter::ProcessCSVLine(const string line, string win_from, string win_to, double gmt_offset, int &capacity, int &count, int &skipped, bool &is_header) {
   string trimmed = line; StringTrimRight(trimmed); StringTrimLeft(trimmed);
   if(StringLen(trimmed) == 0) return;
   if(StringGetCharacter(trimmed, 0) == '#') {
      if(is_header) {
         if(StringFind(trimmed, "SERVER") >= 0) m_csv_timezone = "SERVER";
         else m_csv_timezone = "UTC";
         is_header = false;
      }
      return;
   }
   is_header = false;
   if(StringLen(trimmed) >= 10 && StringLen(win_from) > 0) {
      string datePart = StringSubstr(trimmed, 0, 10);
      ushort d0 = StringGetCharacter(datePart,0);
      if(d0 < '0' || d0 > '9') { skipped++; return; }
      if(StringCompare(datePart, win_from, false) < 0 || StringCompare(datePart, win_to, false) > 0) { skipped++; return; }
   }
   string dataStr, horaStr, evento, impacto, pais;
   if(!ParseCSVLine(trimmed, dataStr, horaStr, evento, impacto, pais)) { skipped++; return; }
   if(StringLen(dataStr) < 10) { skipped++; return; }
   datetime tempo_csv = StringToTime(dataStr + " " + horaStr);
   if(tempo_csv == 0) { skipped++; return; }
   datetime tempo_server;
   if(m_csv_timezone == "UTC") tempo_server = (datetime)(tempo_csv + gmt_offset * 3600.0);
   else tempo_server = tempo_csv;
   if(count >= capacity) { capacity += 10000; ArrayResize(m_noticias, capacity); }
   string impUpper = impacto; StringToUpper(impUpper);
   string evUpper = evento; StringToUpper(evUpper);
   string paUpper = pais; StringToUpper(paUpper);
   m_noticias[count].tempo = tempo_server; m_noticias[count].evento = evento;
   m_noticias[count].impacto = impacto; m_noticias[count].pais = paUpper;
   m_noticias[count].is_high = (StringFind(impUpper, "HIGH") >= 0);
   m_noticias[count].is_medium = (StringFind(impUpper, "MEDIUM") >= 0 || StringFind(impUpper, "MED") >= 0);
   m_noticias[count].is_low = (StringFind(impUpper, "LOW") >= 0);
   m_noticias[count].is_speech = (StringFind(evUpper, "SPEAK") >= 0) || (StringFind(evUpper, "SPEECH") >= 0) || (StringFind(evUpper, "TESTIF") >= 0);
   m_noticias[count].is_holiday = (StringFind(impUpper, "HOLIDAY") >= 0) || (StringFind(evUpper, "HOLIDAY") >= 0);
   count++;
}

bool CNewsFilter::CarregarNoticiasCSV() {
   if(!m_enabled) { m_news_loaded = false; return true; }
   m_csv_timezone = "UTC";
   double gmt_to_server_offset = GetGMTtoServerOffset();
   if(MQLInfoInteger(MQL_TESTER) && InpNewsBrokerGMT != 0) gmt_to_server_offset = InpNewsBrokerGMT;
   datetime now_clip = TimeCurrent();
   string win_from_str = ""; string win_to_str = "";
   if(now_clip > D'2019.01.01') {
      win_from_str = TimeToString(now_clip - 15 * 86400, TIME_DATE);
      win_to_str = TimeToString(now_clip + 700 * 86400, TIME_DATE);
   }
   int capacity = 10000; ArrayResize(m_noticias, capacity);
   int count = 0; int skipped = 0; bool is_header = true;
   if(MQLInfoInteger(MQL_TESTER)) {
      int handle = FileOpen(NEWS_CSV_FILE, FILE_READ | FILE_TXT | FILE_COMMON, 0, CP_UTF8);
      if(handle == INVALID_HANDLE) { m_news_loaded = false; return false; }
      while(!FileIsEnding(handle)) {
         string line = FileReadString(handle);
         ProcessCSVLine(line, win_from_str, win_to_str, gmt_to_server_offset, capacity, count, skipped, is_header);
      }
      m_csv_mtime = (datetime)FileGetInteger(handle, FILE_MODIFY_DATE);
      FileClose(handle);
   } else {
      string content;
      if(!ReadCSVContentLive(content)) { m_news_loaded = false; return false; }
      string lines[]; int total = StringSplit(content, '\n', lines);
      for(int i = 0; i < total; i++) {
         ProcessCSVLine(lines[i], win_from_str, win_to_str, gmt_to_server_offset, capacity, count, skipped, is_header);
      }
   }
   ArrayResize(m_noticias, count);
   SortNoticias(count);
   m_noticias_count = count;
   m_news_loaded = (count > 0);
   return true;
}

int CNewsFilter::BuscaBinaria(datetime target) {
   if(m_noticias_count == 0) return 0;
   int left = 0; int right = m_noticias_count - 1; int result = m_noticias_count;
   while(left <= right) {
      int mid = left + (right - left) / 2;
      if(m_noticias[mid].tempo >= target) { result = mid; right = mid - 1; }
      else left = mid + 1;
   }
   return result;
}

bool CNewsFilter::VerificarBloqueio(int idx, datetime now) {
   int before_min = 0; int after_min = 0;
   ENUM_NEWS_BLOCK_REASON reason = NEWS_BLOCK_NONE;
   string reason_text = "";
   if(m_noticias[idx].is_holiday && m_holidays) {
      before_min = m_high_before; after_min = m_high_after;
      reason = NEWS_BLOCK_HOLIDAY; reason_text = "BLOCKED - HOLIDAY";
   } else if(m_noticias[idx].is_speech && m_speakers) {
      before_min = m_high_before; after_min = m_high_after;
      reason = NEWS_BLOCK_SPEECH; reason_text = "BLOCKED - SPEECH";
   } else if(m_noticias[idx].is_high && m_high_impact) {
      before_min = MathMax(15, m_high_before);
      after_min = MathMax(30, m_high_after);
      reason = NEWS_BLOCK_HIGH; reason_text = "BLOCKED - HIGH IMPACT";
   } else if(m_noticias[idx].is_medium) {
      before_min = m_med_before; after_min = m_med_after;
      reason = NEWS_BLOCK_MEDIUM; reason_text = "BLOCKED - MEDIUM IMPACT";
   } else if(m_noticias[idx].is_low) {
      before_min = m_low_before; after_min = m_low_after;
      reason = NEWS_BLOCK_LOW; reason_text = "BLOCKED - LOW IMPACT";
   }
   if(reason == NEWS_BLOCK_NONE) return false;
   datetime event_time = m_noticias[idx].tempo;
   datetime block_start = event_time - before_min * 60;
   datetime block_end = event_time + after_min * 60;
   if(now < block_start || now > block_end) return false;
   string event_currency = m_noticias[idx].pais;
   if(m_currencies != ",ALL,") {
      if(StringFind(m_currencies, "," + event_currency + ",") < 0) return false;
   }
   m_block_reason = reason; m_block_reason_text = reason_text + " (" + event_currency + ")";
   m_block_event = m_noticias[idx].evento; m_block_currency = event_currency; m_block_time = event_time;
   return true;
}

double CNewsFilter::GetChartBottomPrice() {
   datetime now = TimeCurrent();
   if(m_cached_bottom_price > 0 && now - m_bottom_price_time < 60) return m_cached_bottom_price;
   int chart_height = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   int chart_width = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int bottom_pixel_y = chart_height - 25; int center_pixel_x = chart_width / 2;
   int sub_window = 0; datetime temp_time = 0; double temp_price = 0;
   if(ChartXYToTimePrice(0, center_pixel_x, bottom_pixel_y, sub_window, temp_time, temp_price) && temp_price > 0) {
      m_cached_bottom_price = temp_price; m_bottom_price_time = now; return m_cached_bottom_price;
   }
   double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
   double min_price = bid;
   int bars = MathMin(200, iBars(m_symbol, PERIOD_CURRENT));
   int lowest = iLowest(m_symbol, PERIOD_CURRENT, MODE_LOW, bars, 0);
   if(lowest >= 0) min_price = iLow(m_symbol, PERIOD_CURRENT, lowest);
   double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
   double offset = MathMax(bid * 0.002, 20 * point);
   int digits = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
   m_cached_bottom_price = NormalizeDouble(min_price - offset, digits);
   m_bottom_price_time = now;
   return m_cached_bottom_price;
}

void CNewsFilter::CreateVLineWithLabel(string name, datetime time, color clr, string line_desc, string label_text, int width, ENUM_LINE_STYLE style, bool apply_gray_past) {
   bool is_past = apply_gray_past && (time <= TimeCurrent());
   color draw_color = is_past ? clrGray : clr;
   string line_name = m_prefix + name; string text_name = m_prefix + name + "_lbl";
   if(ObjectFind(0, line_name) < 0) ObjectCreate(0, line_name, OBJ_VLINE, 0, time, 0);
   ObjectSetInteger(0, line_name, OBJPROP_TIME, time); ObjectSetInteger(0, line_name, OBJPROP_COLOR, draw_color);
   ObjectSetInteger(0, line_name, OBJPROP_STYLE, style); ObjectSetInteger(0, line_name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, line_name, OBJPROP_BACK, true); ObjectSetInteger(0, line_name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, line_name, OBJPROP_HIDDEN, true); ObjectSetString(0, line_name, OBJPROP_TOOLTIP, line_desc);
   double price = GetChartBottomPrice();
   if(ObjectFind(0, text_name) < 0) ObjectCreate(0, text_name, OBJ_TEXT, 0, time, price);
   ObjectSetInteger(0, text_name, OBJPROP_TIME, time); ObjectSetDouble(0, text_name, OBJPROP_PRICE, price);
   ObjectSetString(0, text_name, OBJPROP_TEXT, label_text); ObjectSetInteger(0, text_name, OBJPROP_COLOR, draw_color);
   ObjectSetInteger(0, text_name, OBJPROP_FONTSIZE, 7); ObjectSetString(0, text_name, OBJPROP_FONT, "Arial");
   ObjectSetDouble(0, text_name, OBJPROP_ANGLE, 90); ObjectSetInteger(0, text_name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, text_name, OBJPROP_BACK, false); ObjectSetInteger(0, text_name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, text_name, OBJPROP_HIDDEN, true);
}

void CNewsFilter::CleanupNewsObjects() {
   for(int i = 0; i < m_news_draw_count; i++) {
      string line_name = m_prefix + m_news_draw[i].obj_prefix;
      ObjectDelete(0, line_name); ObjectDelete(0, line_name + "_lbl");
   }
   m_news_draw_count = 0; ArrayResize(m_news_draw, 0);
}

void CNewsFilter::DrawNewsLines() {
   if(MQLInfoInteger(MQL_TESTER)) return;
   if(!m_enabled || m_noticias_count == 0) return;
   datetime now = TimeCurrent(); MqlDateTime dt; TimeToStruct(now, dt);
   datetime today = now - dt.hour * 3600 - dt.min * 60 - dt.sec;
   if(today == m_news_drawn_day && m_news_draw_count > 0) return;
   CleanupNewsObjects(); m_news_drawn_day = today;
   datetime check_from = today; datetime check_to = today + (datetime)m_draw_days * 86400;
   int start_idx = BuscaBinaria(check_from);
   ArrayResize(m_news_draw, 50);
   for(int i = start_idx; i < m_noticias_count; i++) {
      if(m_noticias[i].tempo > check_to) break;
      if(m_max_draw > 0 && m_news_draw_count >= m_max_draw) break;
      string event_currency = m_noticias[i].pais;
      if(m_currencies != ",ALL,") {
         if(StringFind(m_currencies, "," + event_currency + ",") < 0) continue;
      }
      bool should_draw = false; color line_color = clrGray; string type_tag = ""; ENUM_LINE_STYLE line_style = STYLE_DASH;
      if(m_noticias[i].is_holiday && m_holidays) { should_draw = true; line_color = clrMagenta; type_tag = "HDY"; line_style = STYLE_DOT; }
      else if(m_noticias[i].is_speech && m_speakers) { should_draw = true; line_color = clrOrange; type_tag = "SPC"; line_style = STYLE_DASH; }
      else if(m_noticias[i].is_high && m_high_impact) { should_draw = true; line_color = clrRed; type_tag = "HI"; line_style = STYLE_SOLID; }
      else if(m_noticias[i].is_medium) { should_draw = true; line_color = clrYellow; type_tag = "MD"; line_style = STYLE_DASH; }
      if(!should_draw) continue;
      if(m_news_draw_count >= ArraySize(m_news_draw)) {
         int new_size = ArraySize(m_news_draw) + 25;
         if(m_max_draw > 0) new_size = MathMin(new_size, m_max_draw);
         if(ArrayResize(m_news_draw, new_size) < 0) break;
      }
      string obj_name = "NEWS_" + IntegerToString(m_news_draw_count);
      string label = type_tag + " " + event_currency + " " + m_noticias[i].evento;
      if(StringLen(label) > 45) label = StringSubstr(label, 0, 42) + "...";
      CreateVLineWithLabel(obj_name, m_noticias[i].tempo, line_color, type_tag + ": " + event_currency + " " + m_noticias[i].evento, label, 1, line_style, true);
      m_news_draw[m_news_draw_count].obj_prefix = obj_name;
      m_news_draw[m_news_draw_count].event_time = m_noticias[i].tempo;
      m_news_draw[m_news_draw_count].orig_color = line_color;
      m_news_draw[m_news_draw_count].label_text = label;
      m_news_draw_count++;
   }
   ArrayResize(m_news_draw, m_news_draw_count);
   if(m_news_draw_count > 0) ChartRedraw();
}

void CNewsFilter::UpdateVisuals() {
   if(MQLInfoInteger(MQL_TESTER)) return;
   static datetime last_update = 0; datetime now = TimeCurrent();
   if(now - last_update < 1) return; last_update = now;
   DrawNewsLines();
   if(!m_enabled || m_news_draw_count <= 0) return;
   bool need_redraw = false; double bottom_price = GetChartBottomPrice();
   for(int i = 0; i < m_news_draw_count; i++) {
      bool is_past = (m_news_draw[i].event_time <= now);
      color current_color = is_past ? clrGray : m_news_draw[i].orig_color;
      string line_name = m_prefix + m_news_draw[i].obj_prefix; string text_name = line_name + "_lbl";
      if(ObjectFind(0, line_name) >= 0) {
         if((color)ObjectGetInteger(0, line_name, OBJPROP_COLOR) != current_color) {
            ObjectSetInteger(0, line_name, OBJPROP_COLOR, current_color); need_redraw = true;
         }
      }
      if(ObjectFind(0, text_name) >= 0) {
         if((color)ObjectGetInteger(0, text_name, OBJPROP_COLOR) != current_color) {
            ObjectSetInteger(0, text_name, OBJPROP_COLOR, current_color); need_redraw = true;
         }
         if(MathAbs(ObjectGetDouble(0, text_name, OBJPROP_PRICE) - bottom_price) > SymbolInfoDouble(m_symbol, SYMBOL_POINT) * 10) {
            ObjectSetDouble(0, text_name, OBJPROP_PRICE, bottom_price); need_redraw = true;
         }
      }
   }
   if(need_redraw) ChartRedraw();
}

bool CNewsFilter::IsNewsBlocked() {
   if(!m_enabled || m_noticias_count == 0 || !m_news_loaded) return false;
   datetime now = TimeCurrent(); datetime check_from, check_to;
   if(UsarCache(now, check_from, check_to)) return m_news_cache.is_blocked;
   int start_idx = BuscaBinaria(check_from);
   if(start_idx >= m_noticias_count || m_noticias[start_idx].tempo > check_to) {
      m_news_cache.is_valid = true; m_news_cache.is_blocked = false;
      m_news_cache.check_from = check_from; m_news_cache.check_to = check_to;
      m_news_cache.file_mtime = m_csv_mtime; ResetBlockState(); return false;
   }
   for(int i = start_idx; i < m_noticias_count; i++) {
      if(m_noticias[i].tempo > check_to) break;
      if(VerificarBloqueio(i, now)) {
         m_news_cache.is_valid = true; m_news_cache.is_blocked = true;
         m_news_cache.check_from = check_from; m_news_cache.check_to = check_to;
         m_news_cache.file_mtime = m_csv_mtime;
         m_news_cache.block_reason = m_block_reason; m_news_cache.block_reason_text = m_block_reason_text;
         m_news_cache.block_event = m_block_event; m_news_cache.block_currency = m_block_currency;
         m_news_cache.block_time = m_block_time; return true;
      }
   }
   m_news_cache.is_valid = true; m_news_cache.is_blocked = false;
   m_news_cache.check_from = check_from; m_news_cache.check_to = check_to;
   m_news_cache.file_mtime = m_csv_mtime; ResetBlockState(); return false;
}

void CNewsFilter::Deinit() {
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_VLINE);
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_TEXT);
   ChartRedraw();
}