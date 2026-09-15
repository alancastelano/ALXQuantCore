"""
ALXQuant Data Collector v1.0
=================================
Conecta ao MetaTrader 5 via variáveis de ambiente (.env),
baixa dados históricos OHLC M5 em "fatias" seguras (para não sobrecarregar o servidor),
limpa, consolida e salva o dataset final.
"""

import os
import time
import pandas as pd
from datetime import datetime, timedelta
from dotenv import load_dotenv
import MetaTrader5 as mt5

# ==========================================================
# 1. CONFIGURAÇÃO INICIAL
# ==========================================================
# Carrega as variáveis do arquivo .env na raiz do projeto
load_dotenv(r'C:\ALXQuant\.env')

# Lê as variáveis de ambiente com segurança (retorna None se faltar)
MT5_PATH = os.getenv('MT5_PATH')
MT5_ACCOUNT = int(os.getenv('MT5_ACCOUNT', 0))
MT5_PASSWORD = os.getenv('MT5_PASSWORD', '')
MT5_SERVER = os.getenv('MT5_SERVER', '')

# Configurações de extração
SYMBOL = "XAUUSD"
TIMEFRAME = mt5.TIMEFRAME_M5
ANOS_HISTORICO = 5
OUTPUT_DIR = r"C:\ALXQuant\data\datasets"
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "xauusd_m5_5y.csv")

# Tamanho da fatia de tempo para pedir ao servidor (60 dias por requisição é seguro)
CHUNK_DAYS = 60


def connect_mt5():
    """Inicia o MT5 usando as credenciais do .env."""
    print("[1/4] Conectando ao MetaTrader 5...")
    
    if not MT5_PATH or not MT5_ACCOUNT:
        print("ERRO: Variáveis MT5_PATH ou MT5_ACCOUNT não encontradas no .env")
        return False

    # Tenta inicializar apontando para o terminal específico
    initialized = mt5.initialize(path=MT5_PATH)
    
    if not initialized:
        print("ERRO: Falha ao inicializar a biblioteca MT5.")
        return False

    # Tenta fazer login na conta específica
    login_ok = mt5.login(login=MT5_ACCOUNT, password=MT5_PASSWORD, server=MT5_SERVER,path=MT5_PATH)
    
    if not login_ok:
        print("ERRO: Falha no login. Verifique conta, senha e servidor no .env")
        print("Detalhes do MT5:", mt5.last_error())
        mt5.shutdown()
        return False

    # Confirma os dados da conta
    account_info = mt5.account_info()
    print("  -> Conectado com sucesso!")
    print("     Conta: {} | Servidor: {} | Saldo: ${:.2f}".format(
        account_info.login, account_info.server, account_info.balance))
    return True


def download_data():
    """Baixa os dados em fatias (chunks) para evitar timeout do broker."""
    print("\n[2/4] Baixando dados historicos ({} anos em fatias de {} dias)...".format(
        ANOS_HISTORICO, CHUNK_DAYS))
    
    data_fim = datetime.now()
    data_inicio = data_fim - timedelta(days=ANOS_HISTORICO * 365)
    
    current_start = data_inicio
    all_data = []
    chunk_num = 1
    
    while current_start < data_fim:
        current_end = current_start + timedelta(days=CHUNK_DAYS)
        if current_end > data_fim:
            current_end = data_fim

        # Puxa os dados do servidor
        rates = mt5.copy_rates_range(SYMBOL, TIMEFRAME, current_start, current_end)
        
        if rates is not None and len(rates) > 0:
            all_data.append(rates)
            print("  -> Fatia {}: {} candles ({} a {})".format(
                chunk_num, len(rates), 
                current_start.strftime('%Y-%m-%d'), 
                current_end.strftime('%Y-%m-%d')))
        else:
            print("  -> Fatia {}: Sem dados retornados.".format(chunk_num))

        # Avança o ponteiro e espera um pouco para não ser banido pelo broker
        current_start = current_end
        chunk_num += 1
        time.sleep(0.5)  # Pausa de meio segundo entre requisições

    if not all_data:
        print("ERRO: Nenhum dado foi baixado.")
        return None

    # Concatena todas as fatias em um único array NumPy
    import numpy as np
    combined_data = np.concatenate(all_data)
    return combined_data


def process_and_save(data):
    """Limpa os dados, remove duplicatas e salva em CSV."""
    print("\n[3/4] Processando e limpando o dataset...")
    
    df = pd.DataFrame(data)
    
    # Converte o tempo Unix para Datetime legível
    df['time'] = pd.to_datetime(df['time'], unit='s')
    
    # Remove possíveis duplicatas causadas pela sobreposição de fatias
    before_len = len(df)
    df = df.drop_duplicates(subset=['time']).sort_values('time').reset_index(drop=True)
    after_len = len(df)
    
    if before_len != after_len:
        print("  -> Removidas {} linhas duplicadas.".format(before_len - after_len))

    # Cria a pasta de saída se não existir
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    
    # Salva o arquivo final
    df.to_csv(OUTPUT_FILE, index=False)
    print("  -> Dataset salvo em: {}".format(OUTPUT_FILE))
    print("  -> Total final de candles: {}".format(after_len))
    
    # Mostra um resumo rápido
    print("\n  --- RESUMO DO DATASET ---")
    print("  De: {}".format(df['time'].iloc[0]))
    print("  Ate: {}".format(df['time'].iloc[-1]))
    print("--------------------------")


def main():
    start_time = time.time()
    print("=" * 50)
    print("  ALXQUANT DATA COLLECTOR v1.0")
    print("=" * 50)

    # 1. Conecta
    if not connect_mt5():
        return

    # 2. Baixa
    raw_data = download_data()
    
    if raw_data is not None:
        # 3. Processa e Salva
        process_and_save(raw_data)
        
        print("\n[4/4] Finalizado com sucesso!")
        print("Tempo total: {:.2f} segundos".format(time.time() - start_time))
    else:
        print("\n[!] Processo interrompido por falta de dados.")

    # Encerra a conexão com o MT5
    mt5.shutdown()
    print("\nConexao com MT5 encerrada.")


if __name__ == "__main__":
    main()