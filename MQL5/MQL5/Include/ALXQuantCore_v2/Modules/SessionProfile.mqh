//+------------------------------------------------------------------+
//|                                              SessionProfile.mqh   |
//|                                       ALXQuantCore v1.00          |
//|                Classifica sessão por exchange em tempo real       |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore"
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
*/

enum ENUM_SESSION_ID
{
   SESSION_NONE    = -1,
   SESSION_NZX     = 0,
   SESSION_ASX     = 1,
   SESSION_JPX     = 2,
   SESSION_KOSPI   = 3,
   SESSION_SSE     = 4,
   SESSION_HKEX    = 5,
   SESSION_SGX     = 6,
   SESSION_NSE     = 7,
   SESSION_XETRA   = 8,
   SESSION_SIX     = 9,
   SESSION_LSE     = 10,
   SESSION_B3      = 11,
   SESSION_NYSE    = 12,
   SESSION_TSX     = 13,
   SESSION_TOTAL
};

struct SExchangeSession
{
   ENUM_SESSION_ID id;
   string          name;           // "NZX"
   string          continent;      // "PACIFIC" | "ASIA" | "EUROPE" | "AMERICAS"
   string          country;        // "New Zealand"
   string          currency;       // "NZD"
   int             openHour;       // GMT hour
   int             openMin;        // GMT minute
   int             closeHour;      // GMT hour
   int             closeMin;       // GMT minute
   bool            overnight;      // session spans midnight
};

class CSessionProfile
{
private:
   SExchangeSession m_sessions[SESSION_TOTAL];

public:
   CSessionProfile()
   {
      InitSessions();
   }

