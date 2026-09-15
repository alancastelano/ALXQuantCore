from dataclasses import dataclass, field
from dotenv import load_dotenv
import os
from pathlib import Path

load_dotenv()

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DB_PATH = PROJECT_ROOT / "data" / "ALXQuantCore.duckdb"


@dataclass
class MT5Config:
    path: str = os.getenv("MT5_PATH", "")
    account: int = int(os.getenv("MT5_ACCOUNT", "0"))
    password: str = os.getenv("MT5_PASSWORD", "")
    server: str = os.getenv("MT5_SERVER", "")

@dataclass
class APIConfig:
    host: str = "127.0.0.1"
    port: int = 8000
    mql5_timeout_ms: int = 200  # timeout p/ MQL5 aguardar resposta


@dataclass
class FREDConfig:
    api_key: str = os.getenv("FRED_API_KEY", "")


@dataclass
class TradingConfig:
    symbols: tuple = ("EURUSD", "XAUUSD", "US30", "CHINAH")
    timeframes: tuple = ("M1", "M5", "M15", "H1", "H4", "D1")
    default_lot: float = 0.01
    max_lot: float = 1.0
    risk_per_trade_pct: float = 0.02  # 2% risco por trade


@dataclass
class NewsConfig:
    forex_factory_csv: str = os.getenv("FOREX_FACTORY_CSV", "C:\\ALXQuant\\data\\mql5\\Calendar.csv")


@dataclass
class Config:
    mt5: MT5Config = field(default_factory=MT5Config)
    api: APIConfig = field(default_factory=APIConfig)
    fred: FREDConfig = field(default_factory=FREDConfig)
    trading: TradingConfig = field(default_factory=TradingConfig)
    news: NewsConfig = field(default_factory=NewsConfig)


config = Config()
