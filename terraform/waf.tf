# WAF attached to the internal ALB (alb.tf) — NOT to API Gateway, even
# though API Gateway is this service's actual public entry point.
# Confirmed against a real `apply`, not a design choice: AWS WAFv2's
# AssociateWebACL only supports a fixed list of resource types (CloudFront,
# ALB, AppSync, Cognito, App Runner, Verified Access, and API Gateway REST
# APIs specifically) — HTTP APIs (apigatewayv2, api_gateway.tf's
# protocol_type = "HTTP") aren't on that list at all. Every attempt to
# associate this Web ACL with the API Gateway stage's ARN failed with "The
# ARN isn't valid" regardless of how the "$default" stage name was encoded
# — that error is WAFv2 rejecting the whole /apis/.../stages/... shape, not
# a quoting problem. Migrating to a REST API (v1) just to regain WAF
# support isn't on the table here — that's the exact same generation
# change kong.tf's own doc comment already rejected, for the same "not
# worth it for one feature" reason (there, Usage Plans; here, WAF).
#
# The real consequence of sitting on the ALB instead: this evaluates
# traffic AFTER API Gateway's JWT authorizer, not before. It still
# inspects every request's contents (the managed rule groups below) and
# still rate-limits by real caller (the forwarded_ip_config on
# RateLimitPerIp, below), but it no longer shields the authorizer itself
# from a flood of anonymous/invalid-token requests — API Gateway would eat
# that cost before this WAF ever sees the request. Kong (kong.tf) still
# fills the one gap neither of these covers: per-consumer rate limiting.
#
# scope = REGIONAL, not CLOUDFRONT — this attaches to a regional ALB
# (alb.tf), not a CloudFront distribution, so unlike a CLOUDFRONT-scope ACL
# (always us-east-1, regardless of the distribution's origin region) this
# must be created in the same region as the ALB itself.
resource "aws_wafv2_web_acl" "this" {
  name        = "${local.name_prefix}-api"
  description = "WAF for the ${local.name_prefix} ALB, protecting the books-api request path behind it."
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

  # Volumetric abuse from one real caller: more than var.waf_rate_limit_per_5min
  # requests in WAF's fixed rolling 5-minute window (not configurable — that
  # window length is intrinsic to rate_based_statement, only the limit is)
  # gets blocked here. Deliberately generous — this is abuse protection
  # sitting in front of every consumer combined, not the per-consumer quota
  # Kong already owns downstream (ecs/kong/rate-limits.<environment>.json).
  #
  # forwarded_ip_config is required here, not optional: this Web ACL is on
  # the ALB (see the module-level comment above for why), which every
  # request reaches via API Gateway's VPC Link — a private hop, so the raw
  # TCP source IP the ALB actually sees is the VPC Link's own ENI, not the
  # original caller's, and aggregate_key_type = "IP" would key every
  # request in this rule to that same handful of addresses instead of
  # distinguishing real callers. X-Forwarded-For is what actually carries
  # the caller's IP through that hop (API Gateway's HTTP_PROXY integration
  # sets it, same as any L7 proxy would). fallback_behavior = "MATCH" (i.e.
  # treat a missing/malformed header as a match, and count it toward the
  # limit) errs toward not silently disabling this rule if that header is
  # ever absent, at the cost of an unusual request being rate-limited
  # alongside everyone else sharing that fallback bucket.
  rule {
    name     = "RateLimitPerIp"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "FORWARDED_IP"

        forwarded_ip_config {
          header_name       = "X-Forwarded-For"
          fallback_behavior = "MATCH"
        }
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

# Attaches to the ALB itself (alb.tf) — see the module-level comment above
# for why this isn't the API Gateway stage. For WAFv2's ALB resource type,
# resource_arn is just the load balancer's own ARN, no listener or target
# group involved.
resource "aws_wafv2_web_acl_association" "this" {
  resource_arn = aws_lb.this.arn
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
