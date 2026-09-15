//+------------------------------------------------------------------+
//|                                              ALX_EURScalper_MQ5.mq5 |
//| Copyright 2026, ALX Quant                                        |
//| Refatorado para MQL5 com arquitetura profissional                |
//+------------------------------------------------------------------+
#property copyright "2026, ALX Quant"
#property version   "5.00"
#property description "Scalper de Grid/Martingale com Filtros de Horário, Range e Gestão de Risco Global"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUTS ORGANIZADOS                                               |
//+------------------------------------------------------------------+
input group "=== Configurações de Lote e Grid ==="
input double InpBaseLot          = 0.01;    // Lote Inicial
input double InpLotMultiplier    = 1.5;     // Multiplicador de Lote (Martingale)
input int    InpMaxTrades        = 8;       // Máximo de Ordens na Cesta (Grid)
input double InpGridStepPips     = 25.0;    // Distância do Grid em Pips
input double InpTakeProfitPips   = 30.0;    // Alvo de Lucro em Pips (sobre o preço médio)

input group "=== Gestão de Risco Global ==="
input bool   InpUseDailyTarget   = true;    // Usar Alvo Diário em USD?
input double InpDailyTargetUSD   = 50.0;    // Alvo Diário em USD
input bool   InpUseEquityStop    = true;    // Usar Stop por Perda de Equity (%)
input double InpEquityRiskPct    = 20.0;    // % de Perda Máxima da Equity para fechar tudo
input bool   InpUseHiddenTP      = true;    // Usar Take Profit Oculto (baseado no lucro total)
input double InpHiddenTPUSD      = 500.0;   // Lucro Total em USD para fechar a cesta

input group "=== Filtros de Horário ==="
input int    InpOpenHour         = 6;       // Hora de Início (Servidor)
input int    InpCloseHour        = 17;      // Hora de Fim (Servidor)
input bool   InpTradeThursday    = true;    // Operar na Quinta-feira?
input int    InpThursdayStopHour = 12;      // Parar de operar na Quinta após esta hora
input bool   InpTradeFriday      = false;   // Operar na Sexta-feira?
input int    InpFridayStopHour   = 20;      // Parar de operar na Sexta após esta hora

input group "=== Filtro de Range Diário ==="
input double InpOpenRangePips    = 20.0;    // Range mínimo de abertura em Pips
input double InpMaxDailyRangePips= 500.0;   // Range máximo diário permitido em Pips

input group "=== Configurações Gerais ==="
input int    InpMagicNumber      = 20260822;// Número Mágico do EA
input int    InpSlippagePoints   = 30;      // Slippage máximo em Points

//+------------------------------------------------------------------+
//| VARIÁVEIS GLOBAIS                                                |
//+------------------------------------------------------------------+
CTrade trade;
double pointMultiplier; // Converte Pips em Points (ex: 10 para 5 dígitos)
double dailyStartEquity;

//+------------------------------------------------------------------+
//| INICIALIZAÇÃO                                                    |
//+------------------------------------------------------------------+
int OnInit() {
   // Configurar o objeto de trade
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFilling(ORDER_FILLING_FOK); // Tenta FOK, se falhar, o Trade.mqh ajusta automaticamente
   
   // Calcular multiplicador de ponto (Pip to Point)
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   pointMultiplier = (digits == 3 || digits == 5) ? 10.0 : 1.0;
   
   dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   Print("✅ ALX EURScalper MQL5 Inicializado com sucesso no ", _Symbol);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| DESINICIALIZAÇÃO                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Comment(""); // Limpa o gráfico ao remover o EA
}

//+------------------------------------------------------------------+
//| LOOP PRINCIPAL (OTIMIZADO)                                       |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Verificar Condições de Fechamento Global (Risco)
   if (CheckGlobalExitConditions()) return;

   // 2. Obter dados das posições atuais
   int totalBuys = GetPositionCount(POSITION_TYPE_BUY);
   int totalSells = GetPositionCount(POSITION_TYPE_SELL);
   int totalPositions = totalBuys + totalSells;

   // 3. Se não houver posições, verificar filtros e sinal de entrada
   if (totalPositions == 0) {
      if (!IsTimeAllowed()) return;
      if (!IsDailyRangeAllowed()) return;
      
      // Sinal simples de momentum (Close[2] vs Close[1]) do código original
      double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
      double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);
      
      if (close2 > close1) {
         OpenPosition(POSITION_TYPE_BUY, InpBaseLot);
      } else if (close2 < close1) {
         OpenPosition(POSITION_TYPE_SELL, InpBaseLot);
      }
      return;
   }

   // 4. Se já houver posições, verificar lógica de Grid/Martingale
   if (totalPositions > 0 && totalPositions < InpMaxTrades) {
      double lastBuyPrice = GetLastOpenPrice(POSITION_TYPE_BUY);
      double lastSellPrice = GetLastOpenPrice(POSITION_TYPE_SELL);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double gridStepPoints = InpGridStepPips * _Point * pointMultiplier;

      // Lógica de Grid: Preço se moveu X pontos contra a última ordem?
      if (totalBuys > 0 && (lastBuyPrice - currentAsk) >= gridStepPoints) {
         double nextLot = CalculateNextLot(POSITION_TYPE_BUY);
         OpenPosition(POSITION_TYPE_BUY, nextLot);
      }
      else if (totalSells > 0 && (currentBid - lastSellPrice) >= gridStepPoints) {
         double nextLot = CalculateNextLot(POSITION_TYPE_SELL);
         OpenPosition(POSITION_TYPE_SELL, nextLot);
      }
   }

   // 5. Gerenciar Take Profit Unificado (Baseado no Preço Médio)
   ManageUnifiedTakeProfit();
}

