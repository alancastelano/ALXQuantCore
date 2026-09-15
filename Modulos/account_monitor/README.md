# ALX Account Monitor

Monitoramento em tempo real de múltiplas contas MT5 distribuídas em VPS pelo
mundo. Módulo **independente** do ALXQuantCore (banco, GUI e servidor próprios).

```
MT5 Terminal (EA ALXAccountManager)
      │  WebRequest (HTTP/HTTPS)  + X-API-Key + timestamp + nonce
      ▼
ALX Account Monitor (FastAPI, porta 8400)
      │
      ├── auth (Master Key + auto-emissão de API Key por conta)
      ├── telemetry (normalização + persistência)
      ├── performance (P&L por deals)
      └── WebSocket (broadcast em mudança)
      ▼
GUI (static/, mesmo padrão visual ALXQuantCore)
```

## Como rodar

```bash
# 1. Defina a Master Key no .env da raiz do projeto
ACCOUNT_MONITOR_MASTER_KEY=sua-master-key-secreta
ACCOUNT_MONITOR_PORT=8400
ACCOUNT_MONITOR_HOST=0.0.0.0

# 2. Suba o servidor
python -m Modulos.account_monitor.serve
# 3. GUI em http://<ip>:8400/
```

## Registro de contas (auto-registro)

1. Instale o EA `ALXAccountManager.mq5` no terminal MT5 da conta.
2. Preencha `InpServerUrl`, `InpAccountId` e `InpMasterKey`.
3. **Adicione a URL do servidor** em `Ferramentas → Opções → Expert Advisors → Permitir WebRequest`.
4. No primeiro heartbeat o servidor autentica via Master Key e **emite uma
   API Key individual** para o `account_id`, devolvida na resposta. O EA
   cacheia e passa a usar essa key.

Não é necessário cadastrar nada manualmente no servidor.

## Segurança

- Fluxo único: `EA → servidor → GUI` (a GUI nunca acessa o MT5).
- **Nunca** são armazenadas senhas de MT5 (trading/investor). O campo `login`
  é apenas o número identificador da conta, lido do terminal já logado.
- API Keys ficam hasheadas (SHA-256) em `data/account_monitor_keys.json`.
- Validação de timestamp (±60s), nonce (anti-replay, TTL 120s), rate limit.
- Revogação: `POST /api/v1/admin/revoke/{account_id}` (requer Master Key).
- HTTPS: configure `AM_REQUIRE_HTTPS=1` no servidor de IP fixo (com proxy TLS
  na frente). Em dev local fica desligado.

## Endpoints

| Método | Path | Descrição |
|--------|------|-----------|
| POST | `/api/v1/accounts/heartbeat` | Estado da conta (a cada ~5s) |
| POST | `/api/v1/accounts/telemetry` | Estado completo + posições + deals |
| POST | `/api/v1/accounts/events` | Evento (POSITION_CLOSE etc.) |
| GET | `/api/v1/accounts` | Lista consolidada (tabela) |
| GET | `/api/v1/accounts/{id}` | Detalhe da conta |
| GET | `/api/v1/accounts/{id}/positions` | Posições abertas |
| GET | `/api/v1/accounts/{id}/performance` | P&L + curva de equity |
| GET | `/api/v1/dashboard/summary` | Cards agregados |
| WS | `/ws` | Broadcast `account_update` / `position_update` |

## Metodologia de P&L

- Daily/Weekly/Monthly são calculados a partir de **deals fechados**
  (`profit + swap + commission`) dentro da janela, **não** por diferença de
  snapshots de balance/equity.
- Depósitos/retiradas/créditos são movimentos de `BALANCE_CHANGE` e **não**
  contam como P&L.
- Janelas: Daily = 00:00 UTC; Weekly = segunda 00:00 UTC; Monthly = dia 1 00:00 UTC.
- Drawdown: equity em relação ao pico (dos snapshots), em %.

## Timezone

- Timestamps armazenados em **UTC** (o EA envia `TimeGMT()`).
- Conversão para o fuso local acontece apenas na apresentação (browser).

## Status de conexão

- `ONLINE` < 10s desde o último heartbeat
- `WARNING` 10–30s
- `OFFLINE` > 30s

Limites configuráveis via `AM_ONLINE_WARNING_SEC` / `AM_OFFLINE_SEC`.

## Estrutura

```
Modulos/account_monitor/
├── __init__.py
├── config.py        # host/porta/thresholds (.env)
├── db.py            # DuckDB separado (data/account_monitor.duckdb)
├── auth.py          # validação de chave/timestamp/nonce/rate limit
├── keys_store.py    # emissão/revogação de API Keys (SHA-256)
├── telemetry.py     # normalização + persistência + broadcast
├── performance.py   # P&L e drawdown
├── ws.py            # gerenciador WebSocket
├── serve.py         # FastAPI (autônomo)
└── static/          # GUI (index.html + css + js)
```

O banco utilizado (`data/account_monitor.duckdb`) é **separado** do
`ALXQuantCore.duckdb` para não competir por lock nem misturar domínios.