//+------------------------------------------------------------------+
//|                                              Core/Timefilter.mqh |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//|                       CTimeFilter — time + session (v11.0)        |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      ""
#property version   "11.0"
/*
    v.11.0 - 2026-09-06 - Refactor: CTimeFilter puro (time + session).
                           Inputs declarados dentro da classe.
                           Overnight session check corrigido.
                           InpWaitNZX..InpWaitNYSE respeitados.
    v.10.0 - 2026-08-24 - Renumber to major 10 platform alignment.
    v.7.20 - 2026-08-07 - Fix timezone + unificação Init/CSV.
*/

//+------------------------------------------------------------------+
//| Enum: motivo do bloqueio de tempo                                 |
//+------------------------------------------------------------------+
enum ENUM_TIME_BLOCK_REASON
{
   TIME_BLOCK_NONE        = 0,
   TIME_BLOCK_SESSION     = 1,   // Fora da sessão configurada
   TIME_BLOCK_MARKET_OPEN = 2,   // Abertura de mercado global
   TIME_BLOCK_FRIDAY      = 3,   // Sexta-feira bloqueada
   TIME_BLOCK_SESSION_END = 4    // X min antes do fim da sessão
};

//+------------------------------------------------------------------+
//| Struct: sessão global (mercado)                                   |
//+------------------------------------------------------------------+
struct GlobalSession
{
   bool   isActive;
   int    hour;
   int    min;
   string name;
   color  clr;
};

//+------------------------------------------------------------------+
//| CTimeFilter — filtro de tempo + sessão                            |
//|   Inputs declarados aqui (aparecem no EA automaticamente)         |
//+------------------------------------------------------------------+
class CTimeFilter
{
private:
   //--- State
   string            m_symbol;
   string            m_prefix;
   bool              m_is_waiting;
   GlobalSession     m_global_opens[7];
   ENUM_TIME_BLOCK_REASON m_block_reason;
   string            m_block_reason_text;
   //--- Time params (calculados no Init)
   int               m_time_start_min;
   int               m_time_end_min;
   bool              m_time_friday;
   int               m_time_wait_minutes;
   int               m_market_open_wait_minutes;
   //--- Drawing
   double            m_cached_bottom_price;
   datetime          m_bottom_price_time;

   //--- Helpers
   void              ResetBlockState();
   int               TimeToMinutes(string time_str);
   bool              CheckGlobalOpens(datetime time_now);
   datetime          SetTimeToDate(datetime base_date, int hour, int min);
   void              SetSession(int index, bool active, int hour, int min, string name, color clr);
   void              CreateVLineWithLabel(string name, datetime time, color clr,
                                         string line_desc, string label_text,
                                         int width = 1, ENUM_LINE_STYLE style = STYLE_DASH);
   double            GetChartBottomPrice();
   int               GetOffsetHours();

public:
                     CTimeFilter();
                    ~CTimeFilter() { Deinit(); }

   void              Init();
   bool              IsTimeTrade();
   void              DrawSessionLines();
   void              Deinit();
   bool              IsWaiting() { return m_is_waiting; }
   ENUM_TIME_BLOCK_REASON GetBlockReason() { return m_block_reason; }
   string            GetBlockReasonText() { return m_block_reason_text; }
};

//+------------------------------------------------------------------+
//| Inputs — declarados dentro da classe                              |
//+------------------------------------------------------------------+
input group             "▸ Time Filter"
input bool              InpTimeEnabled        = true;          // Time filter (On/Off)
input int               InpTimezone_offset    = 0;             // TimeZone Offset (hours vs GMT, 0=auto)
input string            InpTimeStart          = "02:00";       // Time start (HH:mm)
input string            InpTimeEnd            = "17:00";       // Time end (HH:mm)
input bool              InpTimeTradeFriday    = true;          // Trade friday?
input int               InpTimeWaitEnd        = 5;             // Block X min before session end
input int               InpTimeMarketOpenWait = 15;            // Block X min AFTER market open

