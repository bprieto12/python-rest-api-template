# Terraform — books-api

Everything this service needs on AWS, in one place: a dedicated VPC, ECS
cluster, an *internal* ALB, API Gateway (the actual public entry point) with
Cognito-issued OAuth2 tokens enforced on every request, Kong (per-consumer
rate limiting — `kong.tf`), the two DynamoDB tables, and the ECS task
definition/service. Deliberately not split across a separate "platform" repo
and a "service" repo — this is one small service with one deploy target, and
that split earns its cost once there's a second service sharing
infrastructure, not before. See `../CLAUDE.md`'s deploy pipeline section for
how this fits with `../ecs/` and CD.

**Two environments, one config.** This same config is applied twice, once
per **Terraform workspace** (`staging`/`production` — see
`environment.tf`), which is what isolates their state and resource names
(production keeps every name as-is, staging gets `-staging` appended — see
`environment.tf`'s `local.name_prefix`). Always run `terraform workspace
select <environment>` (or `-or-create` the first time) before `plan`/
`apply` — there's a `check` block that refuses to run in the unnamed
`default` workspace, precisely so an environment never gets picked
implicitly. See [`../docs/RUNBOOK.md`](../docs/RUNBOOK.md)'s "Environments"
section for the release flow and the one-time state migration a
pre-existing deployment needs.

## Request path

```
caller --(HTTPS + Bearer token)--> API Gateway --(JWT authorizer)--> VPC Link --(HTTP, private)--> WAF --> ALB (internal)
  --> Kong (verify JWT, per-consumer rate limit) --(ECS Service Connect)--> ECS (books-api)
```

TLS terminates for real at API Gateway; everything after that is plain HTTP
inside the private VPC — see "The ALB is dedicated to this one service, and
plain HTTP" below for why.

**Why WAF is on the ALB, not API Gateway (`waf.tf`):** it was originally meant
to sit in front of the JWT authorizer, but that turned out not to be
possible — confirmed against a real `apply`, not a design choice: WAFv2's
`AssociateWebACL` only supports a fixed list of resource types (CloudFront,
ALB, AppSync, Cognito, App Runner, Verified Access, and API Gateway *REST*
APIs specifically), and HTTP APIs (`apigatewayv2`, what this project uses)
aren't on that list — every association attempt against the API Gateway
stage's ARN failed with "The ARN isn't valid" regardless of how the
`$default` stage name was encoded. Migrating to a REST API just to regain
WAF support isn't on the table — that's the same generation change
`kong.tf` already rejected, for the same reason, just for a different
missing feature (there, Usage Plans; here, WAF). So the Web ACL attaches to
the ALB instead: it still inspects every request's contents (AWS Managed
Rule Groups) and still rate-limits by real caller (a `forwarded_ip_config`-based
rate rule, since the ALB only sees the VPC Link's IP on the raw connection,
not the caller's — `X-Forwarded-For` is what actually carries it through
that hop), but it no longer shields the JWT authorizer itself from
anonymous volumetric abuse, since that traffic reaches API Gateway before
this WAF ever sees it. Blocked/rate-limited requests are logged to
`aws_cloudwatch_log_group.waf`, with the `Authorization` header redacted so
a still-valid bearer token never ends up in cleartext there.

`api_gateway.tf` is the only public thing here. The ALB (`alb.tf`) is
`internal = true` specifically so this can't be bypassed — there's no way to
reach it except through the VPC Link, which only API Gateway can use.
`cognito.tf` is the token issuer: machine-to-machine only (client-credentials
grant), no hosted login UI, no human users. See "Auth" below for the actual
flow a caller goes through.

**Why Kong sits in the middle (`kong.tf`):** API Gateway's JWT authorizer
only proves a token is *valid* — it can't rate-limit per caller, and
per-consumer throttling (Usage Plans/API Keys) isn't available on
`apigatewayv2` (HTTP API) at all, that's a REST API (v1)-only feature.
Rather than migrate API Gateway generations, Kong OSS sits behind the ALB
instead: it re-verifies the same Cognito-issued JWT (never trust an
unverified claim for rate-limiting), reads the caller's `client_id` claim,
and enforces that consumer's limit before the request ever reaches
`books-api`. `books-api` itself is no longer registered with the ALB at all —
Kong is; `books-api` is only reachable from Kong, over ECS Service Connect's
internal DNS (`books-api`), which is what makes Kong's build-time-baked
declarative config independent of Terraform apply order (an ALB's own
`dns_name` wouldn't exist yet when Kong's image is built — see
`ecs/kong/render_config.py`).

Kong's rate-limit counters are **in-memory** (`policy: local`), which is only
accurate with exactly one Kong task running — `var.kong_desired_count`
defaults to 1 for this reason. Scaling Kong out, or running more than one
task during a rolling deploy, means limits get enforced per-task rather than
globally, until this moves to a shared (Redis/ElastiCache-backed) policy —
not done here, to avoid adding a new stateful dependency for a low-traffic
template service.

## Auth

See [`../docs/RUNBOOK.md`](../docs/RUNBOOK.md) for the consumer-facing
version of this (how to make a request, how to get a client added, how to
change a consumer's rate limit) — this section is about why it's built this
way.

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

There's one Cognito client (and one Kong consumer/rate limit) per entry in
`var.api_consumers` — `CONSUMER=<name> ../scripts/get-token.sh` picks which
one (default: `"default"`, today's one real caller). See
`../docs/RUNBOOK.md`'s "How to add a user" for adding another.

Tokens are scoped (`books-api/read`, `books-api/write` — `cognito.tf`'s
resource server) and API Gateway enforces which one a route needs:
`GET /api/v1/books`/`GET /api/v1/books/{book_id}` accept either scope, while
`POST /api/v1/books`, `PATCH /api/v1/books/{book_id}`, and
`DELETE /api/v1/books/{book_id}` require `books-api/write` specifically
(`aws_apigatewayv2_route.books_*` in `api_gateway.tf`, via each route's own
`authorization_scopes` — a `read`-only token now gets a 401 from a mutating
call). `$default` (everything else — the health probes, `/`, any future
route not added to that list) stays audience-only, same as before scopes
existed — so a new endpoint needs its own explicit route here to actually
get scope enforcement, not just a new FastAPI path.

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
  everything) — straight out of `../ecs/task-definition.<environment>.json`
  (one file per environment, selected automatically by
  `terraform.workspace` — see `main.tf`), the same file CD renders for that
  environment. Nothing in `variables.tf`/`terraform.tfvars` duplicates a
  value that's already in that JSON; if the roles, image, or port change,
  edit the JSON, not a tfvars file. Terraform then only ignores
  `container_definitions` in `lifecycle`, so later CD-registered revisions
  don't drift.
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

`../scripts/bootstrap.sh` does everything below — the state bucket, workspace
selection, this `apply`, and the GitHub OIDC/secrets wiring
`../ecs/README.md` and `.github/workflows/` need — in one command, **run
once per environment** (`ENVIRONMENT=production`, then again with
`ENVIRONMENT=staging`). What follows is what it's actually doing, for anyone
customizing the process or debugging a step it got stuck on.

1. The zone in `hosted_zone_name` must already exist in Route 53 (create it
   once via console/CLI if it doesn't, and delegate it at your registrar —
   that's the only manual DNS step; once the zone exists and is delegated,
   everything else, including the ACM cert's DNS validation, works in one
   `apply` with no further waiting). Both environments can share the same
   zone as long as `domain_name` differs (e.g. `books-api.example.com` vs.
   `staging.books-api.example.com`).
2. Create the state backend once, ever — it's shared across environments
   (see `backend.hcl.example` for the CLI commands: just an S3 bucket; state
   locking is native to the S3 backend as of Terraform 1.10, no DynamoDB
   table needed). Copy it to `backend.hcl`, fill in real values,
   `terraform init -backend-config=backend.hcl`.
3. `terraform workspace select -or-create production` (or `staging`).
   `hosted_zone_name`/`domain_name` differ per environment, so they're
   passed as `TF_VAR_hosted_zone_name`/`TF_VAR_domain_name` rather than a
   shared `terraform.tfvars` — `terraform.tfvars.example` still works for a
   single-environment setup if you'd rather use a file, just don't let one
   copy get applied against the wrong workspace.
4. `terraform plan` and read it, then `terraform apply`. This creates the
   VPC, cluster, internal ALB, cert, target group, the two DynamoDB tables,
   Cognito (user pool, domain, one client per `var.api_consumers` entry),
   API Gateway (with its JWT authorizer and VPC Link), Kong (Service Connect
   namespace, target group, ECS service), and the initial ECS service + task
   definition revisions (`books-api` and `books-api-kong`) — all named for
   whichever workspace is currently selected.
5. Set that environment's GitHub OIDC deploy role ARN and
   `ECS_SUBNETS`/`ECS_SECURITY_GROUPS` (see
   [`../ecs/README.md`](../ecs/README.md)) from this apply's
   `aws_subnet.private[*].id` / `aws_security_group.ecs_tasks.id` — CD takes
   over deploys from here.

**Migrating an existing hand-created service:** if a service already exists
from an old manual bootstrap, `terraform import` it (and the target group /
Route 53 record) before the first `apply`, rather than applying blind —
otherwise Terraform will try to create resources that already exist.

**Migrating an existing pre-workspace production:** if this account already
had books-api applied before staging (and Terraform workspaces) existed
here, its state is in the unnamed `default` workspace, not one literally
named `production` — see [`../docs/RUNBOOK.md`](../docs/RUNBOOK.md)'s
"Environments" section for the state-migration steps. Do this before
running `bootstrap.sh` against production again.

## CI (GitHub Actions)

[`../.github/workflows/terraform.yml`](../.github/workflows/terraform.yml)
runs this from GitHub instead of a local machine:

- **On a PR** touching `terraform/`, it runs `plan` for **both**
  environments (a matrix job, one per workspace).
- **On push to `main`**, it **auto-applies to staging**. **On push of a
  `v*` tag**, it **auto-applies to production** — the same release trigger
  `cd.yml` uses, so a release promotes `terraform/`'s state at that commit
  to production alongside the image. Unlike the PR trigger, these aren't
  restricted to commits that touch `terraform/` — every push to `main`/`v*`
  runs `apply` regardless, since re-applying unchanged config is a cheap
  no-op and a release should mean production matches what's tagged in
  every respect.
- **`workflow_dispatch`** (the "Run workflow" button, or `gh workflow run
  terraform.yml -f action=apply -f environment=production`) runs `plan`
  (default) or `apply` against the one environment picked — for an on-demand
  re-apply with no new commit/tag.

Each environment reads from its **own** GitHub Environment ("staging" or
"production") — CI can't read `backend.hcl` or `terraform.tfvars`
(gitignored, never in the checkout):

| Kind | Name | Value |
| --- | --- | --- |
| Variable | `TF_STATE_BUCKET` | the backend S3 bucket — same value in both Environments, since the bucket itself is shared (see `backend.hcl`) |
| Variable | `HOSTED_ZONE_NAME` | e.g. `example.com` — typically the same in both |
| Variable | `DOMAIN_NAME` | e.g. `books-api.example.com` for production, `staging.books-api.example.com` for staging |
| Secret | `TF_DEPLOY_ROLE_ARN` | that environment's Terraform-apply role from IAM below — **not** the same secret as CD's `AWS_DEPLOY_ROLE_ARN`, and a **different role per environment** (`books-api-terraform` vs. `books-api-staging-terraform`) |

`apply` always runs with `-auto-approve` since there's no terminal in CI to
confirm otherwise — the actual safety net is a required-reviewers
protection rule on the target GitHub Environment, added in repo settings,
not anything in the workflow file (production almost certainly wants this;
staging may not). Worth knowing: since a PR's `plan` job also runs with
`environment: <that environment>`, turning on required reviewers pauses
PR-triggered plans for that environment too, not just applies — arguably a
feature, since an untrusted PR shouldn't read an environment's secrets just
by being opened, but it does mean plans aren't instant once that's on.

## IAM

`scripts/bootstrap.sh` creates the Terraform deploy role (and CD's) with an
**inline policy scoped per environment**, not `AdministratorAccess` — the
policy is built in the script itself (`TF_POLICY`/`CD_POLICY`), one role pair
per environment, so read it there for the literal JSON. The shape:

- **Resource-scoped by ARN** wherever the name is deterministic (everything
  keys off `$NAME_PREFIX`, so staging's role and production's role can only
  reach their *own* resources): ECS cluster/service, both DynamoDB tables,
  the CloudWatch log groups (including the WAF one, `aws-waf-logs-$NAME_PREFIX`),
  the SNS alerts topic, the CloudWatch alarms, the WAFv2 Web ACL (`waf.tf`
  — a Web ACL's ARN embeds its name verbatim, `regional/webacl/<name>/<id>`,
  so this scopes to `<name>/*` the same way AWS's own access-denied errors
  report the resource they checked), `iam:PassRole` for the execution/task
  roles, and (for CD) the ECR repo.
- **Resource-scoped by an `Environment` tag/condition** where the ARN isn't
  knowable ahead of the resource existing but the API supports tag-based
  conditions anyway: ACM certificate request/describe/delete
  (`aws:RequestTag`/`aws:ResourceTag`). Works because `versions.tf`'s
  provider `default_tags` stamps every resource Terraform creates with
  `Environment = <workspace>`.
- **`route53:ChangeResourceRecordSets` is scoped to the one hosted zone**,
  not per-environment — both environments' DNS records live in the *same*
  shared zone (`route53.tf`), so this is unavoidably shared between every
  environment's Terraform role. Nothing else about the zone (creation,
  deletion) is grantable at all, since it's looked up via `data`, never
  managed.
- **`wafv2:CreateWebACL`/`UpdateWebACL` also need permission on
  `regional/managedruleset/*/*`** (`WafManagedRuleGroups`) whenever the Web
  ACL references AWS Managed Rule Groups (waf.tf's three `rule` blocks) —
  confirmed against two real `apply` attempts, the second of which ruled out
  the obvious narrower fix: granting the three specific
  `regional/managedruleset/AWS/AWSManagedRulesXxx` ARNs `waf.tf` actually
  references still failed identically, because the AccessDenied error
  itself names the checked resource as the literal double wildcard, not the
  specific rule group that triggered it. This action's authorization
  apparently doesn't discriminate by which managed rule group is
  referenced — effectively `Resource: "*"` for this one statement (like
  Cognito/ACM's opaque-ID cases above), just narrowed to wafv2's
  `managedruleset` resource type. Shared across every environment's role
  the same way the hosted zone below is, since there's no `$NAME_PREFIX` in
  it to isolate by.
- **Still service-wide (`service:*`) on `Resource: "*"`, deliberately, not
  tightened further:** `ec2:*`, `elasticloadbalancing:*`, `apigateway:*`,
  `cognito-idp:*`. Two different reasons force this: (a) VPC/ALB/API
  Gateway resource-level IAM restriction is inconsistent enough across
  individual EC2/ELB/API-Gateway-v2 actions that enumerating them
  action-by-action risks silently breaking a live `apply` partway
  through — worse than leaving the service open; (b) Cognito user pool/API
  Gateway API IDs are opaque and assigned at creation, so there's no ARN to
  pre-scope to before the first `apply` ever runs — every Cognito action
  here was *already* `Resource: "*"` regardless of how the action list was
  written, so narrowing the actions bought no real isolation, only
  fragility (a hand-picked Cognito action list broke a real `apply` on
  `GetUserPoolMfaConfig`, a read call needed to populate a computed
  attribute that isn't obvious from the resource's own Create/Update/
  Describe actions — not the only one of its kind, most likely). **The
  residual gap:** with these, a compromised or misconfigured Terraform role
  in one environment could still reach *any* VPC/ALB/API Gateway/Cognito
  resource in the account, not just its own environment's — acceptable
  here only because nothing else in the account uses those services.
- `ecs:RegisterTaskDefinition`/`DeregisterTaskDefinition`/
  `DescribeTaskDefinition`/`ListTaskDefinitions`/`TagResource`/
  `UntagResource`/`ListTagsForResource` are also `Resource: "*"` — task
  definition actions don't support resource-level permissions at all per
  AWS's own ECS IAM reference, regardless of how narrowly you'd like to
  scope them. (The cluster/service actions in the same statement group
  *do* get scoped to this environment's own cluster/service ARNs — see
  `scripts/bootstrap.sh`'s `EcsClusterAndService` statement.)
- **`logs:CreateLogDelivery`/`GetLogDelivery`/`UpdateLogDelivery`/
  `DeleteLogDelivery`/`ListLogDeliveries`/`PutResourcePolicy`/
  `DescribeResourcePolicies` (`ApiGatewayAccessLogDelivery`) are
  `Resource: "*"`** — enabling `access_log_settings` on the
  `aws_apigatewayv2_stage` (`api_gateway.tf`, `dashboard.tf`'s data source)
  routes through CloudWatch's "Log Delivery" service under the hood rather
  than writing to the destination log group directly, and none of those
  delivery actions support resource-level scoping (the delivery resource
  doesn't exist yet at the time `CreateLogDelivery` is called — same class
  of gap as Cognito's opaque IDs above). The log *group* itself stays
  scoped (`LogsThisEnvironmentsGroup`) — only the delivery-pipe actions are
  wide.
- ECS cluster/service, SNS, and CloudWatch (Alarms and Logs) each also
  needed a `ListTagsForResource`/`ListTagsLogGroup`-style read action added
  alongside the obvious `TagResource` write — the same class of gap as
  Cognito's `GetUserPoolMfaConfig` above, but these three keep their
  hand-picked action lists (rather than going to a service-wide wildcard
  like Cognito did) because they *do* get real ARN-level resource scoping
  worth preserving, and each one's action set is small and well-bounded
  enough that hand-picking hasn't proven as fragile as Cognito's turned
  out to be.

Run `apply` from a separate role than the one CD assumes — don't widen the
deploy role just to let CI run Terraform too. In CI this is
`secrets.TF_DEPLOY_ROLE_ARN`, a different OIDC-trusted role from CD's
`AWS_DEPLOY_ROLE_ARN` even though both live in the same GitHub Environment
(per environment — "production"'s `TF_DEPLOY_ROLE_ARN` and "staging"'s are
two different roles, each trusted only for that one environment's OIDC
tokens, and now each scoped to that environment's own resources too; see
`scripts/bootstrap.sh`).

**If you're tightening an already-live role** (one bootstrapped before this
policy existed, still holding `AdministratorAccess`): re-run
`scripts/bootstrap.sh` for that environment — it detaches
`AdministratorAccess` and attaches the scoped policy in its place. Do this
against **staging first** and watch a full `terraform apply` + `cd.yml`
deploy succeed before doing the same to production. An `AccessDenied` error
afterward just means one action got missed for something this template
doesn't do by default (a customization you've added) — add it to the
relevant `Sid` in `scripts/bootstrap.sh` and re-run; it isn't a sign
anything here is fundamentally broken.

## Cost notes

- One NAT gateway (`single_nat_gateway = true`) rather than one per AZ —
  cheaper, less resilient to a single AZ outage. Fine for a low-traffic
  setup; flip the variable if that tradeoff stops being acceptable.
- `FARGATE_SPOT` is available as a capacity provider but not the default —
  opt in if this service can tolerate interruption.
