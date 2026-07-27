output "app_security_group_id" {
  description = "Security group for the application instance."
  value       = aws_security_group.app.id
}

output "rds_security_group_id" {
  description = "Security group for RDS."
  value       = aws_security_group.rds.id
}

output "cloudflare_ipv4_ranges" {
  description = "Cloudflare ranges currently admitted on 443."
  value       = local.cloudflare_ipv4
}

output "cloudflare_ipv4_count" {
  description = "Count of admitted Cloudflare ranges. Sanity-check this is ~15, never 0."
  value       = length(local.cloudflare_ipv4)
}