   void InitSessions()
   {
      // Pacific
      m_sessions[SESSION_NZX].id        = SESSION_NZX;
      m_sessions[SESSION_NZX].name      = "NZX";   m_sessions[SESSION_NZX].continent  = "PACIFIC";
      m_sessions[SESSION_NZX].country   = "New Zealand"; m_sessions[SESSION_NZX].currency  = "NZD";
      m_sessions[SESSION_NZX].openHour  = 21; m_sessions[SESSION_NZX].openMin   = 45;
      m_sessions[SESSION_NZX].closeHour = 6;  m_sessions[SESSION_NZX].closeMin  = 0;
      m_sessions[SESSION_NZX].overnight = true;

      m_sessions[SESSION_ASX].id        = SESSION_ASX;
      m_sessions[SESSION_ASX].name      = "ASX";   m_sessions[SESSION_ASX].continent  = "PACIFIC";
      m_sessions[SESSION_ASX].country   = "Australia"; m_sessions[SESSION_ASX].currency  = "AUD";
      m_sessions[SESSION_ASX].openHour  = 23; m_sessions[SESSION_ASX].openMin   = 50;
      m_sessions[SESSION_ASX].closeHour = 6;  m_sessions[SESSION_ASX].closeMin  = 0;
      m_sessions[SESSION_ASX].overnight = true;

      // Asia
      m_sessions[SESSION_JPX].id        = SESSION_JPX;
      m_sessions[SESSION_JPX].name      = "JPX";   m_sessions[SESSION_JPX].continent  = "ASIA";
      m_sessions[SESSION_JPX].country   = "Japan";  m_sessions[SESSION_JPX].currency  = "JPY";
      m_sessions[SESSION_JPX].openHour  = 0;  m_sessions[SESSION_JPX].openMin   = 0;
      m_sessions[SESSION_JPX].closeHour = 6;  m_sessions[SESSION_JPX].closeMin  = 0;
      m_sessions[SESSION_JPX].overnight = true;

      m_sessions[SESSION_KOSPI].id        = SESSION_KOSPI;
      m_sessions[SESSION_KOSPI].name      = "KOSPI"; m_sessions[SESSION_KOSPI].continent = "ASIA";
      m_sessions[SESSION_KOSPI].country   = "South Korea"; m_sessions[SESSION_KOSPI].currency = "KRW";
      m_sessions[SESSION_KOSPI].openHour  = 0;  m_sessions[SESSION_KOSPI].openMin   = 0;
      m_sessions[SESSION_KOSPI].closeHour = 6;  m_sessions[SESSION_KOSPI].closeMin  = 30;
      m_sessions[SESSION_KOSPI].overnight = true;

      m_sessions[SESSION_SSE].id        = SESSION_SSE;
      m_sessions[SESSION_SSE].name      = "SSE";   m_sessions[SESSION_SSE].continent  = "ASIA";
      m_sessions[SESSION_SSE].country   = "China";  m_sessions[SESSION_SSE].currency  = "CNY";
      m_sessions[SESSION_SSE].openHour  = 1;  m_sessions[SESSION_SSE].openMin   = 30;
      m_sessions[SESSION_SSE].closeHour = 8;  m_sessions[SESSION_SSE].closeMin  = 0;
      m_sessions[SESSION_SSE].overnight = false;

      m_sessions[SESSION_HKEX].id        = SESSION_HKEX;
      m_sessions[SESSION_HKEX].name      = "HKEX";  m_sessions[SESSION_HKEX].continent = "ASIA";
      m_sessions[SESSION_HKEX].country   = "Hong Kong"; m_sessions[SESSION_HKEX].currency = "HKD";
      m_sessions[SESSION_HKEX].openHour  = 1;  m_sessions[SESSION_HKEX].openMin   = 30;
      m_sessions[SESSION_HKEX].closeHour = 8;  m_sessions[SESSION_HKEX].closeMin  = 0;
      m_sessions[SESSION_HKEX].overnight = false;

      m_sessions[SESSION_SGX].id        = SESSION_SGX;
      m_sessions[SESSION_SGX].name      = "SGX";   m_sessions[SESSION_SGX].continent  = "ASIA";
      m_sessions[SESSION_SGX].country   = "Singapore"; m_sessions[SESSION_SGX].currency = "SGD";
      m_sessions[SESSION_SGX].openHour  = 1;  m_sessions[SESSION_SGX].openMin   = 0;
      m_sessions[SESSION_SGX].closeHour = 9;  m_sessions[SESSION_SGX].closeMin  = 0;
      m_sessions[SESSION_SGX].overnight = false;

      m_sessions[SESSION_NSE].id        = SESSION_NSE;
      m_sessions[SESSION_NSE].name      = "NSE";   m_sessions[SESSION_NSE].continent  = "ASIA";
      m_sessions[SESSION_NSE].country   = "India";  m_sessions[SESSION_NSE].currency  = "INR";
      m_sessions[SESSION_NSE].openHour  = 3;  m_sessions[SESSION_NSE].openMin   = 45;
      m_sessions[SESSION_NSE].closeHour = 11; m_sessions[SESSION_NSE].closeMin  = 0;
      m_sessions[SESSION_NSE].overnight = false;

      // Europe
      m_sessions[SESSION_XETRA].id        = SESSION_XETRA;
      m_sessions[SESSION_XETRA].name      = "XETRA"; m_sessions[SESSION_XETRA].continent = "EUROPE";
      m_sessions[SESSION_XETRA].country   = "Germany"; m_sessions[SESSION_XETRA].currency = "EUR";
      m_sessions[SESSION_XETRA].openHour  = 7;  m_sessions[SESSION_XETRA].openMin   = 0;
      m_sessions[SESSION_XETRA].closeHour = 15; m_sessions[SESSION_XETRA].closeMin  = 30;
      m_sessions[SESSION_XETRA].overnight = false;

      m_sessions[SESSION_SIX].id        = SESSION_SIX;
      m_sessions[SESSION_SIX].name      = "SIX";   m_sessions[SESSION_SIX].continent  = "EUROPE";
      m_sessions[SESSION_SIX].country   = "Switzerland"; m_sessions[SESSION_SIX].currency = "CHF";
      m_sessions[SESSION_SIX].openHour  = 7;  m_sessions[SESSION_SIX].openMin   = 0;
      m_sessions[SESSION_SIX].closeHour = 15; m_sessions[SESSION_SIX].closeMin  = 30;
      m_sessions[SESSION_SIX].overnight = false;

      m_sessions[SESSION_LSE].id        = SESSION_LSE;
      m_sessions[SESSION_LSE].name      = "LSE";   m_sessions[SESSION_LSE].continent  = "EUROPE";
      m_sessions[SESSION_LSE].country   = "UK";    m_sessions[SESSION_LSE].currency  = "GBP";
      m_sessions[SESSION_LSE].openHour  = 8;  m_sessions[SESSION_LSE].openMin   = 0;
      m_sessions[SESSION_LSE].closeHour = 16; m_sessions[SESSION_LSE].closeMin  = 30;
      m_sessions[SESSION_LSE].overnight = false;

      // Americas
      m_sessions[SESSION_B3].id        = SESSION_B3;
      m_sessions[SESSION_B3].name      = "B3";    m_sessions[SESSION_B3].continent   = "AMERICAS";
      m_sessions[SESSION_B3].country   = "Brazil"; m_sessions[SESSION_B3].currency   = "BRL";
      m_sessions[SESSION_B3].openHour  = 13; m_sessions[SESSION_B3].openMin   = 0;
      m_sessions[SESSION_B3].closeHour = 21; m_sessions[SESSION_B3].closeMin  = 0;
      m_sessions[SESSION_B3].overnight = false;

      m_sessions[SESSION_NYSE].id        = SESSION_NYSE;
      m_sessions[SESSION_NYSE].name      = "NYSE";  m_sessions[SESSION_NYSE].continent = "AMERICAS";
      m_sessions[SESSION_NYSE].country   = "US";    m_sessions[SESSION_NYSE].currency = "USD";
      m_sessions[SESSION_NYSE].openHour  = 14; m_sessions[SESSION_NYSE].openMin   = 30;
      m_sessions[SESSION_NYSE].closeHour = 21; m_sessions[SESSION_NYSE].closeMin  = 0;
      m_sessions[SESSION_NYSE].overnight = false;

      m_sessions[SESSION_TSX].id        = SESSION_TSX;
      m_sessions[SESSION_TSX].name      = "TSX";   m_sessions[SESSION_TSX].continent  = "AMERICAS";
      m_sessions[SESSION_TSX].country   = "Canada"; m_sessions[SESSION_TSX].currency  = "CAD";
      m_sessions[SESSION_TSX].openHour  = 14; m_sessions[SESSION_TSX].openMin   = 30;
      m_sessions[SESSION_TSX].closeHour = 21; m_sessions[SESSION_TSX].closeMin  = 0;
      m_sessions[SESSION_TSX].overnight = false;
   }

