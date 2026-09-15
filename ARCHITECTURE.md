# ARQUITETURA — ALXQuant

## Visão Geral

ALXQuant é uma plataforma quantitativa profissional "AI Native" que combina tecnologias Python avançadas e Expert Advisors MQL5 para um pipeline completo de negociação quantitativa, desde análise e estratégia até execução e análise pós-negociação.

## Arquitetura Geral

```
C:\ALXQuant
├── data/                    # Camada de dados centralizada (DuckDB)
│   ├── ALXQuantCore.duckdb   # Banco de dados columnar principal (138MB)
│   ├── datasets/             # CSVs OHLC brutos (M5)
│   ├── mql5/                 # Intercâmbio MQL5↔Python (CSVs canônicos do EA)
│   ├── miner/                # CSVs de miner (alpha_miner / DataMiner)
│   ├── report/               # PDFs de relatórios gerados
│   ├── cache/asset_dna/      # Cache joblib do asset_dna
│   └── image/                # Assets (logo)
├── Modulos/                # Módulos Python (estrutura principal)
│   ├── asset_dna/           # Perfilamento de ativos (HMM, Hurst, entropia, MI, TE)
│   ├── risk_sentiment/      # Análise macroeconômica PCA + sinal RORO
│   ├── alpha_miner/         # Mineração de alpha
│   ├── datahouse/           # Coleta e validação de dados
│   └── _old_not_used/       # Legado/deprecated
├── gui/                    # Backend web (FastAPI + HTML/CSS/JS)
│   └── html/                # Terminal Bloomberg-style com 10 endpoints
├── MQL5/                   # Código MQL5 (execução)
│   └── MQL5/               # Subpasta do MetaTrader
│       ├── Experts/        # Expert Advisors (EAQuant_v5, v6, v7, v8, EAQuantLab)
│       ├── Include/        # ALXQuantCore (RiskManager, Strategy, Execution)
│       ├── Indicators/     # Indicadores customizados
│       └── Scripts/        # Exemplos, testes e ferramentas de manutenção
└── Documentação/           # Arquivos de documentação e governança
```

## Princípios Arquiteturais

### Clean Architecture com Separação de Camadas
- **Domínio**: Lógica de negociação, gerenciamento de risco, modelos quant
- **Aplicação**: Orquestração, API, bridges Python↔MQL5
- **Apresentação**: Dashboard web, FastAPI, interfaces MQL5

### Alto Desacoplamento e Baixa Acoplamento
- Cada módulo independente com responsabilidades claras
- Interfaces bem definidas entre componentes
- Dependências apenas para baixo (ex: UseCases dependem de Domínio, não vice-versa)
- Testes unitários para componentes críticos

### Escalabilidade e Performance
- Design baseado em eventos para processamento assíncrono
- Pipelines processuais para workflows pesados
- Vetorização NumPy/Pandas para velocidade
- Numba para loops críticos
- DuckDB para armazenamento columnar multi-thread

### Atestabilidade e Auditoria
- Testes unitários para todos os componentes críticos
- Logs de auditoria completos para operações sensíveis
- Versionamento semântico com Git
- Documentação completa de APIs e componentes

## Camada de Dados (DuckDB)

### Arquitetura do Banco de Dados

