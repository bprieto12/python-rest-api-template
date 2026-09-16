#!/usr/bin/env bash
# Fetches a Cognito client-credentials access token for books-api and prints
# *only the token* to stdout — everything else goes to stderr, so this is
# safe to use directly wherever a bearer token is needed:
#
#   curl -H "Authorization: Bearer $(scripts/get-token.sh)" https://books-api.spixionic.com/api/v1/books
#
# Usage:
#   scripts/get-token.sh [scope ...]   # default: books-api/read books-api/write
#
# Reads client id/secret/domain from `terraform output` in ../terraform by
# default — needs local Terraform state, i.e. someone's already applied it.
# There's one client per consumer (terraform/cognito.tf's var.api_consumers);
# CONSUMER picks which one (default: "default", today's one real caller).
# Override CONSUMER, or skip Terraform entirely with COGNITO_CLIENT_ID /
# COGNITO_CLIENT_SECRET / COGNITO_DOMAIN env vars (e.g. CI, or a teammate's
# machine without local state).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
SCOPE="${*:-books-api/read books-api/write}"
CONSUMER="${CONSUMER:-default}"

tf_output() {
  terraform -chdir="$SCRIPT_DIR/../terraform" output -raw "$1"
}

tf_output_json_field() {
  terraform -chdir="$SCRIPT_DIR/../terraform" output -json "$1" \
    | python3 -c "import sys, json; print(json.load(sys.stdin)['$CONSUMER'])"
}

CLIENT_ID="${COGNITO_CLIENT_ID:-$(tf_output_json_field cognito_client_ids)}"
CLIENT_SECRET="${COGNITO_CLIENT_SECRET:-$(tf_output_json_field cognito_client_secrets)}"
DOMAIN="${COGNITO_DOMAIN:-$(tf_output cognito_domain)}"

echo "Requesting token (scope: $SCOPE)..." >&2

RESPONSE="$(curl -sS -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d grant_type=client_credentials \
  -d "scope=$SCOPE" \
  "https://$DOMAIN.auth.$AWS_REGION.amazoncognito.com/oauth2/token")"

TOKEN="$(python3 -c 'import sys, json; print(json.load(sys.stdin)["access_token"])' <<<"$RESPONSE" 2>/dev/null || true)"

if [ -z "$TOKEN" ]; then
  echo "Failed to get a token. Response from Cognito:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

echo "$TOKEN"
