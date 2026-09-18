#!/usr/bin/env bash
# One-command setup for a books-api environment: the Terraform state bucket
# (shared across environments — one bucket, isolated by Terraform workspace,
# see terraform/environment.tf), ECR + the ECS execution/task IAM roles (via
# ecs/bootstrap.sh), a GitHub OIDC provider (shared) + two PER-ENVIRONMENT
# deploy roles, `terraform apply` in that environment's workspace, and every
# GitHub Environment secret/variable CD, the Terraform CI workflow, and the
# k6 performance workflow need (AWS_DEPLOY_ROLE_ARN, TF_DEPLOY_ROLE_ARN,
# COGNITO_CLIENT_SECRET, DOMAIN_NAME, HOSTED_ZONE_NAME, TF_STATE_BUCKET,
# ECS_SUBNETS, ECS_SECURITY_GROUPS, COGNITO_CLIENT_ID, COGNITO_DOMAIN — all
# in the $ENVIRONMENT GitHub Environment). Safe to re-run: every step checks
# before creating/overwriting.
#
# Run once per environment, right after cloning this template into a new
# repo:
#   HOSTED_ZONE_NAME=example.com DOMAIN_NAME=books-api.example.com \
#     ENVIRONMENT=production ./scripts/bootstrap.sh
#   HOSTED_ZONE_NAME=example.com DOMAIN_NAME=staging.books-api.example.com \
#     ENVIRONMENT=staging ./scripts/bootstrap.sh
#
# If books-api is already live in this account from BEFORE environments
# existed here, its state is sitting in Terraform's unnamed "default"
# workspace, not a "production" workspace — migrate that state first (see
# docs/RUNBOOK.md's "Environments" section) or this script's `terraform
# apply` will try to create a second, colliding copy of everything.
#
# Does NOT create your domain or Route 53 hosted zone — bring your own,
# already delegated (see terraform/variables.tf's hosted_zone_name
# description for why this repo never owns it). scripts/teardown.sh's
# reverse of this never touches it either.
#
#   Optional: AWS_REGION (default us-east-1), ENVIRONMENT (default
#   production — the same default terraform/environment.tf and
#   ecs/bootstrap.sh use), TF_STATE_BUCKET (default
#   books-api-tfstate-<account-id> — override this to reconcile with a
#   bucket that already exists from a previous manual setup), GITHUB_REPO
#   (owner/repo — default: read from `gh repo view`), AUTO_APPROVE=1 (skip
#   the terraform apply / teardown-style confirmation prompts, for CI).
#
# Needs, on $PATH and authenticated: aws, terraform (>=1.10), gh, python3.
# Needs REAL AWS credentials (static keys, or an assumed role) exported as
# AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY(/AWS_SESSION_TOKEN) — not an
# `aws login` browser session, which the AWS CLI understands but neither
# Terraform's nor aioboto3's SDKs do (this bit us repeatedly during initial
# setup — see git history on terraform/README.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

: "${HOSTED_ZONE_NAME:?Set HOSTED_ZONE_NAME to an already-existing, already-delegated Route 53 hosted zone, e.g. example.com}"
: "${DOMAIN_NAME:?Set DOMAIN_NAME to the FQDN this service should answer on, e.g. books-api.example.com}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-production}"
if [ "$ENVIRONMENT" = "production" ]; then
  NAME_PREFIX="books-api"
else
  NAME_PREFIX="books-api-$ENVIRONMENT"
fi

echo "== Preflight =="

for cmd in aws terraform gh python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required tool: $cmd" >&2; exit 1; }
done

if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  cat >&2 <<'EOF'
AWS_ACCESS_KEY_ID isn't set. Terraform needs real static credentials (or an
assumed role) — an `aws login` browser session works for the aws CLI itself
but not for Terraform's (or aioboto3's) own SDK, which don't read its cache.
Export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (and AWS_SESSION_TOKEN if
temporary) first.
EOF
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Account: $ACCOUNT_ID   Region: $AWS_REGION   Environment: $ENVIRONMENT"

HOSTED_ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "$HOSTED_ZONE_NAME" \
  --query "HostedZones[?Name=='${HOSTED_ZONE_NAME}.'].Id | [0]" --output text)"
