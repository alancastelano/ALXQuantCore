//+------------------------------------------------------------------+
//|                                                   TimeFilter.mqh |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//| v10.0 - Separated Time Filter (input declarations in Core)       |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore Ltd."
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.10.0 - 2026-08-31 - Change: Input declarations removed — use globals from Core/Timefilter.mqh
                           (InpUseTime, InpTimezone_offset, InpTimeStart, InpTimeEnd,
                            InpTradeFriday, InpTimeWaitEnd, InpMarketOpenWaitMinutes,
                            InpNewsBrokerGMT).
*/

//--- Inputs declados em Core/Timefilter.mqh (fonte unica).
//--- Esta classe apenas referencia as variaveis globais.

enum ENUM_TIME_BLOCK_REASON
{
   TIME_BLOCK_NONE = 0,
   TIME_BLOCK_SESSION,
   TIME_BLOCK_MARKET_OPEN,
   TIME_BLOCK_FRIDAY,
   TIME_BLOCK_SESSION_END
};

struct GlobalSession
{
   bool   isActive;
   int    hour;
   int    min;
   string name;
   color  clr;
};

class CTimeFilter
{
private:
   string            m_symbol;
   string            m_prefix;
   bool              m_is_waiting;
   GlobalSession     m_global_opens[7];
   
bool              m_timefilter;
    string            m_time_start_str, m_time_end_str;
    int               m_time_start_min, m_time_end_min;
    bool              m_time_friday;
    int               m_time_wait_minutes;
    int               m_market_open_wait_minutes;
    double            m_cached_bottom_price;
    datetime          m_bottom_price_time;
   
   ENUM_TIME_BLOCK_REASON m_block_reason;
   string                  m_block_reason_text;

   void              ResetBlockState();
   int               TimeToMinutes(string time_str);
   bool              CheckGlobalOpens(datetime time_now);
   datetime          SetTimeToDate(datetime base_date, int hour, int min);
   void              SetSession(int index, bool active, int hour, int min, string name, color clr);
   void              CreateVLineWithLabel(string name, datetime time, color clr, string line_desc, string label_text, int width = 1, ENUM_LINE_STYLE style = STYLE_DASH, bool apply_gray_past = false);
   double            GetChartBottomPrice();

public:
                     CTimeFilter(void);
                    ~CTimeFilter(void) { Deinit(); }

   bool              Init(ulong magic, bool useTime, string timeStart, string timeEnd, bool tradeFriday, int timeWaitEnd = 15, int marketOpenWait = 15);
   bool              IsTimeTrade();
   void              DrawSessionLines();
   void              Deinit();
   bool              IsWaiting() { return m_is_waiting; }
   ENUM_TIME_BLOCK_REASON GetBlockReason() { return m_block_reason; }
   string            GetBlockReasonText() { return m_block_reason_text; }
};

//+------------------------------------------------------------------+
CTimeFilter::CTimeFilter(void) : m_symbol(_Symbol), m_is_waiting(false),
   m_block_reason(TIME_BLOCK_NONE), m_block_reason_text(""),
   m_cached_bottom_price(0), m_bottom_price_time(0)
{
   ResetBlockState();
}

void CTimeFilter::ResetBlockState()
{
   m_block_reason      = TIME_BLOCK_NONE;
   m_block_reason_text = "";
}

//+------------------------------------------------------------------+
bool CTimeFilter::Init(ulong magic, bool useTime, string timeStart, string timeEnd, bool tradeFriday, int timeWaitEnd = 15, int marketOpenWait = 15)
{
   m_symbol = _Symbol;
   m_prefix = "TF_" + IntegerToString(magic) + "_";
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_VLINE);
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_TEXT);

   double gmt_to_server_offset = (MQLInfoInteger(MQL_TESTER)) ? 0.0 : (double)(TimeCurrent() - TimeGMT()) / 3600.0;
   if(MQLInfoInteger(MQL_TESTER) && InpNewsBrokerGMT != 0) gmt_to_server_offset = InpNewsBrokerGMT;
   
   int delta_hours = (int)MathRound(gmt_to_server_offset) - InpTimezone_offset;

   m_timefilter              = useTime;
   m_time_start_str          = timeStart;
   m_time_end_str            = timeEnd;
   m_time_friday             = tradeFriday;
   m_time_wait_minutes       = timeWaitEnd;
   m_market_open_wait_minutes = marketOpenWait;

   int start_min_raw = TimeToMinutes(timeStart);
   int end_min_raw   = TimeToMinutes(timeEnd);

   if(start_min_raw != -1 && end_min_raw != -1)
   {
      m_time_start_min = start_min_raw + (delta_hours * 60);
      m_time_end_min   = end_min_raw + (delta_hours * 60);
      while(m_time_start_min >= 1440) m_time_start_min -= 1440;
      while(m_time_start_min < 0)     m_time_start_min += 1440;
      while(m_time_end_min >= 1440)   m_time_end_min -= 1440;
      while(m_time_end_min < 0)       m_time_end_min += 1440;
   }

   SetSession(0, true,  21, 45, "NZX",  clrYellow);
   SetSession(1, true,  23, 05, "ASX",  clrYellow);
   SetSession(2, true,  00, 00, "JPX",  clrYellow);
   SetSession(3, true,  08, 30, "HKEX", clrYellow);
   SetSession(4, true,  08, 00, "SGX",  clrYellow);
   SetSession(5, true,  08, 00, "LSE",  clrYellow);
   SetSession(6, true,  14, 30, "NYSE", clrYellow);
   return true;
}

