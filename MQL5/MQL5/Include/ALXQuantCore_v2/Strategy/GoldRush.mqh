//+------------------------------------------------------------------+
//|                                                      GoldRush.mqh|
//|                                Copyright 2026, ALXQuantCore Ltd. |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore Ltd."
#property version   "5.10"

//+------------------------------------------------------------------+
//| #Inputs                                                          |
//+------------------------------------------------------------------+
input group "== Gold Rush Strategy =="
input bool     InpGR_On         = true;     // Distância das Linhas (Pips)
input double   InpGR_Weight     = 100.0;   // Peso do Lote (%)
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Classe CGoldRush (Apenas Sinais e Regras de Saída)               |
//+------------------------------------------------------------------+
class CGoldRush
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
            CGoldRush() { ZeroMemory(m_state); ZeroMemory(m_params); }
           ~CGoldRush() 
           { 
              ObjectDelete(0, "GR_LineBuy");
              ObjectDelete(0, "GR_LineSell");
           }
           
   bool Init(void);
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
bool CGoldRush::Init(void)
{
   if(!InpGR_On)
      return(true);

   if(!m_symbol.RefreshRates()) return false;
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
void CGoldRush::OnTickState()
{
   if(!m_symbol.RefreshRates()) return;
   UpdateLines();
}

//+------------------------------------------------------------------+
//| ATUALIZAÇÃO DAS LINHAS (Trailing Outward)                       |
//+------------------------------------------------------------------+
// Substitua o seu UpdateLines por esta lógica:
void CGoldRush::UpdateLines()
{
   double ask = m_symbol.Ask();
   double bid = m_symbol.Bid();
   
   // A linha de compra deve ser "A MÁXIMA alcançada MENOS a distância"
   double new_high_anchor = ask - PipToPrice(m_params.dist); 
   if(new_high_anchor > m_state.buy_line_price || m_state.buy_line_price == 0)
   {
      m_state.buy_line_price = new_high_anchor;
      ObjectSetDouble(0, "GR_LineBuy", OBJPROP_PRICE, m_state.buy_line_price);
   }
   
   // A linha de venda deve ser "A MÍNIMA alcançada MAIS a distância"
   double new_low_anchor = bid + PipToPrice(m_params.dist);
   if(new_low_anchor < m_state.sell_line_price || m_state.sell_line_price == 0)
   {
      m_state.sell_line_price = new_low_anchor;
      ObjectSetDouble(0, "GR_LineSell", OBJPROP_PRICE, m_state.sell_line_price);
   }
}

//+------------------------------------------------------------------+
//| SINAL INICIAL (Primeira Ordem)                                   |
//+------------------------------------------------------------------+
uchar CGoldRush::SignalInitial()
{
   if(!InpGR_On)
      return(0);

   if(CountPositions(POSITION_TYPE_BUY) > 0 || CountPositions(POSITION_TYPE_SELL) > 0) return 0;

   double open0  = iOpen(m_symbol.Name(), PERIOD_CURRENT, 0);
   double close0 = iClose(m_symbol.Name(), PERIOD_CURRENT, 0);
   
   // Compra: Candle Vermelho + Preço caiu até a Linha Buy
   if(open0 > close0 && m_symbol.Ask() <= m_state.buy_line_price)
      return 1;
   
   // Venda: Candle Verde + Preço subiu até a Linha Sell
   if(open0 < close0 && m_symbol.Bid() >= m_state.sell_line_price)
      return 2;
   
   return 0;
}

//+------------------------------------------------------------------+
//| REGRA DE SAÍDA: Checa se a cesta atingiu o alvo                  |
//+------------------------------------------------------------------+
bool CGoldRush::ShouldCloseBasket()
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
double CGoldRush::PipToPrice(double pips)
{
   int digits = (int)m_symbol.Digits();
   double point = m_symbol.Point();
   return (digits == 3 || digits == 5) ? pips * 10.0 * point : pips * point;
}

int CGoldRush::CountPositions(ENUM_POSITION_TYPE type)
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

double CGoldRush::GetHighestPrice(ENUM_POSITION_TYPE type)
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

double CGoldRush::GetLowestPrice(ENUM_POSITION_TYPE type)
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