if [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" = "None" ]; then
  echo "No Route 53 hosted zone found for $HOSTED_ZONE_NAME." >&2
  echo "This script doesn't create one — create/delegate it first, then re-run." >&2
  exit 1
fi
HOSTED_ZONE_ID="${HOSTED_ZONE_ID#/hostedzone/}" # comes back as "/hostedzone/ZXXXXXXXXXXXXX"; used below to scope the Terraform role's route53:ChangeResourceRecordSets

REPO_NWO="${GITHUB_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
: "${REPO_NWO:?Could not determine the GitHub repo. Run this from inside a clone with gh authenticated, or set GITHUB_REPO=owner/repo}"
echo "GitHub repo: $REPO_NWO"

TF_STATE_BUCKET="${TF_STATE_BUCKET:-books-api-tfstate-$ACCOUNT_ID}"
echo "State bucket: $TF_STATE_BUCKET (shared across environments — isolated by Terraform workspace)"
echo

echo "== 1. Terraform state bucket =="

if aws s3api head-bucket --bucket "$TF_STATE_BUCKET" 2>/dev/null; then
  echo "Already exists"
else
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$AWS_REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
  fi
  aws s3api put-bucket-versioning --bucket "$TF_STATE_BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$TF_STATE_BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
  aws s3api put-public-access-block --bucket "$TF_STATE_BUCKET" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "Created (versioned, encrypted, public access blocked)"
fi
echo

echo "== 2. Local Terraform backend config =="
# Shared across environments (one bucket, one key, isolated by workspace)
# so this is written once regardless of which environment you're
# bootstrapping. hosted_zone_name/domain_name are NOT written to a local
# tfvars file — they differ per environment, so they're passed as
# TF_VAR_* below instead, the same way the GitHub Actions workflows do it.

if [ -f "$TF_DIR/backend.hcl" ]; then
  echo "terraform/backend.hcl already exists — leaving it alone"
else
  cat > "$TF_DIR/backend.hcl" <<EOF
bucket       = "$TF_STATE_BUCKET"
key          = "books-api.tfstate"
region       = "$AWS_REGION"
use_lockfile = true
encrypt      = true
EOF
  echo "Wrote terraform/backend.hcl"
fi
echo

echo "== 3. ECR repo + ECS execution/task IAM roles =="
echo "(must exist before terraform apply — the task definition it creates"
echo "references these roles by ARN)"
(cd "$REPO_ROOT" && ENVIRONMENT="$ENVIRONMENT" AWS_REGION="$AWS_REGION" ./ecs/bootstrap.sh)
echo

echo "== 4. GitHub OIDC provider + deploy roles =="

OIDC_PROVIDER_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
  echo "GitHub OIDC provider already registered"
else
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 >/dev/null
  echo "Registered GitHub OIDC provider"
fi

# Every workflow job that needs these roles (cd.yml's build-and-push and
# deploy, terraform.yml's plan/apply jobs) uses `environment:
# $ENVIRONMENT` — that alone fixes the OIDC token's `sub` claim to this one
# form, regardless of whether the run was a push, a PR, or
# workflow_dispatch (see git history on this file — found out the hard way
# that "environment:" overrides the usual ref/pull_request-shaped sub
# entirely). The owner/repo each get a `*` wildcard because GitHub embeds
# their immutable numeric IDs in the real claim (repo:owner@id/name@id:...),
# not just the plain names.
#
# One role pair PER environment (books-api-cd/books-api-terraform for
# production, books-api-staging-cd/books-api-staging-terraform for
# staging, etc.) — each one's trust policy only matches OIDC tokens minted
# for that one GitHub Environment, so a compromised staging deploy can't
# assume production's role.
OWNER="${REPO_NWO%%/*}"
REPO="${REPO_NWO#*/}"
TRUST_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "$OIDC_PROVIDER_ARN" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": { "token.actions.githubusercontent.com:sub": "repo:${OWNER}@*/${REPO}@*:environment:${ENVIRONMENT}" }
    }
  }]
}
JSON
)

create_or_update_role() {
  local role_name="$1"
  if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$role_name" --policy-document "$TRUST_POLICY"
    echo "IAM role $role_name already existed — trust policy refreshed"
  else
    aws iam create-role --role-name "$role_name" --assume-role-policy-document "$TRUST_POLICY" >/dev/null
    echo "Created IAM role $role_name"
  fi
  # Detach AdministratorAccess if an earlier version of this script attached
  # it — this run replaces it with the scoped inline policy below. Harmless
  # no-op if it was never attached (that's the common case on a fresh role).
  aws iam detach-role-policy --role-name "$role_name" \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess 2>/dev/null || true
}

CD_ROLE_NAME="${NAME_PREFIX}-cd"
TF_ROLE_NAME="${NAME_PREFIX}-terraform"
create_or_update_role "$CD_ROLE_NAME"
create_or_update_role "$TF_ROLE_NAME"

