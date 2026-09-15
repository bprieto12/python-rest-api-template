# Terraform — books-api

Everything this service needs on AWS, in one place: a dedicated VPC, ECS
cluster, an *internal* ALB, API Gateway (the actual public entry point) with
Cognito-issued OAuth2 tokens enforced on every request, the two DynamoDB
tables, and the ECS task definition/service. Deliberately not split across a
separate "platform" repo and a "service" repo — this is one small service
with one deploy target, and that split earns its cost once there's a second
service sharing infrastructure, not before. See `../CLAUDE.md`'s deploy
pipeline section for how this fits with `../ecs/` and CD.

## Request path

```
caller --(HTTPS + Bearer token)--> API Gateway --(JWT authorizer)--> VPC Link --(HTTP, private)--> ALB (internal) --> ECS
```

TLS terminates for real at API Gateway; everything after that is plain HTTP
inside the private VPC — see "The ALB is dedicated to this one service, and
plain HTTP" below for why.

`api_gateway.tf` is the only public thing here. The ALB (`alb.tf`) is
`internal = true` specifically so this can't be bypassed — there's no way to
reach it except through the VPC Link, which only API Gateway can use.
`cognito.tf` is the token issuer: machine-to-machine only (client-credentials
grant), no hosted login UI, no human users. See "Auth" below for the actual
flow a caller goes through.

## Auth

See [`../docs/RUNBOOK.md`](../docs/RUNBOOK.md) for the consumer-facing
version of this (how to make a request, how to get a client added) — this
section is about why it's built this way.

A caller does the OAuth2 client-credentials grant against the Cognito
domain, then calls the API with the resulting bearer token.
[`../scripts/get-token.sh`](../scripts/get-token.sh) wraps that grant —
it reads the client id/secret/domain straight from `terraform output` and
prints just the token, so it composes directly into a request:

```bash
curl -H "Authorization: Bearer $(../scripts/get-token.sh)" https://books-api.spixionic.com/api/v1/books

# request a specific scope instead of the default (both read and write):
../scripts/get-token.sh books-api/read
```

No local Terraform state (e.g. from CI, or a teammate's machine)? Set
`COGNITO_CLIENT_ID`/`COGNITO_CLIENT_SECRET`/`COGNITO_DOMAIN` and the script
uses those instead of calling `terraform output`.

Tokens are scoped (`books-api/read`, `books-api/write` — `cognito.tf`'s
resource server) but API Gateway's authorizer here only checks that the
token is *valid*, not which scopes it carries — every valid token can call
every route. Enforcing scopes per-route would mean either per-route
authorizers in `api_gateway.tf` or checking `event.requestContext.authorizer.jwt.claims.scope`
in the app itself; neither exists yet, both are natural next steps if
different callers should have different access.

The app itself (`src/books_api/`) has no idea any of this exists — enforcement
is entirely at the gateway, so local dev (`make run`, `docker compose up`)
stays exactly as unauthenticated as it's always been.

## Why Terraform only owns the *first* task definition revision

CD ([`../.github/workflows/cd.yml`](../.github/workflows/cd.yml)) calls
`aws ecs register-task-definition` and `aws ecs update-service
--force-new-deployment` directly, on every push to `main`. If Terraform also
tracked every field of the task definition and service, `terraform plan`
would see CD's changes as drift and try to revert them on the next apply.

Instead:
- `aws_ecs_task_definition.this` reads every field it needs — family, cpu,
  memory, execution/task role ARNs, container definitions (image, port,
  everything) — straight out of `../ecs/task-definition.json`, the same file
  CD renders. Nothing in `variables.tf`/`terraform.tfvars` duplicates a value
  that's already in that JSON; if the roles, image, or port change, edit the
  JSON, not a tfvars file. Terraform then only ignores `container_definitions`
  in `lifecycle`, so later CD-registered revisions don't drift.
- `aws_ecs_service.this` ignores `task_definition` and `desired_count` for the
  same reason — CD owns rollouts, and scaling is handled outside Terraform
  (console/CLI/autoscaling), not by re-applying it.

Net effect: Terraform owns the *shape* (networking, load balancer wiring,
DNS); CD owns *rollouts*. Re-running `terraform apply` after a normal deploy
should show no changes to those two resources.

## The ALB is dedicated to this one service, and plain HTTP

`alb.tf`'s listener forwards straight to `books-api`'s target group — no
host-header listener rule, no fallback 404. With one service behind it,
there's nothing to route between. If a second service ever needs to share
this ALB (rather than getting its own, which is also a fine choice), that's
the point at which pulling the ALB/VPC/cluster out into something shared
starts paying for itself — see the git history on this file for what that
split looked like before it was folded back in here.

It's HTTP, not HTTPS, despite `acm.tf` existing right there — API Gateway's
`HTTP_PROXY` + `VPC_LINK` private integration to an ALB doesn't perform TLS
to the target no matter which listener it's pointed at (confirmed directly:
pointing it at an HTTPS listener got every request rejected by the ALB
itself with "plain HTTP request was sent to HTTPS port"). That's fine here —
TLS terminates for real at API Gateway's custom domain
(`aws_apigatewayv2_domain_name`, using the same cert), and this listener is
only ever reached from the VPC Link's own ENIs inside the private VPC, never
from the public internet.

## Route 53: looked up, not owned

`route53.tf` does `data "aws_route53_zone"` against `hosted_zone_name`
rather than creating a zone. The zone is DNS for a domain almost certainly
used for other things too — a personal site, email — so this repo only ever
manages the one record for `domain_name`, never the zone itself.

## One-time setup