   bool IsSessionOpen(ENUM_SESSION_ID id, datetime t = 0)
   {
      if(t == 0) t = TimeCurrent();
      MqlDateTime dt;
      TimeToStruct(t, dt);
      int nowMin = dt.hour * 60 + dt.min;

      int openMin  = m_sessions[id].openHour * 60 + m_sessions[id].openMin;
      int closeMin = m_sessions[id].closeHour * 60 + m_sessions[id].closeMin;

      if(m_sessions[id].overnight)
      {
         if(openMin < closeMin)
            closeMin += 1440;
         if(nowMin < openMin)
            nowMin += 1440;
      }

      return (nowMin >= openMin && nowMin < closeMin);
   }

   ENUM_SESSION_ID GetPrimarySession(datetime t = 0)
   {
      if(t == 0) t = TimeCurrent();

      // Check all sessions in order of preference (most recently opened first)
      ENUM_SESSION_ID best = SESSION_NONE;
      int bestOpenMin = -1;
      int nowMin = -1;

      MqlDateTime dt;
      TimeToStruct(t, dt);
      nowMin = dt.hour * 60 + dt.min;

      for(int i = 0; i < SESSION_TOTAL; i++)
      {
         if(!IsSessionOpen((ENUM_SESSION_ID)i, t)) continue;

         int openMin = m_sessions[i].openHour * 60 + m_sessions[i].openMin;
         int adjOpen = openMin;

         if(m_sessions[i].overnight && openMin > nowMin)
            adjOpen -= 1440;

         if(adjOpen > bestOpenMin)
         {
            bestOpenMin = adjOpen;
            best = (ENUM_SESSION_ID)i;
         }
      }

      return best;
   }

