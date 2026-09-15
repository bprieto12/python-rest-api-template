# Internal — API Gateway (api_gateway.tf) is the only public entry point.
# Dedicated to this one service: the HTTPS listener forwards straight to
# books-api's target group, no host-header routing/listener rules, since
# there's nothing else behind it to route between.
#
# No port-80 listener: nothing reaches this ALB except API Gateway's VPC
# Link, which always calls the HTTPS listener directly (it terminates TLS
# from the actual caller itself) — an HTTP->HTTPS redirect listener would be
# genuinely dead code here, unlike when this ALB was internet-facing.

resource "aws_lb" "this" {
  name               = "books-api"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.private[*].id
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
