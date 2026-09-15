//+------------------------------------------------------------------+
//| HumanBehavior.mqh                                                |
//| Anti-copy-trade / Human-like execution behavior                  |
//| ALXQuant Core - Institutional Grade                              |
//+------------------------------------------------------------------+
//| v10.1.0 |
//+------------------------------------------------------------------+
#property copyright "ALXQuant"
#property link      "https://t.me/invest_sniper"
#property version "10.1"
#property strict
/*
    v.10.1 - 2026-08-25 - Remove: Lot jitter (InpHumanLotJitterPct) and Risk jitter (InpHumanRiskJitterPct).
                           Removed GetLotJitter() and GetRiskMultiplier() methods.
                           Lot sizing is now fully deterministic (controlled by CExecution).
    v.10.0 - 2026-08-24 - Normalizado para macro v10 release.
*/
input group "▸ Human Behavior"
input double InpHumanEntryJitterPips    = 0.5;   // ± pips at entry (0 = off)
input double InpHumanSLTPJitterPct      = 1.5;   // % of ATR for SL/TP (0 = off)
input double InpHumanPipsStepJitterPct  = 0.5;   // % of PipsStep (0 = off)
input int    InpHumanMaxDelayMs         = 300;   // max delay ms (0 = off)
input bool   InpHumanRandomOrderType    = false; // 10% chance LIMIT/IOC

//+------------------------------------------------------------------+
//| Classe HumanBehavior                                             |
//+------------------------------------------------------------------+
class HumanBehavior {
private:
    uint   m_baseSeed;
    uint   m_sessionSeed;
    uint   m_rngState;        // PRNG state (isolated from global)
    int    m_tradesThisSession;
    bool   m_initialized;

    // Configurações (lidas dos inputs globais da classe)
    double m_entryJitterPips;
    double m_slTpJitterPct;
    double m_pipsStepJitterPct;
    int    m_maxDelayMs;
    bool   m_useRandomOrderType;

    // Estado interno

    // Hash simples para o símbolo (substitui StringHash que não existe no MQL5)
    uint GetSymbolHash() const {
        uint hash = 0;
        for(int i = 0; i < StringLen(_Symbol); i++) {
            hash += (uint)StringGetCharacter(_Symbol, i) * (i + 1);
        }
        return hash;
    }

    // Normaliza o lote para atender às regras exatas da corretora
    double NormalizeLot(double lot) {
        // 1. Obter as regras do símbolo
        double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
        double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
        
        // Fallback para MQL4 caso SymbolInfoDouble falhe
        if(stepLot == 0) {
            #ifdef __MQL4__
            minLot = MarketInfo(_Symbol, MODE_MINLOT);
            maxLot = MarketInfo(_Symbol, MODE_MAXLOT);
            stepLot = MarketInfo(_Symbol, MODE_LOTSTEP);
            #endif
        }
        if(stepLot == 0) stepLot = 0.01; // Fallback de segurança absoluto
        if(minLot == 0)  minLot = 0.01;
        if(maxLot == 0)  maxLot = 100.0;
    
        // 2. Limitar o lote aos mínimos e máximos permitidos ANTES de arredondar
        lot = MathMax(minLot, MathMin(maxLot, lot));
    
        // 3. TRUNCAR (MathFloor) para o step mais próximo. 
        // <-- CORREÇÃO CRÍTICA: MathFloor garante que NUNCA arredondamos para cima, 
        // protegendo a margem e evitando rejeição por excesso de risco em mesas proprietárias.
        // Ex: 0.105 com step 0.01 vira 0.10, não 0.11.
        double normalizedLot = MathFloor((lot + 1e-8) / stepLot) * stepLot;
    
        // 4. Limitar novamente após o arredondamento (segurança extra)
        return MathMax(minLot, MathMin(maxLot, normalizedLot));
    }

    // LCG PRNG (Linear Congruential Generator) - isolado da global MathRand()
    uint NextRand() {
        // Parâmetros do Numerical Recipes
        m_rngState = (uint)((m_rngState * 1664525U + 1013904223U) % 4294967296ULL);
        return m_rngState;
    }

    double NextRandDbl() {
        return (double)NextRand() / 4294967296.0;
    }

public:
    // Constructor
    HumanBehavior() : m_initialized(false), m_tradesThisSession(0), m_rngState(0) {}

