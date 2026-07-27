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
}

module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix = local.name_prefix
  environment = var.environment
  kms_key_arn = module.kms.main_key_arn

  alert_emails = var.alert_emails

  # Dev should be near-free most of the time, since it only exists while you are
  # actively testing. A sustained spend here means you forgot to destroy it.
  monthly_budget_usd   = 10
  alert_thresholds_usd = [3, 6]

  rds_instance_id          = module.rds.instance_id
  rds_allocated_storage_gb = 20
  autoscaling_group_name   = module.ecs.autoscaling_group_name
}
