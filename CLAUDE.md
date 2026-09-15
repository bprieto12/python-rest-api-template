# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **template** FastAPI REST API serving book data. There is no real dataset —
`src/books_api/seed_data.py` holds ~24 mock books that everything (the seed
script, the `seeded_client` test fixture) builds on. When adding features, extend
the mock catalogue rather than assuming an external source.

## Commands

`uv` is the package manager and every command runs through it. `make help` lists
targets; the essentials:

| Task | Command |
| --- | --- |
| Install deps | `uv sync` (add `--frozen` in CI/Docker) |
| Run API (reload) | `make run` → http://localhost:8000/docs |
| Full local stack | `make up` (DynamoDB Local + OTel Collector + Prometheus + Grafana + API in Docker) |
| Tests | `make test` — hermetic, against an in-process moto DynamoDB double |
| One test | `uv run pytest tests/test_books.py::test_patch_updates_fields` |
| Lint | `make lint` (`ruff format --check` + `ruff check`) |
| Types | `make typecheck` (`mypy --strict` on `src/`) |
| Format + autofix | `make fmt` |
| Load mock catalogue | `make seed` (add `CREATE_TABLES=1` for local dev, before Terraform owns the tables) |
| Regenerate lockfile | `uv lock` after editing `pyproject.toml` |

## Architecture

Request flow: `routers/*` (HTTP concerns, status codes, `HTTPException`) →
`repository.py` (pure async functions over the DynamoDB tables, no HTTP) →
`models.py` (a plain `Book` dataclass, not an ORM model). `schemas.py` is the
wire contract and is the only thing routers should return. Keep these layers
separate — no repository internals in routers beyond passing values through,
no `HTTPException` in `repository`.

**Storage is DynamoDB, not a relational database** — see `repository.py`'s
module docstring for the full reasoning (why two tables, how ISBN uniqueness
is enforced without a relational unique constraint, and the explicit
trade-off of scanning + filtering in Python for search, since DynamoDB has no
server-side `ILIKE`). Read that docstring before touching `repository.py`;
the design decisions there aren't obvious from the code alone.

**Resource lifecycle.** The aioboto3 DynamoDB resource is opened in the
FastAPI **lifespan** (`main.py`) and stored on `app.state.dynamodb`. The
`get_tables` dependency (`db.py`) just reads `request.app.state.dynamodb.tables`
— unlike a SQL session, there's no per-request transaction boundary to open
and commit, since each DynamoDB item operation is already atomic on its own.
Tests bypass the lifespan entirely and populate `app.state` by hand (see
`tests/conftest.py`); if you move resource setup out of the lifespan, that
fixture breaks.

**Config.** All configuration is env vars via `pydantic-settings` (`config.py`),
cached through `get_settings()`. `DYNAMODB_ENDPOINT_URL` overrides the endpoint
for local dev/tests (DynamoDB Local, moto); leave it unset for real AWS.
`OTEL_EXPORTER_OTLP_ENDPOINT` maps to the OpenTelemetry standard var; leaving
it empty makes telemetry fall back to the console exporter so the app still
boots without a collector.

**Telemetry** (`telemetry.py`). `setup_telemetry` installs global meter/tracer
providers once per process (guarded by a module flag) and instruments
`botocore` globally, which aioboto3's async calls also run through — there's
no per-resource hook the way there was for the old SQLAlchemy engine.
`instrument_app` attaches the FastAPI middleware and swallows "already
instrumented" errors so the test suite can build many apps. Custom metrics go
through `get_meter()` (see the `books.writes` counter in `routers/books.py`).

**Tests run against moto's `ThreadedMotoServer`**, not `@mock_aws`. moto's
usual decorator only patches `botocore` internals, which this app's async
`aiobotocore` calls don't go through — it silently mocks nothing. The
threaded server is a real local HTTP server instead, so it works with any
client. See `tests/conftest.py`.

## Deploy pipeline

`.github/workflows/ci.yml` runs lint + mypy + tests (fully hermetic — no
service containers) + a Docker build with a `/healthz` smoke test, on every PR.

`.github/workflows/cd.yml` runs on push to `main` / `v*` tags: assumes an AWS IAM
role via **GitHub OIDC** (`secrets.AWS_DEPLOY_ROLE_ARN`), builds and pushes to
**ECR** tagged with the commit SHA, registers a new `ecs/task-definition.json`
revision, then `aws ecs update-service --force-new-deployment` and waits for
the rollout to stabilize. There's no migration step — DynamoDB is schemaless,
so there's nothing for a migration task to do.

`terraform/` owns everything that isn't re-applied on every deploy: a
dedicated VPC, the ECS cluster, an ALB (with ACM cert and one Route 53
record) built just for this service, the target group, the two DynamoDB
tables, and the initial ECS service + task definition revision — created once
via `terraform apply` (locally, or via `.github/workflows/terraform.yml`'s
`workflow_dispatch`), not something CD re-applies; CD only registers new task
definition revisions and calls `update-service`. Per-account placeholders and
IAM role requirements are in `ecs/README.md` and `terraform/README.md`.

## Conventions

- Everything DB-facing is `async`; there is no sync path.
- Ruff rules include `I` (import sort), `UP`, `B`, `SIM`, `ASYNC` — `make fmt`
  before committing.
- `B008` is ignored project-wide because FastAPI's `Depends()` lives in argument
  defaults by design.
- New endpoints mount under `settings.api_v1_prefix` (`/api/v1`); health probes
  (`/healthz`, `/readyz`) stay at the root, for the orchestrator's own probing.
