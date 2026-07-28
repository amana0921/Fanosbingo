variable "zone_id" {
  description = "Cloudflare zone id for the apex domain."
  type        = string
}

variable "domain_name" {
  description = "Apex domain. api.<this> and rt.<this> are created."
  type        = string
}

variable "origin_ip" {
  description = <<-EOT
    Elastic IP of the container instance. Sourced from the ecs module rather
    than typed in, so it cannot drift from the address the instance actually
    claims on boot.
  EOT
  type        = string
}

variable "enable_rate_limiting" {
  description = <<-EOT
    Create the rate-limiting ruleset.

    OFF by default, deliberately. The free plan allows exactly ONE rate-limiting
    rule per zone, so if the zone already has one -- created in the dashboard,
    perhaps years ago and forgotten -- the first apply conflicts, and it does so
    partway through a change that is also adopting DNS records.

    Bring the zone under Terraform first, confirm DNS and the settings converge,
    then turn this on as its own change with its own plan to read.
  EOT
  type        = bool
  default     = false
}

variable "rate_limit_requests_per_minute" {
  description = <<-EOT
    Requests per minute per source IP to the money-moving and auth endpoints
    before blocking.

    Ten is generous for a human: withdrawing is a deliberate act, not something
    done in a loop. It is restrictive for a script.
  EOT
  type        = number
  default     = 10
}
