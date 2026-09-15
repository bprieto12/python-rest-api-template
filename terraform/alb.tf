# Internal — API Gateway (api_gateway.tf) is the only public entry point.
# Dedicated to this one service: the listener forwards straight to
# books-api's target group, no host-header routing/listener rules, since
# there's nothing else behind it to route between.
#
# Plain HTTP, not HTTPS: API Gateway's HTTP_PROXY + VPC_LINK private
# integration to an ALB doesn't perform TLS to the target regardless of
# which listener it's pointed at — verified directly (pointing it at an
# HTTPS listener here produced ALB's own "plain HTTP request was sent to
# HTTPS port" error on every request). That's fine architecturally: TLS
# already terminates at the real public edge (API Gateway, with the actual
# domain and cert); this hop is entirely inside the VPC, reachable only from
# the VPC Link's own ENIs, and never touches the public internet.
resource "aws_lb" "this" {
  name               = "books-api"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.private[*].id
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
