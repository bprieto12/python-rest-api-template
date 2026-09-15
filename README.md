# books-api

A template REST API that serves **book data**, built to be copied into real
projects. There is no real dataset behind it — [`src/books_api/seed_data.py`](src/books_api/seed_data.py)
holds ~24 mock books that stand in for one.

## Stack

| Concern            | Choice                                             |
| ------------------ | ------------------------------------------------- |
| Web framework      | FastAPI + Uvicorn (ASGI)                          |
| Data store         | DynamoDB via aioboto3 (async)                     |
| Auth               | OAuth2 client-credentials via Amazon Cognito, enforced at API Gateway — not in the app itself |
| Observability      | OpenTelemetry metrics + traces (OTLP, console fallback) |
| Packaging          | uv (`pyproject.toml` + `uv.lock`)                 |
| Container          | Multi-stage `Dockerfile` (uv build layer)         |
| Local infra        | `docker compose` (DynamoDB Local + OTel Collector + Prometheus + Grafana + API) |
| Orchestration      | ECS Fargate (internal ALB) behind API Gateway, task/service defs in [`ecs/`](ecs/) |
| CI/CD              | GitHub Actions ([`.github/workflows/`](.github/workflows/)) |
| Cloud              | AWS — ECR for images, ECS Fargate for compute, DynamoDB for storage, API Gateway + Cognito for auth, OIDC for CD |

## Quick start

```bash
uv sync                      # create .venv from uv.lock
cp .env.example .env         # optional; defaults point at DynamoDB Local's usual address

# Option A — everything in Docker
make up                      # dynamodb-local + collector + prometheus + grafana + api

# then:
#   http://localhost:8000/docs    API + Swagger UI
#   http://localhost:3000         Grafana — "Books API — Overview" dashboard (no login)
#   http://localhost:9090         Prometheus (try:  rate(http_server_duration_milliseconds_count[1m]) )
#   http://localhost:8889/metrics collector's re-exported app metrics

# Option B — DynamoDB Local in Docker, API on the host
docker compose up -d dynamodb-local
DYNAMODB_ENDPOINT_URL=http://localhost:8001 make seed CREATE_TABLES=1
DYNAMODB_ENDPOINT_URL=http://localhost:8001 make run   # http://localhost:8000/docs
```

## Common commands

Run `make help` for the full list. The important ones:

```bash
make test        # pytest — hermetic, runs against an in-process moto DynamoDB double
make lint        # ruff format --check + ruff check
make typecheck   # mypy --strict on src/
make fmt         # ruff format + ruff check --fix
make seed CREATE_TABLES=1   # create the tables (local dev only) and load the mock catalogue
```

## Layout

```
src/books_api/
  main.py         app factory + lifespan (opens the DynamoDB resource, wires telemetry)
  config.py       pydantic-settings; all config comes from env vars
  db.py           async DynamoDB resource + get_tables dependency
  models.py       the Book record shape (a plain dataclass, not an ORM model)
  schemas.py      Pydantic request/response models — the API contract
  repository.py   data-access functions over the DynamoDB tables (no HTTP here)
  routers/        health.py (probes), books.py (CRUD under /api/v1)
  telemetry.py    OpenTelemetry setup (metrics + traces)
  seed_data.py    the mock catalogue
scripts/seed.py       idempotent loader for the mock catalogue
scripts/get-token.sh  gets a Cognito bearer token for calling the deployed API
ecs/              Fargate task/service definitions (see ecs/README.md)
terraform/        this service's AWS infrastructure (see terraform/README.md)
tests/            pytest suite (httpx ASGI client)
```

## Why DynamoDB, and what that trades away

Provisioned-capacity DynamoDB has a *perpetual* free tier (25 WCU/25 RCU/25GB)
— genuinely $0/mo for a low-traffic service, unlike RDS's free tier which
lapses after 12 months. The real cost: DynamoDB is a key-value store, not a
query engine. Listing books does a full table `Scan`, filtered and sorted in
Python — there's no server-side equivalent of SQL's case-insensitive
`ILIKE '%term%'` short of a real search index. Fine for a small mock
catalogue; revisit (a GSI, or an actual search index) if it ever needs to
hold more than a few hundred/thousand items. See `repository.py`'s module
docstring for the full reasoning, including how ISBN uniqueness is enforced
without a relational unique constraint.

## Deployment notes

- **Images** are built and pushed to ECR by [`.github/workflows/cd.yml`](.github/workflows/cd.yml)
  on push to `main` / `v*` tags, tagged with the commit SHA.
- **Deploy auth** is GitHub OIDC → an IAM role (`secrets.AWS_DEPLOY_ROLE_ARN`); no static keys.
- **API auth** is separate from all of that — callers authenticate to the
  *API itself* with an OAuth2 client-credentials token from Cognito, checked
  by API Gateway before a request ever reaches the ALB/ECS. See
  [`terraform/README.md`](terraform/README.md)'s "Auth" section for the flow.
- **Rollout** registers a new [`ecs/task-definition.json`](ecs/task-definition.json)
  revision, then `aws ecs update-service --force-new-deployment` and waits for
  the service to stabilize — there's no migration step (DynamoDB is
  schemaless). See [`ecs/README.md`](ecs/README.md) and
  [`ecs/bootstrap.sh`](ecs/bootstrap.sh) for the one-time IAM/ECR bootstrap,
  and [`terraform/README.md`](terraform/README.md) for the infrastructure
  itself (including the DynamoDB tables, API Gateway, and Cognito).