   string GetSessionName(ENUM_SESSION_ID id)
   {
      if(id < 0 || id >= SESSION_TOTAL) return "NONE";
      return m_sessions[id].continent + "_" + m_sessions[id].name;
   }

   string GetSessionNameOnly(ENUM_SESSION_ID id)
   {
      if(id < 0 || id >= SESSION_TOTAL) return "NONE";
      return m_sessions[id].name;
   }

   string GetSessionContinent(ENUM_SESSION_ID id)
   {
      if(id < 0 || id >= SESSION_TOTAL) return "NONE";
      return m_sessions[id].continent;
   }

   string GetSessionCountry(ENUM_SESSION_ID id)
   {
      if(id < 0 || id >= SESSION_TOTAL) return "NONE";
      return m_sessions[id].country;
   }

   string GetSessionCurrency(ENUM_SESSION_ID id)
   {
      if(id < 0 || id >= SESSION_TOTAL) return "NONE";
      return m_sessions[id].currency;
   }

string GetActiveSessionName(datetime t = 0)
   {
      return GetSessionName(GetPrimarySession(t));
   }

   // v5.1: 14 sessões detalhadas (GMT)
   string GetActiveSessionName14(datetime t = 0)
   {
      if(t == 0) t = TimeCurrent();
      
      MqlDateTime dt;
      TimeToStruct(t, dt);
      int hour = dt.hour;
      int min  = dt.min;
      int totalMin = hour * 60 + min;
      
      // 14 sessões detalhadas (GMT)
      if(totalMin >= 21*60+45 || totalMin < 6*60)       return "Off_Hours";        // 21:45-06:00
      if(totalMin >= 21*60+45 && totalMin < 23*60+50)   return "Australia_NZ";      // 21:45-23:50
      if(totalMin >= 0 && totalMin < 6*60)              return "Off_Hours";        // 00:00-06:00
      if(totalMin >= 6*60 && totalMin < 8*60)           return "Asia_1_Tokyo";      // 06:00-08:00
      if(totalMin >= 8*60 && totalMin < 9*60+30)        return "Asia_2_China_HK";   // 08:00-09:30
      if(totalMin >= 9*60+30 && totalMin < 12*60)       return "Asia_3_SE_India";   // 09:30-12:00
      if(totalMin >= 12*60 && totalMin < 14*60)         return "Europe_Open";       // 12:00-14:00
      if(totalMin >= 14*60 && totalMin < 16*60)         return "Europe_Main";       // 14:00-16:00
      if(totalMin >= 16*60 && totalMin < 17*60)         return "NY_Pre_Brazil";     // 16:00-17:00
      if(totalMin >= 17*60 && totalMin < 20*60)         return "NY_Main";           // 17:00-20:00
      if(totalMin >= 20*60 && totalMin < 22*60)         return "NY_Post";           // 20:00-22:00
      
      return "Off_Hours";
   }

   string GetActiveSessionsCSV(datetime t = 0)
   {
      if(t == 0) t = TimeCurrent();
      string result = "";
      int count = 0;

      for(int i = 0; i < SESSION_TOTAL; i++)
      {
         if(IsSessionOpen((ENUM_SESSION_ID)i, t))
         {
            if(count > 0) result += "|";
            result += m_sessions[i].name;
            count++;
         }
      }

      return (count > 0) ? result : "NONE";
   }

