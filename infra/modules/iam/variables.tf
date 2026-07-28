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
    Which contexts in the repository may assume this environment's deploy role,
    as `sub` claim suffixes. Deliberately NOT "*", which would let any workflow
    in any repository deploy into this account.

    The default is set by the environment root and is `environment:<env>`, not a
    branch: the workflows that use this role (deploy-services, sync-secrets,
    db-migrate) all run under a GitHub Environment, and the environment is the
    thing that carries protection rules.

    That scoping is also what separates dev from prod. A job must declare
    `environment: prod` to obtain a subject matching the prod role, and
    declaring it puts the job behind prod's required reviewers. A pull request
    can therefore reach dev's deploy role and cannot reach prod's.
  EOT
  type        = list(string)
  default     = ["ref:refs/heads/main"]

  validation {
    condition     = !contains(var.github_allowed_refs, "*")
    error_message = "A bare '*' would let any repository on GitHub assume this role."
  }
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
