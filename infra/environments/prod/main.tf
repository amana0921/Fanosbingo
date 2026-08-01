/**
 * Fanos Bingo — prod environment.
 *
 * This one holds real player balances and a funded hot wallet. Every setting
 * that differs from dev exists to make destruction hard and recovery possible:
 *
 *   - RDS deletion protection on, final snapshot required
 *   - No apply_immediately: schema-level changes wait for the maintenance window
 *   - 7-day PITR
 *   - 30-day KMS deletion window (deleting the signing key strands funds)
 *   - ECR force_delete off
 *   - BSC mainnet
 *
 * Applied only via the Terraform workflow, gated by the `prod` GitHub
 * Environment's required reviewers.
 */

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # S3 bucket names are globally unique across all AWS accounts.
  spa_bucket_name = "${local.name_prefix}-spa-${data.aws_caller_identity.current.account_id}"
}

module "vpc" {
  source = "../../modules/vpc"

  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
}

module "security_groups" {
  source = "../../modules/security_groups"

  name_prefix = local.name_prefix
  vpc_id      = module.vpc.vpc_id
}

module "kms" {
  source = "../../modules/kms"

  name_prefix = local.name_prefix

  # Full window. Deleting the wallet signing key means the funds only it can
  # move become permanently unreachable.
  deletion_window_in_days = 30
}

module "ssm" {
  source = "../../modules/ssm"

  name_prefix = local.name_prefix
  kms_key_arn = module.kms.main_key_arn
  domain_name = var.domain_name

  bsc_chain_id = var.bsc_chain_id
}

module "ecr" {
  source = "../../modules/ecr"

  name_prefix = local.name_prefix

  # Never silently discard prod images; keep enough history to roll back.
  force_delete     = false
  keep_last_images = 10
}

module "ecs" {
  source = "../../modules/ecs"

  name_prefix = local.name_prefix
  environment = var.environment

  subnet_ids            = [module.vpc.public_subnet_ids[0]]
  security_group_id     = module.security_groups.app_security_group_id
  instance_profile_name = module.iam.ec2_instance_profile_name
  kms_key_arn           = module.kms.main_key_arn

  # Pinned in ami.tf, bumped by pull request. See that file.
  ami_id = local.ecs_ami_id

  # Stage 2 upgrade: set instance_count = 2 and add subnet index 1. The ticker's
  # advisory lock already guarantees a single game-loop caller across instances.
  instance_count = 1
}

module "rds" {
  source = "../../modules/rds"

  name_prefix       = local.name_prefix
  subnet_ids        = module.vpc.isolated_subnet_ids
  security_group_id = module.security_groups.rds_security_group_id
  kms_key_arn       = module.kms.main_key_arn

  # Make accidental destruction of the balance ledger as hard as possible.
  deletion_protection = true
  skip_final_snapshot = false

  # Modifications wait for the maintenance window rather than interrupting play.
  apply_immediately = false

  backup_retention_period = 7

  # Stage 2 upgrade: multi_az = true (roughly doubles the instance cost).
  multi_az = false
}

module "iam" {
  source = "../../modules/iam"

  name_prefix = local.name_prefix
  environment = var.environment

  kms_key_arn            = module.kms.main_key_arn
  wallet_signing_key_arn = module.kms.wallet_signing_key_arn
  spa_bucket_name        = local.spa_bucket_name

  # This environment's master secret, by exact ARN. Sourced from the rds module
  # rather than pattern-matched, so the dev deploy role cannot request it.
  rds_master_secret_arn = module.rds.master_user_secret_arn

  github_repository           = var.github_repository
  create_github_oidc_provider = var.create_github_oidc_provider