//+------------------------------------------------------------------+
bool CTimeFilter::IsTimeTrade()
{
   if(!m_timefilter) return true;

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   if(!m_time_friday && dt.day_of_week == 5)
   {
      m_block_reason      = TIME_BLOCK_FRIDAY;
      m_block_reason_text = "BLOCKED - FRIDAY";
      return false;
   }

   int current_min = dt.hour * 60 + dt.min;

   if(m_time_start_min < m_time_end_min)
   {
      if(current_min < m_time_start_min || current_min >= m_time_end_min)
      {
         m_block_reason      = TIME_BLOCK_SESSION;
         m_block_reason_text = "BLOCKED - SESSION";
         return false;
      }
   }
   else if(m_time_start_min > m_time_end_min)
   {
      if(current_min < m_time_start_min && current_min >= m_time_end_min)
      {
         m_block_reason      = TIME_BLOCK_SESSION;
         m_block_reason_text = "BLOCKED - SESSION";
         return false;
      }
   }

   if(m_time_wait_minutes > 0)
   {
      int end_wait_start = m_time_end_min - m_time_wait_minutes;
      if(end_wait_start < 0) end_wait_start += 1440;

      if(m_time_start_min < m_time_end_min)
      {
         if(current_min >= end_wait_start && current_min < m_time_end_min)
         {
            m_block_reason      = TIME_BLOCK_SESSION_END;
            m_block_reason_text = "BLOCKED - SESSION END";
            return false;
         }
      }
      else
      {
         if(current_min >= end_wait_start || current_min < m_time_end_min)
         {
            m_block_reason      = TIME_BLOCK_SESSION_END;
            m_block_reason_text = "BLOCKED - SESSION END";
            return false;
         }
      }
   }

   m_is_waiting = false;
   if(CheckGlobalOpens(now))
   {
      m_block_reason      = TIME_BLOCK_MARKET_OPEN;
      m_block_reason_text = "BLOCKED - MARKET OPEN WAIT";
      return false;
   }

   ResetBlockState();
   return true;
}

//+------------------------------------------------------------------+
int CTimeFilter::TimeToMinutes(string time_str)
{
   StringTrimLeft(time_str);
   StringTrimRight(time_str);
   string result[];
   if(StringSplit(time_str, ':', result) != 2) return -1;
   int hours = (int)StringToInteger(result[0]);
   int mins  = (int)StringToInteger(result[1]);
   if(hours < 0 || hours > 23 || mins < 0 || mins > 59) return -1;
   return hours * 60 + mins;
}

