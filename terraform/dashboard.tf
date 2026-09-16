# A single CloudWatch dashboard covering API performance, infrastructure,
# and DynamoDB — recreated on every `apply` rather than hand-built in the
# console, same reasoning as everything else in this directory.
#
# Three kinds of data source, deliberately not mixed within one widget:
#   - The API Gateway access log (aws_cloudwatch_log_group.api_gateway_access,
#     api_gateway.tf) via CloudWatch Logs Insights — used ONLY for what no
#     native metric can give: exact status codes, routes, and consumer
#     identity per request.
#   - Native, documented AWS metrics (AWS/ApiGateway, ECS/ContainerInsights,
#     AWS/DynamoDB) for everything else.
#   - The app's own log group (aws_cloudwatch_log_group.this, logs.tf) for
#     the Info/Error log tables.
#
# Deliberately NOT used: the app's custom ECS/AWSOTel/Application OTel
# metrics (docs/RUNBOOK.md's metrics table). Their exact exported
# dimensions depend on the aws-otel-collector sidecar's baked-in config
# (ecs/task-definition.*.json's `--config=/etc/ecs/ecs-cloudwatch-xray.yaml`,
# not something in this repo), and unlike alarms.tf's metrics, there was no
# live AWS session available while writing this to confirm actual dimension
# names against real CloudWatch data. Every metric/dimension referenced
# below is instead one of AWS's own stable, documented metrics for that
# service. Still: apply to staging first and check each widget for "no
# data" before trusting this in production.

