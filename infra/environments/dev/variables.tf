variable "aws_region" {
  description = "AWS region. us-east-1 is cheapest and is where CloudFront-scoped ACM certificates must live."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name. Becomes part of every resource name."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "project_name" {
  description = "Project slug used to build the resource name prefix."
  type        = string
  default     = "fanosbingo"
}

variable "vpc_cidr" {
  description = "CIDR for this environment's VPC. Keep dev and prod distinct so they could be peered later."
  type        = string
  default     = "10.30.0.0/16"
}

variable "domain_name" {
  description = "Apex domain the SPA is served from, e.g. fanosbingo.com. Used for the CORS allowed origin."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository permitted to assume the deploy role, as owner/name."
  type        = string
}

variable "ticker_image" {
  description = <<-EOT
    Full image reference for the ticker, tagged by git SHA. Left null until the
    first image is pushed; CI then deploys new revisions directly, so this is
    only the initial value Terraform sets.
  EOT
  type        = string
  default     = null
}

variable "postgrest_image" {
  description = "Full image reference for PostgREST, tagged by git SHA. Null until first pushed."
  type        = string
  default     = null
}

variable "realtime_image" {
  description = "Full image reference for Realtime, tagged by git SHA. Null until first pushed."
  type        = string
  default     = null
}

variable "caddy_image" {
  description = "Full image reference for Caddy, tagged by git SHA. Null until first pushed."
  type        = string
  default     = null
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
    Create the account-wide GitHub OIDC provider. Normally false: the bootstrap
    script created it, and Terraform authenticates THROUGH it, so Terraform
    cannot also be what creates it.
  EOT
  type        = bool
  default     = false
}

variable "cloudflare_zone_id" {
  description = <<-EOT
    Cloudflare zone id for domain_name. Empty disables Terraform management of
    DNS and zone settings, leaving them as dashboard state.

    The API token is NOT a variable: the provider reads CLOUDFLARE_API_TOKEN
    from the environment, so it never enters Terraform state or a plan file.
    The token needs Zone:Read, DNS:Edit, Zone Settings:Edit and, if rate
    limiting is enabled, Zone WAF:Edit -- on this zone only.
  EOT
  type        = string
  default     = ""
}

variable "manage_cloudflare" {
  description = <<-EOT
    Whether THIS root manages the Cloudflare zone.

    Both environments share one domain and therefore one zone, so exactly one of
    them may own the DNS records and zone settings.

    Dev owns the zone TODAY, because dev is what currently serves
    api.<domain> and rt.<domain>.
  EOT
  type        = bool
  default     = true
}

variable "alert_sms_numbers" {
  description = <<-EOT
    E.164 numbers for a SECOND alerting channel, e.g. ["+251911234567"].

    Empty means every alarm -- including "money owed to a player" -- reaches one
    email inbox and nothing else. See modules/monitoring/variables.tf for the
    SNS SMS caveats that are not visible from a clean apply.
  EOT
  type        = list(string)
  default     = []
}
