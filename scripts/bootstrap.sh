#!/usr/bin/env bash
# One-command setup for a brand-new deployment of books-api: the Terraform
# state bucket, ECR + the ECS execution/task IAM roles (via ecs/bootstrap.sh),
# a GitHub OIDC provider + two deploy roles, `terraform apply`, and every
# GitHub Environment secret/variable CD and the Terraform CI workflow need
# (AWS_DEPLOY_ROLE_ARN, TF_DEPLOY_ROLE_ARN, DOMAIN_NAME, HOSTED_ZONE_NAME,
# TF_STATE_BUCKET, ECS_SUBNETS, ECS_SECURITY_GROUPS — all in the "production"
# GitHub Environment). Run this once, right after cloning this template into
# a new repo. Safe to re-run: every step checks before creating/overwriting.
#
# Does NOT create your domain or Route 53 hosted zone — bring your own,
# already delegated (see terraform/variables.tf's hosted_zone_name
# description for why this repo never owns it). scripts/teardown.sh's
# reverse of this never touches it either.
#
# Usage:
#   HOSTED_ZONE_NAME=example.com DOMAIN_NAME=books-api.example.com ./scripts/bootstrap.sh
#
#   Optional: AWS_REGION (default us-east-1), TF_STATE_BUCKET (default
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
echo "Account: $ACCOUNT_ID   Region: $AWS_REGION"

if ! aws route53 list-hosted-zones-by-name --dns-name "$HOSTED_ZONE_NAME" \
     --query "HostedZones[?Name=='${HOSTED_ZONE_NAME}.']" --output text | grep -q .; then
  echo "No Route 53 hosted zone found for $HOSTED_ZONE_NAME." >&2
  echo "This script doesn't create one — create/delegate it first, then re-run." >&2
  exit 1
fi

REPO_NWO="${GITHUB_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
: "${REPO_NWO:?Could not determine the GitHub repo. Run this from inside a clone with gh authenticated, or set GITHUB_REPO=owner/repo}"
echo "GitHub repo: $REPO_NWO"

TF_STATE_BUCKET="${TF_STATE_BUCKET:-books-api-tfstate-$ACCOUNT_ID}"
echo "State bucket: $TF_STATE_BUCKET"
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

echo "== 2. Local Terraform config files =="

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

if [ -f "$TF_DIR/terraform.tfvars" ]; then
  echo "terraform/terraform.tfvars already exists — leaving it alone"
else
  cat > "$TF_DIR/terraform.tfvars" <<EOF
aws_region = "$AWS_REGION"

hosted_zone_name = "$HOSTED_ZONE_NAME"
domain_name      = "$DOMAIN_NAME"
EOF
  echo "Wrote terraform/terraform.tfvars"
fi
echo

echo "== 3. ECR repo + ECS execution/task IAM roles =="
echo "(must exist before terraform apply — the task definition it creates"
echo "references these roles by ARN)"
(cd "$REPO_ROOT" && AWS_REGION="$AWS_REGION" ./ecs/bootstrap.sh)
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
# deploy, terraform.yml's terraform job) is `environment: production` —
# that alone fixes the OIDC token's `sub` claim to this one form,
# regardless of whether the run was a push, a PR, or workflow_dispatch (see
# git history on this file — found out the hard way that "environment:"
# overrides the usual ref/pull_request-shaped sub entirely). The owner/repo
# each get a `*` wildcard because GitHub embeds their immutable numeric IDs
# in the real claim (repo:owner@id/name@id:...), not just the plain names.
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
      "StringLike": { "token.actions.githubusercontent.com:sub": "repo:${OWNER}@*/${REPO}@*:environment:production" }
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
  # AdministratorAccess for simplicity, same tradeoff already made for the
  # ECS roles and local terraform-apply credentials — see ecs/README.md and
  # terraform/README.md's IAM sections for the actual minimal permission
  # sets if you want to tighten these later.
  aws iam attach-role-policy --role-name "$role_name" --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
}

create_or_update_role books-api-cd
create_or_update_role books-api-terraform

CD_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/books-api-cd"
TF_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/books-api-terraform"
echo

echo "== 5. terraform apply =="
(
  cd "$TF_DIR"
  terraform init -backend-config=backend.hcl
  terraform plan -var-file=terraform.tfvars -out=.bootstrap.tfplan
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

echo "== 6. GitHub Environment 'production' secrets/variables =="

SUBNETS="$(cd "$TF_DIR" && terraform output -json private_subnet_ids | python3 -c 'import sys,json; print(",".join(json.load(sys.stdin)))')"
SG="$(cd "$TF_DIR" && terraform output -raw ecs_security_group_id)"

gh secret set AWS_DEPLOY_ROLE_ARN --env production --repo "$REPO_NWO" --body "$CD_ROLE_ARN"
gh secret set TF_DEPLOY_ROLE_ARN --env production --repo "$REPO_NWO" --body "$TF_ROLE_ARN"
gh variable set DOMAIN_NAME --env production --repo "$REPO_NWO" --body "$DOMAIN_NAME"
gh variable set HOSTED_ZONE_NAME --env production --repo "$REPO_NWO" --body "$HOSTED_ZONE_NAME"
gh variable set TF_STATE_BUCKET --env production --repo "$REPO_NWO" --body "$TF_STATE_BUCKET"
gh variable set ECS_SUBNETS --env production --repo "$REPO_NWO" --body "$SUBNETS"
gh variable set ECS_SECURITY_GROUPS --env production --repo "$REPO_NWO" --body "$SG"

echo "Set: AWS_DEPLOY_ROLE_ARN, TF_DEPLOY_ROLE_ARN (secrets), DOMAIN_NAME,"
echo "HOSTED_ZONE_NAME, TF_STATE_BUCKET, ECS_SUBNETS, ECS_SECURITY_GROUPS (variables)"
echo
echo "Note: ECS_SUBNETS/ECS_SECURITY_GROUPS aren't actually read by any"
echo "current workflow — they were for cd.yml's old migration-task network"
echo "config, removed when DynamoDB replaced Postgres (nothing left to"
echo "migrate). Set anyway since they're harmless and something might use"
echo "them again; see git history on ecs/README.md for the removal."
echo

cat <<EOF
== Done ==

Consider adding required reviewers to the "production" GitHub Environment
in repo settings — that's what actually gates workflow_dispatch applies
(and, incidentally, PR-triggered plans, since they share that job's
environment key) behind approval. Not set up by this script; a deliberate
choice to make, not a default to assume.

Next: uv run python scripts/seed.py   # load the mock catalogue
      git push                        # first real CD deploy
EOF
