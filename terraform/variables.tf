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

variable "desired_count" {
  description = "Initial desired task count. Ignored after the first apply — CD's deploys don't change it, so scale via the console/CLI/autoscaling, not by re-applying this."
  type        = number
  default     = 2
}

variable "api_consumers" {
  description = "Names of the API callers that get their own Cognito client-credentials client and their own Kong consumer/rate limit (see terraform/cognito.tf and terraform/kong.tf). Seeded with just today's one real caller — add a name here (and see docs/RUNBOOK.md's \"How to add a user\") when a second one shows up."
  type        = list(string)
  default     = ["default"]
}

variable "kong_desired_count" {
  description = "Kong's task count. Deliberately kept separate from desired_count (books-api's) and pinned to 1 by default — Kong's rate-limiting plugin uses the in-memory \"local\" policy, which is only accurate as long as exactly one task is enforcing it. Raising this without also moving to a shared (Redis-backed) rate-limit policy means limits get enforced per-task, not globally."
  type        = number
  default     = 1
}
