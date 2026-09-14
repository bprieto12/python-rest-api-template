output "service_name" {
  description = "Name of the ECS service (matches --service for aws ecs commands)."
  value       = aws_ecs_service.this.name
}

output "task_definition_family" {
  description = "Task definition family CD registers new revisions under."
  value       = aws_ecs_task_definition.this.family
}

output "target_group_arn" {
  description = "ARN of the target group backing this service."
  value       = aws_lb_target_group.this.arn
}

output "fqdn" {
  description = "Public DNS name this service is reachable at."
  value       = aws_route53_record.this.fqdn
}