//+------------------------------------------------------------------+
//| FUNÇÕES AUXILIARES DE LEITURA DE POSIÇÕES                        |
//+------------------------------------------------------------------+
int GetPositionCount(ENUM_POSITION_TYPE type) {
   int count = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) > 0) {
         if (PositionGetString(POSITION_SYMBOL) == _Symbol && 
             PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
             PositionGetInteger(POSITION_TYPE) == type) {
            count++;
         }
      }
   }
   return count;
}

double GetLastOpenPrice(ENUM_POSITION_TYPE type) {
   double lastPrice = 0;
   datetime lastTime = 0;
   
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) > 0) {
         if (PositionGetString(POSITION_SYMBOL) == _Symbol && 
             PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
             PositionGetInteger(POSITION_TYPE) == type) {
            
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            if (openTime > lastTime) {
               lastTime = openTime;
               lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            }
         }
      }
   }
   return lastPrice;
}

double GetAveragePrice(ENUM_POSITION_TYPE type) {
   double totalCost = 0;
   double totalLots = 0;
   
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) > 0) {
         if (PositionGetString(POSITION_SYMBOL) == _Symbol && 
             PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
             PositionGetInteger(POSITION_TYPE) == type) {
            
            double lots = PositionGetDouble(POSITION_VOLUME);
            double price = PositionGetDouble(POSITION_PRICE_OPEN);
            totalCost += (lots * price);
            totalLots += lots;
         }
      }
   }
   return (totalLots > 0) ? (totalCost / totalLots) : 0;
}

double GetTotalFloatingProfit() {
   double profit = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) > 0) {
         if (PositionGetString(POSITION_SYMBOL) == _Symbol && 
             PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }
   }
   return profit;
}

//+------------------------------------------------------------------+
//| FUNÇÕES DE GESTÃO DE RISCO E FECHAMENTO                          |
//+------------------------------------------------------------------+
bool CheckGlobalExitConditions() {
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double floatingProfit = GetTotalFloatingProfit();

   // 1. Alvo Diário em USD
   if (InpUseDailyTarget && floatingProfit >= InpDailyTargetUSD) {
      Print("🎯 Alvo Diário atingido! Fechando todas as posições.");
      CloseAllPositions();
      return true;
   }

   // 2. Stop por Perda de Equity (%)
   if (InpUseEquityStop && floatingProfit < 0) {
      double maxLossAllowed = currentEquity * (InpEquityRiskPct / 100.0);
      if (MathAbs(floatingProfit) >= maxLossAllowed) {
         Print("🚨 Stop de Equity acionado! Fechando todas as posições.");
         CloseAllPositions();
         return true;
      }
   }

   // 3. Take Profit Oculto (Baseado no lucro total da cesta)
   if (InpUseHiddenTP && floatingProfit >= InpHiddenTPUSD) {
      Print("🔒 Take Profit Oculto acionado! Fechando todas as posições.");
      CloseAllPositions();
      return true;
   }

   return false;
}

