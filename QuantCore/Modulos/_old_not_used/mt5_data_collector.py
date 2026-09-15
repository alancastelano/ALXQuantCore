"""
ALXQuant MT5 Data Collector v1.0
==================================
Extrai dados OHLC M5 do MetaTrader 5 e persiste localmente.
Uso: python mt5_data_collector.py [--symbol XAUUSD] [--tf M5] [--years 5]
"""

import os
import sys
import time
import argparse
import pandas as pd
from datetime import datetime, timedelta
from dotenv import load_dotenv
import MetaTrader5 as mt5

load_dotenv(r'C:\ALXQuant\.env', override=True)

MT5_PATH = os.getenv('MT5_PATH')
MT5_ACCOUNT = int(os.getenv('MT5_ACCOUNT', 0))
MT5_PASSWORD = os.getenv('MT5_PASSWORD', '')
MT5_SERVER = os.getenv('MT5_SERVER', '')

TIMEFRAME_MAP = {
    'M1': mt5.TIMEFRAME_M1, 'M5': mt5.TIMEFRAME_M5, 'M15': mt5.TIMEFRAME_M15,
    'M30': mt5.TIMEFRAME_M30, 'H1': mt5.TIMEFRAME_H1, 'H4': mt5.TIMEFRAME_H4,
    'D1': mt5.TIMEFRAME_D1,
}

OUTPUT_DIR = r"C:\ALXQuant\data\datasets"
CHUNK_DAYS = 60


def connect_mt5():
    if not MT5_PATH or not MT5_ACCOUNT:
        print("ERRO: Variaveis MT5_PATH ou MT5_ACCOUNT nao encontradas no .env")
        return False
    print(f"  .env lido: conta={MT5_ACCOUNT}, server={MT5_SERVER}, path={MT5_PATH}")
    print(f"[1/4] Inicializando MT5 em: {MT5_PATH}")
    initialized = mt5.initialize(path=MT5_PATH)
    if not initialized:
        print(f"ERRO: MT5 nao inicializou. {mt5.last_error()}")
        print("Dica: Feche outros terminais MT5 e tente novamente.")
        return False
    print("  [OK] Terminal MT5 conectado")
    if MT5_ACCOUNT:
        authorized = mt5.login(MT5_ACCOUNT, password=MT5_PASSWORD, server=MT5_SERVER)
        if not authorized:
            print(f"  [AVISO] Login falhou ({mt5.last_error()}), continuando em modo demonstracao/leitura")
        else:
            print(f"  [OK] Logado na conta {MT5_ACCOUNT}")
    return True


def fetch_ohlc(symbol, timeframe_mt5, days_history):
    print(f"[2/4] Baixando dados {symbol}...")
    now = datetime.now()
    date_to = now
    date_from = now - timedelta(days=days_history)
    all_rates = []
    current_to = date_to
    current_from = max(date_from, current_to - timedelta(days=CHUNK_DAYS))
    chunk_num = 1
    while current_to > date_from:
        print(f"  Fatia {chunk_num}: {current_from.date()} -> {current_to.date()}", end="")
        rates = mt5.copy_rates_range(symbol, timeframe_mt5, current_from, current_to)
        if rates is not None and len(rates) > 0:
            df_chunk = pd.DataFrame(rates)
            df_chunk['time'] = pd.to_datetime(df_chunk['time'], unit='s')
            all_rates.append(df_chunk)
            print(f" -> {len(df_chunk)} candles")
        else:
            print(" -> vazio")
        current_to = current_from - timedelta(seconds=1)
        current_from = max(date_from, current_to - timedelta(days=CHUNK_DAYS))
        chunk_num += 1
        time.sleep(0.3)
    if not all_rates:
        print("  [ERRO] Nenhum dado retornado. Verifique se o simbolo existe no Market Watch.")
        return None
    df = pd.concat(all_rates, ignore_index=True)
    df.drop_duplicates(subset='time', keep='first', inplace=True)
    df.sort_values('time', inplace=True)
    df.reset_index(drop=True, inplace=True)
    print(f"  [OK] Total: {len(df)} candles | {df['time'].iloc[0].date()} a {df['time'].iloc[-1].date()}")
    return df


def save_dataset(df, symbol, tf_name):
    print(f"[3/4] Salvando dataset...")
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    filename = f"{symbol}_{tf_name}.csv"
    filepath = os.path.join(OUTPUT_DIR, filename)
    cols = ['time', 'open', 'high', 'low', 'close', 'tick_volume', 'spread', 'real_volume']
    available = [c for c in cols if c in df.columns]
    df_out = df[available].copy()
    df_out.to_csv(filepath, index=False, date_format='%Y-%m-%d %H:%M:%S')
    print(f"  [OK] Salvo: {filepath} ({os.path.getsize(filepath)/1024:.0f} KB)")


def main():
    parser = argparse.ArgumentParser(description='MT5 Data Collector')
    parser.add_argument('--symbol', default='XAUUSD', help='Simbolo (default: XAUUSD)')
    parser.add_argument('--tf', default='M5', choices=list(TIMEFRAME_MAP.keys()), help='Timeframe (default: M5)')
    parser.add_argument('--years', type=int, default=5, help='Anos de historico (default: 5)')
    args = parser.parse_args()

    print("=" * 55)
    print("  ALXQuant MT5 Data Collector v1.0")
    print("=" * 55)

    if not connect_mt5():
        sys.exit(1)

    tf_mt5 = TIMEFRAME_MAP[args.tf]
    df = fetch_ohlc(args.symbol, tf_mt5, args.years * 365)
    if df is None:
        mt5.shutdown()
        sys.exit(1)

    save_dataset(df, args.symbol, args.tf)

    print(f"[4/4] Finalizando...")
    mt5.shutdown()
    print("  [OK] Conexao MT5 encerrada")
    print(f"\nDataset disponivel em: {os.path.join(OUTPUT_DIR, f'{args.symbol}_{args.tf}.csv')}")
    print("=" * 55)


if __name__ == '__main__':
    main()
