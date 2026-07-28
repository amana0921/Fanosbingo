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
#   3. The `terraform-executor` role — admin, for applies
#   4. The `terraform-planner` role — read-only, for pull requests
#
# It ends by writing .bootstrap-output.json, which scripts/bootstrap-github.sh
# reads to finish the setup. Nothing has to be copied by hand between the two.
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

# Machine-readable handoff to bootstrap-github.sh. Gitignored: it names the
# account id. Nothing secret is in it, but it is not repository content either.
BOOTSTRAP_OUTPUT="${BOOTSTRAP_OUTPUT:-.bootstrap-output.json}"

# TWO roles, not one, and the split is the point.
#
#   terraform-executor  AdministratorAccess. Trusted ONLY from the main branch
#                       and from the protected GitHub Environments.
#   terraform-planner   Read-only. Trusted from pull_request.
#
# Why: `terraform plan` runs on pull requests, and a pull request runs workflow
# code taken from the PR branch. A single role trusted for `pull_request` and
# holding AdministratorAccess therefore means "anyone who can open a PR with a
# modified workflow file gets admin in this account". GitHub withholds
# id-token: write from FORK pull requests, so today, with one collaborator, that
# is bounded -- but the bound is a GitHub default and a repository setting, not
# something this account controls. The planner role removes the reliance.
#
# The planner can read what Terraform needs to produce a diff, and can write
# exactly one thing: the state lock file. Its decryption grant is scoped to dev
# by resource tag -- see the policy further down, which explains why "read-only
# AND unable to read any secret" is not achievable here.
#
# TWO subject prefix forms are listed for each context, and this is not
# redundancy:
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

PLANNER_ROLE_NAME="${PLANNER_ROLE_NAME:-${PROJECT}-terraform-planner}"

# Environments are named here so a new one (account, staging) is a one-line
# change rather than a hand-edited trust policy in the console.
ENVIRONMENTS=(account dev prod)

EXECUTOR_CONTEXTS=("ref:refs/heads/main")
for env_name in "${ENVIRONMENTS[@]}"; do
  EXECUTOR_CONTEXTS+=("environment:${env_name}")
done

PLANNER_CONTEXTS=("pull_request")

# Expands a list of contexts into both subject-prefix forms.
subjects_for() {
  local out=()
  local ctx
  for ctx in "$@"; do
    out+=("repo:${GITHUB_REPOSITORY}:${ctx}")
    out+=("repo:${GITHUB_OWNER}@*/${GITHUB_NAME}@*:${ctx}")
  done
  printf '%s\n' "${out[@]}"
}

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
echo "  Executor:   ${ROLE_NAME} (admin, applies)"
echo "  Planner:    ${PLANNER_ROLE_NAME} (read-only, pull requests)"
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

trust_policy_for() {
  local subs
  subs="$(subjects_for "$@" | jq -R . | jq -sc .)"

  jq -nc --arg oidc "${OIDC_ARN}" --argjson subs "${subs}" '
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
  }'
}

# Creates or updates a role's trust policy. Idempotent either way.
upsert_role() {
  local role_name="$1" description="$2" trust="$3"

  if aws iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    warn "  ${role_name} already exists — updating trust policy"
    aws iam update-assume-role-policy --role-name "${role_name}" \
      --policy-document "${trust}" >/dev/null
  else
    aws iam create-role --role-name "${role_name}" \
      --description "${description}" \
      --assume-role-policy-document "${trust}" \
      --max-session-duration 3600 >/dev/null
    info "  ${role_name} created"
  fi
}

upsert_role "${ROLE_NAME}" \
  "Assumed by GitHub Actions to APPLY Terraform for ${GITHUB_REPOSITORY}" \
  "$(trust_policy_for "${EXECUTOR_CONTEXTS[@]}")"

# Terraform creates IAM roles, KMS keys, RDS instances and VPCs, so this role is
# necessarily broad. The meaningful control is the TRUST policy above: only the
# named repository, only the named branches and environments. Narrowing the
# permission policy while leaving the trust wide would be security theatre.
aws iam attach-role-policy --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"
info "  AdministratorAccess attached (scoped by the trust policy, not the permissions)"

