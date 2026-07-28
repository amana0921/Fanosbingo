/**
 * Fanos Bingo — dev environment.
 *
 * Dev is NOT always-on. Stand it up when you need to test a migration or a
 * risky change, then tear it down:
 *
 *   terraform apply
 *   ...test against BSC testnet...
 *   terraform destroy
 *
 * Idle cost after destroy is effectively zero. Leaving it running costs about
 * the same as prod (~$30/mo) and would double the budget.
 *
 * Modules are wired in here as each is built.
 * Current: vpc, security_groups, kms, ssm, iam.
 */

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Fallback image pins, used only where SSM has no pointer yet.
  #
  # These are the legacy TICKER_IMAGE/POSTGREST_IMAGE/... GitHub variables. They
  # exist so this environment keeps running across the switch to SSM-held image
  # pointers; once every service has deployed once, they can be deleted from the
  # repository settings and this map can go with them.
  #
  # An unset GitHub variable arrives as TF_VAR_x="" -- an EMPTY STRING, not null
  # -- so a bare `== null` check passes and Terraform goes on to register a task
  # definition with no image, failing with the distinctly unhelpful
  # "Container.image should not be null or empty". app_stack normalises empties,
  # so passing them straight through is safe.
  image_overrides = {
    ticker    = var.ticker_image
    postgrest = var.postgrest_image
    realtime  = var.realtime_image
    caddy     = var.caddy_image
  }

  # S3 bucket names are globally unique across all AWS accounts, so the account
  # id is appended. Computed here rather than in the s3_cloudfront module so the
  # iam module can scope the deploy role to it before that module exists.
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

  # Shorter window in dev so a torn-down environment does not leave keys
  # lingering for a month. Prod uses the full 30 days.
  deletion_window_in_days = 7
}

module "ssm" {
  source = "../../modules/ssm"

  name_prefix = local.name_prefix
  kms_key_arn = module.kms.main_key_arn
  domain_name = var.domain_name

  # Dev talks to BSC testnet. Nothing here should ever touch mainnet funds.
  bsc_chain_id      = 97
  bsc_rpc_primary   = "https://data-seed-prebsc-1-s1.binance.org:8545"
  bsc_rpc_secondary = "https://data-seed-prebsc-2-s1.binance.org:8545"
}

module "ecr" {
  source = "../../modules/ecr"

  name_prefix = local.name_prefix

  # Dev repositories go away with the environment.
  force_delete     = true
  keep_last_images = 5
}

module "ecs" {
  source = "../../modules/ecs"

  name_prefix = local.name_prefix
  environment = var.environment

  # Index 0 only — a single instance in a single AZ at this tier.
  subnet_ids            = [module.vpc.public_subnet_ids[0]]
  security_group_id     = module.security_groups.app_security_group_id
  instance_profile_name = module.iam.ec2_instance_profile_name
  kms_key_arn           = module.kms.main_key_arn

  # Pinned in ami.tf, bumped by pull request. See that file.
  ami_id = local.ecs_ami_id
}

module "rds" {
  source = "../../modules/rds"

  name_prefix       = local.name_prefix
  subnet_ids        = module.vpc.isolated_subnet_ids
  security_group_id = module.security_groups.rds_security_group_id
  kms_key_arn       = module.kms.main_key_arn

  # Dev is disposable: allow destroy without ceremony. Prod inverts all three.
  deletion_protection = false
  skip_final_snapshot = true
  apply_immediately   = true

  # Shorter retention in dev — PITR here is a convenience, not a safety net.
  backup_retention_period = 1
}

module "iam" {
  source = "../../modules/iam"

  name_prefix = local.name_prefix
  environment = var.environment

  kms_key_arn            = module.kms.main_key_arn
  wallet_signing_key_arn = module.kms.wallet_signing_key_arn
  spa_bucket_name        = local.spa_bucket_name

  github_repository = var.github_repository

  # The GitHub OIDC provider is account-wide. Dev creates it; prod reuses it by
  # setting create_github_oidc_provider = false and passing the ARN.
  create_github_oidc_provider = var.create_github_oidc_provider

  # Three contexts, and the third is a deliberate, bounded decision.
  #
  #   environment:dev       deploy-services, sync-secrets, the drill, ami-bump
  #   ref:refs/heads/main   anything dispatched from the default branch
  #   pull_request          the db-migrate DRY RUN on a pull request
  #
  # `pull_request` means PR-branch code can reach this role: it can read and
  # write dev's parameter tree and tunnel to the dev database. That is the cost
  # of dry-running a migration against a real database, the check is worth
  # having, and dev holds BSC testnet credentials by construction.
  #
  # It is emphatically NOT granted in prod, which is why this list is set per
  # environment rather than defaulted in the module.
  github_allowed_refs = ["environment:dev", "ref:refs/heads/main", "pull_request"]
}

# ---------------------------------------------------------------------------
# The application
#
# Every container is defined once, in modules/app_stack, and called identically
# by dev and prod. These blocks used to be inline here and simply absent from
# prod, which meant applying prod would have produced infrastructure with no
# application running on it.
#
# Which build runs is read from SSM (/fanosbingo-dev/images/<service>), written
# by the deploy workflow. The variables below only apply while an environment
# still predates that mechanism -- see modules/app_stack.
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

  image_overrides = local.image_overrides
}

# Address changes only. Without these, moving the service definitions into
# modules/app_stack would destroy and recreate all four running services --
# a real outage in exchange for a refactor nobody asked to be disruptive.
moved {
  from = module.service_ticker
  to   = module.app_stack.module.ticker
}

moved {
  from = module.service_postgrest
  to   = module.app_stack.module.postgrest
}

moved {
  from = module.service_realtime
  to   = module.app_stack.module.realtime
}

moved {
  from = module.service_caddy
  to   = module.app_stack.module.caddy
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

  # Dev should be near-free most of the time, since it only exists while you are
  # actively testing. A sustained spend here means you forgot to destroy it.
  monthly_budget_usd   = 10
  alert_thresholds_usd = [3, 6]

  rds_instance_id          = module.rds.instance_id
  rds_allocated_storage_gb = 20
  autoscaling_group_name   = module.ecs.autoscaling_group_name
}
