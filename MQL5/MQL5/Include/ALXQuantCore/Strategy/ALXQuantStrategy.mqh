//+------------------------------------------------------------------+
//|                                             ALXQuantStrategy.mqh |
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
*/nput group    "== Strategys On/Off =="
input bool     InpStrategy_Breakout          = false;          // 10.1. BreakOut [Não funcionando]     
input bool     InpStrategy_MeanRev           = false;          // 10.2. Mean Reversal [TOP]
input bool     InpStrategy_Momentum          = false;          // 10.3. BrealOut & Momentum [TOP]       
input bool     InpStrategy_VolBreak          = false;          // 10.4. Volume Breakout [Não funcionando]         
input bool     InpStrategy_Pullback          = false;          // 10.5. Pullback VWAP/TWAP [TOP]       
input bool     InpStrategy_Session           = true;           // 10.6. BreakOut Session open [TOP]       
input bool     InpStrategy_RM                = false;          // 16.1. Operar RM Breakout?
//+------------------------------------------------------------------+
input group    "== 10. Strategy#1 - Breakout =="
input double   InpStrategy_Breakout_weight   = 100.0;          // 11.1. [Breakout] Weight lot   
input uint     InpStrategy_Breakout_Bar      = 0;              // 11.2. [Breakout] Position Bar (0~1) 
input uint     InpStrategy_Breakout_AvBar    = 80;             // 11.3. [Breakout] Average bar 
input double   InpStrategy_Breakout_PipsStep = 4;              // 11.4. [Breakout] Volatility mult.
input string   InpStrategy_Breakout_comm     = "Breakout#1";   // 11.5. [Breakout] Comment   
//+------------------------------------------------------------------+
input group    "== 11. Strategy#2 - MeanRev =="
input double   InpStrategy_MeanRev_weight    = 50.0;           // 12.1. [MeanRev] Weight lot
input int      Filter                        = 130;            // 12.2. [MeanRev] Filtro de vela (pts)
input int      KeltnerPeriod                 = 20;             // 12.3. [MeanRev] Keltner Period          
input double   KeltnerDev                    = 2.0;            // 12.4. [MeanRev] KeltnerPeriod
input int      RSI_PARAM                     = 14;             // 12.5. [MeanRev] RSI Período
input double   RSIBuyLevel                   = 30.0;           // 12.6. [MeanRev] RSI buy level
input double   RSISellLevel                  = 70.0;           // 12.7. [MeanRev] RSI sell level
input string   InpStrategy_MeanRev_comm      = "MeanRev#2";    // 12.8. [MeanRev] Comment
//+------------------------------------------------------------------+
input group    "== 12. Strategy#3 - Momentum =="
input double   InpStrategy_Momentum_weight   = 100.0;          // 13.1. [Momentum] Weight lot
input uint     InpStrategy_Momentum_AvBar    = 80;             // 13.2. [Momentum] Average bar 
input double   InpStrategy_Momentum_PipsStep = 2;              // 13.3. [Momentum] Volatility mult.
input string   InpStrategy_Momentum_comm     = "Momentum#3";   // 13.4. [Momentum] Comment
//+------------------------------------------------------------------+
input group    "== 13. Strategy#4 - Volatility Breakout =="
input double   InpStrategy_VolBreak_weight   = 75.0;           // 14.1. [VolBreak] Weight lot
input uint     InpStrategy_VolBreak_Lookback = 20;             // 14.2. [VolBreak] Period Trendrange
input double   InpStrategy_VolBreak_ATR_Mult = 0.7;            // 14.3. [VolBreak] Max ATR Trendrange
input string   InpStrategy_VolBreak_comm     = "VolBreak#4";   // 14.4. [VolBreak] Comment
//+------------------------------------------------------------------+
input group    "== 14. Strategy#5 - VWAP/TWAP =="
input double   InpStrategy_Pullback_weight   = 50.0;           // 15.1. [VWAP/TWAP] Weight lot
input enPrice  InpStrategy_Pullback_price    = PRICE_VWAP;     // 15.2. [VWAP/TWAP] Price mode
input string   InpStrategy_Pullback_comm     = "PullBack#5";   // 14.4. [VWAP/TWAP] Comment
//+------------------------------------------------------------------+
input group    "== 15. Strategy#6 - Session Breakout =="
input double   InpStrategy_Session_weight    = 75.0;           // 16.1. [Session] Weight lot
input int      InpStrategy_Session_StartHour = 6;              // 16.2. [Session] Time start session (Londres)
input int      InpStrategy_Session_EndHour   = 12;             // 16.3. [Session] Time breakout (after NY)
input string   InpStrategy_Session_comm      = "Session#6";    // 14.4. [Session] Comment
//+------------------------------------------------------------------+
input group    "== 16. Strategy#7 - RM Range Breakout =="

