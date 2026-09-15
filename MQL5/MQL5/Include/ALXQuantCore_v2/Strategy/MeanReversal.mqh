//+------------------------------------------------------------------+
//|                                             MeanReversal.mqh     |
//|                                 Copyright 2026, ALXQuantCore Ltd.|
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore Ltd."
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
    v.7.13 - 2026-08-02 - Fix: Init(symbol, magic, dist) inicializa m_symbol
                           (Name/Refresh/RefreshRates) e m_magic — sem isso
                           iOpen/iClose usavam símbolo vazio e SignalInitial()
                           nunca retornava sinal. SetExpertMagicNumber no CTrade.
    v.7.14 - 2026-08-02 - Fix: SignalInitial() comparava com as linhas trocadas
                           (BUY na linha superior / SELL na inferior). Agora usa
                           sell_line p/ BUY e buy_line p/ SELL, como o GoldRush
                           Pro original. UpdateLines() vira "chase" (±dist, sem
                           cruzamento), fiel ao EA de origem.
    v.7.15 - 2026-08-02 - Fix: cor do candle passou a usar a ULTIMA VELA FECHADA
                           (barra 1). O EA avalia o sinal so no open de barra
                           (open0==close0 na barra em formacao), entao a condicao
                           de cor nunca era verdadeira e o sinal retornava 0
                           sempre.
*/
//+------------------------------------------------------------------+
class CMeanReversion
{
private:
   //--- Parâmetros Agrupados
   struct SGoldRushParams
   {
      double   dist;            // Distância inicial das linhas (Pips)
      double   min_profit;      // Alvo de lucro da cesta ($)
   };
   SGoldRushParams m_params;
   
     //---
   CPositionInfo  m_position; 
   CTrade         m_trade;    
   CSymbolInfo    m_symbol;   
   //---
  
   //--- Estado Interno 
   struct SGoldRushState
   {
      double   buy_line_price;
      double   sell_line_price;
   };
   SGoldRushState m_state;

   ulong           m_magic;

   //--- Métodos Internos
   void   UpdateLines();
   //bool   CheckIndicators(); // Retorna true se filtro ATR está OK
   double PipToPrice(double pips);
   int    CountPositions(ENUM_POSITION_TYPE type);
   double GetHighestPrice(ENUM_POSITION_TYPE type);
   double GetLowestPrice(ENUM_POSITION_TYPE type);

public:
            CMeanReversion() { ZeroMemory(m_state); ZeroMemory(m_params); }
           ~CMeanReversion() 
           { 
              ObjectDelete(0, "GR_LineBuy");
              ObjectDelete(0, "GR_LineSell");
           }
           
   bool Init(string symbol, ulong magic, double dist,double min_profit);
   void OnTickState(); // Para atualizar linhas e estado visual
            
   //--- Sinais de Entrada
   uchar SignalInitial(); // Retorna 0=Nada, 1=Buy, 2=Sell
   //uchar SignalGrid();    // Retorna 0=Nada, 1=Buy, 2=Sell
   
   //--- Regras de Saída
   bool ShouldCloseBasket(); // Retorna true se atingiu o MinProfit
};
//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
bool CMeanReversion::Init(string symbol, ulong magic, double dist,double min_profit)
{
   if(!InpStrategy_meal_reversal)
      return(true);

   if(!m_symbol.Name(symbol)) return false;
   if(!m_symbol.Refresh()) return false;
   if(!m_symbol.RefreshRates()) return false;

   m_magic = magic;
   m_trade.SetExpertMagicNumber(m_magic);
   m_params.dist        = dist;
   m_params.min_profit  = min_profit;

   m_state.buy_line_price  = m_symbol.Ask() + PipToPrice(m_params.dist);
   m_state.sell_line_price = m_symbol.Bid() - PipToPrice(m_params.dist);
   
   ObjectCreate(0, "GR_LineBuy", OBJ_HLINE, 0, 0, m_state.buy_line_price);
   ObjectSetInteger(0, "GR_LineBuy", OBJPROP_COLOR, clrRed);
   
   ObjectCreate(0, "GR_LineSell", OBJ_HLINE, 0, 0, m_state.sell_line_price);
   ObjectSetInteger(0, "GR_LineSell", OBJPROP_COLOR, clrBlue);
   
   return true;
}

