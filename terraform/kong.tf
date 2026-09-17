# Kong Gateway (OSS, DB-less) sits between the ALB and books-api, doing the
# one thing API Gateway's JWT authorizer can't: per-consumer rate limiting.
# apigatewayv2 (api_gateway.tf) has no Usage Plans/API Keys concept at all —
# that's a REST API (v1)-only feature — so this is the AWS-native answer
# short of migrating API Gateway generations. See ../docs/RUNBOOK.md and
# ../terraform/README.md for the full request-path writeup.
#
# Kong re-verifies the same Cognito-issued JWT api_gateway.tf's authorizer
# already checked (never trust an unverified claim for rate-limiting), reads
# the consumer from its `client_id` claim, and enforces that consumer's
# limit — see ../ecs/kong/render_config.py for what actually generates the
# declarative config (kong.yml) baked into Kong's image on every deploy.

# Service Connect gives Kong a stable, Terraform-chosen DNS name for
# books-api ("books-api") that doesn't depend on apply order — unlike the
# ALB's AWS-generated dns_name, which wouldn't exist yet when Kong's image is
# built (its declarative config is baked in at build time, not apply time).
resource "aws_service_discovery_http_namespace" "this" {
  name = "${local.name_prefix}.internal"
}

resource "aws_security_group" "kong_tasks" {
  name        = "${local.name_prefix}-kong-tasks"
  description = "${local.name_prefix} Kong task SG - ingress from the ALB only."
  vpc_id      = aws_vpc.this.id

  # 8000 is the proxy port (real traffic); 8100 is the status port the
  # target group's health check hits (see aws_lb_target_group.kong below) —
  # separate from proxy traffic so health checks are never themselves
  # rate-limited or counted as a consumer's requests.
  ingress {
    description     = "From the ALB - proxy traffic"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "From the ALB - health checks"
    from_port       = 8100
    to_port         = 8100
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "ECR, CloudWatch Logs via NAT, and books-api via Service Connect"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-kong-tasks" }
}

resource "aws_lb_target_group" "kong" {
  name        = "${local.name_prefix}-kong"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip" # required for awsvpc-mode Fargate tasks

  health_check {
    # Kong's status port (KONG_STATUS_LISTEN, see ecs/kong/Dockerfile) is
    # separate from the proxy port so health checks never compete with, or
    # get rate-limited alongside, real traffic.
    port                = "8100"
    path                = "/status"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
}

locals {
  kong_task_definition = jsondecode(file("${path.module}/../ecs/task-definition.kong.${local.environment}.json"))

  kong_container = one([
    for c in local.kong_task_definition.containerDefinitions : c if c.name == "kong"
  ])
}

resource "aws_ecs_task_definition" "kong" {
  family                   = local.kong_task_definition.family
  requires_compatibilities = local.kong_task_definition.requiresCompatibilities
  network_mode             = local.kong_task_definition.networkMode
  cpu                      = local.kong_task_definition.cpu
  memory                   = local.kong_task_definition.memory
  execution_role_arn       = local.kong_task_definition.executionRoleArn
  task_role_arn            = local.kong_task_definition.taskRoleArn
  container_definitions    = jsonencode(local.kong_task_definition.containerDefinitions)

  runtime_platform {
    cpu_architecture        = local.kong_task_definition.runtimePlatform.cpuArchitecture
    operating_system_family = local.kong_task_definition.runtimePlatform.operatingSystemFamily
  }

  lifecycle {
    # Same split as aws_ecs_task_definition.this (main.tf) — CD registers
    # later revisions directly, Terraform only owns the first one's shape.
    ignore_changes = [container_definitions]
  }
}

resource "aws_ecs_service" "kong" {
  name             = local.kong_task_definition.family
  cluster          = aws_ecs_cluster.this.id
  task_definition  = aws_ecs_task_definition.kong.arn
  launch_type      = "FARGATE"
  platform_version = "LATEST"
  desired_count    = var.kong_desired_count

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.kong_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.kong.arn
    container_name   = local.kong_container.name
    container_port   = local.kong_container.portMappings[0].containerPort
  }

  # Resolving another service's Service Connect DNS name (books-api, see
  # main.tf) requires the CALLING task to be Service-Connect-enabled too,
  # not just the one being called — that's what installs the per-task Envoy
  # sidecar that intercepts and resolves those names. Confirmed the hard way
  # against real staging infra: without this, Kong's upstream requests fail
  # with "name resolution failed", even though books-api's own
  # configuration was completely correct. No `service` block needed here —
  # Kong doesn't need to expose itself via Service Connect (the ALB target
  # group above is how traffic reaches Kong), it only needs to consume it.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.this.arn
  }

  health_check_grace_period_seconds = 30

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  enable_execute_command = true

  depends_on = [aws_lb_listener.http]

  lifecycle {
    # Same reasoning as aws_ecs_service.this (main.tf) — CD owns rollouts,
    # scaling is managed outside this repo. service_connect_configuration
    # joined this list for the same reason it did there: cd.yml's
    # deploy-kong job has to resend it on every update-service call or AWS
    # silently clears it, and Terraform would otherwise fight CD over it on
    # every push to main (terraform.yml runs unconditionally, concurrently
    # with cd.yml, with no ordering between them).
    ignore_changes = [task_definition, desired_count, service_connect_configuration]
  }
}