```sql
-- Tabelas principais (fonte única de verdade)
CREATE TABLE ohlc_prices (
  symbol VARCHAR,
  timeframe VARCHAR,
  datetime DATETIME,
  open DOUBLE,
  high DOUBLE,
  low DOUBLE,
  close DOUBLE,
  volume DOUBLE,
  date_key INTEGER
);

CREATE TABLE risk_labels (
  id INTEGER PRIMARY KEY,
  symbol VARCHAR,
  datetime DATETIME,
  timeframe VARCHAR,
  roro_score DOUBLE,
  vix DOUBLE,
  dxy DOUBLE,
  spx DOUBLE,
  date_key INTEGER
);

CREATE TABLE macro_series (
  symbol VARCHAR,
  date_key INTEGER,
  value DOUBLE
);

CREATE TABLE macro_catalog (
  symbol VARCHAR,
  name VARCHAR,
  description TEXT
);

CREATE TABLE calendar_events (
  date_key INTEGER,
  impact VARCHAR,
  country VARCHAR,
  event VARCHAR,
  previous DOUBLE,
  forecast DOUBLE,
  actual DOUBLE
);

-- Views para consultas analíticas
CREATE VIEW v_risk_sentiment AS
SELECT 
  symbol,
  datetime,
  timeframe,
  roro_score,
  vix,
  dxy,
  spx
FROM risk_labels
WHERE datetime >= CURRENT_DATE - INTERVAL '30 days';

CREATE VIEW v_macro_status AS
SELECT 
  date_key,
  SUM(CASE WHEN symbol = 'VIX' THEN value END) / COUNT(*) as avg_vix,
  SUM(CASE WHEN symbol = 'DXY' THEN value END) / COUNT(*) as avg_dxy,
  SUM(CASE WHEN symbol = 'SPX' THEN value END) / COUNT(*) as avg_spx
FROM macro_series
WHERE date_key >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY date_key;
```

### Fluxo de Dados

1. **Coleta**
   - MT5 → CSVs OHLC brutos (datasets/)
   - FRED/Yahoo Finance → CSVs macroeconômicos (miner/)
   - Validação e transformação em pipelines Python
   - Inserção no DuckDB com controles de concorrência

2. **Processamento**
   - Asset DNA: HMM, Hurst, entropia, Transfer Entropy, Wavelet
   - Risk Sentiment: PCA + sinal RORO
   - Alpha Research: Engine de fatores
   - Backtest: Walk-Forward, Monte Carlo, custos realistas

3. **Intercâmbio MQL5↔Python**
   - risk_sentiment_daily.csv, Calendar.csv sincronizados para data/mql5/
   - asset_profile_<SYM>_<TF>.json gerado para Strategy Tester
   - FileReader.mqh para bypass de sandbox MQL5
   - Commands unificadas para MT5 e Strategy Tester

4. **Análise e Relatórios**
   - Visualização Bloomberg-style no dashboard web
   - PDFs gerados para research alpha/ghost
   - Health checks multi-domínio
   - Monitoring e alertas

## Camada de Software Python

### Pipeline Asset DNA

```python
# Pipeline de perfilamento de ativos institucional
AssetDNAEngine(
    hmm_params={"n_components": 10, "max_iter": 1000},
    hurst_params={"window": 252},
    entropy_params={"window": 64},
    transfer_entropy_params={"window": 128},
    wavelet_params={"wavelet": "db4", "level": 5}
)
```

### Pipeline Risk Sentiment

```python
# Análise de sentimento e risco macro
RiskSentimentEngine(
    pca_components=3,
    fred_symbols=["VIX", "DXY", "SPX"],
    yahoo_symbols=["VIX", "DXY", "SPX"],
    lookback_days=252
)
```

### Pipeline Alpha Research

```python
# Engine de fatores institucionais
AlphaResearchEngine(
    factor_universes=["Momentum", "Value", "Size", "Quality"],
    lookback_months=60,
    forward_months=12,
    transaction_costs=0.0001,
    slippage_model="volume_adjusted"
)
```

## Camada MQL5

### Arquitetura ALXQuantCore

```
MQL5/MQL5/Include/ALXQuantCore/
├── Core/                     # Fundamentos e utilitários
│   ├── RiskManager.mqh      # Gestão de risco (daily/monthly loss, trailing DD)
│   ├── Execution.mqh        # Order execution (retry, slippage tracking)
│   ├── Strategy.mqh         # Estratégias quant
│   └── Design.mqh           # Design patterns e utilitários
├── Modules/                  # Módulos de especialidade
│   ├── RiskManager.mqh      # Gestão avançada de risco
│   ├── RiskSentiment.mqh    # Filtro de sentimento de mercado
│   ├── Timefilter.mqh       # Filtro de horário + notícias
│   ├── MacroRegimeEngine.mqh # Engine de regime de mercado
│   ├── Execution.mqh        # Implementação de execução
│   └── PositionSizing.mqh   # Algoritmos de sizing
└── Strategy/                # Estratégias específicas
    ├── TrendFollowing.mqh
    ├── MeanReversal.mqh
    ├── Breakout.mqh
    └── GoldRush.mqh
```

