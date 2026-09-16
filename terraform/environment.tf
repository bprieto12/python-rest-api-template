# Staging and production are two Terraform workspaces against this same
# config, not two directories or a separate module — the resources are
# identical between them (same VPC/ALB/ECS/Cognito/API-Gateway/DynamoDB
# shape), which is exactly the case workspaces exist for. Each workspace
# gets its own state automatically (the S3 backend keys it under
# env:/<workspace>/<key>) with zero extra backend config.
#
#   terraform workspace new staging      # once, ever
#   terraform workspace select staging   # before every plan/apply against it
#
# "production" keeps every name exactly as it already was before this file
# existed (no environment suffix) — it was live before workspaces existed
# here, and a rename would mean Terraform destroying and recreating
# everything just to relabel it. Only staging (and anything created after
# it) gets a suffix. See docs/RUNBOOK.md's "Environments" section for the
# one-time migration that moved production's existing state into a
# "production" workspace to make this possible without downtime.
#
# terraform.workspace defaults to "default" if nobody's selected one yet —
# that's never a real environment here, so applying in it is refused
# outright rather than silently creating yet another (wrongly-named) copy
# of everything.
check "workspace_selected" {
  assert {
    condition     = terraform.workspace != "default"
    error_message = "Select a workspace first: terraform workspace select production (or staging) — never apply in the default workspace."
  }
}

locals {
  environment = terraform.workspace
  name_prefix = local.environment == "production" ? "books-api" : "books-api-${local.environment}"
}