  # ONE subject, and that is the entire point.
  #
  # Reaching this role requires declaring `environment: prod`, which puts the job
  # behind prod's required reviewers. That is the boundary between "a contributor
  # can break testnet" and "a contributor can touch real balances".
  #
  # `ref:refs/heads/main` USED TO BE HERE, and it silently dissolved that
  # boundary. A workflow_dispatch from main emits the subject
  # `repo:<owner>/<repo>:ref:refs/heads/main` regardless of whether the job
  # declares an environment -- so any workflow that built this role's ARN from an
  # input without declaring `environment:` reached prod with nobody asked to
  # approve. Two did: db-migrate.yml and verify.yml. Between them that is decrypt
  # of prod's whole SSM tree and a tunnel to the prod database as app_service,
  # which holds BYPASSRLS.
  #
  # The comment that used to sit here asserted the boundary held. It did not, and
  # the assertion is what stopped anyone checking -- the same failure shape
  # db/20-post/004 documents for a security statement that reports success and
  # changes nothing.
  #
  # Removing it costs nothing, because every legitimate consumer already declares
  # an environment: deploy-services, sync-secrets and db-restore-drill always
  # did, and db-migrate and verify now do. terraform.yml does not use this role
  # at all -- it uses the separate executor and planner roles.
  #
  # NO `pull_request` either, unlike dev.
  github_allowed_refs = ["environment:prod"]
}

# ---------------------------------------------------------------------------
# The application
#
# Identical to dev, by construction. Until this module existed prod defined no
# services at all: applying it produced a VPC, a database and an idle container
# instance, and the gap would only have been discovered on cutover night.
#
# No image_overrides here. Prod has never run, so there is no legacy GitHub
# variable to carry forward -- every service waits for the deploy workflow to
# write /fanosbingo-prod/images/<service> and is created on the next apply.
# ---------------------------------------------------------------------------
module "app_stack" {
  source = "../../modules/app_stack"

  name_prefix = local.name_prefix
  environment = var.environment
  aws_region  = var.aws_region
  domain_name = var.domain_name

  cluster_arn       = module.ecs.cluster_arn
  capacity_provider = module.ecs.capacity_provider_name
  log_group_name    = module.ecs.log_group_name

  db_host = module.rds.address
  db_port = module.rds.port
  db_name = module.rds.database_name

  task_execution_role_arn = module.iam.task_execution_role_arn
  task_ticker_role_arn    = module.iam.task_ticker_role_arn
  task_data_role_arn      = module.iam.task_data_role_arn
  task_functions_role_arn = module.iam.task_functions_role_arn
  wallet_signing_key_id   = module.kms.wallet_signing_key_id
  metric_namespace        = module.iam.metric_namespace

  # Must match what the ssm module publishes, and what the RPC actually serves.
  # The service checks the latter at startup and refuses to run on a mismatch.
  bsc_chain_id    = var.bsc_chain_id
  bsc_rpc_primary = "https://bsc-dataseed1.binance.org"
}

# ---------------------------------------------------------------------------
# Cloudflare
#
# The other half of the origin lock. sg-app admits 443 only from Cloudflare's
# ranges; this is what makes sure Cloudflare is actually in front, with strict
# TLS and the settings that a Telegram Mini App needs.
#
# Count-gated on the zone id so a contributor without a Cloudflare token can
# still plan and apply everything else. When it is off, those settings are
# dashboard state and scripts/verify-cloudflare.sh is the only thing checking
# them.
# ---------------------------------------------------------------------------
module "cloudflare" {
  source = "../../modules/cloudflare"

  count = var.manage_cloudflare && try(trimspace(var.cloudflare_zone_id), "") != "" ? 1 : 0

  zone_id     = var.cloudflare_zone_id
  domain_name = var.domain_name

  # Taken from the ecs module, not typed in: the records must point at the
  # address the instance actually claims on boot, and a stale literal here would
  # black-hole the whole site.
  origin_ip = module.ecs.public_ip
}

module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix = local.name_prefix
  environment = var.environment
  kms_key_arn = module.kms.main_key_arn

  # Must match the namespace the containers publish to, or the game-loop alarm
  # watches nothing. Sourced from iam rather than restated, so it cannot drift.
  metric_namespace = module.iam.metric_namespace

  alert_emails = var.alert_emails

  # Ceiling of $32 with alerts at $20 and $27, plus a forecast alert. On a
  # credit-based Free Tier plan, exhausting credits on a Free account plan
  # SUSPENDS resources — these alerts are the warning to switch to Paid.
  monthly_budget_usd   = 32
  alert_thresholds_usd = [20, 27]

  rds_instance_id          = module.rds.instance_id
  rds_allocated_storage_gb = 20
  autoscaling_group_name   = module.ecs.autoscaling_group_name
}
