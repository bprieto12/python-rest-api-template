"""Unit tests for pydantic-settings config loading — no I/O, no app."""

from __future__ import annotations

import pytest

from books_api.config import Settings


def test_defaults_require_no_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DYNAMODB_ENDPOINT_URL", raising=False)
    settings = Settings(_env_file=None)
    assert settings.environment == "local"
    assert settings.api_v1_prefix == "/api/v1"
    assert settings.dynamodb_endpoint_url is None
    assert settings.otel_enabled is True


def test_env_vars_override_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ENVIRONMENT", "staging")
    monkeypatch.setenv("DYNAMODB_ENDPOINT_URL", "http://localhost:8001")
    monkeypatch.setenv("OTEL_ENABLED", "false")
    settings = Settings(_env_file=None)
    assert settings.environment == "staging"
    assert settings.dynamodb_endpoint_url == "http://localhost:8001"
    assert settings.otel_enabled is False


def test_unknown_env_vars_are_ignored(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SOME_UNRELATED_VAR", "whatever")
    Settings(_env_file=None)  # must not raise
