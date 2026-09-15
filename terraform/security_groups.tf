resource "aws_security_group" "alb" {
  name        = "books-api-alb"
  description = "books-api ALB - internal, reachable only via API Gateway's VPC Link."
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "books-api-alb" }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "books-api-ecs-tasks"
  description = "books-api task SG - ingress from the ALB only."
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "From the ALB"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "ECR, Secrets Manager, CloudWatch Logs, RDS, etc. via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "books-api-ecs-tasks" }
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
  name        = "books-api-vpc-link"
  description = "API Gateway VPC Link ENIs - reach the internal ALB, nothing else."
  vpc_id      = aws_vpc.this.id

  tags = { Name = "books-api-vpc-link" }
}

resource "aws_vpc_security_group_egress_rule" "vpc_link_to_alb" {
  security_group_id            = aws_security_group.vpc_link.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "To the internal ALB"
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_vpc_link" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.vpc_link.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "From API Gateway's VPC Link"
}