locals {
  dashboard_region    = var.aws_region
  ecs_cluster_name    = aws_ecs_cluster.this.name
  ecs_service_name    = aws_ecs_service.this.name
  api_id              = aws_apigatewayv2_api.this.id
  books_table_name    = aws_dynamodb_table.books.name
  isbns_table_name    = aws_dynamodb_table.isbns.name
  app_log_group_name  = aws_cloudwatch_log_group.this.name
  access_log_group_id = aws_cloudwatch_log_group.api_gateway_access.name
  # Reserved capacity for one task, straight from the same task definition
  # JSON ecs.tf already parses — the reference line on the per-task
  # CPU/Memory widgets below, not a value re-typed by hand.
  task_cpu_units  = tonumber(local.task_definition.cpu)
  task_memory_mib = tonumber(local.task_definition.memory)
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.name_prefix

  dashboard_body = jsonencode({
    widgets = [
      # ---------------------------------------------------------------
      # API Performance
      # ---------------------------------------------------------------
      {
        type = "text", x = 0, y = 0, width = 24, height = 1
        properties = {
          markdown = "## API Performance\nFrom the API Gateway access log (status/route/consumer detail) and native `AWS/ApiGateway` metrics (counts/latency)."
        }
      },
      {
        type = "log", x = 0, y = 1, width = 8, height = 6
        properties = {
          title  = "Response Statuses"
          region = local.dashboard_region
          view   = "pie"
          query  = "SOURCE '${local.access_log_group_id}' | fields status | stats count(*) as count by status | sort count desc"
        }
      },
      {
        type = "log", x = 8, y = 1, width = 8, height = 6
        properties = {
          title  = "Response status codes over time"
          region = local.dashboard_region
          view   = "line"
          query  = "SOURCE '${local.access_log_group_id}' | fields @timestamp, status | stats count(*) as count by bin(5m), status"
        }
      },
      {
        type = "log", x = 16, y = 1, width = 8, height = 6
        properties = {
          title  = "Top Routes"
          region = local.dashboard_region
          view   = "bar"
          query  = "SOURCE '${local.access_log_group_id}' | fields path | stats count(*) as count by path | sort count desc | limit 10"
        }
      },
      {
        type = "log", x = 0, y = 7, width = 8, height = 6
        properties = {
          title  = "Top Consumers"
          region = local.dashboard_region
          view   = "bar"
          query  = "SOURCE '${local.access_log_group_id}' | fields consumer | stats count(*) as count by consumer | sort count desc | limit 10"
        }
      },
      {
        type = "metric", x = 8, y = 7, width = 8, height = 6
        properties = {
          title   = "Requests over time"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", local.api_id, { id = "m1", stat = "Sum", label = "Requests" }]
          ]
        }
      },
      {
        type = "metric", x = 16, y = 7, width = 8, height = 6
        properties = {
          title   = "RPS over time"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            [{ expression = "m1/PERIOD(m1)", label = "RPS", id = "e1" }],
            ["AWS/ApiGateway", "Count", "ApiId", local.api_id, { id = "m1", stat = "Sum", visible = false }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 13, width = 12, height = 6
        properties = {
          title   = "p95 response time (ms) over time"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", local.api_id, { id = "m1", stat = "p95", label = "p95 latency" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 13, width = 6, height = 6
        properties = {
          title  = "p95 response time (ms)"
          region = local.dashboard_region
          view   = "singleValue"
          period = 300
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", local.api_id, { id = "m1", stat = "p95", label = "p95 latency" }]
          ]
        }
      },
      {
        type = "metric", x = 18, y = 13, width = 6, height = 6
        properties = {
          title  = "Max RPS"
          region = local.dashboard_region
          view   = "singleValue"
          stat   = "Maximum"
          period = 60
          metrics = [
            [{ expression = "m1/PERIOD(m1)", label = "Max RPS", id = "e1" }],
            ["AWS/ApiGateway", "Count", "ApiId", local.api_id, { id = "m1", stat = "Sum", visible = false }]
          ]
        }
      },
      {
        type = "log", x = 0, y = 19, width = 12, height = 6
        properties = {
          title  = "Info Logs"
          region = local.dashboard_region
          view   = "table"
          query  = "SOURCE '${local.app_log_group_name}' | fields @timestamp, @logStream, @message | filter @logStream like /^api\\// | filter @message like /^INFO/ | sort @timestamp desc | limit 100"
        }
      },
      {
        type = "log", x = 12, y = 19, width = 12, height = 6
        properties = {
          title  = "Error Logs"
          region = local.dashboard_region
          view   = "table"
          query  = "SOURCE '${local.app_log_group_name}' | fields @timestamp, @logStream, @message | filter @logStream like /^api\\// | filter @message like /^ERROR/ | sort @timestamp desc | limit 100"
        }
      },

      # ---------------------------------------------------------------
      # Infrastructure Metrics
      # ---------------------------------------------------------------
      {
        type = "text", x = 0, y = 25, width = 24, height = 1
        properties = {
          markdown = "## Infrastructure Metrics\nECS Fargate — no EC2 hosts exist here, so \"per host\" below means per-task (ECS/ContainerInsights, TaskId dimension)."
        }
      },
      {
        type = "metric", x = 0, y = 26, width = 8, height = 6
        properties = {
          title   = "Container (task) counts over time"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", local.ecs_cluster_name, "ServiceName", local.ecs_service_name, { id = "m1", stat = "Average", label = "Running" }],
            ["ECS/ContainerInsights", "DesiredTaskCount", "ClusterName", local.ecs_cluster_name, "ServiceName", local.ecs_service_name, { id = "m2", stat = "Average", label = "Desired" }]
          ]
        }
      },
      {
        type = "metric", x = 8, y = 26, width = 8, height = 6
        properties = {
          title   = "% Memory used by containers"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          yAxis   = { left = { min = 0, max = 100 } }
          metrics = [
            ["ECS/ContainerInsights", "MemoryUtilization", "ClusterName", local.ecs_cluster_name, "ServiceName", local.ecs_service_name, { id = "m1", stat = "Average", label = "Average" }],
            ["ECS/ContainerInsights", "MemoryUtilization", "ClusterName", local.ecs_cluster_name, "ServiceName", local.ecs_service_name, { id = "m2", stat = "Maximum", label = "Maximum" }]
          ]
        }
      },
      {
        type = "metric", x = 16, y = 26, width = 8, height = 6
        properties = {
          title   = "% CPU used by containers"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          yAxis   = { left = { min = 0, max = 100 } }
          metrics = [
            ["ECS/ContainerInsights", "CpuUtilization", "ClusterName", local.ecs_cluster_name, "ServiceName", local.ecs_service_name, { id = "m1", stat = "Average", label = "Average" }],
            ["ECS/ContainerInsights", "CpuUtilization", "ClusterName", local.ecs_cluster_name, "ServiceName", local.ecs_service_name, { id = "m2", stat = "Maximum", label = "Maximum" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 32, width = 8, height = 6
        properties = {
          title   = "Server (cluster task) counts over time"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", local.ecs_cluster_name, { id = "m1", stat = "Average", label = "Running (cluster-wide)" }],
            ["ECS/ContainerInsights", "PendingTaskCount", "ClusterName", local.ecs_cluster_name, { id = "m2", stat = "Average", label = "Pending (cluster-wide)" }]
          ]
        }
      },
      {
        type = "metric", x = 8, y = 32, width = 8, height = 6
        properties = {
          title   = "CPU utilization per task over time"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          # TaskIds are ephemeral (replaced on every deploy) so this has to
          # discover them dynamically rather than name specific dimension
          # values — SEARCH() is the only way to do that.
          metrics = [
            [{ expression = "SEARCH('{ECS/ContainerInsights,ClusterName,ServiceName,TaskId} MetricName=\"CpuUtilized\" ClusterName=\"${local.ecs_cluster_name}\" ServiceName=\"${local.ecs_service_name}\"', 'Average', 300)", label = "", id = "e1" }]
          ]
          annotations = {
            horizontal = [
              { label = "Reserved (${local.task_cpu_units} CPU units)", value = local.task_cpu_units }
            ]
          }
        }
      },
      {
        type = "metric", x = 16, y = 32, width = 8, height = 6
        properties = {
          title   = "Memory Utilization per task over time"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            [{ expression = "SEARCH('{ECS/ContainerInsights,ClusterName,ServiceName,TaskId} MetricName=\"MemoryUtilized\" ClusterName=\"${local.ecs_cluster_name}\" ServiceName=\"${local.ecs_service_name}\"', 'Average', 300)", label = "", id = "e1" }]
          ]
          annotations = {
            horizontal = [
              { label = "Reserved (${local.task_memory_mib} MiB)", value = local.task_memory_mib }
            ]
          }
        }
      },

      # ---------------------------------------------------------------
      # DB Metrics (DynamoDB)
      # ---------------------------------------------------------------
      {
        type = "text", x = 0, y = 38, width = 24, height = 1
        properties = {
          markdown = "## DB Metrics (DynamoDB)\nBoth tables are fixed at 5/5 provisioned capacity, not autoscaled (terraform/dynamodb.tf) — capacity headroom is the thing most worth watching here."
        }
      },
      {
        type = "metric", x = 0, y = 39, width = 8, height = 6
        properties = {
          title   = "Consumed vs. Provisioned Read Capacity"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", local.books_table_name, { id = "m1", stat = "Sum", label = "books consumed" }],
            ["AWS/DynamoDB", "ProvisionedReadCapacityUnits", "TableName", local.books_table_name, { id = "m2", stat = "Average", label = "books provisioned" }],
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", local.isbns_table_name, { id = "m3", stat = "Sum", label = "isbns consumed" }],
            ["AWS/DynamoDB", "ProvisionedReadCapacityUnits", "TableName", local.isbns_table_name, { id = "m4", stat = "Average", label = "isbns provisioned" }]
          ]
        }
      },
      {
        type = "metric", x = 8, y = 39, width = 8, height = 6
        properties = {
          title   = "Consumed vs. Provisioned Write Capacity"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          metrics = [
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", local.books_table_name, { id = "m1", stat = "Sum", label = "books consumed" }],
            ["AWS/DynamoDB", "ProvisionedWriteCapacityUnits", "TableName", local.books_table_name, { id = "m2", stat = "Average", label = "books provisioned" }],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", local.isbns_table_name, { id = "m3", stat = "Sum", label = "isbns consumed" }],
            ["AWS/DynamoDB", "ProvisionedWriteCapacityUnits", "TableName", local.isbns_table_name, { id = "m4", stat = "Average", label = "isbns provisioned" }]
          ]
        }
      },
      {
        type = "metric", x = 16, y = 39, width = 8, height = 6
        properties = {
          title   = "Throttled Requests over time"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          # Same metric/dimensions as the aws_cloudwatch_metric_alarm.dynamodb_throttles
          # alarms in alarms.tf — this is the visual companion to those.
          metrics = [
            ["AWS/DynamoDB", "ThrottledRequests", "TableName", local.books_table_name, { id = "m1", stat = "Sum", label = "books" }],
            ["AWS/DynamoDB", "ThrottledRequests", "TableName", local.isbns_table_name, { id = "m2", stat = "Sum", label = "isbns" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 45, width = 12, height = 6
        properties = {
          title   = "Successful Request Latency by operation (ms)"
          region  = local.dashboard_region
          view    = "timeSeries"
          stacked = false
          period  = 300
          # Operation isn't hardcoded (GetItem/PutItem/Query/...) — SEARCH()
          # picks up whichever operations each table actually serves.
          metrics = [
            [{ expression = "SEARCH('{AWS/DynamoDB,TableName,Operation} MetricName=\"SuccessfulRequestLatency\" TableName=\"${local.books_table_name}\"', 'Average', 300)", label = "", id = "e1" }],
            [{ expression = "SEARCH('{AWS/DynamoDB,TableName,Operation} MetricName=\"SuccessfulRequestLatency\" TableName=\"${local.isbns_table_name}\"', 'Average', 300)", label = "", id = "e2" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 45, width = 6, height = 6
        properties = {
          title  = "Item Count (current, approximate)"
          region = local.dashboard_region
          view   = "singleValue"
          # DynamoDB only publishes ItemCount a few times a day (it's a
          # storage-metadata metric, not a live counter) — a wide period is
          # what makes the latest known value show up at all.
          period = 21600
          metrics = [
            ["AWS/DynamoDB", "ItemCount", "TableName", local.books_table_name, { id = "m1", stat = "Average", label = "books" }],
            ["AWS/DynamoDB", "ItemCount", "TableName", local.isbns_table_name, { id = "m2", stat = "Average", label = "isbns" }]
          ]
        }
      },
      {
        type = "metric", x = 18, y = 45, width = 6, height = 6
        properties = {
          title  = "Conditional check failures (isbns)"
          region = local.dashboard_region
          view   = "timeSeries"
          period = 300
          # repository.py enforces ISBN uniqueness with
          # ConditionExpression="attribute_not_exists(isbn)" on this table —
          # spikes here are duplicate-ISBN attempts, not an error condition.
          metrics = [
            ["AWS/DynamoDB", "ConditionalCheckFailedRequests", "TableName", local.isbns_table_name, { id = "m1", stat = "Sum", label = "isbns" }]
          ]
        }
      }
    ]
  })
}
