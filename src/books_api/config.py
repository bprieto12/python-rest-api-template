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

    # --- Database (DynamoDB) -------------------------------------------------
    # Two tables: `books` holds the actual records; `isbns` holds one pointer
    # item per ISBN (isbn -> book id), used only to enforce ISBN uniqueness via
    # a conditional write — DynamoDB has no secondary unique-constraint concept.
    # `dynamodb_endpoint_url` overrides the endpoint for local dev / tests
    # (DynamoDB Local, moto); leave unset to use real AWS.
    aws_region: str = "us-east-1"
    dynamodb_books_table: str = "books-api-books"
    dynamodb_isbns_table: str = "books-api-isbns"
    dynamodb_endpoint_url: str | None = None

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
