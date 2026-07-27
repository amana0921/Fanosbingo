#!/usr/bin/env bash
#
# One-time AWS bootstrap for Fanos Bingo.
#
# This is the ONLY step that is not automated, and it exists because of an
# unavoidable chicken-and-egg problem: GitHub Actions authenticates to AWS via
# an OIDC role, but that role has to be created by something that is already
# authenticated. Everything after this runs in CI with no long-lived credentials.
#
# It creates:
#   1. The S3 bucket holding Terraform state (versioned, encrypted, private)
#   2. The GitHub OIDC identity provider
#   3. The `terraform-executor` role that the infra workflows assume
#
# The script is IDEMPOTENT. Re-running it is safe and is the intended way to
# repair drift — it reports what already exists rather than failing.
#
# Usage:
#   ./scripts/bootstrap-aws.sh
#   GITHUB_REPOSITORY=owner/repo AWS_REGION=us-east-1 ./scripts/bootstrap-aws.sh
#
# Requires: AWS CLI authenticated with permissions to create IAM roles and S3
# buckets. An account administrator, in practice, and only this once.

set -euo pipefail

GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-amana0921/Fanosbingo}"
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-fanosbingo}"
ROLE_NAME="${ROLE_NAME:-${PROJECT}-terraform-executor}"

# Contexts permitted to assume the role. Deliberately not a bare "*", which
# would let any workflow in any repository run Terraform against this account.
#
# TWO prefix forms are listed for each context, and this is not redundancy:
#
#   repo:owner/name:...              the classic, documented form
#   repo:owner@<id>/name@<id>:...    GitHub's IMMUTABLE subject prefix
#
# GitHub now emits subject claims containing numeric owner and repository IDs,
# so that renaming an account or repository does not silently break trust
# policies. The consequence is that a trust policy written the documented way
# matches nothing, and STS returns a flatly unhelpful "Not authorized to perform
# sts:AssumeRoleWithWebIdentity". Check which form your repository emits with:
#
#   gh api repos/OWNER/NAME/actions/oidc/customization/sub
#
# The wildcards only cover the numeric IDs. Account names cannot contain "@", so
# "owner@*" still pins the owner name exactly — the scoping is not weakened.
GITHUB_OWNER="${GITHUB_REPOSITORY%%/*}"
GITHUB_NAME="${GITHUB_REPOSITORY##*/}"

ALLOWED_CONTEXTS=(
  "ref:refs/heads/main"
  "environment:dev"
  "environment:prod"
  "pull_request"
)

ALLOWED_SUBJECTS=()
for ctx in "${ALLOWED_CONTEXTS[@]}"; do
  ALLOWED_SUBJECTS+=("repo:${GITHUB_REPOSITORY}:${ctx}")
  ALLOWED_SUBJECTS+=("repo:${GITHUB_OWNER}@*/${GITHUB_NAME}@*:${ctx}")
done

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info()  { echo "${GREEN}==>${NC} $*"; }
warn()  { echo "${YELLOW}==>${NC} $*"; }
die()   { echo "${RED}ERROR:${NC} $*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || die "AWS CLI not found. Install it first."
command -v jq  >/dev/null 2>&1 || die "jq not found. Install it: sudo apt install -y jq"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "Not authenticated to AWS. Run 'aws configure' first."
CALLER="$(aws sts get-caller-identity --query Arn --output text)"

BUCKET="${PROJECT}-tfstate-${ACCOUNT_ID}"

echo
echo "${BOLD}Fanos Bingo — AWS bootstrap${NC}"
echo "  Account:    ${ACCOUNT_ID}"
echo "  Caller:     ${CALLER}"
echo "  Region:     ${AWS_REGION}"
echo "  Repository: ${GITHUB_REPOSITORY}"
echo "  State:      s3://${BUCKET}"
echo "  Role:       ${ROLE_NAME}"
echo

# ---------------------------------------------------------------------------
# 1. Terraform state bucket
# ---------------------------------------------------------------------------
info "State bucket"

if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  warn "  s3://${BUCKET} already exists — leaving it alone"
else
  # us-east-1 rejects a LocationConstraint; every other region requires one.
  if [ "${AWS_REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET}" --region "${AWS_REGION}" >/dev/null
  else
    aws s3api create-bucket --bucket "${BUCKET}" --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  info "  created s3://${BUCKET}"
fi

# Versioning is not optional. State corruption is only recoverable from a prior
# version, and there is no other copy of it anywhere.
aws s3api put-bucket-versioning --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled
info "  versioning enabled"

aws s3api put-bucket-encryption --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
info "  encryption enabled"

# State contains RDS endpoints and every attribute Terraform manages. It must
# never be public.
aws s3api put-public-access-block --bucket "${BUCKET}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
info "  public access blocked"

# Expire old state versions after 90 days so the bucket does not grow forever.
aws s3api put-bucket-lifecycle-configuration --bucket "${BUCKET}" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "expire-old-state-versions",
      "Status": "Enabled",
      "Filter": {"Prefix": ""},
      "NoncurrentVersionExpiration": {"NoncurrentDays": 90},
      "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 7}
    }]
  }'
info "  lifecycle policy set"

