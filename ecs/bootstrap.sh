#!/usr/bin/env bash
# One-time AWS prerequisites for books-api: the ECR repo (shared across
# environments — one image, built once, promoted between them) and the ECS
# execution/task IAM roles for the given environment — everything
# ecs/task-definition.<environment>.json and terraform/ assume already
# exist, but that nothing in this repo creates. Safe to re-run: every step
# checks before creating, and the two AWS-side updates (attach-role-policy,
# put-role-policy) are themselves idempotent.
#
# Run once per environment:
#   ENVIRONMENT=production ./ecs/bootstrap.sh   # default if unset
#   ENVIRONMENT=staging ./ecs/bootstrap.sh
#
# "production" keeps every name exactly as it was before other environments
# existed here (no suffix) — see terraform/environment.tf for why. Anything
# else gets "-<environment>" appended.
#
# Does NOT create the DynamoDB tables — terraform/ owns those; this script
# only grants the task role permissions to use them once they exist, scoped
# to their ARNs by name (same names terraform/ creates, so run terraform
# apply either before or after this — order doesn't matter here).

set -euo pipefail

ENVIRONMENT="${ENVIRONMENT:-production}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$ENVIRONMENT" = "production" ]; then
  NAME_PREFIX="books-api"
else
  NAME_PREFIX="books-api-$ENVIRONMENT"
fi

echo "Account: $ACCOUNT_ID   Region: $AWS_REGION   Environment: $ENVIRONMENT"
echo

# --- ECR -----------------------------------------------------------------
# Deliberately not environment-scoped — one repo, one image per commit SHA,
# the same artifact promoted from staging to production rather than
# rebuilt for each. See docs/RUNBOOK.md's "Environments" section. Same
# reasoning applies to the "kong" repo (terraform/kong.tf, cd.yml's
# build-and-push-kong job) — a second, independently-versioned image, not
# environment-scoped either.
for repo in books-api kong; do
  if aws ecr describe-repositories --repository-names "$repo" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "ECR repo $repo already exists"
  else
    aws ecr create-repository --repository-name "$repo" --region "$AWS_REGION" >/dev/null
    echo "Created ECR repo $repo"
  fi
done

# --- IAM: execution role (pull image, write logs) --------------------------
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ecs-tasks.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

create_role_if_missing() {
  local role_name="$1"
  if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    echo "IAM role $role_name already exists"
  else
    aws iam create-role --role-name "$role_name" \
      --assume-role-policy-document "$TRUST_POLICY" >/dev/null
    echo "Created IAM role $role_name"
  fi
}

EXECUTION_ROLE="${NAME_PREFIX}-execution"
TASK_ROLE="${NAME_PREFIX}-task"

create_role_if_missing "$EXECUTION_ROLE"
aws iam attach-role-policy --role-name "$EXECUTION_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# AmazonECSTaskExecutionRolePolicy covers logs:CreateLogStream/PutLogEvents
# but deliberately not logs:CreateLogGroup — task-definition.<environment>.json
# sets "awslogs-create-group": "true" for both containers, which needs it
# granted explicitly, scoped to the one log group both containers share.
LOGS_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "logs:CreateLogGroup",
    "Resource": "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:/ecs/${NAME_PREFIX}:*"
  }]
}
EOF
)
aws iam put-role-policy --role-name "$EXECUTION_ROLE" \
  --policy-name "${NAME_PREFIX}-log-group" --policy-document "$LOGS_POLICY"
echo "  $EXECUTION_ROLE: AmazonECSTaskExecutionRolePolicy + logs:CreateLogGroup on /ecs/$NAME_PREFIX"

# --- IAM: task role (what the app/sidecar containers can call at runtime) --
create_role_if_missing "$TASK_ROLE"
aws iam attach-role-policy --role-name "$TASK_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess
aws iam attach-role-policy --role-name "$TASK_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy

DYNAMODB_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Scan",
      "dynamodb:Query",
      "dynamodb:DescribeTable"
    ],
    "Resource": [
      "arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/${NAME_PREFIX}-books",
      "arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/${NAME_PREFIX}-isbns"
    ]
  }]
}
EOF
)
aws iam put-role-policy --role-name "$TASK_ROLE" \
  --policy-name "${NAME_PREFIX}-dynamodb" --policy-document "$DYNAMODB_POLICY"
echo "  $TASK_ROLE: AWSXRayDaemonWriteAccess + CloudWatchAgentServerPolicy + DynamoDB access on both tables"
echo

# --- Patch the placeholder account id in this environment's task defs -----
# Kong reuses books-api's execution role (it needs no DynamoDB/task-role
# permissions of its own — see ecs/task-definition.kong.<environment>.json),
# so it gets the same placeholder-patch treatment, not a separate role.
for TASK_DEF in "$SCRIPT_DIR/task-definition.${ENVIRONMENT}.json" "$SCRIPT_DIR/task-definition.kong.${ENVIRONMENT}.json"; do
  if [ ! -f "$TASK_DEF" ]; then
    echo "No $(basename "$TASK_DEF") — is ENVIRONMENT ($ENVIRONMENT) spelled right?" >&2
    exit 1
  fi
  if grep -q '000000000000' "$TASK_DEF"; then
    sed -i.bak "s/000000000000/$ACCOUNT_ID/g" "$TASK_DEF" && rm -f "$TASK_DEF.bak"
    echo "Patched $(basename "$TASK_DEF") with account $ACCOUNT_ID"
  else
    echo "$(basename "$TASK_DEF") has no placeholder account id left — left untouched"
  fi
done

echo
echo "Done. Next: terraform apply (in terraform/, workspace $ENVIRONMENT) to create the DynamoDB tables and the rest of this environment's infra."
