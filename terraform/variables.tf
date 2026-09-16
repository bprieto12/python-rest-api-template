variable "aws_region" {
  description = "AWS region this deploys into."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for this service's VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread public/private subnets across."
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway for all private subnets instead of one per AZ. Cheaper (one hourly charge instead of az_count); less resilient to a single AZ's NAT failing. Fine for a low-traffic / cost-conscious setup."
  type        = bool
  default     = true
}

variable "hosted_zone_name" {
  description = "An already-existing Route 53 hosted zone (e.g. \"example.com\") to create this service's DNS record in. This repo doesn't create or own the zone — that's DNS for a domain you likely use for other things too, not something a single service's Terraform should be able to delete out from under you."
  type        = string
}

variable "domain_name" {
  description = "Fully-qualified domain name this service is reachable at (e.g. books-api.example.com) — must be domain_name within hosted_zone_name."
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
