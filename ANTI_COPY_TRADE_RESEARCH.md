# PROP FIRM COPY-TRADE DETECTION ANALYSIS

## COMMON DETECTION METHODS USED BY PROP FIRMS

1. **EXACT PRICE MATCHING** - Identical entry/exit prices within milliseconds
2. **TIMING CORRELATION** - Trades opened/closed within milliseconds of each other
3. **VOLUME CORRELATION** - Identical position sizes or proportional scaling
4. **STRATEGY FINGERPRINTING** - Identical SL/TP ratios, risk parameters, entry patterns
5. **SEQUENCE MATCHING** - Same sequence of trades across multiple accounts
6. **LATENCY PATTERNS** - Identical execution latency patterns
7. **RISK PARAMETER MATCHING** - Identical risk %, lot sizing formulas
8. **ORDER TYPE PATTERNS** - Same order types (market/limit/stop) in same sequence

## ANTI-DETECTION STRATEGIES (PROFESSIONAL APPROACHES)

### 1. PARAMETER RANDOMIZATION (Per Trade/Per Session)
- Entry price jitter: ±1-3 pips random offset
- SL/TP randomization: ±2-5 pips or ±5-15% of ATR
- Position size jitter: ±5-15% per trade
- PipsStep randomization: ±10-30% per session

### 2. TEMPORAL RANDOMIZATION
- Entry delay: 100-5000ms random delay before execution
- Order staggering: Multiple accounts stagger entries by 1-30 seconds
- Session-level randomization: New random seed per trading session

### 3. STRUCTURAL RANDOMIZATION
- SL/TP as ATR multiples with random coefficient (1.5-3.0)
- Dynamic risk% per trade (0.8%-1.2% of base risk)
- Variable lot step sizing
- Random SL/TP order (sometimes SL first, sometimes TP first)

### 4. BEHAVIORAL MIMICRY
- Human-like hesitation: Random 50-2000ms before order send
- Partial fills simulation: Split large orders into 2-3 smaller orders
- Random order type variation (Market vs Limit vs Stop)
- Simulated "hesitation" cancels/replaces

### 4. ACCOUNT-LEVEL DIFFERENTIATION
- Unique magic numbers per account
- Account-specific risk profiles
- Timezone-based session offsets
- Broker-specific spread/commission adjustments

## RISK FACTORS TO CONSIDER
- Over-randomization destroys edge
- Regulatory compliance (some prop firms prohibit intentional obfuscation)
- Execution quality degradation
- Backtesting complexity increases exponentially
- Correlation between randomized parameters must be maintained