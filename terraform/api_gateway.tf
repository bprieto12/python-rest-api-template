# The public entry point — everything else (ALB, ECS) is private and
# reachable only from here, via the VPC Link below. Every request needs a
# valid Cognito-issued JWT; there's no unauthenticated route, health checks
# included (the ALB target group's own health check bypasses this whole
# path entirely — it polls the ECS tasks directly, not through the gateway).

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
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.this.id
  name             = "cognito-client-credentials"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.this.id]
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
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
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
