//+------------------------------------------------------------------+
//|                                                ALXAccountManager.mq5 |
//|                          Copyright 2026, ALXQuant Ltd.           |
//|                                                                  |
//|  EA de MONITORAMENTO (NAO executa trading).                      |
//|  Envia telemetria da conta (balance, equity, margin, posicoes,   |
//|  deals) ao servidor ALX Account Monitor via WebRequest().        |
//|                                                                  |
//|  Fluxo: MT5 -> HTTPS -> ALX Server -> WebSocket -> GUI           |
//|                                                                  |
//|  Seguranca: API Key (header X-API-Key) + account_id + timestamp  |
//|  + nonce. A chave e emitida automaticamente pelo servidor no     |
//|  primeiro contato (Master Key) e cacheada localmente.            |
//|                                                                  |
//|  NAO armazena senhas de MT5 em lugar algum; o campo login e      |
//|  apenas o numero identificador da conta, lido do terminal.       |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuant Ltd."
#property version   "1.00"
#property strict
#property description "ALX Account Manager - Monitoramento de conta (sem trading)"

#define EA_NAME    "ALXAccountManager"
#define EA_VERSION "v1.0"

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group               "=== CONEXAO ==="
input string              InpServerUrl        = "http://127.0.0.1:8400"; // Servidor Account Monitor
input string              InpAccountId        = "";                       // Account ID (vazio = usa numero MT5)
input string              InpMasterKey        = "am_4GyHCdzF3N3KnCftGuAj-0V3yorCR44RVrw4hUis5R0";                      // Master Key (1o contato)
//+------------------------------------------------------------------+
input group               "=== TELEMETRIA ==="
input int                 InpHeartbeatSec     = 10;                        // Intervalo heartbeat (seg)
input bool                InpSendEvents       = true;                     // Enviar eventos imediatos
//+------------------------------------------------------------------+

#include <Trade\PositionInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Trade\DealInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| Globais                                                          |
//+------------------------------------------------------------------+
string g_apiKey    = "";        // API Key cacheada (emitida pelo servidor)
bool   g_hasApiKey = false;
datetime g_lastHeartbeat = 0;
string g_nonceSeed  = "";
int    g_nonceCounter = 0;

CPositionInfo m_pos;
CDealInfo     m_deal;
COrderInfo    m_order;
CHistoryOrderInfo m_histOrder;

// Snapshot previo de posicoes para detectar eventos (open/close/modify)
struct PosTicket {
   ulong  ticket;
   string symbol;
   long   type;
   double volume;
   double sl;
   double tp;
};
PosTicket g_prevPositions[];
datetime  g_lastDealCheck = 0;

// P&L acumulado (calculado pelo EA a partir do historico MT5)
double g_pnlDay        = 0.0;
double g_pnlWeek       = 0.0;
double g_pnlMonth      = 0.0;
datetime g_lastWeekCalc  = 0;
datetime g_lastMonthCalc = 0;
string g_accountId       = "";  // account_id resolvido (input ou numero MT5)

//+------------------------------------------------------------------+
//| Util: monta JSON                                                |
//+------------------------------------------------------------------+
string JsonEscape(const string s)
{
   string r = s;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "\"", "\\\"");
   StringReplace(r, "\n", "\\n");
   StringReplace(r, "\r", "\\r");
   StringReplace(r, "\t", "\\t");
   return r;
}

string JsonKeyVal(const string key, const string val)
{
   return "\"" + key + "\":\"" + JsonEscape(val) + "\"";
}

string JsonKeyNum(const string key, const double val)
{
   return "\"" + key + "\":" + DoubleToString(val, 8);
}

string JsonLong(const string key, const long val)
{
   return "\"" + key + "\":" + IntegerToString(val);
}

string JsonULong(const string key, const ulong val)
{
   return "\"" + key + "\":" + IntegerToString((long)val);
}

