#!/usr/bin/env bash
# One-time AWS prerequisites for books-api: the ECR repo, the ECS
# execution/task IAM roles, and the DATABASE_URL secret — everything
# ecs/task-definition.json and terraform/ assume already exists, but that
# nothing in this repo creates. Safe to re-run: every step checks before
# creating, and the two AWS-side updates (attach-role-policy, put-role-policy)
# are themselves idempotent.
#
# Usage:
#   DATABASE_URL='postgresql+asyncpg://user:pass@host:5432/books' ./ecs/bootstrap.sh
#
# Does NOT create a database — DATABASE_URL has to point at a real Postgres
# instance you've already stood up (this repo's Terraform doesn't provision
# one; docker-compose's Postgres is local-dev only, and "localhost" from
# inside an ECS task means that task's own network namespace, never your
# machine). If DATABASE_URL is unset, the secret is created with an obvious
# placeholder instead of failing outright — everything else (ECR, IAM roles)
# still gets created, but the deployed service's DB-backed calls will fail
# until you rotate it:
#   aws secretsmanager put-secret-value --secret-id books-api/database-url --secret-string '...'

set -euo pipefail

if [ -z "${DATABASE_URL:-}" ]; then
  echo "WARNING: DATABASE_URL not set — creating the secret with a placeholder value."
  echo "  The deployed service's DB-backed endpoints will fail until you rotate it"
  echo "  (see this script's header for the command)."
  echo
  DATABASE_URL="postgresql+asyncpg://REPLACE-ME:REPLACE-ME@REPLACE-ME:5432/REPLACE-ME"
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
SECRET_NAME="books-api/database-url"
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

# --- Secrets Manager -------------------------------------------------------
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists — not overwriting (use"
  echo "  aws secretsmanager put-secret-value --secret-id $SECRET_NAME --secret-string '...'"
  echo "  to rotate it)"
else
  aws secretsmanager create-secret --name "$SECRET_NAME" \
    --secret-string "$DATABASE_URL" --region "$AWS_REGION" >/dev/null
  echo "Created secret $SECRET_NAME"
fi
SECRET_ARN="$(aws secretsmanager describe-secret --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" --query ARN --output text)"

# --- IAM: execution role (pull image, write logs, read the secret) ---------
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

aws iam put-role-policy --role-name books-api-execution \
  --policy-name books-api-database-url \
  --policy-document "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "secretsmanager:GetSecretValue",
    "Resource": "$SECRET_ARN"
  }]
}
EOF
)"
echo "  books-api-execution: AmazonECSTaskExecutionRolePolicy + read access to $SECRET_NAME"

# --- IAM: task role (what the app/sidecar containers can call at runtime) --
create_role_if_missing books-api-task
aws iam attach-role-policy --role-name books-api-task \
  --policy-arn arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess
aws iam attach-role-policy --role-name books-api-task \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
echo "  books-api-task: AWSXRayDaemonWriteAccess + CloudWatchAgentServerPolicy"
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
echo "Done. Next: terraform apply (in terraform/), then push to main so CD builds and deploys the real image."