CD_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$CD_ROLE_NAME"
TF_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$TF_ROLE_NAME"

# Both policies below are scoped to THIS environment's own resources
# wherever the target AWS API supports it (by ARN where the name is
# deterministic — cluster/service/table/log-group/topic/alarm all embed
# $NAME_PREFIX — or by an Environment tag/RequestTag condition where it
# isn't, since every resource Terraform creates gets `Environment =
# $ENVIRONMENT` from versions.tf's provider default_tags). A few services
# stay allowed on Resource "*" — not full-account AdministratorAccess, but
# not resource-scoped either — because their create-time ARNs are opaque
# (Cognito pool IDs, API Gateway IDs, ACM certificate IDs, and now the Cloud
# Map namespace kong.tf's aws_service_discovery_http_namespace creates for
# ECS Service Connect all fall in this bucket — none are knowable before the
# first apply) or resource-level IAM restriction genuinely isn't supported
# for the action (ecs:RegisterTaskDefinition, elasticloadbalancing:*,
# ec2:* mostly fall in the latter camp — VPC/ALB networking actions are too
# fragile to enumerate action-by-action without live testing; getting one
# wrong mid-`apply` against real infrastructure is worse than leaving that
# one service-wide). See terraform/README.md's IAM section for the full
# reasoning and the residual gaps this leaves.
#
# route53:ChangeResourceRecordSets is scoped to the one hosted zone, not to
# $ENVIRONMENT — both environments' DNS records live in the SAME shared
# zone (see route53.tf), so this one action is unavoidably shared between
# every environment's Terraform role.
#
# cognito-idp:* is a full service wildcard, not a hand-picked action list —
# it was a narrower list originally, but the AWS provider's aws_cognito_*
# resources turned out to need a long tail of dedicated per-config read
# calls (GetUserPoolMfaConfig, etc.) beyond the obvious Create/Delete/
# Describe/Update ones, discovered one broken `apply` at a time. Since
# every Cognito action here is already Resource "*" anyway (pool/client
# IDs are opaque, can't be pre-scoped — see above), narrowing the action
# list bought no real resource-level isolation, just fragility. ECS/SNS/
# CloudWatch Alarms/Logs below hit the SAME class of gap (their own
# List/GetTags-style calls, needed for the AWS provider to read back tags
# on refresh) — those keep hand-picked action lists since they're each a
# small, well-bounded set AND (unlike Cognito) actually get real ARN-level
# resource scoping worth preserving; each fix is called out at its own
# statement below.
#
# The Terraform role also needs read-only access to the bare (un-prefixed)
# "books-api.tfstate" key, not just its own "env:/$ENVIRONMENT/..." one —
# `terraform init` always checks state at whatever workspace is currently
# selected BEFORE any `terraform workspace select` runs, which on a fresh
# checkout (CI, or a new clone) is the unnamed "default" workspace, whose
# key has no "env:/" prefix at all. Without this, init itself 403s before
# ever reaching the real workspace. Read-only is deliberate — the "default"
# workspace should hold nothing after migration (see
# terraform/environment.tf and docs/RUNBOOK.md's "Environments" section),
# so this role should never need to WRITE there.
#
# That bare key ALSO has to be covered by the ListBucket statement's
# prefix condition below, not just s3:GetObject — this bit us for real:
# the key genuinely doesn't exist post-migration (correctly — "default"
# should be empty), and S3 deliberately returns 403 instead of 404 for a
# GetObject/HeadObject on a nonexistent key whenever the caller can't
# ALSO confirm non-existence via ListBucket on that same prefix. Without
# "books-api.tfstate" in the allowed s3:prefix list, the correctly-granted
# s3:GetObject above still 403s in practice, not 404s — indistinguishable
# from a real permissions gap from the caller's side.
#
# ListBucket's prefix condition is "env:/*", not "env:/$ENVIRONMENT/*" —
# this ALSO bit us for real, worse than the above: `terraform workspace
# select -or-create` has to LIST the generic "env:/" prefix first, to
# enumerate every EXISTING workspace and decide whether to select or
# create one. Scoped to just this environment's own subtree, that listing
# 403s, and Terraform — unable to tell "staging" already exists — takes
# the "create" branch, silently against a workspace that's already live,
# every single run. Object-level access (GetObject/PutObject/DeleteObject
# on StateBackendObjects above) stays scoped to this environment's own
# key only — this only widens what key NAMES the role can see exist, not
# what content it can read or write. Names alone aren't sensitive here
# ("staging"/"production" are already public knowledge from this repo's
# own docs); the alternative (every environment's Terraform role silently
# reapplying its entire config from scratch, colliding with its own real
# infrastructure, on every single run) is far worse.
#
# CognitoReadForKongConfig (below) is new for Kong: cd.yml's
# build-and-push-kong job renders kong.yml (ecs/kong/render_config.py) from
# the live consumer list + Cognito's JWKS before building that image, which
# means reading Cognito directly — the CD role has no Terraform state access
# (that's TF_POLICY's job, a different role), so it can't get any of this
# from `terraform output` the way a human running scripts/get-token.sh
# would. Everything is self-discovered at deploy time, not read from a
# GitHub Environment variable/secret someone has to keep in sync by hand —
# confirmed the hard way that a fresh teardown+bootstrap+release cycle can
# reach this job with those never populated (nothing about cutting a
# release *requires* bootstrap.sh's interactive local flow to have
# succeeded first): ListUserPools finds the pool by its deterministic name
# (local.name_prefix), ListUserPoolClients lists its clients (name + id,
# all render_config.py needs), and DescribeUserPoolClient reads the
# "default" consumer's secret directly (used only to fetch one probe token
# to determine which of Cognito's currently-published signing keys is
# actually in use — see the "Determine the signing kid" step in cd.yml).
# Resource "*" for the same opaque-ID reason as cognito-idp:* elsewhere in
# this file (a user pool ARN isn't scopeable to $NAME_PREFIX the way e.g.
# the ECS service ARNs above are).
#
# WafThisEnvironmentsWebAcl (below) is new for waf.tf: unlike Cognito's pool
# ID, a Web ACL's ARN embeds its *name* verbatim
# (regional/webacl/<name>/<id>), and that name is deterministic
# ("${NAME_PREFIX}-api", set in waf.tf) even though the trailing <id> isn't
# — so this scopes to "<name>/*", the same wildcard-the-opaque-suffix
# pattern AWS's own CreateWebACL access-denied errors report as the
# resource they checked against. Bundles in the web ACL's own
# Associate/DisassociateWebACL/GetWebACLForResource (the API Gateway stage
# it's associated with, api_gateway.tf, has no ARN of its own to scope a
# second permission to) and PutLoggingConfiguration/
# DeleteLoggingConfiguration/GetLoggingConfiguration for
# aws_wafv2_web_acl_logging_configuration.
#
# WafManagedRuleGroups (below) is a second, separate statement — confirmed
# against a real `apply`: CreateWebACL/UpdateWebACL check permission not
# just on the Web ACL being created but on every AWS Managed Rule Group it
# *references* (waf.tf's three `rule` blocks). The obvious move — grant the
# three specific ARNs waf.tf actually references
# (regional/managedruleset/AWS/AWSManagedRulesCommonRuleSet etc.) — does
# NOT work; confirmed against a real `apply` that still failed identically
# with those three ARNs granted. The AccessDenied error itself names the
# resource it actually checks as "regional/managedruleset/*/*" — a literal
# double wildcard, not the specific vendor/name pair for whichever rule
# group triggered it — so this action's authorization apparently doesn't
# discriminate by which managed rule group is referenced at all. This is
# the wafv2 equivalent of this file's other opaque-permission cases
# (Cognito's pool ID, ACM's certificate ID): Resource: "*" in every
# practical sense for this one statement, just narrowed to wafv2's
# managedruleset resource type rather than the whole service. Shared across
# every environment's Terraform role the same way
# route53:ChangeResourceRecordSets' hosted zone is (see below) — there's no
# `$NAME_PREFIX` in it to isolate by anyway.
CD_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "EcrPushPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": [
        "arn:aws:ecr:$AWS_REGION:$ACCOUNT_ID:repository/books-api",
        "arn:aws:ecr:$AWS_REGION:$ACCOUNT_ID:repository/kong"
      ]
    },
    {
      "Sid": "RegisterTaskDefinitions",
      "Effect": "Allow",
      "Action": ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"],
      "Resource": "*"
    },
    {
      "Sid": "CognitoReadForKongConfig",
      "Effect": "Allow",
      "Action": [
        "cognito-idp:ListUserPools",
        "cognito-idp:ListUserPoolClients",
        "cognito-idp:DescribeUserPoolClient"
      ],
      "Resource": "*"
    },
    {
      "Sid": "UpdateThisEnvironmentsService",
      "Effect": "Allow",
      "Action": ["ecs:UpdateService", "ecs:DescribeServices"],
      "Resource": [
        "arn:aws:ecs:$AWS_REGION:$ACCOUNT_ID:cluster/$NAME_PREFIX",
        "arn:aws:ecs:$AWS_REGION:$ACCOUNT_ID:service/$NAME_PREFIX/$NAME_PREFIX",
        "arn:aws:ecs:$AWS_REGION:$ACCOUNT_ID:service/$NAME_PREFIX/$NAME_PREFIX-kong"
      ]
    },
    {
      "Sid": "PassThisEnvironmentsRoles",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::$ACCOUNT_ID:role/${NAME_PREFIX}-execution",
        "arn:aws:iam::$ACCOUNT_ID:role/${NAME_PREFIX}-task"
      ]
    }
  ]
}
JSON
)

