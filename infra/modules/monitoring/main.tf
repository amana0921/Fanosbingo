/**
 * Budgets and baseline alarms.
 *
 * The budget alerts are not decoration. On a credit-based AWS Free Tier plan,
 * exhausting your credits on a *Free* account plan suspends resources — for a
 * real-money game that is an outage, not a warning. These alerts are the early
 * signal that you need to switch to a Paid account plan, or that something is
 * running that should not be.
 *
 * Coverage is in two layers, and the second matters more.
 *
 * INFRASTRUCTURE alarms (RDS, EC2) tell you a component is unhealthy. They are
 * necessary and insufficient: every one of them can sit at OK while the game is
 * frozen, because a process can be running happily and still not be calling
 * numbers.
 *
 * The GAME LOOP alarm is the one that corresponds to what a player experiences.
 * The ticker's Dockerfile deliberately ships no HEALTHCHECK and says so: its
 * liveness is asserted here instead, from the outside, on the thing that
 * actually matters.
 *
 * Everything here fits in the CloudWatch free tier (10 alarms, 1M API requests).
 */

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-alerts" })
}

# Email subscriptions require the recipient to click a confirmation link before
# anything is delivered. Terraform reports the subscription as created while it
# is still "pending confirmation" — check your inbox, or alarms will fire into
# the void.
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# ---------------------------------------------------------------------------
# Cost
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Environment$${var.environment}"]
  }

  # Absolute dollar thresholds, expressed as percentages of the limit.
  dynamic "notification" {
    for_each = var.alert_thresholds_usd

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = (notification.value / var.monthly_budget_usd) * 100
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
      subscriber_email_addresses = var.alert_emails
    }
  }

  # Forecast-based alert: catches a cost trend early enough to act, rather than
  # telling you about it once the money is already spent.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = var.alert_emails
  }
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

# Disk full means the database stops accepting writes — a total outage. The
# usual cause here is a stalled logical replication slot retaining WAL, which
# max_slot_wal_keep_size is meant to prevent; this alarm is the backstop for
# when that assumption is wrong.
resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  alarm_name          = "${var.name_prefix}-rds-low-storage"
  alarm_description   = "RDS free storage below 20%. Disk full stops all writes."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = var.rds_allocated_storage_gb * 1024 * 1024 * 1024 * 0.2

  dimensions         = { DBInstanceIdentifier = var.rds_instance_id }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  treat_missing_data = "breaching"

  tags = var.tags
}

# On a burstable class, exhausting CPU credits does not throttle gracefully —
# the instance drops to baseline (roughly 10-20% of a vCPU) and query latency
# collapses. This is the alarm that tells you it is time for db.t4g.small.
resource "aws_cloudwatch_metric_alarm" "rds_cpu_credits" {
  alarm_name          = "${var.name_prefix}-rds-cpu-credits-low"
  alarm_description   = "RDS CPU credit balance low. Burstable instance is about to throttle to baseline."
  namespace           = "AWS/RDS"
  metric_name         = "CPUCreditBalance"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 30

  dimensions         = { DBInstanceIdentifier = var.rds_instance_id }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name_prefix}-rds-cpu-high"
  alarm_description   = "RDS CPU above 80% for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80

  dimensions         = { DBInstanceIdentifier = var.rds_instance_id }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

# PostgREST, Realtime, the ticker and the functions container each hold a pool.
# Exhausting max_connections presents as intermittent, confusing failures rather
# than a clean outage.
resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.name_prefix}-rds-connections-high"
  alarm_description   = "RDS connection count approaching the instance limit."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.rds_max_connections_alarm

  dimensions         = { DBInstanceIdentifier = var.rds_instance_id }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Application instance
# ---------------------------------------------------------------------------

# With a single instance this alarm IS the outage notification. The ASG will
# replace the instance in 3-5 minutes on its own; this tells you it happened.
resource "aws_cloudwatch_metric_alarm" "ec2_status_check" {
  alarm_name          = "${var.name_prefix}-ec2-status-check-failed"
  alarm_description   = "Application instance failed its status check. Game is down until the ASG replaces it."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0

  dimensions         = { AutoScalingGroupName = var.autoscaling_group_name }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Game loop
#
# THE alarm. Everything else in this file describes the health of a component;
# this one describes whether the game is running.
# ---------------------------------------------------------------------------

# treat_missing_data = "breaching" is the entire point of this alarm, not a
# detail. It makes one alarm cover both failure modes:
#
#   * the loop is stalled  -> the metric climbs past the threshold
#   * the ticker is dead   -> no data points arrive at all
#
# With the CloudWatch default of "missing", a ticker that crashes stops
# publishing and the alarm sits at INSUFFICIENT_DATA forever -- silent, in
# exactly the situation it exists to catch. That is the same class of failure as
# the sub-minute pg_cron schedule this service was built to replace: a heartbeat
# that stops without complaining.
#
# Threshold: numbers are called every CALL_INTERVAL_MS (3.5s). 30 seconds is
# roughly eight missed calls -- unambiguous to a player, and far enough above
# normal jitter that a slow tick does not page anybody.
resource "aws_cloudwatch_metric_alarm" "game_loop_stalled" {
  alarm_name        = "${var.name_prefix}-game-loop-stalled"
  alarm_description = "No bingo number called for 30s, or the ticker has stopped publishing entirely. Players are watching a frozen board."

  namespace   = var.metric_namespace
  metric_name = "SecondsSinceLastNumberCalled"
  statistic   = "Maximum"

  # 60s periods over two of them: fast enough to matter, slow enough that a
  # single delayed publish does not page anyone.
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 30

  dimensions         = { Environment = var.environment }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  treat_missing_data = "breaching"

  tags = var.tags
}

# A tick that takes longer than its own interval means the loop cannot keep
# cadence: number calls drift and players notice before any component looks
# unhealthy. Warning-level -- it precedes the stall rather than being one.
resource "aws_cloudwatch_metric_alarm" "tick_duration" {
  alarm_name        = "${var.name_prefix}-tick-duration-high"
  alarm_description = "game_tick() is taking longer than its 1s interval. The loop is falling behind."

  namespace           = var.metric_namespace
  metric_name         = "TickDuration"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 800

  dimensions    = { Environment = var.environment }
  alarm_actions = [aws_sns_topic.alerts.arn]

  # Unlike the stall alarm, absent data here is not a failure -- the stall alarm
  # already owns "the ticker is gone", and duplicating that would page twice for
  # one incident.
  treat_missing_data = "notBreaching"

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ec2_cpu_credits" {
  alarm_name          = "${var.name_prefix}-ec2-cpu-credits-low"
  alarm_description   = "Instance CPU credit balance low. t4g.small is about to throttle to baseline."
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 30

  dimensions         = { AutoScalingGroupName = var.autoscaling_group_name }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}
