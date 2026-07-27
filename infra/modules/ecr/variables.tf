variable "name_prefix" {
  description = "Prefix applied to every repository name, e.g. fanosbingo-dev."
  type        = string
}

variable "repository_names" {
  description = <<-EOT
    Images we build. This includes postgrest and realtime, which are thin layers
    over the upstream images adding Amazon's RDS CA bundle -- without it a
    connection with sslmode=verify-full fails, and the alternative (sslmode=
    require) encrypts without verifying anything.
  EOT
  type        = list(string)
  default     = ["caddy", "functions", "postgrest", "realtime", "ticker"]
}

variable "keep_last_images" {
  description = "How many tagged images to retain per repository before expiry."
  type        = number
  default     = 10

  validation {
    condition     = var.keep_last_images >= 3
    error_message = "Keep at least 3 images so a rollback target always exists."
  }
}

variable "force_delete" {
  description = "Allow deleting a repository that still contains images. True in dev, false in prod."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every repository."
  type        = map(string)
  default     = {}
}