//input group             "▸ Global Sessions"
      bool              InpWaitNZX           = true;          // Block at NZX open?
      bool              InpWaitASX           = true;          // Block at ASX open?
      bool              InpWaitJPX           = true;          // Block at JPX open?
      bool              InpWaitHKEX          = true;          // Block at HKEX open?
      bool              InpWaitSGX           = true;          // Block at SGX open?
      bool              InpWaitLSE           = true;          // Block at LSE open?
      bool              InpWaitNYSE          = true;          // Block at NYSE open?

//+------------------------------------------------------------------+
//| Construtor                                                         |
//+------------------------------------------------------------------+
CTimeFilter::CTimeFilter() : m_symbol(_Symbol), m_is_waiting(false),
   m_block_reason(TIME_BLOCK_NONE), m_block_reason_text(""),
   m_time_start_min(0), m_time_end_min(0), m_time_friday(true),
   m_time_wait_minutes(15), m_market_open_wait_minutes(15),
   m_cached_bottom_price(0), m_bottom_price_time(0)
{
   m_prefix = "TF_";
}

//+------------------------------------------------------------------+
//| GetOffsetHours — auto-detect UTC→server (live) / manual (tester)  |
//+------------------------------------------------------------------+
int CTimeFilter::GetOffsetHours()
{
   //--- Live/Demo: automático (TimeCurrent - TimeGMT)
   if(!MQLInfoInteger(MQL_TESTER))
   {
      datetime nowBroker = TimeCurrent();
      datetime nowGMT    = TimeGMT();
      return (int)MathRound((double)(nowBroker - nowGMT) / 3600.0);
   }
   //--- Tester: usa InpTimezone_offset (TimeGMT() pode ser igual a TimeCurrent)
   return InpTimezone_offset;
}

//+------------------------------------------------------------------+
//| Init — configura tudo (chamar no OnInit do EA)                    |
//+------------------------------------------------------------------+
void CTimeFilter::Init()
{
   m_symbol = _Symbol;
   m_prefix = "TF_" + IntegerToString(0) + "_";  // magic pode ser passado depois

   ObjectsDeleteAll(0, m_prefix, 0, OBJ_VLINE);
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_TEXT);

   //--- Offset: auto (live) ou input (tester)
   int server_offset = GetOffsetHours();
   int delta_hours   = server_offset - InpTimezone_offset;

   //--- Parse horários
   int start_raw = TimeToMinutes(InpTimeStart);
   int end_raw   = TimeToMinutes(InpTimeEnd);

   if(start_raw == -1 || end_raw == -1)
   {
      Print("[TimeFilter] ERRO: Formato de horário inválido (", InpTimeStart, "/", InpTimeEnd, ")");
   }
   else
   {
      m_time_start_min = start_raw + (delta_hours * 60);
      m_time_end_min   = end_raw + (delta_hours * 60);
      while(m_time_start_min >= 1440) m_time_start_min -= 1440;
      while(m_time_start_min < 0)     m_time_start_min += 1440;
      while(m_time_end_min >= 1440)   m_time_end_min -= 1440;
      while(m_time_end_min < 0)       m_time_end_min += 1440;
   }

   m_time_friday             = InpTimeTradeFriday;
   m_time_wait_minutes       = InpTimeWaitEnd;
   m_market_open_wait_minutes = InpTimeMarketOpenWait;

   //--- Sessões globais (respeita InpWait*)
   SetSession(0, InpWaitNZX,  21, 45, "NZX",  clrYellow);
   SetSession(1, InpWaitASX,  23, 05, "ASX",  clrYellow);
   SetSession(2, InpWaitJPX,  00, 00, "JPX",  clrYellow);
   SetSession(3, InpWaitHKEX, 08, 30, "HKEX", clrYellow);
   SetSession(4, InpWaitSGX,  08, 00, "SGX",  clrYellow);
   SetSession(5, InpWaitLSE,  08, 00, "LSE",  clrYellow);
   SetSession(6, InpWaitNYSE, 14, 30, "NYSE", clrYellow);

   Print("[TimeFilter] Init OK — offset=", server_offset, "h, start=",
         InpTimeStart, " end=", InpTimeEnd, " friday=", InpTimeTradeFriday);
}

