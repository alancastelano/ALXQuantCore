"""Entry point do ALX Account Monitor para empacotamento como .exe (PyInstaller).

Importa o app diretamente (nao por string) para que o PyInstaller consiga
resolver e empacotar todos os modulos. O .env, o banco e as keys ficam
ao lado do executavel (veja config.py, modo "frozen").
"""
import uvicorn

from Modulos.account_monitor import auth, db, keys_store, performance, telemetry, ws  # noqa: F401  (garante empacotamento)
from Modulos.account_monitor.config import config
from Modulos.account_monitor.serve import app


def main():
    uvicorn.run(app, host=config.host, port=config.port)


if __name__ == "__main__":
    main()