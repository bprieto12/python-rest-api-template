# The public entry point — everything else (ALB, ECS) is private and
# reachable only from here, via the VPC Link below. Every request needs a
# valid Cognito-issued JWT except the two explicit carve-outs below (the
# docs UI and the schema it fetches — see aws_apigatewayv2_route.docs) —
# health checks bypass this whole path entirely regardless (the ALB target
# group's own health check polls the ECS tasks directly, not through the
# gateway), so they were never part of this in the first place.

resource "aws_apigatewayv2_api" "this" {
  name          = local.name_prefix
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = local.name_prefix
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = aws_subnet.private[*].id
}

# JWT authorizers validate the `aud` claim against `audience` — but Cognito
# client-credentials access tokens don't carry an `aud` claim at all (only
# ID tokens do). API Gateway specifically falls back to checking `client_id`
# against `audience` when `aud` is absent, which is exactly the case here —
# documented Cognito/API Gateway integration behavior, not a workaround.
#
# `audience` lists every consumer's client id (cognito.tf's for_each over
# var.api_consumers) — this authorizer only proves a token is valid for
# *some* known consumer, same as before there was more than one client. It
# doesn't (and can't) tell them apart; that's Kong's job, downstream.
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.this.id
  name             = "cognito-client-credentials"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [for c in aws_cognito_user_pool_client.consumers : c.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
  }
}

# HTTP_PROXY + VPC_LINK forwards the request essentially as-is (method,
# path, headers, body) to the ALB's listener — the integration_uri for a
# private ALB integration is the *listener* ARN, not the load balancer's or
# target group's. Deliberately the HTTP listener, not an HTTPS one — this
# integration type doesn't perform TLS to the target regardless of which
# listener it's pointed at (see alb.tf), so pointing it at an HTTPS listener
# just gets every request rejected by the ALB itself. TLS already terminates
# for real at this API's custom domain (aws_apigatewayv2_domain_name below).
resource "aws_apigatewayv2_integration" "alb" {
  api_id             = aws_apigatewayv2_api.this.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.this.id
  integration_uri    = aws_lb_listener.http.arn
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "$default" # every path/method, including "/" and the health probes

  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
  # No authorization_scopes here deliberately — this is the catch-all for
  # everything *not* covered by the explicit, scoped books routes below
  # (the health probes, "/", any future route added without updating this
  # file), so it stays audience-only like before scopes existed.
}

# Explicit, scoped routes for the books CRUD surface. cognito.tf issues a
# `read` and a `write` custom scope per consumer, but until these routes
# existed nothing ever checked which scopes a given token actually carried
# — every consumer with any valid token could call every method, including
# the mutating ones. apigatewayv2 always prefers a literal/path-parameter
# route over "$default" (the same rule that lets aws_apigatewayv2_route.docs
# carve itself out above), so these take priority without touching it.
#
# For a JWT authorizer, `authorization_scopes` is an OR match — API Gateway
# admits the request if the token's `scope` claim contains *at least one* of
# the listed scopes. GET lists both scopes (a write-only consumer can still
# read; there's no reason to also require read), the three mutating routes
# require write specifically.
locals {
  books_read_scopes  = ["${aws_cognito_resource_server.this.identifier}/read", "${aws_cognito_resource_server.this.identifier}/write"]
  books_write_scopes = ["${aws_cognito_resource_server.this.identifier}/write"]
}

resource "aws_apigatewayv2_route" "books_list" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /api/v1/books"

  target               = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type   = "JWT"
  authorizer_id        = aws_apigatewayv2_authorizer.cognito.id
  authorization_scopes = local.books_read_scopes
}

resource "aws_apigatewayv2_route" "books_get" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /api/v1/books/{book_id}"

  target               = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type   = "JWT"
  authorizer_id        = aws_apigatewayv2_authorizer.cognito.id
  authorization_scopes = local.books_read_scopes
}

resource "aws_apigatewayv2_route" "books_create" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /api/v1/books"

  target               = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type   = "JWT"
  authorizer_id        = aws_apigatewayv2_authorizer.cognito.id
  authorization_scopes = local.books_write_scopes
}

resource "aws_apigatewayv2_route" "books_update" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "PATCH /api/v1/books/{book_id}"

  target               = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type   = "JWT"
  authorizer_id        = aws_apigatewayv2_authorizer.cognito.id
  authorization_scopes = local.books_write_scopes
}

resource "aws_apigatewayv2_route" "books_delete" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "DELETE /api/v1/books/{book_id}"

  target               = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type   = "JWT"
  authorizer_id        = aws_apigatewayv2_authorizer.cognito.id
  authorization_scopes = local.books_write_scopes
}

# FastAPI's docs UI and the schema it fetches — deliberately public. A
# specific route_key always wins over "$default" in HTTP API routing, so
# these two carve themselves out of the blanket JWT requirement above
# without touching it. No authorization_type/authorizer_id set on either
# means "NONE" (the resource's default) — Swagger UI itself has to load
# unauthenticated too, since it's a browser fetching these by URL, not a
# caller that can attach a bearer token. Kong needs the equivalent carve-out
# too (ecs/kong/render_config.py) — it re-verifies the JWT independently, so
# leaving API Gateway's requirement off alone isn't enough.
resource "aws_apigatewayv2_route" "docs" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /docs"
  target    = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

resource "aws_apigatewayv2_route" "openapi_json" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "GET /openapi.json"
  target    = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  # Closes the gap docs/RUNBOOK.md used to flag under "How to view logs":
  # without this there is no per-request record of which route, which
  # caller, or which status code a request got — only the aggregate 4xx/5xx
  # *counts* in AWS/ApiGateway metrics. HTTP APIs (unlike REST APIs) don't
  # need an account-level CloudWatch role or a log-group resource policy for
  # this — referencing the log group's ARN here is enough.
  #
  # $context.authorizer.jwt.claims.client_id is the documented way to pull a
  # claim out of the token the JWT authorizer already validated — Cognito's
  # client-credentials tokens carry client_id, which is the one thing that
  # tells callers apart (see cognito.tf and docs/RUNBOOK.md's "User
  # Management" section on the one shared client today).
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_access.arn
    format = jsonencode({
      requestId          = "$context.requestId"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      path               = "$context.path"
      status             = "$context.status"
      responseLength     = "$context.responseLength"
      integrationLatency = "$context.integrationLatency"
      responseLatency    = "$context.responseLatency"
      consumer           = "$context.authorizer.jwt.claims.client_id"
      sourceIp           = "$context.identity.sourceIp"
      errorMessage       = "$context.error.message"
      authorizerError    = "$context.authorizer.error"
    })
  }
}

# This is the one place TLS actually terminates for real, on the public
# path — everything from here to the ALB is plain HTTP over a private VPC
# hop (see the integration above). Regional custom domains need a cert in
# the same region, which acm.tf's already is.
resource "aws_apigatewayv2_domain_name" "this" {
  domain_name = var.domain_name

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.this.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  domain_name = aws_apigatewayv2_domain_name.this.id
  stage       = aws_apigatewayv2_stage.default.id
}
