variable "name_prefix" {
  description = "Environment prefix, e.g. fanosbingo-dev."
  type        = string
}

variable "name" {
  description = "Short service name: ticker, postgrest, realtime, functions, caddy."
  type        = string
}

variable "cluster_arn" {
  description = "ECS cluster to run in."
  type        = string
}

variable "capacity_provider" {
  description = "Capacity provider name. Swapping this to FARGATE also requires network_mode = awsvpc."
  type        = string
}

variable "image" {
  description = "Full image reference. Tag by git SHA, never :latest -- the ECR repositories are IMMUTABLE."
  type        = string
}

variable "task_role_arn" {
  description = "Runtime role the container's own code assumes."
  type        = string
}

variable "execution_role_arn" {
  description = "Role the ECS agent uses to pull the image and fetch secrets."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group for container logs."
  type        = string
}

variable "network_mode" {
  description = <<-EOT
    bridge for most services, host for Caddy (which must own 443 on the host).

    NOT awsvpc: it allocates one ENI per task and a t4g.small supports three
    interfaces total, so five services would not fit.
  EOT
  type        = string
  default     = "bridge"

  validation {
    condition     = contains(["bridge", "host", "awsvpc"], var.network_mode)
    error_message = "network_mode must be bridge, host, or awsvpc."
  }
}

variable "cpu" {
  description = "CPU units (1024 = one vCPU). A soft share on EC2, not a hard cap."
  type        = number
  default     = 128
}

variable "memory_reservation" {
  description = <<-EOT
    Soft memory floor in MiB. Deliberately NOT a hard limit: on EC2 a hard limit
    OOM-kills the container even when the instance has free memory. The
    scheduler uses this to decide placement.
  EOT
  type        = number
  default     = 128
}

variable "desired_count" {
  description = "Task count. The ticker is safe at 2 thanks to its advisory lock."
  type        = number
  default     = 1
}

variable "environment_variables" {
  description = "Plain environment variables. Never put secrets here -- they are visible in the task definition."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = <<-EOT
    Map of environment variable name to SSM parameter path (leading slash
    included), e.g. { PGPASSWORD = "/fanosbingo-dev/db/app_password" }.

    Fetched by the ECS agent at container start using the execution role, so
    values never enter the task definition or Terraform state.
  EOT
  type        = map(string)
  default     = {}
}

variable "port_mappings" {
  description = "Static host port bindings. Static rather than dynamic so Caddy can address them at fixed 127.0.0.1 ports."
  type = list(object({
    container_port = number
    host_port      = number
  }))
  default = []
}

variable "command" {
  description = "Override the image CMD."
  type        = list(string)
  default     = null
}

variable "health_check" {
  description = "Container health check. Omit for services with nothing meaningful to probe."
  type = object({
    command      = list(string)
    interval     = number
    timeout      = number
    retries      = number
    start_period = number
  })
  default = null
}

variable "stop_timeout" {
  description = "Seconds between SIGTERM and SIGKILL. The ticker uses this window to release its advisory lock."
  type        = number
  default     = 30
}

variable "deployment_minimum_healthy_percent" {
  description = <<-EOT
    0 by default: with one instance and static host ports there is nowhere to
    place a replacement before the old task stops. Stage 2's second instance is
    what makes a genuinely zero-downtime roll possible.
  EOT
  type        = number
  default     = 0
}

variable "deployment_maximum_percent" {
  description = "100 so ECS stops the old task before starting the new one, freeing the static host port."
  type        = number
  default     = 100
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
