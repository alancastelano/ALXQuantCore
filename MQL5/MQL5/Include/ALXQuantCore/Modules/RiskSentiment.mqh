//+------------------------------------------------------------------+
//|                                              RiskSentiment.mqh    |
//|                                     Copyright 2026, ALXQuantCore |
//|                   CSV-based risk sentiment from Python dataset    |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore"
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.2.00 - 2026-07-01 - Versao base CSV risk sentiment.
    v.2.01 - 2026-08-03 - Fix: aceita coluna roro_score (Python) alem de global_risk_score.
                        - Add: sp500, GetSP500(), GetYieldCurve(), Get*_PctChange() p/ DataMiner.
*/

#ifndef RISK_SENTIMENT_CSV_FILE
#define RISK_SENTIMENT_CSV_FILE "risk_sentiment_daily.csv"
#endif

//+------------------------------------------------------------------+
//| Classe de Risk Sentiment — le risk_sentiment_daily.csv via MQL5  |
//| Init() carrega CSV inteiro em memória. GetSentiment() busca a    |
//| data atual via TimeCurrent() e retorna 1=RISK_ON, 0=NEUTRAL,     |
//| -1=RISK_OFF. GetTradeDirection(symbol) combina sentimento +     |
//| perfil do ativo para dar direção (1=BUY, 0=ANY, -1=SELL).       |
//+------------------------------------------------------------------+
class CRiskSentiment
{
private:
   struct SCSVRow
   {
      string date;              // "YYYY-MM-DD"
      double global_risk_score;
      string risk_label;        // "RISK_ON" | "NEUTRAL" | "RISK_OFF"
      double vix;               // VIX index level
      double usd_index;         // DXY index level
      double yield_2y;          // US Treasury 2Y yield
      double yield_10y;         // US Treasury 10Y yield
      double sp500;             // SP500 level (opcional, 0 se ausente)
   };

    SCSVRow           m_rows[];
    bool              m_loaded;
    bool              m_available;

   datetime          m_last_bar;
   int               m_cached_sentiment;
    double            m_cached_score;
    double            m_cached_vix;
    double            m_cached_dxy;
    double            m_cached_y2y;
    double            m_cached_y10y;
    double            m_cached_sp500;
    int               m_current_idx;
    string            m_cached_label;

   bool              LoadCSV();
   int               FindRowByDate(datetime dt);
   datetime          ParseDate(string date_str);
   double            PctChange(double curr, double prev);

public:
   CRiskSentiment();
   ~CRiskSentiment();

   void              Init();

    string            GetRiskLabel();
    double            GetRiskScore();
    double            GetVIX();
    double            GetDXY();
    double            GetYield2Y();
    double            GetYield10Y();
    double            GetSP500();
    double            GetYieldCurve();
    double            GetVIX_PctChange();
    double            GetDXY_PctChange();
    double            GetSP500_PctChange();
    double            GetYield2Y_PctChange();
    double            GetYield10Y_PctChange();
    bool              IsYieldCurveInverted();
    int               GetSentiment();
   int               GetTradeDirection(string symbol);

   static int        GetAssetProfile(string symbol);
};

//+------------------------------------------------------------------+
//| Construtor / Destrutor                                            |
//+------------------------------------------------------------------+
CRiskSentiment::CRiskSentiment()
{
   m_loaded = false;
   m_available = false;
   m_last_bar = 0;
   m_cached_sentiment = 0;
   m_cached_score = 0.5;
   m_cached_vix = 0;
   m_cached_dxy = 0;
   m_cached_y2y = 0;
   m_cached_y10y = 0;
   m_cached_sp500 = 0;
   m_current_idx = -1;
   m_cached_label = "NEUTRAL";
   ArrayResize(m_rows, 0);
}

CRiskSentiment::~CRiskSentiment() {}

//+------------------------------------------------------------------+
//| Init — carrega CSV inteiro em m_rows[] (chamado 1x no OnInit)    |
//+------------------------------------------------------------------+
void CRiskSentiment::Init()
{
   LoadCSV();
   GetSentiment();
   Print(__FUNCTION__ + " - The initial design module has been successfully initialized!");
}

