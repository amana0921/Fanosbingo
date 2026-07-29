/**
 * The application: every long-running container, in one place.
 *
 * This module exists because dev and prod were drifting. The five service
 * definitions used to live inline in infra/environments/dev/main.tf, and prod
 * simply did not have them -- so `terraform apply` against prod would have
 * produced a VPC, a database and an idle container instance with no application
 * on it. Defining them once and calling the module from both roots makes that
 * class of divergence impossible rather than merely unlikely.
 *
 * WHERE IMAGE TAGS COME FROM
 *
 * Not from Terraform, and no longer from a GitHub variable somebody remembers
 * to update.
 *
 * Each service has an SSM parameter at /<prefix>/images/<service> holding the
 * image URI that should be running. The deploy workflow writes it immediately
 * after a successful push; Terraform reads it to decide whether the service can
 * exist at all. A service whose parameter is absent or still "none" has never
 * been built, so it is not created -- an ECS service pointing at an image that
 * does not exist retries forever without ever saying why.
 *
 * The parameters are read with aws_ssm_parameters_by_path rather than one
 * aws_ssm_parameter per service, deliberately: the plural data source returns an
 * empty result for a path with nothing under it, where the singular one fails
 * the whole plan. A fresh environment must be able to plan before anything has
 * ever been deployed into it.
 *
 * image_overrides is the escape hatch and the migration path. A value passed
 * there wins only when SSM has nothing to say, which is what lets an environment
 * that predates this module keep running until its first deploy populates SSM.
 */

locals {
  service_names = ["ticker", "postgrest", "realtime", "caddy", "functions"]

  # Values are returned positionally alongside names, so zipmap reassembles the
  # map. A parameter still holding "none" is treated as absent: that is the value
  # bootstrap writes, and it means "nothing has been built for this service yet".
  ssm_images = {
    for name, value in zipmap(
      data.aws_ssm_parameters_by_path.images.names,
      nonsensitive(data.aws_ssm_parameters_by_path.images.values)
    ) :
    basename(name) => trimspace(value)
    if trimspace(value) != "" && trimspace(value) != "none"
  }

  # An unset GitHub variable arrives as TF_VAR_x="" -- an empty string, not null
  # -- so a bare `== null` check passes and Terraform goes on to register a task
  # definition with no image. Normalise both sources the same way.
  #
  # try(trimspace(x), "") rather than coalesce(): coalesce SKIPS empty strings,
  # so coalesce("", "") has no valid argument and raises. try() covers both the
  # empty string and the null, because trimspace(null) raises and yields "".
  overrides = {
    for name, value in var.image_overrides :
    name => try(trimspace(value), "")
    if try(trimspace(value), "") != ""
  }

  images = {
    for name in local.service_names :
    name => try(local.ssm_images[name], try(local.overrides[name], null))
  }
}

# Returns an empty result rather than failing when nothing has been deployed
# into this environment yet. See the header comment.
data "aws_ssm_parameters_by_path" "images" {
  path = "/${var.name_prefix}/images"
}

# ---------------------------------------------------------------------------
# ticker -- the game's heartbeat
#
# Deployed first of the five: no ingress, no TLS, no dependency on Caddy, so it
# proves the whole container path (image pull, secret injection, logging, IAM)
# with the fewest moving parts.
#
# It talks only to the database, so it has no port mapping at all.
# ---------------------------------------------------------------------------
module "ticker" {
  source = "../ecs_service"

  count = local.images["ticker"] == null ? 0 : 1

  name_prefix       = var.name_prefix
  name              = "ticker"
  cluster_arn       = var.cluster_arn
  capacity_provider = var.capacity_provider
  log_group_name    = var.log_group_name

  image              = local.images["ticker"]
  task_role_arn      = var.task_ticker_role_arn
  execution_role_arn = var.task_execution_role_arn

  network_mode       = "bridge"
  cpu                = 128
  memory_reservation = 160

  environment_variables = {
    ENVIRONMENT      = var.environment
    AWS_REGION       = var.aws_region
    METRIC_NAMESPACE = var.metric_namespace
    PGHOST           = var.db_host
    PGPORT           = tostring(var.db_port)
    PGDATABASE       = var.db_name
    PGUSER           = "app_service"
    PGSSLMODE        = "require"
    TICK_INTERVAL_MS = "1000"
    CALL_INTERVAL_MS = "3500"
  }

