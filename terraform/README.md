# Terraform — books-api

Everything this service needs on AWS, in one place: a dedicated VPC, ECS
cluster, an *internal* ALB, API Gateway (the actual public entry point) with
Cognito-issued OAuth2 tokens enforced on every request, the two DynamoDB
tables, and the ECS task definition/service. Deliberately not split across a
separate "platform" repo and a "service" repo — this is one small service
with one deploy target, and that split earns its cost once there's a second
service sharing infrastructure, not before. See `../CLAUDE.md`'s deploy
pipeline section for how this fits with `../ecs/` and CD.

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
   Cognito (user pool, domain, client), API Gateway (with its JWT authorizer
   and VPC Link), and the initial ECS service + task definition revision —
   all named for whichever workspace is currently selected.
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
  the CloudWatch log group, the SNS alerts topic, the CloudWatch alarms,
  `iam:PassRole` for the execution/task roles, and (for CD) the ECR repo.
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
- **Still service-wide (`service:*`) on `Resource: "*"`, deliberately, not
  tightened further:** `ec2:*`, `elasticloadbalancing:*`, `apigateway:*`,
  and Cognito's own action list (though narrowed off the full
  `cognito-idp:*`, it isn't resource-scoped). Two different reasons force
  this: (a) VPC/ALB/API Gateway resource-level IAM restriction is
  inconsistent enough across individual EC2/ELB/API-Gateway-v2 actions that
  enumerating them action-by-action risks silently breaking a live `apply`
  partway through — worse than leaving the service open; (b) Cognito user
  pool/API Gateway API IDs are opaque and assigned at creation, so there's
  no ARN to pre-scope to before the first `apply` ever runs. **The residual
  gap:** with these, a compromised or misconfigured Terraform role in one
  environment could still reach *any* VPC/ALB/API Gateway/Cognito resource
  in the account, not just its own environment's — acceptable here only
  because nothing else in the account uses those services.
- `ecs:RegisterTaskDefinition`/`DeregisterTaskDefinition`/
  `DescribeTaskDefinition`/`ListTaskDefinitions` are also `Resource: "*"` —
  these don't support resource-level permissions at all per AWS's own ECS
  IAM reference, regardless of how narrowly you'd like to scope them.

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