`../scripts/bootstrap.sh` does everything below — the state bucket, this
`apply`, and the GitHub OIDC/secrets wiring `../ecs/README.md` and
`.github/workflows/` need — in one command. What follows is what it's
actually doing, for anyone customizing the process or debugging a step it
got stuck on.

1. The zone in `hosted_zone_name` must already exist in Route 53 (create it
   once via console/CLI if it doesn't, and delegate it at your registrar —
   that's the only manual DNS step; once the zone exists and is delegated,
   everything else, including the ACM cert's DNS validation, works in one
   `apply` with no further waiting).
2. Create the state backend once — see `backend.hcl.example` for the CLI
   commands (just an S3 bucket; state locking is native to the S3 backend as
   of Terraform 1.10, no DynamoDB table needed). Copy it to `backend.hcl`,
   fill in real values, `terraform init -backend-config=backend.hcl`.
3. Copy `terraform.tfvars.example` → `terraform.tfvars`, set
   `hosted_zone_name` and `domain_name` for real.
4. `terraform plan` and read it, then `terraform apply`. This creates the
   VPC, cluster, internal ALB, cert, target group, the two DynamoDB tables,
   Cognito (user pool, domain, client), API Gateway (with its JWT authorizer
   and VPC Link), and the initial ECS service + task definition revision.
5. Set the GitHub OIDC deploy role ARN and `ECS_SUBNETS`/`ECS_SECURITY_GROUPS`
   (see [`../ecs/README.md`](../ecs/README.md)) from this apply's
   `aws_subnet.private[*].id` / `aws_security_group.ecs_tasks.id` — CD takes
   over deploys from here.

**Migrating an existing hand-created service:** if a service already exists
from an old manual bootstrap, `terraform import` it (and the target group /
Route 53 record) before the first `apply`, rather than applying blind —
otherwise Terraform will try to create resources that already exist.

## CI (GitHub Actions)

[`../.github/workflows/terraform.yml`](../.github/workflows/terraform.yml)
runs this from GitHub instead of a local machine:

- **On a PR** touching `terraform/`, it runs `plan` automatically.
- **`workflow_dispatch`** (the "Run workflow" button, or `gh workflow run
  terraform.yml -f action=apply`) runs `plan` (default) or `apply`.

It reuses the `production` GitHub Environment CD's deploy job already scopes
to, but needs its own entries there — CI can't read `backend.hcl` or
`terraform.tfvars` (gitignored, never in the checkout):

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `TF_STATE_BUCKET` | the backend S3 bucket (same as in `backend.hcl`) |
| Variable | `HOSTED_ZONE_NAME` | e.g. `example.com` |
| Variable | `DOMAIN_NAME` | e.g. `books-api.example.com` |
| Secret | `TF_DEPLOY_ROLE_ARN` | the broader Terraform-apply role from IAM below — **not** the same secret as CD's `AWS_DEPLOY_ROLE_ARN` |

`apply` always runs with `-auto-approve` since there's no terminal in CI to
confirm otherwise — the actual safety net is a required-reviewers protection
rule on the `production` Environment, added in repo settings, not anything in
the workflow file. Worth knowing: since `plan` and `apply` share that job's
`environment:` key, turning on required reviewers pauses PR-triggered plans
too, not just applies — arguably a feature, since an untrusted PR shouldn't
read production secrets just by being opened, but it does mean plans aren't
instant once that's on.

## IAM

Applying this needs a broader role than CD's OIDC deploy role — at minimum
`ec2:*` (VPC/subnets/NAT), `elasticloadbalancing:*`, `ecs:CreateCluster` /
`CreateService` / `UpdateService` / `DescribeServices` /
`PutClusterCapacityProviders`, `acm:RequestCertificate` /
`DescribeCertificate`, `route53:GetHostedZone` / `ChangeResourceRecordSets`,
`dynamodb:CreateTable` / `DeleteTable` / `DescribeTable` / `UpdateTable` /
`UpdateContinuousBackups` (point-in-time recovery is a distinct API call
from the table update itself)
(note: this is a *different* set of DynamoDB permissions than the task
role's — this is table lifecycle, not item access; see `ecs/README.md`),
`logs:CreateLogGroup` / `DeleteLogGroup` / `DescribeLogGroups` /
`PutRetentionPolicy` (also distinct from the execution role's
`logs:CreateLogGroup` in `ecs/bootstrap.sh` — that one only lets the running
task create the group if this apply hasn't already; this one is Terraform
owning the group's retention policy), `cognito-idp:CreateUserPool` /
`DeleteUserPool` / `CreateUserPoolDomain` / `DeleteUserPoolDomain` /
`CreateUserPoolClient` / `DeleteUserPoolClient` / `CreateResourceServer` /
`DeleteResourceServer`, `apigateway:*` (HTTP API, VPC Link, authorizer,
route, stage, and custom domain — no finer-grained action set than the
blanket one is commonly documented for API Gateway v2 resources),
`sns:CreateTopic` / `DeleteTopic` / `GetTopicAttributes`,
`cloudwatch:PutMetricAlarm` / `DeleteAlarms` / `DescribeAlarms`,
and `iam:PassRole` for the execution/task roles. Run `apply` from a separate,
more privileged role than the one CD assumes — don't widen the deploy role
just to let CI run Terraform too. In CI this is `secrets.TF_DEPLOY_ROLE_ARN`,
a different OIDC-trusted role from CD's `AWS_DEPLOY_ROLE_ARN` even though
both live in the same `production` GitHub Environment.

## Cost notes

- One NAT gateway (`single_nat_gateway = true`) rather than one per AZ —
  cheaper, less resilient to a single AZ outage. Fine for a low-traffic
  setup; flip the variable if that tradeoff stops being acceptable.
- `FARGATE_SPOT` is available as a capacity provider but not the default —
  opt in if this service can tolerate interruption.
