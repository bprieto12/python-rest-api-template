# Explicitly managed so retention isn't "forever" by default — ECS's
# "awslogs-create-group": "true" (ecs/task-definition.<environment>.json)
# would otherwise create this group itself, with no expiration, the first
# time a task starts. Both containers in the task share this one group.
#
# CloudWatch Logs retention is day-granularity, minimum 1 day — there is no
# literal "2 hours" option; 1 day is the closest available value.

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 1
}

# API Gateway access logs — the destination referenced by
# aws_apigatewayv2_stage.default's access_log_settings (api_gateway.tf).
# Same 1-day retention choice as above, for the same reason. This is what
# closes the "no per-request record of who called what" gap docs/RUNBOOK.md
# used to call out under "How to view logs" — see dashboard.tf for what
# reads it.
resource "aws_cloudwatch_log_group" "api_gateway_access" {
  name              = "/aws/apigateway/${local.name_prefix}"
  retention_in_days = 1
}
