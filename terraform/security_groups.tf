resource "aws_security_group" "alb" {
  name        = "books-api-alb"
  description = "books-api ALB - public HTTP/HTTPS ingress."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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
