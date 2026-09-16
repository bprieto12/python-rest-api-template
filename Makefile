.DEFAULT_GOAL := help
.PHONY: help install-uv install lock fmt lint typecheck test test-unit test-integration cov run seed up down logs docker-build performance-smoke performance-load

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

install-uv: ## Install the uv package manager (standalone installer)
	@command -v uv >/dev/null 2>&1 && { echo "uv already installed: $$(uv --version)"; exit 0; } || true
	curl -LsSf https://astral.sh/uv/install.sh | sh

install: ## Sync the virtualenv from uv.lock (incl. dev deps)
	uv sync

lock: ## Regenerate uv.lock after editing pyproject.toml
	uv lock

fmt: ## Autoformat + autofix with ruff
	uv run ruff format .
	uv run ruff check --fix .

lint: ## Lint (ruff) without fixing
	uv run ruff format --check .
	uv run ruff check .

typecheck: ## Static types (mypy, strict)
	uv run mypy src

test: ## Run the full test suite (unit + integration)
	uv run pytest

test-unit: ## Run only unit tests (pure logic, no I/O)
	uv run pytest tests/unit

test-integration: ## Run only integration tests (against an in-process moto DynamoDB double, no services needed)
	uv run pytest tests/integration

cov: ## Tests with coverage report
	uv run pytest --cov --cov-report=term-missing

run: ## Run the API with autoreload on :8000
	uv run uvicorn books_api.main:app --reload --port 8000

seed: ## Load the mock catalogue (pass CREATE_TABLES=1 to also create the tables — local dev only)
	uv run python scripts/seed.py $(if $(CREATE_TABLES),--create-tables)

up: ## Bring up the full local stack (db + collector + api)
	docker compose up --build

down: ## Tear it down and drop volumes
	docker compose down -v

logs: ## Tail the api container
	docker compose logs -f api

docker-build: ## Build the production image
	docker build -t books-api:local .

performance-smoke: ## k6 smoke test — needs `make up` running, or set BASE_URL/COGNITO_* for a deployed environment
	k6 run performance/smoke.js

performance-load: ## k6 load test — see performance/README.md's DynamoDB capacity note before pointing this at a deployed environment
	k6 run performance/load.js
