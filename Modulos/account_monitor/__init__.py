"""ALX Account Monitor.

Modulo independente (isolado do ALXQuantCore) para monitoramento em tempo real
de multiplas contas MT5 distribuídas em VPS pelo mundo.

Fluxo:
    EA (MT5) --WebRequest--> FastAPI --WebSocket--> GUI (static/)

Arquitetura:
    - Banco proprio (data/account_monitor.duckdb), separado do Quant.
    - GUI propria dentro de static/ (mesmo padrao visual ALXQuantCore).
    - Auth: Master Key + auto-emissao de API Key por account_id.
    - Performance: P&L por deals fechados (profit+swap+commission), UTC.

Uso:
    python -m Modulos.account_monitor.serve
"""