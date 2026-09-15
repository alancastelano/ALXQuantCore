//+------------------------------------------------------------------+
//| HumanBehavior.mqh  v10.3.0                                       |
//| Foco: Entry + Delay + Hesitação (SL/TP agora são determinísticos)|
//+------------------------------------------------------------------+
#property copyright "ALXQuant"
#property version   "10.3"

input group "▸ Human Behavior"
input double InpHumanEntryJitterPips = 0.9;   // ± pips no preço de entrada (0 = off)
input int    InpHumanMinDelayMs      = 150;   // delay mínimo (ms)
input int    InpHumanMaxDelayMs      = 750;   // delay máximo (ms)
input double InpHumanSkipTradeChance = 4;     // % chance de pular o trade
input bool   InpHumanRandomOrderType = false; // chance de usar LIMIT/IOC

class CHumanBehavior
{
private:
   uint   m_baseSeed;
   uint   m_sessionSeed;
   uint   m_rngState;
   int    m_tradesThisSession;
   bool   m_initialized;

   double m_entryJitterPips;
   int    m_minDelayMs;
   int    m_maxDelayMs;
   double m_skipTradeChance;
   bool   m_useRandomOrderType;

   uint GetSymbolHash() const
   {
      uint hash = 0;
      for(int i = 0; i < StringLen(_Symbol); i++)
         hash += (uint)StringGetCharacter(_Symbol, i) * (i + 1);
      return hash;
   }

   uint NextRand()
   {
      m_rngState = (uint)((m_rngState * 1664525U + 1013904223U) % 4294967296ULL);
      return m_rngState;
   }

   double NextRandDbl()
   {
      return (double)NextRand() / 4294967296.0;
   }

public:
   CHumanBehavior() : m_initialized(false), m_tradesThisSession(0), m_rngState(0) {}

   void Init()
   {
      if(m_initialized) return;

      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      m_entryJitterPips = (InpHumanEntryJitterPips > 0) ? InpHumanEntryJitterPips * point * 10.0 : 0.0;

      m_minDelayMs        = MathMax(0, InpHumanMinDelayMs);
      m_maxDelayMs        = MathMax(m_minDelayMs, InpHumanMaxDelayMs);
      m_skipTradeChance   = MathMax(0.0, MathMin(20.0, InpHumanSkipTradeChance));
      m_useRandomOrderType= InpHumanRandomOrderType;

      uint symbolHash = GetSymbolHash();
      m_baseSeed = (uint)(AccountInfoInteger(ACCOUNT_LOGIN) * 31 + symbolHash * 17);
      m_rngState = m_baseSeed ^ GetTickCount();

      NewSession();
      m_initialized = true;
   }

   void NewSession()
   {
      m_sessionSeed = m_baseSeed ^ GetTickCount();
      m_tradesThisSession = 0;
      m_rngState = m_sessionSeed;
   }

   void NewTrade()
   {
      if(!m_initialized) return;
      m_tradesThisSession++;
      m_rngState = m_sessionSeed ^ (uint)(m_tradesThisSession * 7919);
   }

   // Chance de hesitar e não enviar a ordem
   bool ShouldSkipTrade()
   {
      if(!m_initialized || m_skipTradeChance <= 0) return false;
      return (NextRandDbl() * 100.0) < m_skipTradeChance;
   }

   // Jitter no preço de entrada
   double GetEntryJitter()
   {
      if(!m_initialized || m_entryJitterPips <= 0) return 0.0;
      if(NextRandDbl() < 0.18) return 0.0; // 18% de chance de não aplicar

      double factor = (NextRandDbl() * 2.0) - 1.0; // -1.0 ~ +1.0
      return factor * m_entryJitterPips;
   }

   int GetExecutionDelay()
   {
      if(!m_initialized || m_maxDelayMs <= 0) return 0;
      int range = m_maxDelayMs - m_minDelayMs;
      if(range <= 0) return m_minDelayMs;
      return m_minDelayMs + (int)(NextRand() % (range + 1));
   }

   bool IsInitialized() const { return m_initialized; }

   bool ShouldUseRandomOrderType()
   {
      if(!m_initialized || !m_useRandomOrderType) return false;
      return (NextRand() % 100) < 8;
   }

   void SleepHuman()
   {
      if(!m_initialized) return;
      Sleep(GetExecutionDelay());
   }
};