//+------------------------------------------------------------------+
//| IsTimeTrade — verifica se pode operar agora                       |
//+------------------------------------------------------------------+
bool CTimeFilter::IsTimeTrade()
{
   if(!InpTimeEnabled)
      return true;

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   //--- Sexta-feira bloqueada
   if(!m_time_friday && dt.day_of_week == 5)
   {
      m_block_reason      = TIME_BLOCK_FRIDAY;
      m_block_reason_text = "BLOCKED - FRIDAY";
      return false;
   }

   int current_min = dt.hour * 60 + dt.min;

   //--- Sessão normal (start < end, ex: 02:00→17:00)
   if(m_time_start_min < m_time_end_min)
   {
      if(current_min < m_time_start_min || current_min >= m_time_end_min)
      {
         m_block_reason      = TIME_BLOCK_SESSION;
         m_block_reason_text = "BLOCKED - SESSION";
         return false;
      }
   }
   //--- Overnight session (start > end, ex: 22:00→06:00)
   else
   {
      if(current_min < m_time_start_min && current_min >= m_time_end_min)
      {
         m_block_reason      = TIME_BLOCK_SESSION;
         m_block_reason_text = "BLOCKED - SESSION";
         return false;
      }
   }

   //--- Bloqueio X min antes do fim da sessão
   if(m_time_wait_minutes > 0)
   {
      int end_wait_start;
      if(m_time_start_min < m_time_end_min)
         end_wait_start = m_time_end_min - m_time_wait_minutes;
      else
         end_wait_start = m_time_end_min - m_time_wait_minutes + 1440;

      bool in_wait = false;
      if(m_time_start_min < m_time_end_min)
         in_wait = (current_min >= end_wait_start && current_min < m_time_end_min);
      else
         in_wait = (current_min >= end_wait_start || current_min < m_time_end_min);

      if(in_wait)
      {
         m_block_reason      = TIME_BLOCK_SESSION_END;
         m_block_reason_text = "BLOCKED - SESSION END (" + IntegerToString(m_time_wait_minutes) + " min)";
         return false;
      }
   }

   //--- Abertura de mercado global
   if(CheckGlobalOpens(now))
   {
      m_block_reason      = TIME_BLOCK_MARKET_OPEN;
      m_block_reason_text = "BLOCKED - MARKET OPEN";
      return false;
   }

   //--- Tudo OK
   ResetBlockState();
   return true;
}

//+------------------------------------------------------------------+
//| CheckGlobalOpens — verifica se está no período de abertura        |
//+------------------------------------------------------------------+
bool CTimeFilter::CheckGlobalOpens(datetime time_now)
{
   if(m_market_open_wait_minutes <= 0) return false;

   for(int i = 0; i < 7; i++)
   {
      if(!m_global_opens[i].isActive) continue;

      datetime open_today = SetTimeToDate(time_now, m_global_opens[i].hour, m_global_opens[i].min);
      datetime rest_end   = open_today + m_market_open_wait_minutes * 60;

      if(time_now >= open_today && time_now < rest_end)
      {
         m_is_waiting = true;
         return true;
      }

      //--- Verifica também o mercado do dia anterior (meia-noite→abertura)
      datetime open_yesterday = open_today - 86400;
      datetime rest_end_y     = open_yesterday + m_market_open_wait_minutes * 60;
      if(time_now >= open_yesterday && time_now < rest_end_y)
      {
         m_is_waiting = true;
         return true;
      }
   }

   m_is_waiting = false;
   return false;
}

