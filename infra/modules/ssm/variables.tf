variable "name_prefix" {
  description = "Prefix applied to every parameter path, e.g. fanosbingo-dev."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK used to encrypt SecureString parameters."
  type        = string
}

variable "domain_name" {
  description = "Apex domain. Used to derive the CORS allowed origin and API base URL."
  type        = string
}

variable "bsc_rpc_primary" {
  description = "Primary BSC JSON-RPC endpoint for the deposit indexer."
  type        = string
  default     = "https://bsc-dataseed.binance.org"
}

variable "bsc_rpc_secondary" {
  description = "Fallback BSC JSON-RPC endpoint, used when the primary errors or rate-limits."
  type        = string
  default     = "https://bsc-dataseed1.defibit.io"
}

variable "bsc_chain_id" {
  description = "BSC chain id. 56 is mainnet, 97 is testnet. Dev should use 97."
  type        = number
  default     = 97

  validation {
    condition     = contains([56, 97], var.bsc_chain_id)
    error_message = "bsc_chain_id must be 56 (mainnet) or 97 (testnet)."
  }
}

variable "extra_plain_parameters" {
  description = "Additional non-secret parameters, as a map of relative path to value."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to every parameter."
  type        = map(string)
  default     = {}
}
