#!/usr/bin/env bash
# One-time AWS prerequisites for books-api: the ECR repo and the ECS
# execution/task IAM roles — everything ecs/task-definition.json and
# terraform/ assume already exists, but that nothing in this repo creates.
# Safe to re-run: every step checks before creating, and the two AWS-side
# updates (attach-role-policy, put-role-policy) are themselves idempotent.
#
# Usage: ./ecs/bootstrap.sh
#
# Does NOT create the DynamoDB tables — terraform/ owns those; this script
# only grants books-api-task the permissions to use them once they exist,
# scoped to their ARNs by name (same names terraform/ creates, so run
# terraform apply either before or after this — order doesn't matter here).

set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Account: $ACCOUNT_ID   Region: $AWS_REGION"
echo

# --- ECR ---------------------------------------------------------------
if aws ecr describe-repositories --repository-names books-api --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "ECR repo books-api already exists"
else
  aws ecr create-repository --repository-name books-api --region "$AWS_REGION" >/dev/null
  echo "Created ECR repo books-api"
fi

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

create_role_if_missing books-api-execution
aws iam attach-role-policy --role-name books-api-execution \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# AmazonECSTaskExecutionRolePolicy covers logs:CreateLogStream/PutLogEvents
# but deliberately not logs:CreateLogGroup — task-definition.json sets
# "awslogs-create-group": "true" for both containers, which needs it granted
# explicitly, scoped to the one log group both containers share.
LOGS_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "logs:CreateLogGroup",
    "Resource": "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:/ecs/books-api:*"
  }]
}
EOF
)
aws iam put-role-policy --role-name books-api-execution \
  --policy-name books-api-log-group --policy-document "$LOGS_POLICY"
echo "  books-api-execution: AmazonECSTaskExecutionRolePolicy + logs:CreateLogGroup on /ecs/books-api"

# --- IAM: task role (what the app/sidecar containers can call at runtime) --
create_role_if_missing books-api-task
aws iam attach-role-policy --role-name books-api-task \
  --policy-arn arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess
aws iam attach-role-policy --role-name books-api-task \
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
      "arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/books-api-books",
      "arn:aws:dynamodb:$AWS_REGION:$ACCOUNT_ID:table/books-api-isbns"
    ]
  }]
}
EOF
)
aws iam put-role-policy --role-name books-api-task \
  --policy-name books-api-dynamodb --policy-document "$DYNAMODB_POLICY"
echo "  books-api-task: AWSXRayDaemonWriteAccess + CloudWatchAgentServerPolicy + DynamoDB access on both tables"
echo

# --- Patch the placeholder account id in task-definition.json -------------
TASK_DEF="$SCRIPT_DIR/task-definition.json"
if grep -q '000000000000' "$TASK_DEF"; then
  sed -i.bak "s/000000000000/$ACCOUNT_ID/g" "$TASK_DEF" && rm -f "$TASK_DEF.bak"
  echo "Patched $(basename "$TASK_DEF") with account $ACCOUNT_ID"
else
  echo "$(basename "$TASK_DEF") has no placeholder account id left — left untouched"
fi

echo
echo "Done. Next: terraform apply (in terraform/) to create the DynamoDB tables and the rest of the service's infra, then push to main so CD builds and deploys the real image."
