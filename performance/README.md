# Performance tests (k6)

Two scripts, both plain [k6](https://k6.io) JavaScript, no build step or
package.json needed:

- **`smoke.js`** — 1 VU, 5 iterations, read-only. "Is it actually up and
  wired correctly end to end" — safe to run against any environment,
  including production, with negligible load. Not a load test.
- **`load.js`** — staged ramp-up/hold/ramp-down, mostly reads with a
  smaller fraction of full create → patch → delete write cycles. The real
  performance test.

## Read this before running `load.js` against anything deployed

Both DynamoDB tables run **provisioned** capacity at 5 read / 5 write units
— not on-demand (see `../terraform/dynamodb.tf`'s comment: it's what keeps
this on the perpetual free tier rather than autoscaling). `load.js`'s
defaults (5 VUs, ~1 request/sec each, 20% of iterations writing) are
deliberately conservative to stay under that ceiling. Turning `VUS` or
`HOLD_DURATION` up without also raising the tables' capacity first won't
give you a meaningful result — it'll just trip the `dynamodb_throttles`
CloudWatch alarms and page whoever's subscribed to `../docs/RUNBOOK.md`'s
alerts topic.

If you actually want to test at higher throughput: temporarily raise
`read_capacity`/`write_capacity` in `terraform/dynamodb.tf` (or switch
`billing_mode` to `PAY_PER_REQUEST` for the duration of the test) and
`terraform apply`, run the heavier test, then revert and `apply` again
afterward. Don't leave it raised — that's real money for headroom this
service doesn't otherwise need.

## Running locally

Against the local Docker stack (`make up`), no auth needed — API Gateway
and Cognito don't exist in local dev at all:

```bash
BASE_URL=http://localhost:8000 k6 run performance/smoke.js
BASE_URL=http://localhost:8000 k6 run performance/load.js
```

Needs `k6` installed (`brew install k6`, or see
[k6's install docs](https://k6.io/docs/get-started/installation/) for other
platforms). No `k6` locally? Run it via Docker instead — swap in your own
`BASE_URL`:

```bash
docker run --rm -i -e BASE_URL=http://host.docker.internal:8000 \
  -v "$PWD/performance:/performance" grafana/k6 run /performance/smoke.js
```

## Running against a deployed environment

Needs a bearer token, so also set the Cognito client credentials (the same
ones `../scripts/get-token.sh` uses — `terraform output` in `../terraform`,
or ask whoever provisioned your client):

```bash
BASE_URL=https://staging.books-api.example.com \
COGNITO_CLIENT_ID=... COGNITO_CLIENT_SECRET=... COGNITO_DOMAIN=... \
  k6 run performance/smoke.js
```

## Running in CI

`.github/workflows/performance.yml` — `workflow_dispatch` only, never automatic on
push/PR, since this hits a real deployed environment over the network and
(for `load.js`) writes real data. Pick the target environment, the script
(`smoke` or `load`), and — for `load` — optionally override `vus`/`duration`.
Reads `BASE_URL`/`COGNITO_*` from that environment's own GitHub Environment
vars/secrets, the same ones `scripts/bootstrap.sh` sets.

## Cleaning up after an interrupted `load.js` run

Every book `load.js` creates, it also deletes in the same iteration — the
only way one survives is the run getting killed mid-iteration (Ctrl+C,
CI cancellation). Those are tagged `genre=load-test` specifically so
they're easy to find:

```bash
curl -H "Authorization: Bearer $(../scripts/get-token.sh)" \
  "https://staging.books-api.example.com/api/v1/books?genre=load-test"
# then DELETE each id that comes back
```

## Thresholds

`load.js`'s thresholds intentionally mirror `../terraform/alarms.tf`'s own
SLOs (`gateway_5xx`, `gateway_latency_p99`) rather than an arbitrary
separate bar — a k6 failure here means "the same thing production alerting
would page on," so a clean k6 run is a real, if partial, signal that those
alarms would have stayed quiet too.
