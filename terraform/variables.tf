variable "aws_region" {
  description = "AWS region this service deploys into."
  type        = string
  default     = "us-east-1"
}

# --- Platform inputs -------------------------------------------------------
# Everything below comes from the shared `infrastructure` repo (cluster, VPC,
# ALB, hosted zone) rather than being declared here. Until that repo exists,
# fill these in by hand per environment (see terraform.tfvars.example); once
# it does, swap the defaults for `data "aws_ssm_parameter"` lookups against
# the names it publishes, without touching main.tf.

variable "cluster_name" {
  description = "Name of the shared ECS cluster this service runs on."
  type        = string
}

variable "vpc_id" {
  description = "VPC the target group is registered in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet ids for the service's ENIs (awsvpc mode)."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups attached to the service's ENIs."
  type        = list(string)
}

variable "alb_listener_arn" {
  description = "ARN of the shared ALB's HTTPS listener to attach a routing rule to."
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name of the shared ALB, for the Route 53 alias record."
  type        = string
}

variable "alb_zone_id" {
  description = "Hosted zone id of the shared ALB (from the aws_lb resource), for the alias record."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone id this service's record is created in."
  type        = string
}

variable "listener_rule_priority" {
  description = "Priority for this service's listener rule on the shared ALB listener. Must be unique per listener across all services."
  type        = number
}

# --- Service inputs ----------------------------------------------------------
# Execution/task role ARNs, the container image, and the container port are
# NOT variables here — they're already in ../ecs/task-definition.json, which
# main.tf reads directly. Duplicating them as tfvars would just be a second
# place for them to go stale.

variable "domain_name" {
  description = "Fully-qualified domain name this service is reachable at (e.g. books-api.example.com)."
  type        = string
}

variable "health_check_path" {
  description = "HTTP path the target group health checks against."
  type        = string
  default     = "/healthz"
}

variable "desired_count" {
  description = "Initial desired task count. Ignored after the first apply — CD's deploys don't change it, so scale via the console/CLI/autoscaling, not by re-applying this."
  type        = number
  default     = 2
}