### Componentes Principais

#### RiskManager
- Gestão completa de risco multi-janel
- Daily/monthly profit/loss limits com modo $/% unificado
- Trailing Max Drawdown real (2-Step FTMO)
- Consistency window eGerenciamento de condições de bloqueio

#### CExecution
- Validação de volume/margem robusta
- Retry automático com tracking de slippage
- Controle de posição com modificação em tempo real
- Gerenciamento de estado e retry de operações

#### CTimefilter
- Filter de horário (sessions, Christmas, etc.)
- News filter com Calendar.csv do Python
- Support para Strategy Tester e live trading
- Loading otimizado de CSV via FileReader.mqh

#### CMacroRegimeEngine
- DFA baseado em HMM para regime de mercado
- Detecção de caos e breakout regimes
- Momentum e análise de VWAP
- High/low regime detection

## Camada Web (FastAPI)

### Arquitetura do Backend

```python
# FastAPI com arquitetura CQRS
app = FastAPI(title="ALXQuant Terminal", version="1.0.0")

# Commandes (escrita)
@app.post("/api/strategy-tester/prepare")
async def prepare_strategy_tester(request: StrategyTesterCommand):
    # Gera CSVs necessários para EA no Strategy Tester

@app.post("/api/asset-dna/run")
async def run_asset_dna(request: AssetDNACommand):
    # Executa pipeline completo de Asset DNA

# Queries (leitura)
@app.get("/api/market/data")
async def get_market_data(symbol: str, timeframe: str, start: datetime, end: datetime):
    # Retorna dados do DuckDB para gráficos

@app.get("/api/risk-sentiment/status")
async def get_risk_sentiment_status():
    # Retorna status atual de risco e sentimento
```

### Frontend (HTML/CSS/JS)

- Terminal Bloomberg-style com layout multi-pane
- Gráficos OHLC interativos (Plotly.js)
- Watchlist gerenciável e widgets de análise
- WebSockets para streaming de dados em tempo real
- Alerts e notificações em tempo real

## Padrões Arquiteturais

### 1. Clean Architecture
- Separação clara entre camadas de domínio, aplicação e apresentação
- Testes unitários para componentes críticos
- Mock completo para componentes externos
- Controladores não conhecem frameworks UI

### 2. CQRS
- Commands para operações de escrita
- Queries para operações de leitura
- Histórico de comandos para undo/redo
- Validação estrita de entradas

### 3. Event-Driven
- Comunicação assíncrona entre módulos
- Pipelines processuais para workflows pesados
- Channels para streaming em tempo real
- Replicas para tolerância a falhas

### 4. Repository Pattern
- Abstração de acesso a dados
- Queries otimizadas e paginadas
- Controle de concorrência integrado
- Transações supportadas

### 5. Strategy Pattern
- Estratégias de negociação plugáveis
- Interchangeable risk management strategies
- Configurable execution handlers
- Strategy composition e inheritance

## Fluxo Típico de Desenvolvimento

### 1. Análise
- Garante aderência aos requisitos Quant e AI Native
- Identifica todos os impactos no sistema
- Avalia riscos técnicos e de negócio
- Garante conformidade com padrões de qualidade

### 2. Planejamento
- Define escopo e marcos de entrega
- Aloca tarefas para especialidades
- Garante recursos e dependências
- Define critérios de aceitação

### 3. Implementação
- Codifica seguindo padrões Quant e AI Native
- Implementa testes unitários e de integração
- Garante documentação completa
- Realiza code review completo

### 4. Validação
- Executa suite completa de testes
- Realiza integração e testes E2E
- Valida conformidade com padrões
- Garante performance e escalabilidade

### 5. Implantação
- Atualiza versionamento semântico
- Garante conformidade com AI Native
- Valida rollout em ambiente de produção
- Monitora métricas e health checks

## Decisões Arquiteturais Chave

