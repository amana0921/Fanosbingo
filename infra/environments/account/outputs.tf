output "trail_arn" {
  description = "The account trail."
  value       = module.cloudtrail.trail_arn
}

output "audit_bucket" {
  description = "Durable audit record. Retained for a year, not force-destroyable."
  value       = module.cloudtrail.bucket_name
}

output "security_alerts_topic_arn" {
  description = "Where the detections report."
  value       = aws_sns_topic.security.arn
}

output "detections" {
  description = "Alarms watching the audit trail."
  value       = module.cloudtrail.detections
}

output "permitted_signing_roles" {
  description = "Roles excluded from the kms:Sign alarm. Anything else calling Sign pages."
  value       = module.cloudtrail.permitted_signing_roles
}

output "post_apply_checklist" {
  description = "What still needs a human after this applies."
  value = [
    "Confirm the SNS email subscription -- alarms are silent until you click the link.",
    "Verify the trail is logging: aws cloudtrail get-trail-status --name ${module.cloudtrail.trail_arn}",
    "Prove the detection works before trusting it. See scripts/verify-detections.sh.",
  ]
}
