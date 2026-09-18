# Perimeter WAF in front of API Gateway — the one layer that inspects raw
# request contents (headers, query string, body) *before* anything else in
# the path gets a chance to reject it. Everything downstream already
# authenticates (Cognito JWT, api_gateway.tf) and rate-limits per-consumer
# (Kong, kong.tf), but neither of those helps with:
#   - injection-shaped payloads: repository.py builds DynamoDB
#     FilterExpressions from raw query params (author/q) rather than a
#     parameterized driver call — the managed rule groups below are the
#     layer that actually inspects for that, independent of what the app
#     code does with the value afterward.
#   - anonymous volumetric abuse: Kong never sees a request that fails API
#     Gateway's JWT authorizer, so a flood of invalid-token requests against
#     the (comparatively expensive) authorizer itself is invisible to Kong's
#     rate limiting entirely. The rate-based rule below is what catches that,
#     upstream of the authorizer.
#
# scope = REGIONAL, not CLOUDFRONT — this attaches to a regional HTTP API
# (api_gateway.tf), not a CloudFront distribution, so unlike a
# CLOUDFRONT-scope ACL (always us-east-1, regardless of the distribution's
# origin region) this must be created in the same region as the API itself.
resource "aws_wafv2_web_acl" "this" {
  name        = "${local.name_prefix}-api"
  description = "Perimeter WAF for the ${local.name_prefix} API Gateway."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # AWS Managed Rule Groups — maintained by AWS, no extra charge beyond the
  # WCU cost already folded into WAF's per-ACL pricing. `override_action { none
  # {} }` means each rule group's own block/count decisions are honored as
  # written, not overridden to count-only.
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-sqli"
      sampled_requests_enabled   = true
    }
  }

  # Pre-auth volumetric abuse: more than var.waf_rate_limit_per_5min requests
  # from one IP in WAF's fixed rolling 5-minute window (not configurable —
  # that window length is intrinsic to rate_based_statement, only the limit
  # is) gets blocked here, before it ever reaches the JWT authorizer.
  # Deliberately generous — this is abuse protection sitting in front of
  # every consumer combined, not the per-consumer quota Kong already owns
  # downstream (ecs/kong/rate-limits.<environment>.json).
  rule {
    name     = "RateLimitPerIp"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-web-acl"
    sampled_requests_enabled   = true
  }
}

# Attaches to the API Gateway *stage*, not the API itself — that's the
# resource_arn shape aws_wafv2_web_acl_association expects for an HTTP API
# (.../apis/<api-id>/stages/<stage-name>), which aws_apigatewayv2_stage.default.arn
# already produces in the right form.
resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = aws_apigatewayv2_stage.default.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

# WAF logging requires its destination log group's name to start with
# "aws-waf-logs-" — a hard requirement of aws_wafv2_web_acl_logging_configuration,
# not a convention; anything else is rejected at apply time. That specific
# prefix is also what lets WAF write to it with no separate resource policy
# needed (AWS grants the service permission automatically for names matching
# it). Same 1-day retention as this repo's other log groups (logs.tf) — this
# is for "what got blocked and why" during an incident, not audit retention.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${local.name_prefix}"
  retention_in_days = 1
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Every request through this WAF carries its Cognito access token in
  # Authorization — WAF logs the full request including headers by default,
  # so without this a bearer token (still valid for up to an hour, per
  # docs/RUNBOOK.md) would otherwise sit in cleartext in a CloudWatch log
  # group. Redacted, not omitted: the field still appears in the log entry,
  # just with its value blanked out, which is what this resource supports.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}
