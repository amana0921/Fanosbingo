variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. fanosbingo-dev."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
