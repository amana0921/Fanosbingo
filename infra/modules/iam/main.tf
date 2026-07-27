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
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for ref in var.github_allowed_refs : "repo:${var.github_repository}:${ref}"]
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

  statement {
    sid    = "EcsDeploy"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
      "ecs:ListTasks",
      "ecs:DescribeTasks",
    ]
    resources = ["*"]
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
