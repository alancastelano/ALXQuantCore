# PROMPT VPS — Provisionamento ALXQuant (colar no agente OpenCode DA VPS)

> Instruções para o agente rodando **dentro da VPS Windows** (RDP/admin).
> Escopo: deixar o hub QuantCore em produção. Fase 2 (CommandCenter :8500,
> EAs satélites) está FORA deste prompt.

## 0. Regras de operação (obedecer sempre)

- Shell: **Windows PowerShell 5.1**. NÃO use `&&` (use `;`). NÃO use `cd`
  dentro do comando — passe `workdir` da ferramenta. Caminhos com espaço,
  sempre entre aspas duplas.
- Nunca use shell para ler/editar arquivos (use as ferramentas Read/Edit/
  Write). Shell é só para comandos reais (git, pip, nssm, sc, schtasks...).
- Antes de cada fase, confira o estado atual (read-only). Depois de cada
  fase, execute a verificação indicada e só avance se passar.
- Se algo falhar 2x, PARE e reporte (não improvise destrutivamente).
- Nunca exiba segredos (.env, senhas) no relatório final — só confirme
  que foram preenchidos.

## 1. Inventário (verificar o que já existe)

1. `C:\ALXQuant` existe? É clone git de
   `https://github.com/alancastelano/ALXQuantCore.git`? (`git status`)
2. Versões: `python --version` (esperado 3.14), `node --version` (esperado
   20.x), `git --version`, `nssm status ALXQuant-Server` (pode não existir
   ainda — normal).
3. `C:\ALXQuant\data\ALXQuantCore.duckdb` existe (~770 MB)? Foi copiado via
   RDP antes. Se NÃO existir, PARE este item e avise o usuário (recoletar
   do zero leva horas — decisão dele).

## 2. Pré-requisitos (instalar o que faltar, ordem importa)

1. **Git for Windows** (se ausente): https://git-scm.com/download/win
2. **Python 3.14** amd64 (se ausente): https://www.python.org/downloads/
   - Marcar "Add python.exe to PATH". Confirmar com `py -3.14 --version`.
3. **Node.js 20 LTS** (se ausente): https://nodejs.org/ (`node --version`).
4. **NSSM** (se ausente): baixar https://nssm.cc/download, extrair
   `nssm.exe` (win64) para `C:\Tools\nssm\nssm.exe` e colocar no PATH
   (ou chamar pelo caminho completo).
5. **MT5 terminal — SOMENTE DADOS, sem EAs de trade**: instalar
   https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe
   - PERGUNTAR ao usuário: conta demo (login, senha, servidor da corretora).
   - Logar no terminal, deixar rodando. Habilitar login automático
     (salvar senha) para sobreviver a reboot.
   - Anotar o caminho real do `terminal64.exe` (padrão:
     `C:\Program Files\MetaTrader 5\terminal64.exe`).

## 3. Repo + ambiente Python

1. Se `C:\ALXQuant` não é clone: `git clone
   https://github.com/alancastelano/ALXQuantCore.git C:\ALXQuant`
   (se a pasta existe mas não é repo, PERGUNTAR antes de mexer).
2. `cd C:\ALXQuant\QuantCore` → `python -m venv .venv`
3. `.\.venv\Scripts\python.exe -m pip install --upgrade pip`
4. `.\.venv\Scripts\python.exe -m pip install -r requirements.txt`
   (~1,1 GB, ~10 min — aguardar conclusão, exit 0).

## 4. `.env` da VPS (PERGUNTAR os valores ao usuário, nunca inventar)

1. Copiar `C:\ALXQuant\.env.example` → `C:\ALXQuant\.env`.
2. Preencher (perguntar um a um): `MT5_ACCOUNT`, `MT5_PASSWORD`,
   `MT5_SERVER`, `MT5_PATH` (confirmar caminho do passo 2.5),
   `FRED_API_KEY` (opcional — pular se não tiver), LLM keys (opcional).
3. Confirmar: `.env` existe e NÃO aparece em `git status` (é ignorado).

## 5. Validação do sistema (gate obrigatório antes dos serviços)

Com `workdir=C:\ALXQuant\QuantCore`, usando `.\.venv\Scripts\python.exe`:

1. `python -c "import Modulos.datahouse.collector, Modulos.macro_state.registry, Modulos.risk_sentiment.engine, gui.html.serve; print('imports OK')"`
   → esperado `imports OK`.
2. `python -m pytest Modulos/calibration/tests Modulos/macro_state/tests -q`
   → esperado `11 passed`.
3. Conexão MT5 (terminal ABERTO e logado):
   `python -c "import MetaTrader5 as mt5; print(mt5.initialize()); print(mt5.version()); mt5.shutdown()"`
   → esperado `True` + versão. Se `False`, diagnosticar (terminal fechado?
   login errado? `.env`?) e NÃO avançar sem resolver ou sem ordem do usuário.

## 6. Serviços Windows (NSSM) + boot

1. Criar `ALXQuant-Server`:
   - Application: `C:\ALXQuant\QuantCore\.venv\Scripts\python.exe`
   - AppParameters: `-m uvicorn gui.html.serve:app --host 127.0.0.1 --port 8000`
   - AppDirectory: `C:\ALXQuant\QuantCore`
   - Startup: automático. `nssm start ALXQuant-Server`.
2. Criar `MT5-Terminal` (torneira de dados):
   - Application: `<caminho do passo 2.5>\terminal64.exe`
   - AppDirectory: pasta do terminal. Startup automático.
   - Confirmar no log que logou sozinho após `nssm start`.
3. Aguardar 30s e sondar: `Invoke-WebRequest http://127.0.0.1:8000/`
   → esperado HTTP 200.

## 7. Dados iniciais + agendamento

1. Confirmar `data\ALXQuantCore.duckdb` legível:
   `python -c "import duckdb; print(duckdb.query('SELECT count(*) FROM ohlc_prices').fetchall())"`
   (se a tabela ainda não existir, registrar no relatório — o coletor cria).
2. Rodar 1 coleta curta de fumaça (ex.: 1 símbolo M5, poucos dias) via
   `Modulos.datahouse.cli_collector` e confirmar linhas novas no DuckDB.
3. Revisar `data\schedules.json` (4 tasks) e registrar as tasks
   `ALX-DataHouse-*` no Task Scheduler (comandos já apontam para
   `QuantCore\.venv` — só conferir).

## 8. Relatório final (responder NESTE formato)

- Serviços: `nssm status` dos 2 + uptime.
- Sonda `:8000` → HTTP <código>.
- MT5: versão + conta logada (NÃO exibir senha).
- Testes: `11 passed` (ou o que saiu).
- Disco livre em C: (GB).
- Pendências (se houver) + o que foi perguntado ao usuário e respondido.

## FORA DE ESCOPO (não fazer)

- CommandCenter (`CommandCenter/`, `:8500`, `vite`, `npm`) — fase 2.
- EAs de trade na VPS — proibido nesta fase (só MT5 de dados).
- `deploy.ps1`/`deploy.yml` (CI) — o deploy aqui é `git pull` manual + restart.
- Abrir portas no firewall (tudo é localhost; acesso remoto via túnel SSH
  quando configurado).
