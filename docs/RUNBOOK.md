# Runbook

Operating this service day-to-day — as opposed to `terraform/README.md` and
`ecs/README.md`, which cover *building* it. This assumes it's already
deployed per those docs.

## Environments

There are two: **staging** and **production**. They're the same Terraform
config (`terraform/`) applied twice, once per **Terraform workspace**
(`terraform.workspace` — see `terraform/environment.tf`), which is what
actually keeps their state and resources apart; there is no separate
directory or module per environment.

Naming follows one rule everywhere (`local.name_prefix` in
`terraform/environment.tf`): **production keeps every name exactly as it
was before staging existed** (`books-api`, `/ecs/books-api`, the
`books-api` ECS cluster/service, and so on — everything this runbook's
other sections reference by that literal name); staging gets `-staging`
appended (`books-api-staging`, `/ecs/books-api-staging`, ...). The same
rule applies to the IAM deploy roles (`books-api-cd`/`books-api-terraform`
vs. `books-api-staging-cd`/`books-api-staging-terraform`) and to the
GitHub Environments the CD/Terraform workflows read secrets and variables
from ("production" vs. "staging"). The one deliberate exception is the
Cognito resource server identifier (`books-api`, unchanged in both) — see
the comment in `terraform/cognito.tf` for why.

### Release flow

- **Push to `main`** → deploys to **staging** automatically.
- **Push a `v*` tag** → deploys to **production**. `.github/workflows/cd.yml`
  reuses the exact image already built and pushed for that commit (by the
  `main` push that got it into staging) rather than rebuilding — production
  always runs the literal artifact staging already ran, never a
  fresh-but-nominally-identical build.
- **`workflow_dispatch`** on `cd.yml` deploys either environment on demand
  (a redeploy with no new commit — e.g. after an infra-only change),
  bypassing both triggers above.

There's no automated promotion gate (a staging smoke test that has to pass
before a tag can go out) — tagging `v*` is a human decision. Add one later
if staging failures start reaching production tags in practice; not built
preemptively.

