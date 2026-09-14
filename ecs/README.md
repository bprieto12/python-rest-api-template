# ECS deployment

Fargate task definition + service for `books-api`. CD pushes images to ECR and
updates these; the cluster, VPC/subnets, security groups, ALB, and target group
are assumed to already exist — created once via Terraform/CDK/console/CLI,
outside this repo. That's the same boundary the Kubernetes manifests this
replaced drew around the EKS cluster: infra that's provisioned once, versus the
app-level config that changes on every deploy.

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
- **`service-definition.json`** — input to the **one-time**
  `aws ecs create-service` bootstrap below. CD never touches networking or the
  load balancer after that; it only registers new task definition revisions and
  calls `update-service`.

## One-time bootstrap (per environment)

1. `aws ecs create-cluster --cluster-name books-api`
2. Fill in `service-definition.json` — real subnets, security group, target
   group ARN — then:
   `aws ecs create-service --cli-input-json file://ecs/service-definition.json`
3. Set the GitHub secret `AWS_DEPLOY_ROLE_ARN` and repo/environment variables
   `ECS_SUBNETS` and `ECS_SECURITY_GROUPS` (comma-separated subnet/SG ids, no
   quotes) — the one-off migration task in CD needs its own network config
   since it isn't part of the service.

## IAM

- **Execution role** (`executionRoleArn`): pull from ECR, write to CloudWatch
  Logs, read the `DATABASE_URL` secret (`secretsmanager:GetSecretValue`).
- **Task role** (`taskRoleArn`): what the *app containers* can call at runtime —
  for the collector sidecar, attach `AWSXRayDaemonWriteAccess` and enough
  CloudWatch Logs access to write EMF metrics (`CloudWatchAgentServerPolicy`
  covers it).
- The **GitHub OIDC deploy role** needs `ecs:RegisterTaskDefinition`,
  `ecs:RunTask`, `ecs:DescribeTasks`, `ecs:UpdateService`,
  `ecs:DescribeServices`, `iam:PassRole` for the two roles above, plus ECR push.

## Migrations

ECS has no Kubernetes-style init container. CD instead `run-task`s the same
task definition with the `api` container's command overridden to
`alembic upgrade head`, waits for it to stop, and checks its exit code —
the service is only updated if that migration succeeded.
