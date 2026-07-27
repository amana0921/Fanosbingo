output "parameter_path_prefix" {
  description = "SSM path prefix holding this environment's config and secrets."
  value       = "/${var.name_prefix}"
}

output "parameter_arn_wildcard" {
  description = "ARN pattern for IAM policies granting read access to this environment's parameters."
  value       = "arn:aws:ssm:*:*:parameter/${var.name_prefix}/*"
}

output "secret_parameter_names" {
  description = "Full names of every SecureString parameter that must be populated out-of-band before launch."
  value       = [for p in aws_ssm_parameter.secret : p.name]
}

output "plain_parameter_names" {
  description = "Full names of the non-secret parameters."
  value       = [for p in aws_ssm_parameter.plain : p.name]
}
