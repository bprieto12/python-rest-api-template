# Explicitly managed so retention isn't "forever" by default — ECS's
# "awslogs-create-group": "true" (ecs/task-definition.json) would otherwise
# create this group itself, with no expiration, the first time a task
# starts. Both containers in the task share this one group.
#
# CloudWatch Logs retention is day-granularity, minimum 1 day — there is no
# literal "2 hours" option; 1 day is the closest available value.

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/books-api"
  retention_in_days = 1
}