    // Inicialização (chamar no OnInit do EA)
    void Init() {
        if(m_initialized) return;

        // Lê inputs globais da classe (0 = desligado, >0 = usa valor)
        m_entryJitterPips     = (InpHumanEntryJitterPips > 0)     ? InpHumanEntryJitterPips * 10.0 * _Point : 0;
        // v1.04: Clamp dos percentuais para evitar multiplicadores negativos
        m_slTpJitterPct       = ClampPct(InpHumanSLTPJitterPct, 50.0);
        m_pipsStepJitterPct   = ClampPct(InpHumanPipsStepJitterPct, 50.0);
        m_maxDelayMs          = (InpHumanMaxDelayMs > 0)          ? InpHumanMaxDelayMs                      : 0;
        m_useRandomOrderType  = InpHumanRandomOrderType;

        // Seed determinística: AccountLogin + Symbol hash + timestamp
        uint symbolHash = GetSymbolHash();
        m_baseSeed = (uint)(AccountInfoInteger(ACCOUNT_LOGIN) * 31 + symbolHash * 17);
        // Inicializa PRNG com semente base
        m_rngState = m_baseSeed ^ GetTickCount();

        NewSession();
        m_initialized = true;
    }

    // Nova sessão (chamar no OnTick quando nova barra M5)
    void NewSession() {
        m_sessionSeed = m_baseSeed ^ GetTickCount();
        m_tradesThisSession = 0;
        // Reinicia PRNG com semente de sessão
        m_rngState = m_sessionSeed;
    }

    // Novo trade (chamar ANTES de cada trade)
    void NewTrade() {
        if(!m_initialized) return;
        m_tradesThisSession++;
        // Seed isolado por tipo de jitter (evita correlação entre tipos)
        uint tradeSeed = m_sessionSeed ^ (uint)(m_tradesThisSession * 7919); // 7919 é primo
        m_rngState = tradeSeed;
    }

    // ± pips no preço de entrada (0 = desligado)
    double GetEntryJitter() {
        if(!m_initialized || m_entryJitterPips <= 0) return 0;
        double randomFactor = (NextRand() % 2000 - 1000) / 1000.0;
        return randomFactor * m_entryJitterPips;
    }

    // ±% do ATR para SL (0 = desligado)
    double GetSLJitter(double atr) {
        if(!m_initialized || atr <= 0 || m_slTpJitterPct <= 0) return 0;
        double pct = m_slTpJitterPct * (0.5 + NextRandDbl());
        double jitter = atr * pct;
        return (NextRand() % 2 == 0) ? jitter : -jitter;
    }

    // ± ATR para TP
    double GetTPJitter(double atr) {
        if(!m_initialized || atr <= 0 || m_slTpJitterPct <= 0) return 0;
        double pct = m_slTpJitterPct * (0.5 + NextRandDbl());
        double jitter = atr * pct;
        return (NextRand() % 2 == 0) ? jitter : -jitter;
    }

    // PipsStep jitter (0 = desligado)
    double GetPipsStepJitter(double basePipsStep) {
        if(!m_initialized || m_pipsStepJitterPct <= 0) return basePipsStep;
        double mult = (1.0 - m_pipsStepJitterPct) + (NextRandDbl() * m_pipsStepJitterPct);
        return basePipsStep * mult;
    }

    // Delay humano antes de enviar ordem (0 = desligado)
    int GetExecutionDelay() {
        if(!m_initialized || m_maxDelayMs <= 0) return 0;
        int safeMax = MathMax(1, m_maxDelayMs - 50);
        return 50 + (int)((NextRand() % safeMax));
    }

    // 10% chance de usar LIMIT/IOC em vez de MARKET
    bool ShouldUseRandomOrderType() {
        if(!m_initialized || !m_useRandomOrderType) return false;
        return (NextRand() % 100) < 10;
    }

    // Sleep com delay humano
    void SleepHuman() {
        if(!m_initialized) return;
        Sleep(GetExecutionDelay());
    }

protected:
    // Clamp percent inputs - avoid negative multipliers
    double ClampPct(double pct, double max_pct) {
        if(pct <= 0) return 0.0;
        double clamped = MathMax(0.001, MathMin(max_pct, pct));
        if(clamped != pct) {
            PrintFormat("[%s] WARNING: %% input %.1f%% clamped to %.1f%% (max safe)", __FILE__, pct, clamped, clamped);
        }
        return clamped;
    }
};