TF_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StateBackendObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::$TF_STATE_BUCKET/env:/$ENVIRONMENT/books-api.tfstate*"
    },
    {
      "Sid": "StateBackendInitBareKeyReadOnly",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$TF_STATE_BUCKET/books-api.tfstate"
    },
    {
      "Sid": "StateBackendList",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::$TF_STATE_BUCKET",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["env:/*", "books-api.tfstate"]
        }
      }
    },
    {
      "Sid": "Networking",
      "Effect": "Allow",
      "Action": "ec2:*",
      "Resource": "*"
    },
    {
      "Sid": "LoadBalancing",
      "Effect": "Allow",
      "Action": "elasticloadbalancing:*",
      "Resource": "*"
    },
    {
      "Sid": "ServiceDiscovery",
      "Effect": "Allow",
      "Action": "servicediscovery:*",
      "Resource": "*"
    },
    {
      "Sid": "EcsClusterAndService",
      "Effect": "Allow",
      "Action": [
        "ecs:CreateCluster", "ecs:DeleteCluster", "ecs:DescribeClusters",
        "ecs:PutClusterCapacityProviders", "ecs:TagResource", "ecs:UntagResource",
        "ecs:ListTagsForResource",
        "ecs:CreateService", "ecs:DeleteService", "ecs:UpdateService", "ecs:DescribeServices"
      ],
      "Resource": [
        "arn:aws:ecs:$AWS_REGION:$ACCOUNT_ID:cluster/$NAME_PREFIX",
        "arn:aws:ecs:$AWS_REGION:$ACCOUNT_ID:service/$NAME_PREFIX/$NAME_PREFIX",
        "arn:aws:ecs:$AWS_REGION:$ACCOUNT_ID:service/$NAME_PREFIX/$NAME_PREFIX-kong"
      ]
    },
    {
      "Sid": "EcsTaskDefinitions",
      "Effect": "Allow",
      "Action": [
        "ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition",
        "ecs:DescribeTaskDefinition", "ecs:ListTaskDefinitions",
        "ecs:TagResource", "ecs:UntagResource", "ecs:ListTagsForResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassThisEnvironmentsRoles",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": [
        "arn:aws:iam::$ACCOUNT_ID:role/${NAME_PREFIX}-execution",
        "arn:aws:iam::$ACCOUNT_ID:role/${NAME_PREFIX}-task"
      ]
    },
    {
      "Sid": "AcmRequestThisEnvironmentsCert",
      "Effect": "Allow",
      "Action": "acm:RequestCertificate",
      "Resource": "*",
      "Condition": { "StringEquals": { "aws:RequestTag/Environment": "$ENVIRONMENT" } }
    },
    {
      "Sid": "AcmManageThisEnvironmentsCert",
      "Effect": "Allow",
      "Action": [
        "acm:DescribeCertificate", "acm:DeleteCertificate",
        "acm:AddTagsToCertificate", "acm:ListTagsForCertificate"
      ],
      "Resource": "*",
      "Condition": { "StringEquals": { "aws:ResourceTag/Environment": "$ENVIRONMENT" } }
    },
    {
      "Sid": "Route53Read",
      "Effect": "Allow",
      "Action": [
        "route53:GetHostedZone", "route53:ListHostedZones",
        "route53:GetChange", "route53:ListResourceRecordSets",
        "route53:ListTagsForResource"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Route53WriteSharedZone",
      "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/$HOSTED_ZONE_ID"
    },
    {
      "Sid": "DynamoDbThisEnvironmentsTables",
      "Effect": "Allow",
      "Action": [
        "dynamodb:CreateTable", "dynamodb:DeleteTable", "dynamodb:DescribeTable",
        "dynamodb:UpdateTable", "dynamodb:UpdateContinuousBackups",
        "dynamodb:DescribeContinuousBackups", "dynamodb:DescribeTimeToLive",
        "dynamodb:TagResource", "dynamodb:ListTagsOfResource"
      ],
      "Resource": [
        "arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/${NAME_PREFIX}-books",
        "arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/${NAME_PREFIX}-isbns"
      ]
    },
    {
      "Sid": "LogsThisEnvironmentsGroup",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy",
        "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource",
        "logs:ListTagsLogGroup"
      ],
      "Resource": [
        "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:/ecs/${NAME_PREFIX}",
        "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:/ecs/${NAME_PREFIX}:*",
        "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:/aws/apigateway/${NAME_PREFIX}",
        "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:/aws/apigateway/${NAME_PREFIX}:*",
        "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:aws-waf-logs-${NAME_PREFIX}",
        "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:aws-waf-logs-${NAME_PREFIX}:*"
      ]
    },
    {
      "Sid": "LogsDescribe",
      "Effect": "Allow",
      "Action": "logs:DescribeLogGroups",
      "Resource": "*"
    },
    {
      "Sid": "WafThisEnvironmentsWebAcl",
      "Effect": "Allow",
      "Action": [
        "wafv2:CreateWebACL", "wafv2:DeleteWebACL", "wafv2:GetWebACL", "wafv2:UpdateWebACL",
        "wafv2:TagResource", "wafv2:UntagResource", "wafv2:ListTagsForResource",
        "wafv2:AssociateWebACL", "wafv2:DisassociateWebACL", "wafv2:GetWebACLForResource",
        "wafv2:PutLoggingConfiguration", "wafv2:DeleteLoggingConfiguration",
        "wafv2:GetLoggingConfiguration"
      ],
      "Resource": "arn:aws:wafv2:$AWS_REGION:$ACCOUNT_ID:regional/webacl/${NAME_PREFIX}-api/*"
    },
    {
      "Sid": "WafManagedRuleGroups",
      "Effect": "Allow",
      "Action": ["wafv2:CreateWebACL", "wafv2:UpdateWebACL"],
      "Resource": "arn:aws:wafv2:$AWS_REGION:$ACCOUNT_ID:regional/managedruleset/*/*"
    },
    {
      "Sid": "ApiGatewayAccessLogDelivery",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery",
        "logs:DeleteLogDelivery", "logs:ListLogDeliveries",
        "logs:PutResourcePolicy", "logs:DescribeResourcePolicies"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Cognito",
      "Effect": "Allow",
      "Action": "cognito-idp:*",
      "Resource": "*"
    },
    {
      "Sid": "ApiGateway",
      "Effect": "Allow",
      "Action": "apigateway:*",
      "Resource": "*"
    },
    {
      "Sid": "SnsThisEnvironmentsTopic",
      "Effect": "Allow",
      "Action": [
        "sns:CreateTopic", "sns:DeleteTopic", "sns:GetTopicAttributes", "sns:SetTopicAttributes",
        "sns:TagResource", "sns:UntagResource", "sns:ListTagsForResource"
      ],
      "Resource": "arn:aws:sns:$AWS_REGION:$ACCOUNT_ID:${NAME_PREFIX}-alerts"
    },
    {
      "Sid": "AlarmsThisEnvironment",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms",
        "cloudwatch:TagResource", "cloudwatch:UntagResource", "cloudwatch:ListTagsForResource"
      ],
      "Resource": "arn:aws:cloudwatch:$AWS_REGION:$ACCOUNT_ID:alarm:${NAME_PREFIX}-*"
    },
    {
      "Sid": "AlarmsDescribe",
      "Effect": "Allow",
      "Action": "cloudwatch:DescribeAlarms",
      "Resource": "*"
    },
    {
      "Sid": "DashboardThisEnvironment",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutDashboard", "cloudwatch:GetDashboard", "cloudwatch:DeleteDashboards"
      ],
      "Resource": "arn:aws:cloudwatch::$ACCOUNT_ID:dashboard/${NAME_PREFIX}*"
    },
    {
      "Sid": "DashboardList",
      "Effect": "Allow",
      "Action": "cloudwatch:ListDashboards",
      "Resource": "*"
    }
  ]
}
JSON
)

