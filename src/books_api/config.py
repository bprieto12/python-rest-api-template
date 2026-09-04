"""Application settings, loaded from the environment (and an optional ``.env``)."""

from __future__ import annotations

from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # --- App ---------------------------------------------------------------
    app_name: str = "books-api"
    environment: Literal["local", "ci", "staging", "production"] = "local"
    debug: bool = False
    api_v1_prefix: str = "/api/v1"

    # --- Database --------------------------------------------------------------
    # SQLAlchemy async URL. Use the ``postgresql+asyncpg`` driver in every real
    # environment; the SQLite URL exists only for hermetic tests.
    database_url: str = "postgresql+asyncpg://books:books@localhost:5432/books"
    db_pool_size: int = 5
    db_max_overflow: int = 10
    db_echo: bool = False

    # --- OpenTelemetry ------------------------------------------------------
    # ``otel_exporter_otlp_endpoint`` maps to the standard OTEL_EXPORTER_OTLP_ENDPOINT
    # env var. When it is unset we fall back to the console exporter so the app
    # still runs without a collector.
    otel_enabled: bool = True
    otel_service_name: str = "books-api"
    otel_exporter_otlp_endpoint: str | None = None
    otel_exporter_otlp_protocol: Literal["grpc", "http/protobuf"] = "grpc"
    otel_metric_export_interval_ms: int = 15_000
    otel_console_export: bool = False


@lru_cache
def get_settings() -> Settings:
    """Return a process-wide cached :class:`Settings` instance."""
    return Settings()
