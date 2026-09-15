# ALXQuant.codebase.md

## Visão Geral

O ALXQuant é um sistema quantitativo de trading com uma arquitetura híbrida Python+MQL5. A estrutura atual mostra que o projeto passou por uma reorganização significativa, com componentes Python movidos para `Modulos/` e componentes MQL5 mantidos em `MQL5/MQL5/`.

## Objetivo do Projeto

Desenvolver um sistema de trading quantitativo robusto e compliance-ready que:
- Implementa estratégias de negociação baseadas em evidências institucionais
- Garante conformidade com regras de prop-firms (FTMO, MFF)
- Integra análise de ativos em tempo real com execução automatizada
- Oferece monitoramento em tempo real através de um terminal profissional estilo Bloomberg

## Arquitetura Geral

A arquitetura atual segue um modelo de módulos de dados unificados:

```
C:\ALXQuant
├── data\                    # Camada de dados centralizada (DuckDB)
│   └── ALXQuantCore.duckdb  # Banco de dados columnar principal (138MB)
├── gui\                     # Backend web (FastAPI + HTML/CSS/JS)
│   └── html\
│       ├── serve.py         # Backend FastAPI com 10 endpoints
│       ├── dashboard.html   # Template do terminal
│       ├── css\ e js\       # Frontend
├── MQL5\                    # Código MQL5 (execução)
│   └── MQL5\                # Subpasta do MetaTrader
│       ├── Experts\         # Expert Advisors
│       ├── Include\         # ALXQuantCore (RiskManager, Strategy, Execution)
│       └── Indicators\      # Indicadores customizados
└── Modulos\                 # Módulos Python (reorganizados)
    ├── datahouse\           # banco de dados central duckdb (datasets, macro_asset, risk_sentiment)
    ├── asset_dna\           # Perfilamento de ativos (HMM, entropia, MI, TE)
    ├── risk_sentiment\      # Análise macroeconômica PCA
    └── __init__.py          # Pacote Python
└── Arquivos de apoio (raiz)
    ├── config.py\           # Configurações
    ├── config.json\         # Versões cruzadas
    ├── CHANGELOG_MQL.md\    # Changelog MQL5 (512 linhas)
    ├── CHANGELOG_PYTHON.md  # Changelog Python (1623 linhas)
    ├── README.md\           # Visão geral (512 linhas)
    ├── CONTEXT.md\          # Contexto de análise
    └── AGENTS.md\           # Diretrizes de desenvolvimento
```

## Fluxo Completo dos Dados

### Pipeline Atual (Rastreável):

1. **Banco de Dados**: `data/ALXQuantCore.duckdb` (138MB) - Fonte única de verdade
2. **Backend Web**: `gui/html/serve.py` - FastAPI com 10 endpoints
3. **Execução MQL5**: `MQL5/MQL5/Experts/` - Expert Advisors para MetaTrader 5

### Módulos Python (Atualmente em `Modulos/`):

#### Asset DNA (Python)
- **Objetivo**: Perfil de ativos institucionais com ML/HMM
- **Arquivos**: `Modulos/asset_dna/asset_dna.py`, `asset_dna_full.py`, `asset_dna_v7_fast.py`
- **Legado**: `Modulos/asset_dna/__old/` - Versões anteriores (profiler_v3-v7)

#### Risk Sentiment (Python)
- **Objetivo**: Análise macroeconômica PCA + sinal RORO
- **Arquivos**: `Modulos/risk_sentiment/engine.py`, `migrate.py`
- **Funcionalidade**: engine.py coleta FRED/Yahoo → PCA → roro_score

#### Legacy/Migration Modules:
- **Alpha Miner**: `Modulos/alpha_miner/alpha_miner.py`
- **Alpha Research**: `Modulos/_old_not_used/alpha_research.py`
- **Asset DNA Profiler**: `Modulos/_old_not_used/asset_dna_profiler.py`
- **Risk Sentiment Dataset**: `Modulos/_old_not_used/build_risk_sentiment_dataset.py`
- **MT5 Collector**: `Modulos/_old_not_used/coletor_mt5.py`
- **Dashboard**: `Modulos/_old_not_used/dashboard.py`
- **Diagnostics**: `Modulos/_old_not_used/diagnose_csv.py`

## Tecnologias

