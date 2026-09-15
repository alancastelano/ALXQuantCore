//+------------------------------------------------------------------+
//|                                              SessionBreakout.mqh |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
*/

input group    "== 15. Strategy#6 - Session Breakout =="
bool     InpStrategy_Session           = true;           // [Session] On/Off
input ulong    InpStrategy_Session_magic     = 0;              // [Session] Magic ID
input double   InpStrategy_Session_weight    = 75.0;           // [Session] Weight lot
input string   InpStrategy_Session_comm      = "Session#6";    // [Session] Comment

input bool     InpStrategy_Session_MidnNight = true;           // [Session] ICT MidiNight Open
input bool     InpStrategy_Session_vwap      = true;           // [Session] VWAP
input int      InpStrategy_Session_StartHour = 6;              // [Session] Time start session (London)
input int      InpStrategy_Session_EndHour   = 12;             // [Session] Time breakout (NY)

input group    "== 15.1 Trade Management ==="
input double   InpStrategy_Session_be        = 120;            // [Breakout] Break-even Trigger (points)
input double   InpStrategy_Session_distance  = 80.0;           // [Trailing] Distance (points)
input double   InpStrategy_Session_step      = 60.0;           // [Trailing] Step (points)


class CSessionBreakout
{
private:
   struct SBreakoutParams
   {
      bool     session;
      ulong    magic;
      double   lot_weight;          
      string   comm;                
      bool     MidnNight;
      bool     vwap;
      int      StartHour;           
      int      EndHour;             
      double   treilling_be;        
      double   treilling_distance;  
      double   treilling_step;      
   };
   SBreakoutParams m_params;
   
   // --- State Machine ---
   datetime m_lastDayTraded;      
   double   m_sessionHigh;        
   double   m_sessionLow;        
   bool     m_rangeLocked; 
   bool     m_signalFiredToday; // <--- NOVO: Impede spam de sinais no mesmo dia     
   
   CSymbolInfo    m_symbol;   
   
   void     UpdateSessionRange();
   bool     IsContextBullish();
   bool     IsContextBearish();
   
   bool     IsUS_DaylightSavings(datetime time);
   double   GetNYMidnightOpenPrice();
   double   GetEngineVWAP();

public:
   CSessionBreakout();
  ~CSessionBreakout();

   bool     Init(string symbol);  
   uchar    SignalSessionBreakout(double &out_sl);
   void     ManageOpenPositions();
};

//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CSessionBreakout::CSessionBreakout()
{
   ZeroMemory(m_params);
   m_params.session      = InpStrategy_Session;  
   m_params.magic        = InpStrategy_Session_magic;
   m_params.lot_weight   = InpStrategy_Session_weight;         
   m_params.comm         = InpStrategy_Session_comm;           
   m_params.MidnNight    = InpStrategy_Session_MidnNight;
   m_params.vwap         = InpStrategy_Session_vwap;
   m_params.StartHour    = InpStrategy_Session_StartHour;      
   m_params.EndHour      = InpStrategy_Session_EndHour;        
   m_params.treilling_be       = InpStrategy_Session_be;       
   m_params.treilling_distance = InpStrategy_Session_distance; 
   m_params.treilling_step     = InpStrategy_Session_step;     
   
   m_lastDayTraded = 0;
   m_sessionHigh   = 0;
   m_sessionLow    = 0;
   m_rangeLocked   = false;
   m_signalFiredToday = false; // Inicializa
}

CSessionBreakout::~CSessionBreakout() {}