string FreshNonce()
{
   g_nonceCounter++;
   return IntegerToString((long)TimeLocal()) + "_" + IntegerToString(g_nonceCounter);
}

//+------------------------------------------------------------------+
//| Le todos os quality_*.json do diretorio mql5/                    |
//+------------------------------------------------------------------+
string ReadAllQualityJson()
{
   string result = "";
   string filename = FindFirstQualityFile();
   while(StringLen(filename) > 0)
   {
      string content = ReadFileContent("mql5\\" + filename);
      if(StringLen(content) > 10) // JSON minimo: "{}" = 2 chars
      {
         // Extrair magic_symbol do nome: quality_{magic}_{symbol}.json
         string key = filename;
         StringReplace(key, "quality_", "");
         StringReplace(key, ".json", "");
         if(StringLen(result) > 0) result += ",";
         result += "\"" + key + "\":" + content;
      }
      filename = FindNextQualityFile();
   }
   return result;
}

string g_qualityFindHandle = "";
string g_qualityCurrentFile = "";

string FindFirstQualityFile()
{
   string result = "";
   long handle = FileFindFirst("mql5\\quality_*.json", result);
   if(handle <= 0) return "";
   g_qualityFindHandle = IntegerToString(handle);
   g_qualityCurrentFile = result;
   return result;
}

string FindNextQualityFile()
{
   string result = "";
   if(g_qualityFindHandle == "") return "";
   long handle = StringToInteger(g_qualityFindHandle);
   if(handle <= 0) return "";
   if(!FileFindNext(handle, result))
     {
      g_qualityFindHandle = "";
      return "";
     }
   g_qualityCurrentFile = result;
   return result;
}

string ReadFileContent(string filepath)
{
   int handle = FileOpen(filepath, FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle == INVALID_HANDLE) return "";
   string content = "";
   while(!FileIsEnding(handle))
      content += FileReadString(handle);
   FileClose(handle);
   return content;
}

//+------------------------------------------------------------------+
//| Calcula P&L acumulado (profit+swap+comission) de deals fechados  |
//| desde 'from' ate agora.                                          |
//+------------------------------------------------------------------+
double CalcPnlSince(datetime from)
{
   if(!HistorySelect(from, TimeCurrent())) return 0.0;
   double pnl = 0.0;
   int total = HistoryDealsTotal();

   MqlDateTime fdt;
   TimeToStruct(from, fdt);
   Print(EA_NAME, ": DEBUG from=", from, " (",
         fdt.year, "-", fdt.mon, "-", fdt.day, " ", fdt.hour, ":", fdt.min,
         ") total=", total);

   double sumIn = 0.0, sumOut = 0.0, sumInOut = 0.0, sumOutBy = 0.0;
   int cntIn = 0, cntOut = 0, cntInOut = 0, cntOutBy = 0;

   for(int i = 0; i < total; i++)
     {
      if(!m_deal.SelectByIndex(i)) continue;
      long posid = m_deal.PositionId();
      long entry = (long)m_deal.Entry();
      long dtype = (long)m_deal.Type();
      double profit = m_deal.Profit();
      double swap = m_deal.Swap();
      double commission = m_deal.Commission();
      double net = profit + swap + commission;
      double t = (double)m_deal.Time();

      if(entry == DEAL_ENTRY_IN)       { sumIn   += net; cntIn++; }
      else if(entry == DEAL_ENTRY_OUT) { sumOut  += net; cntOut++; }
      else if(entry == DEAL_ENTRY_INOUT){sumInOut+= net; cntInOut++; }
      else if(entry == DEAL_ENTRY_OUT_BY){sumOutBy+=net; cntOutBy++; }

      // print apenas deals relevantes (fechamento ou balanco) para economizar log
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT || entry == DEAL_ENTRY_OUT_BY)
        {
         Print(EA_NAME, ": DEBUG deal#", i,
               " posid=", posid,
               " entry=", entry,
               " type=", dtype,
               " profit=", profit,
               " swap=", swap,
               " comm=", commission,
               " time=", (long)m_deal.Time());
        }

      if(m_deal.Entry() != DEAL_ENTRY_OUT) continue;
      pnl += net;
     }

   Print(EA_NAME, ": DEBUG RESUMO  IN(count=", cntIn, " sum=", DoubleToString(sumIn,2),
         ")  OUT(count=", cntOut, " sum=", DoubleToString(sumOut,2),
         ")  INOUT(count=", cntInOut, " sum=", DoubleToString(sumInOut,2),
         ")  OUT_BY(count=", cntOutBy, " sum=", DoubleToString(sumOutBy,2), ")");
   Print(EA_NAME, ": DEBUG CalcPnlSince RESULT pnl=", DoubleToString(pnl,2));
   return pnl;
}

