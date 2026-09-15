//+------------------------------------------------------------------+
//|                                                   EA QUantFX.mq5 |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property version   "11.0"

const string EA_NAME    = "Quant Crypto";
const string EA_VERSION = "v11.0.0";

#include <ALXQuantCore\Framework.mqh> CFramework m_framework;

//+------------------------------------------------------------------+
//| # Init                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   m_framework.Init();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| # OnDeInit                                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) { m_framework.DeInit(reason); }

//+------------------------------------------------------------------+
//|======================== OnTick ===================================|
//+------------------------------------------------------------------+
void OnTick()
{
//---
   MqlTick tick;
//---
   if(!SymbolInfoTick(Symbol(),tick))
      Print("SymbolInfoTick() failed, error = ",GetLastError());

    //--- Execution engine: retry/timeout/spread/quality
    m_exec.Update();

    // Regime (new M5 bar only)
   static datetime last_bar = 0;
   datetime bar = iTime(_Symbol, PERIOD_M5, 0);
   if(bar != last_bar)
   {
      m_regime.Get();
      last_bar = bar;
   }

//---
   if(sets.time_new == 0) sets.time_new = TimeCurrent();
   if(sets.price_open == 0) sets.price_open = tick.bid;

   if(sets.time_new + sets.time_open < TimeCurrent())
   {
      sets.time_new = TimeCurrent();
      sets.price_open = tick.bid;
   }

   bool buy_tfh  = iClose(m_symbol.Name(),InphighTimeframeConfirme,0) > iOpen(m_symbol.Name(),InphighTimeframeConfirme,0); 
   bool sell_tfh = iClose(m_symbol.Name(),InphighTimeframeConfirme,0) < iOpen(m_symbol.Name(),InphighTimeframeConfirme,0); 

   sets.m_need_open_buy  = buy_tfh  && (sets.time_new + sets.time_open >= TimeCurrent() && tick.bid - InpPipsStep * m_symbol.Point() >= sets.price_open);
   sets.m_need_open_sell = sell_tfh && (sets.time_new + sets.time_open >= TimeCurrent() && tick.bid + InpPipsStep * m_symbol.Point() <= sets.price_open);

   datetime current_bar = iTime(_Symbol, _Period, 0);

   bool can_trade_open = CalculateAllPositions()==0    &&
                         m_timefilter.IsTimeTrade()    &&
                         !m_newsfilter.IsNewsBlocked() &&
                         IsSpreadOK()                  &&
                         !m_regime.IsChaosRegime()     &&
                         !m_exec.IsBusy()              &&
                         current_bar > 0               &&
                         current_bar != sets.m_last_trade_bar_time;


   if(can_trade_open)
   {
      if(sets.m_need_open_sell) { OpenPosition(POSITION_TYPE_SELL); } ///m_trade.Sell(GetLot(), m_symbol.Name() , tick.bid, 0, 0, sets.m_comment); }
      if(sets.m_need_open_buy)  { OpenPosition(POSITION_TYPE_BUY);  } //m_trade.Buy(GetLot() , m_symbol.Name() , tick.ask, 0, 0, sets.m_comment); }
   }

//--- Trailing Stop
   if(CalculateAllPositions()==1) { Traling(); }
}

//+------------------------------------------------------------------+
//|========================== Funções ================================|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Distância de Stop (em preço) - independente do lote               |
//| Usado pelo modo lot_risk para saber "quanto preço" o SL vai andar |
//+------------------------------------------------------------------+
double GetStopDistancePrice()
{
   double dist = 0.0;

   if(InpSLMode == SL_ATR)
   {
      double atr = CustomATR(InpATRStopsPeriod, 1);
      dist = atr * InpSLValue;
   }
   else // SL_FIXED
   {
      dist = InpSLValue * sets.m_adjusted_point;
   }

   return dist;
}

