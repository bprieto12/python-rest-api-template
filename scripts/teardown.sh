#!/usr/bin/env bash
# Tears down everything scripts/bootstrap.sh built, in reverse: terraform
# destroy first (while the roles it needs still exist), then the ECR repo,
# the four IAM roles, the state bucket, and the GitHub Environment
# secrets/variables bootstrap.sh set.
#
# Does NOT touch your Route 53 hosted zone or domain — safe by construction,
# not just by care: hosted_zone_name is read via a `data` source
# (terraform/route53.tf), never a `resource`, so terraform destroy has
# nothing there to even attempt deleting.
#
# Does NOT delete the GitHub OIDC provider
# (token.actions.githubusercontent.com) — it's account-wide, shared by
# anything else that might use GitHub Actions OIDC in this account, not
# specific to this one service.
#
# Usage:
#   ./scripts/teardown.sh                  # asks for confirmation first
#   AUTO_APPROVE=1 ./scripts/teardown.sh    # no prompts (CI, etc.)
#
#   Optional: AWS_REGION (default us-east-1), TF_STATE_BUCKET (default
#   books-api-tfstate-<account-id> — override to match what bootstrap.sh
#   actually used if you set one explicitly then), GITHUB_REPO (owner/repo
#   — default: read from `gh repo view`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
AWS_REGION="${AWS_REGION:-us-east-1}"

for cmd in aws terraform gh python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required tool: $cmd" >&2; exit 1; }
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REPO_NWO="${GITHUB_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-books-api-tfstate-$ACCOUNT_ID}"

cat <<EOF
This will DESTROY every AWS resource scripts/bootstrap.sh created for
books-api in account $ACCOUNT_ID:
  - VPC, ALB, ECS cluster/service
  - Both DynamoDB tables, and everything in them
  - Cognito (user pool, app client) and API Gateway
  - The SNS alerts topic and its CloudWatch Alarms (any email/webhook you
    subscribed to it is dropped along with the topic — re-subscribe if you
    bootstrap this again)
  - The ECR repo books-api, and any images in it
  - The state bucket ($TF_STATE_BUCKET)
  - 4 IAM roles (books-api-execution, books-api-task, books-api-cd, books-api-terraform)
  - The GitHub Environment "production" secrets/variables bootstrap.sh set

Your Route 53 hosted zone/domain is NOT touched — it was never Terraform-
managed to begin with (see terraform/route53.tf). The GitHub OIDC provider
is also left alone, since other things in this account may depend on it.

EOF

if [ "${AUTO_APPROVE:-}" != "1" ]; then
  printf 'Type the AWS account id (%s) to confirm: ' "$ACCOUNT_ID"
  read -r CONFIRM
  [ "$CONFIRM" = "$ACCOUNT_ID" ] || { echo "Aborted."; exit 1; }
fi
echo

echo "== 1. terraform destroy =="

if [ -f "$TF_DIR/backend.hcl" ]; then
  (
    cd "$TF_DIR"
    [ -d .terraform ] || terraform init -backend-config=backend.hcl
    if [ "${AUTO_APPROVE:-}" = "1" ]; then
      terraform destroy -var-file=terraform.tfvars -auto-approve
    else
      terraform destroy -var-file=terraform.tfvars
    fi
  )
else
  echo "No terraform/backend.hcl — nothing to destroy via Terraform (either" >&2
  echo "already torn down, or this environment was never applied here)." >&2
fi
echo

echo "== 2. ECR repo =="

if aws ecr describe-repositories --repository-names books-api --region "$AWS_REGION" >/dev/null 2>&1; then
  aws ecr delete-repository --repository-name books-api --region "$AWS_REGION" --force >/dev/null
  echo "Deleted (including any images in it)"
else
  echo "Doesn't exist — skipping"
fi
echo

echo "== 3. IAM roles =="

delete_role() {
  local role_name="$1"
  if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    echo "$role_name: doesn't exist — skipping"
    return
  fi
  for policy_arn in $(aws iam list-attached-role-policies --role-name "$role_name" \
      --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$role_name" --policy-arn "$policy_arn"
  done
  for policy_name in $(aws iam list-role-policies --role-name "$role_name" \
      --query 'PolicyNames' --output text); do
    aws iam delete-role-policy --role-name "$role_name" --policy-name "$policy_name"
  done
  aws iam delete-role --role-name "$role_name"
  echo "$role_name: deleted"
}

for role in books-api-execution books-api-task books-api-cd books-api-terraform; do
  delete_role "$role"
done
echo

echo "== 4. Terraform state bucket =="

if aws s3api head-bucket --bucket "$TF_STATE_BUCKET" 2>/dev/null; then
  # Versioned bucket — deleting the bucket needs every version AND every
  # delete marker gone first, not just the current versions (plain
  # `s3 rm --recursive` only adds delete markers, it doesn't remove what's
  # underneath them). Fine to do this in one batch each for a bucket this
  # small; a state bucket with >1000 historical objects would need paging
  # (AWS's delete-objects limit), which nothing here does.
  VERSIONS_FILE="$(mktemp)"
  MARKERS_FILE="$(mktemp)"
  trap 'rm -f "$VERSIONS_FILE" "$MARKERS_FILE"' EXIT

  aws s3api list-object-versions --bucket "$TF_STATE_BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json > "$VERSIONS_FILE"
  if [ "$(python3 -c "import json; print(len(json.load(open('$VERSIONS_FILE'))['Objects'] or []))")" != "0" ]; then
    aws s3api delete-objects --bucket "$TF_STATE_BUCKET" --delete "file://$VERSIONS_FILE" >/dev/null
  fi

  aws s3api list-object-versions --bucket "$TF_STATE_BUCKET" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json > "$MARKERS_FILE"
  if [ "$(python3 -c "import json; print(len(json.load(open('$MARKERS_FILE'))['Objects'] or []))")" != "0" ]; then
    aws s3api delete-objects --bucket "$TF_STATE_BUCKET" --delete "file://$MARKERS_FILE" >/dev/null
  fi

  aws s3api delete-bucket --bucket "$TF_STATE_BUCKET" --region "$AWS_REGION"
  echo "Deleted $TF_STATE_BUCKET"
else
  echo "$TF_STATE_BUCKET doesn't exist — skipping"
fi
echo

echo "== 5. GitHub Environment 'production' secrets/variables =="

if [ -n "$REPO_NWO" ]; then
  for s in AWS_DEPLOY_ROLE_ARN TF_DEPLOY_ROLE_ARN; do
    gh secret delete "$s" --env production --repo "$REPO_NWO" 2>/dev/null \
      && echo "$s: deleted" || echo "$s: already gone"
  done
  for v in DOMAIN_NAME HOSTED_ZONE_NAME TF_STATE_BUCKET ECS_SUBNETS ECS_SECURITY_GROUPS; do
    gh variable delete "$v" --env production --repo "$REPO_NWO" 2>/dev/null \
      && echo "$v: deleted" || echo "$v: already gone"
  done
else
  echo "Couldn't determine the GitHub repo — skipping. Remove these by hand," >&2
  echo "or re-run with GITHUB_REPO=owner/repo set." >&2
fi
echo

echo "== Done =="
echo "Route 53 (hosted zone/domain) and the GitHub OIDC provider were left"
echo "untouched, as documented at the top of this script."