  # Fetched by the ECS agent at container start. Never in the task definition,
  # never in Terraform state.
  secrets = {
    PGPASSWORD = "/${var.name_prefix}/db/app_password"
  }

  # Long enough for the shutdown handler to release the advisory lock, so a
  # standby takes over in milliseconds rather than waiting for the connection to
  # be reaped.
  stop_timeout = 30
}

# ---------------------------------------------------------------------------
# postgrest -- the data API
#
# This is what makes the migration tractable. The SPA's ~200 supabase.from()
# call sites and all 47 RLS policies work against it unchanged, because it IS
# the same component Supabase runs. Rewriting those call sites against API
# Gateway + Lambda would have been weeks of work and would have discarded RLS as
# the authorization layer.
# ---------------------------------------------------------------------------
module "postgrest" {
  source = "../ecs_service"

  count = local.images["postgrest"] == null ? 0 : 1

  name_prefix       = var.name_prefix
  name              = "postgrest"
  cluster_arn       = var.cluster_arn
  capacity_provider = var.capacity_provider
  log_group_name    = var.log_group_name

  image              = local.images["postgrest"]
  task_role_arn      = var.task_data_role_arn
  execution_role_arn = var.task_execution_role_arn

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
      "host=${var.db_host}",
      "port=${var.db_port}",
      "dbname=${var.db_name}",
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
    PGPASSWORD = "/${var.name_prefix}/db/postgrest_password"
    # Must match whatever mints player JWTs, or every authenticated request 401s.
    PGRST_JWT_SECRET = "/${var.name_prefix}/app/jwt_secret"
  }

  # No container health check.
  #
  # It previously shelled out to wget, which this image may not ship. A health
  # check whose binary is missing does not fail loudly -- the container reports
  # UNKNOWN forever and the ECS deployment sits at IN_PROGRESS indefinitely,
  # which reads like a slow rollout rather than a broken probe. Caddy health
  # checks this upstream instead, which tests the path traffic actually takes.
}

# ---------------------------------------------------------------------------
# realtime -- live game updates
#
# Self-hosting the same component Supabase runs means all 10 postgres_changes
# subscription sites in the SPA work unchanged. Rebuilding this on AppSync or
# API Gateway WebSockets would mean reimplementing RLS-aware row-change fan-out,
# which is the genuinely hard part.
#
# Everything below was established by running the real image against a local
# PostgreSQL, because none of it is guessable:
#
#   * The _realtime schema must EXIST BEFORE the container starts, or it dies
#     with "no schema has been selected to create in". It cannot create the
#     schema itself -- the failing statement is the creation of its own
#     migration-tracking table. Handled in db/00-bootstrap.
#
#   * ECTO_IPV6 and ERL_AFLAGS are baked into the image as IPv6. In an IPv4-only
#     VPC that fails to connect, so both are overridden here.
#
#   * Tenant resolution is by HOST SUBDOMAIN. A request arriving as Host: <ip>
#     gets 403; Host: realtime-dev.<anything> gets 101 Switching Protocols.
#     Caddy must rewrite the Host header.
#
#   * The websocket path is /socket/websocket, NOT /realtime/v1/websocket.
#     Supabase's own gateway strips that prefix; ours must too.
#
# On TLS: an earlier revision pinned 2.34.47, which has NO TLS support for its
# database connection, and concluded that rds.force_ssl would have to be turned
# off. That was the wrong trade -- it would have weakened every connection to the
# database for the sake of one client. 2.120.0 adds DB_SSL and DB_SSL_CA_CERT, so
# enforcement stays on and this connection is verified against Amazon's CA,
# matching postgrest and ticker.
# ---------------------------------------------------------------------------
module "realtime" {
  source = "../ecs_service"

  count = local.images["realtime"] == null ? 0 : 1

  name_prefix       = var.name_prefix
  name              = "realtime"
  cluster_arn       = var.cluster_arn
  capacity_provider = var.capacity_provider
  log_group_name    = var.log_group_name