input double   InpStrategy_RM_weight      = 100.0;         // 16.2. [RM] Weight lot
input string   InpStrategy_RM_comm        = "RangeBreak#7";// 16.3. [RM] Comment
input int      InpStrategy_RM_MinRange    = 5;             // 16.4. [RM] Min Range (barras)
input int      InpStrategy_RM_MaxRange    = 30;            // 16.5. [RM] Max Range (barras)
input int      InpStrategy_RM_HLFilter    = 10;            // 16.6. [RM] High/Low Filter (barras)
//+------------------------------------------------------------------+



long     InpStrategy_Breakout_Magic    = 2021;     // [Breakout] Magic ID   
long     InpStrategy_MeanRev_Magic     = 2022;     // [MeanRev] Magic ID   
long     InpStrategy_Momentum_Magic    = 2023;     // [Momentum] Magic ID   
long     InpStrategy_VolBreak_Magic    = 2024;     // [VolBreak] Magic ID   
long     InpStrategy_Pullback_Magic    = 2025;     // [Pullback] Magic ID   
long     InpStrategy_Session_Magic     = 2026;     // [Session] Magic ID   
//+------------------------------------------------------------------+


uchar SignalBreakout(void)
{
   if(!m_symbol.RefreshRates() || !m_symbol.Refresh()) return(0);

   // Dados do Candle 1 (Fechado - Seguro contra repainting)
   double open1  = iOpen(m_symbol.Name(), Period(), 1);
   double close1 = iClose(m_symbol.Name(), Period(), 1);
   double high1  = iHigh(m_symbol.Name(), Period(), 1);
   double low1   = iLow(m_symbol.Name(), Period(), 1);
   
   double avgBar = m_core.AverageBar(InpStrategy_Breakout_AvBar); 
   double point  = m_symbol.Point();
   
   double bodySize1 = MathAbs(open1 - close1) / point;
   double threshold = avgBar * InpStrategy_Breakout_PipsStep;
   
   double ask = m_symbol.Ask();
   double bid = m_symbol.Bid();

   // COMPRA: Candle 1 foi de alta forte (corpo > threshold) e o preço atual rompeu a máxima dele
   if(close1 > open1 && bodySize1 > threshold) 
   {
      if(ask > high1) return(1);
   }

   // VENDA: Candle 1 foi de baixa forte (corpo > threshold) e o preço atual rompeu a mínima dele
   if(close1 < open1 && bodySize1 > threshold) 
   {
      if(bid < low1) return(2);
   }

   return(0);
}



/*
// Estratégia 1: Breakout (Rompimento de Volatilidade) - Otimizado para Candle 0
uchar SignalBreakout(void)
{
   if(!m_symbol.RefreshRates() || !m_symbol.Refresh())
      return(0);

   double open0  = iOpen(m_symbol.Name(),Period(), InpStrategy_Breakout_Bar);
   double close0 = iClose(m_symbol.Name(),Period(), InpStrategy_Breakout_Bar);
   double high0  = iHigh(m_symbol.Name(),Period(), InpStrategy_Breakout_Bar);
   double low0   = iLow(m_symbol.Name(),Period(), InpStrategy_Breakout_Bar);
   double avgBar = m_core.AverageBar(InpStrategy_Breakout_AvBar); 
   double point  = m_symbol.Point();
   
   double bodySize = MathAbs(open0 - close0) / point;
   double threshold = avgBar * InpStrategy_Breakout_PipsStep;
   
   // Variável de proteção real: O preço atual está sustentando a direção?
   double currentPrice = m_symbol.Ask(); // Preço em tempo real
   
   // Compra Breakout: Corpo forte + Preço atual está no topo do candle (sustentou a alta)
   if(close0 > open0 && bodySize > threshold) 
   {
      double upperZone = high0 - (high0 - low0) * 0.20; // Zona dos 20% mais altos do candle
      if(currentPrice >= upperZone) return(1);
   }

   currentPrice = m_symbol.Bid(); // Para venda usamos o Bid
   
   // Venda Breakout: Corpo forte + Preço atual está na base do candle (sustentou a baixa)
   if(close0 < open0 && bodySize > threshold) 
   {
      double lowerZone = low0 + (high0 - low0) * 0.20; // Zona dos 20% mais baixos do candle
      if(currentPrice <= lowerZone) return(2);
   }

   return(0);
}
*/