//+------------------------------------------------------------------+
//| Lote máximo permitido pela alavancagem configurada                |
//| Limita exposição: lot * contractSize * price <= balance * lev     |
//+------------------------------------------------------------------+
double GetMaxLotByLeverage()
{
   if(InpMaxLeverage <= 0) return DBL_MAX; // 0 = sem limite de alavancagem

   double balance = m_account.Balance();
   if(balance <= 0.0) return 0.0;

   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double price = m_symbol.Ask() > 0.0 ? m_symbol.Ask() : m_symbol.Bid();

   if(contractSize <= 0.0 || price <= 0.0)
      return DBL_MAX; // não foi possível calcular, não bloqueia

   double maxLot = (balance * InpMaxLeverage) / (contractSize * price);
   return maxLot;
}

//+------------------------------------------------------------------+
//| GetLot - Cálculo robusto do lote por modo selecionado             |
//+------------------------------------------------------------------+
double GetLot(void)
{
   //--- Garante dados atualizados do símbolo
   m_symbol.RefreshRates();

   double minLot  = m_symbol.LotsMin();
   double maxLot  = m_symbol.LotsMax();
   double step    = m_symbol.LotsStep();

   //--- Sanidade dos limites do símbolo
   if(minLot <= 0.0 || maxLot <= 0.0 || step <= 0.0)
   {
      PrintFormat("[GetLot] %s: limites de lote inválidos (min=%.5f max=%.5f step=%.5f). Abortando com lote mínimo de segurança.",
                  m_symbol.Name(), minLot, maxLot, step);
      return (minLot > 0.0) ? minLot : 0.01;
   }

   double balance = m_account.Balance();
   double lot = 0.0;

   switch(InpLotMode)
   {
      //=========================================================
      case lot_fix:
      //=========================================================
      {
         lot = InpLotValue;
         break;
      }

      //=========================================================
      case lot_min:
      //=========================================================
      {
         lot = minLot;
         break;
      }

      //=========================================================
      case lot_balance: // "lote por cada $10.000 de saldo"
      //=========================================================
      {
         if(balance <= 0.0 || InpLotValue <= 0.0)
         {
            lot = minLot;
            break;
         }
         lot = (balance / 10000.0) * InpLotValue;
         break;
      }

      //=========================================================
      case lot_risk: // Risco % real, baseado na distância do SL
      //=========================================================
      {
         if(balance <= 0.0 || InpLotValue <= 0.0)
         {
            lot = minLot;
            break;
         }

         double tickValue = m_symbol.TickValue();
         double tickSize  = m_symbol.TickSize();

         if(tickValue <= 0.0 || tickSize <= 0.0)
         {
            PrintFormat("[GetLot] %s: TickValue/TickSize inválidos (tv=%.5f ts=%.5f). Usando lote mínimo.",
                        m_symbol.Name(), tickValue, tickSize);
            lot = minLot;
            break;
         }

         double distPrice = GetStopDistancePrice();
         if(distPrice <= 0.0)
         {
            PrintFormat("[GetLot] %s: distância de SL inválida para cálculo de risco. Usando lote mínimo.",
                        m_symbol.Name());
            lot = minLot;
            break;
         }

         double riskMoney   = balance * (InpLotValue / 100.0); // InpLotValue = % de risco
         double distInTicks = distPrice / tickSize;
         double lossPerLot  = distInTicks * tickValue;

         if(lossPerLot <= 0.0)
         {
            lot = minLot;
            break;
         }

         lot = riskMoney / lossPerLot;
         break;
      }

      default:
         lot = minLot;
         break;
   }

   //--- Proteção contra NaN/inf em qualquer modo
   if(!MathIsValidNumber(lot) || lot <= 0.0)
   {
      PrintFormat("[GetLot] %s: cálculo resultou em valor inválido (%.5f). Usando lote mínimo.",
                  m_symbol.Name(), lot);
      lot = minLot;
   }

   //--- Teto fixo do input (InpMaxLot)
   if(InpMaxLot > 0.0)
      lot = MathMin(lot, InpMaxLot);

   //--- Teto por alavancagem máxima permitida
   double maxByLeverage = GetMaxLotByLeverage();
   if(maxByLeverage < DBL_MAX)
      lot = MathMin(lot, maxByLeverage);

   //--- Limita aos limites do símbolo
   lot = MathMax(minLot, MathMin(maxLot, lot));

   //--- Ajusta ao step a partir do mínimo
   double steps = MathFloor((lot - minLot) / step + 1e-8);
   lot = minLot + steps * step;

   //--- Proteção final
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return(lot);
}