bool CSessionBreakout::Init(string symbol)
{
   if(!m_symbol.Name(symbol)) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Motor Principal do Sinal                                         |
//+------------------------------------------------------------------+
uchar CSessionBreakout::SignalSessionBreakout(double &out_sl)
{
   if(!m_params.session) return 0;
   if(!m_symbol.RefreshRates() || !m_symbol.Refresh()) return 0;

   MqlDateTime tm;
   TimeCurrent(tm);
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));

   // 1. Reset diário (Meia-noite)
   if(today != m_lastDayTraded)
   {
      m_rangeLocked = false;
      m_sessionHigh = 0;
      m_sessionLow  = 0;
      m_signalFiredToday = false; // Libera o sinal para o novo dia
      m_lastDayTraded = today;
   }

   // 2. Atualiza o Range enquanto a sessão não acabou
   if(tm.hour < m_params.EndHour)
   {
      UpdateSessionRange();
   }
   else if(!m_rangeLocked)
   {
      m_rangeLocked = true;
      if(m_sessionHigh == 0) UpdateSessionRange(); 
   }

   // 3. BLOQUEIA se já atirou o sinal hoje ou se o range não travou
   if(!m_rangeLocked || m_signalFiredToday) return 0;

   double ask = m_symbol.Ask();
   double bid = m_symbol.Bid();

   // 4. Lógica de Rompimento a Mercado
   if(ask > m_sessionHigh && IsContextBullish())
   {
      out_sl = m_sessionLow;           // SL na mínima do range
      m_signalFiredToday = true;       // TRAVA O SINAL PARA O RESTO DO DIA
      return 1; // Compra a Mercado
   }
   else if(bid < m_sessionLow && IsContextBearish())
   {
      out_sl = m_sessionHigh;          // SL na máxima do range
      m_signalFiredToday = true;       // TRAVA O SINAL PARA O RESTO DO DIA
      return 2; // Venda a Mercado
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Atualiza o Range em Tempo Real                                   |
//+------------------------------------------------------------------+
void CSessionBreakout::UpdateSessionRange()
{
   MqlDateTime tm;
   TimeCurrent(tm);

   if(tm.hour < m_params.StartHour || tm.hour >= m_params.EndHour) return;

   double currentHigh = m_symbol.Bid();
   double currentLow  = m_symbol.Ask();

   if(m_sessionHigh == 0) 
   {
      m_sessionHigh = currentHigh;
      m_sessionLow  = currentLow;
   }

   if(currentHigh > m_sessionHigh) m_sessionHigh = currentHigh;
   if(currentLow  < m_sessionLow)  m_sessionLow  = currentLow;
}

//+------------------------------------------------------------------+
//| Filtros de Contexto (Agora com fallback seguro)                  |
//+------------------------------------------------------------------+
bool CSessionBreakout::IsContextBullish()
{
   if(!m_params.MidnNight && !m_params.vwap) return true;
   
   double midnightOpen = m_params.MidnNight ? GetNYMidnightOpenPrice() : 0;
   double vwapVal      = m_params.vwap      ? GetEngineVWAP() : 0;
      
   // Se o filtro falhar (retornar 0), ele não bloqueia o trade
   if(m_params.MidnNight && midnightOpen > 0 && m_symbol.Ask() < midnightOpen) return false;
   if(m_params.vwap      && vwapVal > 0      && m_symbol.Ask() < vwapVal)      return false;
   
   return true;
}

bool CSessionBreakout::IsContextBearish()
{
   if(!m_params.MidnNight && !m_params.vwap) return true;
   
   double midnightOpen = m_params.MidnNight ? GetNYMidnightOpenPrice() : 0;
   double vwapVal      = m_params.vwap      ? GetEngineVWAP() : 0;
      
   if(m_params.MidnNight && midnightOpen > 0 && m_symbol.Bid() > midnightOpen) return false;
   if(m_params.vwap      && vwapVal > 0      && m_symbol.Bid() > vwapVal)      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Gerenciamento de Posição (Trailing e BE)                         |
//+------------------------------------------------------------------+
void CSessionBreakout::ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != m_symbol.Name() || 
         PositionGetInteger(POSITION_MAGIC) != m_params.magic) continue;

      double openPrice   = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL   = PositionGetDouble(POSITION_SL);
      double currentTP   = PositionGetDouble(POSITION_TP);
      long   posType     = PositionGetInteger(POSITION_TYPE);
      
      double point = m_symbol.Point();
      double bid   = m_symbol.Bid();
      double ask   = m_symbol.Ask();
      
      CTrade trade;
      trade.SetExpertMagicNumber(m_params.magic);

      if(posType == POSITION_TYPE_BUY)
      {
         if(m_params.treilling_be > 0 && currentSL < openPrice)
         {
            if(bid >= openPrice + (m_params.treilling_be * point))
            {
               double newSL = openPrice + (10 * point); 
               trade.PositionModify(ticket, newSL, currentTP);
               continue; 
            }
         }
         else if(currentSL >= openPrice && m_params.treilling_distance > 0 && m_params.treilling_step > 0)
         {
            double desiredSL = bid - (m_params.treilling_distance * point);
            if(desiredSL > currentSL + (m_params.treilling_step * point))
            {
               trade.PositionModify(ticket, desiredSL, currentTP);
               continue;
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         if(m_params.treilling_be > 0 && (currentSL > openPrice || currentSL == 0))
         {
            if(ask <= openPrice - (m_params.treilling_be * point))
            {
               double newSL = openPrice - (10 * point);
               trade.PositionModify(ticket, newSL, currentTP);
               continue;
            }
         }
         else if((currentSL <= openPrice && currentSL > 0) && m_params.treilling_distance > 0 && m_params.treilling_step > 0)
         {
            double desiredSL = ask + (m_params.treilling_distance * point);
            if(desiredSL < currentSL - (m_params.treilling_step * point))
            {
               trade.PositionModify(ticket, desiredSL, currentTP);
               continue;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Cálculos VWAP e Midnight Open                                    |
//+------------------------------------------------------------------+
bool CSessionBreakout::IsUS_DaylightSavings(datetime time)
{
   MqlDateTime tm;
   TimeToStruct(time, tm);
   if(tm.mon < 3 || tm.mon > 11) return(false);
   if(tm.mon > 3 && tm.mon < 11) return(true);
   
   datetime march1 = StringToTime(IntegerToString(tm.year)+".03.01 00:00");
   MqlDateTime t_m1; TimeToStruct(march1, t_m1);
   int first_su_march = (7 - t_m1.day_of_week) % 7 + 1;
   int second_su_march = first_su_march + 7;
   
   datetime nov1 = StringToTime(IntegerToString(tm.year)+".11.01 00:00");
   MqlDateTime t_n1; TimeToStruct(nov1, t_n1);
   int first_su_nov = (7 - t_n1.day_of_week) % 7 + 1;
   
   if(tm.mon == 3) return(tm.day >= second_su_march);
   if(tm.mon == 11) return(tm.day < first_su_nov);
   return(false);
}

double CSessionBreakout::GetNYMidnightOpenPrice()
{
   datetime serverTime = TimeCurrent();
   datetime gmtTime    = TimeGMT();
   int brokerOffsetSeconds = (int)(serverTime - gmtTime);
   int nyOffsetHours = IsUS_DaylightSavings(serverTime) ? -4 : -5;
   int nyOffsetSeconds = nyOffsetHours * 3600;
   
   MqlDateTime tm_now;
   TimeToStruct(serverTime, tm_now);
   datetime nyMidnightLocal = StringToTime(StringFormat("%04d.%02d.%02d 00:00:00", tm_now.year, tm_now.mon, tm_now.day));
   
   datetime nyMidnightInBroker = (nyMidnightLocal - nyOffsetSeconds) + brokerOffsetSeconds;
   if(nyMidnightInBroker > serverTime) nyMidnightInBroker -= 86400;

   int barIndex = iBarShift(m_symbol.Name(), PERIOD_M1, nyMidnightInBroker, false);
   if(barIndex < 0) return(0.0);
   
   return iOpen(m_symbol.Name(), PERIOD_M1, barIndex);
}

double CSessionBreakout::GetEngineVWAP()
{
   datetime dtToday = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   int startBar = iBarShift(m_symbol.Name(), Period(), dtToday, false);
   if(startBar < 0) return(0.0);
   
   MqlRates rates[];
   if(CopyRates(m_symbol.Name(), Period(), 0, startBar + 1, rates) <= 0) return(0.0);
   
   double cumVolumePrice = 0.0;
   double cumVolume      = 0.0;
   
   for(int i = 0; i < ArraySize(rates); i++)
   {
      double typicalPrice = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      long volume = (rates[i].real_volume > 0) ? rates[i].real_volume : rates[i].tick_volume;
      if(volume <= 0) volume = 1;
      
      cumVolumePrice += typicalPrice * volume;
      cumVolume      += volume;
   }
   
   return (cumVolume > 0.0) ? (cumVolumePrice / cumVolume) : 0.0;
}

/*
uchar CSessionBreakout::SignalSessionBreakout(void)
{
   if(!m_symbol.RefreshRates() || !m_symbol.Refresh()) return(0);

   MqlDateTime tm;
   TimeCurrent(tm);

   // Só tenta operar na hora do rompimento (Ex: das 10:00 às 10:59)
   if(tm.hour != InpStrategy_Session_EndHour) return(0);

   // Acha a máxima e mínima do período de formação (Ex: das 07:00 às 09:59)
   double highest = -DBL_MAX;
   double lowest  = DBL_MAX;
   
   // Loop para trás no tempo para achar o range
   for(int i = 1; i <= 60; i++) // Procura até 60 barras M5 para trás
   {
      datetime barTime = iTime(m_symbol.Name(), Period(), i);
      MqlDateTime barTm;
      TimeToStruct(barTime, barTm);
      
      if(barTm.hour >= InpStrategy_Session_StartHour && barTm.hour < InpStrategy_Session_EndHour)
      {
         double h = iHigh(m_symbol.Name(), Period(), i);
         double l = iLow(m_symbol.Name(), Period(), i);
         if(h > highest) highest = h;
         if(l < lowest) lowest = l;
      }
      else if(barTm.hour < InpStrategy_Session_StartHour)
         break; // Parou de ser o horário da sessão, pode parar de procurar
   }

   if(highest == -DBL_MAX || lowest == DBL_MAX) return(0); // Não achou o range

   // Rompeu?
   double bid = m_symbol.Bid();
   double ask = m_symbol.Ask();

   if(ask > highest) return(1); // Compra
   if(bid < lowest) return(2);  // Venda

   return(0);
}
*/