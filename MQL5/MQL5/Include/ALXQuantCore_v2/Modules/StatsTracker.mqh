//+------------------------------------------------------------------+
//| StatsTracker.mqh                                                 |
//| ALXQuantCore - Estatisticas por EA+Symbol (nunca conta global)   |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.20 - 2026-08-20 - Add: modulo de estatisticas por EA+Symbol
                         (ganho diario, posicoes abertas, lotes, DD%,
                         WinRate, Profit Factor, RRR, Expectancy,
                         Z-Score runs test, streaks, maxDD).
                         Escopo sempre: _Symbol + magic do EA.
                         Incremental: varre apenas deals novos a cada
                         Update(); agrupa fechamento por POSITION_ID.
*/

struct AssetStats
{
   double   daily_gain;          // fechados hoje + flutuante (moeda da conta)
   int      open_positions;      // posicoes abertas (symbol+magic)
   double   open_lots;           // volume total aberto (symbol+magic)
   double   daily_dd_pct;        // % queda do pico do dia -> agora
   double   max_dd_pct;          // % max drawdown historico (curva fechada)
   double   cumulative_pnl;      // P/L liquido acumulado (fechados all-time)
};

struct PerfStats
{
   int      closed_trades;       // trades fechados (agrupados por posicao)
   int      wins;
   int      losses;
   double   win_rate;            // %
   double   profit_factor;       // bruto ganho / bruto perda
   double   rrr;                 // avg win / avg loss
   double   expectancy;          // P/L medio por trade
   double   z_score;             // runs test (sequencias W/L)
   int      max_consec_wins;
   int      max_consec_losses;
   double   max_dd;              // max drawdown em moeda da conta
   double   max_dd_pct;
};

class CStatsTracker
{
private:
   string   m_symbol;
   ulong    m_magic;

   datetime m_day_start;
   double   m_day_peak;
   ulong    m_last_deal_ticket;

   struct STrade
   {
      long     pos_id;           // POSITION_IDENTIFIER
      double   net;              // P/L + swap + comissao
      datetime close_time;
   };
   STrade   m_trades[];
   int      m_trade_count;

   AssetStats m_asset;
   PerfStats  m_perf;

   int      FindPosition(long pos_id);
   double   FloatingPnl();
   double   ClosedTodayPnl();
   int      OpenPositions();
   double   OpenLots();
   void     RecomputePerf();
   bool     PositionStillOpen(long pos_id);

public:
   void     Init(string symbol, ulong magic);
   void     Update();
   void     GetAssetStats(AssetStats &as);
   void     GetPerfStats(PerfStats &ps);
};

//+------------------------------------------------------------------+
//| Inicializacao                                                    |
//+------------------------------------------------------------------+
void CStatsTracker::Init(string symbol, ulong magic)
{
   m_symbol          = symbol;
   m_magic           = magic;
   m_day_start       = 0;
   m_day_peak        = 0.0;
   m_last_deal_ticket = 0;
   m_trade_count     = 0;
   ArrayResize(m_trades, 0);
   m_asset.daily_gain      = 0.0;
   m_asset.open_positions  = 0;
   m_asset.open_lots       = 0.0;
   m_asset.daily_dd_pct    = 0.0;
   m_asset.max_dd_pct      = 0.0;
   m_asset.cumulative_pnl  = 0.0;
   m_perf.closed_trades    = 0;
   m_perf.wins             = 0;
   m_perf.losses           = 0;
   m_perf.win_rate         = 0.0;
   m_perf.profit_factor    = 0.0;
   m_perf.rrr              = 0.0;
   m_perf.expectancy       = 0.0;
   m_perf.z_score          = 0.0;
   m_perf.max_consec_wins  = 0;
   m_perf.max_consec_losses = 0;
   m_perf.max_dd           = 0.0;
   m_perf.max_dd_pct       = 0.0;
}

int CStatsTracker::FindPosition(long pos_id)
{
   for(int i = 0; i < m_trade_count; i++)
      if(m_trades[i].pos_id == pos_id)
         return i;
   return -1;
}

bool CStatsTracker::PositionStillOpen(long pos_id)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;
      if(PositionGetInteger(POSITION_IDENTIFIER) == pos_id)
         return true;
   }
   return false;
}

double CStatsTracker::FloatingPnl()
{
   double pnl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;
      pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pnl;
}

int CStatsTracker::OpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;
      count++;
   }
   return count;
}

double CStatsTracker::OpenLots()
{
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != m_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;
      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

double CStatsTracker::ClosedTodayPnl()
{
   double pnl = 0.0;
   if(m_day_start == 0) return 0.0;
   if(!HistorySelect(m_day_start, TimeCurrent())) return 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= 0) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != m_symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)m_magic) continue;
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT || entry == DEAL_ENTRY_OUT_BY)
      {
         pnl += HistoryDealGetDouble(ticket, DEAL_PROFIT)
              + HistoryDealGetDouble(ticket, DEAL_SWAP)
              + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      }
   }
   return pnl;
}