//+------------------------------------------------------------------+
//| Calcula o preço do Stop Loss (Fixo / ATR / Fallback %)           |
//+------------------------------------------------------------------+
double GetStopLossPrice(ENUM_POSITION_TYPE type, double open_price, double lots)
{
   double dist = 0.0;
   double stop_min = m_symbol.StopsLevel() * m_symbol.Point();
   if(stop_min <= 0.0)
      stop_min = (m_symbol.Ask() - m_symbol.Bid()) * 3.0;
   stop_min *= 1.1;

   //--- Modo ATR
   if(InpSLMode == SL_ATR)
   {
      double atr = CustomATR(InpATRStopsPeriod, 1);
      dist = atr * InpSLValue;  // Kv
   }
   //--- Modo Fixo
   else
   {
      dist = InpSLValue * m_symbol.Point() * 10.0;  // pips → pontos
   }

   //--- Fallback: StopLossProcent (se dist == 0)
   if(dist <= 0.0 && StopLossProcent > 0.0 && lots > 0.0)
   {
      double risk_money = m_account.Balance() * StopLossProcent / 100.0;
      double tick_value = m_symbol.TickValue();
      double tick_size  = m_symbol.TickSize();
      if(tick_value > 0.0 && tick_size > 0.0)
         dist = (risk_money / (tick_value * lots)) * tick_size;
   }

   if(dist <= 0.0) return 0.0;

   //--- Calcula preço do SL
   double sl = 0.0;
   if(type == POSITION_TYPE_BUY)
      sl = open_price - dist;
   else
      sl = open_price + dist;

   //--- Validação StopsLevel
   if(type == POSITION_TYPE_BUY && (open_price - sl) < stop_min)
      sl = open_price - stop_min;
   if(type == POSITION_TYPE_SELL && (sl - open_price) < stop_min)
      sl = open_price + stop_min;

   return m_symbol.NormalizePrice(sl);
}


//+------------------------------------------------------------------+
//| IsSpreadOK                                                       |
//+------------------------------------------------------------------+
bool IsSpreadOK(void)
{
   if(InpMaxSpreadPips <= 0)
      return true;

   if(!m_symbol.RefreshRates())
      return false;

   return (m_symbol.Spread() <= InpMaxSpreadPips);
}

/*
//+------------------------------------------------------------------+
//| IsFridayClose - Verifica se é hora de fechar sexta                |
//+------------------------------------------------------------------+
bool IsFridayClose(void)
{
   if(InpFridayCloseHour <= 0) return false; // filtro desligado
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   //--- Sexta-feira (day_of_week=5) com horário >= hora de fechar
   if(dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour)
      return true;
   
   return false;
}
*/

//+------------------------------------------------------------------+
//| Calculate all positions Buy and Sell                             |
//+------------------------------------------------------------------+
int CalculateAllPositions(void)
  {
   int count=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
      if(m_position.SelectByIndex(i)) // selects the position by index for further access to its properties
         if(m_position.Symbol()==m_symbol.Name() && m_position.Magic()==sets.m_magic)
           {
               count++;
           }
//---
   return(count);
  }

//+------------------------------------------------------------------+
//| Close positions                                                  |
//+------------------------------------------------------------------+
void CloseAllPositions(void)
  {
   for(int i=PositionsTotal()-1;i>=0;i--) // returns the number of current positions
      if(m_position.SelectByIndex(i))     // selects the position by index for further access to its properties
         if(m_position.Symbol()==Symbol() && m_position.Magic()==sets.m_magic)
            m_trade.PositionClose(m_position.Ticket()); // close a position by the specified symbol
  }


