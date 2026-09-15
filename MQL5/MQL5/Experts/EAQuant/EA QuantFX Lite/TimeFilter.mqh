//+------------------------------------------------------------------+
//|                                                   TimeFilter.mqh |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+


//========================= TIME FILTER ==============================
bool IsTimeFilter()
{
   MqlDateTime dt;
   datetime brazilTime = GetBrazilTime();

   if(!TimeToStruct(brazilTime, dt))
      return false;

   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;

   if(dt.day_of_week == 5 && !InpTradeFriday)
      return false;

   if(InpTimeStart <= InpTimeEnd)
      return (dt.hour >= InpTimeStart && dt.hour < InpTimeEnd);
   else
      return (dt.hour >= InpTimeStart || dt.hour < InpTimeEnd);
}

//========================= TIME HELPERS =============================
datetime GetReliableUTC()
{
   if(sets.g_syncOk)
      return TimeLocal() + sets.g_utcOffsetSeconds;
   return TimeGMT();
}

datetime GetBrazilTime()
{
   return GetReliableUTC() - 3 * 3600;
}

void SyncUniversalClock()
{
   datetime trueUtc;
   if(GetTrueUTCFromWeb(trueUtc))
   {
      sets.g_utcOffsetSeconds = trueUtc - TimeLocal();
      sets.g_syncOk = true;
   }
   else
   {
      Print("Sync failed, keeping last known offset.");
   }
}

bool GetTrueUTCFromWeb(datetime &utcOut)
{
   string resultHeaders;
   char   data[];
   char   result[];

   ResetLastError();
   int res = WebRequest("GET", "https://www.google.com", NULL, 5000, data, result, resultHeaders);
   if(res == -1)
   {
      Print("WebRequest error (", GetLastError(), "). Allow URL in Options > Expert Advisors.");
      return false;
   }

   int pos = StringFind(resultHeaders, "Date:");
   if(pos < 0) return false;

   string dateLine = StringSubstr(resultHeaders, pos + 5);
   int endPos = StringFind(dateLine, "\r\n");
   if(endPos > 0) dateLine = StringSubstr(dateLine, 0, endPos);
   StringTrimLeft(dateLine);
   StringTrimRight(dateLine);

   string parts[];
   if(StringSplit(dateLine, ' ', parts) < 6) return false;

   string months[12] = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"};
   int month = -1;
   for(int i = 0; i < 12; i++)
      if(parts[2] == months[i]) { month = i + 1; break; }
   if(month == -1) return false;

   string hms[];
   StringSplit(parts[4], ':', hms);

   MqlDateTime dt;
   dt.day  = (int)StringToInteger(parts[1]);
   dt.mon  = month;
   dt.year = (int)StringToInteger(parts[3]);
   dt.hour = (int)StringToInteger(hms[0]);
   dt.min  = (int)StringToInteger(hms[1]);
   dt.sec  = (int)StringToInteger(hms[2]);

   utcOut = StructToTime(dt);
   return true;
}

//+------------------------------------------------------------------+
//| NEWS FILTER (GlobalVariable)                                     |
//+------------------------------------------------------------------+
bool CanTradeByNews()
{
   if(!GlobalVariableCheck("NI_CAN_TRADE"))
      return true;
   return (GlobalVariableGet("NI_CAN_TRADE") >= 0.5);
}
