output "instance_id" {
  description = "RDS instance identifier."
  value       = aws_db_instance.this.identifier
}

output "instance_arn" {
  description = "RDS instance ARN, for CloudWatch alarm dimensions and IAM policies."
  value       = aws_db_instance.this.arn
}

output "endpoint" {
  description = "Connection endpoint, host:port."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "Hostname only."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Port."
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "Initial database name."
  value       = aws_db_instance.this.db_name
}

output "master_username" {
  description = "Master username."
  value       = aws_db_instance.this.username
}

output "master_user_secret_arn" {
  description = <<-EOT
    Secrets Manager secret holding the RDS-managed master password. Read it with:
      aws secretsmanager get-secret-value --secret-id <this> --query SecretString
    The password never passes through Terraform state.
  EOT
  value       = try(aws_db_instance.this.master_user_secret[0].secret_arn, null)
}

output "parameter_group_name" {
  description = "Parameter group name. Changes to static parameters need a reboot to apply."
  value       = aws_db_parameter_group.this.name
}

output "resource_id" {
  description = "DbiResourceId, used to build IAM database authentication policies."
  value       = aws_db_instance.this.resource_id
}