void Traling()
{
   double Point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   CCommission *comm = m_framework.Commission();
   double commFloor = comm.DistPrice(); // cost floor (comissão+buffer) em preço

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == sets.m_magic)
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);

         if(posType == POSITION_TYPE_BUY && InpTraillingStep != 0)
         {
            double firstLockPrice = NormalizeDouble(openPrice + InpTraliingStart * Point + commFloor, digits);
            double trailPrice     = NormalizeDouble(Bid - InpTraillingStep * Point, digits);

            // First lock: cost floor (breakeven real = abertura + comissão)
            if((currentSL < openPrice || currentSL == 0) && Bid - (InpTraillingStep + InpTraliingStart) * Point >= openPrice + commFloor)
               m_trade.PositionModify(ticket, firstLockPrice, currentTP);

            // Subsequent steps: only move if above cost floor
            if(currentSL >= openPrice + commFloor && trailPrice > currentSL)
               m_trade.PositionModify(ticket, trailPrice, currentTP);
         }

         if(posType == POSITION_TYPE_SELL && InpTraillingStep != 0)
         {
            double firstLockPrice = NormalizeDouble(openPrice - InpTraliingStart * Point - commFloor, digits);
            double trailPrice     = NormalizeDouble(Ask + InpTraillingStep * Point, digits);

            if((currentSL > openPrice || currentSL == 0) && Ask + (InpTraillingStep + InpTraliingStart) * Point <= openPrice - commFloor)
               m_trade.PositionModify(ticket, firstLockPrice, currentTP);

            if(currentSL <= openPrice - commFloor && trailPrice < currentSL)
               m_trade.PositionModify(ticket, trailPrice, currentTP);
         }
      }
   }
}


//+------------------------------------------------------------------+
//| Lucro flutuante no par atual                                     |
//+------------------------------------------------------------------+
double Profit(int type)
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == sets.m_magic)
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL))
         {
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }
   }
   return profit;
}

//+------------------------------------------------------------------+
//| Lucro flutuante global na conta                                   |
//+------------------------------------------------------------------+
double ProfitAll(int type)
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == sets.m_magic)
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL))
         {
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }
   }
   return profit;
}

//+------------------------------------------------------------------+
//| AllLots - Soma de lotes por tipo                                 |
//+------------------------------------------------------------------+
double AllLots(int type)
{
   double lot = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == sets.m_magic)
      {
         long posType = PositionGetInteger(POSITION_TYPE);
         if(type == -1 || (type == 0 && posType == POSITION_TYPE_BUY) || (type == 1 && posType == POSITION_TYPE_SELL))
            lot += PositionGetDouble(POSITION_VOLUME);
      }
   }
   return lot;
}

//--- Timer
void OnTimer()
{
   m_framework.OnTimer();
   m_newsfilter.ReloadNews();
}

//+------------------------------------------------------------------+
//| TradeTransaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   //--- CExecution: confirma fill, mede slippage/latencia
   m_exec.ProcessTradeTransaction(trans, request, result);

//--- get transaction type as enumeration value 
   ENUM_TRADE_TRANSACTION_TYPE type=trans.type;