//+------------------------------------------------------------------+
bool CTimeFilter::CheckGlobalOpens(datetime time_now)
{
   int wait_min = m_market_open_wait_minutes;
   if(wait_min <= 0) return false;
   
   for(int i = 0; i < 7; i++)
   {
      if(!m_global_opens[i].isActive) continue;
      datetime open_today = SetTimeToDate(time_now, m_global_opens[i].hour, m_global_opens[i].min);
      datetime rest_end   = open_today + wait_min * 60;
      if(time_now >= open_today && time_now < rest_end)
      {
         m_is_waiting = true;
         return true;
      }
   }
   return false;
}

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
double CTimeFilter::GetChartBottomPrice()
{
   datetime now = TimeCurrent();
   if(m_cached_bottom_price > 0 && now - m_bottom_price_time < 60)
      return m_cached_bottom_price;

   int chart_height = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   int chart_width  = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int bottom_pixel_y = chart_height - 25;
   int center_pixel_x = chart_width / 2;

   int sub_window = 0;
   datetime temp_time = 0;
   double temp_price = 0;

   if(ChartXYToTimePrice(0, center_pixel_x, bottom_pixel_y, sub_window, temp_time, temp_price) && temp_price > 0)
   {
      m_cached_bottom_price = temp_price;
      m_bottom_price_time   = now;
      return m_cached_bottom_price;
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
   m_bottom_price_time   = now;
   return m_cached_bottom_price;
}

//+------------------------------------------------------------------+
void CTimeFilter::CreateVLineWithLabel(string name, datetime time, color clr, string line_desc, string label_text, int width, ENUM_LINE_STYLE style, bool apply_gray_past)
{
   bool is_past = apply_gray_past && (time <= TimeCurrent());
   color draw_color = is_past ? clrGray : clr;
   string line_name = m_prefix + name;
   string text_name = m_prefix + name + "_lbl";

   if(ObjectFind(0, line_name) < 0) ObjectCreate(0, line_name, OBJ_VLINE, 0, time, 0);
   ObjectSetInteger(0, line_name, OBJPROP_TIME, time);
   ObjectSetInteger(0, line_name, OBJPROP_COLOR, draw_color);
   ObjectSetInteger(0, line_name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, line_name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, line_name, OBJPROP_BACK, true);
   ObjectSetInteger(0, line_name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, line_name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, line_name, OBJPROP_TOOLTIP, line_desc);

   double price = GetChartBottomPrice();
   if(ObjectFind(0, text_name) < 0) ObjectCreate(0, text_name, OBJ_TEXT, 0, time, price);
   ObjectSetInteger(0, text_name, OBJPROP_TIME, time);
   ObjectSetDouble(0, text_name, OBJPROP_PRICE, price);
   ObjectSetString(0, text_name, OBJPROP_TEXT, label_text);
   ObjectSetInteger(0, text_name, OBJPROP_COLOR, draw_color);
   ObjectSetInteger(0, text_name, OBJPROP_FONTSIZE, 7);
   ObjectSetString(0, text_name, OBJPROP_FONT, "Arial");
   ObjectSetDouble(0, text_name, OBJPROP_ANGLE, 90);
   ObjectSetInteger(0, text_name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, text_name, OBJPROP_BACK, false);
   ObjectSetInteger(0, text_name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, text_name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
void CTimeFilter::DrawSessionLines()
{
   if(MQLInfoInteger(MQL_TESTER)) return;
   static datetime last_day = 0;
   datetime current_day = iTime(m_symbol, PERIOD_D1, 0);

   if(current_day != last_day)
   {
      last_day = current_day;
      datetime now = TimeCurrent();

      CreateVLineWithLabel("SessionStart", SetTimeToDate(now, m_time_start_min / 60, m_time_start_min % 60), clrTeal, "Start: " + m_time_start_str, "START " + m_time_start_str, 2, STYLE_SOLID, false);
      CreateVLineWithLabel("SessionEnd", SetTimeToDate(now, m_time_end_min / 60, m_time_end_min % 60), clrCrimson, "End: " + m_time_end_str, "END " + m_time_end_str, 2, STYLE_SOLID, false);

      if(m_time_wait_minutes > 0)
      {
         int end_wait_hour = m_time_end_min / 60;
         int end_wait_min  = (m_time_end_min % 60) - m_time_wait_minutes;
         while(end_wait_min < 0) { end_wait_min += 60; end_wait_hour--; }
         while(end_wait_hour < 0) end_wait_hour += 24;
         CreateVLineWithLabel("SessionEndWait", SetTimeToDate(now, end_wait_hour, end_wait_min), clrOrange, "End Wait", "END WAIT", 1, STYLE_DOT, false);
      }

      for(int i = 0; i < 7; i++)
      {
         if(!m_global_opens[i].isActive) continue;
         datetime open_time = SetTimeToDate(now, m_global_opens[i].hour, m_global_opens[i].min);
         CreateVLineWithLabel(m_global_opens[i].name, open_time, m_global_opens[i].clr, m_global_opens[i].name + " Open", m_global_opens[i].name + " OPEN", 1, STYLE_DOT, false);
         CreateVLineWithLabel(m_global_opens[i].name + "_WaitEnd", open_time + m_market_open_wait_minutes * 60, clrYellow, m_global_opens[i].name + " Wait End", m_global_opens[i].name + " WAIT", 1, STYLE_DOT, false);
      }
   }
}

//+------------------------------------------------------------------+
void CTimeFilter::Deinit()
{
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_VLINE);
   ObjectsDeleteAll(0, m_prefix, 0, OBJ_TEXT);
   ChartRedraw();
}