//+------------------------------------------------------------------+
//|                                                 PortfolioRisk.mqh |
//|                     Copyright 2026, ALXQuantCore Ltd.             |
//|       Coordenador de risco multi-EA (registry + exposicao)        |
//|                                                                   |
//| v7.1.0                                                            |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property version "7.10"
/*
    v.7.10 - 2026-08-15 - Add: CPortfolioRisk - coordenador de risco
        multi-EA distribuido via GlobalVariables (registry ALX_PF_*):
        heartbeat de instancias, exposicao por moeda (gross lots),
        share 1/N do orcamento de lotes e anti-hedge por simbolo.
*/

#ifndef PORTFOLIO_RISK_MQH
#define PORTFOLIO_RISK_MQH

//+------------------------------------------------------------------+
//| Inputs (file-scope, opt-in; EA define os valores)                |
//+------------------------------------------------------------------+
input group             "▸ Portfolio Risk (multi-EA)"
input bool              InpPortfolioRisk      = false;   // Portfolio risk (On/Off)
input double            InpPF_MaxLotsCurrency = 2.0;     // Max open lots per currency (0=off)
input double            InpPF_MaxLotsTotal    = 5.0;     // Portfolio lot budget (0=off)
input bool              InpPF_AntiHedge       = true;    // Anti-hedge (same symbol, any magic)
input int               InpPF_HeartbeatMin    = 5;       // Stale registry after N min

//+------------------------------------------------------------------+
//| CLASS CPortfolioRisk                                              |
//+------------------------------------------------------------------+
class CPortfolioRisk
  {
private:
   string   m_prefix;      // "ALX_PF_"
   string   m_ea_name;
   ulong    m_magic;
   string   m_symbol;
   bool     m_active;

   string   KeyHB(void)           const { return m_prefix + IntegerToString(m_magic) + "_hb"; }
   double   OwnLots(void);
   double   CurrencyLots(string currency);
   bool     HasOppositePosition(const ENUM_POSITION_TYPE type);
   void     CleanupStaleRegistry(void);

public:
            CPortfolioRisk() : m_prefix("ALX_PF_"), m_ea_name(""), m_magic(0),
                               m_symbol(""), m_active(false) {}
   //--- ciclo de vida
   bool     Init(const string ea_name, const ulong magic, const string symbol);
   void     Heartbeat(void);            // chamar no OnTimer
   void     Deinit(void);
   //--- consultas / gate de entrada
   int      GetActiveEAs(void);         // instancias vivas no registry
   bool     CanOpen(const ENUM_POSITION_TYPE type, const double lot);
  };

//+------------------------------------------------------------------+
//| Init - registra a instancia e seta o heartbeat                   |
//+------------------------------------------------------------------+
bool CPortfolioRisk::Init(const string ea_name, const ulong magic, const string symbol)
  {
   m_active = InpPortfolioRisk;
   if(!m_active)
      return(false);

   m_ea_name = ea_name;
   m_magic   = magic;
   m_symbol  = symbol;

   CleanupStaleRegistry();
   GlobalVariableSet(KeyHB(), (double)TimeCurrent());

   PrintFormat("[PortfolioRisk] init | ea=%s magic=%I64u symbol=%s | ativos=%d",
               m_ea_name, m_magic, m_symbol, GetActiveEAs());
   return(true);
  }
//+------------------------------------------------------------------+
//| Heartbeat - renova o registro (OnTimer) + limpeza de mortos      |
//+------------------------------------------------------------------+
void CPortfolioRisk::Heartbeat(void)
  {
   if(!m_active) return;
   GlobalVariableSet(KeyHB(), (double)TimeCurrent());
   CleanupStaleRegistry();
  }
//+------------------------------------------------------------------+
//| Deinit - remove o registro da instancia                          |
//+------------------------------------------------------------------+
void CPortfolioRisk::Deinit(void)
  {
   if(!m_active) return;
   GlobalVariableDel(KeyHB());
   m_active = false;
  }
//+------------------------------------------------------------------+
//| GetActiveEAs - conta instancias com heartbeat dentro da janela   |
//+------------------------------------------------------------------+
int CPortfolioRisk::GetActiveEAs(void)
  {
   if(!m_active) return(0);

   datetime now      = TimeCurrent();
   datetime window   = (datetime)(InpPF_HeartbeatMin * 60);
   int      alive    = 0;
   int      total    = GlobalVariablesTotal();

   for(int i = 0; i < total; i++)
     {
      string name = GlobalVariableName(i);
      if(StringFind(name, m_prefix) != 0) continue;
      if(StringFind(name, "_hb") < 0)     continue;

      double val;
      if(!GlobalVariableGet(name, val)) continue;
      if(now - (datetime)val <= window) alive++;
     }
   return(alive);
  }