//--- if transaction is result of addition of the transaction in history
   if(type==TRADE_TRANSACTION_DEAL_ADD)
     {
      long     deal_ticket       =0;
      long     deal_order        =0;
      long     deal_time         =0;
      long     deal_time_msc     =0;
      long     deal_type         =-1;
      long     deal_entry        =-1;
      long     deal_magic        =0;
      long     deal_reason       =-1;
      long     deal_position_id  =0;
      double   deal_volume       =0.0;
      double   deal_price        =0.0;
      double   deal_commission   =0.0;
      double   deal_swap         =0.0;
      double   deal_profit       =0.0;
      string   deal_symbol       ="";
      string   deal_comment      ="";
      string   deal_external_id  ="";
      if(HistoryDealSelect(trans.deal))
        {
         deal_ticket       =HistoryDealGetInteger(trans.deal,DEAL_TICKET);
         deal_order        =HistoryDealGetInteger(trans.deal,DEAL_ORDER);
         deal_time         =HistoryDealGetInteger(trans.deal,DEAL_TIME);
         deal_time_msc     =HistoryDealGetInteger(trans.deal,DEAL_TIME_MSC);
         deal_type         =HistoryDealGetInteger(trans.deal,DEAL_TYPE);
         deal_entry        =HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
         deal_magic        =HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
         deal_reason       =HistoryDealGetInteger(trans.deal,DEAL_REASON);
         deal_position_id  =HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);

         deal_volume       =HistoryDealGetDouble(trans.deal,DEAL_VOLUME);
         deal_price        =HistoryDealGetDouble(trans.deal,DEAL_PRICE);
         deal_commission   =HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
         deal_swap         =HistoryDealGetDouble(trans.deal,DEAL_SWAP);
         deal_profit       =HistoryDealGetDouble(trans.deal,DEAL_PROFIT);

         deal_symbol       =HistoryDealGetString(trans.deal,DEAL_SYMBOL);
         deal_comment      =HistoryDealGetString(trans.deal,DEAL_COMMENT);
         deal_external_id  =HistoryDealGetString(trans.deal,DEAL_EXTERNAL_ID);
        }
      else
         return;
       if(deal_symbol==m_symbol.Name() && deal_magic==sets.m_magic)
          if(deal_entry==DEAL_ENTRY_IN)
             if(deal_type==DEAL_TYPE_BUY || deal_type==DEAL_TYPE_SELL)
               {
                 // CExecution handles fill confirmation internally
               }
     }
  }

//+------------------------------------------------------------------+
//| Refreshes the symbol quotes data                                 |
//+------------------------------------------------------------------+
bool RefreshRates(void)
  {
//--- refresh rates
   if(!m_symbol.RefreshRates())
      return(false);
//--- check for invalid price
   if(m_symbol.Ask()==0 || m_symbol.Bid()==0)
      return(false);
//---
   return(true);
  }

//+------------------------------------------------------------------+
//| Custom ATR - Cálculo puro sem indicador                          |
//+------------------------------------------------------------------+
double CustomATR(int atr_period, int shift=1)
{
   if(atr_period <= 0) return 0.0;
   
   double sum_tr = 0.0;
   int valid_bars = 0;
   
   for(int i = shift; i < shift + atr_period; i++)
   {
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      double l = iLow(_Symbol, PERIOD_CURRENT, i);
      double c = iClose(_Symbol, PERIOD_CURRENT, i + 1);
      
      if(h == 0 || l == 0 || c == 0) continue;
      
      double tr = MathMax(h - l, MathMax(MathAbs(h - c), MathAbs(l - c)));
      sum_tr += tr;
      valid_bars++;
   }
   
   return (valid_bars > 0) ? sum_tr / valid_bars : 0.0;
}

//+------------------------------------------------------------------+
//| Gera Magic Number Único por Conta, Ativo e Timeframe             |
//+------------------------------------------------------------------+
ulong AutoMagicID(string ea_name, string version="1.0")
{
   // Adicionamos o Account Login para garantir unicidade absoluta entre contas
   ulong accountLogin = (ulong)AccountInfoInteger(ACCOUNT_LOGIN);
   string key = ea_name + "|" + version + "|" + _Symbol + "|" + IntegerToString(_Period) + "|" + IntegerToString(accountLogin);
   
   ulong hash = 5381;
   for(int i = 0; i < StringLen(key); i++)
      hash = ((hash << 5) + hash) + StringGetCharacter(key, i);

   // Mantém o mask 0x7FFFFFFF para garantir que seja um inteiro positivo válido (max ~2.14 bilhões)
   return hash & 0x7FFFFFFF;
}

