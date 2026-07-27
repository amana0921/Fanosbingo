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
