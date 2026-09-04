.DEFAULT_GOAL := help
.PHONY: help install-uv install lock fmt lint typecheck test cov run migrate revision seed up down logs docker-build

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

test: ## Run the test suite (SQLite unless TEST_DATABASE_URL is set)
	uv run pytest

cov: ## Tests with coverage report
	uv run pytest --cov --cov-report=term-missing

run: ## Run the API with autoreload on :8000
	uv run uvicorn books_api.main:app --reload --port 8000

migrate: ## Apply migrations to $$DATABASE_URL
	uv run alembic upgrade head

revision: ## Autogenerate a migration: make revision m="add rating"
	uv run alembic revision --autogenerate -m "$(m)"

seed: ## Load the mock catalogue
	uv run python scripts/seed.py

up: ## Bring up the full local stack (db + collector + api)
	docker compose up --build

down: ## Tear it down and drop volumes
	docker compose down -v

logs: ## Tail the api container
	docker compose logs -f api

docker-build: ## Build the production image
	docker build -t books-api:local .
