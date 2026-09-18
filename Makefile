.DEFAULT_GOAL := help
.PHONY: help install-uv install lock fmt lint typecheck test test-unit test-integration cov run seed seed-staging seed-production up down logs docker-build performance-smoke performance-load architecture-diagram install-hooks

AWS_REGION ?= us-east-1

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

install-hooks: ## One-time setup: install the git pre-commit hook (.pre-commit-config.yaml) so `make fmt`'s checks run automatically on every commit
	uv run pre-commit install

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

seed-staging: ## Load the mock catalogue into staging's real DynamoDB tables — no --create-tables, Terraform already owns them. Needs your own AWS credentials (not the ECS task role) with write access; see README.md
	AWS_REGION=$(AWS_REGION) \
	DYNAMODB_BOOKS_TABLE=books-api-staging-books \
	DYNAMODB_ISBNS_TABLE=books-api-staging-isbns \
	uv run python scripts/seed.py

seed-production: ## Load the mock catalogue into production's real DynamoDB tables — same caveats as seed-staging
	AWS_REGION=$(AWS_REGION) \
	DYNAMODB_BOOKS_TABLE=books-api-books \
	DYNAMODB_ISBNS_TABLE=books-api-isbns \
	uv run python scripts/seed.py

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

architecture-diagram: ## Regenerate ARCHITECTURE.md's Mermaid diagram (edit scripts/generate_architecture_diagram.py, not ARCHITECTURE.md itself)
	uv run python scripts/generate_architecture_diagram.py