# ---------------------------------------------------------------------------
# 2. Auto Scaling service-linked role
#
# The KMS key policy grants this role permission to encrypt instance root
# volumes. KMS validates that principals named in a key policy actually exist,
# so on a brand-new account the Terraform apply would fail with
# MalformedPolicyDocumentException before it ever got as far as launching an
# instance. AWS normally creates this role lazily on first ASG use, which is too
# late for us.
# ---------------------------------------------------------------------------
info "Auto Scaling service-linked role"

if aws iam get-role --role-name AWSServiceRoleForAutoScaling >/dev/null 2>&1; then
  warn "  already exists — reusing"
else
  aws iam create-service-linked-role \
    --aws-service-name autoscaling.amazonaws.com >/dev/null 2>&1 \
    && info "  created" \
    || warn "  could not create (it may already exist under a custom suffix)"
fi

# ---------------------------------------------------------------------------
# 3. GitHub OIDC provider (account-wide, exactly one per account)
# ---------------------------------------------------------------------------
info "GitHub OIDC provider"

OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" >/dev/null 2>&1; then
  warn "  already exists — reusing"
else
  aws iam create-open-id-connect-provider \
    --url "https://token.actions.githubusercontent.com" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1" >/dev/null
  info "  created"
fi

# ---------------------------------------------------------------------------
# 4. Terraform executor role
# ---------------------------------------------------------------------------
info "Terraform executor role"

# Report the prefix GitHub actually emits, so a mismatch is visible here rather
# than as an opaque STS rejection thirty minutes later.
if command -v gh >/dev/null 2>&1; then
  actual_prefix="$(gh api "repos/${GITHUB_REPOSITORY}/actions/oidc/customization/sub" \
    --jq '.sub_claim_prefix' 2>/dev/null || echo "")"
  if [ -n "$actual_prefix" ]; then
    info "  GitHub emits subject prefix: ${actual_prefix}"
  fi
fi

SUBJECT_JSON="$(printf '%s\n' "${ALLOWED_SUBJECTS[@]}" | jq -R . | jq -sc .)"

TRUST_POLICY="$(jq -nc \
  --arg oidc "${OIDC_ARN}" \
  --argjson subs "${SUBJECT_JSON}" '
{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Principal: { Federated: $oidc },
    Action: "sts:AssumeRoleWithWebIdentity",
    Condition: {
      StringEquals: { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      StringLike:   { "token.actions.githubusercontent.com:sub": $subs }
    }
  }]
}')"

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  warn "  already exists — updating trust policy"
  aws iam update-assume-role-policy --role-name "${ROLE_NAME}" \
    --policy-document "${TRUST_POLICY}" >/dev/null
else
  aws iam create-role --role-name "${ROLE_NAME}" \
    --description "Assumed by GitHub Actions to run Terraform for ${GITHUB_REPOSITORY}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --max-session-duration 3600 >/dev/null
  info "  created"
fi

# Terraform creates IAM roles, KMS keys, RDS instances and VPCs, so this role is
# necessarily broad. The meaningful control is the TRUST policy above: only the
# named repository, only the named branches and environments. Narrowing the
# permission policy while leaving the trust wide would be security theatre.
aws iam attach-role-policy --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"
info "  AdministratorAccess attached (scoped by the trust policy, not the permissions)"

# Deny the executor the ability to alter its own trust policy or delete the
# state bucket — a compromised workflow should not be able to widen its own
# access or destroy the record of what exists.
aws iam put-role-policy --role-name "${ROLE_NAME}" \
  --policy-name "self-protection" \
  --policy-document "$(jq -nc --arg role "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" --arg bucket "arn:aws:s3:::${BUCKET}" '
{
  Version: "2012-10-17",
  Statement: [
    {
      Sid: "DenySelfTrustModification",
      Effect: "Deny",
      Action: [
        "iam:UpdateAssumeRolePolicy",
        "iam:DeleteRole",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy"
      ],
      Resource: $role
    },
    {
      Sid: "DenyStateBucketDeletion",
      Effect: "Deny",
      Action: ["s3:DeleteBucket", "s3:PutBucketPolicy", "s3:PutBucketVersioning"],
      Resource: $bucket
    },
    {
      Sid: "DenyOidcProviderDeletion",
      Effect: "Deny",
      Action: ["iam:DeleteOpenIDConnectProvider"],
      Resource: "*"
    }
  ]
}')"
info "  self-protection guardrails attached"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
cat <<EOF

${GREEN}${BOLD}Bootstrap complete.${NC} You should never need to run this again.

${BOLD}Next: add these to GitHub${NC}
  Settings > Secrets and variables > Actions > Variables

    AWS_ROLE_ARN        ${ROLE_ARN}
    AWS_REGION          ${AWS_REGION}
    TF_STATE_BUCKET     ${BUCKET}

  Set them in one command with the GitHub CLI:

    gh variable set AWS_ROLE_ARN    --body "${ROLE_ARN}"
    gh variable set AWS_REGION      --body "${AWS_REGION}"
    gh variable set TF_STATE_BUCKET --body "${BUCKET}"

${BOLD}Then: create the GitHub Environments${NC}
  Settings > Environments

    dev   — no protection needed
    prod  — enable "Required reviewers" (yourself). This is what stops an
            accidental merge from applying to the environment holding real money.

${BOLD}After that${NC}, every change goes through a pull request. Nothing is applied
by hand again.

EOF
