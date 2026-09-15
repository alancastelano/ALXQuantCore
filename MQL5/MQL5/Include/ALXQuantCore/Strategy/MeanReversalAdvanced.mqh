//+------------------------------------------------------------------+
//|                                   MeanReversionAdvanced.mqh      |
//|                        Copyright 2026, ALXQuantCore Ltd.         |
//|                        Baseado nos princípios de Ernest P. Chan  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      "https://www.mql5.com"
#property version "10.0"

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
// Certifique-se de que este arquivo esteja na mesma pasta
//#include "MacroRegimeEngine_v3.mqh" 

//+------------------------------------------------------------------+
//| INPUTS DA ESTRATÉGIA (Configuráveis no EA)                       |
//+------------------------------------------------------------------+
input group   "=== Mean Reversion Advanced (Chan Method) ==="
input bool    InpStrategy_MR_Advanced      = true;   // Ativar Estratégia
input double  InpMR_ZScore_Entry           = 1.8;    // Threshold Z-Score para Entrada (ex: 1.8 desvios)
input double  InpMR_ZScore_Exit            = 0.3;    // Threshold Z-Score para Saída (ex: 0.3 = perto da média)
input int     InpMR_Lookback_Period        = 20;     // Período para cálculo da Média e Desvio (Half-Life aprox.)
input double  InpMR_ATR_Multiplier         = 1.5;    // Multiplicador do ATR para distância dinâmica das linhas
input double  InpMR_Min_Profit_Money       = 10.0;   // Lucro mínimo em dinheiro (Rede de segurança)
input bool    InpMR_Use_Regime_Filter      = true;   // Usar MacroRegimeEngine para bloquear tendências/caos

//+------------------------------------------------------------------+
//| ESTRUTURA DE ESTADO DA ESTRATÉGIA                                |
//+------------------------------------------------------------------+
struct SMR_Advanced_State
{
   double buy_line_price;
   double sell_line_price;
};

//+------------------------------------------------------------------+
//| CLASSE PRINCIPAL                                                 |
//+------------------------------------------------------------------+
class CMeanReversionAdvanced
{
private:
   CSymbolInfo        m_symbol;
   CTrade             m_trade;
   ulong              m_magic;
   SMR_Advanced_State m_state;
   
   // Handles de Indicadores para Z-Score
   int                m_ma_handle;
   int                m_stddev_handle;
   double             m_ma_buffer[];
   double             m_stddev_buffer[];
   
   // Motor de Regime (Instância interna)
   CMacroRegimeEngine m_regime;

   // Helpers
   double            PipToPrice(double pips);
   int               CountPositions(ENUM_POSITION_TYPE type);
   double            GetBasketProfit();

public:
   // Construtor / Destrutor
                     CMeanReversionAdvanced();
                    ~CMeanReversionAdvanced();
   
   // Inicialização
   bool              Init(string symbol, ulong magic);
   void              Deinit();
   
   // Lógica Principal
   uchar             SignalInitial();
   void              UpdateLinesDynamic();
   bool              ShouldCloseBasket();
   
   // Acesso a dados (opcional, para debug no EA)
   double            GetCurrentZScore();
};

//+------------------------------------------------------------------+
//| Construtor e Destrutor                                           |
//+------------------------------------------------------------------+
CMeanReversionAdvanced::CMeanReversionAdvanced()
{
   m_magic = 0;
   m_ma_handle = INVALID_HANDLE;
   m_stddev_handle = INVALID_HANDLE;
   ArraySetAsSeries(m_ma_buffer, true);
   ArraySetAsSeries(m_stddev_buffer, true);
}

CMeanReversionAdvanced::~CMeanReversionAdvanced()
{
   Deinit();
}

