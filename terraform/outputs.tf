output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
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
