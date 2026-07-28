output "api_hostname" {
  description = "Proxied API hostname."
  value       = cloudflare_dns_record.api.name
}

output "realtime_hostname" {
  description = "Proxied Realtime hostname."
  value       = cloudflare_dns_record.realtime.name
}

output "managed_settings" {
  description = "Zone settings held in code. Anything not listed is still dashboard state."
  value = {
    ssl              = cloudflare_zone_setting.ssl.value
    min_tls_version  = cloudflare_zone_setting.min_tls_version.value
    tls_1_3          = cloudflare_zone_setting.tls_1_3.value
    always_use_https = cloudflare_zone_setting.always_use_https.value
    browser_check    = cloudflare_zone_setting.browser_check.value
    cache_level      = cloudflare_zone_setting.cache_level.value
    websockets       = cloudflare_zone_setting.websockets.value
  }
}