//+------------------------------------------------------------------+
//| OwnLots - lotes abertos deste EA (magic)                         |
//+------------------------------------------------------------------+
double CPortfolioRisk::OwnLots(void)
  {
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)m_magic)
         lots += PositionGetDouble(POSITION_VOLUME);
     }
   return(lots);
  }
//+------------------------------------------------------------------+
//| CurrencyLots - lotes brutos abertos que expoem a moeda           |
//| (par FX: base+quote; demais: prefixo do ticker)                  |
//+------------------------------------------------------------------+
double CPortfolioRisk::CurrencyLots(string currency)
  {
   StringToUpper(currency);
   double lots = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(StringLen(sym) >= 6)
        {
         string base_c  = StringSubstr(sym, 0, 3);
         string quote_c = StringSubstr(sym, 3, 3);
         if(base_c == currency || quote_c == currency)
            lots += PositionGetDouble(POSITION_VOLUME);
        }
      else if(StringFind(sym, currency) == 0)
         lots += PositionGetDouble(POSITION_VOLUME);
     }
   return(lots);
  }
//+------------------------------------------------------------------+
//| HasOppositePosition - existe posicao oposta no simbolo           |
//| (qualquer magic) => proibicao de hedge                           |
//+------------------------------------------------------------------+
bool CPortfolioRisk::HasOppositePosition(const ENUM_POSITION_TYPE type)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;

      long ptype = PositionGetInteger(POSITION_TYPE);
      if((type == POSITION_TYPE_BUY  && ptype == POSITION_TYPE_SELL) ||
         (type == POSITION_TYPE_SELL && ptype == POSITION_TYPE_BUY))
         return(true);
     }
   return(false);
  }
//+------------------------------------------------------------------+
//| CleanupStaleRegistry - remove registros mortos (>24h)            |
//+------------------------------------------------------------------+
void CPortfolioRisk::CleanupStaleRegistry(void)
  {
   datetime now    = TimeCurrent();
   datetime cutoff = now - 24 * 3600;

   int total = GlobalVariablesTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      string name = GlobalVariableName(i);
      if(StringFind(name, m_prefix) != 0) continue;
      if(StringFind(name, "_hb") < 0)     continue;

      double val;
      if(GlobalVariableGet(name, val) && (datetime)val < cutoff)
         GlobalVariableDel(name);
     }
  }
//+------------------------------------------------------------------+
//| CanOpen - gate unico de entrada (anti-hedge + moeda + share)     |
//+------------------------------------------------------------------+
bool CPortfolioRisk::CanOpen(const ENUM_POSITION_TYPE type, const double lot)
  {
   if(!m_active) return(true);

   //--- 1. Anti-hedge (mesmo simbolo, qualquer EA)
   if(InpPF_AntiHedge && HasOppositePosition(type))
     {
      PrintFormat("[PortfolioRisk] BLOCK anti-hedge: %s %s | posicao oposta existente",
                  m_symbol, (type == POSITION_TYPE_BUY) ? "BUY" : "SELL");
      return(false);
     }

   //--- 2. Exposicao por moeda (gross lots)
   if(InpPF_MaxLotsCurrency > 0.0 && StringLen(m_symbol) >= 6)
     {
      string base_c  = StringSubstr(m_symbol, 0, 3);
      string quote_c = StringSubstr(m_symbol, 3, 3);
      if(CurrencyLots(base_c) + lot > InpPF_MaxLotsCurrency)
        {
         PrintFormat("[PortfolioRisk] BLOCK exposicao por moeda: %s | base=%s %.2f+%.2f > %.2f",
                     m_symbol, base_c, CurrencyLots(base_c), lot, InpPF_MaxLotsCurrency);
         return(false);
        }
      if(CurrencyLots(quote_c) + lot > InpPF_MaxLotsCurrency)
        {
         PrintFormat("[PortfolioRisk] BLOCK exposicao por moeda: %s | quote=%s %.2f+%.2f > %.2f",
                     m_symbol, quote_c, CurrencyLots(quote_c), lot, InpPF_MaxLotsCurrency);
         return(false);
        }
     }

   //--- 3. Share 1/N do orcamento de lotes do portfolio
   if(InpPF_MaxLotsTotal > 0.0)
     {
      int    alive = GetActiveEAs();
      double share = InpPF_MaxLotsTotal / MathMax(1, alive);
      if(OwnLots() + lot > share)
        {
         PrintFormat("[PortfolioRisk] BLOCK share 1/N: %s | own=%.2f lot=%.2f > share=%.2f (ativos=%d)",
                     m_symbol, OwnLots(), lot, share, alive);
         return(false);
        }
     }

   return(true);
  }

#endif // PORTFOLIO_RISK_MQH