//+------------------------------------------------------------------+
//| Lógica de Sinal (Baseada na Volatility Bands do TradingView)     |
//+------------------------------------------------------------------+
uchar SignalReversal(void)
{
   // Pegamos dados do candle 0 (atual) para reversão rápida
   double high0 = iHigh(_Symbol, PERIOD_CURRENT, 0);
   double low0  = iLow(_Symbol, PERIOD_CURRENT, 0);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if((high0 - low0) < (Filter*Point()) ) return 0;

   // Calculamos o Canal de Volatilidade (Keltner) no Index 0
   double k_upper = CustomKeltner(_Symbol, PERIOD_CURRENT, KeltnerPeriod, KeltnerDev, 1, 0); 
   double k_lower = CustomKeltner(_Symbol, PERIOD_CURRENT, KeltnerPeriod, KeltnerDev, 2, 0); 
   double rsi     = CustomiRSI(_Symbol, PERIOD_CURRENT, RSI_PARAM, 0);

   // SINAL DE COMPRA: Preço abaixo da banda e RSI sobrevendido
   if(bid < k_lower && rsi < RSIBuyLevel) return -1;

   // SINAL DE VENDA: Preço acima da banda e RSI sobrecomprado
   if(ask > k_upper && rsi > RSISellLevel) return 1;

   return 0;
}

// Estratégia 3: Breakout (Rompimento de Volatilidade)
uchar SignalBreakoutMomentum(void)
{
   if(!m_symbol.RefreshRates() || !m_symbol.Refresh())
      return(0);

   double open0  = iOpen(m_symbol.Name(), Period(), 0);
   double close0 = iClose(m_symbol.Name(), Period(), 0);
   double open1  = iOpen(m_symbol.Name(), Period(), 1);
   double close1 = iClose(m_symbol.Name(),Period(), 1);
   double open2  = iOpen(m_symbol.Name(), Period(), 2);
   double close2 = iClose(m_symbol.Name(), Period(), 2);
   
   double avgBar = m_core.AverageBar(InpStrategy_Momentum_AvBar); 
   double point  = m_symbol.Point();;
   double threshold = avgBar * InpStrategy_Momentum_PipsStep;

   // Verifica o tamanho do corpo da vela atual (Momentum)
   double bodySize0 = MathAbs(open0 - close0) / point;

   if(bodySize0 <= threshold) return(0); // Se a vela atual não tem força, não faz nada.

   // COMPRA: Vela[2] Baixista + Vela[1] Altista + Vela[0] Altista Forte
   // Exige que o mercado caiu, teve refluxo, e agora rompe com força.
   if(close2 < open2 && close1 > open1 && close0 > open0) return(1); 
   // VENDA: Vela[2] Altista + Vela[1] Baixista + Vela[0] Baixista Forte
   if(close2 > open2 && close1 < open1 && close0 < open0) return(2);

   return(0);
}


