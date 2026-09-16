resource "aws_security_group" "alb" {
  # name_prefix, not name: `description` is ForceNew on this resource (any
  # change recreates the whole security group, not just its rules) — paired
  # with a fixed `name`, that replacement fails outright the moment anything
  # else (the ALB itself, here) still references the old group while AWS
  # hasn't yet released its ENI, since the new group can't be created under
  # the same name until the old one is gone. name_prefix + CBD below lets
  # the new group exist (under a generated name) before the old one is
  # torn down, so a future description/rule change that forces replacement
  # can't hit this same race.
  name_prefix = "${local.name_prefix}-alb-"
  description = "${local.name_prefix} ALB - internal, reachable only via API Gateway VPC Link."
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "ecs_tasks" {
  # books-api no longer registers with the ALB directly (see kong.tf/alb.tf)
  # — Kong does, and reaches books-api over ECS Service Connect instead. So
  # this SG's only ingress is from Kong's tasks now, not the ALB.
  name        = "${local.name_prefix}-ecs-tasks"
  description = "${local.name_prefix} task SG - ingress from Kong only (Service Connect)."
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "From Kong, via Service Connect"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.kong_tasks.id]
  }

  egress {
    description = "ECR, Secrets Manager, CloudWatch Logs, RDS, etc. via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-ecs-tasks" }
}

# API Gateway's VPC Link ENIs — the only thing allowed to reach the (now
# internal) ALB. alb <-> vpc_link is a mutual reference, so these two rules
# are separate aws_vpc_security_group_*_rule resources rather than inline
# ingress/egress blocks on each other's security_group resource — inline
# blocks referencing each other that way is a real Terraform dependency
# cycle (alb needs vpc_link's id, vpc_link needs alb's id, neither security
# group can finish creating first). Standalone rule resources break the
# cycle: both groups get created empty, then the cross-referencing rules
# attach to each afterward.

resource "aws_security_group" "vpc_link" {
  name        = "${local.name_prefix}-vpc-link"
  description = "API Gateway VPC Link ENIs - reach the internal ALB, nothing else."
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-vpc-link" }
}

resource "aws_vpc_security_group_egress_rule" "vpc_link_to_alb" {
  security_group_id            = aws_security_group.vpc_link.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "To the internal ALB"
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_vpc_link" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.vpc_link.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "From the API Gateway VPC Link"
}