aws iam put-role-policy --role-name "$CD_ROLE_NAME" --policy-name "$CD_ROLE_NAME" --policy-document "$CD_POLICY"
aws iam put-role-policy --role-name "$TF_ROLE_NAME" --policy-name "$TF_ROLE_NAME" --policy-document "$TF_POLICY"
echo "  $CD_ROLE_NAME: scoped to the books-api ECR repo + this environment's ECS cluster/service"
echo "  $TF_ROLE_NAME: scoped to this environment's resources where the AWS API supports it (see terraform/README.md's IAM section for exactly what isn't)"
echo

if [ -f "$TF_DIR/terraform.tfvars" ]; then
  cat >&2 <<EOF

WARNING: $TF_DIR/terraform.tfvars exists. A leftover copy from before this
script supported multiple environments would still set hosted_zone_name/
domain_name — and since a tfvars file overrides TF_VAR_* environment
variables in Terraform's own precedence order, an old copy with, say,
production's domain_name would silently win over the values passed on this
run's command line, applying the WRONG domain in this ($ENVIRONMENT)
workspace. The -var flags below take precedence over it either way (-var
beats any tfvars file), so this run is safe regardless — but delete or
rename that file so nothing reads it by accident later; a single shared
file can't hold different values per environment anyway.

EOF
fi

