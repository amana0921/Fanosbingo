variable "aws_region" {
  description = "AWS region. us-east-1 is cheapest and is where CloudFront-scoped ACM certificates must live."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name. Becomes part of every resource name."
  type        = string
  default     = "prod"

  validation {
    condition     = var.environment == "prod"
    error_message = "This root module is prod. Do not point it at another environment."
  }
}

variable "project_name" {
  description = "Project slug used to build the resource name prefix."
  type        = string
  default     = "fanosbingo"
}

variable "vpc_cidr" {
  description = "CIDR for prod's VPC. Distinct from dev's 10.30.0.0/16 so the two could be peered."
  type        = string
  default     = "10.20.0.0/16"
}

variable "domain_name" {
  description = "Apex domain the SPA is served from, e.g. fanosbingo.com."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository permitted to assume the deploy role, as owner/name."
  type        = string
}

variable "alert_emails" {
  description = <<-EOT
    Addresses receiving budget and alarm notifications. Each recipient must click
    the SNS confirmation link before any alert is delivered.
  EOT
  type        = list(string)
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Leave false. scripts/bootstrap-aws.sh created the account-wide OIDC provider,
    and Terraform authenticates through it.
  EOT
  type        = bool
  default     = false
}

variable "bsc_chain_id" {
  description = "BSC chain id. 56 is mainnet. Only set 97 if you are deliberately running prod against testnet."
  type        = number
  default     = 56

  validation {
    condition     = contains([56, 97], var.bsc_chain_id)
    error_message = "bsc_chain_id must be 56 (mainnet) or 97 (testnet)."
  }
}
