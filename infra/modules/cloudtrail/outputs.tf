output "trail_arn" {
  description = "ARN of the account trail."
  value       = aws_cloudtrail.this.arn
}

output "bucket_name" {
  description = "Bucket holding the durable audit record."
  value       = aws_s3_bucket.trail.id
}

output "log_group_name" {
  description = "CloudWatch log group the metric filters read."
  value       = aws_cloudwatch_log_group.trail.name
}

output "permitted_signing_roles" {
  description = "Role names excluded from the kms:Sign alarm."
  value       = var.permitted_signing_roles
}

output "detections" {
  description = "Alarms this module creates."
  value = [
    aws_cloudwatch_metric_alarm.unexpected_kms_sign.alarm_name,
    aws_cloudwatch_metric_alarm.root_account_used.alarm_name,
  ]
}