echo "== 5. terraform apply (workspace: $ENVIRONMENT) =="
(
  cd "$TF_DIR"
  # Contains planned values in cleartext, including sensitive ones (e.g.
  # the Cognito client secret) — must not survive this subshell under ANY
  # exit path, including a failed apply. The trap covers that; the
  # explicit rm calls below are the normal-path cleanup (belt and
  # suspenders, both fine to run since rm -f is idempotent).
  trap 'rm -f .bootstrap.tfplan' EXIT

  terraform init -backend-config=backend.hcl

  # Hard stop, not just a documentation note: if the unnamed "default"
  # workspace still holds ANY resources, something here predates
  # workspaces entirely and hasn't been migrated into a real named
  # workspace yet. Proceeding anyway is exactly what caused a real
  # incident — a fresh, empty named workspace tried to build a second
  # copy of everything already live under "default", producing a mix of
  # "already exists" errors and (worse) silently-adopted real resources
  # for anything AWS treats as idempotent-by-name (ECS clusters, SNS
  # topics, CloudWatch alarms). `terraform state list` reads state only —
  # no vars needed, safe to run before anything else here.
  terraform workspace select default
  DEFAULT_WORKSPACE_RESOURCE_COUNT="$(terraform state list 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$DEFAULT_WORKSPACE_RESOURCE_COUNT" != "0" ]; then
    cat >&2 <<EOF

