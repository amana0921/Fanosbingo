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

  # An unset GitHub variable arrives as TF_VAR_x="" -- an EMPTY STRING, not
  # null. A bare `== null` check therefore passes, and Terraform goes on to
  # register a task definition with no image, failing with the distinctly
  # unhelpful "Container.image should not be null or empty". Normalise here so
  # every service gate behaves the same way.
  ticker_image    = trimspace(coalesce(var.ticker_image, "")) == "" ? null : var.ticker_image
  postgrest_image = trimspace(coalesce(var.postgrest_image, "")) == "" ? null : var.postgrest_image

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

# ---------------------------------------------------------------------------
# Services
#
# The ticker is the game's heartbeat. It is intentionally the first service
# deployed: it has no ingress, no TLS and no dependency on Caddy, so it proves
# the container path (image pull, secret injection, logging, IAM) with the
# fewest moving parts.
#
# image is var-driven so CI can deploy a new git-SHA tag without a terraform
# apply. The service ignores task_definition changes for the same reason.
# ---------------------------------------------------------------------------
module "service_ticker" {
  source = "../../modules/ecs_service"

  # No image, no service. Creating a service that references an image which does
  # not exist yet produces one that can never start a task and retries forever.
  # Build and push first (deploy-services workflow), then set TICKER_IMAGE.
  count = local.ticker_image == null ? 0 : 1

  name_prefix       = local.name_prefix
  name              = "ticker"
  cluster_arn       = module.ecs.cluster_arn
  capacity_provider = module.ecs.capacity_provider_name
  log_group_name    = module.ecs.log_group_name

  image              = local.ticker_image
  task_role_arn      = module.iam.task_ticker_role_arn
  execution_role_arn = module.iam.task_execution_role_arn

  # No ports: the ticker talks only to the database.
  network_mode       = "bridge"
  cpu                = 128
  memory_reservation = 160

  environment_variables = {
    ENVIRONMENT      = var.environment
    AWS_REGION       = var.aws_region
    METRIC_NAMESPACE = module.iam.metric_namespace
    PGHOST           = module.rds.address
    PGPORT           = tostring(module.rds.port)
    PGDATABASE       = module.rds.database_name
    PGUSER           = "app_service"
    PGSSLMODE        = "require"
    TICK_INTERVAL_MS = "1000"
    CALL_INTERVAL_MS = "3500"
  }

  # Fetched by the ECS agent at container start. Never in the task definition,
  # never in Terraform state.
  secrets = {
    PGPASSWORD = "/${local.name_prefix}/db/app_password"
  }

  # Long enough for the shutdown handler to release the advisory lock, so a
  # standby takes over in milliseconds rather than waiting for the connection
  # to be reaped.
  stop_timeout = 30
}

# PostgREST: the data API.
#
# This is what makes the migration tractable. The SPA's ~200 supabase.from()
# call sites and all 47 RLS policies work against it unchanged, because it IS
# the same component Supabase runs. Rewriting those call sites against API
# Gateway + Lambda would have been weeks of work and would have thrown away RLS
# as the authorization layer.
module "service_postgrest" {
  source = "../../modules/ecs_service"

  count = local.postgrest_image == null ? 0 : 1

  name_prefix       = local.name_prefix
  name              = "postgrest"
  cluster_arn       = module.ecs.cluster_arn
  capacity_provider = module.ecs.capacity_provider_name
  log_group_name    = module.ecs.log_group_name

  image              = local.postgrest_image
  task_role_arn      = module.iam.task_data_role_arn
  execution_role_arn = module.iam.task_execution_role_arn

  # Static host port so Caddy can proxy to a fixed 127.0.0.1:3000.
  network_mode = "bridge"
  port_mappings = [{
    container_port = 3000
    host_port      = 3000
  }]

  cpu                = 128
  memory_reservation = 96

  environment_variables = {
    # libpq keyword form rather than a URI, so the password can come from
    # PGPASSWORD instead of being embedded in a connection string that would
    # then have to live in SSM as one blob.
    PGRST_DB_URI = join(" ", [
      "host=${module.rds.address}",
      "port=${module.rds.port}",
      "dbname=${module.rds.database_name}",
      "user=authenticator",
      "sslmode=verify-full",
      "sslrootcert=/opt/rds-global-bundle.pem",
    ])

    PGRST_DB_SCHEMAS = "public"

    # Requests with no JWT act as `anon`; RLS policies decide what that can see.
    PGRST_DB_ANON_ROLE = "anon"

    PGRST_SERVER_PORT = "3000"
    PGRST_DB_POOL     = "10"

    # Puts the verified JWT payload into the request.jwt.claims GUC, which is
    # exactly what the auth.uid() shim in db/00-bootstrap reads. Without it the
    # 9 RLS policies referencing auth.uid() silently match nothing.
    PGRST_DB_USE_LEGACY_GUCS = "false"

    PGRST_LOG_LEVEL = "info"
  }

  secrets = {
    # authenticator's password. libpq reads PGPASSWORD.
    PGPASSWORD = "/${local.name_prefix}/db/postgrest_password"
    # Must match whatever mints player JWTs, or every authenticated request 401s.
    PGRST_JWT_SECRET = "/${local.name_prefix}/app/jwt_secret"
  }

  # No container health check.
  #
  # It previously shelled out to wget, which this image may not ship. A health
  # check whose binary is missing does not fail loudly -- the container reports
  # UNKNOWN forever and the ECS deployment sits at IN_PROGRESS indefinitely,
  # which reads like a slow rollout rather than a broken probe.
  #
  # Caddy will health-check the upstream once it fronts this service, which is
  # the right layer for it: it tests the path traffic actually takes.
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