//+------------------------------------------------------------------+
//| Gera Comentário da Ordem com Dados do Regime (Anti-Compliance)   |
//+------------------------------------------------------------------+
string GenerateRegimeComment()
{
   // 1. Sufixo único da conta (últimos 4 dígitos do login)
   ulong accLogin = AccountInfoInteger(ACCOUNT_LOGIN);
   int uniqueSuffix = (int)(accLogin % 9999);
   
   // 2. Obter dados do regime no exato momento da entrada
   // NOTA: Substitua 'GetHurst()' e 'GetR2()' pelos nomes reais 
   // dos métodos públicos da sua classe CMacroRegimeEngine
   double hurstVal = m_regime.GetLastHurst();      // Ex: 0.522
   double r2Val    = m_regime.GetConfidence();     // Ex: 0.64
   
   // 3. Formatar para 2 casas decimais (economiza espaço e padroniza)
   string hStr = DoubleToString(hurstVal, 2);
   string rStr = DoubleToString(r2Val, 2);
   
   // 4. Montar string compacta e profissional (Ex: "QFX_H0.52_R20.64_8492")
   // StringFormat é mais seguro e rápido que concatenação com '+'
   return StringFormat("QFX_H%s_R%s_%04d", hStr, rStr, uniqueSuffix);
}


//+------------------------------------------------------------------+
//| Open positions - Versão limpa e integrada                        |
//+------------------------------------------------------------------+
void OpenPosition(const ENUM_POSITION_TYPE pos_type)
{
   if(!RefreshRates() || !m_symbol.Refresh())
      return;

   //--- StopsLevel
   double stop_level = m_symbol.StopsLevel() * m_symbol.Point();
   if(stop_level == 0.0)
      stop_level = (m_symbol.Ask() - m_symbol.Bid()) * 3.0;
   stop_level *= 1.1;

   //==============================================================
   // 1. Human Behavior
   //==============================================================
   m_human.NewTrade();

   if(m_human.ShouldSkipTrade())
   {
      return;
   }

   //==============================================================
   // 2. Lote
   //==============================================================
   double lots = GetLot();
   if(lots <= 0.0) return;

   //==============================================================
   // 3. Preço de entrada + Jitter
   //==============================================================
   double price = (pos_type == POSITION_TYPE_BUY) ? m_symbol.Ask() : m_symbol.Bid();
   price += m_human.GetEntryJitter();
   price = m_symbol.NormalizePrice(price);

   //==============================================================
   // 4. SL e TP
   //==============================================================
   double sl = GetStopLossPrice(pos_type, price, lots);
   double tp = m_tp.GetTakeProfitPrice(pos_type, price, sl);

   //--- Validação StopsLevel
   if(pos_type == POSITION_TYPE_BUY)
   {
      if(sl > 0.0 && (m_symbol.Bid() - sl) < stop_level)
         sl = m_symbol.Bid() - stop_level;
      if(tp > 0.0 && (tp - m_symbol.Bid()) < stop_level)
         tp = m_symbol.Bid() + stop_level;
   }
   else
   {
      if(sl > 0.0 && (sl - m_symbol.Ask()) < stop_level)
         sl = m_symbol.Ask() + stop_level;
      if(tp > 0.0 && (m_symbol.Ask() - tp) < stop_level)
         tp = m_symbol.Ask() - stop_level;
   }

   if(sl > 0.0) sl = m_symbol.NormalizePrice(sl);
   if(tp > 0.0) tp = m_symbol.NormalizePrice(tp);

   //==============================================================
   // 5. Delay humano
   //==============================================================
   m_human.SleepHuman();

   //==============================================================
   // 6. Envia ordem via CExecution (spread gate, retry, quality)
   //==============================================================
   bool result = false;

   if(pos_type == POSITION_TYPE_BUY)
      result = m_exec.Buy(lots, sl, tp, sets.m_comment);
   else
      result = m_exec.Sell(lots, sl, tp, sets.m_comment);

   if(result)
   {
      sets.m_last_trade_bar_time = iTime(_Symbol, _Period, 0);
   }
   else
   {
      Print("Falha ao enviar ordem. State: ", m_exec.StateToString());
   }
}
