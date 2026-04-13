import os
from dotenv import load_dotenv

load_dotenv(override=True)

# Algo server (TimescaleDB)
ALGO_SERVER_DB_HOST: str | None = os.getenv("ALGO_SERVER_DB_HOST")
ALGO_SERVER_DB_PORT: str | None = os.getenv("ALGO_SERVER_DB_PORT")
ALGO_SERVER_DB_USER: str | None = os.getenv("ALGO_SERVER_DB_USER")
ALGO_SERVER_DB_PASSWORD: str | None = os.getenv("ALGO_SERVER_DB_PASSWORD")
ALGO_SERVER_DB_NAME: str | None = os.getenv("ALGO_SERVER_DB_NAME")

# Windows server (BioT PostgreSQL)
WINDOWS_SERVER_DB_HOST: str | None = os.getenv("WINDOWS_SERVER_DB_HOST")
WINDOWS_SERVER_DB_PORT: str | None = os.getenv("WINDOWS_SERVER_DB_PORT")
WINDOWS_SERVER_DB_USER: str | None = os.getenv("WINDOWS_SERVER_DB_USER")
WINDOWS_SERVER_DB_PASSWORD: str | None = os.getenv("WINDOWS_SERVER_DB_PASSWORD")
WINDOWS_SERVER_DB_NAME: str | None = os.getenv("WINDOWS_SERVER_DB_NAME")
