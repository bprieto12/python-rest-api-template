terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial config on purpose — bucket/key/region/dynamodb_table are supplied
  # per environment, e.g.:
  #   terraform init -backend-config=environments/production.backend.hcl
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
