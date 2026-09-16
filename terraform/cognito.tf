# Machine-to-machine auth only — no hosted sign-up/login UI, no human users.
# A caller does the OAuth2 client-credentials grant against the domain below
# to get a bearer token, then calls the API through API Gateway with it:
#
#   curl -s -u "$CLIENT_ID:$CLIENT_SECRET" \
#     -d grant_type=client_credentials -d scope=books-api/read \
#     "https://$(terraform output -raw cognito_domain).auth.us-east-1.amazoncognito.com/oauth2/token"
#
# See terraform/README.md for the full flow, including where each of these
# three values comes from.

data "aws_caller_identity" "current" {}

resource "aws_cognito_user_pool" "this" {
  name = local.name_prefix
}

# A Cognito domain is what actually serves the OAuth2 endpoints
# (/oauth2/token etc.) — the user pool alone has no reachable URL. The
# prefix must be globally unique across every AWS account using Cognito's
# shared *.auth.<region>.amazoncognito.com namespace; account id + name
# (which already differs per environment) makes that trivially true without
# needing a user-supplied name.
resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${local.name_prefix}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.this.id
}

# Defines the custom scopes (books-api/read, books-api/write) that get
# embedded in issued tokens — Cognito requires a resource server before an
# app client can request custom (non-OpenID) scopes. Identifier stays
# "books-api" literally in every environment, not name_prefix — it only
# needs to be unique *within* a user pool, and staging/production already
# have entirely separate pools, so there's no collision to avoid. Keeping it
# constant also means scripts/get-token.sh's scope strings work unchanged
# regardless of which environment's tokens you're fetching.
resource "aws_cognito_resource_server" "this" {
  identifier   = "books-api"
  name         = "books-api"
  user_pool_id = aws_cognito_user_pool.this.id

  scope {
    scope_name        = "read"
    scope_description = "Read book data"
  }

  scope {
    scope_name        = "write"
    scope_description = "Create, update, or delete book data"
  }
}

# The one app client every caller shares — generate_secret = true is what
# makes this a confidential client, required for the client-credentials
# grant (there's no browser/redirect involved to justify a public client).
resource "aws_cognito_user_pool_client" "this" {
  name         = "${local.name_prefix}-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_scopes = [
    "${aws_cognito_resource_server.this.identifier}/read",
    "${aws_cognito_resource_server.this.identifier}/write",
  ]
  supported_identity_providers = ["COGNITO"]
}