   int GetActiveSessionsCount(datetime t = 0)
   {
      if(t == 0) t = TimeCurrent();
      int count = 0;
      for(int i = 0; i < SESSION_TOTAL; i++)
      {
         if(IsSessionOpen((ENUM_SESSION_ID)i, t))
            count++;
      }
      return count;
   }

   bool IsOverlapPeriod(datetime t = 0)
   {
      if(t == 0) t = TimeCurrent();
      int count = 0;
      for(int i = 0; i < SESSION_TOTAL; i++)
      {
         if(IsSessionOpen((ENUM_SESSION_ID)i, t))
            count++;
      }
      return count >= 2;
   }

   int GetMinutesToSessionEnd(ENUM_SESSION_ID id, datetime t = 0)
   {
      if(t == 0) t = TimeCurrent();
      MqlDateTime dt;
      TimeToStruct(t, dt);
      int nowMin = dt.hour * 60 + dt.min;
      int closeMin = m_sessions[id].closeHour * 60 + m_sessions[id].closeMin;

      if(m_sessions[id].overnight && closeMin < nowMin)
         closeMin += 1440;

      return closeMin - nowMin;
   }

   int GetMinutesSinceSessionOpen(ENUM_SESSION_ID id, datetime t = 0)
   {
      if(t == 0) t = TimeCurrent();
      MqlDateTime dt;
      TimeToStruct(t, dt);
      int nowMin = dt.hour * 60 + dt.min;
      int openMin = m_sessions[id].openHour * 60 + m_sessions[id].openMin;

      if(m_sessions[id].overnight && nowMin < openMin)
         nowMin += 1440;

      return nowMin - openMin;
   }

   // Retorna a sessão relevante para um par Forex específico
   ENUM_SESSION_ID GetSessionForSymbol(string symbol)
   {
      if(symbol == "NZDUSD" || symbol == "NZDCAD" || symbol == "NZDJPY" ||
         symbol == "NZDCHF" || symbol == "AUDNZD")
         return SESSION_NZX;

      if(symbol == "AUDUSD" || symbol == "AUDJPY" || symbol == "AUDCAD" ||
         symbol == "AUDCHF" || symbol == "AUDNZD")
         return SESSION_ASX;

      if(symbol == "USDJPY" || symbol == "EURJPY" || symbol == "GBPJPY" ||
         symbol == "CHFJPY" || symbol == "AUDJPY" || symbol == "NZDJPY" ||
         symbol == "CADJPY")
         return SESSION_JPX;

      if(symbol == "USDSGD" || symbol == "EURSGD" || symbol == "AUDSGD")
         return SESSION_SGX;
      if(symbol == "USDCNH" || symbol == "EURCNH" || symbol == "USDHKD")
         return SESSION_HKEX;
      if(symbol == "USDINR")
         return SESSION_NSE;

      if(symbol == "EURUSD" || symbol == "EURGBP" || symbol == "EURCHF" ||
         symbol == "EURAUD" || symbol == "EURNZD" || symbol == "EURCAD" ||
         symbol == "EURJPY" || symbol == "EURSGD")
         return SESSION_XETRA;

      if(symbol == "GBPUSD" || symbol == "GBPJPY" || symbol == "GBPAUD" ||
         symbol == "GBPNZD" || symbol == "GBPCAD" || symbol == "GBPCHF")
         return SESSION_LSE;

      if(symbol == "USDCHF" || symbol == "EURCHF" || symbol == "GBPCHF")
         return SESSION_SIX;

      if(symbol == "USDCAD")
         return SESSION_TSX;
      if(symbol == "USDBRL")
         return SESSION_B3;

      return SESSION_NYSE;
   }
};