//+------------------------------------------------------------------+
//| Atualização de Estado (Chamar no OnTick antes dos sinais)        |
//+------------------------------------------------------------------+
void CMeanReversion::OnTickState()
{
   if(!m_symbol.RefreshRates()) return;
   UpdateLines();
}

//+------------------------------------------------------------------+
//| ATUALIZAÇÃO DAS LINHAS (Chase — GoldRush Pro)                   |
//+------------------------------------------------------------------+
// As linhas perseguem o preço: LineBuy segue Ask+dist e LineSell segue
// Bid-dist, impedidas de cruzar entre si (mesmo comportamento do EA
// original "Buy & Sell Rotating").
void CMeanReversion::UpdateLines()
{
   double ask  = m_symbol.Ask();
   double bid  = m_symbol.Bid();
   double dist = PipToPrice(m_params.dist);

   if((ask + dist) < m_state.buy_line_price)
      m_state.buy_line_price = ask + dist;

   if((bid - dist) > m_state.sell_line_price)
      m_state.sell_line_price = bid - dist;

   if(ask < m_state.sell_line_price && (bid - dist) > m_state.buy_line_price)
      m_state.buy_line_price = ask + dist;

   if(bid > m_state.buy_line_price && (ask + dist) < m_state.sell_line_price)
      m_state.sell_line_price = bid - dist;

   ObjectSetDouble(0, "GR_LineBuy", OBJPROP_PRICE, m_state.buy_line_price);
   ObjectSetDouble(0, "GR_LineSell", OBJPROP_PRICE, m_state.sell_line_price);
}

//+------------------------------------------------------------------+
//| SINAL INICIAL (Primeira Ordem)                                   |
//+------------------------------------------------------------------+
uchar CMeanReversion::SignalInitial()
{
   if(!InpStrategy_meal_reversal)
      return(0);

   if(CountPositions(POSITION_TYPE_BUY) > 0 || CountPositions(POSITION_TYPE_SELL) > 0) return 0;

   // Usa a ultima vela FECHADA (barra 1): o EA avalia o sinal apenas no
   // open de cada barra, quando open0==close0 da barra em formacao.
   double open0  = iOpen(m_symbol.Name(), PERIOD_CURRENT, 1);
   double close0 = iClose(m_symbol.Name(), PERIOD_CURRENT, 1);
   
   // Compra: Candle Vermelho + Preço tocou a Linha Sell (inferior)
   if(open0 > close0 && m_symbol.Ask() <= m_state.sell_line_price)
      return 1;
   
   // Venda: Candle Verde + Preço tocou a Linha Buy (superior)
   if(open0 < close0 && m_symbol.Bid() >= m_state.buy_line_price)
      return 2;
   
   return 0;
}

//+------------------------------------------------------------------+
//| REGRA DE SAÍDA: Checa se a cesta atingiu o alvo                  |
//+------------------------------------------------------------------+
bool CMeanReversion::ShouldCloseBasket()
{
   double total_profit = 0;
   int total_positions = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      
      if(PositionGetInteger(POSITION_MAGIC) == (long)m_magic && PositionGetString(POSITION_SYMBOL) == m_symbol.Name())
      {
         total_profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         total_positions++;
      }
   }
   
   return (total_positions > 0 && total_profit >= m_params.min_profit);
}

//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+
double CMeanReversion::PipToPrice(double pips)
{
   int digits = (int)m_symbol.Digits();
   double point = m_symbol.Point();
   return (digits == 3 || digits == 5) ? pips * 10.0 * point : pips * point;
}

int CMeanReversion::CountPositions(ENUM_POSITION_TYPE type)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)m_magic && PositionGetString(POSITION_SYMBOL) == m_symbol.Name())
      {
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type) count++;
      }
   }
   return count;
}

double CMeanReversion::GetHighestPrice(ENUM_POSITION_TYPE type)
{
   double highest = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)m_magic && PositionGetString(POSITION_SYMBOL) == m_symbol.Name())
      {
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         {
            double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            if(open_price > highest) highest = open_price;
         }
      }
   }
   return highest;
}

double CMeanReversion::GetLowestPrice(ENUM_POSITION_TYPE type)
{
   double lowest = 999999;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)m_magic && PositionGetString(POSITION_SYMBOL) == m_symbol.Name())
      {
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         {
            double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            if(open_price < lowest) lowest = open_price;
         }
      }
   }
   return lowest;
}