uchar SignalVolatilityBreakout(void)
{
   if(!m_symbol.RefreshRates() || !m_symbol.Refresh()) return(0);

   // 1. Checa se o mercado está apertado (ATR menor que a média * Multiplicador)
   double atr = CustomATR(m_symbol.Name(),Period(), 14);
   
   double avgATR = m_core.AverageBar(14); // Sua função de média
   if(atr > avgATR * InpStrategy_VolBreak_ATR_Mult) return(0); // Mercado já está expandido, não é consolidação

   // 2. Acha a Máxima e Mínima do período de consolidação (Velas 1 até Lookback)
   double highest = -DBL_MAX;
   double lowest  = DBL_MAX;
   
   for(uint i = 1; i<=InpStrategy_VolBreak_Lookback; i++)
   {
      double h = iHigh(m_symbol.Name(),Period(), i);
      double l = iLow(m_symbol.Name(),Period(), i);
      if(h > highest) highest = h;
      if(l < lowest) lowest = l;
   }

   // 3. Rompeu o teto ou o chão no Candle 0?
   double bid = m_symbol.Bid();
   double ask = m_symbol.Ask();

   if(ask > highest) return(1); // Compra rompendo o teto
   if(bid < lowest) return(2);  // Venda rompendo o chão

   return(0);
}


// Estratégia 5: Pullback em VWAP/TWAP (Buy the Dip / Sell the Rally)
uchar SignalMAPullback(void)
{
   if(!m_symbol.RefreshRates() || !m_symbol.Refresh()) return(0);

   // ==================================================================
   // 1. PARÂMETROS DE TENDÊNCIA E ÂNCORA (VWAP / TWAP)
   // ==================================================================
   
   // Tendência Macro: TWAP longo (Média temporal, ignora distorções de volume de notícias)
   double twap_slow = CustomMA(_Symbol, _Period, 200, 1, CUSTOM_PRICE_TWAP);
   
   // Âncora Curta: VWAP dos últimos 20 períodos (Preço médio real onde o dinheiro entrou)
   double vwap_fast = CustomMA(_Symbol, _Period, 20, 1, CUSTOM_PRICE_VWAP);
   
   // Segurança: Se não conseguir calcular os indicadores, não opera
   if(twap_slow == 0.0 || vwap_fast == 0.0) return(0);

   // ==================================================================
   // 2. DADOS DO CANDLE ANTERIOR (Shift 1 para evitar repainting)
   // ==================================================================
   double close1 = iClose(_Symbol, _Period, 1);
   double open1  = iOpen(_Symbol, _Period, 1);
   double low1   = iLow(_Symbol, _Period, 1);
   double high1  = iHigh(_Symbol, _Period, 1);

   // ==================================================================
   // 3. LÓGICA DE COMPRA (Bullish Pullback)
   // ==================================================================
   // A) Tendência de Alta macro: Fechamento acima do TWAP lento
   if(close1 > twap_slow)
   {
      // B) O preço recuou e tocou o VWAP rápido (A mínima do candle encostou ou passou levemente o VWAP)
      // Usamos um fator de 1.001 (0.1%) para dar um "desconto" e considerar o toque mesmo com spread
      if(low1 <= vwap_fast * 1.001) 
      {
         // C) Rejeição: O candle formou um martelo (Fechou acima da abertura E acima do VWAP)
         if(close1 > open1 && close1 > vwap_fast)
            return(1); // Sinal de Compra!
      }
   }

   // ==================================================================
   // 4. LÓGICA DE VENDA (Bearish Pullback)
   // ==================================================================
   // A) Tendência de Baixa macro: Fechamento abaixo do TWAP lento
   if(close1 < twap_slow)
   {
      // B) O preço subiu e tocou o VWAP rápido (A máxima do candle encostou ou passou levemente o VWAP)
      if(high1 >= vwap_fast * 0.999) // Fator de desconto para venda
      {
         // C) Rejeição: O candle formou um shooting star (Fechou abaixo da abertura E abaixo do VWAP)
         if(close1 < open1 && close1 < vwap_fast)
            return(2); // Sinal de Venda!
      }
   }

   return(0);
}


uchar SignalSessionBreakout(void)
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


