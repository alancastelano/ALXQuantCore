//+------------------------------------------------------------------+
//|                                                    Terminal.mqh  |
//|                     Copyright 2026, ALXQuantCore Ltd.             |
//|                Check list critico: operacao + alerta Telegram     |
//|                                                                   |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      ""
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.10 - 2026-08-20 - Add: CTerminal - check list geral de
            dependencias (arquivos, GlobalVariables, permissoes/modo)
            e do terminal (conexao, build/recursos, conta, simbolo,
            horario). Relatorio com OK/WARN/FAIL + AllOK().
            Sem dependencia de modulos externos (auto-contido).
    v.7.20 - 2026-08-20 - Change: foco em itens CRITICOS que podem
            parar a operacao ou o alerta Telegram. Cada checagem gera
            FAIL real (AllOK() = nenhum FAIL): conta ativa, terminal
            conectado, EA permitido (3 camadas), ping acima do limite
            (SetPingLimitMs, TERMINAL_PING_LAST em us), DLLs nao
            permitidas, dependencias ausentes (FileIsExist/
            GlobalVariableCheck), margem level < 100% e simbolo
            bloqueado. Telemetria nao-critica removida (build, CPU,
            memoria, disco, OpenCL, spread, volume, saldo, horario,
            email/push). Fix: TERMINAL_TRADE_EXPERT (inexistente em
            MQL5) removido; EA permitido via ACCOUNT_TRADE_EXPERT.
    v.7.21 - 2026-08-20 - Add: WarnCount() acessor (contador de WARN)
            p/ notificacao Telegram com severidade (Critical/Warning/
            Info) do EA QUantFX v3.4.0.
*/

//+------------------------------------------------------------------+
//| CTerminal - Diagnostico critico de dependencias e do terminal    |
//|                                                                  |
//| Uso no EA (ex.: OnInit):                                         |
//|   CTerminal m_terminal;                                          |
//|   m_terminal.SetEAContext("EA QUantFX", EA_VERSION);             |
//|   m_terminal.SetSymbol(m_symbol.Name());                         |
//|   m_terminal.SetPingLimitMs(InpPingMaxMs);                       |
//|   m_terminal.AddFileDependency("arquivo.csv");                   |
//|   m_terminal.AddGlobalVarDependency("NI_CAN_TRADE");             |
//|   string rel = m_terminal.RunAll();  Print(rel);                 |
//|   if(!m_terminal.AllOK()) { /* alerta critico incondicional */ } |
//+------------------------------------------------------------------+
class CTerminal
{
private:
   string m_ea_name;
   string m_ea_version;
   string m_symbol;
   string m_files[];
   string m_gvs[];
   int    m_pass;
   int    m_warn;
   int    m_fail;
   int    m_ping_limit_ms;

   string Clean(string s);
   string RawInfo(string label, string value);
   string Raw(string status, string msg);
   string Line(string label, bool ok, string value, bool warn=false);
   string Summary(void);
   void   ResetCounters(void);

public:
   CTerminal();
   void   SetEAContext(string eaName, string version);
   void   SetSymbol(string symbol);
   void   SetPingLimitMs(int limitMs);
   void   AddFileDependency(string path);
   void   AddGlobalVarDependency(string name);
   string CheckDependencies(void);
   string CheckEnvironment(void);
   string CheckSymbol(void);
   string RunAll(void);
   bool   AllOK(void);
   int    FailCount(void);
   int    WarnCount(void);
};

//+------------------------------------------------------------------+
CTerminal::CTerminal(void)
{
   ResetCounters();
   m_ea_name       = "";
   m_ea_version    = "";
   m_symbol        = "";
   m_ping_limit_ms = 300;
}

void CTerminal::SetEAContext(string eaName, string version)
{
   m_ea_name    = eaName;
   m_ea_version = version;
}

void CTerminal::SetSymbol(string symbol)
{
   m_symbol = symbol;
}

void CTerminal::SetPingLimitMs(int limitMs)
{
   if(limitMs > 0)
      m_ping_limit_ms = limitMs;
}

void CTerminal::AddFileDependency(string path)
{
   int n = ArraySize(m_files);
   ArrayResize(m_files, n + 1);
   m_files[n] = path;
}

void CTerminal::AddGlobalVarDependency(string name)
{
   int n = ArraySize(m_gvs);
   ArrayResize(m_gvs, n + 1);
   m_gvs[n] = name;
}