  image              = local.images["realtime"]
  task_role_arn      = var.task_data_role_arn
  execution_role_arn = var.task_execution_role_arn

  network_mode = "bridge"
  port_mappings = [{
    container_port = 4000
    host_port      = 4000
  }]

  # The BEAM VM is the memory-hungry container in this stack; the other four
  # together use less.
  cpu                = 256
  memory_reservation = 420

  environment_variables = {
    PORT     = "4000"
    APP_NAME = "realtime"

    DB_HOST = var.db_host
    DB_PORT = tostring(var.db_port)
    DB_NAME = var.db_name
    DB_USER = "app_service"

    # Points Ecto at Realtime's own schema. The schema must already exist.
    DB_AFTER_CONNECT_QUERY = "SET search_path TO _realtime"

    # The image defaults to IPv6 for both the database connection and Erlang
    # distribution. Neither works in an IPv4-only VPC.
    ECTO_IPV6     = "false"
    DB_IP_VERSION = "ipv4"
    ERL_AFLAGS    = "-proto_dist inet_tcp"
    DNS_NODES     = "''"

    # Creates the default tenant on first boot, which is what makes the
    # websocket handshake resolvable at all.
    SEED_SELF_HOST = "true"
    RUN_JANITOR    = "true"
    RLIMIT_NOFILE  = "10000"

    # Keeps replication slot names distinct per environment, so dev and prod can
    # never collide on a shared database during a migration or restore.
    SLOT_NAME_SUFFIX = var.environment

    DB_POOL_SIZE = "5"

    # RDS PostgreSQL 15+ ships rds.force_ssl=1 as the ENGINE DEFAULT, so the
    # database refuses an unencrypted connection outright:
    #   FATAL 28000 no pg_hba.conf entry for host ... no encryption
    #
    # DB_SSL_CA_CERT is a FILE PATH (Erlang :cacertfile). Without it, DB_SSL
    # alone falls back to verify: :verify_none -- encrypted but unverified -- so
    # supplying the path is what makes verification actually happen.
    DB_SSL         = "true"
    DB_SSL_CA_CERT = "/opt/rds-global-bundle.pem"
  }

  secrets = {
    DB_PASSWORD     = "/${var.name_prefix}/db/app_password"
    SECRET_KEY_BASE = "/${var.name_prefix}/realtime/secret_key_base"
    DB_ENC_KEY      = "/${var.name_prefix}/realtime/db_enc_key"
    # Must match the secret PostgREST verifies with, or a token accepted by the
    # data API is rejected by the realtime channel and vice versa.
    API_JWT_SECRET = "/${var.name_prefix}/app/jwt_secret"
    # Newly REQUIRED in 2.120.0: without it the VM terminates during boot with a
    # System.EnvError rather than a readable message.
    METRICS_JWT_SECRET = "/${var.name_prefix}/realtime/metrics_jwt_secret"
  }

  # Realtime runs its Ecto migrations on boot, which takes a few seconds.
  stop_timeout = 30
}

# ---------------------------------------------------------------------------
# functions -- the ported edge functions
#
# Not built yet (Phase 3's remaining work), so this block is inert until an
# image lands in SSM. It is defined here rather than left for later because
# wiring a service is exactly the kind of step that gets done differently in
# each environment when it is done twice.
#
# Caddy already routes /functions/v1/* to 127.0.0.1:8080, so nothing downstream
# needs to change when this starts running.
#
# This is the ONLY task role permitted to call kms:Sign, which is what makes the
# CloudTrail alarm on signing by any other principal a real signal.
#
# The variable names below follow what the Deno handlers read today
# (supabase/functions/*/index.ts). Confirm them against the port as it lands.
# ---------------------------------------------------------------------------
module "functions" {
  source = "../ecs_service"

  count = local.images["functions"] == null ? 0 : 1

  name_prefix       = var.name_prefix
  name              = "functions"
  cluster_arn       = var.cluster_arn
  capacity_provider = var.capacity_provider
  log_group_name    = var.log_group_name

  image              = local.images["functions"]
  task_role_arn      = var.task_functions_role_arn
  execution_role_arn = var.task_execution_role_arn

