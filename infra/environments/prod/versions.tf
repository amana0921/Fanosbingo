terraform {
  # 1.11+ is required for S3-native state locking (use_lockfile).
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
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "fanosbingo"
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = var.github_repository
    }
  }
}

# Cloudflare is half of the origin lock -- see modules/cloudflare. The token is
# read from the environment (CLOUDFLARE_API_TOKEN) rather than a variable, so it
# never reaches Terraform state or a plan file.
#
# An absent token is fine as long as no Cloudflare resource is created: the
# provider makes no API call at configure time. That is what lets the module be
# count-gated instead of forcing every contributor to hold a Cloudflare token.
provider "cloudflare" {}