void CTerminal::ResetCounters(void)
{
   m_pass = 0;
   m_warn = 0;
   m_fail = 0;
}

//--- Sanitiza valores para nao quebrar o corpo URL-encoded do Telegram
string CTerminal::Clean(string s)
{
   StringReplace(s, "&", "e");
   StringReplace(s, "=", ":");
   return s;
}

//--- Linha informativa (nao afeta os contadores OK/WARN/FAIL)
string CTerminal::RawInfo(string label, string value)
{
   return "[INFO] " + Clean(label) + ": " + Clean(value) + "\n";
}

//--- Emite linha de resultado e atualiza os contadores
string CTerminal::Raw(string status, string msg)
{
   if(status == "OK")
      m_pass++;
   else if(status == "WARN")
      m_warn++;
   else
      m_fail++;
   return "[" + status + "] " + Clean(msg) + "\n";
}

string CTerminal::Line(string label, bool ok, string value, bool warn=false)
{
   string status = ok ? "OK" : (warn ? "WARN" : "FAIL");
   return Raw(status, label + ": " + value);
}

string CTerminal::Summary(void)
{
   return "== RESUMO: " + IntegerToString(m_pass) + " OK / " +
          IntegerToString(m_warn) + " WARN / " +
          IntegerToString(m_fail) + " FAIL ==";
}

//+------------------------------------------------------------------+
//| 1. DEPENDENCIAS CRITICAS - arquivos + GlobalVariables            |
//|    (FAIL real se ausentes: podem parar a operacao)               |
//+------------------------------------------------------------------+
string CTerminal::CheckDependencies(void)
{
   string r = "== 1. DEPENDENCIAS CRITICAS ==";
   int nf = ArraySize(m_files);
   if(nf == 0)
      r += "\n" + Raw("WARN", "Nenhum arquivo de dependencia configurado");
   for(int i = 0; i < nf; i++)
   {
      bool ok = FileIsExist(m_files[i]);
      r += "\n" + Line("Arquivo", ok, m_files[i]);
   }
   int ng = ArraySize(m_gvs);
   if(ng == 0)
      r += "\n" + Raw("WARN", "Nenhuma GlobalVariable de dependencia configurada");
   for(int i = 0; i < ng; i++)
   {
      bool ok = GlobalVariableCheck(m_gvs[i]);
      r += "\n" + Line("GlobalVar", ok, m_gvs[i]);
   }
   return r;
}