//+------------------------------------------------------------------+
//| Retorna timestamp do inicio do dia (00:00 UTC)                   |
//+------------------------------------------------------------------+
datetime GetDayStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return TimeCurrent() - dt.hour * 3600 - dt.min * 60 - dt.sec;
}

//+------------------------------------------------------------------+
//| Retorna timestamp do inicio da semana (Segunda 00:00 UTC)        |
//+------------------------------------------------------------------+
datetime GetWeekStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int dayOfWeek = dt.day_of_week; // 0=Sunday, 1=Monday, ...
   int daysSinceMonday = (dayOfWeek == 0) ? 6 : (dayOfWeek - 1);
   datetime todayMidnight = TimeCurrent() - dt.hour * 3600 - dt.min * 60 - dt.sec;
   return todayMidnight - daysSinceMonday * 86400;
}

//+------------------------------------------------------------------+
//| Retorna timestamp do inicio do mes (dia 1 00:00 UTC)             |
//+------------------------------------------------------------------+
datetime GetMonthStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime todayMidnight = TimeCurrent() - dt.hour * 3600 - dt.min * 60 - dt.sec;
   return todayMidnight - (dt.day - 1) * 86400;
}

//+------------------------------------------------------------------+
//| Atualiza P&L day/week/month (recalcula a cada heartbeat)         |
//+------------------------------------------------------------------+
void UpdatePnlWeekMonth()
{
   g_pnlDay   = CalcPnlSince(GetDayStart());
   g_pnlWeek  = CalcPnlSince(GetWeekStart());
   g_pnlMonth = CalcPnlSince(GetMonthStart());
}

//+------------------------------------------------------------------+
//| Envia payload JSON via WebRequest POST                            |
//| Retorna HTTP status code (200, 201, 401, etc).                   |
//+------------------------------------------------------------------+
int HttpPost(const string path, const string body, const string apiKey, string &response)
{
   char post[];
   char result[];
   string result_headers;
   int timeout = 60000;

   int len = StringToCharArray(body, post, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0) ArrayResize(post, len - 1);

   string headers = "Content-Type: application/json\r\n";
   if(apiKey != "")
      headers += "X-API-Key: " + apiKey + "\r\n";

   ResetLastError();
   string url = InpServerUrl;
   while(StringLen(url) > 0 && StringGetCharacter(url, StringLen(url) - 1) == '/')
      url = StringSubstr(url, 0, StringLen(url) - 1);

   int res = WebRequest("POST", url + path, headers, timeout, post, result, result_headers);

   if(res == -1)
     {
      int err = GetLastError();
      Print(EA_NAME, ": WebRequest falhou. Erro ", err,
            ". Adicione ", InpServerUrl, " em Ferramentas -> Opcoes -> Expert Advisors -> WebRequest.");
      return -1;
     }

   response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

   if(res < 200 || res >= 300)
     {
      // WebRequest can return a server status (for example 1003) rather
      // than -1. Keep the response visible so the server's reason is clear.
      Print(EA_NAME, ": HTTP ", res, " em ", path,
            " last_error=", GetLastError(),
            " headers=", result_headers,
            " body=", response);
     }

   return res;
}

