/**
 * Identities.
 *
 * Four kinds of principal, each with the narrowest policy that lets it work:
 *
 *   1. github_deploy    — assumed from GitHub Actions via OIDC. No long-lived
 *                         AWS access key exists anywhere.
 *   2. ec2_instance     — the ECS container instance host.
 *   3. task_execution   — used by the ECS agent to pull images and inject
 *                         secrets. Shared by all tasks.
 *   4. task_*           — per-service runtime roles. Only the functions role
 *                         may ask KMS to sign a withdrawal.
 *
 * The split between task_execution and the task_* roles matters: the execution
 * role reads secrets at container start, the task role is what the running code
 * itself can do. Collapsing them would give application code the ability to read
 * every secret in the environment.
 */

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  partition      = data.aws_partition.current.partition
  ssm_param_arn  = "arn:${local.partition}:ssm:*:${local.account_id}:parameter/${var.name_prefix}/*"
  metric_namespc = "FanosBingo/${var.name_prefix}"

  github_owner = split("/", var.github_repository)[0]
  github_name  = split("/", var.github_repository)[1]

  # Every permitted context, in both the documented and the immutable subject
  # prefix forms. See the condition in the trust policy below for why.
  github_allowed_subjects = flatten([
    for ref in var.github_allowed_refs : [
      "repo:${var.github_repository}:${ref}",
      "repo:${local.github_owner}@*/${local.github_name}@*:${ref}",
    ]
  ])
}

# ===========================================================================
# 1. GitHub Actions deploy role (OIDC)
# ===========================================================================
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS validates GitHub's certificate chain against its own trust store now, so
  # this value is no longer load-bearing, but the field remains required.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