//+------------------------------------------------------------------+
//| LoadCSV — lê risk_sentiment_daily.csv de FILE_COMMON              |
//+------------------------------------------------------------------+
bool CRiskSentiment::LoadCSV()
{
   m_loaded = false;
   ArrayResize(m_rows, 0);

   int handle = FileOpen(RISK_SENTIMENT_CSV_FILE, FILE_READ | FILE_TXT | FILE_COMMON, 0, CP_UTF8);
   if(handle == INVALID_HANDLE)
   {
      Print("[RiskSentiment] CSV nao encontrado: ", RISK_SENTIMENT_CSV_FILE);
      return false;
   }

   //--- Parse cabecalho (primeira linha)
   string header_line = FileReadString(handle);
   string cols[];
   int n = StringSplit(header_line, ',', cols);

   int col_date = -1, col_label = -1, col_score = -1;
   int col_vix = -1, col_usd = -1;
   int col_y2y = -1, col_y10y = -1, col_sp500 = -1;
   for(int i = 0; i < n; i++)
   {
      string c = cols[i];
      StringTrimLeft(c);
      StringTrimRight(c);
      if(c == "date")                   col_date = i;
      else if(c == "risk_label")        col_label = i;
      else if(c == "global_risk_score" || c == "roro_score") col_score = i;
      else if(c == "vix")               col_vix = i;
      else if(c == "usd_index")         col_usd = i;
      else if(c == "yield_2y")          col_y2y = i;
      else if(c == "yield_10y")         col_y10y = i;
      else if(c == "sp500")             col_sp500 = i;
   }

   if(col_date < 0 || col_label < 0 || col_score < 0)
   {
      Print("[RiskSentiment] CSV sem colunas obrigatorias (date, risk_label, global_risk_score)");
      FileClose(handle);
      return false;
   }

   //--- Parse linhas de dados — ler linha a linha sem concatenacao
   int capacity = 1000;
   ArrayResize(m_rows, capacity);
   int count = 0;

   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      StringTrimRight(line);
      if(StringLen(line) < 5) continue;

      string fields[];
      int fn = StringSplit(line, ',', fields);
      if(fn <= col_date || fn <= col_label || fn <= col_score) continue;

      SCSVRow r;
      r.date = fields[col_date];
      r.risk_label = fields[col_label];
      r.global_risk_score = StringToDouble(fields[col_score]);
      r.vix = (col_vix >= 0 && fn > col_vix) ? StringToDouble(fields[col_vix]) : 0;
      r.usd_index = (col_usd >= 0 && fn > col_usd) ? StringToDouble(fields[col_usd]) : 0;
      r.yield_2y = (col_y2y >= 0 && fn > col_y2y) ? StringToDouble(fields[col_y2y]) : 0;
      r.yield_10y = (col_y10y >= 0 && fn > col_y10y) ? StringToDouble(fields[col_y10y]) : 0;
      r.sp500 = (col_sp500 >= 0 && fn > col_sp500) ? StringToDouble(fields[col_sp500]) : 0;

      if(count >= capacity)
      {
         capacity += 500;
         ArrayResize(m_rows, capacity);
      }

      m_rows[count] = r;
      count++;
   }

   FileClose(handle);

   ArrayResize(m_rows, count);

   if(count == 0)
   {
      Print("[RiskSentiment] CSV sem linhas de dados");
      return false;
   }

   m_loaded = true;
   Print("[RiskSentiment] CSV carregado: ", count, " linhas de ", m_rows[0].date, " ate ", m_rows[count - 1].date);
   return true;
}

//+------------------------------------------------------------------+
//| ParseDate — converte "YYYY-MM-DD" para datetime                  |
//+------------------------------------------------------------------+
datetime CRiskSentiment::ParseDate(string date_str)
{
   string parts[];
   int n = StringSplit(date_str, '-', parts);
   if(n < 3) return 0;
   return StringToTime(StringFormat("%d.%02d.%02d",
      (int)StringToInteger(parts[0]),
      (int)StringToInteger(parts[1]),
      (int)StringToInteger(parts[2])));
}

//+------------------------------------------------------------------+
//| FindRowByDate — busca binária pela maior data <= dt              |
//+------------------------------------------------------------------+
int CRiskSentiment::FindRowByDate(datetime dt)
{
   int lo = 0, hi = ArraySize(m_rows) - 1;
   int best = -1;
   while(lo <= hi)
   {
      int mid = (lo + hi) / 2;
      datetime mid_dt = ParseDate(m_rows[mid].date);
      if(mid_dt <= dt) { best = mid; lo = mid + 1; }
      else              { hi = mid - 1; }
   }
   return best;
}

