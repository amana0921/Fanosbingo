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

variable "monthly_account_budget_usd" {
  description = <<-EOT
    Ceiling for the WHOLE account, untagged and unfiltered.

    Deliberately above the sum of the per-environment budgets (dev $10, prod
    $32), because it also covers what a tag filter structurally cannot see:
    data transfer, KMS requests, the CloudTrail and Terraform state buckets, and
    anything created outside Terraform. Set so that crossing it means something
    is genuinely wrong, not that both environments are merely running.
  EOT
  type        = number
  default     = 50
}

variable "account_alert_thresholds_usd" {
  description = <<-EOT
    Absolute dollar amounts at which to notify, expressed against
    monthly_account_budget_usd. Two is enough: one that means "look at this
    week", one that means "act today".
  EOT
  type        = list(number)
  default     = [30, 42]

  validation {
    condition     = length(var.account_alert_thresholds_usd) > 0
    error_message = "At least one threshold, or the budget only ever reports after the fact."
  }
}
