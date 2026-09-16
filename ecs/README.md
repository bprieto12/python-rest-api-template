# ECS deployment

Fargate task definition + service for `books-api`. CD pushes images to ECR and
updates these; the cluster, VPC/subnets, security groups, ALB, and target group
are assumed to already exist — created once via [`../terraform`](../terraform),
not something CD re-applies. That's the same boundary the Kubernetes manifests
this replaced drew around the EKS cluster: infra that's provisioned once,
versus the app-level config that changes on every deploy.

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

## One-time bootstrap (per environment)

`../scripts/bootstrap.sh` runs this (`ENVIRONMENT=<env> ./bootstrap.sh`) as
one step among several — the state bucket, `terraform apply` in that
environment's workspace, and the GitHub OIDC/secrets wiring too. Run it
directly instead only if you specifically want just the ECR repo + IAM
roles for one environment, without the rest.

1. `ENVIRONMENT=production ./bootstrap.sh` (or `ENVIRONMENT=staging`,
   defaults to `production` if unset) — creates the (shared) ECR repo, the
   two IAM roles below for that environment (the task role's DynamoDB
   permissions are scoped to that environment's table names in
   `../terraform`, by ARN), and patches the placeholder account id out of
   that environment's `task-definition.<environment>.json`. **Run this
   before `terraform apply`** — the task definition Terraform creates
   references these roles by ARN, and registration fails if they don't
   exist yet.
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
  `DescribeServices` on that environment's cluster/service only,
  `iam:PassRole` for the two roles above only, and push/pull on the one
  `books-api` ECR repo — not `AdministratorAccess`. See
  `scripts/bootstrap.sh`'s `CD_POLICY` for the literal policy and
  `terraform/README.md`'s IAM section for the equivalent reasoning on the
  Terraform role.