//+------------------------------------------------------------------+
//| GetSentiment — atualiza cache (se nova barra) e retorna int      |
//| 1 = RISK_ON, 0 = NEUTRAL, -1 = RISK_OFF                          |
//+------------------------------------------------------------------+
int CRiskSentiment::GetSentiment()
{
   datetime now = TimeCurrent();
   datetime day_start = now - (now % 86400);

   if(day_start == m_last_bar && m_loaded)
      return m_cached_sentiment;

   m_last_bar = day_start;

   if(!m_loaded)
   {
      m_available = false;
      m_cached_sentiment = 0;
      m_cached_score = 0.5;
      m_cached_vix = -1;
      m_cached_dxy = -1;
      m_cached_y2y = -1;
      m_cached_y10y = -1;
      m_cached_sp500 = -1;
      m_cached_label = "INDISPONIVEL";
      return 0;
   }

   int idx = FindRowByDate(now);
   if(idx < 0)
   {
      m_available = false;
      m_cached_sentiment = 0;
      m_cached_score = 0.5;
      m_cached_vix = -1;
      m_cached_dxy = -1;
      m_cached_y2y = -1;
      m_cached_y10y = -1;
      m_cached_sp500 = -1;
      m_cached_label = "INDISPONIVEL";
   }
   else
   {
      m_available = true;
      m_cached_score = m_rows[idx].global_risk_score;
      m_cached_vix = m_rows[idx].vix;
      m_cached_dxy = m_rows[idx].usd_index;
      m_cached_y2y = m_rows[idx].yield_2y;
      m_cached_y10y = m_rows[idx].yield_10y;
      m_cached_sp500 = m_rows[idx].sp500;
      m_cached_label = m_rows[idx].risk_label;
      m_current_idx = idx;

      if(m_cached_label == "RISK_ON")
         m_cached_sentiment = 1;
      else if(m_cached_label == "RISK_OFF")
         m_cached_sentiment = -1;
      else
         m_cached_sentiment = 0;
   }

   return m_cached_sentiment;
}

//+------------------------------------------------------------------+
//| GetRiskLabel — retorna "RISK_ON" | "NEUTRAL" | "RISK_OFF"        |
//+------------------------------------------------------------------+
string CRiskSentiment::GetRiskLabel()
{
   GetSentiment();
   return m_cached_label;
}

//+------------------------------------------------------------------+
//| GetRiskScore — retorna global_risk_score (0.0 a 1.0)            |
//+------------------------------------------------------------------+
double CRiskSentiment::GetRiskScore()
{
   GetSentiment();
   return m_cached_score;
}

//+------------------------------------------------------------------+
//| GetAssetProfile — perfil macro do ativo                          |
//| Retorno: 1 = risk-on (sobe na euforia)                           |
//|         -1 = risk-off (sobe no panico, safe haven)               |
//|          0 = neutro (sem vies direcional forte)                  |
//+------------------------------------------------------------------+
int CRiskSentiment::GetAssetProfile(string symbol)
{
   if(symbol == "XAUUSD" || symbol == "GOLD" || symbol == "XAU" ||
      symbol == "VIX" || symbol == "DXY" || symbol == "USDX" ||
      symbol == "USD_INDEX")
      return -1;

   if(symbol == "EURUSD" || symbol == "USDCAD" || symbol == "GBPUSD" ||
      symbol == "USDJPY" || symbol == "USDCHF" || symbol == "NZDUSD" ||
      symbol == "AUDUSD" || symbol == "EURJPY" || symbol == "GBPJPY" ||
      symbol == "EURAUD")
      return 0;

   return 1;
}

//+------------------------------------------------------------------+
//| GetVIX — retorna valor do VIX (cache da linha do dia)            |
//+------------------------------------------------------------------+
double CRiskSentiment::GetVIX()
{
   GetSentiment();
   return m_cached_vix;
}

//+------------------------------------------------------------------+
//| GetDXY — retorna valor do DXY/usd_index (cache da linha do dia)  |
//+------------------------------------------------------------------+
double CRiskSentiment::GetDXY()
{
   GetSentiment();
   return m_cached_dxy;
}

//+------------------------------------------------------------------+
//| GetYield2Y — retorna yield 2Y (cache da linha do dia)            |
//+------------------------------------------------------------------+
double CRiskSentiment::GetYield2Y()
{
   GetSentiment();
   return m_cached_y2y;
}

//+------------------------------------------------------------------+
//| GetYield10Y — retorna yield 10Y (cache da linha do dia)          |
//+------------------------------------------------------------------+
double CRiskSentiment::GetYield10Y()
{
   GetSentiment();
   return m_cached_y10y;
}

