variable "name_prefix" {
  description = "Prefix applied to every role name, e.g. fanosbingo-dev."
  type        = string
}

variable "environment" {
  description = "Environment name. Used in the tag condition scoping Elastic IP association."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK the task execution role may use to decrypt SecureString parameters."
  type        = string
}

variable "wallet_signing_key_arn" {
  description = "secp256k1 key ARN. Only the functions task role is granted kms:Sign on it."
  type        = string
}

variable "spa_bucket_name" {
  description = "S3 bucket holding the built SPA, so the deploy role can be scoped to it."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository permitted to assume the deploy role, as owner/name."
  type        = string
}

variable "github_allowed_refs" {
  description = <<-EOT
    Which refs in the repository may assume the deploy role, as `sub` claim
    suffixes. Defaults to the main branch only — deliberately NOT "*", which
    would let a pull request from a fork deploy to your account.
  EOT
  type        = list(string)
  default     = ["ref:refs/heads/main"]
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Create the GitHub OIDC provider. Defaults to FALSE because
    scripts/bootstrap-aws.sh already created it — Terraform itself runs via that
    provider, so it cannot be the thing that creates it. Only set true if you are
    managing this account without the bootstrap script.
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