//+------------------------------------------------------------------+
//| Extrai o valor de "issued_api_key" de uma resposta JSON simples  |
//+------------------------------------------------------------------+
string ExtractIssuedKey(const string response)
{
   string k1 = "\"issued_api_key\":"; 
   int p = StringFind(response, k1);
   if(p < 0) return "";
   // pula ate a aspas de abertura
   int q1 = StringFind(response, "\"", p + StringLen(k1));
   if(q1 < 0) return "";
   int q2 = StringFind(response, "\"", q1 + 1);
   if(q2 < 0) return "";
   return StringSubstr(response, q1 + 1, q2 - q1 - 1);
}

//+------------------------------------------------------------------+
//| Coleta dados da conta                                            |
//+------------------------------------------------------------------+
double AccountBalance()  { return AccountInfoDouble(ACCOUNT_BALANCE); }
double AccountEquity()   { return AccountInfoDouble(ACCOUNT_EQUITY); }
double AccountMargin()   { return AccountInfoDouble(ACCOUNT_MARGIN); }
double AccountFreeMargin(){ return AccountInfoDouble(ACCOUNT_MARGIN_FREE); }
double AccountMarginLevel(){ return AccountInfoDouble(ACCOUNT_MARGIN_LEVEL); }
double AccountProfit()   { return AccountInfoDouble(ACCOUNT_PROFIT); }
double AccountCredit()   { return AccountInfoDouble(ACCOUNT_CREDIT); }
long   AccountLeverage() { return AccountInfoInteger(ACCOUNT_LEVERAGE); }
long   AccountLogin()    { return AccountInfoInteger(ACCOUNT_LOGIN); }
string AccountServer()   { return AccountInfoString(ACCOUNT_SERVER); }
string AccountCompany()  { return AccountInfoString(ACCOUNT_COMPANY); }
string AccountCurrency() { return AccountInfoString(ACCOUNT_CURRENCY); }

//+------------------------------------------------------------------+
//| Monta JSON de uma posicao                                        |
//+------------------------------------------------------------------+
string PositionJson(const ulong ticket, const string symbol, const long type,
                    const double volume, const double openPrice, const double currentPrice,
                    const double sl, const double tp, const double profit,
                    const double swap, const double commission, const ulong magic,
                    const datetime openTime, const string comment)
{
   string t = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
   return "{"
        + JsonULong("ticket", ticket)
        + "," + JsonKeyVal("symbol", symbol)
        + "," + JsonKeyVal("type", t)
        + "," + JsonKeyNum("volume", volume)
        + "," + JsonKeyNum("open_price", openPrice)
        + "," + JsonKeyNum("current_price", currentPrice)
        + "," + JsonKeyNum("sl", sl)
        + "," + JsonKeyNum("tp", tp)
        + "," + JsonKeyNum("profit", profit)
        + "," + JsonKeyNum("swap", swap)
        + "," + JsonKeyNum("commission", commission)
        + "," + JsonULong("magic", magic)
        + "," + JsonLong("open_time", (long)openTime)
        + "," + JsonKeyVal("comment", comment)
        + "}";
}

//+------------------------------------------------------------------+
//| Monta JSON de um deal (historico)                                |
//+------------------------------------------------------------------+
string DealJson(const ulong deal, const ulong ticket, const string symbol,
                const string type, const double volume, const double profit,
                const double swap, const double commission, const double closeTime)
{
   return "{"
        + JsonULong("deal", deal)
        + "," + JsonULong("ticket", ticket)
        + "," + JsonKeyVal("symbol", symbol)
        + "," + JsonKeyVal("type", type)
        + "," + JsonKeyNum("volume", volume)
        + "," + JsonKeyNum("profit", profit)
        + "," + JsonKeyNum("swap", swap)
        + "," + JsonKeyNum("commission", commission)
        + "," + JsonKeyNum("close_time", closeTime)
        + "}";
}

