# ECS deployment

Fargate task definition + service for `books-api`. CD pushes images to ECR and
updates these; the cluster, VPC/subnets, security groups, ALB, and target group
are assumed to already exist — created once via [`../terraform`](../terraform),
not something CD re-applies. That's the same boundary the Kubernetes manifests
this replaced drew around the EKS cluster: infra that's provisioned once,
versus the app-level config that changes on every deploy.

## Files

- **`task-definition.json`** — the Fargate task, two containers:
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
  in [`../terraform/main.tf`](../terraform/main.tf) — Terraform reads it
  to create the *first* task definition revision, so `apply` and CD agree on
  shape. See `../terraform/README.md` for why Terraform stops tracking it
  after that.

## One-time bootstrap (per environment)

`../scripts/bootstrap.sh` runs this (`./bootstrap.sh`) as one step among
several — the state bucket, `terraform apply`, and the GitHub OIDC/secrets
wiring too. Run it directly instead only if you specifically want just the
ECR repo + IAM roles, without the rest.

1. `./bootstrap.sh` — creates the ECR repo, the two IAM roles below (the task
   role's DynamoDB permissions are scoped to the table names `../terraform`
   creates, by ARN), and patches the placeholder account id out of
   `task-definition.json`. **Run this before `terraform apply`** — the task
   definition Terraform creates references these roles by ARN, and
   registration fails if they don't exist yet.
2. The service, target group, DynamoDB tables, and Route 53 record are
   created by [`../terraform`](../terraform) — see its README for the full
   setup.
3. Set the GitHub secret `AWS_DEPLOY_ROLE_ARN` in the `production` Environment
   — that's the only CD-specific setup left. (Older versions of this file
   also had you set `ECS_SUBNETS`/`ECS_SECURITY_GROUPS` for a migration
   task's network config — gone now that DynamoDB is schemaless and there's
   nothing to migrate.)

## IAM

`bootstrap.sh` creates both of these — this is what it sets up and why:

- **Execution role** (`executionRoleArn`, `books-api-execution`): pull from
  ECR, write to CloudWatch Logs (`AmazonECSTaskExecutionRolePolicy` covers
  both). No secrets to read — there's no connection string.
- **Task role** (`taskRoleArn`, `books-api-task`): what the *app containers*
  can call at runtime — `dynamodb:GetItem`/`PutItem`/`UpdateItem`/
  `DeleteItem`/`Scan`/`Query`/`DescribeTable` scoped to the two table ARNs
  (this is how the app actually talks to DynamoDB — no credentials in the
  task definition at all), plus `AWSXRayDaemonWriteAccess` and
  `CloudWatchAgentServerPolicy` for the collector sidecar.
- The **GitHub OIDC deploy role** (not created by the script — a role trusted
  for this repo via GitHub's OIDC provider) needs `ecs:RegisterTaskDefinition`,
  `ecs:UpdateService`, `ecs:DescribeServices`, `iam:PassRole` for the two
  roles above, plus ECR push.
