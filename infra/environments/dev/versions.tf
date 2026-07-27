terraform {
  # 1.11+ is required for S3-native state locking (use_lockfile), which removes
  # the need for a separate DynamoDB lock table.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 8.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Every resource in this environment carries these, so cost allocation and
  # "what is this and who owns it" are answerable from the console alone.
  default_tags {
    tags = {
      Project     = "fanosbingo"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = var.github_repository
    }
  }
}