STOP: the "default" Terraform workspace still holds $DEFAULT_WORKSPACE_RESOURCE_COUNT
resource(s) ($(terraform state list 2>/dev/null | tr '\n' ' ')).

This means something was applied here before this repo used named
workspaces, and it has NOT been migrated into a "production" workspace
yet. Bootstrapping ANY environment now would try to build a second copy
of whatever's in "default", alongside it in the same account — that is
exactly what caused a real production incident earlier; see the git
history / your own terminal scrollback for what that looked like to
clean up.

Migrate "default" into a properly-named workspace FIRST — see
docs/RUNBOOK.md's "Environments" section, "Migrating an existing
production to a named workspace" for the exact steps (back up state,
terraform workspace new production, state push, and — critically —
confirm an EMPTY terraform plan before trusting it). Re-run this script
only after that migration's final plan comes back with no unexpected
changes.
EOF
    exit 1
  fi

  terraform workspace select -or-create "$ENVIRONMENT"
  # -var, not TF_VAR_* env vars — -var has the HIGHEST precedence in
  # Terraform (beats any terraform.tfvars/*.auto.tfvars file, which in turn
  # beats TF_VAR_* env vars), so this can't be silently shadowed by a
  # leftover tfvars file the way an env-var-only approach was.
  terraform plan \
    -var "hosted_zone_name=$HOSTED_ZONE_NAME" \
    -var "domain_name=$DOMAIN_NAME" \
    -out=.bootstrap.tfplan
  if [ "${AUTO_APPROVE:-}" = "1" ]; then
    terraform apply .bootstrap.tfplan
  else
    printf '\nApply the plan above? [y/N] '
    read -r REPLY
    case "$REPLY" in
      y|Y) terraform apply .bootstrap.tfplan ;;
      *) echo "Aborted before apply. Nothing past this point has run."; rm -f .bootstrap.tfplan; exit 1 ;;
    esac
  fi
  rm -f .bootstrap.tfplan
)
echo

echo "== 6. GitHub Environment '$ENVIRONMENT' secrets/variables =="

SUBNETS="$(cd "$TF_DIR" && terraform output -json private_subnet_ids | python3 -c 'import sys,json; print(",".join(json.load(sys.stdin)))')"
SG="$(cd "$TF_DIR" && terraform output -raw ecs_security_group_id)"
COGNITO_CLIENT_ID_OUT="$(cd "$TF_DIR" && terraform output -json cognito_client_ids | python3 -c 'import sys,json; print(json.load(sys.stdin)["default"])')"
COGNITO_CLIENT_SECRET_OUT="$(cd "$TF_DIR" && terraform output -json cognito_client_secrets | python3 -c 'import sys,json; print(json.load(sys.stdin)["default"])')"
COGNITO_DOMAIN_OUT="$(cd "$TF_DIR" && terraform output -raw cognito_domain)"