//+------------------------------------------------------------------+
//| IsYieldCurveInverted — TRUE se a curva 10Y-2Y esta invertida     |
//| (10Y < 2Y), indicando risco de recessao.                         |
//+------------------------------------------------------------------+
bool CRiskSentiment::IsYieldCurveInverted()
{
   GetSentiment();
   return (m_cached_y10y > 0 && m_cached_y2y > 0 && m_cached_y10y < m_cached_y2y);
}

//+------------------------------------------------------------------+
//| GetTradeDirection — combina sentimento + perfil do ativo         |
//| Retorno: 1 = favorece COMPRA, -1 = favorece VENDA, 0 = neutro   |
//|                                                                  |
//| RISK_ON  + risk-on  asset (SP500)  = BUY  (+1)                  |
//| RISK_ON  + risk-off asset (XAUUSD) = SELL (-1)                  |
//| RISK_OFF + risk-on  asset (SP500)  = SELL (-1)                  |
//| RISK_OFF + risk-off asset (XAUUSD) = BUY  (+1)                  |
//| Qualquer + neutro          asset   = ANY  (0)                   |
//+------------------------------------------------------------------+
int CRiskSentiment::GetTradeDirection(string symbol)
{
   int profile = GetAssetProfile(symbol);
   if(profile == 0) return 0;
   return GetSentiment() * profile;
}

//+------------------------------------------------------------------+
//| GetSP500 — retorna nivel do SP500 (cache da linha do dia)        |
//+------------------------------------------------------------------+
double CRiskSentiment::GetSP500()
{
   GetSentiment();
   return m_cached_sp500;
}

//+------------------------------------------------------------------+
//| GetYieldCurve — diferencial 10Y - 2Y em pontos percentuais       |
//+------------------------------------------------------------------+
double CRiskSentiment::GetYieldCurve()
{
   GetSentiment();
   if(!m_available) return -1.0;
   return (m_cached_y10y - m_cached_y2y);
}

//+------------------------------------------------------------------+
//| PctChange — variacao percentual entre dois valores               |
//+------------------------------------------------------------------+
double CRiskSentiment::PctChange(double curr, double prev)
{
   if(prev == 0) return 0;
   return ((curr - prev) / prev) * 100.0;
}

//+------------------------------------------------------------------+
//| GetVIX_PctChange — variacao diaria do VIX (%)                   |
//+------------------------------------------------------------------+
double CRiskSentiment::GetVIX_PctChange()
{
   GetSentiment();
   if(!m_available || m_current_idx <= 0) return -1.0;
   return PctChange(m_rows[m_current_idx].vix, m_rows[m_current_idx - 1].vix);
}

//+------------------------------------------------------------------+
//| GetDXY_PctChange — variacao diaria do DXY/usd_index (%)          |
//+------------------------------------------------------------------+
double CRiskSentiment::GetDXY_PctChange()
{
   GetSentiment();
   if(!m_available || m_current_idx <= 0) return -1.0;
   return PctChange(m_rows[m_current_idx].usd_index, m_rows[m_current_idx - 1].usd_index);
}

//+------------------------------------------------------------------+
//| GetSP500_PctChange — variacao diaria do SP500 (%)                |
//+------------------------------------------------------------------+
double CRiskSentiment::GetSP500_PctChange()
{
   GetSentiment();
   if(!m_available || m_current_idx <= 0) return -1.0;
   return PctChange(m_rows[m_current_idx].sp500, m_rows[m_current_idx - 1].sp500);
}

//+------------------------------------------------------------------+
//| GetYield2Y_PctChange — variacao diaria do yield 2Y (%)           |
//+------------------------------------------------------------------+
double CRiskSentiment::GetYield2Y_PctChange()
{
   GetSentiment();
   if(!m_available || m_current_idx <= 0) return -1.0;
   return PctChange(m_rows[m_current_idx].yield_2y, m_rows[m_current_idx - 1].yield_2y);
}

//+------------------------------------------------------------------+
//| GetYield10Y_PctChange — variacao diaria do yield 10Y (%)         |
//+------------------------------------------------------------------+
double CRiskSentiment::GetYield10Y_PctChange()
{
   GetSentiment();
   if(!m_available || m_current_idx <= 0) return -1.0;
   return PctChange(m_rows[m_current_idx].yield_10y, m_rows[m_current_idx - 1].yield_10y);
}
