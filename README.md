# ALXQuant v10.3.3

Sistema quantitativo de trading com integração Python nativa e DuckDB central.

**Plataforma:** `v10.3.3` | **Contrato binário:** `policy_bin` format 10000 | **Compatibilidade:** Major 10 alinhado (MQL5 + Python)

## Arquitetura

```
C:\ALXQuant
├── app/                    # Código Python (brain do sistema)
│   ├── asset_dna/          # Perfilamento de ativos (HMM, entropia, MI, TE)
│   ├── backtest/           # Motor de backtest com Walk-Forward + Monte Carlo
│   ├── data_housing/       # Coleta, validação, scheduler de dados (Datahouse)
│   ├── db/                 # Camada de dados (DuckDB)
│   ├── risk_sentiment/     # Análise de sentimento e risco macro
│   ├── alpha_research.py   # Pesquisa alpha
│   └── dashboard.py        # Dashboard interativo (legado Streamlit)
├── gui/
│   └── html/               # Terminal Bloomberg-style (FastAPI + HTML/CSS/JS)
│       ├── serve.py        # Backend FastAPI com 10 endpoints
│       ├── dashboard.html  # Template do terminal
│       ├── css/alxquant.css
│       └── js/alxquant.js
├── MQL5/MQL5/              # Código MQL5 (execução)
│   ├── Experts/
│   │   └── EAQuant/        # EAs canônicos (4) + __backup/ (árvores arquivadas)
│   ├── Include/
│   │   └── ALXQuantCore/   # Core MQL5 (RiskManager, Strategy, Execution) - fonte única
│   └── Indicators/
│       └── ALXQuantCore/   # Indicadores customizados
└── data/                    # Dados centralizados (Datahouse)
    ├── ALXQuantCore.duckdb   # Único banco de dados central
    ├── datasets/             # CSVs OHLC brutos (M5)
    ├── mql5/                 # Intercâmbio MQL5↔Python (CSVs canônicos do EA)
    ├── miner/                # CSVs de miner (alpha_miner / DataMiner)
    ├── report/               # PDFs de relatórios gerados
    ├── cache/asset_dna/      # Cache joblib do asset_dna
    └── image/                # Assets (logo)
```

## Stack

- **Python 3.14**: DuckDB, NumPy, Pandas, Scikit-learn, HMMLearn, Numba
- **MQL5**: MetaTrader 5 Expert Advisor com 10+ estratégias
- **Banco**: DuckDB (colunar, multi-threaded, 88% menor que SQLite)

## Estratégias (MQL5)

- TrendFollowing (SuperTrend + VWAP + regime)
- MeanReversionKeltner (Keltner + RSI)
- BreakoutSimple, MomentumBreakout, VolBreakout
- PullbackVWAP, RangeBreakout, SessionBreakout
- GoldRush, MeanReversal (OU-based)

## EAs (Experts/EAQuant)

