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
    Requests per minute per source IP to the authentication and account-creation
    endpoints before blocking.

    Thirty, not ten, and the reason is the player base rather than the threat.

    The rule keys on ip.src. This game's players reach Telegram over Ethiopian
    mobile networks, where large numbers of subscribers share a small pool of
    carrier-NAT addresses -- so "one IP" here is not one person. At ten per
    minute, a busy evening on one carrier egress would start blocking players
    who have done nothing but open the app, and the symptom is a Mini App that
    fails to log in for some users and not others, with nothing in the origin
    logs because Cloudflare answered first.

    Thirty still stops a script cold: a real client calls /auth/telegram once per
    session, so thirty is roughly thirty distinct people behind one address in
    the same minute, and an attacker looking for volume needs orders of
    magnitude more than that to be worth their time.

    If this ever needs to be tight rather than generous, the fix is to stop
    keying on IP -- not to lower this number.
  EOT
  type        = number
  default     = 30
}

variable "enable_cache_bypass" {
  description = <<-EOT
    Create a cache rule that never caches api.<domain> or rt.<domain>.

    OFF by default. Cloudflare does not cache these responses today -- it caches
    by file extension for static assets, and the API paths have no cacheable
    extension and carry no Cache-Control from PostgREST. So this is defence in
    depth rather than a fix for a live problem, and it is worth landing as its
    own change with its own plan.
  EOT
  type        = bool
  default     = false
}
