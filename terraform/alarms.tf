# Operationalizes a handful of SLOs (see docs/RUNBOOK.md's "Alerting" section
# for the full writeup of what each one means and why this threshold) as
# CloudWatch Alarms, all publishing to one SNS topic. Every metric name and
# dimension set below was checked directly against this account's actual
# CloudWatch data before being hardcoded here (`aws cloudwatch list-metrics
# --namespace ...`) rather than assumed from memory.
#
# Nothing is subscribed to the topic by default — deliberately. An email
# address or webhook is a personal choice this repo shouldn't make or store
# on your behalf. Subscribe yourself, once:
#   aws sns subscribe --topic-arn $(terraform output -raw alerts_topic_arn) \
#     --protocol email --notification-endpoint you@example.com
# (confirm the subscription email AWS sends you, or nothing arrives).

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}

# --- SLO: the service is actually up ---------------------------------------
# At least one ECS target healthy behind the ALB, always. This is the single
# most fundamental signal — everything else is about degraded, not down.
resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name        = "${local.name_prefix}-unhealthy-targets"
  alarm_description = "No healthy ECS targets behind the ALB - the service is effectively down."
  namespace         = "AWS/ApplicationELB"
  metric_name       = "UnHealthyHostCount"
  dimensions = {
    TargetGroup  = aws_lb_target_group.this.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  # This metric is always actively published as long as any target is
  # registered — a gap here is itself suspicious (e.g. the ALB is gone),
  # unlike the low-traffic alarms below where no data just means no traffic.
  treat_missing_data = "breaching"
  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
}

# --- SLO: availability - fewer than ~1% of requests 5xx ---------------------
# A raw count, not a computed error rate — simpler, and meaningful at this
# service's actual traffic level (a computed percentage needs enough volume
# per period to not be noise; this doesn't have that yet). Revisit as a
# metric-math error-rate expression once real traffic volume justifies it.
resource "aws_cloudwatch_metric_alarm" "gateway_5xx" {
  alarm_name          = "${local.name_prefix}-gateway-5xx"
  alarm_description   = "API Gateway is returning 5xx responses."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.this.id }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching" # no traffic = no data here, and that's fine
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# --- SLO: latency - p99 under 3s --------------------------------------------
# Generous on purpose — this is "something is clearly wrong" territory
# (Fargate/DynamoDB cold paths included), not a tight performance target.
# Tighten once real traffic gives a baseline worth holding to.
resource "aws_cloudwatch_metric_alarm" "gateway_latency_p99" {
  alarm_name          = "${local.name_prefix}-gateway-latency-p99"
  alarm_description   = "API Gateway p99 integration latency is above 3s."
  namespace           = "AWS/ApiGateway"
  metric_name         = "IntegrationLatency"
  dimensions          = { ApiId = aws_apigatewayv2_api.this.id }
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 3
  threshold           = 3000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# --- SLO: the data layer has headroom - zero throttles ----------------------
# Capacity is fixed (5/5 provisioned, not autoscaled — terraform/dynamodb.tf)
# — this is the earliest warning that ceiling is being hit, before callers
# start seeing errors from it. ThrottledRequests has never fired in this
# account (confirmed: absent from `list-metrics` entirely, unlike every
# other DynamoDB metric checked alongside it) — that's it never having
# happened, not a wrong metric name; a real throttle will make it appear.
resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  for_each = {
    books = aws_dynamodb_table.books.name
    isbns = aws_dynamodb_table.isbns.name
  }

  alarm_name          = "${local.name_prefix}-dynamodb-throttles-${each.key}"
  alarm_description   = "DynamoDB is throttling requests on the ${each.key} table - fixed provisioned capacity may need raising."
  namespace           = "AWS/DynamoDB"
  metric_name         = "ThrottledRequests"
  dimensions          = { TableName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