//+------------------------------------------------------------------+
//| Coleta deals fechados desde 'from'                               |
//+------------------------------------------------------------------+
string BuildDealsJson(datetime from)
{
   if(!HistorySelect(from, TimeCurrent())) return "";
   string json = "";
   bool first = true;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      if(!m_deal.SelectByIndex(i)) continue;
      ENUM_DEAL_ENTRY entry = m_deal.Entry();
      if(entry == DEAL_ENTRY_IN) continue;  // pular entradas
      if(!first) json += ",";
      first = false;
      string dealType = (m_deal.Type() == DEAL_TYPE_BUY) ? "BUY" : "SELL";
      json += DealJson(
         m_deal.Ticket(),
         m_deal.PositionId(),
         m_deal.Symbol(),
         dealType,
         m_deal.Volume(),
         m_deal.Profit(),
         m_deal.Swap(),
         m_deal.Commission(),
         (double)m_deal.Time()
      );
     }
   return json;
}

//+------------------------------------------------------------------+
//| Monta o JSON completo do heartbeat (conta + posicoes)            |
//+------------------------------------------------------------------+
string BuildHeartbeatJson()
{
   double ts = (double)TimeGMT();

   string body = "{";
   body += JsonKeyVal("account_id", g_accountId);
   body += "," + JsonKeyNum("timestamp", ts);
   body += "," + JsonKeyVal("nonce", FreshNonce());
   body += "," + JsonLong("login", AccountLogin());
   body += "," + JsonKeyVal("broker", AccountCompany());
   body += "," + JsonKeyVal("server", AccountServer());
   body += "," + JsonKeyVal("currency", AccountCurrency());
   body += "," + JsonKeyNum("balance", AccountBalance());
   body += "," + JsonKeyNum("equity", AccountEquity());
   body += "," + JsonKeyNum("margin", AccountMargin());
   body += "," + JsonKeyNum("free_margin", AccountFreeMargin());
   body += "," + JsonKeyNum("margin_level", AccountMarginLevel());
   body += "," + JsonKeyNum("profit", AccountProfit());
   body += "," + JsonKeyNum("credit", AccountCredit());
   body += "," + JsonLong("leverage", AccountLeverage());
   body += "," + JsonKeyNum("pnl_day", g_pnlDay);
   body += "," + JsonKeyNum("pnl_week", g_pnlWeek);
   body += "," + JsonKeyNum("pnl_month", g_pnlMonth);

   // Terminal info
   body += "," + JsonLong("terminal_build", TerminalInfoInteger(TERMINAL_BUILD));
   body += "," + JsonLong("terminal_ping_ms", TerminalInfoInteger(TERMINAL_PING_LAST) / 1000);
   body += ",\"terminal_connected\":" + (TerminalInfoInteger(TERMINAL_CONNECTED) ? "true" : "false");
   body += ",\"terminal_name\":\"" + JsonEscape(TerminalInfoString(TERMINAL_NAME)) + "\"";
   body += ",\"vps_info\":\"" + JsonEscape(TerminalInfoString(TERMINAL_NAME)) + "\"";

   // Quality data from trading EAs
   string qualityData = ReadAllQualityJson();
   body += ",\"quality\":{" + qualityData + "}";

   body += ",\"positions\":[";
   int total = PositionsTotal();
   bool first = true;
   for(int i = 0; i < total; i++)
     {
      if(!m_pos.SelectByIndex(i)) continue;
      if(!first) body += ",";
      first = false;
      body += PositionJson(
         m_pos.Ticket(),
         m_pos.Symbol(),
         (long)m_pos.PositionType(),
         m_pos.Volume(),
         m_pos.PriceOpen(),
         m_pos.PriceCurrent(),
         m_pos.StopLoss(),
         m_pos.TakeProfit(),
         m_pos.Profit(),
         m_pos.Swap(),
         m_pos.Commission(),
         m_pos.Magic(),
         (datetime)m_pos.Time(),
         m_pos.Comment()
      );
     }
   body += "]";

   body += ",\"orders\":[]";
   body += ",\"deals\":[]";
   body += "}";
   return body;
}

