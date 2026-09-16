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

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.this.id
}

output "cognito_client_secret" {
  sensitive = true # retrieve with: terraform output -raw cognito_client_secret
  value     = aws_cognito_user_pool_client.this.client_secret
}

output "alerts_topic_arn" {
  description = "Subscribe yourself: aws sns subscribe --topic-arn <this> --protocol email --notification-endpoint you@example.com"
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_url" {
  description = "Direct console link to the CloudWatch dashboard (dashboard.tf)."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.this.dashboard_name}"
}
