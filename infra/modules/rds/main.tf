/**
 * PostgreSQL.
 *
 * This is the single most important resource in the stack: it holds player
 * balances. Everything else can be rebuilt from git in under an hour.
 *
 * Three parameter-group settings are load-bearing and easy to get wrong:
 *
 *   rds.logical_replication = 1
 *       Sets wal_level=logical, which the self-hosted Realtime container needs
 *       to consume a replication slot. Without it Realtime starts, connects,
 *       and silently never delivers a row change.
 *
 *   shared_preload_libraries = pg_cron
 *       Needed for the housekeeping jobs. NOTE: pg_cron on RDS has ONE-MINUTE
 *       granularity. Supabase's `cron.schedule_in_database('...', '4 seconds',
 *       ...)` six-field syntax is a fork extension and will NOT schedule here.
 *       That is why the game loop moved to the ticker container. Do not try to
 *       reinstate the 4-second cron job — it fails silently, which is the worst
 *       possible failure mode for a game heartbeat.
 *
 *   max_slot_wal_keep_size = 2048 (MB)
 *       If the Realtime container dies, its replication slot stops advancing
 *       and Postgres retains WAL forever waiting for it. Without this cap the
 *       disk fills and the database stops accepting writes — turning a
 *       recoverable container crash into a full outage. With it, the slot is
 *       dropped instead and Realtime resyncs on reconnect.
 *
 * Both `rds.logical_replication` and `shared_preload_libraries` are static
 * parameters: they only take effect after a reboot. Terraform will not reboot
 * the instance for you on a parameter-group change.
 */

resource "aws_db_subnet_group" "this" {
  name        = "${var.name_prefix}-db"
  description = "Isolated subnets — no route to the internet in either direction"
  subnet_ids  = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-db-subnets" })
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.name_prefix}-pg16"
  family      = "postgres16"
  description = "Fanos Bingo: logical replication for Realtime, pg_cron for housekeeping"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot" # static parameter
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_cron,pg_stat_statements"
    apply_method = "pending-reboot" # static parameter
  }

  parameter {
    name         = "cron.database_name"
    value        = var.database_name
    apply_method = "pending-reboot"
  }

  # Cap WAL retained for an inactive replication slot. See the header comment —
  # this is what stops a dead Realtime container from filling the disk.
  parameter {
    name         = "max_slot_wal_keep_size"
    value        = tostring(var.max_slot_wal_keep_mb)
    apply_method = "immediate"
  }

  # Log slow queries. At 1s this is quiet in normal operation but catches the
  # lock contention that shows up under a join spike.
  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-pg"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.database_name
  username = var.master_username

  # RDS generates and rotates the master password in Secrets Manager, so it
  # never passes through Terraform state. Costs ~$0.40/mo, which is the right
  # trade for the credential that owns every player balance.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  # Application roles authenticate with IAM tokens rather than passwords where
  # possible, so there is no long-lived app credential to leak.
  iam_database_authentication_enabled = true

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage # storage autoscaling ceiling
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  parameter_group_name = aws_db_parameter_group.this.name

  # 7 days of point-in-time recovery. RPO is ~5 minutes.
  backup_retention_period = var.backup_retention_period
  backup_window           = var.backup_window
  maintenance_window      = var.maintenance_window
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-pg-final-${var.final_snapshot_suffix}"

  performance_insights_enabled = var.performance_insights_enabled

  # Surface Postgres logs in CloudWatch so slow queries and errors are visible
  # without shelling into anything.
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = merge(var.tags, { Name = "${var.name_prefix}-pg" })
}
