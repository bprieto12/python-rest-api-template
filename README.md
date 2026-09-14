# books-api

A template REST API that serves **book data**, built to be copied into real
projects. There is no real dataset behind it — [`src/books_api/seed_data.py`](src/books_api/seed_data.py)
holds ~24 mock books that stand in for one.

## Stack

| Concern            | Choice                                             |
| ------------------ | ------------------------------------------------- |
| Web framework      | FastAPI + Uvicorn (ASGI)                          |
| Data store         | PostgreSQL via SQLAlchemy 2.0 async + asyncpg     |
| Migrations         | Alembic (async env)                               |
| Observability      | OpenTelemetry metrics + traces (OTLP, console fallback) |
| Packaging          | uv (`pyproject.toml` + `uv.lock`)                 |
| Container          | Multi-stage `Dockerfile` (uv build layer)         |
| Local infra        | `docker compose` (Postgres + OTel Collector + Prometheus + Grafana + API) |
| Orchestration      | ECS Fargate, task/service defs in [`ecs/`](ecs/)  |
| CI/CD              | GitHub Actions ([`.github/workflows/`](.github/workflows/)) |
| Cloud              | AWS — ECR for images, ECS Fargate for compute, OIDC for auth |

## Quick start

```bash
uv sync                      # create .venv from uv.lock
cp .env.example .env         # optional; defaults already point at localhost PG

# Option A — everything in Docker
make up                      # db + collector + prometheus + grafana + api

# then:
#   http://localhost:8000/docs    API + Swagger UI
#   http://localhost:3000         Grafana — "Books API — Overview" dashboard (no login)
#   http://localhost:9090         Prometheus (try:  rate(http_server_duration_milliseconds_count[1m]) )
#   http://localhost:8889/metrics collector's re-exported app metrics

# Option B — Postgres in Docker, API on the host
docker compose up -d db
make migrate && make seed
make run                     # http://localhost:8000/docs
```

## Common commands

Run `make help` for the full list. The important ones:

```bash
make test        # pytest (SQLite by default; set TEST_DATABASE_URL for PG)
make lint        # ruff format --check + ruff check
make typecheck   # mypy --strict on src/
make fmt         # ruff format + ruff check --fix
make migrate     # alembic upgrade head
make revision m="add rating column"   # autogenerate a migration
```

## Layout

```
src/books_api/
  main.py         app factory + lifespan (creates engine, wires telemetry)
  config.py       pydantic-settings; all config comes from env vars
  db.py           async engine/sessionmaker + get_session dependency
  models.py       SQLAlchemy models (kept SQLite-portable for tests)
  schemas.py      Pydantic request/response models — the API contract
  repository.py   data-access functions over an AsyncSession (no HTTP here)
  routers/        health.py (probes), books.py (CRUD under /api/v1)
  telemetry.py    OpenTelemetry setup (metrics + traces)
  seed_data.py    the mock catalogue
alembic/          migration env + versions/
scripts/seed.py   idempotent loader for the mock catalogue
ecs/              Fargate task/service definitions (see ecs/README.md)
tests/            pytest suite (httpx ASGI client)
```

## Deployment notes

- **Images** are built and pushed to ECR by [`.github/workflows/cd.yml`](.github/workflows/cd.yml)
  on push to `main` / `v*` tags, tagged with the commit SHA.
- **Auth** is GitHub OIDC → an IAM role (`secrets.AWS_DEPLOY_ROLE_ARN`); no static keys.
- **Rollout** registers a new [`ecs/task-definition.json`](ecs/task-definition.json)
  revision, runs `alembic upgrade head` as a one-off Fargate task and checks its
  exit code, then `aws ecs update-service --force-new-deployment` and waits for
  the service to stabilize. See [`ecs/README.md`](ecs/README.md) for the
  one-time cluster/service bootstrap, IAM roles, and placeholders to fill in
  before the first deploy.
