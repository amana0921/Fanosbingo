/**
 * A single ECS service: task definition + service.
 *
 * NETWORK MODE, and an honest correction to an earlier claim.
 *
 * I previously described the EC2-to-Fargate move as "a one-line capacity
 * provider change". That is true of the compute billing model but NOT of
 * networking, and the reason is ENI limits:
 *
 *   awsvpc mode allocates one ENI per task. A t4g.small supports 3 network
 *   interfaces total, one of which the instance itself uses. Five tasks in
 *   awsvpc mode simply do not fit. (ENI trunking raises this, but requires an
 *   account-level opt-in and instance-type support.)
 *
 * So services run in `bridge` mode with static host port bindings, and Caddy --
 * which must own 443 on the host anyway -- runs in `host` mode and proxies to
 * 127.0.0.1:<port>. Simple, no service discovery, no ENI ceiling.
 *
 * The Fargate migration therefore also means switching every service to awsvpc
 * and giving Caddy real service discovery (Cloud Map). Contained, but a genuine
 * change rather than one line. Task definitions, IAM roles, secret injection
 * and log configuration all carry over untouched.
 */

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  # ECS injects secrets by ARN, not by parameter name.
  secret_arn_prefix = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter"

  container_definition = merge(
    {
      name      = var.name
      image     = var.image
      essential = true

      # On EC2, memory is a hard cap: exceeding it kills the container. Reserved
      # memory is the scheduler's soft floor. Setting only the reservation lets
      # a container burst into unused instance memory rather than being OOM
      # killed while the box has headroom.
      memoryReservation = var.memory_reservation
      cpu               = var.cpu

      environment = [
        for k, v in var.environment_variables : { name = k, value = tostring(v) }
      ]

      # Values are fetched by the ECS agent at container start using the task
      # EXECUTION role, so they never appear in the task definition, in
      # Terraform state, or in the console.
      secrets = [
        for env_name, param_path in var.secrets : {
          name      = env_name
          valueFrom = "${local.secret_arn_prefix}${param_path}"
        }
      ]

      portMappings = [
        for p in var.port_mappings : {
          containerPort = p.container_port
          hostPort      = p.host_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group_name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = var.name
        }
      }

      # SIGTERM, then SIGKILL after this many seconds. The ticker uses the
      # window to release its advisory lock so a standby takes over in
      # milliseconds rather than waiting for the connection to be reaped.
      stopTimeout = var.stop_timeout
    },
    var.command == null ? {} : { command = var.command },
    var.health_check == null ? {} : {
      healthCheck = {
        command     = var.health_check.command
        interval    = var.health_check.interval
        timeout     = var.health_check.timeout
        retries     = var.health_check.retries
        startPeriod = var.health_check.start_period
      }
    },
  )
}

resource "aws_ecs_task_definition" "this" {
  family             = "${var.name_prefix}-${var.name}"
  network_mode       = var.network_mode
  task_role_arn      = var.task_role_arn
  execution_role_arn = var.execution_role_arn

  # Task-level cpu/memory are optional on EC2 and deliberately omitted: setting
  # them would reserve capacity per task and, with five services on one
  # instance, exhaust the scheduler's view of available resources long before
  # the instance is actually full.
  requires_compatibilities = ["EC2"]

  container_definitions = jsonencode([local.container_definition])

  tags = merge(var.tags, { Name = "${var.name_prefix}-${var.name}" })
}

# Resolves the newest ACTIVE revision of this family, whether Terraform or CI
# registered it. depends_on so it is read AFTER any revision this apply creates.
data "aws_ecs_task_definition" "latest" {
  task_definition = aws_ecs_task_definition.this.family
  depends_on      = [aws_ecs_task_definition.this]
}

resource "aws_ecs_service" "this" {
  name    = var.name
  cluster = var.cluster_arn

  # Point at whichever revision is newer: the one this apply just registered, or
  # the one CI registered on its last deploy.
  #
  # The naive alternatives both fail. Pinning to aws_ecs_task_definition.this.arn
  # makes every terraform apply revert whatever CI deployed. Adding
  # `ignore_changes = [task_definition]` fixes that but creates a worse problem:
  # Terraform can then CHANGE configuration and never ROLL IT OUT. That bit us
  # here -- a corrected TLS certificate path sat in an unused revision while the
  # service kept crash-looping on the old one, looking for all the world like the
  # fix had not worked.
  task_definition = "${aws_ecs_task_definition.this.family}:${max(
    aws_ecs_task_definition.this.revision,
    data.aws_ecs_task_definition.latest.revision,
  )}"

  desired_count = var.desired_count

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider
    base              = var.desired_count
    weight            = 100
  }

  # With one instance there is nowhere to place a replacement before stopping
  # the old task, so a rolling deploy must be allowed to go to zero briefly.
  # Stage 2's second instance is what makes a true zero-downtime roll possible.
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent

  # `aws ecs execute-command` into a running container for debugging, without
  # SSH and without opening a port.
  enable_execute_command = true

  # Static host ports mean a new task cannot start until the old one frees the
  # port, so ECS must be allowed to stop first.
  force_new_deployment = false

  lifecycle {
    # task_definition is deliberately NOT ignored -- see the max() above, which
    # is what lets Terraform and CI both register revisions without either
    # overwriting the other.
    #
    # desired_count is ignored so a future autoscaling policy can move it
    # without every apply fighting to put it back.
    ignore_changes = [desired_count]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${var.name}" })
}
