# ECS deployment

Fargate task definition + service for `books-api`. CD pushes images to ECR and
updates these; the cluster, VPC/subnets, security groups, ALB, and target group
are assumed to already exist — created once via [`../terraform`](../terraform),
not something CD re-applies. That's the same boundary the Kubernetes manifests
this replaced drew around the EKS cluster: infra that's provisioned once,
versus the app-level config that changes on every deploy.

## Files

- **`task-definition.json`** — the Fargate task, two containers:
  - `api` — the app. `DATABASE_URL` comes from Secrets Manager via `secrets`;
    everything else is a plain env var. `OTEL_EXPORTER_OTLP_ENDPOINT` points at
    `localhost:4317` — the sidecar below, reachable because containers in one
    Fargate task share a network namespace (`awsvpc` mode).
  - `aws-otel-collector` — the [ADOT](https://aws-otel.github.io/) collector,
    using its bundled `ecs-cloudwatch-xray.yaml` preset: traces → X-Ray,
    metrics → CloudWatch (EMF), both tagged with cluster/task/revision via
    ECS resource detection. Swap the `command` for a different bundled preset
    (e.g. `ecs-amp-xray.yaml` for Amazon Managed Prometheus instead of
    CloudWatch) or point `AOT_CONFIG_CONTENT` at your own YAML if you need a
    different backend — the local `otel-collector.yaml` used by `docker compose`
    is a reasonable starting point.

  This file is also the single source of truth for the container definitions
  in [`../terraform/main.tf`](../terraform/main.tf) — Terraform reads it
  to create the *first* task definition revision, so `apply` and CD agree on
  shape. See `../terraform/README.md` for why Terraform stops tracking it
  after that.

## One-time bootstrap (per environment)

1. `./bootstrap.sh` (needs `DATABASE_URL` in the environment — see the script
   header) — creates the ECR repo, the two IAM roles below, the
   `books-api/database-url` secret, and patches the placeholder account id
   out of `task-definition.json`. **Run this before `terraform apply`** —
   the task definition Terraform creates references these roles by ARN, and
   registration fails if they don't exist yet.
2. The service, target group, and Route 53 record are created by
   [`../terraform`](../terraform) — see its README for the full setup.
3. Set the GitHub secret `AWS_DEPLOY_ROLE_ARN` and repo/environment variables
   `ECS_SUBNETS` and `ECS_SECURITY_GROUPS` (comma-separated subnet/SG ids, no
   quotes) — the one-off migration task in CD needs its own network config
   since it isn't part of the service.

## IAM

`bootstrap.sh` creates both of these — this is what it sets up and why:

- **Execution role** (`executionRoleArn`, `books-api-execution`): pull from
  ECR, write to CloudWatch Logs (`AmazonECSTaskExecutionRolePolicy` covers
  both), read the `DATABASE_URL` secret (`secretsmanager:GetSecretValue`,
  scoped to that one secret's ARN via an inline policy).
- **Task role** (`taskRoleArn`, `books-api-task`): what the *app containers*
  can call at runtime — for the collector sidecar, `AWSXRayDaemonWriteAccess`
  and `CloudWatchAgentServerPolicy` (EMF metrics).
- The **GitHub OIDC deploy role** (not created by the script — a role trusted
  for this repo via GitHub's OIDC provider) needs `ecs:RegisterTaskDefinition`,
  `ecs:RunTask`, `ecs:DescribeTasks`, `ecs:UpdateService`,
  `ecs:DescribeServices`, `iam:PassRole` for the two roles above, plus ECR push.

## Migrations

ECS has no Kubernetes-style init container. CD instead `run-task`s the same
task definition with the `api` container's command overridden to
`alembic upgrade head`, waits for it to stop, and checks its exit code —
the service is only updated if that migration succeeded.