void CStatsTracker::RecomputePerf()
{
   int   wins   = 0;
   int   losses = 0;
   double gross_win  = 0.0;
   double gross_loss = 0.0;
   int   cW = 0, cL = 0, maxW = 0, maxL = 0;
   int   runs = 0, last_sign = 0;
   double cum = 0.0, hwm = 0.0, maxdd = 0.0, maxdd_pct = 0.0;
   int   closed = 0;

   for(int i = 0; i < m_trade_count; i++)
   {
      if(PositionStillOpen(m_trades[i].pos_id)) continue;   // ainda nao finalizado

      double net = m_trades[i].net;
      closed++;
      cum += net;

      int sign = (net > 0.0) ? 1 : -1;
      if(net > 0.0) { wins++; gross_win += net; }
      else          { losses++; gross_loss += MathAbs(net); }

      //--- streaks
      if(sign == 1) { cW++; cL = 0; }
      else          { cL++; cW = 0; }
      if(cW > maxW) maxW = cW;
      if(cL > maxL) maxL = cL;

      //--- runs test
      if(last_sign == 0) runs = 1;
      else if(sign != last_sign) runs++;
      last_sign = sign;

      //--- curva cumulativa (maxDD)
      if(cum > hwm) hwm = cum;
      double dd = hwm - cum;
      if(dd > maxdd) maxdd = dd;
      if(hwm > 0.0)
      {
         double ddp = dd / hwm * 100.0;
         if(ddp > maxdd_pct) maxdd_pct = ddp;
      }
   }

   //--- AssetStats (all-time)
   m_asset.cumulative_pnl = cum;
   m_asset.max_dd_pct     = maxdd_pct;

   //--- PerfStats
   m_perf.closed_trades   = closed;
   m_perf.wins            = wins;
   m_perf.losses          = losses;
   m_perf.win_rate        = (closed > 0) ? (double)wins / closed * 100.0 : 0.0;
   m_perf.profit_factor   = (gross_loss > 0.0) ? gross_win / gross_loss
                          : (gross_win  > 0.0) ? 999.0 : 0.0;
   double avg_win  = (wins   > 0) ? gross_win  / wins   : 0.0;
   double avg_loss = (losses > 0) ? gross_loss / losses : 0.0;
   m_perf.rrr         = (avg_loss > 0.0) ? avg_win / avg_loss : 0.0;
   m_perf.expectancy  = (closed > 0) ? (gross_win - gross_loss) / closed : 0.0;
   m_perf.max_consec_wins   = maxW;
   m_perf.max_consec_losses = maxL;
   m_perf.max_dd      = maxdd;
   m_perf.max_dd_pct  = maxdd_pct;

   //--- Z-Score (runs test de sequencia)
   if(closed >= 3 && wins > 0 && losses > 0)
   {
      double N = closed;
      double W = wins;
      double L = losses;
      double expR  = 1.0 + 2.0 * W * L / N;
      double varR  = 2.0 * W * L * (2.0 * W * L - N) / (N * N * (N - 1.0));
      m_perf.z_score = (varR > 0.0) ? (runs - expR) / MathSqrt(varR) : 0.0;
   }
   else
      m_perf.z_score = 0.0;
}

//+------------------------------------------------------------------+
//| Atualizacao (chamar no OnTimer)                                  |
//+------------------------------------------------------------------+
void CStatsTracker::Update()
{
   //--- rollover diario
   datetime now = TimeCurrent();
   datetime day = now - (now % 86400);
   if(day != m_day_start)
   {
      m_day_start = day;
      m_day_peak  = 0.0;
   }

   //--- processa deals novos (all-time), agrupando por posicao
   if(HistorySelect(0, now))
   {
      int total = HistoryDealsTotal();
      int start_idx = 0;
      bool resume_ok = false;
      if(m_last_deal_ticket > 0)
      {
         for(int i = 0; i < total; i++)
         {
            ulong t = HistoryDealGetTicket(i);
            if(t <= m_last_deal_ticket) { start_idx = i + 1; resume_ok = true; }
            else break;
         }
         if(!resume_ok)   // historico encolheu (limpo) -> rebuild
         {
            m_trade_count = 0;
            ArrayResize(m_trades, 0);
            m_last_deal_ticket = 0;
            start_idx = 0;
         }
      }

      for(int i = start_idx; i < total; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket <= 0) continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != m_symbol) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)m_magic) continue;
         long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY) continue;

         long   pos_id = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
         double net = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                    + HistoryDealGetDouble(ticket, DEAL_SWAP)
                    + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         int idx = FindPosition(pos_id);
         if(idx < 0)
         {
            ArrayResize(m_trades, m_trade_count + 1);
            m_trades[m_trade_count].pos_id     = pos_id;
            m_trades[m_trade_count].net        = net;
            m_trades[m_trade_count].close_time = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
            m_trade_count++;
         }
         else
         {
            m_trades[idx].net        += net;
            m_trades[idx].close_time  = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         }
      }
      if(total > 0)
         m_last_deal_ticket = HistoryDealGetTicket(total - 1);
   }

   //--- asset status (dia)
   double floating   = FloatingPnl();
   double day_closed = ClosedTodayPnl();
   double daily      = day_closed + floating;
   if(daily > m_day_peak) m_day_peak = daily;

   m_asset.daily_gain     = daily;
   m_asset.open_positions = OpenPositions();
   m_asset.open_lots      = OpenLots();
   m_asset.daily_dd_pct   = (m_day_peak > 0.0 && daily < m_day_peak)
                            ? (m_day_peak - daily) / m_day_peak * 100.0 : 0.0;

   //--- performance (all-time)
   RecomputePerf();
}

void CStatsTracker::GetAssetStats(AssetStats &as)
{
   as = m_asset;
}

void CStatsTracker::GetPerfStats(PerfStats &ps)
{
   ps = m_perf;
}