//+------------------------------------------------------------------+
//| DrawSessionLines — desenha verticais de sessão                    |
//+------------------------------------------------------------------+
void CTimeFilter::DrawSessionLines()
{
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   for(int i = 0; i < 7; i++)
   {
      if(!m_global_opens[i].isActive) continue;

      datetime open_time = SetTimeToDate(now, m_global_opens[i].hour, m_global_opens[i].min);
      string name = m_prefix + "SESSION_" + m_global_opens[i].name;
      string label = m_global_opens[i].name + " Open";

      CreateVLineWithLabel(name, open_time, m_global_opens[i].clr, label, label, 1, STYLE_DASH);
   }
}

//+------------------------------------------------------------------+
//| Deinit — limpa gráfico                                            |
//+------------------------------------------------------------------+
void CTimeFilter::Deinit()
{
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_VLINE);
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_TEXT);
}

//+------------------------------------------------------------------+
//| SetSession — configura uma sessão global                          |
//+------------------------------------------------------------------+
void CTimeFilter::SetSession(int index, bool active, int hour, int min, string name, color clr)
{
   if(index < 0 || index >= 7) return;
   m_global_opens[index].isActive = active;
   m_global_opens[index].hour     = hour;
   m_global_opens[index].min      = min;
   m_global_opens[index].name     = name;
   m_global_opens[index].clr      = clr;
}

//+------------------------------------------------------------------+
//| TimeToMinutes — converte "HH:MM" para minutos                     |
//+------------------------------------------------------------------+
int CTimeFilter::TimeToMinutes(string time_str)
{
   StringTrimLeft(time_str);
   StringTrimRight(time_str);
   string parts[];
   if(StringSplit(time_str, ':', parts) != 2) return -1;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59) return -1;
   return h * 60 + m;
}

//+------------------------------------------------------------------+
//| SetTimeToDate — combina data de base + hora/min                   |
//+------------------------------------------------------------------+
datetime CTimeFilter::SetTimeToDate(datetime base_date, int hour, int min)
{
   MqlDateTime dt;
   TimeToStruct(base_date, dt);
   dt.hour = hour;
   dt.min  = min;
   dt.sec  = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| ResetBlockState — limpa motivo de bloqueio                        |
//+------------------------------------------------------------------+
void CTimeFilter::ResetBlockState()
{
   m_block_reason      = TIME_BLOCK_NONE;
   m_block_reason_text = "";
}

//+------------------------------------------------------------------+
//| CreateVLineWithLabel — cria linha vertical + label no gráfico      |
//+------------------------------------------------------------------+
void CTimeFilter::CreateVLineWithLabel(string name, datetime time, color clr,
                                       string line_desc, string label_text,
                                       int width, ENUM_LINE_STYLE style)
{
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);

   ObjectCreate(0, name, OBJ_VLINE, 0, time, 0);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

   string lbl = name + "_TXT";
   if(ObjectFind(0, lbl) >= 0) ObjectDelete(0, lbl);

   double price = GetChartBottomPrice();
   ObjectCreate(0, lbl, OBJ_TEXT, 0, time, price);
   ObjectSetString(0, lbl, OBJPROP_TEXT, label_text);
   ObjectSetInteger(0, lbl, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, lbl, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| GetChartBottomPrice — preço adaptativo para posicionar labels      |
//+------------------------------------------------------------------+
double CTimeFilter::GetChartBottomPrice()
{
   datetime now = TimeCurrent();
   if(now - m_bottom_price_time < 60 && m_cached_bottom_price > 0)
      return m_cached_bottom_price;

   double min_price = 0;
   int    bars     = iBars(_Symbol, PERIOD_H1);
   int    count    = MathMin(bars, 48);

   if(count > 0)
   {
      double temp[];
      if(CopyLow(_Symbol, PERIOD_H1, 0, count, temp) > 0)
      {
         min_price = temp[0];
         for(int i = 1; i < count; i++)
            if(temp[i] < min_price) min_price = temp[i];
      }
   }

   if(min_price == 0) min_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   m_cached_bottom_price = min_price;
   m_bottom_price_time   = now;
   return min_price;
}
//+------------------------------------------------------------------+
