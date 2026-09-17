# The ECS task definition (initial revision only) and service.
#
# `../ecs/task-definition.<environment>.json` stays the single source of
# truth for the container definitions and the execution/task roles, image,
# and container port — the same file CD renders and registers on every
# deploy for that environment. Terraform only reads it to create the *first*
# revision so `apply` and CD agree on shape; `ignore_changes` below keeps
# Terraform from fighting every later `register-task-definition` call CD
# makes on its own. Nothing here should duplicate a value that's already in
# that file — update the JSON, not a tfvars file, when e.g. the roles or
# port change. See ../ecs/README.md for the full CD-vs-Terraform ownership
# split, and for why there's one such file per environment rather than one
# shared file (staging and production need different role ARNs and
# DynamoDB table names baked in).

locals {
  task_definition = jsondecode(file("${path.module}/../ecs/task-definition.${local.environment}.json"))

  api_container = one([
    for c in local.task_definition.containerDefinitions : c if c.name == "api"
  ])
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.task_definition.family
  requires_compatibilities = local.task_definition.requiresCompatibilities
  network_mode             = local.task_definition.networkMode
  cpu                      = local.task_definition.cpu
  memory                   = local.task_definition.memory
  execution_role_arn       = local.task_definition.executionRoleArn
  task_role_arn            = local.task_definition.taskRoleArn
  container_definitions    = jsonencode(local.task_definition.containerDefinitions)

  runtime_platform {
    cpu_architecture        = local.task_definition.runtimePlatform.cpuArchitecture
    operating_system_family = local.task_definition.runtimePlatform.operatingSystemFamily
  }

  lifecycle {
    # CD registers new revisions directly via `aws ecs register-task-definition`
    # on every deploy — Terraform only owns the initial shape.
    ignore_changes = [container_definitions]
  }
}

resource "aws_ecs_service" "this" {
  name             = local.task_definition.family
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.this.arn
  launch_type      = "FARGATE"
  platform_version = "LATEST"
  desired_count    = var.desired_count

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  # Not behind the ALB anymore — Kong is (kong.tf/alb.tf). books-api is only
  # reachable from Kong now, over Service Connect's internal DNS ("books-api"
  # — the client_alias below), not a target group.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.this.arn

    service {
      port_name = "api" # must match the named portMapping in the task def, see ecs/task-definition.<environment>.json

      client_alias {
        dns_name = "books-api"
        port     = local.api_container.portMappings[0].containerPort
      }
    }
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  enable_execute_command = true

  lifecycle {
    # CD owns rollouts (`register-task-definition` + `update-service
    # --force-new-deployment`) and scaling is managed outside this repo —
    # Terraform shouldn't revert either on the next apply.
    ignore_changes = [task_definition, desired_count]
  }
}
