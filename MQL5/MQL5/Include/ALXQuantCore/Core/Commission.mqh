//+------------------------------------------------------------------+
//|                                                 Commission.mqh   |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//|                       Comissão por lote — classe extraída         |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      ""
#property version   "1.00"

//+------------------------------------------------------------------+
//| Enum: modo de comissão                                            |
//+------------------------------------------------------------------+
enum enCommMode
  {
   comm_round_trip = 0,   // Round trip (in+out total, e.g. $7/lot total)
   comm_out_only   = 1    // Out only (per side, e.g. $3.50 per side)
  };

//+------------------------------------------------------------------+
//| #Inputs                                                          |
//+------------------------------------------------------------------+
input group                "➜ Commission"
input enCommMode           InpCommMode             = comm_round_trip;// Commission mode
input double               InpCommissionUSDperLot  = 7.0;            // Commission per lot (USD, 0=off)
input double               InpCommBufferUSDperLot  = 0.05;           // Extra buffer per lot (USD)
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Classe CCommission                                                |
//|   - Mede comissão real via DEAL_COMMISSION (histórico 30 dias)    |
//|   - Fornece custo por lote, distância em preço, total, net       |
//+------------------------------------------------------------------+
class CCommission
  {
private:
   CSymbolInfo   *m_symbol;        // ponteiro para o símbolo (injetado)
   ulong          m_magic;         // magic number
   enCommMode     m_mode;          // round_trip / out_only

   //--- state calculado no Init
   bool           m_active;        // false se input==0
   double         m_cost_per_lot;  // $/lot final (medido+buffer, ajustado pelo mode)
   double         m_dist_price;    // distância em preço que cobre comissão+buffer
   double         m_buffer;        // buffer $/lot salvo

   //--- mede comissão real do broker (varre DEAL_COMMISSION)
   double MeasureCommissionPerLot()
     {
      if(!HistorySelect(TimeCurrent()-30*86400, TimeCurrent()))
         return 0.0;

      double totalComm = 0.0;
      double totalVol  = 0.0;
      int    count     = HistoryDealsTotal();

      for(int i = count-1; i >= 0; i--)
        {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0) continue;

         if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != m_symbol.Name()) continue;
         if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != (long)m_magic)  continue;
         if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_IN)  continue;

         double comm = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         double vol  = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
         if(vol > 0.0 && comm < 0.0)
           {
            totalComm += -comm;   // valor absoluto
            totalVol  += vol;
           }
        }

      if(totalVol <= 0.0) return 0.0;
      return totalComm / totalVol;   // $/lot round-trip real
     }

public:
                     CCommission();
                    ~CCommission();

   //--- Inicializa: recebe símbolo, magic, mode e inputs do EA
   bool               Init(CSymbolInfo *symbol, ulong magic);

   //--- Getters
   bool               IsActive()    const { return m_active; }
   double             CostPerLot()  const { return m_cost_per_lot; }
   double             DistPrice()   const { return m_dist_price; }

   //--- Cálculos
   double             TotalCommission(double lots) const;
   double             NetProfit(double gross, double lots) const;
  };

//+------------------------------------------------------------------+
//| Construtor                                                        |
//+------------------------------------------------------------------+
CCommission::CCommission()
  {
   m_symbol       = NULL;
   m_magic        = 0;
   m_mode         = comm_round_trip;
   m_active       = false;
   m_cost_per_lot = 0.0;
   m_dist_price   = 0.0;
   m_buffer       = 0.0;
  }

//+------------------------------------------------------------------+
//| Destrutor                                                         |
//+------------------------------------------------------------------+
CCommission::~CCommission()
  {
  }

//+------------------------------------------------------------------+
//| Init — recebe inputs do EA + símbolo + magic                     |
//+------------------------------------------------------------------+
bool CCommission::Init(CSymbolInfo *symbol, ulong magic)
  {
   m_symbol = symbol;
   m_magic  = magic;
   m_mode   = InpCommMode;
   m_buffer = InpCommBufferUSDperLot;

   m_active = (InpCommissionUSDperLot > 0.0);

   if(!m_active)
     {
      m_cost_per_lot = 0.0;
      m_dist_price   = 0.0;
      //Print("[COMMISSION] Desativada (input=0)");
      return(true);
     }

   //--- mede comissão real; fallback para input
   m_cost_per_lot = MeasureCommissionPerLot();
   if(m_cost_per_lot <= 0.0) { m_cost_per_lot = InpCommissionUSDperLot; }

   //--- ajusta pelo modo: out_only = por lado (custo total = 2× input)
   if(m_mode == comm_out_only)
      m_cost_per_lot *= 2.0;

   //--- adiciona buffer
   m_cost_per_lot += m_buffer;

   //--- converte para distância em preço (lot-independente)
   if(m_symbol != NULL)
     {
      double tickSize = m_symbol.TickSize();
      double tickVal  = m_symbol.TickValue();
      if(tickSize > 0.0 && tickVal > 0.0)
         m_dist_price = m_cost_per_lot * tickSize / tickVal;
      else
         m_dist_price = m_cost_per_lot * m_symbol.Point() * 10.0;  // fallback
     }
   else
      m_dist_price = 0.0;

   //Print("[COMMISSION] Ativa: mode=", (m_mode == comm_round_trip ? "RoundTrip" : "OutOnly"),
   //      " cost=$", DoubleToString(m_cost_per_lot, 2), "/lot",
   //      " dist=", DoubleToString(m_dist_price, (m_symbol != NULL ? m_symbol.Digits() : 5)));

   return(true);
  }

//+------------------------------------------------------------------+
//| TotalCommission — custo total para X lots                         |
//+------------------------------------------------------------------+
double CCommission::TotalCommission(double lots) const
  {
   if(!m_active || lots <= 0.0) return 0.0;
   return lots * m_cost_per_lot;
  }

//+------------------------------------------------------------------+
//| NetProfit — lucro líquido = gross - comissão                      |
//+------------------------------------------------------------------+
double CCommission::NetProfit(double gross, double lots) const
  {
   if(!m_active) return gross;
   return gross - TotalCommission(lots);
  }
//+------------------------------------------------------------------+
