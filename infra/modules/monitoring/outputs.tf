output "alerts_topic_arn" {
  description = "SNS topic every alarm and budget notification publishes to. Phase 3 alarms reuse it."
  value       = aws_sns_topic.alerts.arn
}

output "alerts_topic_name" {
  description = "SNS topic name."
  value       = aws_sns_topic.alerts.name
}

output "alarm_names" {
  description = "Baseline alarms created in Phase 1. Gameplay alarms are added in Phase 3."
  value = [
    aws_cloudwatch_metric_alarm.rds_free_storage.alarm_name,
    aws_cloudwatch_metric_alarm.rds_cpu_credits.alarm_name,
    aws_cloudwatch_metric_alarm.rds_cpu.alarm_name,
    aws_cloudwatch_metric_alarm.rds_connections.alarm_name,
    aws_cloudwatch_metric_alarm.ec2_status_check.alarm_name,
    aws_cloudwatch_metric_alarm.ec2_cpu_credits.alarm_name,
  ]
}

output "subscription_confirmation_required" {
  description = "Reminder: SNS email subscriptions deliver nothing until confirmed via the emailed link."
  value       = "Confirm SNS subscriptions for: ${join(", ", var.alert_emails)}"
}