void CloseAllPositions() {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) > 0) {
         if (PositionGetString(POSITION_SYMBOL) == _Symbol && 
             PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            trade.PositionClose(PositionGetTicket(i));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| FUNÇÕES DE FILTRO (HORÁRIO E RANGE)                              |
//+------------------------------------------------------------------+
bool IsTimeAllowed() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentHour = dt.hour;
   int dayOfWeek = dt.day_of_week; // 0=Dom, 4=Qui, 5=Sex

   if (dayOfWeek == 4 && !InpTradeThursday) return false;
   if (dayOfWeek == 4 && InpTradeThursday && currentHour >= InpThursdayStopHour) return false;
   
   if (dayOfWeek == 5 && !InpTradeFriday) return false;
   if (dayOfWeek == 5 && InpTradeFriday && currentHour >= InpFridayStopHour) return false;

   if (InpOpenHour < InpCloseHour) {
      if (currentHour < InpOpenHour || currentHour >= InpCloseHour) return false;
   } else {
      // Permite passagem da meia-noite
      if (currentHour < InpOpenHour && currentHour >= InpCloseHour) return false;
   }

   return true;
}

bool IsDailyRangeAllowed() {
   if (InpOpenRangePips <= 0 && InpMaxDailyRangePips <= 0) return true;

   // Obter preço de abertura do dia atual
   datetime todayStart = iTime(_Symbol, PERIOD_D1, 0);
   double dailyOpen = iOpen(_Symbol, PERIOD_D1, 0);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double rangeUp = MathAbs(currentAsk - dailyOpen) / (_Point * pointMultiplier);
   double rangeDown = MathAbs(dailyOpen - currentBid) / (_Point * pointMultiplier);

   if (rangeUp < InpOpenRangePips || rangeUp > InpMaxDailyRangePips) return false;
   if (rangeDown < InpOpenRangePips || rangeDown > InpMaxDailyRangePips) return false;

   return true;
}

//+------------------------------------------------------------------+
//| FUNÇÕES DE EXECUÇÃO E CÁLCULO                                    |
//+------------------------------------------------------------------+
double CalculateNextLot(ENUM_POSITION_TYPE type) {
   // Encontra o último lote aberto e multiplica
   double lastLot = InpBaseLot;
   double maxTime = 0;
   
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (PositionGetTicket(i) > 0) {
         if (PositionGetString(POSITION_SYMBOL) == _Symbol && 
             PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
             PositionGetInteger(POSITION_TYPE) == type) {
            
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            if (openTime > maxTime) {
               maxTime = openTime;
               lastLot = PositionGetDouble(POSITION_VOLUME);
            }
         }
      }
   }
   
   double nextLot = lastLot * InpLotMultiplier;
   
   // Normalizar e validar com os limites da corretora
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   nextLot = MathMax(minLot, MathMin(maxLot, nextLot));
   nextLot = MathRound(nextLot / lotStep) * lotStep;
   
   return nextLot;
}

void OpenPosition(ENUM_POSITION_TYPE type, double lotSize) {
   double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string comment = StringFormat("Grid_%d", GetPositionCount(type) + 1);
   
   if (type == POSITION_TYPE_BUY) {
      if (trade.Buy(lotSize, _Symbol, price, 0, 0, comment)) {
         Print("✅ Compra aberta: ", lotSize, " lots @ ", price);
      } else {
         Print("❌ Falha na compra. Erro: ", GetLastError());
      }
   } else {
      if (trade.Sell(lotSize, _Symbol, price, 0, 0, comment)) {
         Print("✅ Venda aberta: ", lotSize, " lots @ ", price);
      } else {
         Print("❌ Falha na venda. Erro: ", GetLastError());
      }
   }
}

void ManageUnifiedTakeProfit() {
   double tpPips = InpTakeProfitPips;
   if (tpPips <= 0) return; // Se TP for 0, não faz nada (deixa o HiddenTP cuidar)

   double buyAvgPrice = GetAveragePrice(POSITION_TYPE_BUY);
   double sellAvgPrice = GetAveragePrice(POSITION_TYPE_SELL);
   
   if (buyAvgPrice > 0) {
      double buyTP = buyAvgPrice + (tpPips * _Point * pointMultiplier);
      buyTP = NormalizeDouble(buyTP, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      
      // Verifica se precisa modificar (evita requotes desnecessários)
      for (int i = PositionsTotal() - 1; i >= 0; i--) {
         if (PositionGetTicket(i) > 0) {
            if (PositionGetString(POSITION_SYMBOL) == _Symbol && 
                PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
                PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
               
               double currentTP = PositionGetDouble(POSITION_TP);
               if (MathAbs(currentTP - buyTP) > _Point) {
                  trade.PositionModify(PositionGetTicket(i), PositionGetDouble(POSITION_SL), buyTP);
               }
            }
         }
      }
   }

   if (sellAvgPrice > 0) {
      double sellTP = sellAvgPrice - (tpPips * _Point * pointMultiplier);
      sellTP = NormalizeDouble(sellTP, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      
      for (int i = PositionsTotal() - 1; i >= 0; i--) {
         if (PositionGetTicket(i) > 0) {
            if (PositionGetString(POSITION_SYMBOL) == _Symbol && 
                PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
                PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
               
               double currentTP = PositionGetDouble(POSITION_TP);
               if (MathAbs(currentTP - sellTP) > _Point) {
                  trade.PositionModify(PositionGetTicket(i), PositionGetDouble(POSITION_SL), sellTP);
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+