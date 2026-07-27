variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. fanosbingo-dev."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the VPC. Subnets are carved from this as /24s."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 8, 21))
    error_message = "vpc_cidr must be at least a /16 so the /24 subnet layout fits."
  }
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
