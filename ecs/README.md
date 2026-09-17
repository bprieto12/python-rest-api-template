# ECS deployment

Fargate task definitions + services for `books-api` **and** Kong
(`../terraform/kong.tf` — per-consumer rate limiting in front of
`books-api`; see `../terraform/README.md`'s "Why Kong sits in the middle").
CD pushes images to ECR and updates these; the cluster, VPC/subnets, security
groups, ALB, and target groups are assumed to already exist — created once
via [`../terraform`](../terraform), not something CD re-applies. That's the
same boundary the Kubernetes manifests this replaced drew around the EKS
cluster: infra that's provisioned once, versus the app-level config that
changes on every deploy.

## Files

- **`task-definition.<environment>.json`** (`.production.json`,
  `.staging.json`) — one per environment, since role ARNs, table names, the
  log group, and `OTEL_SERVICE_NAME` all differ between them (see
  `../terraform/environment.tf`'s naming rule: production keeps every name
  as-is, staging gets `-staging` appended). Otherwise identical — diff them
  before adding a third environment or changing shared config, to make sure
  only the environment-specific fields actually differ. Two containers each:
  - `api` — the app. `DYNAMODB_BOOKS_TABLE`/`DYNAMODB_ISBNS_TABLE`/`AWS_REGION`
    are plain env vars (no secret — DynamoDB access comes from the task role's
    IAM permissions, not a connection string). `OTEL_EXPORTER_OTLP_ENDPOINT`
    points at `localhost:4317` — the sidecar below, reachable because
    containers in one Fargate task share a network namespace (`awsvpc` mode).
  - `aws-otel-collector` — the [ADOT](https://aws-otel.github.io/) collector,
    using its bundled `ecs-cloudwatch-xray.yaml` preset: traces → X-Ray,
    metrics → CloudWatch (EMF), both tagged with cluster/task/revision via
    ECS resource detection. Swap the `command` for a different bundled preset
    (e.g. `ecs-amp-xray.yaml` for Amazon Managed Prometheus instead of
    CloudWatch) or point `AOT_CONFIG_CONTENT` at your own YAML if you need a
    different backend — the local `otel-collector.yaml` used by `docker compose`
    is a reasonable starting point.

  This file is also the single source of truth for the container definitions
  in [`../terraform/main.tf`](../terraform/main.tf) — Terraform reads the
  one for its selected workspace (`terraform.workspace`) to create the
  *first* task definition revision for that environment, so `apply` and CD
  agree on shape. See `../terraform/README.md` for why Terraform stops
  tracking it after that.

- **`task-definition.kong.<environment>.json`** — same shape and same
  Terraform/CD ownership split as above (read by
  [`../terraform/kong.tf`](../terraform/kong.tf) instead of `main.tf`), one
  `kong` container. Reuses `books-api`'s own execution role as both
  `executionRoleArn` and `taskRoleArn` — Kong makes no AWS API calls at
  runtime (its config is baked into the image, not fetched), so it needs
  nothing beyond what the execution role already grants (ECR pull, log
  write), and logs into the *same* log group as `books-api`
  (`awslogs-stream-prefix: kong`) rather than a group of its own, so no new
  `logs:CreateLogGroup` grant was needed either. See
  [`kong/`](kong/) for the image itself and how its declarative config
  (`kong.yml`) gets built.

## One-time bootstrap (per environment)

`../scripts/bootstrap.sh` runs this (`ENVIRONMENT=<env> ./bootstrap.sh`) as
one step among several — the state bucket, `terraform apply` in that
environment's workspace, and the GitHub OIDC/secrets wiring too. Run it
directly instead only if you specifically want just the ECR repo + IAM
roles for one environment, without the rest.

1. `ENVIRONMENT=production ./bootstrap.sh` (or `ENVIRONMENT=staging`,
   defaults to `production` if unset) — creates the two (shared, not
   environment-scoped) ECR repos `books-api` and `kong`, the two IAM roles
   below for that environment (the task role's DynamoDB permissions are
   scoped to that environment's table names in `../terraform`, by ARN — Kong
   reuses these same two roles, see "Files" above), and patches the
   placeholder account id out of that environment's
   `task-definition.<environment>.json` **and**
   `task-definition.kong.<environment>.json`. **Run this before `terraform
   apply`** — the task definitions Terraform creates reference these roles
   by ARN, and registration fails if they don't exist yet.
2. The service, target group, DynamoDB tables, and Route 53 record are
   created by [`../terraform`](../terraform) — see its README for the full
   setup.
3. Set that environment's GitHub secret `AWS_DEPLOY_ROLE_ARN` in the
   matching GitHub Environment ("production" or "staging") — that's the only
   CD-specific setup left. (Older versions of this file also had you set
   `ECS_SUBNETS`/`ECS_SECURITY_GROUPS` for a migration task's network
   config — gone now that DynamoDB is schemaless and there's nothing to
   migrate.)

## IAM

`bootstrap.sh` creates both of these, per environment (production:
`books-api-execution`/`books-api-task`; staging:
`books-api-staging-execution`/`books-api-staging-task`) — this is what it
sets up and why:

- **Execution role** (`executionRoleArn`): pull from ECR, write to
  CloudWatch Logs (`AmazonECSTaskExecutionRolePolicy` covers both). No
  secrets to read — there's no connection string.
- **Task role** (`taskRoleArn`): what the *app containers* can call at
  runtime — `dynamodb:GetItem`/`PutItem`/`UpdateItem`/`DeleteItem`/`Scan`/
  `Query`/`DescribeTable` scoped to that environment's two table ARNs (this
  is how the app actually talks to DynamoDB — no credentials in the task
  definition at all), plus `AWSXRayDaemonWriteAccess` and
  `CloudWatchAgentServerPolicy` for the collector sidecar.
- The **GitHub OIDC deploy role** (`books-api-cd`/`books-api-staging-cd`,
  created by `scripts/bootstrap.sh`, not this one — a role trusted for this
  repo via GitHub's OIDC provider, one per environment) has an inline policy
  scoped to `ecs:RegisterTaskDefinition`, `ecs:UpdateService`/
  `DescribeServices` on that environment's `books-api` *and* `books-api-kong`
  services only, `iam:PassRole` for the two roles above only, push/pull on
  the `books-api` and `kong` ECR repos, and read-only
  `cognito-idp:ListUserPoolClients` (`Resource: "*"` — a user pool's ARN is
  opaque before the first apply, same class of gap as Cognito elsewhere in
  this repo's IAM) so `cd.yml`'s `build-and-push-kong` job can render Kong's
  declarative config without needing Terraform state access — not
  `AdministratorAccess`. See `scripts/bootstrap.sh`'s `CD_POLICY` for the
  literal policy and `terraform/README.md`'s IAM section for the equivalent
  reasoning on the
  Terraform role.
