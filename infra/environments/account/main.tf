/**
 * Fanos Bingo — account-wide security baseline.
 *
 * Everything here is a singleton: there is one CloudTrail per account, one
 * account-level S3 public access block, one password policy. Putting them in
 * dev or prod would mean either duplicating them (and paying twice for the same
 * management events) or having them disappear the moment dev is destroyed --
 * and dev is explicitly disposable.
 *
 * This root is small, changes rarely, and is applied on its own:
 *
 *   gh workflow run terraform.yml -f environment=account -f action=apply
 *
 * It has no dependency on dev or prod existing, and they have no dependency on
 * it. The one coupling is by name: the kms:Sign alarm excludes the task role
 * names the environment roots create, so if you ever rename them, update
 * permitted_signing_roles here in the same change.
 */

data "aws_caller_identity" "current" {}

locals {
  name_prefix = var.project_name

  # Names, not ARNs -- CloudTrail records the role name in
  # userIdentity.sessionContext.sessionIssuer.userName. Listed for every
  # environment whether or not it currently exists: a role that does not exist
  # simply never appears in the log, and pre-listing it means standing prod up
  # does not require remembering to come back here.
  permitted_signing_roles = [
    for env in var.environments : "${var.project_name}-${env}-task-functions"
  ]
}

# ---------------------------------------------------------------------------
# Alerting
#
# Separate from the per-environment topics on purpose. These fire about the
# account rather than about a game, and they must keep working when dev has been
# destroyed.
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "security" {
  name              = "${local.name_prefix}-security-alerts"
  kms_master_key_id = aws_kms_key.audit.arn

  tags = { Name = "${local.name_prefix}-security-alerts" }
}

# Email subscriptions require the recipient to click a confirmation link before
# anything is delivered. Terraform reports the subscription as created while it
# is still "pending confirmation" -- check your inbox, or these alarms fire into
# the void.
resource "aws_sns_topic_subscription" "security_email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.security.arn
  protocol  = "email"
  endpoint  = each.value
}

# ---------------------------------------------------------------------------
# Audit key
#
# Its own CMK rather than an environment's. The environment keys are destroyed
# with their environment, and audit logs must outlive the thing they describe.
# ---------------------------------------------------------------------------
resource "aws_kms_key" "audit" {
  description             = "${local.name_prefix} audit logs and security notifications"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = { Name = "${local.name_prefix}-audit" }
}

resource "aws_kms_alias" "audit" {
  name          = "alias/${local.name_prefix}-audit"
  target_key_id = aws_kms_key.audit.key_id
}

# CloudWatch Logs and CloudWatch alarms publishing to SNS both need to use this
# key. Note that aws_kms_key_policy REPLACES the default policy, so the root
# statement has to be restated -- omitting it locks everyone out of the key,
# including the account itself.
data "aws_iam_policy_document" "audit_key" {
  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
  }

  # Without this, an alarm transitioning to ALARM cannot publish to the
  # encrypted topic and the notification is dropped -- silently, which is the
  # worst possible outcome for a security alarm.
  statement {
    sid    = "AllowCloudWatchAlarmsToPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
  }

  # CloudTrail encrypting the log files it delivers.
  #
  # Conditioned on the encryption context rather than a specific trail ARN, on
  # purpose: the key policy would otherwise need the trail's ARN while the trail
  # needs the key's ARN, and Terraform cannot resolve that cycle. The context
  # still pins this to CloudTrail trails in THIS account, which is the property
  # that matters -- it is not a grant to CloudTrail generally.
  statement {
    sid    = "AllowCloudTrailToEncryptLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"]
    }
  }

  # Reading a delivered log file back. Without this the logs are written and
  # then unreadable, which is an audit trail in name only.
  statement {
    sid    = "AllowAccountToDecryptTrailLogs"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:Decrypt", "kms:ReEncryptFrom"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key_policy" "audit" {
  key_id = aws_kms_key.audit.id
  policy = data.aws_iam_policy_document.audit_key.json
}

# ---------------------------------------------------------------------------
# CloudTrail and its detections
# ---------------------------------------------------------------------------
module "cloudtrail" {
  source = "../../modules/cloudtrail"

  name_prefix      = local.name_prefix
  kms_key_arn      = aws_kms_key.audit.arn
  alerts_topic_arn = aws_sns_topic.security.arn

  permitted_signing_roles = local.permitted_signing_roles

  depends_on = [aws_kms_key_policy.audit]
}

# ---------------------------------------------------------------------------
# Account guardrails
#
# Each of these is a setting somebody would otherwise have to remember to click,
# in a console, once, correctly. That is the definition of a control that
# regresses.
# ---------------------------------------------------------------------------

# Belt and braces over each bucket's own public access block. This one cannot be
# overridden by a bucket-level policy, so a future bucket created outside
# Terraform is covered by default rather than by diligence.
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Every EBS volume created in this region is encrypted, including ones created
# by a service on your behalf where you never see a launch template.
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# There should be no IAM users with console access at all -- everything routine
# is OIDC -- but if one is ever created, it starts from a sane baseline instead
# of the AWS default of no policy whatsoever.
resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 16
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 180
  password_reuse_prevention      = 12
}

