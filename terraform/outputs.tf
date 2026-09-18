output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "private_subnet_ids" {
  description = "Feeds the ECS_SUBNETS GitHub Environment variable — see scripts/bootstrap.sh."
  value       = aws_subnet.private[*].id
}

output "ecs_security_group_id" {
  description = "Feeds the ECS_SECURITY_GROUPS GitHub Environment variable — see scripts/bootstrap.sh."
  value       = aws_security_group.ecs_tasks.id
}

output "fqdn" {
  value = aws_route53_record.this.fqdn
}

output "cognito_domain" {
  description = "The token endpoint is https://<this>.auth.<region>.amazoncognito.com/oauth2/token"
  value       = aws_cognito_user_pool_domain.this.domain
}

output "cognito_user_pool_id" {
  description = "Feeds the COGNITO_USER_POOL_ID GitHub Environment variable — see scripts/bootstrap.sh. cd.yml's build-and-push-kong job uses it to list consumers and fetch the JWKS directly, since the CD role has no Terraform state access to read cognito_client_ids from."
  value       = aws_cognito_user_pool.this.id
}

output "cognito_client_ids" {
  description = "Keyed by consumer name (var.api_consumers) — e.g. `terraform output -json cognito_client_ids | jq -r .default`."
  value       = { for name, c in aws_cognito_user_pool_client.consumers : name => c.id }
}

output "cognito_client_secrets" {
  description = "Keyed by consumer name, same as cognito_client_ids."
  sensitive   = true # retrieve with: terraform output -json cognito_client_secrets
  value       = { for name, c in aws_cognito_user_pool_client.consumers : name => c.client_secret }
}

output "waf_web_acl_arn" {
  description = "The perimeter WAF in front of API Gateway (waf.tf). Blocked/rate-limited requests are logged to aws_cloudwatch_log_group.waf and surfaced via AWS/WAFV2 CloudWatch metrics."
  value       = aws_wafv2_web_acl.this.arn
}

output "alerts_topic_arn" {
  description = "Subscribe yourself: aws sns subscribe --topic-arn <this> --protocol email --notification-endpoint you@example.com"
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_url" {
  description = "Direct console link to the CloudWatch dashboard (dashboard.tf)."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.this.dashboard_name}"
}