### Backend Web (FastAPI)
- **Framework**: FastAPI (10 endpoints)
- **Frontend**: HTML/CSS/JS (terminal Bloomberg-style)
- **Database**: DuckDB (via queries no backend)

### Código MQL5
- **MetaTrader 5 Expert Advisor**
- **Estratégias**: Diversas implementadas em Experts
- **Compliance**: RiskManager completo (daily/monthly loss, trailing DD, consistency)
- **Execução**: CExecution (validação, retry, slippage tracking)

## Banco de Dados

### DuckDB Principal
- **Arquivo**: `data/ALXQuantCore.duckdb` (138MB, columnar, multi-threaded)
- **Tabelas**: 5 tabelas (2.4M ohlc_prices, 785 risk_labels, 132K macro_series, 58 macro_catalog, 98K calendar_events)
- **Views**: 4 views (v_risk_sentiment, v_macro_status, v_calendar_status, v_risk_status)

## Arquivos Importantes

### Críticos (Raramente mudar):
- **`data/ALXQuantCore.duckdb`** - Banco de dados DuckDB principal (138MB)
- **`gui/html/serve.py`** - Backend FastAPI (conforme com v5.23.0)
- **`MQL5/MQL5/Experts/`** - Expert Advisors para MetaTrader 5
- **`MQL5/MQL5/Include/ALXQuantCore/`** - Core MQL5 modules

### Configuration e Documentation:
- **`config.py`** - Configurações (MT5, API, FRED, Trading, News)
- **`config.json`** - Versões cruzadas (v7.12.0 EA, v7.2.1 Python)
- **`CHANGELOG_MQL.md`** - Histórico MQL5 (512 linhas)
- **`CHANGELOG_PYTHON.md`** - Histórico Python (1623 linhas)
- **`README.md`** - Visão geral (512 linhas)

## Arquitetura Atual Análise

### Componentes Web/Frontend:
- **FastAPI Backend** (`gui/html/serve.py`): Backend web com 10 endpoints
- **Terminal Bloomberg-style**: Interface web para monitoramento e gerenciamento
- **Frontend Assets**: CSS/JS para interface de usuário

### Componentes MQL5:
- **Experts Directory**: Contém Expert Advisors:
  - `EAQuant_v5/` - Principal Expert Advisor (v6.1.0)
  - Outros EAs em diretórios `__backup/` (legados, versões anteriores)
- **Include/ALXQuantCore**: Core MQL5 modules:
  - RiskManager.mqh - Gestão de risco
  - Execution.mqh - Order execution
  - Strategy.* - Várias estratégias
  - Core modules (Design.mqh, enums.mqh, Timefilter.mqh, etc.)

### Módulos Legados/Migration:
- **`Modulos/`**: Diretório reorganizado para módulos Python
- **`__old/`**: Versões anteriores (profiler_v3-v7 para Asset DNA)
- **`_old_not_used/`**: Módulos legados (alpha_miner, asset_dna_profiler, etc.)

## Conclusão

O ALXQuant está atualmente em um estado de transição arquitetônica. Os componentes Python principais foram movidos para `Modulos/` diretório, com uma estrutura reorganizada que mantém os componentes essenciais:

1. **Camada de dados**: DuckDB como fonte única de verdade
2. **Camada web**: FastAPI backend com terminal estilo Bloomberg
3. **Camada MQL5**: Expert Advisors com compliance e execução

O projeto mantém sua estrutura essencial, mas passou por uma reestruturação significativa, com módulos Python reorganizados e componentes legados migrados para diretórios `_old/` e `_old_not_used/`.

---

**Resumo**:
- **Arquitetura atual**: Sistema híbrido Python+MQL5 com camada web FastAPI no centro
- **Componentes principais disponíveis**: DuckDB, FastAPI backend, MQL5 Experts, Legacy modules
- **Arquivos analisados**: 30+ (configuração, documentação, banco de dados, código)
- **Pontos que precisam ser documentados manualmente**: Histórico completo das versões Python (changelogs 1623 linhas), details dos módulos Asset DNA, Risk Sentiment, Alpha Mining, Alpha Research

**Status Atual**: Projeto em transição/reorganização arquitetônica - componentes Python movidos para Modulos/, mantendo funcionalidade essencial intacta.
