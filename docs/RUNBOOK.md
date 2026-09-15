# Runbook

Operating this service day-to-day — as opposed to `terraform/README.md` and
`ecs/README.md`, which cover *building* it. This assumes it's already
deployed per those docs.

## Observability / Production Support

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

Console: CloudWatch → Metrics → browse by namespace, or build a Dashboard
from the ones you check often. If you'd rather use Grafana than live in the
CloudWatch console: point your existing local Grafana instance at CloudWatch
as a data source (native support, no new AWS infrastructure needed) — see
the note in `terraform/README.md` if you want to go further and replicate
the local Prometheus/Grafana setup for real in AWS.

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

**Known gap:** API Gateway has no access logging configured
(`aws_apigatewayv2_stage` has no `access_log_settings`). There is currently
no per-request record anywhere of who called what, when, or whether the JWT
authorizer accepted or rejected them — only the aggregate 4xx/5xx *count* in
`AWS/ApiGateway` metrics above. If you need to debug why one specific
caller's request was rejected, that's not currently possible after the
fact. Adding an `aws_cloudwatch_log_group` + `access_log_settings` on the
stage is the fix, whenever that need actually shows up — not built
preemptively.

## User Management

### How to add a user

"User" here means an API **caller** — a client-credentials consumer of this
API — not a human account. Nothing about this service has sign-up, login, or
human user accounts; Cognito's user pool exists solely to issue tokens to
app clients. See `terraform/README.md`'s "Auth" section for the full
request-path reasoning.

Right now there's **one shared app client**, `books-api-client`
(`terraform/cognito.tf`), used by every caller. That's fine while there's
one real consumer; once there's more than one, giving each its own client is
worth doing so you can tell them apart in metrics and revoke one without
touching the others (concretely: right now you can't distinguish which
caller is responsible for a given `AWS/ApiGateway` 4xx, or for read vs. write
DynamoDB load — everyone shares the same identity).

**To add a new caller**, add another client to `terraform/cognito.tf`:

```hcl
resource "aws_cognito_user_pool_client" "some_new_caller" {
  name         = "some-new-caller"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes = [
    "${aws_cognito_resource_server.this.identifier}/read",
    "${aws_cognito_resource_server.this.identifier}/write",
  ]
  supported_identity_providers = ["COGNITO"]
}
```

Add matching outputs (there's currently only one `cognito_client_id`/
`cognito_client_secret` pair in `terraform/outputs.tf`, for the one existing
client — a second caller needs its own named outputs), `terraform apply`,
then hand the new caller their client id/secret out of band. They use them
exactly like the existing client — see "How to make a request" below.

**To remove a caller:** delete their `aws_cognito_user_pool_client` resource
and `terraform apply`. Any token they already hold stays valid until it
expires (see the token lifetime note below) — this revokes their ability to
get a *new* one, not whatever they're already holding.

If you expect to add callers often, it's worth refactoring this to a
`for_each` over a variable map of caller names instead of one resource block
per caller — a natural follow-up whenever that becomes true, not done now
since there's only ever been the one.

## Authentication

### How to make a request

1. Get a client id + secret — either the existing shared one, or a new one
   provisioned per "How to add a user" above.
2. Exchange it for a bearer token with `scripts/get-token.sh` (wraps the
   OAuth2 client-credentials grant against Cognito):
   ```bash
   export COGNITO_CLIENT_ID=...
   export COGNITO_CLIENT_SECRET=...
   export COGNITO_DOMAIN=...       # from `terraform output -raw cognito_domain`, or ask whoever provisioned your client

   TOKEN=$(scripts/get-token.sh)   # defaults to requesting both books-api/read and books-api/write
   ```
3. Call the API with it:
   ```bash
   curl -H "Authorization: Bearer $TOKEN" https://books-api.spixionic.com/api/v1/books
   ```

Two things worth knowing, not just assuming:
- **Scopes aren't enforced per-route yet.** `books-api/read` and
  `books-api/write` both exist and get embedded in the token, but the API
  Gateway authorizer here only checks that the token is *valid* — any valid
  token can call any route regardless of which scope it requested. Request
  the narrower scope anyway if you only need read access — it's forward
  compatible with enforcement being added later, it just isn't enforced
  today.
- **Tokens expire** — Cognito's default access token lifetime (1 hour; not
  explicitly configured in `cognito.tf`, so this is AWS's stock default, not
  a value someone chose). Fetch a new one when requests start getting
  rejected rather than assuming one token lasts forever; `get-token.sh` is
  cheap enough to call before each batch of work if you're not sure.

See `terraform/README.md`'s "Auth" section for *why* this is built the way
it is (Cognito, API Gateway's JWT authorizer, the internal ALB) if you need
the implementation-level picture rather than just how to call the thing.
