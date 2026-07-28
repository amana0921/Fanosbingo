/**
 * Application configuration and secrets, in SSM Parameter Store.
 *
 * Parameter Store rather than Secrets Manager: both are KMS-encrypted,
 * IAM-controlled and CloudTrail-logged, but Standard-tier Parameter Store is
 * free where Secrets Manager is $0.40 per secret per month. The only feature we
 * give up is managed rotation, which none of these values use — a wallet key is
 * rotated by moving funds on chain, not by an AWS scheduler.
 *
 * SECRETS ARE NOT STORED IN TERRAFORM. Each SecureString is created with a
 * placeholder and `ignore_changes = [value]`. Real values are written
 * out-of-band with the AWS CLI. This keeps them out of Terraform state, which
 * is a plaintext JSON document in S3 and is only as protected as that bucket.
 *
 * To set one:
 *
 *   aws ssm put-parameter --name /<prefix>/telegram_bot_token \
 *     --type SecureString --key-id alias/<prefix>-main \
 *     --value 'REAL_VALUE' --overwrite
 */

locals {
  # Non-secret runtime configuration. Safe in state, safe in git.
  plain_parameters = merge(
    {
      # Two RPC endpoints so the deposit indexer can fail over. A single
      # provider going down or rate-limiting is the expected case, not the
      # exceptional one.
      "bsc/rpc_primary"   = var.bsc_rpc_primary
      "bsc/rpc_secondary" = var.bsc_rpc_secondary
      "bsc/chain_id"      = tostring(var.bsc_chain_id)

      # CORS. Every ported function must reject anything else — today all 25
      # send `Access-Control-Allow-Origin: *`, including the ones that move money.
      "app/allowed_origin" = "https://${var.domain_name}"
      "app/api_base_url"   = "https://api.${var.domain_name}"
    },
    var.extra_plain_parameters
  )

  # Secrets. Created empty; populated out-of-band.
  secret_parameters = [
    "telegram/bot_token",          # Telegram Bot API token
    "telegram/webhook_secret",     # X-Telegram-Bot-Api-Secret-Token, verified per request
    "app/jwt_secret",              # signs player JWTs; PostgREST and Realtime verify with it
    "app/admin_bootstrap_key",     # temporary, until Cognito lands in Phase 4
    "db/postgrest_password",       # authenticator role password
    "db/app_password",             # ticker + functions + realtime role password
    "realtime/secret_key_base",    # Phoenix session/cookie signing; 64 hex chars
    "realtime/db_enc_key",         # encrypts tenant credentials at rest; EXACTLY 16 chars
    "realtime/metrics_jwt_secret", # required from Realtime 2.120.0
    "tls/origin_cert",             # Cloudflare Origin Certificate (PEM), 15-year validity
    "tls/origin_key",              # its private key (PEM)
  ]
}

resource "aws_ssm_parameter" "plain" {
  for_each = local.plain_parameters

  name        = "/${var.name_prefix}/${each.key}"
  description = "Non-secret runtime configuration"
  type        = "String"
  value       = each.value
  tier        = "Standard"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# NOT DEFINED HERE: /<prefix>/images/<service>
#
# The image pointers are created and updated by the deploy workflow, and only
# READ by Terraform (modules/app_stack). Terraform does not own them at all, and
# that is deliberate rather than an omission.
#
# Declaring them here with a "none" placeholder was the obvious first design,
# and it is wrong in a way that only shows up once: an environment that already
# has services running has pointers that must be seeded from what is actually
# deployed, and a Terraform-managed resource cannot adopt a parameter that
# already exists without an import. Leaving ownership entirely with the pipeline
# removes the conflict -- `put-parameter --overwrite` creates or updates
# indifferently, and `aws_ssm_parameters_by_path` reads whatever is there,
# returning empty for an environment where nothing has been built yet.
#
# The dividing line is worth stating plainly: Terraform owns infrastructure,
# the pipeline owns which build is running. They are different lifecycles and
# they change at different rates.
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "secret" {
  for_each = toset(local.secret_parameters)

  name = "/${var.name_prefix}/${each.value}"
  # ASCII only, for consistency with the RDS constraint. SSM happens to accept
  # non-ASCII here, but relying on which AWS APIs are lenient is not a strategy.
  description = "Secret: real value set out-of-band, never through Terraform"
  type        = "SecureString"
  key_id      = var.kms_key_arn
  tier        = "Standard"

  # Deliberate placeholder. If you see this value in a running service, the
  # parameter was never populated.
  value = "PLACEHOLDER_SET_ME_OUT_OF_BAND"

  lifecycle {
    # Without this, every `terraform apply` would reset live secrets back to the
    # placeholder and take the service down.
    ignore_changes = [value]
  }

  tags = var.tags
}
