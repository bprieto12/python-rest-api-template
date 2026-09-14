# Scope: the ECS *service* for books-api — task definition, service, target
# group, listener rule, and DNS record. The cluster, VPC, ALB, and hosted zone
# are shared platform resources owned elsewhere (see the `infrastructure`
# repo) and only referenced here by id/ARN via variables.
#
# `../ecs/task-definition.json` stays the single source of truth for the
# container definitions *and* the execution/task roles, image, and container
# port — the same file CD renders and registers on every deploy. Terraform
# only reads it to create the *first* revision so `apply` and CD agree on
# shape; `ignore_changes` below keeps Terraform from fighting every later
# `register-task-definition` call CD makes on its own. Nothing here should
# duplicate a value that's already in that file — update the JSON, not a
# tfvars file, when e.g. the roles or port change.

locals {
  task_definition = jsondecode(file("${path.module}/../ecs/task-definition.json"))

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

resource "aws_lb_target_group" "this" {
  name        = "books-api"
  port        = local.api_container.portMappings[0].containerPort
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # required for awsvpc-mode Fargate tasks

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # ECS churns targets on every deployment; let the new task register before
  # the old one is deregistered.
  deregistration_delay = 30
}

resource "aws_lb_listener_rule" "this" {
  listener_arn = var.alb_listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    host_header {
      values = [var.domain_name]
    }
  }
}

resource "aws_ecs_service" "this" {
  name              = local.task_definition.family
  cluster           = var.cluster_name
  task_definition   = aws_ecs_task_definition.this.arn
  launch_type       = "FARGATE"
  platform_version  = "LATEST"
  desired_count     = var.desired_count

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = local.api_container.name
    container_port   = local.api_container.portMappings[0].containerPort
  }

  health_check_grace_period_seconds = 30

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  enable_execute_command = true

  depends_on = [aws_lb_listener_rule.this]

  lifecycle {
    # CD owns rollouts (`register-task-definition` + `update-service
    # --force-new-deployment`) and scaling is managed outside this repo —
    # Terraform shouldn't revert either on the next apply.
    ignore_changes = [task_definition, desired_count]
  }
}

resource "aws_route53_record" "this" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}
