variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. fanosbingo-dev."
  type        = string
}

variable "environment" {
  description = "Environment name. Used as the budget's cost-allocation tag filter."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting the SNS alert topic."
  type        = string
}

variable "alert_emails" {
  description = <<-EOT
    Addresses receiving budget and alarm notifications. Each must click the SNS
    confirmation email before anything is delivered — an unconfirmed
    subscription silently drops every alert.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "At least one alert email is required; alarms with no subscriber are worse than no alarms."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly budget ceiling for this environment, in USD."
  type        = number
  default     = 32
}

variable "alert_thresholds_usd" {
  description = <<-EOT
    Absolute spend levels that trigger an alert, in USD. Converted to
    percentages of monthly_budget_usd. Each must be below the ceiling.
  EOT
  type        = list(number)
  default     = [20, 27]

  validation {
    condition     = length(var.alert_thresholds_usd) > 0
    error_message = "Provide at least one alert threshold."
  }
}

variable "rds_instance_id" {
  description = "RDS instance identifier, for alarm dimensions."
  type        = string
}

variable "rds_allocated_storage_gb" {
  description = "RDS allocated storage in GiB, used to compute the 20% free-space threshold."
  type        = number
  default     = 20
}

variable "rds_max_connections_alarm" {
  description = <<-EOT
    Connection count that triggers an alarm. db.t4g.micro allows roughly 80-110
    depending on memory, so 60 leaves room to react before exhaustion.
  EOT
  type        = number
  default     = 60
}

variable "autoscaling_group_name" {
  description = "ASG name, for EC2 alarm dimensions."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
