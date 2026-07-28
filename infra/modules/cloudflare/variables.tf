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
    Create the rate-limiting ruleset. The free plan allows exactly one rule per
    zone, so if the zone already has one defined elsewhere, this will conflict.
  EOT
  type        = bool
  default     = true
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
