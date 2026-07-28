variable "aws_region" {
  description = "Region the trail and its log group live in. The trail itself is multi-region regardless."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project slug. Used bare here, with no environment suffix, because these resources are account-wide."
  type        = string
  default     = "fanosbingo"
}

variable "environments" {
  description = <<-EOT
    Environments whose task roles are permitted to sign withdrawals. Listed
    ahead of their existence on purpose: a role that has not been created yet
    never appears in CloudTrail, so pre-listing it costs nothing and means
    standing up prod does not also require editing this root.
  EOT
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "github_repository" {
  description = "owner/name, recorded as a tag so every resource says where it came from."
  type        = string
  default     = "amana0921/Fanosbingo"
}

variable "alert_emails" {
  description = <<-EOT
    Recipients for security alarms. Each address must click the SNS confirmation
    link before anything is delivered.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "At least one address, or the detections have nowhere to report to."
  }
}
