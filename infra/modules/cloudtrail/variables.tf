variable "name_prefix" {
  description = "Name prefix for the trail and its bucket. Account-scoped, so no environment in it."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting the CloudWatch log group the trail delivers to."
  type        = string
}

variable "alerts_topic_arn" {
  description = "SNS topic the detections notify."
  type        = string
}

variable "permitted_signing_roles" {
  description = <<-EOT
    IAM role names allowed to call kms:Sign on the hot wallet. Every other
    principal calling it raises the alarm.

    Names, not ARNs: CloudTrail records the role name in
    userIdentity.sessionContext.sessionIssuer.userName.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.permitted_signing_roles) > 0
    error_message = "At least one role must be permitted, or the alarm fires on legitimate withdrawals."
  }
}

variable "metric_namespace" {
  description = "CloudWatch namespace for the metrics the log filters emit."
  type        = string
  default     = "FanosBingo/Security"
}

variable "retention_days" {
  description = "How long audit logs live in S3. A year is the usual floor for anything money-related."
  type        = number
  default     = 365
}

variable "cloudwatch_retention_days" {
  description = <<-EOT
    Retention for the CloudWatch mirror. Short on purpose: this copy exists so
    metric filters have something to read, not as the archive. S3 holds the
    durable record, and log ingestion is a real cost line at this budget.
  EOT
  type        = number
  default     = 14
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
