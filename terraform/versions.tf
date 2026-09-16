terraform {
  # >= 1.10 specifically for the S3 backend's native state locking
  # (use_lockfile) — no DynamoDB table needed for locking as of that version.
  # This is a floor, not the version actually run — .github/workflows/
  # terraform.yml pins CI to a specific newer patch (currently 1.16.2), kept
  # in sync manually. 1.10.5 (the very first point release with native S3
  # locking) was observed silently skipping the refresh step for several
  # resource types on every apply, planning to recreate them and colliding
  # with real "already exists" errors against infrastructure that was
  # already there — a newer core version resolved it. Bump the CI pin
  # again if that ever recurs, before assuming it's a config/IAM problem.
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
      Service     = "books-api"
      Environment = local.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}