`.github/workflows/terraform.yml` mirrors the same release flow exactly:
a PR touching `terraform/` plans **both** environments (a change can affect
them differently — e.g. something that only breaks once staging's
smaller/newer setup, or once production's free-tier capacity is already
spoken for); a push to `main` **auto-applies to staging**; pushing a `v*`
tag **auto-applies to production** — a release promotes whatever's in
`terraform/` at that commit, the same way it promotes the already-built
image. This is deliberately unconditional on whether that specific commit
touched `terraform/` (unlike the PR trigger) — re-applying unchanged config
is a fast no-op, and a release should mean "production now matches what's
tagged" in every respect, infra included, not just the image.
`workflow_dispatch` is for an on-demand re-apply of either environment with
no new commit/tag (e.g. after fixing a failed apply, or an infra-only
change that shouldn't wait for the next release).

### Setting up staging for the first time

If production already exists but staging doesn't yet:

```bash
HOSTED_ZONE_NAME=example.com DOMAIN_NAME=staging.books-api.example.com \
  ENVIRONMENT=staging ./scripts/bootstrap.sh
```

This creates a `staging` Terraform workspace, a full parallel set of AWS
resources under the `books-api-staging` name, `books-api-staging-cd`/
`books-api-staging-terraform` IAM roles trusted only for OIDC tokens minted
for the "staging" GitHub Environment, and the "staging" GitHub Environment
itself (created automatically the first time a secret/variable is set on
it) with its own `AWS_DEPLOY_ROLE_ARN`/`TF_DEPLOY_ROLE_ARN`/`DOMAIN_NAME`/
etc. `scripts/teardown.sh ENVIRONMENT=staging` reverses it; see that
script's header for exactly what it does and doesn't remove (it never
touches the shared ECR repo or state bucket, since production still needs
them).

**Don't run this at the same time you're pushing/merging to `main`.**
`terraform.yml` auto-applies to staging on every push to `main` (see
"Release flow" above) — running `bootstrap.sh` for staging concurrently
with a push races the two applies against the same state. Terraform's
native S3 locking prevents them from corrupting each other's state, but
the loser still sees real AWS-side collisions (`ResourceInUseException`,
"already exists") on whatever the winner already created, which looks
alarming even though nothing is actually broken — check `terraform state
list` in that workspace to confirm before assuming otherwise. Simplest
fix: do the first-time bootstrap in a moment with no in-flight push to
`main`, then let CD/CI own it from there.

### Migrating an existing production to a named workspace

This only applies once, to a books-api deployment that predates staging
existing at all — its Terraform state is sitting in the **unnamed
`default`** workspace, not a workspace literally named `production`, since
workspaces didn't exist in this repo's Terraform config yet when it was
first applied. `terraform/environment.tf`'s `check` block refuses to
*apply* in the `default` workspace itself, but that alone doesn't stop
someone from bootstrapping a *different*, freshly-created named workspace
while `default` still holds the real infrastructure — which is exactly
what happened once already: a fresh `production` workspace tried to build
a second copy of everything already live under `default`, producing a mix
of "already exists" errors and silently-adopted real resources (anything
AWS treats as idempotent-by-name — ECS clusters, SNS topics, CloudWatch
alarms — just got quietly repointed rather than erroring). `scripts/bootstrap.sh`
now hard-stops before doing anything if `default` still holds any
resources at all, specifically to make that scenario impossible — but the
migration below is still what actually resolves it, not just a check to
get past.

**Back up state before touching any of this:**

```bash
cd terraform
terraform init -backend-config=backend.hcl   # if not already initialized
terraform workspace select default
terraform state pull > /tmp/books-api-default-state-backup.json
```

Then move that state into a real `production` workspace and confirm
nothing changed:

```bash
terraform workspace new production
terraform state push /tmp/books-api-default-state-backup.json
terraform plan   # with TF_VAR_hosted_zone_name / TF_VAR_domain_name set as usual
```

That `plan` must come back **empty** ("No changes."). If it doesn't, stop —
don't apply — and compare against the backup file before doing anything
else; an empty plan is the only real confirmation this went cleanly, not
just "the commands didn't error." Once confirmed, delete the now-empty
`default` workspace (`terraform workspace select production && terraform
workspace delete default`) so nothing accidentally gets applied there
again, and update the CD/Terraform IAM roles for production (see "Setting
up staging for the first time" above — the same `scripts/bootstrap.sh`
invocation you'd use for a new environment also refreshes an existing
one's trust policy/secrets safely, since every step in it checks before
creating or overwriting).

## Observability / Production Support

Everything below names resources as they exist in **production**
(`books-api`, `/ecs/books-api`, ...) — for staging, append `-staging` to
every resource name (`books-api-staging`, `/ecs/books-api-staging`, ...);
see "Environments" above.

### How to view traces

Traces come from the app itself (auto-instrumented via
`FastAPIInstrumentor`/`BotocoreInstrumentor`, see `src/books_api/telemetry.py`)
and are shipped to **AWS X-Ray** by the `aws-otel-collector` sidecar in the
task.

- **Console:** X-Ray → Traces, or Service map. Filter by service name
  `books-api`.
- **CLI:**
  ```bash
  aws xray get-trace-summaries \
    --start-time "$(date -u -v-1H +%s 2>/dev/null || date -u -d '1 hour ago' +%s)" \
    --end-time "$(date -u +%s)"
  ```
  then `aws xray batch-get-traces --trace-ids <id ...>` for the full detail
  on any trace id it returns.

Two things you *won't* see, by design:
- `/healthz` and `/readyz` are excluded from tracing entirely
  (`excluded_urls` in `telemetry.py`) — they're hit every ~30s forever by the
  ALB/container health checks, and would otherwise be almost all the traces
  that exist. Not a bug if they're missing.
- Traces start at the ECS task, not at API Gateway — the gateway hop itself
  isn't instrumented, so a trace won't show you time spent in the JWT
  authorizer or the VPC Link. See "How to view logs" below for the caveat on
  visibility into that hop.

### How to view metrics

Everything lands in **CloudWatch Metrics**, across a few namespaces
depending on which layer you care about:

| Namespace | What's in it |
| --- | --- |
| `ECS/AWSOTel/Application` | App-level: `books.writes`, `http.server.duration`, `http.server.active_requests`, `http.server.request.size`, `http.server.response.size` |
| `ECS/ContainerInsights` | Container CPU/memory/network per task/service/cluster |
| `AWS/DynamoDB` | Consumed vs. provisioned read/write capacity, `ThrottledRequests` — **worth actively watching**, since both tables are fixed at 5/5 provisioned capacity, not autoscaled (see `terraform/dynamodb.tf`); this is the metric that tells you you're about to get throttled before callers start seeing errors |
| `AWS/ApiGateway` | Request count, latency, 4xx/5xx counts at the gateway — published automatically, no extra config. Currently your **only** signal for "how many requests the JWT authorizer is rejecting" (see the gap noted under logs) |
| `AWS/ApplicationELB` | Request count/latency/5xx between API Gateway and ECS specifically — lets you tell a gateway-level rejection apart from a backend-level failure |

**Fastest path: the CloudWatch dashboard** (`terraform/dashboard.tf`,
recreated on every `apply` like everything else here). It covers API
performance (status codes, top routes, top consumers, request rate, p95
latency), infrastructure (ECS task counts, per-task CPU/Memory — there are
no EC2 hosts on Fargate, so "per host" there means per-task), and DynamoDB
capacity/latency, all in one place:

- **Production:** https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards/dashboard/books-api
- **Staging:** https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards/dashboard/books-api-staging

(or `terraform output -raw dashboard_url` from the relevant workspace,
which produces the same link).

Otherwise: CloudWatch → Metrics → browse by namespace.

### Alerting

`terraform/alarms.tf` operationalizes a handful of SLOs as CloudWatch
Alarms, all publishing to one SNS topic (`books-api-alerts`):

| Alarm | SLO it enforces | Threshold |
| --- | --- | --- |
| `books-api-unhealthy-targets` | The service is actually up | Any ECS target unhealthy behind the ALB, for 3 straight minutes |
| `books-api-gateway-5xx` | Availability | 5+ 5xx responses from API Gateway in a 5-minute window |
| `books-api-gateway-latency-p99` | Latency | p99 integration latency above 3s for 15 straight minutes |
| `books-api-dynamodb-throttles-{books,isbns}` | The data layer has headroom | Any throttled DynamoDB request in a 5-minute window |

These are deliberately generous starting thresholds picked without a real
traffic baseline to tune against (see `alarms.tf`'s comments for the
reasoning on each) — tighten them once actual traffic gives you something
to hold the service to. "5+ 5xx" and "p99 latency" specifically are simple
counts/single-metric statistics rather than computed error rates, since this
service doesn't have enough steady traffic yet for a percentage-based
threshold to mean much; revisit as metric-math expressions once it does.

**Nothing is subscribed to the alerts topic by default** — an email address
or webhook isn't something this repo creates or stores on your behalf.
Subscribe yourself, once:

```bash
aws sns subscribe --topic-arn "$(terraform output -raw alerts_topic_arn)" \
  --protocol email --notification-endpoint you@example.com
```

AWS emails a confirmation link to that address — nothing arrives until you
click it. (Slack/PagerDuty/etc. instead of email: subscribe an SNS→webhook
integration the same way, just a different `--protocol`/endpoint.)

To see alarm history/current state: CloudWatch → Alarms — or
`aws cloudwatch describe-alarms --alarm-name-prefix books-api`.

### How to view logs

Container logs go to CloudWatch Logs, log group **`/ecs/books-api`**, two
stream prefixes: `api/` (the app) and `otel-collector/` (the ADOT sidecar).

- **Console:** CloudWatch → Log groups → `/ecs/books-api` → Log streams.
- **CLI (usually faster):**
  ```bash
  aws logs tail /ecs/books-api --follow          # live tail
  aws logs tail /ecs/books-api --since 1h
  aws logs filter-log-events --log-group-name /ecs/books-api --filter-pattern "ERROR"
  ```

**Retention is 1 day** (`terraform/logs.tf`) — a deliberate, cost-driven
choice, not an oversight, but it means anything older than a day is
genuinely gone by the time you go looking for it. If that ever stops being
enough, raise `retention_in_days` there (CloudWatch Logs retention is
day-granularity — see that file's comment for why "a few hours" was never on
the table either).

Successful (2xx) health-check request lines are deliberately suppressed from
the `api/` stream (`_QuietHealthChecks` in `main.py`) — don't be surprised
not to see routine `/healthz`/`/readyz` noise; a *failing* health check still
logs normally, since that's the one case actually worth seeing.

**API Gateway access logs**, log group **`/aws/apigateway/books-api`**
(`terraform/logs.tf`'s `api_gateway_access` group, wired up via
`access_log_settings` on `terraform/api_gateway.tf`'s stage). One JSON line
per request: path, HTTP method, status, request/integration/response
latency, source IP, and — pulled straight out of the validated JWT —
`consumer` (the caller's Cognito `client_id`). This is what the dashboard's
Top Routes/Top Consumers/status-code widgets read from
(`terraform/dashboard.tf`).

To debug why one specific caller's request was rejected or slow:

```bash
aws logs filter-log-events \
  --log-group-name /aws/apigateway/books-api \
  --filter-pattern '{ $.status = 401 }'
```

or via CloudWatch Logs Insights (console, or `aws logs start-query`):

```
fields @timestamp, consumer, path, status, responseLatency, authorizerError
| filter consumer = "<client_id>"
| sort @timestamp desc
```

## User Management

### How to add a user

"User" here means an API **caller** — a client-credentials consumer of this
API — not a human account. Nothing about this service has sign-up, login, or
human user accounts; Cognito's user pool exists solely to issue tokens to
app clients. See `terraform/README.md`'s "Auth" section for the full
request-path reasoning.

Every caller gets its own Cognito client **and** its own Kong consumer/rate
limit, both driven off one list: `var.api_consumers`
(`terraform/variables.tf`, default `["default"]` — today's one real caller).
Adding a name there is the one step that provisions both sides — you don't
touch `terraform/cognito.tf` or Kong's config directly for the common case.

**To add a new caller:**

1. Add their name to `var.api_consumers` (a `terraform.tfvars` entry, or a
   `-var` flag) and `terraform apply` — this creates their Cognito client
   (`terraform/cognito.tf`'s `for_each`) and adds their `client_id` as a
   valid audience on API Gateway's JWT authorizer (`terraform/api_gateway.tf`).
2. Optionally give them a non-default rate limit: add an entry for their name
   in `ecs/kong/rate-limits.<environment>.json` (falls back to `"default"`'s
   limit if you skip this — see "How to view/change a consumer's rate limit"
   below).
3. Redeploy Kong (`.github/workflows/cd.yml`'s `deploy-kong` job, or a normal
   push to `main`/`v*` tag) — this is what actually picks up the new
   consumer and rate limit; `terraform apply` alone only provisions the
   Cognito side, since Kong's declarative config is baked into its image at
   build time, not read from Terraform state.
4. `terraform output -json cognito_client_ids` (and `cognito_client_secrets`)
   to get their id/secret, keyed by the name you added — hand it to them out
   of band. They use it exactly like any other caller — see "How to make a
   request" below (`CONSUMER=<name> scripts/get-token.sh`).

**To remove a caller:** delete their name from `var.api_consumers`,
`terraform apply`, then redeploy Kong the same way. Any token they already
hold stays valid until it expires (see the token lifetime note below) — this
revokes their ability to get a *new* one and to pass Kong's rate-limiting
consumer lookup, not whatever bearer token they're already holding.

"Top Consumers" on the dashboard (and the `consumer` field in the API
Gateway access log — see "How to view logs" above) is keyed off `client_id`,
so it only distinguishes callers once each has its own client — with the
one default consumer today, every request still shows up as `"default"`.

### How to view/change a consumer's rate limit

Rate limits live in `ecs/kong/rate-limits.<environment>.json` — a plain
JSON file, not Terraform state, so changing a number doesn't need
`terraform apply`, just a Kong redeploy (push to `main`/`v*`, or
`workflow_dispatch` on `cd.yml` targeting `deploy-kong`):

```json
{
  "default": { "minute": 100 },
  "some-consumer": { "minute": 20 }
}
```

Any consumer without its own entry falls back to `"default"`'s limit. See
`ecs/kong/render_config.py` for exactly how this turns into Kong's
declarative config, and `terraform/README.md`'s "Why Kong sits in the
middle" for why this exists instead of an API Gateway usage plan (HTTP API
doesn't support them) and why the limit is per-Kong-task, not global
(`policy: local`, `var.kong_desired_count = 1`).

To check whether a caller is actually being throttled: Kong returns
`429` with `RateLimit-*`/`X-RateLimit-*-Minute` response headers on every
request (even successful ones, so you can see how close to the limit a
caller is without waiting for a 429) — `docs/RUNBOOK.md`'s "How to view
logs" above covers the API Gateway access log, which still shows the
request reaching API Gateway even when Kong subsequently rate-limits it
(Kong's rejection happens downstream of the gateway, so a 429 from Kong
doesn't show up as an API Gateway-level rejection).

## Authentication

### How to make a request

1. Get a client id + secret — either the existing `"default"` consumer's, or
   a new one provisioned per "How to add a user" above.
2. Exchange it for a bearer token with `scripts/get-token.sh` (wraps the
   OAuth2 client-credentials grant against Cognito). With local Terraform
   state, it looks up your consumer's id/secret itself — just say which one:
   ```bash
   CONSUMER=default TOKEN=$(scripts/get-token.sh)   # CONSUMER defaults to "default" if unset

   # defaults to requesting both books-api/read and books-api/write; narrow it:
   CONSUMER=default scripts/get-token.sh books-api/read
   ```
   No local state (CI, a teammate's machine)? Skip `CONSUMER` and set the
   credentials directly instead:
   ```bash
   export COGNITO_CLIENT_ID=...
   export COGNITO_CLIENT_SECRET=...
   export COGNITO_DOMAIN=...       # from `terraform output -raw cognito_domain`, or ask whoever provisioned your client

   TOKEN=$(scripts/get-token.sh)
   ```
3. Call the API with it:
   ```bash
   curl -H "Authorization: Bearer $TOKEN" https://books-api.spixionic.com/api/v1/books
   ```

Two things worth knowing, not just assuming:
- **Scopes are enforced per-route.** `books-api/read` and `books-api/write`
  both get embedded in the token, and API Gateway checks which one a route
  actually needs (`terraform/api_gateway.tf`'s `aws_apigatewayv2_route.books_*`):
  the two `GET` routes accept either scope, while `POST`/`PATCH`/`DELETE`
  require `books-api/write`. A `read`-only token gets a 401 from a mutating
  call. Request the narrower scope if you only need read access — beyond
  being good practice, it's now the difference between a token that can and
  can't mutate data.
- **Tokens expire** — Cognito's default access token lifetime (1 hour; not
  explicitly configured in `cognito.tf`, so this is AWS's stock default, not
  a value someone chose). Fetch a new one when requests start getting
  rejected rather than assuming one token lasts forever; `get-token.sh` is
  cheap enough to call before each batch of work if you're not sure.

See `terraform/README.md`'s "Auth" section for *why* this is built the way
it is (Cognito, API Gateway's JWT authorizer, the internal ALB) if you need
the implementation-level picture rather than just how to call the thing.
