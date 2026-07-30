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

variable "rate_limit_requests_per_10s" {
  description = <<-EOT
    Requests per TEN SECONDS per source IP to the authentication and
    account-creation endpoints before blocking.

    Ten seconds, not a minute, because the free plan is entitled to exactly one
    period and that is it -- see the note on `period` in main.tf. The window is
    therefore short and bursty, which makes the value below more sensitive to
    get wrong than a per-minute figure would be.

    Twenty, and the reason is the player base rather than the threat.

    The rule keys on ip.src. This game's players reach Telegram over Ethiopian
    mobile networks, where large numbers of subscribers share a small pool of
    carrier-NAT addresses -- so "one IP" here is not one person. On a ten-second
    window a low value is easy to trip by accident: five would mean a sixth
    person opening the app in the same ten seconds behind one carrier egress
    gets blocked. The symptom is a Mini App that fails to log in for some users
    and not others, with nothing in the origin logs, because Cloudflare answered
    first.

    Twenty still caps any single address at two requests a second sustained. A
    real client calls /auth/telegram once per session, so this is generous for
    humans and a hard ceiling for a script.

    If this ever needs to be tight rather than generous, the fix is to stop
    keying on IP -- not to lower this number.
  EOT
  type        = number
  default     = 20
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