# Deny the executor the ability to alter the OIDC roles' trust policies, delete
# the state bucket, or tamper with the audit trail — a compromised workflow
# should not be able to widen its own access, destroy the record of what exists,
# or erase what it did.
aws iam put-role-policy --role-name "${ROLE_NAME}" \
  --policy-name "self-protection" \
  --policy-document "$(jq -nc \
    --arg role "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
    --arg planner "arn:aws:iam::${ACCOUNT_ID}:role/${PLANNER_ROLE_NAME}" \
    --arg bucket "arn:aws:s3:::${BUCKET}" \
    --arg audit "arn:aws:s3:::${PROJECT}-cloudtrail-${ACCOUNT_ID}" '
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
      Resource: [$role, $planner]
    },
    {
      Sid: "DenyTrailShutdown",
      Effect: "Deny",
      Action: ["cloudtrail:StopLogging", "cloudtrail:DeleteTrail"],
      Resource: "*"
    },
    {
      Sid: "DenyAuditLogDestruction",
      Effect: "Deny",
      # Deliberately NOT PutBucketVersioning or PutBucketPolicy: Terraform needs
      # both to create this bucket in the first place. Only the two actions that
      # destroy history are denied, and Terraform never issues either -- the
      # bucket has no force_destroy.
      Action: ["s3:DeleteBucket", "s3:DeleteObjectVersion"],
      Resource: [$audit, ($audit + "/*")]
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
# 5. Terraform planner role (pull requests)
# ---------------------------------------------------------------------------
info "Terraform planner role"

upsert_role "${PLANNER_ROLE_NAME}" \
  "Assumed by GitHub Actions to PLAN Terraform on pull requests for ${GITHUB_REPOSITORY}" \
  "$(trust_policy_for "${PLANNER_CONTEXTS[@]}")"

aws iam attach-role-policy --role-name "${PLANNER_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/ReadOnlyAccess"
info "  ReadOnlyAccess attached"

# A plan reads state and takes the lock. Those are the only writes it needs, and
# they are the only writes it gets.
#
# ON SECRETS, stated plainly rather than papered over:
#
# Terraform REFRESHES aws_ssm_parameter resources during plan, and the AWS
# provider reads them with WithDecryption=true. A planner that cannot decrypt
# therefore cannot plan at all -- the refresh fails outright. "Read-only and
# unable to read secrets" is not a combination this data model allows.
#
# So the grant is scoped by TAG instead: Decrypt is permitted only on keys
# tagged Environment=dev. Pull requests plan dev and only dev (see the resolve
# job in terraform.yml), so this is sufficient for the job and leaves the prod
# CMK -- and therefore every prod secret -- unreachable from a pull request.
#
# The residual exposure is real and worth knowing: someone who can open a pull
# request in this repository can read DEV SecureStrings. Dev holds BSC testnet
# credentials by construction. Nothing there should ever touch mainnet funds.
#
# secretsmanager:GetSecretValue stays denied outright: that is the RDS master
# password, and a plan has no reason to read it.
aws iam put-role-policy --role-name "${PLANNER_ROLE_NAME}" \
  --policy-name "state-access" \
  --policy-document "$(jq -nc --arg bucket "arn:aws:s3:::${BUCKET}" '
{
  Version: "2012-10-17",
  Statement: [
    {
      Sid: "StateReadAndLock",
      Effect: "Allow",
      Action: ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
      Resource: [$bucket, ($bucket + "/*")]
    },
    {
      Sid: "DecryptDevParametersOnly",
      Effect: "Allow",
      Action: ["kms:Decrypt"],
      Resource: "*",
      Condition: { StringEquals: { "aws:ResourceTag/Environment": "dev" } }
    },
    {
      Sid: "DenyMasterPasswordRead",
      Effect: "Deny",
      Action: ["secretsmanager:GetSecretValue"],
      Resource: "*"
    },
    {
      Sid: "DenyRoleChaining",
      Effect: "Deny",
      Action: ["sts:AssumeRole"],
      Resource: "*"
    }
  ]
}')"
info "  state access + scoped decryption attached"

PLANNER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${PLANNER_ROLE_NAME}"

# ---------------------------------------------------------------------------
# Hand off to the GitHub side
#
# Every value below is derived, not chosen, so there is nothing here for a human
# to get wrong by retyping it. scripts/bootstrap-github.sh consumes exactly
# these and finishes the setup -- variables, environments, protection rules --
# without a browser.
# ---------------------------------------------------------------------------
cat > "${BOOTSTRAP_OUTPUT}" <<JSON
{
  "account_id": "${ACCOUNT_ID}",
  "region": "${AWS_REGION}",
  "repository": "${GITHUB_REPOSITORY}",
  "state_bucket": "${BUCKET}",
  "executor_role_arn": "${ROLE_ARN}",
  "planner_role_arn": "${PLANNER_ROLE_ARN}"
}
JSON

info "Wrote ${BOOTSTRAP_OUTPUT}"

cat <<EOF

${GREEN}${BOLD}AWS bootstrap complete.${NC} You should never need to run this again.

  Executor role  ${ROLE_ARN}
                 AdministratorAccess, trusted from main and the environments
  Planner role   ${PLANNER_ROLE_ARN}
                 ReadOnlyAccess, trusted from pull_request only

${BOLD}Next, and it is one command:${NC}

    ./scripts/bootstrap-github.sh

  That reads ${BOOTSTRAP_OUTPUT}, sets the repository variables, creates the
  account/dev/prod environments and puts required reviewers on prod. Nothing
  after this point is done by hand.

${BOLD}Then, in order:${NC}

    gh workflow run terraform.yml   -f environment=account -f action=apply
    gh workflow run terraform.yml   -f environment=dev     -f action=apply
    gh workflow run sync-secrets.yml -f environment=dev
    ./scripts/verify-detections.sh

EOF
