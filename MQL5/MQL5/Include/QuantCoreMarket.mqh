//+------------------------------------------------------------------+
//|                                            QuantCoreFull.mqh     |
//|     Integração UNIFICADA: Regime + Notícias + Sessões            |
//+------------------------------------------------------------------+
#property copyright "QuantCore System"
#property version   "1.00"
#property strict

// ================= CONFIGURAÇÕES (serão expostas no EA que incluir) =================
input string   QC_API_Server     = "localhost";
input int      QC_API_Port       = 8000;
input int      QC_TimeoutMs      = 2000;
input int      QC_MaxRetries     = 5;
input int      QC_NewsBufferMin  = 5;
input string   QC_NewsImpact     = "HIGH";
input string   QC_DefaultTF      = "M5";

// ================= ESTRUTURA DE RETORNO =================
struct QCFullStatus
{
   string symbol;
   string trend, volatility, momentum, summary, regime_status;
   double price;
   bool is_buy_signal, is_sell_signal, high_volatility;
   bool news_active;
   string next_news_name, next_news_impact;
   int next_news_minutes_away;
   bool nzx_open, asx_open, sgx_open, hkex_open;
   bool sse_open, jpx_open, lse_open, nyse_open;
   string server_time_utc;
};

//+------------------------------------------------------------------+
//| Obtém status COMPLETO (regime + notícias + sessões)              |
//+------------------------------------------------------------------+
bool GetQCFullStatus(string symbol, QCFullStatus &qs)
{
   string url = StringFormat("http://%s:%d/api/v1/mql5/full-status/%s?timeframe=%s&news_buffer_min=%d&news_impact=%s",
                            QC_API_Server, QC_API_Port, symbol, QC_DefaultTF, QC_NewsBufferMin, QC_NewsImpact);
   
   uchar postData[], resultData[];
   string headers = "User-Agent: MQL5-QuantCore\r\n", resultHeaders;
   
   for(int retry = 0; retry < QC_MaxRetries; retry++)
   {
      int httpCode = WebRequest("GET", url, headers, QC_TimeoutMs, postData, resultData, resultHeaders);
      if(httpCode >= 200 && httpCode < 300)
         return ParseQCFullStatus(CharArrayToString(resultData), qs);
      
      Print("⚠️ QC WebRequest falhou (HTTP ", httpCode, "), tentativa ", retry+1, "/", QC_MaxRetries);
      
      if(retry < QC_MaxRetries - 1)
         Sleep(500 * (retry + 1));
   }
   return false;
}

//+------------------------------------------------------------------+
//| Parser interno (não chamar diretamente)                          |
//+------------------------------------------------------------------+
bool ParseQCFullStatus(string json, QCFullStatus &qs)
{
   string reg = ExtractJsonObject(json, "regime");
   if(reg != "")
   {
      qs.symbol = ExtractJsonValue(json, "symbol");
      qs.trend = ExtractJsonValue(reg, "trend");
      qs.volatility = ExtractJsonValue(reg, "volatility");
      qs.momentum = ExtractJsonValue(reg, "momentum");
      qs.summary = ExtractJsonValue(reg, "summary");
      qs.price = StringToDouble(ExtractJsonValue(reg, "price"));
      qs.is_buy_signal = (ExtractJsonValue(reg, "is_buy") == "true");
      qs.is_sell_signal = (ExtractJsonValue(reg, "is_sell") == "true");
      qs.high_volatility = (ExtractJsonValue(reg, "high_vol") == "true");
      qs.regime_status = ExtractJsonValue(reg, "status");
   }
   
   string news = ExtractJsonObject(json, "news");
   if(news != "")
   {
      qs.news_active = (ExtractJsonValue(news, "is_active") == "true");
      if(qs.news_active)
      {
         string ev = ExtractJsonArray(news, "active_events");
         if(ev != "" && StringFind(ev, "{") != -1)
         {
            qs.next_news_name = ExtractJsonValue(ev, "name");
            qs.next_news_impact = ExtractJsonValue(ev, "impact");
            string m = ExtractJsonValue(ev, "minutes_away");
            qs.next_news_minutes_away = (m != "") ? (int)StringToInteger(m) : 999;
         }
      }
   }
   
   string sess = ExtractJsonObject(json, "sessions");
   if(sess != "")
   {
      qs.nzx_open  = (ExtractJsonValue(sess, "NZX_Wellington") == "true");
      qs.asx_open  = (ExtractJsonValue(sess, "ASX_Sydney") == "true");
      qs.sgx_open  = (ExtractJsonValue(sess, "SGX_Singapore") == "true");
      qs.hkex_open = (ExtractJsonValue(sess, "HKEX_HongKong") == "true");
      qs.sse_open  = (ExtractJsonValue(sess, "SSE_Shanghai") == "true");
      qs.jpx_open  = (ExtractJsonValue(sess, "JPX_Tokyo") == "true");
      qs.lse_open  = (ExtractJsonValue(sess, "LSE_London") == "true");
      qs.nyse_open = (ExtractJsonValue(sess, "NYSE_Nasdaq") == "true");
   }
   qs.server_time_utc = ExtractJsonValue(json, "server_time_utc");
   return true;
}

//+------------------------------------------------------------------+
//| Utilitários JSON (leves e seguros)                               |
//+------------------------------------------------------------------+
string ExtractJsonValue(string json, string key)
{
   string sk = "\"" + key + "\":";
   int p = StringFind(json, sk); if(p == -1) return "";
   p += StringLen(sk);
   while(p < StringLen(json) && (StringSubstr(json,p,1)==" " || StringSubstr(json,p,1)=="\t")) p++;
   if(StringSubstr(json,p,1) == "\"") { p++; int e = StringFind(json, "\"", p); return (e==-1) ? "" : StringSubstr(json, p, e-p); }
   int e = p; while(e < StringLen(json)) { string c = StringSubstr(json,e,1); if(c=="," || c=="}" || c=="]" || c==" ") break; e++; }
   return StringSubstr(json, p, e-p);
}

string ExtractJsonObject(string json, string key)
{
   int p = StringFind(json, "\"" + key + "\""); if(p == -1) return "";
   p = StringFind(json, "{", p); if(p == -1) return "";
   int bc = 1, e = p+1; while(e < StringLen(json) && bc > 0) { string c = StringSubstr(json,e,1); if(c=="{") bc++; else if(c=="}") bc--; e++; }
   return (bc != 0) ? "" : StringSubstr(json, p, e-p);
}

string ExtractJsonArray(string json, string key)
{
   int p = StringFind(json, "\"" + key + "\""); if(p == -1) return "";
   p = StringFind(json, "[", p); if(p == -1) return "";
   int bc = 1, e = p+1; while(e < StringLen(json) && bc > 0) { string c = StringSubstr(json,e,1); if(c=="[") bc++; else if(c=="]") bc--; e++; }
   return (bc != 0) ? "" : StringSubstr(json, p, e-p);
}
//+------------------------------------------------------------------+