//+------------------------------------------------------------------+
//| Inicialização                                                    |
//+------------------------------------------------------------------+
bool CMeanReversionAdvanced::Init(string symbol, ulong magic)
{
   if(!InpStrategy_MR_Advanced) return true;
   
   if(!m_symbol.Name(symbol)) return false;
   if(!m_symbol.RefreshRates()) return false;

   m_magic = magic;
   m_trade.SetExpertMagicNumber(m_magic);
   m_trade.SetDeviationInPoints(10);
   m_trade.SetTypeFilling(ORDER_FILLING_FOK); // Ou IOC, conforme seu broker

   // Inicializar Motor de Regime (Período 50, escalas DFA 4 a 20)
   m_regime.Init(50, 4, 20);
   m_regime.SetProfile(m_regime.DetectAssetProfile(symbol));

   // Criar handles para Z-Score (Média Móvel e Desvio Padrão)
   m_ma_handle = iMA(symbol, PERIOD_CURRENT, InpMR_Lookback_Period, 0, MODE_SMA, PRICE_CLOSE);
   m_stddev_handle = iStdDev(symbol, PERIOD_CURRENT, InpMR_Lookback_Period, 0, MODE_SMA, PRICE_CLOSE);

   if(m_ma_handle == INVALID_HANDLE || m_stddev_handle == INVALID_HANDLE)
   {
      Print("Erro ao criar handles de indicadores no MeanReversionAdvanced");
      return false;
   }

   // Inicializar linhas com preço atual (serão atualizadas dinamicamente no OnTick)
   m_state.buy_line_price  = m_symbol.Ask() + (InpMR_ATR_Multiplier * m_regime.CachedATR(1));
   m_state.sell_line_price = m_symbol.Bid() - (InpMR_ATR_Multiplier * m_regime.CachedATR(1));

   return true;
}

void CMeanReversionAdvanced::Deinit()
{
   if(m_ma_handle != INVALID_HANDLE) IndicatorRelease(m_ma_handle);
   if(m_stddev_handle != INVALID_HANDLE) IndicatorRelease(m_stddev_handle);
}

//+------------------------------------------------------------------+
//| CÁLCULO DO Z-SCORE ATUAL                                         |
//+------------------------------------------------------------------+
double CMeanReversionAdvanced::GetCurrentZScore()
{
   if(CopyBuffer(m_ma_handle, 0, 1, 1, m_ma_buffer) <= 0) return 0.0;
   if(CopyBuffer(m_stddev_handle, 0, 1, 1, m_stddev_buffer) <= 0) return 0.0;

   double current_close = iClose(m_symbol.Name(), PERIOD_CURRENT, 1);
   double mean = m_ma_buffer[0];
   double std_dev = m_stddev_buffer[0];

   if(std_dev == 0.0) return 0.0;
   
   return (current_close - mean) / std_dev;
}

//+------------------------------------------------------------------+
//| SINAL INICIAL (Lógica de Entrada Chan + Regime)                  |
//+------------------------------------------------------------------+
uchar CMeanReversionAdvanced::SignalInitial()
{
   if(!InpStrategy_MR_Advanced) return 0;
   
   // 1. Bloqueio se já houver posição
   if(CountPositions(POSITION_TYPE_BUY) > 0 || CountPositions(POSITION_TYPE_SELL) > 0) return 0;

   // 2. FILTRO DE REGIME (Gatekeeper)
   if(InpMR_Use_Regime_Filter)
   {
      m_regime.Get(1); // Forçar cálculo do DFA/Hurst
      if(m_regime.IsChaosRegime()) return 0; // Mercado tóxico/ilíquido
      if(!m_regime.IsMeanReversionRegime()) return 0; // Mercado em tendência forte, não operar MR
   }

   // 3. CÁLCULO DO Z-SCORE
   double z_score = GetCurrentZScore();
   if(z_score == 0.0) return 0; // Falha ao calcular

   // 4. DADOS DA VELA ANTERIOR
   double open1 = iOpen(m_symbol.Name(), PERIOD_CURRENT, 1);
   double close1 = iClose(m_symbol.Name(), PERIOD_CURRENT, 1);
   double ask = m_symbol.Ask();
   double bid = m_symbol.Bid();

   // 5. LÓGICA DE COMPRA (Z-Score negativo extremo + Vela Vermelha + Preço tocou linha)
   if(z_score < -InpMR_ZScore_Entry && open1 > close1 && ask <= m_state.sell_line_price)
   {
      return 1; // Sinal de COMPRA
   }

   // 6. LÓGICA DE VENDA (Z-Score positivo extremo + Vela Verde + Preço tocou linha)
   if(z_score > InpMR_ZScore_Entry && open1 < close1 && bid >= m_state.buy_line_price)
   {
      return 2; // Sinal de VENDA
   }

   return 0;
}

