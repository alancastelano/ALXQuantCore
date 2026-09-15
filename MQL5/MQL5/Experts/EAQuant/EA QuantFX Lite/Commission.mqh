//+------------------------------------------------------------------+
//|                                             Commission.mqh        |
//|                        Simplified for QuantFX Lite                |
//|                        Same logic as CCommission class             |
//+------------------------------------------------------------------+
#property copyright "ALXQuant"
#property version   "1.00"

//+------------------------------------------------------------------+
//| Enum: commission mode                                             |
//+------------------------------------------------------------------+
enum enCommMode
  {
   comm_round_trip = 0,   // Round trip (in+out total)
   comm_out_only   = 1    // Out only (per side, total = 2x)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
//input group                "Commission"
enCommMode           InpCommMode             = comm_round_trip;// Mode
double               InpCommissionUSDperLot  = 7.0;            // Commission/lot (USD, 0=off)
double               InpCommBufferUSDperLot  = 0.05;           // Buffer/lot (USD)

//+------------------------------------------------------------------+
//| Global state                                                     |
//+------------------------------------------------------------------+
bool     g_comm_active       = false;
double   g_comm_cost_per_lot = 0.0;
double   g_comm_dist_price   = 0.0;

//+------------------------------------------------------------------+
//| Measure real commission from deal history (30 days)               |
//+------------------------------------------------------------------+
double CommMeasure(CSymbolInfo *symbol, ulong magic)
  {
   if(!HistorySelect(TimeCurrent() - 30 * 86400, TimeCurrent()))
      return 0.0;

   double totalComm = 0.0;
   double totalVol  = 0.0;
   int    count     = HistoryDealsTotal();

   for(int i = count - 1; i >= 0; i--)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != symbol.Name()) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != (long)magic)   continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;

      double comm = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      double vol  = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      if(vol > 0.0 && comm < 0.0)
        {
         totalComm += -comm;
         totalVol  += vol;
        }
     }

   if(totalVol <= 0.0) return 0.0;
   return totalComm / totalVol;
  }

//+------------------------------------------------------------------+
//| Init commission — call in OnInit()                                |
//+------------------------------------------------------------------+
void CommInit(CSymbolInfo *symbol, ulong magic)
  {
   g_comm_active = (InpCommissionUSDperLot > 0.0);

   if(!g_comm_active)
     {
      g_comm_cost_per_lot = 0.0;
      g_comm_dist_price   = 0.0;
      return;
     }

   //--- measure real commission; fallback to input
   g_comm_cost_per_lot = CommMeasure(symbol, magic);
   if(g_comm_cost_per_lot <= 0.0)
      g_comm_cost_per_lot = InpCommissionUSDperLot;

   //--- mode: out_only = 2x (both sides)
   if(InpCommMode == comm_out_only)
      g_comm_cost_per_lot *= 2.0;

   //--- buffer
   g_comm_cost_per_lot += InpCommBufferUSDperLot;

   //--- dist price (for price-based checks)
   if(symbol != NULL)
     {
      double tickSize = symbol.TickSize();
      double tickVal  = symbol.TickValue();
      if(tickSize > 0.0 && tickVal > 0.0)
         g_comm_dist_price = g_comm_cost_per_lot * tickSize / tickVal;
      else
         g_comm_dist_price = g_comm_cost_per_lot * symbol.Point() * 10.0;
     }
  }

//+------------------------------------------------------------------+
//| TotalCommission — total cost for X lots                          |
//+------------------------------------------------------------------+
double CommTotalCommission(double lots)
  {
   if(!g_comm_active || lots <= 0.0) return 0.0;
   return lots * g_comm_cost_per_lot;
  }

//+------------------------------------------------------------------+
//| NetProfit — gross minus commission                               |
//+------------------------------------------------------------------+
double CommNetProfit(double gross, double lots)
  {
   if(!g_comm_active) return gross;
   return gross - CommTotalCommission(lots);
  }

//+------------------------------------------------------------------+
//| IsActive                                                         |
//+------------------------------------------------------------------+
bool CommIsActive()
  {
   return g_comm_active;
  }
//+------------------------------------------------------------------+
