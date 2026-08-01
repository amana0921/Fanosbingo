/**
 * Encryption keys.
 *
 * Two keys, for two genuinely different jobs.
 *
 * 1. `main` — a symmetric CMK encrypting data at rest: RDS storage, SSM
 *    SecureString parameters, CloudWatch log groups. Annual rotation is on;
 *    AWS keeps old key material so previously-encrypted data stays readable.
 *
 * 2. `wallet_signing` — an asymmetric secp256k1 key (the curve BSC and Ethereum
 *    use) that SIGNS withdrawal transactions. This is the one that matters.
 *    KMS will not export private key material under any circumstance, so there
 *    is no plaintext copy that can be committed to git, pasted into a settings
 *    table, or read out of a compromised database. That is precisely how the
 *    previous hot-wallet key leaked. Every signature is a CloudTrail event, so
 *    unexpected use is detectable rather than invisible.
 *
 * Cost: the symmetric CMK is $1/mo, the asymmetric key is $1/mo, plus a
 * negligible per-request charge. Cheap relative to what it prevents.
 */

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # The Auto Scaling service-linked role. scripts/bootstrap-aws.sh ensures it
  # exists, because KMS validates that principals in a key policy are real and a
  # brand-new account may not have created it yet.
  autoscaling_slr_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
}

# ---------------------------------------------------------------------------
# Encryption at rest
# ---------------------------------------------------------------------------
resource "aws_kms_key" "main" {
  description             = "${var.name_prefix} encryption at rest (RDS, SSM, logs)"
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-main" })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.name_prefix}-main"
  target_key_id = aws_kms_key.main.key_id
}

# Allow CloudWatch Logs to use the key, otherwise encrypted log groups fail to
# create with an opaque permissions error.
data "aws_iam_policy_document" "main" {
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
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }

  # ALARMS PUBLISHING TO THE ENCRYPTED ALERT TOPIC.
  #
  # modules/monitoring encrypts its SNS topic with this key. Without this
  # statement CloudWatch cannot produce a data key to encrypt the message, so an
  # alarm transitioning to ALARM fails to publish and THE NOTIFICATION IS
  # DROPPED. Silently: the alarm state changes correctly, the console shows
  # ALARM, the subscription shows confirmed, and nothing arrives.
  #
  # THIS LESSON WAS ALREADY LEARNED ONCE, in infra/environments/account/main.tf,
  # whose audit key carries the same statement with the comment "the notification
  # is dropped -- silently, which is the worst possible outcome for a security
  # alarm". It was never applied here, so while the account-wide kms:Sign and
  # root-usage alarms could deliver, EVERY PER-ENVIRONMENT ALARM could not --
  # including game-loop-stalled, which modules/monitoring calls "THE alarm ...
  # the one that describes whether the game is running".
  #
  # Found by firing an alarm deliberately with scripts/verify-alarms.sh --fire
  # and getting no email, having already confirmed the subscription, the alarm
  # state and the metric datapoints. Each of those looked correct on its own;
  # the failure was in the one link nothing inspected.
  #
  # Note that attaching an aws_kms_key_policy REPLACES the default policy, so
  # "root has kms:* therefore IAM delegation covers it" does not apply to a
  # service principal here -- the same trap the Auto Scaling statement below
  # documents.
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

  # Auto Scaling must be able to use this key to encrypt the root volume of each
  # instance it launches. Without these two statements the ASG launches an
  # instance, fails to attach the encrypted volume, terminates it, and retries
  # forever — reporting:
  #
  #   Client.InvalidKMSKey.InvalidState: The KMS key provided is in an
  #   incorrect state
  #
  # which is actively misleading: the key is enabled and healthy, and the actual
  # problem is authorisation. Note that attaching an aws_kms_key_policy REPLACES
  # the default policy, so the usual "root has kms:* therefore IAM delegation
  # covers it" reasoning does not apply to service-linked roles here.
  statement {
    sid    = "AllowAutoScalingUseOfKey"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [local.autoscaling_slr_arn]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  # Separate statement because CreateGrant needs the grant-is-for-AWS-resource
  # condition; Auto Scaling creates a grant per volume it encrypts.
  statement {
    sid    = "AllowAutoScalingToCreateGrants"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [local.autoscaling_slr_arn]
    }
    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_kms_key_policy" "main" {
  key_id = aws_kms_key.main.id
  policy = data.aws_iam_policy_document.main.json
}

# ---------------------------------------------------------------------------
# Hot-wallet signing key
# ---------------------------------------------------------------------------
resource "aws_kms_key" "wallet_signing" {
  description              = "${var.name_prefix} withdrawal signing key (non-exportable secp256k1)"
  customer_master_key_spec = "ECC_SECG_P256K1"
  key_usage                = "SIGN_VERIFY"
  deletion_window_in_days  = var.deletion_window_in_days

  # Rotation is not supported for asymmetric keys, and would be wrong here
  # anyway: rotating means deriving a new wallet address and migrating funds on
  # chain. That is a deliberate operational exercise, not a background job.

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-wallet-signing"
    Role = "hot-wallet"
  })
}

resource "aws_kms_alias" "wallet_signing" {
  name          = "alias/${var.name_prefix}-wallet-signing"
  target_key_id = aws_kms_key.wallet_signing.key_id
}
