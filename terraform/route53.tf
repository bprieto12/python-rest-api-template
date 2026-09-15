# The zone already exists — it's DNS for a domain you almost certainly use
# for other things too (a personal site, email, ...), not something this
# one service's Terraform should be able to create/delete. Look it up, don't
# own it; only the one record below is actually managed here.

data "aws_route53_zone" "this" {
  name = var.hosted_zone_name
}

# Points at API Gateway now, not the ALB directly — the ALB is internal
# (alb.tf) and unreachable from outside the VPC, so aliasing it here would
# just be a dead record. API Gateway is the actual public entry point.
resource "aws_route53_record" "this" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.this.domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.this.domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}