//+------------------------------------------------------------------+
//| Envia heartbeat                                                  |
//+------------------------------------------------------------------+
void SendHeartbeat()
{
   string body = BuildHeartbeatJson();
   string response = "";
   string key = (g_hasApiKey ? g_apiKey : InpMasterKey);
   int status = HttpPost("/api/v1/accounts/heartbeat", body, key, response);

   // Watchdog: 401 = key cacheada invalida (servidor reiniciou) → re-autenticar
   if(status == 401 && g_hasApiKey)
     {
      Print(EA_NAME, ": 401 detectado — re-autenticando com Master Key...");
      g_hasApiKey = false;
      g_apiKey = "";
      key = InpMasterKey;
      body = BuildHeartbeatJson();  // nonce novo para evitar replay
      status = HttpPost("/api/v1/accounts/heartbeat", body, key, response);
     }

   if(status == 200 || status == 201)
     {
      if(!g_hasApiKey)
        {
         string issued = ExtractIssuedKey(response);
         if(StringLen(issued) > 0)
           {
            g_apiKey = issued;
            g_hasApiKey = true;
            Print(EA_NAME, ": API Key emitida e cacheada para ", g_accountId);
           }
        }
     }
   else if(status != -1)
     {
      Print(EA_NAME, ": HTTP ", status, " em heartbeat");
     }
}

//+------------------------------------------------------------------+
//| Atualiza snapshot de posicoes e detecta eventos                  |
//+------------------------------------------------------------------+
void SnapshotPositions(PosTicket &arr[])
{
   ArrayResize(arr, 0);
   int total = PositionsTotal();
   ArrayResize(arr, total);
   int n = 0;
   for(int i = 0; i < total; i++)
     {
      if(!m_pos.SelectByIndex(i)) continue;
      arr[n].ticket = m_pos.Ticket();
      arr[n].symbol = m_pos.Symbol();
      arr[n].type   = (long)m_pos.PositionType();
      arr[n].volume = m_pos.Volume();
      arr[n].sl     = m_pos.StopLoss();
      arr[n].tp     = m_pos.TakeProfit();
      n++;
     }
   ArrayResize(arr, n);
}

