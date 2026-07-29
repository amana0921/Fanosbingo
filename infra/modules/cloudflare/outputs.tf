output "api_hostname" {
  description = "Proxied API hostname."
  value       = cloudflare_dns_record.api.name
}

output "app_hostname" {
  description = "The Mini App URL. This is what goes into BotFather."
  value       = cloudflare_dns_record.app.name
}

output "realtime_hostname" {
  description = "Proxied Realtime hostname."
  value       = cloudflare_dns_record.realtime.name
}

output "managed_settings" {
  description = <<-EOT
    Zone settings held in code. Anything not listed is still dashboard state --
    including cache behaviour, which is a cache RULE rather than a zone setting
    (see the comment in main.tf) and Bot Fight Mode, which has no free-plan
    resource and is asserted by scripts/verify-cloudflare.sh instead.
  EOT
  value = {
    ssl              = cloudflare_zone_setting.ssl.value
    min_tls_version  = cloudflare_zone_setting.min_tls_version.value
    tls_1_3          = cloudflare_zone_setting.tls_1_3.value
    always_use_https = cloudflare_zone_setting.always_use_https.value
    browser_check    = cloudflare_zone_setting.browser_check.value
    websockets       = cloudflare_zone_setting.websockets.value
  }
}
