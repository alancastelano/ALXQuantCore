# Auditoria ALXQuantCore — v10.2.0
**Data:** 2026-09-04

---

## Mapa de Dependências

```
ALXQuantCore.mqh (orquestrador)
├── Core/enums.mqh .............. defines (enums)
├── Core/Core.mqh ............... AutoMagicID(), AverageBar()
├── Core/Design.mqh ............. chart colors, trade lines
├── Core/Timefilter.mqh ......... session hours, news CSV
├── Core/Panel.mqh .............. dashboard visual
│   └── Modules/StatsTracker.mqh (structs AssetStats/PerfStats)
├── Modules/HumanBehavior.mqh ... jitter/anti-robot
├── Modules/MacroRegimeEngine.mqh  DFA/Hurst/entropia
├── Modules/RiskSentiment.mqh ... risco macro CSV
├── Modules/SessionProfile.mqh .. 14 sessões de exchange
├── Modules/DataMiner.mqh ....... CSV logger (★ pointer injection OK)
├── Modules/Execution.mqh ....... ordens/lot/risk (★ pointer injection OK)
├── Modules/StatsTracker.mqh .... win rate, Sharpe, Sortino
├── Modules/AccountProtector.mqh  equity guard DLL
├── Modules/Timefilter.mqh ...... ⚠️ NÃO USADO pelo orquestrador
└── Strategy/ .................... não incluídos pelo orquestrador
```

---

## Problemas Encontrados

### 1. Panel.mqh — ACOPLAMENTO DURO (CRÍTICO)

**24+ referências diretas** a globals sem null check:

| Global | Chamadas | Null Check |
|--------|----------|------------|
| `m_regime` | 14 chamadas (IsChaosRegime, GetLastHurst, GetLabel, etc.) | NENHUM |
| `m_exec` | 10 chamadas (StateToString, GetSuccessRate, IsBrokerToxic, etc.) | NENHUM |
| `sets` | 5 chamadas (Isglobal_risk, combined_dir) | NENHUM |

**Consequência**: Se `m_regime` ou `m_exec` não foram inicializados antes do Panel, o EA trava no `DrawDashboard()`.

**Padrão correto** (já usado por DataMiner/Execution): pointer injection via `Init()` + `CheckPointer()` antes de usar.

---

### 2. ALXQuantStrategy.mqh — REFERÊNCIAS OBSOLETAS (CRÍTICO)

| Referência | Problema |
|-----------|----------|
| `m_core.AverageBar()` | **Método não existe** em `Core/Core.mqh` atual |
| `m_core.sets.m_magic` | **`sets` não é membro** de `CCore` — é global file-scope em ALXQuantCore.mqh |

**Consequência**: Este arquivo **não compila** com o framework atual. É uma versão legada.

---

### 3. Execução duplicada de enums

`enLotMode` está definido em **dois lugares**:
- `Core/enums.mqh` (line ~30)
- `Modules/Execution.mqh` (line ~40)

**Consequência**: Se ambos são incluídos, pode dar conflito de redefinição.

---

### 4. Modules/Timefilter.mqh — FANTASMA

Incluído em nenhum EA ativo. O orquestrador usa `Core/Timefilter.mqh` (versão completa com news CSV). `Modules/Timefilter.mqh` é uma versão simplificada que referencia inputs de `Core/Timefilter.mqh`.

**Consequência**: Confusão — dois arquivos com nomes similares, apenas um é usado.

---

### 5. RiskManager.mqh — SUBSTITUÍDO

`AccountProtector` tomou conta das funções de `RiskManager`. O orchestrator usa `m_protector`, não `m_risk`.

**Consequência**: Código morto que confunde.

---

### 6. 3 Padrões de Include Diferentes entre EAs

| Padrão | EAs | Problema |
|--------|-----|----------|
| **A: Umbrella** (`ALXQuantCore.mqh`) | EA QUantFX, IS Green Lab | Melhorias no umbrella afetam todos |
| **B: Módulo por módulo** | EA QUantFX - Base, EA Quant Cripto, US30 | Cópia manual, fácil de ficar desatualizado |
| **C: Misto** | v1.10-Dev, v8 backups | Caótico, include paths inconsistentes |

**Consequência**: Correções no framework não propagam para EAs do padrão B/C.

---

## Plano de Correção

### Fase 1: Corrigir Panel.mqh (desacoplar)

Mudar Panel para **pointer injection** como DataMiner/Execution:

```
Init(ea_name, ea_version, tag,
     CMacroRegimeEngine *regime = NULL,
     CExecution *exec = NULL,
     Setting *settings = NULL)
```

Adicionar `CheckPointer()` antes de cada uso. Se pointer é NULL, exibir "N/A" no dashboard.

### Fase 2: Limpar Strategy/ALXQuantStrategy.mqh

- Remover ou marcar como `#ifdef LEGACY` as referências a `m_core.AverageBar()` e `m_core.sets.m_magic`
- OU restaurar esses métodos em `Core/Core.mqh` se ainda são necessários

### Fase 3: Consolidar enums

- Manter `enLotMode` apenas em `Core/enums.mqh`
- Remover de `Modules/Execution.mqh` e fazer `#include "Core/enums.mqh"`

### Fase 4: Limpar arquivos obsoletos

- Renomear `Modules/Timefilter.mqh` → `Modules/_legacy/TimefilterSimple.mqh`
- Renomear `Modules/RiskManager.mqh` → `Modules/_legacy/RiskManager.mqh`
- Mover `Modules/__backup/` para `_legacy/`

### Fase 5: Padronizar includes dos EAs

Migrar todos os EAs ativos para o padrão Umbrella (A), onde o framework é orquestrado por `ALXQuantCore.mqh` e o EA só escreve a lógica de estratégia.

---

## Prioridade

| # | Item | Impacto | Esforço |
|---|------|---------|---------|
| 1 | Panel.mqh desacoplamento | Alto (crash) | Médio |
| 2 | ALXQuantStrategy limpeza | Alto (não compila) | Baixo |
| 3 | Enums duplicados | Médio (conflito) | Baixo |
| 4 | Arquivos obsoletos | Baixo (confusão) | Baixo |
| 5 | Padronizar EAs | Alto (manutenção) | Alto |