### 1. Escolha do DuckDB
- **Motivo**: Armazenamento columnar, multi-threaded, 88% menor que SQLite
- **Vantagens**: Queries analíticas rápidas, compressão eficiente, API Python robusta
- **Considerações**: Não supporta transações completas, pode não ser ideal para alta concorrência

### 2. FileReader.mqh
- **Motivo**: Bypassar sandbox do MQL5 para Strategy Tester
- **Vantagens**: Leitura direta de CSV, suporte para UTF-8, performance melhor que FILE_COMMON
- **Considerações**: Segurança limitada, dependência em ambiente Windows

### 3. Event-Driven Design
- **Motivo**: Requer pipelines assíncronos para ML e análise pesada
- **Vantagens**: Escalabilidade horizontal, baixa latência, tolerância a falhas
- **Considerações**: Mais complexo de implementar e debugar

### 4. Clean Architecture
- **Motivo**: Garante testabilidade e manutenibilidade a longo prazo
- **Vantagens**: Aderência a SOLID, isolation de dependências, fácil refatoração
- **Considerações**: Mais sobre-Engenharia, overhead inicial maior

## Integração e Interoperabilidade

### Módulos Python ↔ MQL5

1. **Sincronização de Dados**
   - risk_sentiment_daily.csv: engine.py → DuckDB → data/mql5/
   - Calendar.csv: risk_sentiment/engine.py → DuckDB → data/mql5/
   - Asset profile: asset_dna_full.py → DuckDB → data/mql5/

2. **Bridge de Estratégia**
   - RiskManager.mqh lido via FileReader.mqh
   - Timefilter.mqh para news e horário
   - JsonParser.mqh para asset profiles
   - AssetProfileLoader.mqh para loading dinâmico

3. **Integration Points**
   - Health checks para cada componente
   - Logs unificados para debugging
   - Métricas de performance para monitoramento
   - Rollback automático para falhas

### Frontend ↔ Backend

1. **WebSockets**
   - Updates em tempo real para gráficos
   - Streaming de mercado e indicadores
   - Alertas e notificações push

2. **REST APIs**
   - Endpoints unificados para todas as operações
   - Autenticação e autorização robustas
   - Validation estrita de entradas
   - Documentação OpenAPI gerada automaticamente

3. **Cache e CDN**
   - Gráficos estáticos para performance
   - Updates incrementais para dados em tempo real
   - Cache multi-camada para assets estáticos

## Planejamento de Evolução

### Próximos 6 Meses
- Add reinforcement learning para otimização de portfólio
- Implementar pipeline completo de risco baseado em IA
- Expandir para mercados alternativos (cryptos, futures)

### 6-12 Meses
- Add computação quântica híbrida para otimização
- Implementar análise de sentiment multi-modal
- Deploy completo para nuvem multi-região

### 1-2 Anos
- Add AGI quant-native para descoberta autônoma de estratégias
- Implementar consciousness completo do sistema
- Expandir para classes de ativos alternativos (NFT, gaming)

## Garantias de Qualidade

### Arquitetura
- Revisão completa de arquitetura antes da implementação
- Validação de design patterns e principios
- Verificação de escalabilidade e performance
- Garante aderência a padrões Quant e AI Native

### Código
- Code review obrigatório para todas as mudanças
- Pipelines de teste automatizados e completos
- Verificação de qualidade de código com ferramentas estáticas
- Security scanning para vulnerabilidades

### Documentação
- Garante documentação 100% completa para todos os componentes
- Documentação de decisões arquiteturais e escolhas
- Garante versionamento semântico completo
- Garante convenções de nomenclatura consistentes

### Performance
- Testes de performance para componentes críticos
- Garante limites de uso de memória
- Garante tempo de resposta para APIs críticas
- Garante escalabilidade para carga de trabalho esperada

### Segurança
- Validação estrita de todas as entradas
- Auditoria completa de operações críticas
- Security scanning contínuo
- Garante separação de dados sensíveis

Este arquivo define a arquitetura detalhada de ALXQuant, mostrando como os componentes se integram, fluiem dados, e garantem qualidade, performance e segurança.