terraform {
  # >= 1.10 specifically for the S3 backend's native state locking
  # (use_lockfile) — no DynamoDB table needed for locking as of that version.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial config on purpose — bucket/key/region/use_lockfile are supplied
  # at init time, e.g.:
  #   terraform init -backend-config=backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Service   = "books-api"
      ManagedBy = "terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}