//+------------------------------------------------------------------+
//| 2. AMBIENTE - conta ativa, conexao, EA permitido, DLL, ping,     |
//|    margem (tudo que pode parar a operacao ou o alerta)           |
//+------------------------------------------------------------------+
string CTerminal::CheckEnvironment(void)
{
   string r = "== 2. CONTA / TERMINAL / EA ==";

   //--- Terminal conectado
   bool connected = TerminalInfoInteger(TERMINAL_CONNECTED) != 0;
   r += "\n" + Line("Terminal conectado", connected,
                    connected ? "SIM" : "NAO");

   //--- Trade permitido (terminal)
   bool termTrade = TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0;
   r += "\n" + Line("Trade permitido (terminal)", termTrade,
                    termTrade ? "SIM" : "NAO");

   //--- EA permitido (conta)
   bool acctExpert = AccountInfoInteger(ACCOUNT_TRADE_EXPERT) != 0;
   r += "\n" + Line("EA permitido (conta)", acctExpert,
                    acctExpert ? "SIM" : "NAO");

   //--- Trade permitido (programa MQL)
   bool mqlTrade = MQLInfoInteger(MQL_TRADE_ALLOWED) != 0;
   r += "\n" + Line("Trade permitido (MQL)", mqlTrade,
                    mqlTrade ? "SIM" : "NAO");

   //--- Conta ativa
   bool acctActive = AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) != 0;
   r += "\n" + Line("Conta ativa", acctActive,
                    acctActive ? "SIM" : "NAO");

   //--- DLLs: EA nao usa DLL -> permitido = risco/FAIL
   bool dlls = TerminalInfoInteger(TERMINAL_DLLS_ALLOWED) != 0;
   r += "\n" + Line("DLLs nao permitidas", !dlls,
                    dlls ? "PERMITIDAS (indesejado)" : "NAO permitidas");

   //--- Margem level: 0 (sem posicao) = N/A; < 100% = para trade
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   bool   noPos       = marginLevel <= 0.0;
   bool   marginOk    = noPos || marginLevel >= 100.0;
   string marginStr   = noPos ? "N/A (sem posicao)"
                              : DoubleToString(marginLevel, 1) + " %";
   r += "\n" + Line("Nivel de margem", marginOk, marginStr);

   //--- Ping (TERMINAL_PING_LAST em microssegundos)
   long   pingUs = TerminalInfoInteger(TERMINAL_PING_LAST);
   int    pingMs = (int)(pingUs / 1000);
   bool   pingOk = pingUs <= 0 || pingMs <= m_ping_limit_ms;
   string pingStr = (pingUs <= 0) ? "N/A"
                                  : IntegerToString(pingMs) + " ms (limite "
                                    + IntegerToString(m_ping_limit_ms) + " ms)";
   r += "\n" + Line("Ping servidor", pingOk, pingStr);

   //--- Contexto (informacao, nao afeta contadores)
   long   acctMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   string acctStr  = (acctMode == ACCOUNT_TRADE_MODE_REAL)   ? "REAL" :
                     (acctMode == ACCOUNT_TRADE_MODE_DEMO)   ? "DEMO" :
                     (acctMode == ACCOUNT_TRADE_MODE_CONTEST) ? "CONTEST" : "DESCONHECIDO";
   r += "\n" + RawInfo("Modo da conta", acctStr);
   r += "\n" + RawInfo("Conta", IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)));
   r += "\n" + RawInfo("Corretora", AccountInfoString(ACCOUNT_COMPANY));
   r += "\n" + RawInfo("Servidor", AccountInfoString(ACCOUNT_SERVER));
   r += "\n" + RawInfo("Alavancagem", "1:" + IntegerToString((int)AccountInfoInteger(ACCOUNT_LEVERAGE)));
   r += "\n" + RawInfo("Saldo", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));

   return r;
}

//+------------------------------------------------------------------+
//| 3. SIMBOLO - modo de trade (bloqueado = para a operacao)         |
//+------------------------------------------------------------------+
string CTerminal::CheckSymbol(void)
{
   string r = "== 3. SIMBOLO " + m_symbol + " ==";
   if(StringLen(m_symbol) == 0)
   {
      r += "\n" + Raw("WARN", "Simbolo nao definido (SetSymbol nao chamado)");
      return r;
   }
   long   symMode = SymbolInfoInteger(m_symbol, SYMBOL_TRADE_MODE);
   string symStr  = (symMode == SYMBOL_TRADE_MODE_FULL)      ? "FULL" :
                    (symMode == SYMBOL_TRADE_MODE_LONGONLY)  ? "LONGONLY" :
                    (symMode == SYMBOL_TRADE_MODE_SHORTONLY) ? "SHORTONLY" :
                    (symMode == SYMBOL_TRADE_MODE_CLOSEONLY) ? "CLOSEONLY" : "DISABLED";
   bool   ok = (symMode == SYMBOL_TRADE_MODE_FULL ||
                symMode == SYMBOL_TRADE_MODE_LONGONLY ||
                symMode == SYMBOL_TRADE_MODE_SHORTONLY);
   r += "\n" + Line("Modo de trade", ok, symStr);
   return r;
}

//+------------------------------------------------------------------+
//| RunAll - relatorio completo do checklist critico                 |
//+------------------------------------------------------------------+
string CTerminal::RunAll(void)
{
   ResetCounters();
   string r = "== CHECKLIST CRITICO: " + m_ea_name + " " + m_ea_version + " ==";
   r += "\nAtivo: " + m_symbol;
   r += "\n" + CheckDependencies();
   r += "\n" + CheckEnvironment();
   r += "\n" + CheckSymbol();
   r += "\n" + Summary();
   return r;
}

//+------------------------------------------------------------------+
//| AllOK - nenhum FAIL critico (gate de operacao/alerta)            |
//+------------------------------------------------------------------+
bool CTerminal::AllOK(void)
{
   return m_fail == 0;
}

int CTerminal::FailCount(void)
{
   return m_fail;
}

int CTerminal::WarnCount(void)
{
   return m_warn;
}
//+------------------------------------------------------------------+