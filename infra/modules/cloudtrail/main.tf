/**
 * CloudTrail, and the detections that make it worth paying for.
 *
 * WHY THIS EXISTS
 *
 * The hot wallet is a non-exportable KMS secp256k1 key, and exactly one IAM
 * role -- <prefix>-task-functions -- is permitted to call kms:Sign on it. That
 * is a strong preventive control, and it was previously the whole story: the
 * comment in modules/iam asserted that "a CloudTrail alarm on kms:Sign from any
 * other principal is a real signal", and no trail existed to raise one.
 *
 * A control nobody can observe being violated is half a control. This is the
 * other half.
 *
 * WHY IT IS ACCOUNT-SCOPED
 *
 * A trail records the account, not an environment. Standing one up per
 * environment would produce duplicate copies of the same management events --
 * the first copy is free, every subsequent one is billed -- so this module is
 * instantiated once, from infra/environments/account.
 *
 * ENCRYPTION
 *
 * A dedicated audit CMK, not SSE-S3 and not the project key.
 *
 * The project CMK would be wrong: it wraps the RDS volume and every
 * SecureString, and granting cloudtrail.amazonaws.com in that key's policy to
 * cover audit logs widens the blast radius of the key that protects player
 * balances. SSE-S3 would be adequate for confidentiality but gives up key
 * rotation policy, per-principal access control on the logs themselves, and the
 * CloudTrail record of who decrypted them.
 *
 * So the account root creates a separate key whose only job is audit data, and
 * the trail, its bucket and the log group all use it. Deleting that key is how
 * you make the audit history unreadable, which is why its deletion window is 30
 * days and the executor role is denied the actions that would destroy the trail.
 *
 * Confidentiality is one half. Integrity is log-file validation, below.
 */

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  bucket_name = "${var.name_prefix}-cloudtrail-${data.aws_caller_identity.current.account_id}"
  trail_arn   = "arn:${data.aws_partition.current.partition}:cloudtrail:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:trail/${var.name_prefix}"
}

# ---------------------------------------------------------------------------
# Log destination
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "trail" {
  bucket = local.bucket_name

  # No force_destroy. Audit logs should outlive a careless `terraform destroy`;
  # emptying this bucket must be a deliberate, separate act.
  tags = merge(var.tags, { Name = local.bucket_name })
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    # S3 Bucket Keys cut KMS request charges by roughly 99% on a bucket written
    # to continuously, which a trail is. Without it, audit logging becomes a
    # visible line item on a $30/month budget.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket = aws_s3_bucket.trail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    # Cheaper storage after a month: nobody reads month-old audit logs
    # interactively, but an investigation may need them a year later.
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# The aws:SourceArn conditions matter. Without them this bucket policy grants
# CloudTrail-as-a-service write access on behalf of ANY account -- the confused
# deputy shape AWS added these condition keys to close.
data "aws_iam_policy_document" "bucket" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid    = "DenyUnencryptedTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.trail.arn,
      "${aws_s3_bucket.trail.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.bucket.json
}

# ---------------------------------------------------------------------------
# CloudWatch Logs delivery
#
# S3 is the durable record; CloudWatch Logs is what metric filters can watch.
# Alarming requires the second, so the trail delivers to both.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "trail" {
  name              = "/aws/cloudtrail/${var.name_prefix}"
  retention_in_days = var.cloudwatch_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-cloudtrail-logs" })
}

data "aws_iam_policy_document" "cloudtrail_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudtrail_to_logs" {
  name               = "${var.name_prefix}-cloudtrail-to-logs"
  description        = "CloudTrail delivering events to CloudWatch Logs"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "cloudtrail_to_logs" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.trail.arn}:*"]
  }
}

resource "aws_iam_role_policy" "cloudtrail_to_logs" {
  name   = "deliver"
  role   = aws_iam_role.cloudtrail_to_logs.id
  policy = data.aws_iam_policy_document.cloudtrail_to_logs.json
}

# ---------------------------------------------------------------------------
# The trail
# ---------------------------------------------------------------------------
resource "aws_cloudtrail" "this" {
  name           = var.name_prefix
  s3_bucket_name = aws_s3_bucket.trail.id

  # Multi-region even though everything runs in one. An attacker who wants to
  # act unobserved acts in a region you are not watching; a single-region trail
  # is an invitation to do exactly that.
  is_multi_region_trail         = true
  include_global_service_events = true

  # Digest files, so tampering with a delivered log is detectable rather than
  # merely unlikely.
  enable_log_file_validation = true

  # The dedicated audit key. See the header for why it is not the project CMK.
  kms_key_id = var.kms_key_arn

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.trail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_to_logs.arn

  # Management events only. Data events (every S3 object read, every Lambda
  # invoke) are billed per event and would dominate the bill for this account
  # while adding nothing: the signal we need -- kms:Sign, IAM changes, security
  # group edits -- is all management-plane.
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_policy.trail]

  tags = merge(var.tags, { Name = var.name_prefix })
}

# ---------------------------------------------------------------------------
# Detections
# ---------------------------------------------------------------------------

# Withdrawal signing by anything other than the functions task role.
#
# In normal operation this filter matches nothing at all, which is what makes it
# a usable alarm rather than noise: the ONE role allowed to sign is excluded, so
# any match is either a misconfiguration or someone signing transactions who
# should not be able to.
#
# The principal is read from sessionContext.sessionIssuer.userName because the
# caller is always an assumed role -- userIdentity.userName is absent for role
# sessions, and a filter on an absent field silently never matches.
resource "aws_cloudwatch_log_metric_filter" "unexpected_kms_sign" {
  name           = "${var.name_prefix}-unexpected-kms-sign"
  log_group_name = aws_cloudwatch_log_group.trail.name

  pattern = join("", [
    "{ ($.eventSource = \"kms.amazonaws.com\") && ($.eventName = \"Sign\")",
    join("", [
      for role in var.permitted_signing_roles :
      " && ($.userIdentity.sessionContext.sessionIssuer.userName != \"${role}\")"
    ]),
    " }",
  ])

  metric_transformation {
    name          = "UnexpectedKmsSign"
    namespace     = var.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "unexpected_kms_sign" {
  alarm_name        = "${var.name_prefix}-unexpected-kms-sign"
  alarm_description = "kms:Sign called by a principal other than the functions task role. Treat as a possible hot-wallet compromise."

  namespace   = var.metric_namespace
  metric_name = "UnexpectedKmsSign"
  statistic   = "Sum"

  # A single occurrence is the alarm. There is no acceptable rate here.
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0

  alarm_actions = [var.alerts_topic_arn]

  # A gap in the metric means no signing happened, which is the good case.
  treat_missing_data = "notBreaching"

  tags = var.tags
}

# Root credentials should never be used after bootstrap. If they are, either
# somebody took a shortcut or the account is compromised; both are worth an
# email at the moment it happens rather than at the next review.
resource "aws_cloudwatch_log_metric_filter" "root_account_used" {
  name           = "${var.name_prefix}-root-account-used"
  log_group_name = aws_cloudwatch_log_group.trail.name

  pattern = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"

  metric_transformation {
    name          = "RootAccountUsage"
    namespace     = var.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "root_account_used" {
  alarm_name        = "${var.name_prefix}-root-account-used"
  alarm_description = "Root credentials were used. Everything routine runs through OIDC roles; this should never fire."

  namespace           = var.metric_namespace
  metric_name         = "RootAccountUsage"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0

  alarm_actions      = [var.alerts_topic_arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}