# Free, and it answers a question that is otherwise tedious and easy to get
# wrong: which of my resources can be reached from outside this account?
resource "aws_accessanalyzer_analyzer" "this" {
  analyzer_name = "${local.name_prefix}-external-access"
  type          = "ACCOUNT"

  tags = { Name = "${local.name_prefix}-external-access" }
}

# ---------------------------------------------------------------------------
# Cost allocation tags
#
# WITHOUT THIS, EVERY TAG-FILTERED BUDGET REPORTS ZERO FOREVER.
#
# A user-defined tag is not usable as a cost dimension until it is ACTIVATED in
# Billing. Until then Cost Explorer and Budgets can see the tag key exists and
# still attribute nothing to it, so a budget whose cost_filter names it matches
# no spend, sits at $0.00 actual with no forecast, and never crosses a threshold.
#
# MEASURED, not inferred:
#
#   aws ce list-cost-allocation-tags   -> Environment: Inactive
#   aws budgets describe-budgets       -> fanosbingo-dev-monthly
#                                         Actual 0.0, Forecast None
#
# modules/monitoring carries a long comment about the `$${` HCL escape that used
# to render this same filter as a literal, and about that being "the same class
# of defect as a statement that reports success and changes nothing". The escape
# was genuinely fixed. The behaviour did not change, because the cause was never
# only in the HCL -- it was here, one layer down, and the fix looked like it had
# worked because the symptom is identical either way: a budget reading zero.
#
# ACTIVATION IS NOT RETROACTIVE. Costs incurred before this applies stay
# unattributed permanently; only spend from the activation date forward carries
# the tag. So the per-environment budgets become meaningful roughly a day after
# this lands, not immediately -- do not read the first day's $0 as proof it is
# still broken.
#
# Environment is the one the budgets filter on. The other three are activated
# because the cost of doing so is nothing and the question "what is this
# environment spending on, and which of it is account-wide rather than dev"
# cannot be answered later for a period when the tags were off.
resource "aws_ce_cost_allocation_tag" "this" {
  for_each = toset(["Environment", "Project", "Scope", "ManagedBy"])

  tag_key = each.value
  status  = "Active"
}

# ---------------------------------------------------------------------------
# The backstop budget
#
# UNFILTERED, and that is the whole point of it existing alongside the
# per-environment ones.
#
# A tag-filtered budget can only ever see spend that carries the tag, and a
# meaningful amount of what this account bills for cannot carry one:
#
#   - data transfer and NAT-style charges, which are not tagged resources
#   - KMS request charges
#   - the CloudTrail and Terraform state buckets, tagged Scope=account and
#     therefore invisible to a filter on Environment
#   - anything created outside Terraform, by definition
#
# So the per-environment budgets answer "is dev costing more than it should",
# and this one answers "is the account costing more than it should" -- which is
# the question that matters when the failure mode is credit exhaustion
# SUSPENDING resources on a Free account plan, as modules/monitoring describes.
#
# It publishes to the security topic rather than an environment's, for the same
# reason the trail does: this must keep working when dev has been destroyed.
resource "aws_budgets_budget" "account_total" {
  name         = "${local.name_prefix}-account-total"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_account_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # No cost_filter at all. Every dollar the account bills counts.

  dynamic "notification" {
    for_each = var.account_alert_thresholds_usd

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = (notification.value / var.monthly_account_budget_usd) * 100
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_sns_topic_arns  = [aws_sns_topic.security.arn]
      subscriber_email_addresses = var.alert_emails
    }
  }

  # Catches a trend while there is still time to act on it, rather than
  # reporting the money after it is spent.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.security.arn]
    subscriber_email_addresses = var.alert_emails
  }
}