bool HasTicket(PosTicket &arr[], ulong ticket)
{
   for(int i = 0; i < ArraySize(arr); i++)
      if(arr[i].ticket == ticket) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Verifica deals fechados desde a ultima checagem                  |
//+------------------------------------------------------------------+
void SendClosedDeals()
{
   // simplificado: envia eventos de close para deals recentes
   datetime from = g_lastDealCheck > 0 ? g_lastDealCheck : TimeCurrent() - InpHeartbeatSec * 2;
   g_lastDealCheck = TimeCurrent();

   if(!HistorySelect(from, TimeCurrent())) return;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      if(!m_deal.SelectByIndex(i)) continue;
      if(m_deal.Entry() != DEAL_ENTRY_OUT) continue;
      if(m_deal.Time() < from) continue;

      string body = "{";
      body += JsonKeyVal("account_id", g_accountId);
      body += "," + JsonKeyNum("timestamp", (double)TimeGMT());
      body += "," + JsonKeyVal("nonce", FreshNonce());
      body += "," + JsonKeyVal("event", "POSITION_CLOSE");
      body += "," + JsonULong("event_id", m_deal.Ticket());
      body += ",\"position\":{";
      body += JsonLong("ticket", m_deal.PositionId());
      body += "," + JsonKeyVal("symbol", m_deal.Symbol());
      body += "," + JsonKeyNum("profit", m_deal.Profit());
      body += "}";
      body += "}";

      string key = (g_hasApiKey ? g_apiKey : InpMasterKey);
      string response = "";
      int status = HttpPost("/api/v1/accounts/events", body, key, response);

      // Watchdog: 401 → re-autenticar e retry
      if(status == 401 && g_hasApiKey)
        {
         Print(EA_NAME, ": 401 em deal — re-autenticando...");
         g_hasApiKey = false;
         g_apiKey = "";
         key = InpMasterKey;
         HttpPost("/api/v1/accounts/events", body, key, response);
        }
     }
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   // Resolve account_id: usa input se definido, senao usa numero MT5
   if(StringLen(InpAccountId) > 0)
      g_accountId = InpAccountId;
   else
      g_accountId = IntegerToString(AccountLogin());

   Print(EA_NAME, " ", EA_VERSION, " iniciado. Account=", g_accountId, " Server=", InpServerUrl);

   if(InpServerUrl == "")
     {
      Print(EA_NAME, ": ERRO - InpServerUrl vazio.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(StringLen(g_accountId) == 0)
     {
      Print(EA_NAME, ": ERRO - Nao foi possivel obter account_id.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   int hbSec = InpHeartbeatSec;
   if(hbSec < 1) hbSec = 1;

   SnapshotPositions(g_prevPositions);
   UpdatePnlWeekMonth();

   EventSetMillisecondTimer(hbSec * 1000);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| OnTimer -> heartbeat periodico                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   UpdatePnlWeekMonth();
   SendHeartbeat();

   if(InpSendEvents)
     {
      SendClosedDeals();
      // detecta mudanca de posicoes (open/close)
      PosTicket curr[];
      SnapshotPositions(curr);

      // close: estava antes, sumiu agora
      for(int i = 0; i < ArraySize(g_prevPositions); i++)
        {
         if(!HasTicket(curr, g_prevPositions[i].ticket))
           {
            // posicao fechada
            Print(EA_NAME, ": posicao fechada detectada ticket=", g_prevPositions[i].ticket);
           }
        }
      // open: nao estava antes, esta agora
      for(int j = 0; j < ArraySize(curr); j++)
        {
         if(!HasTicket(g_prevPositions, curr[j].ticket))
           {
            Print(EA_NAME, ": posicao aberta detectada ticket=", curr[j].ticket);
           }
        }

      // copia manual (struct contem object string, ArrayCopy nao e permitido)
      ArrayResize(g_prevPositions, ArraySize(curr));
      for(int k = 0; k < ArraySize(curr); k++)
         g_prevPositions[k] = curr[k];
     }
}

//+------------------------------------------------------------------+
//| OnTradeTransaction (opcional, eventos em tempo real)             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(!InpSendEvents) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   m_deal.Ticket(trans.deal);
   if(m_deal.Entry() != DEAL_ENTRY_OUT) return;

   string body = "{";
   body += JsonKeyVal("account_id", g_accountId);
   body += "," + JsonKeyNum("timestamp", (double)TimeGMT());
   body += "," + JsonKeyVal("nonce", FreshNonce());
   body += "," + JsonKeyVal("event", "POSITION_CLOSE");
   body += "," + JsonULong("event_id", m_deal.Ticket());
   body += ",\"position\":{";
   body += JsonLong("ticket", m_deal.PositionId());
   body += "," + JsonKeyVal("symbol", m_deal.Symbol());
   body += "," + JsonKeyNum("profit", m_deal.Profit());
   body += "}";
   body += "}";

   string key = (g_hasApiKey ? g_apiKey : InpMasterKey);
   string response = "";
   int status = HttpPost("/api/v1/accounts/events", body, key, response);

   // Watchdog: 401 → re-autenticar e retry
   if(status == 401 && g_hasApiKey)
     {
      Print(EA_NAME, ": 401 em trade event — re-autenticando...");
      g_hasApiKey = false;
      g_apiKey = "";
      key = InpMasterKey;
      HttpPost("/api/v1/accounts/events", body, key, response);
     }
}
//+------------------------------------------------------------------+