//+------------------------------------------------------------------+
//| ATUALIZAÇÃO DINÂMICA DAS LINHAS (Substitui distância fixa)       |
//+------------------------------------------------------------------+
void CMeanReversionAdvanced::UpdateLinesDynamic()
{
   if(!InpStrategy_MR_Advanced) return;
   if(!m_symbol.RefreshRates()) return;

   // Distância dinâmica baseada no ATR atual (ex: 1.5x ATR)
   double current_atr = m_regime.CachedATR(1);
   if(current_atr == 0.0) current_atr = m_symbol.Point() * 100; // Fallback de segurança
   
   double dynamic_dist = current_atr * InpMR_ATR_Multiplier;
   double ask = m_symbol.Ask();
   double bid = m_symbol.Bid();

   // Lógica de "Chase" (Perseguição) adaptada à volatilidade
   // A linha de compra só desce se o preço cair, criando uma "armadilha" dinâmica
   if((ask + dynamic_dist) < m_state.buy_line_price)
      m_state.buy_line_price = ask + dynamic_dist;

   // A linha de venda só sobe se o preço subir
   if((bid - dynamic_dist) > m_state.sell_line_price)
      m_state.sell_line_price = bid - dynamic_dist;

   // Impedir que as linhas se cruzem (proteção lógica)
   if(m_state.buy_line_price < m_state.sell_line_price)
   {
      double mid = (m_state.buy_line_price + m_state.sell_line_price) / 2.0;
      m_state.buy_line_price = mid;
      m_state.sell_line_price = mid;
   }

   // Atualização visual no gráfico (Opcional, remova se não quiser objetos)
   /*
   ObjectSetDouble(0, "MR_Advanced_BuyLine", OBJPROP_PRICE, m_state.buy_line_price);
   ObjectSetDouble(0, "MR_Advanced_SellLine", OBJPROP_PRICE, m_state.sell_line_price);
   */
}

//+------------------------------------------------------------------+
//| LÓGICA DE SAÍDA (Mean-Crossing + Fallback de Lucro)              |
//+------------------------------------------------------------------+
bool CMeanReversionAdvanced::ShouldCloseBasket()
{
   if(!InpStrategy_MR_Advanced) return false;
   if(CountPositions(POSITION_TYPE_BUY) == 0 && CountPositions(POSITION_TYPE_SELL) == 0) return false;

   // 1. SAÍDA ESTATÍSTICA (Chan): Sair quando o preço retorna à média (Z-Score próximo de 0)
   double z_score = GetCurrentZScore();
   
   if(CountPositions(POSITION_TYPE_BUY) > 0)
   {
      // Se o Z-Score subiu para perto da média (ou ficou positivo), a reversão acabou
      if(z_score >= -InpMR_ZScore_Exit) return true;
   }
   else if(CountPositions(POSITION_TYPE_SELL) > 0)
   {
      // Se o Z-Score desceu para perto da média (ou ficou negativo), a reversão acabou
      if(z_score <= InpMR_ZScore_Exit) return true;
   }

   // 2. REDE DE SEGURANÇA: Lucro mínimo em dinheiro (protege contra spread/correções lentas)
   if(GetBasketProfit() >= InpMR_Min_Profit_Money) return true;

   return false;
}

//+------------------------------------------------------------------+
//| FUNÇÕES AUXILIARES                                               |
//+------------------------------------------------------------------+
double CMeanReversionAdvanced::PipToPrice(double pips)
{
   double point = m_symbol.Point();
   if(m_symbol.Digits() == 3 || m_symbol.Digits() == 5) point *= 10;
   return pips * point;
}

int CMeanReversionAdvanced::CountPositions(ENUM_POSITION_TYPE type)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == m_symbol.Name() && 
            PositionGetInteger(POSITION_MAGIC) == m_magic &&
            PositionGetInteger(POSITION_TYPE) == type)
         {
            count++;
         }
      }
   }
   return count;
}

double CMeanReversionAdvanced::GetBasketProfit()
{
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == m_symbol.Name() && 
            PositionGetInteger(POSITION_MAGIC) == m_magic)
         {
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }
   }
   return profit;
}
//+------------------------------------------------------------------+