variable "name_prefix" {
  description = "Resource name prefix, e.g. fanosbingo-dev."
  type        = string
}

variable "environment" {
  description = "dev or prod."
  type        = string
}

variable "aws_region" {
  description = "Region, passed to containers that call the AWS API."
  type        = string
}

variable "domain_name" {
  description = "Apex domain. Used for TLS host matching and the CORS origin."
  type        = string
}

# --- cluster ---------------------------------------------------------------

variable "cluster_arn" {
  description = "ECS cluster to run in."
  type        = string
}

variable "capacity_provider" {
  description = "Capacity provider backing the cluster."
  type        = string
}

variable "log_group_name" {
  description = "CloudWatch log group every container writes to."
  type        = string
}

# --- database --------------------------------------------------------------

variable "db_host" {
  description = "RDS endpoint address."
  type        = string
}

variable "db_port" {
  description = "RDS port."
  type        = number
}

variable "db_name" {
  description = "Database name."
  type        = string
}

# --- identities ------------------------------------------------------------

variable "task_execution_role_arn" {
  description = "Shared execution role: pulls images and injects secrets at container start."
  type        = string
}

variable "task_ticker_role_arn" {
  description = "Runtime role for the ticker."
  type        = string
}

variable "task_data_role_arn" {
  description = "Runtime role for PostgREST, Realtime and Caddy."
  type        = string
}

variable "task_functions_role_arn" {
  description = "Runtime role for the functions container. The only principal permitted to sign withdrawals."
  type        = string
}

variable "wallet_signing_key_id" {
  description = "KMS key id the functions container signs BSC withdrawals with."
  type        = string
}

variable "metric_namespace" {
  description = "CloudWatch namespace the containers publish custom metrics to."
  type        = string
}

# --- images ----------------------------------------------------------------

variable "image_overrides" {
  description = <<-EOT
    Per-service image URIs that apply ONLY when SSM has no pointer for that
    service. The normal path is the deploy workflow writing
    /<prefix>/images/<service>; this exists so an environment that predates that
    mechanism keeps running until its first deploy populates SSM, and as a
    break-glass pin during an incident.

    Keys: ticker, postgrest, realtime, caddy, functions.
  EOT
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "bsc_chain_id" {
  description = <<-EOT
    Chain the functions service signs for. THE authoritative source.

    Not the settings table: that is application data, writable by application
    code, and a signature commits to whatever chain id it was given. Dev
    currently has settings.deposit_contract_chain_id = 56 (mainnet) while the
    environment is testnet, which is exactly the contradiction this variable
    exists to end.

    The service verifies this against the RPC at startup and refuses to run on a
    mismatch.
  EOT
  type        = number
}

variable "bsc_rpc_primary" {
  description = "RPC endpoint. Checked at startup to confirm it serves bsc_chain_id."
  type        = string
}

variable "alerts_topic_arn" {
  description = <<-EOT
    SNS topic the alarms publish to. The functions service uses it as an
    ALLOWLIST on /alerts/sns: a valid Amazon signature only proves AWS sent a
    message, not that it is ours, so the topic arn is what establishes that.

    Empty disables forwarding without disabling the route. The route must keep
    existing whenever SNS is subscribed to it -- SNS confirms a subscription by
    calling the endpoint, so a 404 there leaves the channel permanently
    unconfirmed.
  EOT
  type        = string
  default     = ""
}

variable "telegram_alert_chat_id" {
  description = <<-EOT
    Chat the operator receives alarms in. Get it by messaging the bot and
    reading `chat.id` from getUpdates.

    A PLAIN environment variable, not an SSM secret, and the distinction is
    load-bearing: ECS resolves secrets at container start and FAILS THE TASK if
    a parameter is absent. Wiring an optional value through SSM would mean an
    unset chat id takes down the whole functions service -- trading a missing
    alert for an outage. It is also not a credential; the bot token is, and a
    chat id without it does nothing.

    Empty means alerts are accepted and verified but not forwarded, which is
    logged rather than silent.
  EOT
  type        = string
  default     = ""
}