  network_mode = "bridge"
  port_mappings = [{
    container_port = 8080
    host_port      = 8080
  }]

  cpu                = 192
  memory_reservation = 256

  environment_variables = {
    ENVIRONMENT      = var.environment
    AWS_REGION       = var.aws_region
    METRIC_NAMESPACE = var.metric_namespace
    PORT             = "8080"

    PGHOST        = var.db_host
    PGPORT        = tostring(var.db_port)
    PGDATABASE    = var.db_name
    PGUSER        = "app_service"
    PGSSLMODE     = "verify-full"
    PGSSLROOTCERT = "/opt/rds-global-bundle.pem"

    # Withdrawals are signed by KMS, never by a private key read from the
    # settings table. That is the structural fix for how the original hot-wallet
    # key leaked -- there is no plaintext copy to steal.
    WALLET_SIGNING_KEY_ID = var.wallet_signing_key_id

    # Lock CORS to the app's own origin. Today all 25 Deno handlers send
    # Access-Control-Allow-Origin: *, including the ones that move money.
    ALLOWED_ORIGIN = "https://${var.domain_name}"
    API_BASE_URL   = "https://api.${var.domain_name}"
    POSTGREST_URL  = "http://127.0.0.1:3000"

    # Chain identity comes from HERE -- infrastructure config Terraform owns per
    # environment -- and never from the settings table, which application code
    # can write. A signature commits to a chain id, so a value of 56 produces a
    # valid BSC mainnet transaction wherever it was made. The service verifies
    # this against the RPC at startup and refuses to run on a mismatch.
    BSC_CHAIN_ID    = tostring(var.bsc_chain_id)
    BSC_RPC_PRIMARY = var.bsc_rpc_primary
  }

  secrets = {
    PGPASSWORD              = "/${var.name_prefix}/db/app_password"
    JWT_SECRET              = "/${var.name_prefix}/app/jwt_secret"
    TELEGRAM_BOT_TOKEN      = "/${var.name_prefix}/telegram/bot_token"
    TELEGRAM_WEBHOOK_SECRET = "/${var.name_prefix}/telegram/webhook_secret"
  }
}

# ---------------------------------------------------------------------------
# caddy -- TLS termination and routing
#
# The only container reachable from outside, and the only one in HOST network
# mode, because it must own :443 on the instance itself. The rest use bridge
# networking with static host ports, which Caddy reaches at 127.0.0.1.
#
# Two Realtime rewrites are mandatory and were verified end to end locally:
#
#   /rest/v1/games?select=id     -> /games?select=id         (postgrest:3000)
#   /realtime/v1/websocket?vsn=1 -> /socket/websocket?vsn=1  (realtime:4000)
#                                   with Host: realtime-dev.<domain>
#
# Without the path rewrite Realtime answers 404; without the Host rewrite it
# answers 403, because it resolves the tenant from the host subdomain.
# ---------------------------------------------------------------------------
module "caddy" {
  source = "../ecs_service"

  count = local.images["caddy"] == null ? 0 : 1

  name_prefix       = var.name_prefix
  name              = "caddy"
  cluster_arn       = var.cluster_arn
  capacity_provider = var.capacity_provider
  log_group_name    = var.log_group_name

  image              = local.images["caddy"]
  task_role_arn      = var.task_data_role_arn
  execution_role_arn = var.task_execution_role_arn

  # host, not bridge: Caddy binds :443 on the instance directly.
  network_mode = "host"

  cpu                = 128
  memory_reservation = 64

  environment_variables = {
    DOMAIN = var.domain_name
    # Tenant id created by Realtime's SEED_SELF_HOST. It is `realtime-dev`
    # regardless of environment, so this is not a copy-paste error in prod.
    REALTIME_TENANT_HOST = "realtime-dev.${var.domain_name}"
  }

  secrets = {
    # Cloudflare Origin Certificate. The entrypoint writes these to disk with
    # 0600 before starting Caddy, so the key never enters the image.
    ORIGIN_CERT = "/${var.name_prefix}/tls/origin_cert"
    ORIGIN_KEY  = "/${var.name_prefix}/tls/origin_key"
  }
}
