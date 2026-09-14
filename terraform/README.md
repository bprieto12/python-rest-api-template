# Terraform — books-api service

Service-level infrastructure for `books-api`: ECS task definition (initial
revision only), ECS service, target group, one listener rule on the shared
ALB, and one Route 53 record. This replaces the manual `aws ecs create-service`
bootstrap that used to live in [`../ecs/service-definition.json`](../ecs).

**What's deliberately *not* here:** the ECS cluster, VPC/subnets, security
groups, ALB, and Route 53 hosted zone. Those are shared across every service
and belong in the `infrastructure` repo, one level up in ownership — this
directory only *references* them, by ARN/id, via variables. See the
[python-rest-api-template ↔ infrastructure split](../CLAUDE.md#deploy-pipeline)
for the reasoning.

## Why Terraform only owns the *first* task definition revision

CD ([`../.github/workflows/cd.yml`](../.github/workflows/cd.yml)) calls
`aws ecs register-task-definition` and `aws ecs update-service
--force-new-deployment` directly, on every push to `main`. If Terraform also
tracked every field of the task definition and service, `terraform plan` would
see CD's changes as drift and try to revert them on the next apply.

Instead:
- `aws_ecs_task_definition.this` reads every field it needs — family, cpu,
  memory, execution/task role ARNs, container definitions (image, port,
  everything) — straight out of `../ecs/task-definition.json`, the same file
  CD renders. Nothing in `variables.tf`/`terraform.tfvars` duplicates a value
  that's already in that JSON; if the roles, image, or port change, edit the
  JSON, not a tfvars file, so there's one place to keep in sync. Terraform
  then only ignores `container_definitions` in `lifecycle`, so later
  CD-registered revisions don't drift.
- `aws_ecs_service.this` ignores `task_definition` and `desired_count` for the
  same reason — CD owns rollouts, and scaling is handled outside this repo
  (console/CLI/autoscaling), not by re-applying Terraform.

Net effect: Terraform owns the *shape* of the service (networking, load
balancer wiring, DNS) and reads app-level facts (roles, image, port) from the
same file CD uses; CD owns *rollouts*. Re-running `terraform apply` after a
normal deploy should show no changes to those two resources.

## One-time setup (per environment)

1. Configure the S3 backend (bucket/key/region/DynamoDB lock table aren't
   hardcoded — see `versions.tf`):
   ```
   terraform init -backend-config=environments/production.backend.hcl
   ```
   (or pass `-backend-config` flags directly; there's no multi-environment
   directory layout yet since there's only one deploy target today).
2. Copy `terraform.tfvars.example` → `terraform.tfvars` and fill in real
   values — most of them come from the `infrastructure` repo's outputs
   (cluster name, VPC/subnet/SG ids, ALB listener ARN, hosted zone id).
3. `terraform apply`. This creates the target group, listener rule, Route 53
   record, and the initial ECS service + task definition revision.
4. Set the GitHub OIDC deploy role ARN and `ECS_SUBNETS`/`ECS_SECURITY_GROUPS`
   as before (see [`../ecs/README.md`](../ecs/README.md)) — CD takes over
   deploys from here.

**Migrating an existing hand-created service:** if a service already exists
from the old `aws ecs create-service` bootstrap, `terraform import` it (and
the target group / listener rule / Route 53 record) before the first
`apply`, rather than applying blind — otherwise Terraform will try to create
resources that already exist.

## Next step: SSM-backed platform inputs

Right now the platform inputs (`cluster_name`, `vpc_id`, `subnet_ids`,
`security_group_ids`, `alb_listener_arn`, `alb_dns_name`, `alb_zone_id`,
`hosted_zone_id`) are plain variables filled in by hand. Once the
`infrastructure` repo exists and publishes these as SSM parameters, swap
their declarations in `variables.tf` for `data "aws_ssm_parameter"` lookups
(with the plain variables kept as an override) — `main.tf` doesn't need to
change, since resources only ever reference `var.*`.

## IAM

Applying this needs a broader role than CD's OIDC deploy role — at minimum
`ecs:CreateService`/`UpdateService`/`DescribeServices`,
`elasticloadbalancing:CreateTargetGroup`/`CreateRule`/`Describe*`,
`route53:ChangeResourceRecordSets`, and `iam:PassRole` for the execution/task
roles. Run `apply` from a separate, more privileged role than the one CD
assumes — don't widen the deploy role just to let CI run Terraform too.
