/**
 * Cloudflare, in code.
 *
 * WHY THIS MATTERS MORE THAN IT LOOKS
 *
 * This stack has no ALB and no AWS WAF. That saves about $30/month and is only
 * safe because of two halves working together:
 *
 *   half one, in AWS   -- sg-app admits 443 solely from Cloudflare's published
 *                         ranges, so the origin cannot be reached directly
 *   half two, here     -- Cloudflare actually proxies the traffic, terminates
 *                         TLS strictly, and applies the rules
 *
 * Half one has been Terraform since day one. Half two was a list in a handover
 * document ending in "set these in the dashboard" -- three settings described as
 * "not optional", none of them versioned, reviewable, or detectable when
 * changed. A control that lives only in somebody's browser session regresses
 * quietly and is discovered during an incident.
 *
 * THE SETTINGS THAT ARE NOT PREFERENCES
 *
 *   SSL mode Full (strict)  Anything less either loops or sends plaintext to
 *                           the origin. "Flexible" in particular means
 *                           Cloudflare speaks HTTP to a server that only
 *                           listens on 443.
 *
 *   Proxied DNS records     A DNS-only (grey cloud) record resolves straight to
 *                           the Elastic IP, which the security group refuses.
 *                           The symptom is a timeout with no error anywhere --
 *                           no 403, no log line, nothing.
 *
 *   Bot Fight Mode OFF      It challenges non-browser clients. Telegram's
 *                           webhook caller and a WebSocket upgrade both look
 *                           exactly like that. Telegram does not solve
 *                           challenges: it retries, then DISABLES your webhook.
 *
 * Bot Fight Mode has no Terraform resource on the free plan, so it cannot be
 * enforced here -- it is asserted instead, by scripts/verify-cloudflare.sh,
 * which fails if it has been switched on.
 */

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# DNS
#
# Both records MUST be proxied. See the header.
# ---------------------------------------------------------------------------
resource "cloudflare_dns_record" "api" {
  zone_id = var.zone_id
  name    = "api.${var.domain_name}"
  type    = "A"
  content = var.origin_ip
  proxied = true

  # Cloudflare serves from its own cache and edge regardless; the origin TTL is
  # only what a DNS-only record would use. 1 means "automatic".
  ttl = 1

  comment = "Fanos Bingo API. Proxied: the origin security group admits Cloudflare ranges only."
}

resource "cloudflare_dns_record" "realtime" {
  zone_id = var.zone_id
  name    = "rt.${var.domain_name}"
  type    = "A"
  content = var.origin_ip
  proxied = true
  ttl     = 1

  comment = "Fanos Bingo Realtime websockets. Proxied: see api."
}

# ---------------------------------------------------------------------------
# Zone settings
#
# One resource per setting in provider v5, rather than the old
# zone_settings_override blob. More verbose, and better: a drifted setting shows
# up as one line in a plan instead of a diff against a map of thirty defaults.
# ---------------------------------------------------------------------------

# The load-bearing one. Full (strict) verifies the Cloudflare Origin Certificate
# that Caddy presents, which is what makes the hop from edge to origin
# trustworthy rather than merely encrypted.
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.zone_id
  setting_id = "ssl"
  value      = "strict"
}

# Reject anything below TLS 1.2 outright.
resource "cloudflare_zone_setting" "min_tls_version" {
  zone_id    = var.zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

resource "cloudflare_zone_setting" "tls_1_3" {
  zone_id    = var.zone_id
  setting_id = "tls_1_3"
  value      = "on"
}

# The API is called by a Telegram Mini App over HTTPS and by Telegram's webhook
# caller. There is no plaintext use case, so plaintext is not offered.
resource "cloudflare_zone_setting" "always_use_https" {
  zone_id    = var.zone_id
  setting_id = "always_use_https"
  value      = "on"
}

# Browser Integrity Check inspects headers and blocks obvious abuse. Unlike Bot
# Fight Mode it does not present a challenge, so Telegram's caller and WebSocket
# upgrades pass through it.
resource "cloudflare_zone_setting" "browser_check" {
  zone_id    = var.zone_id
  setting_id = "browser_check"
  value      = "on"
}

# An API and a WebSocket endpoint. Caching either would serve one player another
# player's game state.
resource "cloudflare_zone_setting" "cache_level" {
  zone_id    = var.zone_id
  setting_id = "cache_level"
  value      = "bypass"
}

# Realtime is WebSockets end to end. Without this the upgrade never completes.
resource "cloudflare_zone_setting" "websockets" {
  zone_id    = var.zone_id
  setting_id = "websockets"
  value      = "on"
}

# ---------------------------------------------------------------------------
# Rate limiting
#
# The free plan allows one rate-limiting rule, and this is the one worth
# spending it on: the endpoints that move money and mint sessions.
#
# Everything else in this system is naturally rate-limited by gameplay -- a
# player can only mark so many cells -- but a withdrawal or an auth attempt is
# worth hammering, and there is no WAF behind this to catch it.
# ---------------------------------------------------------------------------
resource "cloudflare_ruleset" "rate_limit" {
  count = var.enable_rate_limiting ? 1 : 0

  zone_id = var.zone_id
  name    = "fanosbingo-api-rate-limit"
  kind    = "zone"
  phase   = "http_ratelimit"

  rules = [{
    ref         = "money_and_auth_endpoints"
    description = "Throttle withdrawal, transfer and auth endpoints"
    expression  = "(http.host eq \"api.${var.domain_name}\" and (http.request.uri.path contains \"/functions/v1/process-withdrawal\" or http.request.uri.path contains \"/functions/v1/transfer-balance\" or http.request.uri.path contains \"/functions/v1/record-withdrawal\" or http.request.uri.path contains \"/functions/v1/auth\"))"
    action      = "block"

    ratelimit = {
      # Per source IP. Telegram Mini App traffic arrives from real client
      # addresses, so this is the right key.
      characteristics     = ["ip.src", "cf.colo.id"]
      period              = 60
      requests_per_period = var.rate_limit_requests_per_minute
      mitigation_timeout  = 600
    }
  }]
}