gh secret set AWS_DEPLOY_ROLE_ARN --env "$ENVIRONMENT" --repo "$REPO_NWO" --body "$CD_ROLE_ARN"
gh secret set TF_DEPLOY_ROLE_ARN --env "$ENVIRONMENT" --repo "$REPO_NWO" --body "$TF_ROLE_ARN"
gh secret set COGNITO_CLIENT_SECRET --env "$ENVIRONMENT" --repo "$REPO_NWO" --body "$COGNITO_CLIENT_SECRET_OUT"
gh variable set DOMAIN_NAME --env "$ENVIRONMENT" --repo "$REPO_NWO" --body "$DOMAIN_NAME"
gh variable set HOSTED_ZONE_NAME --env "$ENVIRONMENT" --repo "$REPO_NWO" --body "$HOSTED_ZONE_NAME"
gh variable set TF_STATE_BUCKET --env "$ENVIRONMENT" --repo "$REPO_NWO" --body "$TF_STATE_BUCKET"
gh variable set ECS_SUBNETS --env "$ENVIRONMENT" --repo "$REPO_NWO" --body "$SUBNETS"
gh variable set ECS_SECURITY_GROUPS --env "$ENVIRONMENT" --repo "$REPO_NWO" --body "$SG"
gh variable set COGNITO_CLIENT_ID --env "$ENVIRONMENT" --repo "$REPO_NWO" --body "$COGNITO_CLIENT_ID_OUT"
gh variable set COGNITO_DOMAIN --env "$ENVIRONMENT" --repo "$REPO_NWO" --body "$COGNITO_DOMAIN_OUT"
# No COGNITO_USER_POOL_ID here (there used to be one) — cd.yml's
# build-and-push-kong job self-discovers the pool via
# cognito-idp:ListUserPools instead of reading a GitHub variable, precisely
# so a release doesn't depend on this script's interactive local flow
# having succeeded first. See scripts/bootstrap.sh's CognitoReadForKongConfig
# comment for the full reasoning. `terraform output -raw
# cognito_user_pool_id` still works for a human who wants it directly.

echo "Set: AWS_DEPLOY_ROLE_ARN, TF_DEPLOY_ROLE_ARN, COGNITO_CLIENT_SECRET (secrets),"
echo "DOMAIN_NAME, HOSTED_ZONE_NAME, TF_STATE_BUCKET, ECS_SUBNETS,"
echo "ECS_SECURITY_GROUPS, COGNITO_CLIENT_ID, COGNITO_DOMAIN (variables) in the"
echo "GitHub Environment '$ENVIRONMENT' (created automatically if it didn't"
echo "already exist). COGNITO_CLIENT_ID/COGNITO_DOMAIN feed"
echo ".github/workflows/performance.yml (k6) — see performance/README.md."
echo "(cd.yml's build-and-push-kong job needs none of these — it self-discovers"
echo "everything it needs from Cognito directly at deploy time.)"
echo
echo "Note: ECS_SUBNETS/ECS_SECURITY_GROUPS aren't actually read by any"
echo "current workflow — they were for cd.yml's old migration-task network"
echo "config, removed when DynamoDB replaced Postgres (nothing left to"
echo "migrate). Set anyway since they're harmless and something might use"
echo "them again; see git history on ecs/README.md for the removal."
echo

cat <<EOF
== Done ($ENVIRONMENT) ==

Consider adding required reviewers to the "$ENVIRONMENT" GitHub Environment
in repo settings — that's what actually gates workflow_dispatch applies
(and, incidentally, PR-triggered plans, since they share that job's
environment key) behind approval. Not set up by this script; a deliberate
choice to make, not a default to assume. Production almost certainly wants
this; staging may not.

$(if [ "$ENVIRONMENT" = "production" ]; then
  echo "Next: DOMAIN_NAME=staging.$DOMAIN_NAME ENVIRONMENT=staging \\"
  echo "        HOSTED_ZONE_NAME=$HOSTED_ZONE_NAME ./scripts/bootstrap.sh   # set up staging too"
fi)
Next: uv run python scripts/seed.py   # load the mock catalogue (targets whichever environment DYNAMODB_*_TABLE/AWS creds point at)
      git push                        # first real CD deploy (push to main -> staging, tag v* -> production)
EOF