# Normally the provider already exists, created by scripts/bootstrap-aws.sh.
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Without this condition ANY repository on GitHub could assume this role.
    # It is the single most important line in this file.
    #
    # BOTH subject prefix forms are listed, and this is not redundancy. GitHub
    # emits an IMMUTABLE subject containing numeric owner and repository IDs --
    # repo:owner@123/name@456:... -- so that renaming an account does not
    # silently break trust policies. A policy written only the documented way
    # matches nothing and STS answers with a flatly unhelpful "Not authorized to
    # perform sts:AssumeRoleWithWebIdentity". scripts/bootstrap-aws.sh learned
    # this expensively; the same lesson applies here.
    #
    # The wildcard covers only the numeric IDs. Account names cannot contain
    # "@", so "owner@*" still pins the owner exactly.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_allowed_subjects
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "${var.name_prefix}-github-deploy"
  description        = "Assumed by GitHub Actions in ${var.github_repository}"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # This action does not support resource scoping.
  }

  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = ["arn:${local.partition}:ecr:*:${local.account_id}:repository/${var.name_prefix}/*"]
  }

  # Task definitions are account-scoped: neither of these actions supports a
  # resource ARN, so `*` here is the API's limit rather than a choice. What keeps
  # RegisterTaskDefinition from being a privilege escalation is PassTaskRoles
  # below, which pins the roles a definition may be registered with to this
  # environment's.
  statement {
    sid    = "EcsTaskDefinitions"
    effect = "Allow"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
    ]
    resources = ["*"]
  }

  # SCOPED TO THIS ENVIRONMENT'S CLUSTER, unlike the `*` this replaced.
  #
  # ecs:UpdateService on `*` let the dev deploy role act on PROD's services --
  # setting desiredCount to 0 for an outage, or rolling prod back to an older
  # revision. PassTaskRoles stops it registering a definition carrying prod's
  # roles, but nothing stopped it pointing a prod service at a revision that
  # already existed.
  #
  # The cluster is named for the environment (see modules/ecs), so the service
  # ARN prefix is a sufficient boundary.
  statement {
    sid    = "EcsDeploy"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]
    resources = ["arn:${local.partition}:ecs:*:${local.account_id}:service/${var.name_prefix}/*"]
  }

  # ListTasks and DescribeTasks take task ids that are generated per run, so
  # there is no ARN prefix to match on. The ecs:cluster condition key is how
  # these are scoped instead, and it reaches the same boundary.
  statement {
    sid    = "EcsInspectTasks"
    effect = "Allow"
    actions = [
      "ecs:ListTasks",
      "ecs:DescribeTasks",
    ]
    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = ["arn:${local.partition}:ecs:*:${local.account_id}:cluster/${var.name_prefix}"]
    }
  }

  # Registering a task definition means handing ECS a role to run it under.
  # Scoped so a compromised workflow cannot pass an arbitrary privileged role.
  statement {
    sid       = "PassTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${var.name_prefix}-task-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid    = "SpaPublish"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:${local.partition}:s3:::${var.spa_bucket_name}",
      "arn:${local.partition}:s3:::${var.spa_bucket_name}/*",
    ]
  }

  statement {
    sid       = "CdnInvalidate"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = ["*"]
  }

  # ---------------------------------------------------------------------
  # Parameter Store
  #
  # Three workflows need this tree, and they need different things from it:
  # deploy-services writes image pointers, sync-secrets writes secret values,
  # db-migrate reads the two database passwords.
  #
  # HONEST SCOPING NOTE. It would read better to grant write-only here and claim
  # a compromised run cannot exfiltrate anything. That would be false: the
  # migration runner genuinely needs to read db/app_password, and sync-secrets
  # verifies afterwards that no parameter still holds the placeholder, which
  # requires decryption to compare against. So this role can read and write
  # THIS ENVIRONMENT'S parameters, and that is stated rather than obscured.
  #
  # What it decisively cannot do is the reason the role exists: it cannot create
  # or modify an IAM role, change a security group, alter the real database, or
  # reach any environment other than its own. Its only RDS write is creating and
  # deleting an instance whose identifier ends in "-restore-drill" -- see the
  # restore drill statements below. Compare against the AdministratorAccess
  # executor these workflows used to run as.
  # ---------------------------------------------------------------------
  statement {
    sid    = "ManageEnvironmentParameters"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [local.ssm_param_arn]
  }

  statement {
    sid       = "ListParameters"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"] # DescribeParameters does not support resource scoping.
  }

  # SecureString writes need Encrypt; reads need Decrypt. Scoped to this
  # environment's CMK, so the dev deploy role cannot read a prod secret even if
  # it somehow learned the parameter name.
  statement {
    sid       = "UseEnvironmentKey"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }

  # Restoring an ENCRYPTED snapshot needs more than Decrypt.
  #
  # RDS creates a grant on the CMK so the new instance can use it, and without
  # kms:CreateGrant the restore fails with KMSKeyNotAccessibleFault -- a message
  # that says the key "does not exist, is not enabled or you do not have
  # permissions", none of which points at the missing action. Found by the first
  # real run of the restore drill.
  #
  # The GrantIsForAWSResource condition is what keeps this narrow: it permits
  # grants created by an AWS service on your behalf, and not grants this role
  # might mint for an arbitrary principal.
  statement {
    sid       = "GrantKeyUseToRdsOnRestore"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = [var.kms_key_arn]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  # ---------------------------------------------------------------------
  # Database tunnel
  #
  # RDS has no public endpoint. Migrations reach it by port-forwarding through
  # the ECS container instance over Session Manager: no inbound port, no SSH
  # key, and every session attributable to a principal in CloudTrail.
  # ---------------------------------------------------------------------
  #
  # SCOPED BY TAG, and the condition is the whole control.
  #
  # This used to be `instance/*` with no condition, which is EVERY EC2 instance
  # in the account -- including the other environment's. Listing the
  # port-forwarding document alongside it constrains nothing: a session that
  # names no document uses the default SSM-SessionManagerRunShell, so only the
  # instance ARN is evaluated, and there is no ssm:SessionDocumentAccessCheck
  # condition here to force document matching.
  #
  # So the grant was an INTERACTIVE ROOT SHELL on any instance in the account.
  # Chained with dev's trust policy admitting `pull_request` (see
  # environments/dev/main.tf), that made pull-request branch code a path to a
  # shell on the PROD container instance -- where every container's injected
  # secrets are readable from the environment, and the functions task role holds
  # kms:Sign. The comment on dev's `pull_request` grant states the cost as "dev's
  # parameter tree and the dev database"; without this condition that bound did
  # not hold.
  #
  # The Environment tag is propagated to the instance by the ASG (see
  # modules/ecs), the same tag the ec2:AssociateAddress condition already relies
  # on, so this needs nothing new to be true.
  statement {
    sid     = "OpenDatabaseTunnel"
    effect  = "Allow"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:${local.partition}:ec2:*:${local.account_id}:instance/*",
      "arn:${local.partition}:ssm:*::document/AWS-StartPortForwardingSessionToRemoteHost",
    ]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Environment"
      values   = [var.environment]
    }
  }

  statement {
    sid       = "CloseDatabaseTunnel"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:${local.partition}:ssm:*:*:session/*"]
  }

  # Finding the instance to tunnel through and the endpoint to tunnel to.
  #
  # ssm:DescribeInstanceInformation is not optional and is easy to leave out.
  # db-tunnel.sh checks the SSM agent's PingStatus before opening a session,
  # because an instance can be `running` while its agent has not yet registered
  # -- and StartSession against an unregistered agent fails with a far less
  # obvious message than "the agent is not online yet". Granting StartSession
  # without this makes the tunnel fail at the readiness check it exists to pass.
  statement {
    sid    = "DiscoverTunnelEndpoints"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ssm:DescribeInstanceInformation",
      "rds:DescribeDBInstances",
      "rds:DescribeDBSnapshots",
      "ecs:ListContainerInstances",
      "ecs:DescribeContainerInstances",
    ]
    resources = ["*"] # Describe* actions do not support resource-level scoping.
  }

  # The migration runner connects as the RDS master user, whose password is
  # generated and rotated by RDS itself.
  #
  # THIS ENVIRONMENT'S SECRET, by exact ARN. It used to be the `rds!db-*` prefix,
  # which is every RDS-managed secret in the ACCOUNT -- so the dev role could ask
  # for prod's master password.
  #
  # That was not exploitable, and the reason is worth recording because it was
  # luck rather than design: the secret is encrypted with prod's CMK, and
  # UseEnvironmentKey grants kms:Decrypt on this environment's key only, so
  # GetSecretValue returned AccessDenied from KMS. A policy that is correct
  # because a DIFFERENT policy happens to cover it is one edit away from not
  # being correct, which is exactly what db/20-post/007 says about the
  # withdrawal_requests read policy.
  #
  # The ARN is computed by RDS, so it is passed in from the rds module rather
  # than pattern-matched. Guarded with a dynamic block because it is unknown
  # until the instance exists -- an environment can then still plan before RDS
  # has been created.
  dynamic "statement" {
    for_each = try(trimspace(var.rds_master_secret_arn), "") == "" ? [] : [var.rds_master_secret_arn]

    content {
      sid       = "ReadRdsManagedMasterSecret"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [statement.value]
    }
  }

  # ---------------------------------------------------------------------
  # Security control verification
  #
  # verify-detections.sh reads the DEPLOYED metric filters back and tests them
  # against synthetic events. Read-only, and scheduled weekly -- a detector is
  # only coverage for as long as it still matches the thing it watches, and
  # nothing else would notice a filter being edited or a subscription lapsing.
  #
  # logs:TestMetricFilter evaluates a pattern against strings supplied in the
  # request. It reads nothing and writes nothing.
  # ---------------------------------------------------------------------
  statement {
    sid    = "VerifySecurityControls"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeMetricFilters",
      "logs:TestMetricFilter",
      "cloudtrail:GetTrailStatus",
      "cloudtrail:DescribeTrails",
      "sns:ListTopics",
      "sns:ListSubscriptionsByTopic",
      "cloudwatch:DescribeAlarms",
    ]
    resources = ["*"] # None of these read actions supports resource scoping.
  }

  # ---------------------------------------------------------------------
  # Restore drill
  #
  # Scoped by identifier to instances ending in "-restore-drill", so this role
  # can create and destroy a throwaway copy and CANNOT touch the real database.
  # The workflow re-checks the suffix before deleting; this is the control that
  # holds even if the workflow is wrong.
  # ---------------------------------------------------------------------
  statement {
    sid    = "RunRestoreDrill"
    effect = "Allow"
    actions = [
      "rds:RestoreDBInstanceFromDBSnapshot",
      "rds:DeleteDBInstance",
      "rds:AddTagsToResource",
    ]
    resources = [
      "arn:${local.partition}:rds:*:${local.account_id}:db:${var.name_prefix}-pg-restore-drill",
      "arn:${local.partition}:rds:*:${local.account_id}:snapshot:*",
      "arn:${local.partition}:rds:*:${local.account_id}:subgrp:${var.name_prefix}-db",
      "arn:${local.partition}:rds:*:${local.account_id}:pg:*",
    ]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}

# ===========================================================================
# 2. EC2 container instance
# ===========================================================================
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2_instance" {
  name               = "${var.name_prefix}-ec2-instance"
  description        = "ECS container instance host"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

# Lets the ECS agent register the instance with the cluster and pull images.
resource "aws_iam_role_policy_attachment" "ec2_ecs" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Session Manager. This is why there is no port 22 rule and no key pair:
# shell access goes through SSM, needs no inbound port, and is CloudTrail-logged.
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_extra" {
  # On boot the instance re-attaches the environment's Elastic IP to itself, so
  # the address survives an ASG replacement without a DNS change.
  statement {
    sid       = "DescribeAddresses"
    effect    = "Allow"
    actions   = ["ec2:DescribeAddresses", "ec2:DescribeInstances"]
    resources = ["*"] # Describe* actions do not support resource-level scoping.
  }

  statement {
    sid       = "AssociateProjectEip"
    effect    = "Allow"
    actions   = ["ec2:AssociateAddress"]
    resources = ["*"]

    # Constrained to addresses and instances tagged for this environment, so the
    # instance cannot steal an unrelated Elastic IP in the same account.
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = [var.environment]
    }
  }

  statement {
    sid       = "PublishMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"] # PutMetricData does not support resource ARNs.

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.metric_namespc]
    }
  }
}

resource "aws_iam_role_policy" "ec2_extra" {
  name   = "instance-extras"
  role   = aws_iam_role.ec2_instance.id
  policy = data.aws_iam_policy_document.ec2_extra.json
}

resource "aws_iam_instance_profile" "ec2_instance" {
  name = "${var.name_prefix}-ec2-instance"
  role = aws_iam_role.ec2_instance.name
  tags = var.tags
}

# ===========================================================================
# 3. ECS task execution role (image pull + secret injection at container start)
# ===========================================================================
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.name_prefix}-task-execution"
  description        = "ECS agent: pulls images, writes logs, injects secrets"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "task_execution_secrets" {
  # Reads SecureString parameters so ECS can inject them as container env vars.
  statement {
    sid       = "ReadParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameters", "ssm:GetParameter"]
    resources = [local.ssm_param_arn]
  }

  # Decrypting those SecureStrings requires the CMK.
  statement {
    sid       = "DecryptParameters"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "secret-injection"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_secrets.json
}

# ===========================================================================
# 4. Per-service task roles
# ===========================================================================

# Shared by every task role: publish custom metrics and support ECS Exec.
data "aws_iam_policy_document" "task_common" {
  statement {
    sid       = "PublishMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.metric_namespc]
    }
  }

  # ECS Exec — `aws ecs execute-command` into a running container for debugging,
  # without SSH and without opening a port.
  statement {
    sid    = "EcsExec"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

# --- ticker: game loop + BSC deposit indexer -------------------------------
resource "aws_iam_role" "task_ticker" {
  name               = "${var.name_prefix}-task-ticker"
  description        = "Game loop and deposit indexer"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "task_ticker" {
  name   = "runtime"
  role   = aws_iam_role.task_ticker.id
  policy = data.aws_iam_policy_document.task_common.json
}

# --- functions: the 25 ported edge functions -------------------------------
resource "aws_iam_role" "task_functions" {
  name               = "${var.name_prefix}-task-functions"
  description        = "Ported edge functions. The only principal permitted to sign withdrawals."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "task_functions" {
  source_policy_documents = [data.aws_iam_policy_document.task_common.json]

  # The withdrawal signing capability. Deliberately granted to exactly one role,
  # so a CloudTrail alarm on kms:Sign from any other principal is a real signal
  # rather than noise.
  statement {
    sid       = "SignWithdrawals"
    effect    = "Allow"
    actions   = ["kms:Sign", "kms:GetPublicKey"]
    resources = [var.wallet_signing_key_arn]
  }
}

resource "aws_iam_role_policy" "task_functions" {
  name   = "runtime"
  role   = aws_iam_role.task_functions.id
  policy = data.aws_iam_policy_document.task_functions.json
}

# --- postgrest / realtime / caddy: no AWS API access beyond the common set --
resource "aws_iam_role" "task_data" {
  name               = "${var.name_prefix}-task-data"
  description        = "PostgREST, Realtime and Caddy. No AWS API access beyond metrics and exec."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "task_data" {
  name   = "runtime"
  role   = aws_iam_role.task_data.id
  policy = data.aws_iam_policy_document.task_common.json
}