| EA | Origem | Status |
|---|---|---|
| `EA QUantFX.mq5` (v3.5.0) | ex-`EA QUantFX Green` | **v3.4.0**: notificações **Telegram padronizadas** — **Init** via `Startup()` (EA/corretora/servidor/conta/saldo/alavancagem, gate `InpTelegram_init`), **DeInit** via `Shutdown()` (gate `InpTelegram_Deinit`), **Check Terminal** com severidade `Critical` (FAIL, incondicional) / `Warning` / `Info`; abertura e fechamento de ordens via `OrderOpened`/`OrderClosed` (P/L real e hold, gate `InpTelegram_orders`). Diagnóstico crítico via **`CTerminal`** (v7.21): conta ativa, terminal conectado, EA permitido, **ping ≤ `InpPingMaxMs`**, **DLLs não permitidas**, CSV/GV críticos, margem ≥100% e símbolo operável. Requer `api.telegram.org` no WebRequest. FX M1 — **REBUILD LEAN** com núcleo estratégico 1:1 do `IS Green EA.mq5` (referência intocável): entrada M1-breakout ancorada 1s, **saídas AGREGADAS como o IS Green** — ordens abrem com **SL=0/TP=0**, saída por `InpStopLossPerc` (ClosePos, % do equity) + **TP agregado opcional** `InpTakeProfit` (0=off; fecha quando `ProfitAll >= AllLots·TakeProfit`) + **trailing `Tral`/`TralStart` em pontos brutos ×Point** (Tral=10/TralStart=2, idêntico IS Green), 1 posição/símbolo (sem grid — mesa proprietária), janela 02:00–19:00, lote `(balance/10·Risk)/(tickValue·100·D)` com limites `InpMaxLot`/`InpMaxLeverage`. **Backstop de segurança wide** (grupo `Backstop Seguranca`): `InpBackstopMode` Fix/ATR, `InpBackstopValue=10.0` (ATR×10 default = ~2.000 pontos em GBPUSD M1; só corta em catástrofe, sem interferir na rotina diária), `InpATRPeriod=14`. Compliance Moneta mantida: AccountProtector `PRESET_MONETA_INSTANT` (daily 2.5%, **lifetime trailing drawdown 5%** via `InpTrailingDDPct`, floating 1.5%, consistency 15%), **news block high-impact** via `CNewsFilter` (janela de horário via `CTimeFilter`, núcleo IS Green), Magic derivado (AutoMagicID). Performance: removidos DFA/Hurst, RiskSentiment, DataMiner, Panel e CExecution — OnTick mínimo, protetor cacheado no OnTimer 10s. **v3.1.0**: proteção de comissão (`➜ Comissão`) — o SL do trailing só trava acima do **break-even + comissão** (`CommFloorPrice`); TP agregado fecha apenas com lucro líquido ≥ alvo. **v3.0.0**: migrado para o padrão de execução do framework — `CExecution` (sizing via `Calculate` com risco pela distância real do SL, envio via `Buy/Sell` com retry/timeout) + `CPanel` (dashboard no `OnTimer`). SL continua via `CStopLoss` (ATRStops_v1), trailing e saídas agregadas inalterados. **v2.7.1**: lógica de SL consolidada na classe `CStopLoss` (`ALXQuantCore/Core/StopLoss.mqh`). **v2.7.0**: novo `➜ SL Mode` — `InpSLMode` `SL_FIXED` (distância em pips) ou `SL_ATR` (**ATRStops_v1** embutido inline: ATR via `iHigh/iLow/iClose`, banda com ratchet de tendência, cache 1×/barra fechada; SL na abertura + trailing ratchet acompanhando a banda). **v2.6.0**: TradeGate eliminado — `CTimeFilter`/`CNewsFilter` independentes (v8.12) integrados; gate = `IsTimeTrade()` && `!IsNewsBlocked()`; inputs legados `TimeStart/TimeEnd` removidos. **v2.5.1**: REVERT dos Stops ATR (v2.5.0) — restaurado o modelo simples v2.4.0 (SL/TP agregado + trailing `Tral`/`TralStart` ×Point); **Human Simulator** desvia **apenas a entrada** (fidelidade v2.1.0) |
| `IS Green Lab.mq5` (v1.20.0) | Lab strategy | **v1.20.0**: Integração completa do **CExecution Engine** (v7.64) — `Init()` com state-machine retry/timeout, `Calculate()` para position sizing institucional (lot risk via OrderCalcProfit multi-asset: Forex/XAU/BTC/OIL/Stocks), `Buy/Sell` roteados pela engine com analytics de slippage/latency/broker score. Mantidos TP global (`InpTakeProfit`), SL% equity (`InpStopLossPerc`) e trailing nativo (`Tral`/`TralStart`) do Lab. Requer `CMacroRegimeEngine`, `CRiskSentiment`, `CDataMinerBuffered`, `HumanBehavior`. |
| `EA QUant Index.mq5` (v1.02) | ex-`EA QUantHFT_US30` | Offline (padrão HFT não permitido na GFT) |
| `EA QUant Index v2.mq5` (v1.14) | ex-`EA QUantHFT_US30_v2` | Offline (padrão HFT não permitido na GFT) |
| `EA Quant Commodities.mq5` (v8.0.3) | ex-`EA Quant_BASE_trend_v8` | XAUUSD/commodities — fora da conta GFT |
| `Quant_NewsFilter.mq5` (v4.8.1) | Filtro de notícias standalone | Forex Factory CSV → exporta GV `NI_CAN_TRADE`; **cache persistente em disco** (`\Files\`, evita falso bloqueio no restart; refresh live no OnTimer); painel + marcadores; alertas por popup/som/push + **Telegram** (`UseTelegram`, classe `CTelegram`): **init** (Info c/ eventos, fonte dos dados, janela de bloqueio e estado), notícia iminente (Critical HIGH / Warning MED + aviso de bloqueio) e transição **PARADO/LIBERADO** (Critical/Warning p/ parado com a notícia bloqueante; Info p/ liberado com próxima notícia) |

Todos os EAs compilam contra a pasta canônica `Include/ALXQuantCore`.

## Módulos de risco (Include/ALXQuantCore/Modules)

| Módulo | Função |
|---|---|
| `RiskManager.mqh` | Risco por trade/preset (consistência, daily loss, etc.) |
| `AccountProtector.mqh` (v1.40) | Proteção de conta (limites PnL diários/semanais/mensais, consistency rule via `InpConsistencyPct`, 0=off; filtra por magic do EA). Presets: ALXQUANT (default) e GFT_HERO (GFT Instant HERO: daily 2.5%, monthly 4.5%, floating 1%, sem weekly/target) |
| `PortfolioRisk.mqh` (v7.10) | Coordenador multi-EA via GlobalVariables (`ALX_PF_*`): heartbeat/registry, anti-hedge por símbolo, exposição por moeda, share 1/N do orçamento de lotes. Opt-in (`InpPortfolioRisk=false` default) |
| `ExecutionLite.mqh` (v7.11) | Execução simples + position sizing + broker stats (**contrato do `CPanel` preservado**, `m_exec`). Alternativa enxuta ao `CExecution` v7.60 (sem bandas StopATR, sem state-machine de retry pesada, sem ClosePartial/CloseProfitPositions/CreatePanelBackground). Lote `LOT_FIXED/LOT_BALANCE/LOT_RISK`, SL/TP/BE/trailing por ATR direto (`iATR`) ou pips, ADR p/ `TP_ADR`. Execução controlada por `ENUM_ALX_EXEC_MODE {EXEC_MARKET, EXEC_PENDING}` (Buy/Sell Stop + Buy/Sell Limit). **Human Simulator** p/ mesa proprietária: desvios aleatórios ±(0..`InpHumanMaxDevPips`) em entrada, SL, TP e trailing, com seed determinístico (`MathSrand`) p/ backtest reproduzível |
| `TimeFilter.mqh` (v8.12) | Filtro de horário/sessão separado (`CTimeFilter`): janela `InpTimeStart/InpTimeEnd` (default 02:00–19:00) com fuso `InpTimezone_offset`, bloqueio de sexta (`InpTradeFriday`), fim de sessão (`InpTimeWaitEnd`), espera após abertura de mercados globais (`InpMarketOpenWaitMinutes`) e linhas verticais no gráfico. `IsTimeTrade()`/`GetBlockReason()`. Ex-`TradeGate` |
| `NewsFilter.mqh` (v8.12) | Filtro de notícias separado (`CNewsFilter`): impactos high/medium/low + speeches/holidays por moeda (`InpNewsCurrencies`), janelas antes/depois (`InpNewsHighBeforeMin` etc.), ForexFactory live via WebRequest (`InpNewsUseFFLive`) com fallback `Calendar.csv` (Kernel32 `C:\ALXQuant\data\mql5\`), cache + hot-reload, linhas no gráfico. `IsNewsBlocked()`/`GetBlockReason()`. Ex-`TradeGate` |

## Módulos Python

| Módulo | Função |
|---|---|---|
| `asset_dna` | Perfil de ativos com HMM, Hurst, entropia, Transfer Entropy, Wavelet |
| `backtest` | Walk-Forward Optimization, Monte Carlo, custos realistas |
| `data_housing` | Coleta incremental (MT5), validação de gaps/freshness, health check, scheduler Windows |
| `risk_sentiment` | PCA de risco macro (VIX, DXY, yields, curvas) |
| `db` | Schema, migração SQLite→DuckDB, load CSV |
| `v10` | **Novo (v10.1.3):** cérebro Python que gera `policy_<SYM>.bin` (contrato 88 bytes) consumido por EAs MQL5 leves; `policy.py` = fonte da verdade do layout + CRC32; `v10/regime` = RegimeEngine intraday (DFA/Hurst/R²/ADX/ATR, paridade com asset_dna); `v10/policy_compiler.py` = gates (WEEKEND/SESSION/NEWS/CHAOS/VOL_BURST/RORO_EXTREME) + shaping de risco por símbolo; `v10/news` = CalendarGate (calendar_events via DuckDB); `v10/tap` = sync OHLC M5/M15 MT5→DuckDB; `v10/scheduler.py` = orquestrador 5 min (tap→regime→risk→compiler); `v10/dashboard.py` = status da integração |

## Cérebro v10 — como a integração funciona

A ciência (regime/risco/notícias/gates) roda **100% em Python** e entrega a
decisão ao MT5 em um único arquivo binário por símbolo:

```
MT5 --(M5/M15)--> DuckDB (ohlc_prices)         [v10/tap + collector]
                         |
                         v
               RegimeEngine (DFA/Hurst/ADX/ATR) [v10/regime]
                         |
RiskSentiment CSV (diário) -----> PolicyCompiler (gates + shaping)
CalendarGate (calendar_events) -/                   |
                         v                        [v10/policy_compiler]
              policy_<SYM>.bin (88B, CRC32)  ->  data\mql5\ + Common\Files
                         v
              EA leve MQL5 (EAQuantPolicy_v10)  [Policy.mqh - CPolicyReader]
```

- **`v10/policy.py`** é a única fonte da verdade do layout (88 bytes little-
  endian; magic `ALXP`; format_version 10000; CRC-32 poly `0xEDB88320` sobre
  os bytes 0..83). Qualquer alteração de layout deve majorar FORMAT_VERSION.
- **`MQL5\Include\ALXQuantCore\Policy.mqh`** (`CPolicyReader`) decodifica o
  mesmo contrato em MQL5 (unions + CRC idêntico a zlib), com leitura
  dual-path: `FILE_COMMON` no Strategy Tester e Kernel32 ao vivo.
- **EA leve**: para validar a integração use `EAQuantPolicy_v10.mq5`
  (breakout ATR + gates + lot_mult_pct + sl/tp ATR). Ele NÃO contém ciência —
  tudo vem do binário.

### Como testar e validar (terminal, na raiz `C:\ALXQuant`)

```powershell
# 0. Suite unitária de todo o cérebro v10 (sem MT5, sem setup):
python test_policy_v10.py
python test_regime_v10.py
python test_compiler_v10.py
python test_scheduler_v10.py
python test_integration_v10.py      # E2E: dados sintéticos -> bin -> readback
python test_policy_mqh_audit.py     # anti-drift: offsets do .mqh x policy.py

# 1. Gerar os policy_<SYM>.bin reais (sem MT5; usa o DuckDB atual):
python -m v10.scheduler --once --no-tap

# 2. Ver o status completo da integração (freshness, bins, risk, log):
python -m v10.dashboard

# 3. Com MT5 ligado (atualiza M5/M15 e roda o cérebro):
python -m v10.tap.mt5_tap --symbols XAUUSD EURUSD --tfs M5 M15 --days 2
python -m v10.scheduler --once

# 4. Loop contínuo (produção) ou task do Windows a cada 5 min:
python -m v10.scheduler --interval 300
python -m v10.scheduler --install-task
```

Validação no MT5 com `EAQuantPolicy_v10.mq5`: atachar no gráfico do símbolo
e conferir o rótulo no canto superior esquerdo (`[Policy] XAUUSD go=... bloc
=... dir=... mult=... H=...`). `go=1` libera; `go=0` + `block` explica o
motivo (ex.: `WEEKEND`, `NEWS`, `SESSION`). Também compile e rode
`Policy.mqh` num script simples para conferir que a leitura/CRC do binário
fecham com o Python.

## DataHouse — Catálogo único e atualização (v7.3.0)

O DataHouse passou a ter uma **fonte única e visível** de cobertura e atualização:

- **`macro_catalog` (super-catálogo)**: além das 58 séries macro (FRED/YAHOO),
  agora contém o **universo OHLC completo dos 11 ativos** via MT5 (XAUUSD,
  EURUSD, USDJPY, GBPJPY, AUDJPY, EURGBP, US30, US500, US100, HK50, BTCUSD),
  cada um com `category_type`, `collector`, `target_table`, `timeframe`,
  `enabled` e `min_freshness_hours` (cadência por ativo).
- **View `v_update_schedule`**: por ativo expõe cadência, última data,
  `age_hours` e `status (ok/stale/critical)`, calculados sobre
  `MAX(time/date)` real — é o que o sistema consome para decidir o que
  atualizar.
- **Scheduler** deriva a agenda do catálogo: todos os 11 OHLC com slots
  escalonados (evita lock de escrita do DuckDB, que só aceita 1 writer por
  vez), crypto horário, e tasks Macro/Risk. Tasks podem rodar como **SYSTEM**
  (não dependem de logon interativo).
- **Health das tasks** (`validate_all_tasks`): interpreta o `Last Result` do
  Windows (`ok`/`never`/`failed`) e sinaliza `healthy`/`problem`, tornando
  visível task ausente, nunca rodada ou com erro.
- **Log por coleta**: `cli_collector.py --log <arquivo>` e
  `risk_sentiment/engine.py --log` gravam resultado em JSON; `_insert_to_duckdb`
  com retry em caso de lock.
- **Risk sentiment p/ o EA (v7.4.1)**: o CSV `risk_sentiment_daily.csv`
  agora inclui as colunas que o EA v8 consome. Antes faltava `global_risk_score`
  (a engine so gravava `roro_score`), o que fazia o `LoadCSV()` do EA falhar e
  o gate Risk_On/Risk_Off degradar para `NEUTRAL` silenciosamente. Agora o
  arquivo traz `risk_label` + `global_risk_score` (-1..1, positivo=RISK_ON)
  + `usd_index`, sem remover `roro_score`/`vix`/`dxy` usados por EAs v6/v7.
- **Resiliência e validação (v7.4.3)**: `engine.py` agora valida séries por nome
  de coluna (bounds → quarentena NaN + alerta) e roteia os fatores críticos pela
  cadeia de fallback de `Modulos/risk_sentiment/sources.py` (primária →
  `FRED_HTTP`/Yahoo; se todas falharem → `QuarantinedError`). `detect_frozen()`
  sinaliza série possivelmente descontinuada no FRED/Yahoo (sem operar com o
  último valor congelado). Persistência atômica no DB e coluna `is_stale` no
  output. A referência metodológica oficial é o índice KCRORO do Kansas City Fed
  (Chari/Dilts Stedman/Lundblad, NBER 31907) — usado como validação na evolução
  para v4.
- **KCRORO como fonte primária (v7.4.4)**: o sinal que os EAs lêem passou a ser
  o **KCRORO oficial** (headline KC Fed) e não mais o PCA interno. Como o KCRORO
  já é o z-score do PC1 (nível em σ), os limiares usam o nível direto:
  `RISK_ON` (≤−1) | `NEUTRAL` (|·|<1) | `RISK_OFF` (≥1), `global_risk_score` =
  −nível/3 (clipado) e `signal_strength` = |nível|. O sinal é defasado em 1 dia
  (`shift(1)`, sem lookahead). Se o KCRORO estiver indisponível, o PCA interno
  vira modo degradado + alerta. Novos `Modulos/risk_sentiment/validation.py`:
  valida o KCRORO ingerido contra os eventos-âncora do paper (5/5 PASS, ±30%;
  flash crash 5.14 vs 5.12, downgrade US 5.61 vs 4.79, Brexit 6.10 vs 5.92, GFC
  12.61 e COVID 12.16 vs >11; skew 1.65/1.56 e curtose 18.8/21.98 do paper).
- **Execução silenciosa (v7.3.1)**: tasks rodam com `pythonw.exe` +
  `RunAs SYSTEM` — sem janela CMD, sem roubar foco. Sem console, stdout/stderr
  são redirecionados para `data/logs/<simbolo>_<tf>.log` (JSON por linha), com
  traceback capturado em crash.
- **Health consolidado (v7.4.0)**: `python -m Modulos.datahouse.health
  [--notify] [--log]` resume frescor por ativo + cobertura/estado das tasks;
  dispara alerta (`ALXQUANT_ALERT_WEBHOOK`) em caso de ativo crítico ou task
  ausente/falhou. Tasks SYSTEM são reconhecidas como `restricted` (existem,
  mas sem leitura de detalhe fora de sessão elevada), evitando falso
  "ausente". Registro: `register_datahouse_tasks.py` (executar elevado).
- **Autonomia 24/5 (v10.2.0)**: o DataHouse passou a se auto-manter sem
  depender do GUI. A task `ALX-DataHouse-Bootstrap` (trigger `ONSTART`, `/RU
  SYSTEM`) executa `Modulos/datahouse/ensure_tasks.py` em toda inicialização
  do Windows (antes do login): verifica se todas as tasks `ALX-DataHouse-*`
  existem no Task Scheduler e reinstala automaticamente qualquer task ausente.
  Nova task diária `ALX-DataHouse-Validate` (03:40) roda
  `validate_cli.py` (`check_domain_freshness` + `validate_integrity` +
  `validate_all_tasks`, log em `data/logs/validate.log`). Fix no `health.py`
  (import relativo→absoluto) e no `validate_all_tasks` (tasks `restricted`
  não são mais reportadas como `healthy` — agora `indeterminadas` com
  `problem=True`, eliminando o falso "14/14 healthy"). Instalação única do
  bootstrap (elevado): `schtasks /create /tn "ALX-DataHouse-Bootstrap" /tr
  "<pythonw> Modulos\datahouse\ensure_tasks.py --log data\logs\ensure_tasks.log"
  /sc onstart /ru SYSTEM /f`.

## Terminal

```
python -m gui.html.serve
# http://127.0.0.1:8000
```

Um terminal Bloomberg-style com watchlist, gráfico OHLC, scheduler de tasks, health check multi-domínio, e dados macro econômicos.

## Versão

`EA_VERSION: v3.5.0` — veja [CHANGELOG_MQL.md](CHANGELOG_MQL.md) e [CHANGELOG_PYTHON.md](CHANGELOG_PYTHON.md) para histórico completo.

## v3.5.0 — Proteção lucro líquido + TP por posição + Spread filter + Anti-scalping (MINOR)

- **`EA QUantFX.mq5` (v3.4.0 → v3.5.0)**: correção estrutural do problema "mesa engole 67% lucro":
  - **Validação pré-entrada**: nova `CalcTotalCostUSD()` + `ValidateSLForCosts()` — SL distance deve cobrir spread+comissão ×1.5 (RR mínimo); bloqueia trades onde custo > lucro potencial.
  - **TP por posição** via `CExecution` (`InpTPMode`: TP_RISK_REWARD/TP_FIXED/TP_ADR + `InpRiskReward`/`InpTakeProfit`); **TP agregado book-level removido** (fechava quando `ProfitAll >= AllLots·TakeProfit` sem descontar spread entrada+saída).
  - **Spread filter ativo** (novo grupo inputs): hard cap `InpMaxSpreadPoints` + média móvel `InpSpreadLookback` × `InpSpreadMult`; log detalhado quando bloqueado.
  - **Anti-scalping**: `time_open` 1s → 60s (re-arm step mínimo); `InpMinHoldSeconds=120` (trailing/TP só após 2 min); defaults trailing `Tral=50`/`TralStart=20` (eram 20/8); cooldown `InpMinBarsBetweenTrades=3` barras M1.
  - **Regime filter**: Hurst 0.40-0.60 (`InpLastHurstMinValue`/`MaxValue`) — só opera em regime favorável.
  - **Piso lucro**: `InpMinNetProfitUSD=2.0` para validação adicional.
  - **Telegram**: instanciado no `OnInit()` (inputs `m_token`/`m_chat_id` só válidos pós-`OnInit`); `OnDeinit` deleta ponteiro.
  - **Clareza trailing**: grupo renomeado "MODELO FIXO - só ativo se InpSLMode=SL_FIXED"; log config no init.
- **Versão**: `v3.5.0` (#property "3.50").

## v3.4.0 — Telegram padronizado: Startup, Shutdown, Warning, Critical (MINOR)

- **`EA QUantFX.mq5` (v3.3.1 → v3.4.0)**: notificações Telegram agora usam as **funções formatadas padrão** da classe `CTelegram`:
  - **Init** → `Startup(eaName, vr)` (EA, corretora, servidor, conta, saldo, alavancagem, data) — gated por `InpTelegram_init` (substitui o `Info("...INICIADO")` ad-hoc).
  - **Check Terminal** → **`Critical`** quando `!AllOK()` (FAIL, **incondicional** mesmo com `InpTelegram_init=false`); **`Warning`** quando só há WARN; **`Info`** quando tudo OK (estes gated por `InpTelegram_init`); `Print(diag)` sempre.
  - **DeInit** → `Shutdown(eaName, vr, reason)` no `OnDeinit` — gated por **`InpTelegram_Deinit`** (motivo: remover do gráfico, fechar gráfico, troca de ativo/TF, troca de conta, fechar terminal).
  - **Ordens** → mantém `OrderOpened`/`OrderClosed` (abertura com SL/TP reais e fechamento com P/L, saldo e hold).
- **`Terminal.mqh` (v7.20 → v7.21)**: novo acessor **`WarnCount()`** (contador de WARN) para a lógica de severidade Critical/Warning/Info.

## v3.3.1 — CTerminal crítico: ping, conta, DLLs, dependências + alerta incondicional (PATCH)

- **`Terminal.mqh` (v7.10 → v7.20)**: `CTerminal` redesenhado como **checklist crítico** — só o que pode **parar a operação ou o alerta Telegram**, cada item gerando `FAIL` real (gate via `AllOK()`): conta ativa (`ACCOUNT_TRADE_ALLOWED`), terminal conectado (`TERMINAL_CONNECTED`), EA permitido em 3 camadas (`TERMINAL_TRADE_ALLOWED` + `MQL_TRADE_ALLOWED` + `ACCOUNT_TRADE_EXPERT`), **ping do servidor** (`TERMINAL_PING_LAST`, µs→ms) vs `SetPingLimitMs()` (default 300ms), **DLLs não permitidas** (`TERMINAL_DLLS_ALLOWED`), dependências ausentes (`FileIsExist`/`GlobalVariableCheck` agora **FAIL**, não WARN), margem level `<100%` e símbolo bloqueado (`SYMBOL_TRADE_MODE`). Telemetria não-crítica removida (build, CPU, memória, disco, OpenCL, spread, volume, saldo, horário, email/push); contexto mínimo como `[INFO]` (modo conta, login, corretora, servidor, alavancagem, saldo). **Fix compilação**: `TERMINAL_TRADE_EXPERT`/`TERMINAL_OPENCL_SUPPORTED` (inexistentes) removidos.
- **`EA QUantFX.mq5` (v3.3.0 → v3.3.1)**: novo input **`InpPingMaxMs`** (grupo `➜ Terminal`, default 300) repassado via `m_terminal.SetPingLimitMs()`; o **DIAGNÓSTICO crítico agora é enviado por Telegram de forma incondicional** quando `!m_terminal.AllOK()` (mesmo com `InpTelegram_init=false`); `INICIADO` segue gated por `InpTelegram_init`.

## v3.3.0 — Telegram: init + ordens (abertura/fechamento) e diagnóstico CTerminal (MINOR)

- **`Telegram.mqh` (v7.13 → v7.20)**: novas mensagens de trade — `OrderOpened(ticket, symbol, side, volume, price, sl, tp, time)` e `OrderClosed(ticket, symbol, side, volume, openPrice, closePrice, netPL, balance, time, hold)` com P/L **líquido** (profit + swap + commission), saldo e tempo de permanência (hold). Emojis preservados (UTF-8).
- **`Terminal.mqh` (novo, v7.10)**: classe **`CTerminal`** — checklist geral de dependências (arquivos locais `\Files\` e globais via `GlobalVariableCheck`, com mensagem `FAIL` se não existirem) + checklist do terminal (permissões de WebRequest e estado de execução). API: `SetEAContext`, `SetSymbol`, `AddFileDependency`, `AddGlobalVarDependency`, `CheckDependencies`, `CheckPermissions`, `CheckTerminal`, `RunAll` (retorna o relatório), `AllOK`. Sem dependências de módulos externos.
- **`EA QUantFX.mq5` (v3.2.0 → v3.3.0)**: no `OnInit` roda o `CTerminal` (`RunAll()` → `Print` + Telegram se `InpTelegram_init`), verificando `ALX_NewsFilter_ff_thisweek.csv` e a GV `NI_CAN_TRADE`, e envia `Info` de inicialização (EA, versão, ativo, timeframe, magic). No `OnTradeTransaction`, após o delegate do `CExecution`, o novo `NotifyTelegramDeal()` notifica **abertura** (`DEAL_ENTRY_IN`, com SL/TP reais) e **fechamento** (`DEAL_ENTRY_OUT/OUT_BY/INOUT`, com P/L, saldo e hold via `FindOpenDeal`) — filtrado por `DEAL_MAGIC` e `DEAL_SYMBOL`, gated por `InpTelegram_orders`.
- ⚠️ **Requerimento**: adicionar `https://api.telegram.org` em Ferramentas → Opções → Assessores Especialistas → **WebRequest** (senão só loga erro, sem envio).

## v3.2.0 — Painel profissional: Asset Status + Performance por EA+Symbol (MINOR)

- **`StatsTracker.mqh` (novo, v7.20)**: estatísticas **exclusivas do EA no symbol** (nunca conta global). Ganho diário (fechados hoje + flutuante), posições abertas, lotes, **DD%** (pico do dia) e **DD% máximo histórico** (curva de P/L acumulada). Performance dos trades fechados (agrupados por `POSITION_ID`): **WinRate%, Profit Factor, RRR (avg win/avg loss), Expectancy, Z-Score (runs test), streaks máx W/L, maxDD** em moeda. Incremental: processa apenas deals novos a cada `Update()`; auto-rebuild se o histórico for limpo.
- **`Panel.mqh` (v7.16 → v7.20)**: dashboard reorganizado em seções (Filtros / Regime / Execução / **Asset Status** / **Performance**) com fundo de altura dinâmica. **`Risk Manager` → `Entry Gate`** (rótulo honesto — antes era o eco do gate de entrada, não um risk manager real); nova linha **`Equity Guard`** (estado real do freio de drawdown agregado `InpStopLossPerc`); **`Risk Global`** e **`Confluence`** exibem **`N/A`** quando não alimentados (0); `NewsBlockedReason` real (`NI_CAN_TRADE=0` / `NO GV`) no lugar do literal `NEWS`.
- **`EA QUantFX.mq5` (v3.1.2 → v3.2.0)**: `m_stats.Init()` no `OnInit` e `m_stats.Update()` no `OnTimer`; novo input **`InpNewsBlockIfNoGlobal`** (default `false` = opera livre quando o EA de notícias não está rodando); `Equity Guard` e estatísticas passadas ao painel.
- **Auditoria**: Chaos, Hurst, R², Direction, Market Trend, Active Regime, Blockers e todas as linhas de Execução/Broker são alimentadas por dados **reais** do `MacroRegimeEngine` (DFA) e do `CExecution`; `Risk Global`/`Confluence` nunca foram alimentados (agora honestos como `N/A`).

## v3.1.2 — Lot sizing: InpLotValue volta a funcionar em pares JPY (PATCH)

- **`Execution.mqh` (v7.61 → v7.62)**: `NormalizeLot` calculava `notional_per_lot = contract_size × price`, válido apenas quando a cotação == moeda da conta. Em pares JPY (ex.: GBPJPY com conta USD) o nocional ficava ~150× inflado e o clamp de alavancagem **pinava o lote no mínimo**, tornando o `InpLotValue` inerte. Corrigido para a moeda da conta via `(price/tick_size) × tick_value` (valores `SYMBOL_TRADE_TICK_VALUE`/`TICK_SIZE` já vêm na moeda da conta).
- **`EA QUantFX.mq5` (v3.1.1 → v3.1.2)**: `OpenBuy()`/`OpenSell()` consomem a struct `TradeParams` de `m_exec.Calculate()` diretamente (removido o wrapper local `CalcLot()`); caps `InpMaxLot`/`InpMaxLeverage` preservados no novo helper `ApplyLotCaps()`.

## v3.1.1 — Painel: versão exata do EA (PATCH)

- **`Panel.mqh` (v7.15 → v7.16)**: o título do painel exibia `vv` duplicado — `Panel.mqh:67` somava um prefixo fixo `" v"` a uma versão que já chegava com `v` (`EA_VERSION="v3.1.0"` → `EA QUantFX vv3.1.0`). Removido o prefixo fixo: o painel agora exibe **exatamente** a string de versão recebida.
- **`EA QUantFX.mq5` (v3.1.0 → v3.1.1)**: sem mudança de lógica — já passa `EA_VERSION`; o painel passa a mostrar `EA QUantFX v3.1.0` (= `EA_VERSION`). Corrigidos também `EA QUantFX - Copia` e `EA QUant Index v2` (mesmo bug).
- **`EA Quant Commodities.mq5` (v8.0.2 → v8.0.3)**: `m_ea_version` usava `"5.32"` (defasado) → agora espelha `EA_VERSION` (`v8.0.3`).

## v3.1.0 — EA QUantFX: proteção de fechamento abaixo do custo de comissão (MINOR)

- **`EA QUantFX.mq5` (v3.0.0 → v3.1.0)**: novo grupo de inputs `➜ Comissão` — `InpCommission` (USD/lote, **ida e volta**), `InpCommProtect` (liga/desliga) e `InpCommBuffer` (buffer extra em USD acima do custo, default 0).
- **Filtro de custo**: o Stop Loss do trailing (`Traling()`) só sobe (BUY) / desce (SELL) para pelo menos o preço de **break-even + comissão** — calculado por `CommFloorPrice()` via `SYMBOL_TRADE_TICK_VALUE`/`SYMBOL_TRADE_TICK_SIZE` — e nunca acima do mercado. Abaixo do custo o SL não é travado, evitando fechamento com lucro bruto positivo que vira negativo após a comissão (ex.: 0.02 lote, comissão −$0.14). Aplicado às 4 ramificações (banda ATR buy/sell e fixo lock/trailing buy/sell).
- **Take Profit agregado**: fecha apenas com lucro **líquido** ≥ alvo + comissão total do livro (`ProfitAll >= AllLots·InpTakeProfit + InpCommission·AllLots`).

## v3.0.0 — EA QUantFX: migração para CExecution + CPanel (MAJOR)

- **`EA QUantFX.mq5` (v2.7.2 → v3.0.0)** + **`Panel.mqh` (v7.15)**: o EA passou a usar o motor de execução do framework — `CExecution` (sizing via `Calculate`, envio via `Buy/Sell` com retry/timeout, `Update()` no `OnTick`, `ProcessTradeTransaction` no `OnTradeTransaction`) e o painel `CPanel` (dashboard desenhado no `OnTimer`, sem pesar no `OnTick`).
- **Removidos**: `OpenPosition()`, `GetLot()` e a confirmação manual de transação (`m_waiting_transaction`).
- **SL**: continua via `CStopLoss` (ATRStops_v1 validado); o `m_exec` é configurado com `SL_FIXED/0` e recebe o SL explícito no `Buy/Sell`. TP por posição = 0 (saídas agregadas `InpStopLossPerc`/`InpTakeProfit` e trailing `Traling()` inalterados).
- **Sizing**: no modo `risk`, o lote agora usa a distância real do SL (antes fallback de 100 pts) e Equity (antes Balance); caps `InpMaxLot`/`InpMaxLeverage` mantidos via `CalcLot()`.
- **`Panel.mqh` v7.15 (Fix)**: `m_regime.GetTrend()` → `m_regime.GetLabel()` (método removido do `MacroRegimeEngine` v7).
- `.ex5` v3.0.0 sincronizado para o data folder do terminal (`6370...\MQL5\Experts\EAQuant\`).

## v2.7.2 — EA QUantFX: valor de SL unificado em InpSLValue (PATCH)

- **`EA QUantFX.mq5` (v2.7.1 → v2.7.2)** + **`StopLoss.mqh` (v7.01)**: os inputs `InpSLFixValue` (fixo) e `InpATRStopsKv` (ATR) foram **unificados em um único campo `InpSLValue`** — usado como distância em pips no modo `SL_FIXED` e como multiplicador Kv no modo `SL_ATR` (mesmo padrão dos EAs v7/v8 do framework). `InpATRStopsLen`/`InpATRStopsPeriod` permanecem.
  - Default `InpSLValue = 30.0` (preserva o comportamento `SL_FIXED` atual sem preset).
  - ⚠️ **Ação manual necessária**: os presets `EA QUantFX.set` e `EA QUantFX.GBPJPY.M1.last_year.000.ini` ainda carregam os nomes antigos (`InpSLFixValue`/`InpATRStopsKv`) — o tester os ignora e usa `InpSLValue=30.0` como Kv no `SL_ATR` (banda absurdamente larga). Ajuste para `InpSLValue=2.5` nesses arquivos ao rodar backtests em ATR.

## v2.7.1 — EA QUantFX: SL consolidado na classe CStopLoss (PATCH)

- **`EA QUantFX.mq5` (v2.7.0 → v2.7.1)**: toda a lógica de Stop Loss (funções `ATRStops_ATR/Compute/Update`, `GetStopLossPrice` e globais `g_atr_*`) consolidada na classe **`CStopLoss`** — novo módulo `ALXQuantCore/Core/StopLoss.mqh` (v7.00). O EA usa o objeto `m_stoploss`: `Init()` no `OnInit`, `GetStopLossPrice()` em `OpenBuy`/`OpenSell`, `UpdateBands()`/`Upper()`/`Lower()` no trailing ratchet do `Traling()`.
  - Inputs `➜ SL Mode` (`InpSLMode`, `InpSLFixValue`, `InpATRStopsLen/Period/Kv`) movidos para o módulo — continuam expostos nos inputs do EA.
  - Correção de compilação absorvida: `InpSLFixValue × sets.m_adjusted_point` (o global `m_adjusted_point` não existe) — a classe recebe o pip ajustado via `Init()`.

## v2.7.0 — EA QUantFX: SL mode Fixo / ATRStops_v1 (MINOR)

- **`EA QUantFX.mq5` (v2.6.3 → v2.7.0)**: novo grupo de inputs `➜ SL Mode` com `InpSLMode` (`SL_FIXED`/`SL_ATR`).
  - `SL_FIXED` → SL por distância fixa em pips (`InpSLFixValue`; `0` = sem SL).
  - `SL_ATR` → réplica fiel do indicador **ATRStops_v1** (IgorAD) **embutida como cálculo inline** (sem arquivo de indicador): ATR calculado via `iHigh/iLow/iClose` (`ATRStops_ATR`), banda com ratchet de tendência `smin1/smax1/trend1` (`ATRStops_Compute`), cache 1×/barra fechada (`ATRStops_Update`), parâmetros `InpATRStopsLen=10`, `InpATRStopsPeriod=5`, `InpATRStopsKv=2.5`.
  - Aplicação: SL definido na abertura da ordem (`GetStopLossPrice`, com guarda de `StopsLevel`) e **trailing ratchet** no `Traling()` — no modo `SL_ATR` o SL acompanha a banda ATRStops (sobe no long, desce no short, nunca regride); no `SL_FIXED` mantém o trailing fixo `Tral`/`TralStart` atual.
  - **Correção associada (v2.6.3)**: `RefreshRates()` deixou de ser stub — chama `m_symbol.RefreshRates()` e valida `Ask()/Bid()` ≠ 0, populando o `m_tick` interno do `CSymbolInfo`.

## v2.6.1 — News filter: fuso UTC + reload FF no live (PATCH)

- **`EA QUantFX.mq5` (v2.6.0 → v2.6.1)**: `OnTimer()` agora chama `m_news.ReloadNews()` no live (não-tester). O JSON da ForexFactory ("thisweek") era baixado só 1x no `OnInit` e ficava obsoleto após a semana corrente; o `ReloadNews` é throttled por `InpNewsFFRefreshMinutes` (default 60 min). No tester nada muda (CSV carregado 1x no `OnInit`).
- **`Calendar.csv` (dados)**: estava em **UTC+6** (sem metadata `#TIMEZONE=`) e o módulo assume UTC + offset do servidor (+3 no GFT) → bloqueio ~6h atrasado. Aplicado **shift −6h** com rolagem de dia + metadata `#TIMEZONE=UTC` nos dois arquivos (`data\mql5\Calendar.csv` live via Kernel32 e `Common\Files\Calendar.csv` tester). Validado contra o JSON live do FF: CAD CPI 08:30 ET → 12:30 UTC; GBP CPI 02:00 ET → 06:00 UTC.
- **`.set`**: `EA QUantFX.set` ganhou `InpNewsBrokerGMT=3` (GFT GMT+3) — obrigatório no tester com CSV UTC correto.
- **Operação live**: a URL `https://nfs.faireconomy.media` deve estar na whitelist do terminal (Tools → Options → Expert Advisors → Allow WebRequest). Sem FF, o fallback usa o CSV agora em UTC.

## v2.0.0 — EA QUantFX: rebuild lean com núcleo IS Green + compliance (MAJOR)

- **`EA QUantFX.mq5` (v1.4.0 → v2.0.0)**: reescrito do zero com o núcleo estratégico 1:1 do `IS Green EA.mq5` (referência **intocável**, não editada). Entrada breakout ancorada 1s (`InpStep=28`), **TP agregado** `ProfitAll ≥ AllLots·InpTakeProfit` e **SL agregado** `ProfitAll < −(balance/100)·InpStopLossProcent` (4%), trailing IS Green (Tral=10/TralStart=2) com 1 posição, lote `(balance/10·Risk)/(tickValue·100·D)`, janela `InpSessionStart=2..InpSessionEnd=19`. **Removidos**: MacroRegimeEngine (DFA/Hurst), RiskSentiment, DataMiner, Panel, CExecution (lote/SL/TP real, StopATR+ADR por barra) e duplo RefreshRates — OnTick mínimo, sem chamadas pesadas.
- **Compliance mesa proprietária mantida**: AccountProtector `PRESET_MONETA_INSTANT` (`InpPreset=6`, `InpTrailingDDPct=5`, `InpConsistencyPct=15`) com Update cacheado no OnTimer 10s; Timefilter como **news block** high-impact ±30min (Init `useTime=false`; janela de horário controlada pelo núcleo IS Green); Magic derivado via AutoMagicID (não conflita com `Magic=2001` do IS Green).
- **`#property version "2.00"`, `EA_VERSION "v2.0.0"`**.
- **Novo `.set`** `EA QUantFX Lean Moneta.set`: parâmetros IS Green (`Risk=0.01`, `StopLossProcent=4`, `TakeProfit=25`, `Tral=10/2`, `SessionStart=2`, `SessionEnd=19`, `Step=28`) + compliance Moneta (`InpPreset=6`, `InpTrailingDDPct=5`, `InpConsistencyPct=15`, `InpNewsBrokerGMT=3`, Timezone −3).
- **Trade-off (verificar no A/B)**: no IS Green o TP agregado só dispara com `Count>1` (grid); com 1 posição o lucro é capturado pelo trailing (Tral=10 pips).

## v1.4.0 — Moneta Funded Instant: preset + lifetime trailing drawdown (MINOR)

- **`AccountProtector.mqh` (1.40 → 1.50)**: novo preset `PRESET_MONETA_INSTANT` (`InpPreset=6`) para a mesa Moneta Funded (Instant Funding): `daily_loss` 2.5%, `monthly_loss` 4.5%, `float_loss` 1.5%, `consistency_pct` via `InpConsistencyPct` (15%), sem profit targets/sem regra semanal (mesa não exige).
- **Novo limite de lifetime trailing drawdown** (max loss trailing 5% da Moneta): input `InpTrailingDDPct` (default 5.0; 0=off; demais presets = 0). Piso = `min(saldo inicial, pico(bal/equity) − pct%·saldo inicial)` — sobe no pico, nunca desce, capa no saldo inicial, **nunca reseta**. Estado persistido em GlobalVariables (`ALX_AP_TD_PEAK_<login>`, `ALX_AP_TD_INIT_<login>`); novo `TRIGGER_SCOPE=SCOPE_LIFETIME` excluído de `CheckRolloverReset`.
- **`EA QUantFX.mq5` (v1.3.0 → v1.4.0)**: `#property version "1.40"`, `EA_VERSION "v1.4.0"`.
- **Novo `.set`** `EA QUantFX.Moneta.Instant.000.set`: `InpPreset=6`, `InpTrailingDDPct=5`, `InpStopLossPerc=1.5` (risco 1.5% < trigger 2% da mesa), `InpConsistencyPct=15`, `InpNewsMinBefore=120` (fechar ≥2h antes de notícia alta; regra da mesa: trade <2h não pode fechar a ±5min), `InpNewsMinAfter=30`, `InpNewsBrokerGMT=3` (verão UTC+3; inverno usar `2`), lote risco 1%, SL_ATR 2.0, TP_ADR 1.0, ADR 7d, trailing fixo 12/4.

## v1.3.0 — EA QUantFX: lote/SL/TP/trailing via CExecution com cache por barra (MINOR)

- **`EA QUantFX.mq5` (v1.2.0 → v1.3.0)**: o sizing de posição volta a ser feito por `m_exec.Calculate()` (Position Sizing Engine), agora com **cache 1×/barra** (`static datetime size_calc_bar` + `iTime`) — resolve a lentidão do backtest que motivou o revert da v1.1.0 (o motor só recalcula banda StopATR + ADR no primeiro tick de cada barra).
- **Novos inputs**: `InpLotMode` (`LOT_FIXED`/`LOT_BALANCE`/`LOT_RISK`), `InpLotValue` (lote fixo | lote/$1000 | % risco), `InpSLMode`/`InpSLValue` (`SL_FIXED`/`SL_ATR`), `InpTPMode`/`InpTPValue` (`TP_RR`/`TP_FIXED`/`TP_ADR`), `InpADRPeriod=7`, `InpTrailMode` (`TRAIL_FIXED`/`TRAIL_ATR`), `InpTrailDistance`, `InpTrailATR`, `InpTrailStep`. `InpLotRisk` e TP agregado `TakeProfit` removidos; equity stop (`InpStopLossPerc`) mantido.
- **Ordens com SL/TP reais** por lado (BUY `Ask-sl_long`/`Ask+tp_long`, SELL `Bid+sl_short`/`Bid-tp_short`); trailing `Traling()` reescrito usando `sets.ExtTrailingStop/Step` em preço alimentados por `tp_params.trail_distance/trail_step` na abertura.

## v1.0.0 (revert) — EA QUantFX: remoção de StopATR + Take ADR (PATCH)

- **`EA QUantFX.mq5` (v1.1.0 → v1.0.0)**: REVERT da estratégia StopATR + Take ADR. Estratégia restaurada ao estado 100% funcional: `CalculateLot()` local, ordens abrem com `sl=0`/`tp=0`, `TakeProfit=25` (TP agregado) restaurado, `m_exec.Calculate()` removido do `OnTick`. Motivo: StopATR/TakeADR estragaram a estratégia e deixaram o EA extremamente lento no backtest (recomputo da banda StopATR + ADR a cada tick).
- Mantidos (não relacionados à estratégia): **`Execution.mqh` v7.60** e **`Panel.mqh` v7.14** (broker analytics fixes), **`Timefilter.mqh` v7.23** (news filter GBP + offset broker no tester).

## v1.1.0 — EA QUantFX: sizing/SL-TP via CExecution — StopATR + Take ADR 7d (MINOR)

- **`EA QUantFX.mq5` (v1.0.0 → v1.1.0)**: lote, SL e TP passam a ser calculados por `m_exec.Calculate()` (Position Sizing Engine consolidado), removendo a função local `CalculateLot()`. A ordem agora envia **SL/TP reais** (antes `sl=0`/`tp=0`), convertidos em preço por lado: BUY `Ask-sl_long`/`Ask+tp_long`, SELL `Bid+sl_short`/`Bid-tp_short`.
- **Stop Loss = `StopATR`** (input `InpStopATR=2.0`, banda high/low − Kv·ATR com lookback 10).
- **Take Profit = `ADR` 7 dias** (input `InpTakeADR=1.0`, `SetADRPeriod(7)`).
- **`InpLotRisk` interpretado como %**: `0.01` = 1% de risco (`SetLotMode(lot_risk)` + `SetLotValue(InpLotRisk*100)`).
- Removido fechamento por **TP agregado** (`ProfitAll >= AllLots*TakeProfit`); mantidos drawdown de equity e trailing.
- **`Execution.mqh` (7.50 → 7.60)**: `SetADRPeriod(int)` para período ADR configurável no `TP_ADR` (antes fixo em 14 dias); correção das médias `GetAverageSlippage()`/`GetAverageLatency()` que usavam `m_total_requests` (incluía rejects/retries) como denominador — agora usam `m_success_count`; clamp de `reject_rate` a 100% em `GetBrokerScore()`.
- **`Panel.mqh` (7.13 → 7.14)**: fix da conversão pontos→pips do Avg Spread (digits 3/5 → `/10`), antes exibia distância de preço e o threshold vermelho nunca disparava.

## v1.2.0 — News filter: ForexFactory ao vivo via WebRequest + timezone real (MINOR)

- **`EA QUantFX.mq5` (v1.1.1 → v1.2.0)**: no Live o `OnTimer` passa a chamar `m_time.ReloadNews()` (apenas quando `!MQLInfoInteger(MQL_TESTER)` e news habilitadas) — a semana atual da ForexFactory é baixada direto e as notícias bloqueiam no horário real, sem depender do CSV manual.
- **`Timefilter.mqh` (7.23 → 7.24)**:
  - **Fonte primária = ForexFactory JSON** (`https://nfs.faireconomy.media/ff_calendar_thisweek.json`): `DownloadFFThisWeek()` via `WebRequest` GET com throttle de `InpNewsFFRefreshMinutes` (default 60 min, evita rate-limit 429); `ParseFFJSON()` + parser JSON próprio (`JSONSplitObjects`/`JSONExtractField` — **MQL5 não tem API JSON nativa**, verificado na doc oficial).
  - **Timezone corrigido de ponta a ponta**: `ParseFFDateTime()` converte ISO com offset ET DST-aware (`2026-08-17T08:30:00-04:00`) para UTC e depois aplica `GetGMTtoServerOffset()` — validado (CAD CPI 08:30 ET → 12:30 UTC). No tester, o offset vem de `InpNewsBrokerGMT` (agora input) **também para a sessão**, alinhando Live (GFT GMT+3) e backtest.
  - **Fallback**: se o FF falhar (URL não autorizada/429/offline), cai para `Calendar.csv`. No tester, a carga é feita uma vez no `OnInit` (sem reler 6.5MB no timer).
- **Bug crítico corrigido**: `Calendar.csv` estava em **UTC+6** (gerado via `CalendarValueHistory()` do MT5) — o filtro bloqueava 6h fora do horário real. Novo script **`CalendarFixTZ.mq5`** (migração one-off, shift −6h + `#TIMEZONE=UTC`) para regenerar o CSV. Rodar **uma vez** no terminal e reexportar o CSV via `CalendarExport.mq5` a cada semana.
- **Operação**: whitelist obrigatória da URL `https://nfs.faireconomy.media` em Tools → Options → Expert Advisors → Allow WebRequest. `.set` ganhou `InpNewsBrokerGMT=3`.

## v1.1.1 — News filter: GBP + offset broker no tester + CSV live (PATCH)

- **`EA QUantFX.mq5` (v1.1.0 → v1.1.1)**: `GBP` adicionado ao filtro de moedas de notícias (`InpNewsCurrencies`) — GBPAUD, GBPJPY e GBPUSD (3 dos 11 pares GFT) ficavam desprotegidos. `InpNewsBrokerGMT=+3`; diagnósticos no `SetupTimeFilter()` (status do Init, contagem de notícias, offset GMT).
- **`Timefilter.mqh` (7.22 → 7.23)**: no Strategy Tester `GetGMTtoServerOffset()` retorna 0 (`TimeGMT()==TimeCurrent()`) e as notícias UTC ficavam desalinhadas (~3h em servidor GMT+3). Novo input `InpNewsBrokerGMT` aplicado no tester; no live o offset continua automático.
- **Operação**: `Calendar.csv` copiado para `data\mql5\Calendar.csv` (canonical live). Antes existia apenas em `Common\Files` (tester), o que desativava silenciosamente o filtro em operação real.

## v7.22.0 — Timefilter: fix hang no Strategy Tester (PATCH)

- **`Timefilter.mqh` (7.21 → 7.22)**: o `Init()` disparava `CarregarNoticiasCSV()` que lia o `Calendar.csv` inteiro da pasta `Common\Files` do terminal (6.5 MB, 98.344 linhas, 2020–2026) dentro do `OnInit` do tester. O `ParseCSVLine()` era O(n²) (concatenação caractere-a-caractere) e processava todo o histórico → **hang no OnInit do Strategy Tester**.
- Correções: `ParseCSVLine()` reescrito com varredura por índice + `StringSubstr` (O(n)); poda por janela de datas `[now−15d, now+700d]` (pré-filtro O(1) sobre `YYYY.MM.DD`) reduzindo de 98k para poucas centenas de linhas; carga pulada se `InpNewsEnabled=false`.
- **`EA QUantHFT_US30_v2.mq5` (v1.11 → v1.12)**: flags de gate (`IsNewsAllowed`, `IsRiskAllowed`, `IsBusy`) passam a ser preenchidas no `OnTick`; abertura inicial usa `can_open_trade`.

## v1.13.0 — EA QuantHFT_US30_v2: sizing/SL-TP via CExecution (MINOR)

- **`EA QUantHFT_US30_v2.mq5` (v1.12 → v1.13)**: abertura de ordens passa a usar o motor de position sizing `CExecution::Calculate()` — lote, SL e TP de cada ordem saem dos modos configurados, em vez dos cálculos locais antigos.
- Novos inputs `InpSLMode` (`SL_ATR`/`SL_FIXED`) e `InpSLValue` ligados ao motor (`m_exec.SetSLMode/SetSLValue`); novo helper `OpenWithExec()` calcula `sl_points` conforme o modo e converte as distâncias retornadas em preços absolutos.
- Removidas as funções mortas `OpenPosition`, `OpenBuy`, `OpenSell` e `CalculateLot`.

## v7.2.0 — Python: Dados consolidados em `data/` (MINOR)

### O que mudou

- **Datahouse único**: todos os dados vivem em `C:\ALXQuant\data\`. Novos `miner\` (CSVs de miner), `report\` (PDFs de alpha/ghost) e `cache\asset_dna\` (joblib). Removidos `reports\` raiz, `app\alpha_miner\report\`, `app\asset_dna\_cache\` e `app\asset_dna\reports\`.
- **CSVs canônicos em `data\mql5\`**: `risk_sentiment_daily.csv` e `Calendar.csv` são gerados direto em `data\mql5\` (onde o EA lê ao vivo) e sincronizados para `Common\Files` (tester). Escrita morta em `MQL5\MQL5\Files\` removida.
- **Deduplicação**: eliminados `data\Calendar.csv` (idêntico ao de `mql5\`), `data\risk_sentiment_daily.csv` stale, `data\data_miner_xauusd.csv` stale e arquivos stale de `MQL5\MQL5\Files\`.
- **Gui corrigido**: endpoints `/api/strategy-tester/prepare` e `/api/asset-dna/run` apontavam para scripts inexistentes (`prepare_mql5_data.py`, `profiler.py`); agora usam `app\asset_dna\asset_dna_full.py`.

### Arquivos

| Arquivo | Mudança |
|---|---|
| `app/risk_sentiment/engine.py` | `OUTPUT_PATH` → `data\mql5\risk_sentiment_daily.csv`; sem `MQL5\MQL5\Files` |
| `app/build_risk_sentiment_dataset.py` | `OUTPUT` → `data\mql5\risk_sentiment_daily.csv`; sem `MQL5\Files` |
| `config.py` | `FOREX_FACTORY_CSV` default → `data\mql5\Calendar.csv` |
| `app/alpha_miner/alpha_miner.py` | `REPORT_DIR` → `data\report`; `FOREXCAL_PATH` → `data\mql5\Calendar.csv` |
| `app/alpha_research.py` | output default → `data\report\alpha_research_report.pdf` |
| `app/asset_dna/*.py` | `cache_dir` → `data\cache\asset_dna` |
| `gui/html/serve.py` | endpoints apontam para `asset_dna_full.py`; cache em `data\cache\asset_dna` |

---

## v7.12.0 — Leitura de CSV dual-path + hard-fail na inicialização (MINOR)

### O que mudou

- **Leitura dual-path**: `Calendar.csv` e `risk_sentiment_daily.csv` agora são lidos via `FILE_COMMON` no Strategy Tester e via Kernel32 (`C:\ALXQuant\data\mql5\`) ao vivo. O sandbox do tester bloqueia `CreateFileW` com `OPEN_EXISTING` (leitura), embora `GetFileAttributesW` passe e a escrita do `DataMiner` funcione — a troca para Kernel32 (commit `83d562a`) causou falha em cascata no tester.
- **`Timefilter.mqh` (7.14 → 7.15)** e **`RiskSentiment.mqh` (7.16 → 7.17)**: novo método privado `ReadCSVContent()` seleciona o caminho por `MQLInfoInteger(MQL_TESTER)`; `Init()` retorna `bool`.
- **`EA Quant_v7.mq5` (v7.11.1 → v7.12.0)**: `OnInit` falha (`INIT_FAILED`) quando o RiskSentiment não carrega (sempre obrigatório) e quando o `Calendar.csv` não carrega com `InpNewsEnabled=true`. Sem news filter, o Timefilter segue tolerante.
- **Python**: pipelines (`engine.py`, `build_risk_sentiment_dataset.py`) agora sincronizam os CSVs para `Common\Files` (escrita atômica `.tmp` + `os.replace`), garantindo dados UTF-8 atuais no tester.

### Arquivos

| Arquivo | Mudança |
|---|---|
| `Timefilter.mqh` | `7.14 → 7.15`; `ReadCSVContent()` dual-path + `bool Init()` |
| `RiskSentiment.mqh` | `7.16 → 7.17`; `ReadCSVContent()` dual-path + `bool Init()` |
| `EA Quant_v7.mq5` | `v7.11.1 → v7.12.0`; hard-fail no `OnInit` |
| `app/risk_sentiment/engine.py` | sync CSVs para `Common\Files` |
| `app/build_risk_sentiment_dataset.py` | sync CSVs para `Common\Files` |

---

## v7.11.1 — Fix leitura de CSV no Strategy Tester (PATCH)

### O que mudou

- **`Timefilter.mqh` (7.13 → 7.14)** e **`RiskSentiment.mqh` (7.15 → 7.16)**: `CreateFileW` de leitura passa a usar `share_mode = FILE_SHARE_READ | FILE_SHARE_WRITE` (1|2) em vez de apenas `FILE_SHARE_READ`, alinhado ao `DataMiner` (que escreve no mesmo diretório com sucesso no tester). O branch de erro agora imprime `GetLastError()` para expor o código real da falha.
- **Motivo**: no Strategy Tester, `Calendar.csv` e `risk_sentiment_daily.csv` existiam em `C:\ALXQuant\data\mql5\`, com ACLs ok e legíveis via .NET, mas o Timefilter/RiskSentiment reportavam "CSV nao encontrado". A mensagem não refletia a causa; o share_mode restrito podia falhar quando o arquivo estivesse aberto por outro processo.

### Arquivos

| Arquivo | Mudança |
|---|---|
| `Timefilter.mqh` | `7.13 → 7.14`; share `1|2` + `GetLastError()` na falha de leitura |
| `RiskSentiment.mqh` | `7.15 → 7.16`; share `1|2` + `GetLastError()` na falha de leitura |
| `EA Quant_v7.mq5` | `v7.11.0 → v7.11.1` |

---

## v7.11.0 — Nova estratégia: Range Breakout (CRangeBreakout) (MINOR)
### O que mudou

- **`RangeBreakout.mqh` (7.12 → 7.20)**: `CRangeBreakout` refatorado para o padrão ALXQuantCore. Removidos os globais de file-scope (`InpStrategy_RM_*`, incluindo `magic`, `weight`, `comm`, `be`, `distance`, `step`) e os getters `GetLotWeight`/`GetComm`. Novo `Init(symbol, magic, min_range, max_range, hl_filter, be, distance, step, enabled)` recebe os parâmetros do EA; sinal e trailing passam a ser controlados por `m_enabled`. A lógica de sinal (padrões bull/bear + filtros de alternância e anti-sobreposição, em vela fechada) foi mantida.
- **`EA Quant_v7.mq5` (v7.10.3 → v7.11.0)**: integração da estratégia BreakOut.
  - Novo grupo de inputs `▸ 6. Range Breakout`: `InpBreakout_MinRange` (5), `InpBreakout_MaxRange` (30), `InpBreakout_HLFilter` (10), `InpBreakout_BE` (120), `InpBreakout_Distance` (80), `InpBreakout_Step` (60).
  - `OnInit`: `m_breakout.Init(...)` quando `InpStrategy_breakout` estiver habilitado.
  - `OnTick`: bloco de sinal após o Mean Reversal, gated por `InpStrategy_breakout && can_open_trade && spread<2 && VIX<19 && !yieldInverted && brk_score>0`; executa via `m_exec.Calculate`/`m_exec.Execute` com signature `BK`, conta em `sets.m_daily_trades_BK` e notifica no Telegram.
  - Posições BK usam o trailing/breakeven global do EA (mesmo magic de `sets.m_magic`).

### Arquivos

| Arquivo | Mudança |
|---|---|
| `RangeBreakout.mqh` | `7.12 → 7.20`; `Init` com params, sem globais, `m_enabled` |
| `EA Quant_v7.mq5` | `v7.10.3 → v7.11.0`; inputs + `OnInit` + bloco BreakOut |

**Nota:** `InpStrategy_breakout` continua `false` por default — para testar, habilite o input e ajuste `MinRange`/`MaxRange` (5–30 barras no timeframe atual).

---

## v7.10.3 — Fix Mean Reversal: sinal avalia a última vela fechada (barra 1) (PATCH)

### O que mudou

- **`MeanReversal.mqh` (7.14 → 7.15)**: `SignalInitial()` usava a barra em formação (barra 0) para a cor do candle. Como o EA avalia o sinal apenas no **open** de cada barra (`if(time_0==PrevBars) return;`), naquele instante `open0 == close0` e a condição de cor nunca era verdadeira → `SignalInitial()` retornava **0 sempre**. Agora usa a **última vela fechada** (`iOpen/iClose` na barra 1), tornando o sinal determinístico e funcional em qualquer modo de teste.
- **`EA Quant_v7.mq5` (v7.10.2 → v7.10.3)**: removido o Print de diagnóstico (`### Signal`).

### Arquivos

| Arquivo | Mudança |
|---|---|
| `MeanReversal.mqh` | `7.14 → 7.15`; cor do candle = última vela fechada (barra 1) |
| `EA Quant_v7.mq5` | `v7.10.2 → v7.10.3`; remove print de diagnóstico |

---

## v7.10.2 — Fix Mean Reversal: linhas trocadas nos sinais + UpdateLines "chase" (PATCH)

### O que mudou

- **`MeanReversal.mqh` (7.13 → 7.14)**: `SignalInitial()` comparava com as linhas **trocadas** em relação ao GoldRush Pro original — BUY checava a linha superior (`buy_line`) e SELL a inferior (`sell_line`). Agora BUY = candle vermelho + `Ask <= sell_line` (linha inferior) e SELL = candle verde + `Bid >= buy_line` (linha superior), fiéis ao EA de origem. `UpdateLines()` virou **chase**: as linhas perseguem o preço (`buy_line` segue `Ask+dist`, `sell_line` segue `Bid-dist`) e são impedidas de cruzar, como no original.
- **`EA Quant_v7.mq5` (v7.10.1 → v7.10.2)**: removidos o `can_run_meal = true;` forçado e os Prints de debug (`### 01`, `### me_dir`).

### Arquivos

| Arquivo | Mudança |
|---|---|
| `MeanReversal.mqh` | `7.13 → 7.14`; sinais com as linhas corretas + `UpdateLines` chase |
| `EA Quant_v7.mq5` | `v7.10.1 → v7.10.2`; remove debug forçado |

---

## v7.10.1 — Fix CMeanReversion: init do símbolo/magic e sinal SELL (PATCH)

### O que mudou

- **`MeanReversal.mqh` (7.12 → 7.13)**: `Init()` agora recebe `(symbol, magic, dist)` e inicializa de fato o objeto — `m_symbol.Name()`, `m_symbol.Refresh()`, `m_symbol.RefreshRates()` e `m_magic` + `m_trade.SetExpertMagicNumber()`. Antes o símbolo ficava vazio (`CSymbolInfo` padrão tem `m_name=NULL`), fazendo `iOpen/iClose` retornarem 0 → `SignalInitial()` nunca produzia sinal.
- **`EA Quant_v7.mq5` (v7.10.0 → v7.10.1)**: chamada atualizada para `m_meanRev.Init(_Symbol, sets.m_magic, InpMR_Distance)` e correção do lado SELL — `mr_dir == -1` → `mr_dir == 2` (a classe retorna `1=Buy, 2=Sell`).
- **`.set`**: inputs MR antigos (`InpMR_EntryZScore/ExitZScore/Lookback/OULookback`) substituídos por `InpMR_Distance`.

### Arquivos

| Arquivo | Mudança |
|---|---|
| `MeanReversal.mqh` | `7.12 → 7.13`; `Init(symbol, magic, dist)` inicializa `m_symbol`/`m_magic` |
| `EA Quant_v7.mq5` | `v7.10.0 → v7.10.1`; chamada `Init` + fix SELL (`mr_dir == 2`) |
| `EA Quant_v7.set` | inputs MR antigos → `InpMR_Distance` |

---

## v7.10.0 — RiskManager: presets agora definem todos os parâmetros (incluindo limites de janela) (MINOR)

### O que mudou

- **Presets completos**: `SetPresetLimits()` passa a preencher **todos** os parâmetros de cada preset (FTMO Phase 1, Phase 2, Conservator), incluindo os 6 limites de PnL por janela (`daily/weekly/monthly × profit/loss`) e o modo `RM_LIMIT_PCT`. Nenhum limite fica zerado por omissão — os valores são os default do preset e podem ser revisados manualmente.
- **Preset manda**: quando um preset está selecionado, ele define os limites de janela (sobrescreve os inputs). `LoadWindowLimits()` (leitura dos inputs `InpDailyLimitProfitValue` etc.) fica restrito ao modo manual (`RM_MANUAL`/`RM_ALXQUANT`).
- **Valores default por preset** (revisáveis manualmente):

| Parâmetro | FTMO P1 | FTMO P2 | Conservator |
|---|---|---|---|
| `limit_mode` | PCT | PCT | PCT |
| `daily_profit_limit` | 5.0 | 3.0 | 1.0 |
| `daily_loss_limit` | 5.0 | 5.0 | 0.9 |
| `weekly_profit_limit` | 10.0 | 6.0 | 2.0 |
| `weekly_loss_limit` | 8.0 | 8.0 | 1.5 |
| `monthly_profit_limit` | 8.0 | 5.0 | 2.2 |
| `monthly_loss_limit` | 5.0 | 5.0 | 1.8 |

### Arquivos

| Arquivo | Mudança |
|---|---|
| `RiskManager.mqh` | `7.70 → 7.80`; presets com todos os parâmetros; `LoadWindowLimits()` só no modo manual |
| `EA Quant_v7.mq5` | `v7.9.0 → v7.10.0`; nenhuma mudança de código |

---

## v7.9.0 — RiskManager: limites de PnL por janela (Diário/Semanal/Mensal × Ganho/Perda) com modo $/% (MINOR)

### O que mudou

- **Limites de PnL por janela unificados**: 6 limites — Diário, Semanal e Mensal, cada um com Ganho (profit) e Perda (loss) — avaliados sobre o **PnL acumulado (realizado + floating)** da janela, não mais só sobre pisos de equity. Bloqueiam novas ordens até o reset da janela (trava de lucro / proteção de perda).
- **Modo Financeiro/Percentual**: enum global `InpRM_LimitMode` (`RM_LIMIT_MONEY` = $, `RM_LIMIT_PCT` = %). **Um único input por limite serve para os dois modos** (`InpDailyLimitProfitValue`, `InpDailyLimitLossValue`, `InpWeeklyLimitProfitValue`, `InpWeeklyLimitLossValue`, `InpMonthlyLimitProfitValue`, `InpMonthlyLimitLossValue`; `0 = off`).
- **Base do percentual** = saldo no **início da janela**: `day_start_balance` (diário), `week_start_balance` (semanal, nova referência capturada no rollover de segunda-feira), `monthly_ref_balance` (mensal).
- **Janela semanal nova**: `weekly_pnl` acumulado no `RefreshPnL()` + rollover semanal no `Update()` (detecção via `WeeklyKey()` = segunda-feira) que zera o PnL, captura o saldo de referência e desbloqueia as razões semanais.
- **Razões de bloqueio novas**: `RM_REASON_DAILY_PROFIT`, `RM_REASON_WEEKLY_PROFIT`, `RM_REASON_WEEKLY_LOSS`, `RM_REASON_MONTHLY_LOSS` (ganho mensal reutiliza `PROFIT_TARGET`). `IsDailyReason()`/`IsWeeklyReason()`/`IsMonthlyLossReason()` guiam os desbloqueios por rollover.
- **Inputs manuais de equity floor removidos** (unificados): `InpRM_DailyLossPct`, `InpRM_MaxDrawdownPct`, `InpRM_ProfitTargetPct`, `InpRM_DD_Mode`, `InpRM_DLL_Mode`. O modo manual passa a usar somente os 6 limites de PnL; os **presets** (FTMO/Conservator) mantêm os pisos de equity internos intactos (compliance) + leem os 6 novos inputs como camada extra (`0=off` por padrão).
- **Persistência GV** estendida: `WEEK` (chave da semana), `WEEKBAL` (saldo de referência semanal), `WEEKSET` (flag de captura) — sobrevive a restarts.
- **Guard de config** `SetRiskPerTradePct()`: agora compara o risco por trade também contra os limites de perda por janela (converte $→% do saldo-base).
- **GetWeeklyPnL()** novo getter público.

### Arquivos

| Arquivo | Mudança |
|---|---|
| `RiskManager.mqh` | `7.60 → 7.70`; limites de PnL por janela ($/% unificado), janela semanal, enum `ENUM_RM_LIMIT_MODE`, persistência estendida |
| `EA Quant_v7.mq5` | `v7.8.0 → v7.9.0`; nenhuma mudança de código |
| `EA Quant_v7.set` | inputs antigos removidos; 6 novos limites + `InpRM_LimitMode` adicionados |

---

## v7.8.0 — RiskManager: auditoria completa (conformidade real FTMO, buffer, persistência) (MINOR)

### O que mudou

- **Max Drawdown estático REAL**: `RM_DD_STATIC` agora é ancorado no **saldo inicial** e **nunca reseta** — alinhado à regra oficial FTMO 2-Step (corrige divergência da v7.5.0, em que o DD estático resetava mensalmente). Novo modo `RM_DD_STATIC_MONTHLY` (3): janela mensal com reset no rollover (usado pelo preset Conservator). Presets atualizados: `RM_FTMO_PHASE1/2` → `RM_DD_STATIC` + `RM_DLL_FTMO`; `RM_CONSERVATOR` → `RM_DD_STATIC_MONTHLY` + 0.9% DD + 2.2% target + consistency 0.
- **Buffer de segurança** `InpRM_BufferPct` (default 0.5): acrescenta um colchão ao piso de DD e de daily loss — o EA para antes do limite real da firma (recomendação de prop-firm para evitar violação por spread/slippage).
- **Persistência via GlobalVariables**: estado crítico (saldo inicial, pico, referências diária/mensal, contagens, bloqueio e motivo) é gravado em `ALX_RISK_<login>_<magic>_*` e restaurado no `Init()` — o EA sobrevive a restarts sem perder a janela de DD nem reiniciar contadores.
- **Razão de bloqueio tipada**: enum `ENUM_RM_BLOCK_REASON` + `IsDailyReason()/IsMaxDrawdownReason()/IsProfitTargetReason()` no lugar de string-matching frágil.
- **Contagem de trades por posição única**: `RefreshPnL()` agrega por `DEAL_POSITION_ID` — fechamento parcial não infla mais o contador diário.
- **Close-on-breach robusto**: `Block()` verifica retcode da operação e remove ordens pendentes (`TRADE_ACTION_REMOVE`) além de fechar posições.
- **Manual limits**: `ApplyManualLimits()` com `0 = desligado` (antes, um piso implícito de 0.1% impedia desligar).
- **Performance**: scan de histórico com throttle de 30s (era 2s) + `OnTradeTransaction()` forçando refresh imediato; `ManagePositions()` com passes limitados (10).

### Arquivos

| Arquivo | Mudança |
|---|---|
| `RiskManager.mqh` | `7.50 → 7.60`; auditoria completa (DD estático real, buffer, persistência GV, enum de bloqueio, contagem por posição única) |
| `EA Quant_v7.mq5` | `v7.7.0 → v7.8.0`; hook `m_risk.OnTransaction(trans)` no `OnTradeTransaction` |

---

## v7.7.0 — Dados MQL5↔Python concentrados em `data\mql5` (sem sandbox) (MINOR)

### O que mudou

- **Fim do sandbox `FILE_COMMON`**: o EA agora lê `risk_sentiment_daily.csv` e `Calendar.csv` diretamente de `C:\ALXQuant\data\mql5\` via Kernel32 (`CreateFileW`/`ReadFile`, sem passar pelo data-folder do MQL5). O diretório oficial de intercâmbio com o Python é `C:\ALXQuant\data\mql5\` — nada mais é lido de `Common\Files`.
- **RiskSentiment.mqh** (`7.14 → 7.15`): `LoadCSV()` reescrito de `FileOpen(FILE_COMMON)` para leitura WinAPI com path absoluto `ALX_MQL5_DATA_DIR + risk_sentiment_daily.csv`.
- **Timefilter.mqh** (`7.12 → 7.13`): `CarregarNoticiasCSV()` reescrito para ler `Calendar.csv` de `C:\ALXQuant\data\mql5\` via Kernel32 (mesmo padrão).
- **DataMiner**: default `InpDataMinerPath` mudou de `C:\ALXQuant\data\` para `C:\ALXQuant\data\mql5\` (input do EA e `.set` `EA Quant_v7.set`), alinhando a escrita ao mesmo diretório de leitura.
- **Defesas de compilação**: imports kernel32 protegidos por `#ifndef ALX_KERNEL32_READ` e constantes (`HANDLE`/`PVOID`/`GENERIC_READ`…) por guards `#ifndef`, evitando redefinição entre módulos na mesma unidade de compilação.

### Arquivos

| Arquivo | Mudança |
|---|---|
| `RiskSentiment.mqh` | `7.14 → 7.15`; leitura CSV via Kernel32 de `data\mql5` |
| `Timefilter.mqh` | `7.12 → 7.13`; leitura `Calendar.csv` via Kernel32 de `data\mql5` |
| `EA Quant_v7.mq5` | `v7.6.0 → v7.7.0`; `InpDataMinerPath` default → `C:\ALXQuant\data\mql5\` |
| `EA Quant_v7.set` | `InpDataMinerPath=C:\ALXQuant\data\mql5\` |

---

## v7.6.0 — Parser de sentimento tolerante ao schema + yield curve no meal (MINOR)

### O que mudou

- **Parser tolerante**: `CRiskSentiment::LoadCSV()` agora aceita `roro_score` (alias de `global_risk_score`) e `dxy` (alias de `usd_index`). Antes, o CSV gerado por `risk_sentiment/engine.py` (`roro_score, dxy`) fazia `LoadCSV()` falhar — os filtros de VIX e yield curve ficavam inertes. Agora o CSV carrega quando os dados existirem.
- **Meal alinhado**: `can_run_meal` passa a exigir `!IsYieldCurveInverted()` (mesmo filtro que `can_run_trend` já tinha).
- **Comportamento atual**: enquanto o CSV não tiver VIX/yields reais (VIX=0), os filtros seguem passando (fail-open) — até a atualização do CSV ser corrigida no pipeline Python.

### Arquivos

| Arquivo | Mudança |
|---|---|
| `RiskSentiment.mqh` | `7.13 → 7.14`; parser com aliases `roro_score`/`dxy` |
| `EA Quant_v7.mq5` | `v7.5.0 → v7.6.0`; meal com `!IsYieldCurveInverted()` |

> **Nota (a partir da v7.7.0):** o CSV agora é lido diretamente de `C:\ALXQuant\data\mql5\risk_sentiment_daily.csv` via Kernel32 — não usa mais `Common\Files` (sandbox).

---

## v7.5.0 — Max Drawdown vira janela MENSAL (desbloqueio por dia/mês) (MINOR)

### O que mudou

- **Max Drawdown mensal**: a janela de Max Drawdown agora reseta no rollover mensal — nova referência de saldo (`monthly_ref_balance`) e reset dos picos (`peak_balance`/`max_eod_balance`). O breach bloqueia até o fim do mês, não para sempre.
- **Semântica de desbloqueio**: riscos **diários** (Daily Loss) destravam no rollover **diário**; riscos **mensais** (Profit Target + Max Drawdown) destravam no rollover **mensal**. `IsPermanentReason()` foi removida; novas helpers `IsMaxDrawdownReason()`/`IsDailyReason()`.
- **Fim do deadlock**: antes, um breach de Max Drawdown congelava a conta permanentemente (ex: Real Conservator 0.9% em $10.000 travava em $9.909,04 sem nunca destravar). Agora a conta volta a operar no mês seguinte com referência renovada — o bot funciona independente do preset.

### Arquivos

| Arquivo | Mudança |
|---|---|
| `RiskManager.mqh` | `7.32 → 7.50`; janela mensal de Max DD + desbloqueio mensal |
| `EA Quant_v7.mq5` | `v7.4.1 → v7.5.0` |

---

## v7.4.1 — Guard de config (risco vs drawdown) + fix trailing ATR mudo (PATCH)

### O que mudou

- **Guard de configuração**: novo `CRiskManager::SetRiskPerTradePct(pct)` avisa no Init quando `risco por trade (LOT_RISK) >= MathMin(MaxDrawdown, DailyLoss)` — situação em que o primeiro stop-out viola o limite e bloqueia permanentemente (ex: Real Conservator 0.9% DD + 1% risco/trade). Aviso intermediário quando o risco é >50% do limite.
- **Fix trailing ATR mudo**: `TRAIL_ATR` com `InpTrailDistance<=0` (kv=0 → banda não computa) agora cai para fallback `mult 1.0` com warning 1x, em vez de ficar desativado silenciosamente.

> **Diagnóstico do "parou de operar após perda ~$100":** o bloqueio foi do RiskManager (`BLOCKED: Max Drawdown` — permanente), causado pela combinação preset **Real Conservator (0.9% DD = $90 em $10.000)** + **LOT_RISK 1% (~$100/trade)**. Para voltar a operar, use preset **FTMO Phase 2 (5% DD)** e/ou `InpLotValue ≤ 0.5`.

### Arquivos

| Arquivo | Mudança |
|---|---|
| `RiskManager.mqh` | `7.31 → 7.32`; `SetRiskPerTradePct()` + warning no Init |
| `Execution.mqh` | `7.40 → 7.41`; `TrailATRMultiplier()` fallback 1.0 + warning |
| `EA Quant_v7.mq5` | `v7.4.0 → v7.4.1`; chama o guard quando `InpLotMode==LOT_RISK` |
| `CHANGELOG_MQL.md` | v7.4.1 entry |

---

## v7.4.0 — Trailing Stop unificado + modo ATR seguindo a banda StopATR (MINOR)

### O que mudou

- **Inputs consolidados**: os 4 inputs de trailing (Pips + ATR Mult para distância e step) viram 2:
  - `InpTrailDistance` — **pips** no modo FIXED, **múltiplo ATR (Kv)** no modo ATR.
  - `InpTrailStep` — **pips**, único para os dois modos.
- **Modo `TRAIL_ATR` novo**: o SL trailing passa a **seguir a linha StopATR** (mesma banda usada no SL de entrada — `ComputeStopATRBands`): BUY segura o `support`, SELL segura a `resistance`, recomputada no runtime via `CExecution::ComputeTrailBands()`. Antes o "ATR" era só uma distância fixa calculada na entrada.
- Sempre **após o breakeven** (mesmo gate do trailing fixo). Validações `min_stop`/`freeze_level`/monotônico preservadas.

### Arquivos

| Arquivo | Mudança |
|---|---|
| `Execution.mqh` | `7.20 → 7.40`; `m_trail_distance`+`m_trail_step`, setters `SetTrailDistance/SetTrailStep`, `ComputeTrailBands()` |
| `enums.mqh` | `7.12 → 7.13`; comentário `TRAIL_ATR` = Follow StopATR band |
| `EA Quant_v7.mq5` | `v7.3.1 → v7.4.0`; inputs novos, `Trailing()` segue a banda em ATR |
| `EA Quant_v7.set` | migrado para novos inputs (modo ATR: distance 0.9, step 0.6) |
| `CHANGELOG_MQL.md` | v7.4.0 entry |

---

## v7.3.1 — RiskManager: Profit Target mensal com reset (PATCH)

Correção de semântica do v7.3.0: a meta de lucro é **mensal** e **reseta a cada mês** (antes era acumulada e permanente, e o bot parava de operar pelo resto do ano após bater a meta no 1º mês). Agora:

- Bateu a meta no mês → fecha posições e para de abrir até o fim do mês; no 1º dia do mês seguinte o target e a consistency são zerados e o EA reabre.
- **Consistency window mensal**: melhor dia ≤ % do lucro do **mês** (reseta junto com a meta).
- **Max Drawdown continua permanente** (não reseta no rollover mensal).

### Arquivos

| Arquivo | Mudança |
|---|---|
| `RiskManager.mqh` | `7.30 → 7.31`; target mensal, reset mensal, consistency mensal, `IsProfitTargetReason()` |
| `EA Quant_v7.mq5` | `v7.3.0 → v7.3.1` |
| `CHANGELOG_MQL.md` | v7.3.1 entry |
| `README.md` | Esta seção |

---

## v7.3.0 — RiskManager: presets prop firm, drawdown/daily-loss models, profit target acumulado, consistency ativa

### O que mudou

- **Presets reescritos** (`ENUM_RM_PRESET`): `FTMO Phase 1` (8% target, 5% daily, 5% DD), `FTMO Phase 2` (5% target, 5% daily, 5% DD), `Real Conservator` (2.2% target, 0.9% DD, consistency off) e `RM_ALXQUANT` (usa os inputs manuais `InpRM_*` para ajuste livre).
- **Max Drawdown selecionável** (`ENUM_RM_DD_MODE` + `InpRM_DD_Mode`): `STATIC` (piso fixo no saldo inicial — FTMO 2-Step/FundedNext), `TRAILING_EOD` (piso = maior saldo de fechamento de dia − % do inicial — Topstep/FTMO 1-Step) e `TRAILING_INTRADAY` (piso = maior equity − % do inicial — Apex). Breach = **bloqueio permanente**.
- **Daily Loss selecionável** (`ENUM_RM_DLL_MODE` + `InpRM_DLL_Mode`): `DAY_START` (pct do equity do início do dia) ou `FTMO` (fórmula oficial: saldo da meia-noite − % do capital inicial).
- **Profit Target acumulado e permanente**: `(balance − initial)/initial ≥ target` bloqueia definitivamente. Antes era avaliado por mês com gate de `min_trading_days` — o bot seguia operando com 8% de lucro num target de 5% (FTMO verification).
- **Consistency ativada**: `CRiskManager::ManagePositions()` agora é chamada no OnTick do EA. Agregação por dia (realizado + floating), fechamento preventivo do winner e bloqueio pré-abertura — melhor dia ≤ % do lucro total.
- **Removidos**: `InpRM_MaxConsecLoss` (nunca executado), `InpRM_MinTradingDays`, `InpRM_PositionStopUSD` (Per-Position Stop $).
- **Fix**: reset mensal não desbloqueia mais `Profit Target`/`Max Drawdown` (permanentes). Scan de histórico throttled (~1x/2s). Init imprime os parâmetros efetivos e avisa quando um preset sobrescreve inputs manuais.

### Arquivos

| Arquivo | Mudança |
|---|---|
| `RiskManager.mqh` | `7.13 → 7.30`; presets, DD/DLL enums, target acumulado, consistency, limpezas |
| `EA Quant_v7.mq5` | `v7.2.0 → v7.3.0`; `m_risk.ManagePositions()` no OnTick |
| Perfis tester `.set`/`.ini` | Inputs RM novos, órfãos removidos, preset FTMO Phase 2 |
| `CHANGELOG_MQL.md` | v7.3.0 entry |
| `README.md` | Esta seção |

---

## v6.7.0 — profiler_v5: Merge Institutional Math + Full Report

Esta versão unifica a matemática institucional do `profiler_v4.py` (DFA, Kalman, FFD dinâmico, KSG Transfer Entropy, Combinatorial Purged Cross-Validation) com o pipeline completo de relatórios do `profiler.py` original (~16 charts, PDF de 10+ seções, narrativas detalhadas).

### Correções incluídas

- **HMM lookahead bias** — `predict()` agora treina apenas em dados passados (causal)
- **JSON NaN/Inf** — encoder custom `_SafeEncoder` serializa NaN/Inf como `null` em vez de strings
- **Atomic write** — JSON export usa arquivo temporário + `shutil.move()`
- **main() try/except** — falha em qualquer fase loga o erro e exit(1) em vez de silêncio

### Arquivos

| Arquivo | Mudança |
|---|---|
| `app/asset_dna/profiler_v5.py` | **(novo)** merge v4 math + v2 report pipeline |
| `app/asset_dna/merge_v5.py` | Script de merge (uso interno) |
| `EA Quant.mq5` | `#property version 6.700`, `EA_VERSION v6.7.0` |
| `CHANGELOG_PYTHON.md` | v6.7.0 entry |
| `README.md` | Esta seção |

---

## v6.6.0 — Asset DNA + Execution Log Streaming + Dashboard Fixes

Esta versão adiciona o botão **ASSET DNA** no dashboard, streaming real-time de subprocessos para o Execution Log, e correções de layout para monitores menores.

### Novas funcionalidades

- **ASSET DNA** — novo botão roxo no dashboard (FastAPI endpoint `/api/asset-dna/run`) que executa `app/asset_dna/profiler.py` com feedback RUNNING/OK/FAIL e streaming de output em tempo real
- **Execution Log streaming** — toda execução de subprocesso (Strategy Tester e Asset DNA) tem stdout/stderr exibido linha-a-linha no Execution Log via `_run_subprocess_stream()`
- **Strategy Tester refatorado** — migrado para o mesmo helper de streaming

### Correções

- **Layout flexível** — body convertido para flex column com `flex-shrink` e `min-height` para manter bottom panels no viewport sem scroll infinito
- **Fontes reduzidas** — 10px em tabelas, 11px em painéis para melhor adaptação a 1366×768
- **Macro table** — colunas com `table-layout: fixed` e larguras explícitas para alinhar valores
- **showToast → toast** — corrigido bug que impedia feedback de erro do Strategy Tester
- **FastAPI lifespan** — startup event migrado para `lifespan` pattern (elimina `DeprecationWarning`)

### Arquivos modificados

| Arquivo | Mudança |
|---|---|
| `EA Quant.mq5` | `#property version 6.600`, `EA_VERSION v6.6.0` |
| `serve.py` | `_run_subprocess_stream()` helper, `/api/asset-dna/run`, ST refatorado, lifespan pattern |
| `dashboard.html` | Botão ASSET DNA adicionado |
| `alxquant.js` | `runAssetDna()`, `showToast` → `toast` |
| `alxquant.css` | Layout flex, fontes 10/11px, macro columns, `.ad-btn` style |
| `CHANGELOG_MQL.md` | v6.6.0 entry |
| `CHANGELOG_PYTHON.md` | v6.6.0 entry |
| `README.md` | Esta seção |

---

## v6.5.1 — Estratégia Tester + Bridge de Dados

Esta versão implementa a ponte completa entre o Python backend (DuckDB/serve.py) e o MQL5 EA para uso no **Strategy Tester** com dados reais.

### Novas funcionalidades

- **STRATEGY TESTER** — novo botão no dashboard (FastAPI endpoint `/api/strategy-tester/prepare`) que gera em segundos os 3 arquivos que o EA precisa para backtest: `risk_sentiment_daily.csv`, `Calendar.csv` e `asset_profile_<SYM>_<TF>.json`
- **FileReader.mqh** — leitor de arquivos usando `msvcrt.dll` (`_wfopen`/`fread`/`fclose`) para bypassar o sandbox do MQL5 e ler de `C:\ALXQuant\data\mql5\` diretamente
- **Data bridge unificado** — RiskSentiment, Timefilter, JsonParser e AssetProfileLoader agora usam FileReader quando `MQL5_DATA_PATH` está definido

### Correções

- `InpAssetProfilePath` agora tem default `""` (vazio) — o EA constrói dinamicamente `asset_profile_<SYM>_<TF>.json` para o símbolo real em backtest, sem hardcoded paths
- `profiler.py` — `report_dir` alterado de `app/asset_dna/reports/` para `C:\ALXQuant\data\mql5\` (escrita direta no local de leitura do EA)
- `prepare_mql5_data.py` — removida lógica de cópia de `reports/asset_dna/`; agora verifica existência ou gera skeleton
- 4 arquivos `.set` / `.ini` atualizados com `InpAssetProfilePath=` vazio

### Arquivos modificados

| Arquivo | Mudança |
|---|---|
| `EA Quant.mq5` | `MQL5_DATA_PATH`, `InpAssetProfilePath=""`, `#property version 6.501` |
| `FileReader.mqh` | **(novo)** leitura via msvcrt.dll |
| `RiskSentiment.mqh v2.01` | LoadCSV com FileReader |
| `Timefilter.mqh v6.02` | CarregarNoticiasCSV com FileReader, sem tester guard |
| `JsonParser.mqh v1.01` | ReadFile com FileReader |
| `AssetProfileLoader.mqh` | path dinâmico por símbolo+TF |
| `profiler.py` | `report_dir` → `C:\ALXQuant\data\mql5` |
| `prepare_mql5_data.py` | simplificado, sem copy de reports |
| `serve.py` | endpoint `/api/strategy-tester/prepare` |
| `dashboard.html` | botão STRATEGY TESTER |
| `alxquant.js` | `runStrategyTester()` |
| `alxquant.css` | estilo `.st-btn` |