//+------------------------------------------------------------------+
//| Estratégia 7: RM Range Breakout (Baseado no indicador ALX RM)    |
//+------------------------------------------------------------------+
uchar SignalRangeBreakout()
{
   if(!m_symbol.RefreshRates()) return 0;

   int MinRange     = InpStrategy_RM_MinRange;
   int MaxRange     = InpStrategy_RM_MaxRange;
   int HLFilter     = InpStrategy_RM_HLFilter;
   int shift        = 1; // Sempre na vela fechada para evitar repainting

   double close1    = iClose(m_symbol.Name(), PERIOD_CURRENT, shift);
   double open1     = iOpen(m_symbol.Name(), PERIOD_CURRENT, shift);
   double high1     = iHigh(m_symbol.Name(), PERIOD_CURRENT, shift);
   double low1      = iLow(m_symbol.Name(), PERIOD_CURRENT, shift);

   // Níveis de referência (Filtro do Indicador)
   double refHigh   = iHigh(m_symbol.Name(), PERIOD_CURRENT, iHighest(m_symbol.Name(), PERIOD_CURRENT, MODE_HIGH, HLFilter, shift + 1));
   double refLow    = iLow(m_symbol.Name(), PERIOD_CURRENT, iLowest(m_symbol.Name(), PERIOD_CURRENT, MODE_LOW, HLFilter, shift + 1));

   // Escaneia ranges do menor para o maior
   for(int range = MinRange; range <= MaxRange; range++)
   {
      double rangeHigh = iHigh(m_symbol.Name(), PERIOD_CURRENT, iHighest(m_symbol.Name(), PERIOD_CURRENT, MODE_HIGH, range, shift + 1));
      double rangeLow  = iLow(m_symbol.Name(), PERIOD_CURRENT, iLowest(m_symbol.Name(), PERIOD_CURRENT, MODE_LOW, range, shift + 1));
      
      // Preço e vela no início do range (shift + range + 1)
      double closeRangeStart = iClose(m_symbol.Name(), PERIOD_CURRENT, shift + range + 1);
      double highRangeStart = iHigh(m_symbol.Name(), PERIOD_CURRENT, shift + range + 1);
      double lowRangeStart  = iLow(m_symbol.Name(), PERIOD_CURRENT, shift + range + 1);
      
      bool isBullCandle = (close1 > open1);
      bool isBearCandle = (close1 < open1);

      // ==================================================================
      // PADRÃO 1: Bullish Breakout Padrão
      // Vela de alta + Rompe topo do range + Abertura abaixo do fechamento inicial + Fechamento acima da máxima inicial
      // ==================================================================
      if(isBullCandle && close1 > rangeHigh && open1 < closeRangeStart && close1 > highRangeStart)
      {
         // Filtro: O rompimento deve ser num nível significativo (mínima do range <= referência baixa)
         if(rangeLow <= refLow || low1 <= refLow) 
            return 1; // Sinal de Compra
      }

      // ==================================================================
      // PADRÃO 2: Bearish Breakout Padrão
      // Vela de venda + Rompe fundo do range + Abertura acima do fechamento inicial + Fechamento abaixo da mínima inicial
      // ==================================================================
      if(isBearCandle && close1 < rangeLow && open1 > closeRangeStart && close1 < lowRangeStart)
      {
         // Filtro: O rompimento deve ser num nível significativo (máxima do range >= referência alta)
         if(rangeHigh >= refHigh || high1 >= refHigh) 
            return 2; // Sinal de Venda
      }

      // ==================================================================
      // PADRÃO 3: Alternative Bullish (Força bruta no rompimento)
      // Vela de alta + Rompe topo do range + A vela que iniciou o range era de venda (exaustão vendedora)
      // ==================================================================
      bool startWasBear = (closeRangeStart < iOpen(m_symbol.Name(), PERIOD_CURRENT, shift + range + 1));
      if(isBullCandle && close1 > rangeHigh && startWasBear)
      {
         if(rangeLow <= refLow || low1 <= refLow) 
            return 1;
      }

      // ==================================================================
      // PADRÃO 4: Alternative Bearish (Força bruta no rompimento)
      // Vela de venda + Rompe fundo do range + A vela que iniciou o range era de alta (exaustão compradora)
      // ==================================================================
      bool startWasBull = (closeRangeStart > iOpen(m_symbol.Name(), PERIOD_CURRENT, shift + range + 1));
      if(isBearCandle && close1 < rangeLow && startWasBull)
      {
         if(rangeHigh >= refHigh || high1 >= refHigh) 
            return 2;
      }
   }

   return 0; // Sem sinal
}



double GetHistProfit(datetime from)
{
   if(!HistorySelect(from, TimeCurrent())) return 0;
   double p = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == m_core.sets.m_magic)
         p += HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP) + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return p;
}
