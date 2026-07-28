#!/usr/bin/env bash
#
# One-time GitHub bootstrap for Fanos Bingo.
#
# The AWS side was already scripted. The GitHub side was not: repository
# variables, environments and protection rules were a list of instructions
# ending in "Settings > Environments", which is exactly the kind of setup that
# is done slightly differently every time and cannot be reviewed afterwards.
#
# THE PROD GATE IS THE REASON THIS EXISTS
#
# A GitHub Environment that does not exist is created IMPLICITLY, AND WITHOUT
# PROTECTION RULES, the first time a workflow references it. So `environment:
# prod` in a workflow is not a gate until somebody has created `prod` and
# ticked "required reviewers" by hand. A gate that depends on a human having
# clicked something is not a gate. This script creates it with the reviewer
# attached, and verifies it afterwards.
#
# IDEMPOTENT. Re-running is safe and is how you repair drift.
#
# Usage:
#   ./scripts/bootstrap-aws.sh          # writes .bootstrap-output.json
#   ./scripts/bootstrap-github.sh
#
#   # or, without the AWS step:
#   ACCOUNT_ID=... AWS_REGION=... ./scripts/bootstrap-github.sh
#
# Requires: gh, authenticated as someone with admin on the repository.

set -euo pipefail

BOOTSTRAP_OUTPUT="${BOOTSTRAP_OUTPUT:-.bootstrap-output.json}"
PROJECT="${PROJECT:-fanosbingo}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { echo "${GREEN}==>${NC} $*"; }
warn() { echo "${YELLOW}==>${NC} $*"; }
die()  { echo "${RED}ERROR:${NC} $*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh not found. https://cli.github.com"
command -v jq >/dev/null 2>&1 || die "jq not found. sudo apt install -y jq"

gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run 'gh auth login'."

# ---------------------------------------------------------------------------
# Inputs
#
# Read from the AWS bootstrap's output where possible, so the account id and
# role ARNs are never retyped. Environment variables override, for the case
# where the two halves are run by different people.
# ---------------------------------------------------------------------------
if [ -f "$BOOTSTRAP_OUTPUT" ]; then
  info "Reading ${BOOTSTRAP_OUTPUT}"
  ACCOUNT_ID="${ACCOUNT_ID:-$(jq -r '.account_id' "$BOOTSTRAP_OUTPUT")}"
  AWS_REGION="${AWS_REGION:-$(jq -r '.region' "$BOOTSTRAP_OUTPUT")}"
  REPO="${REPO:-$(jq -r '.repository' "$BOOTSTRAP_OUTPUT")}"
  STATE_BUCKET="${STATE_BUCKET:-$(jq -r '.state_bucket' "$BOOTSTRAP_OUTPUT")}"
  EXECUTOR_ROLE_ARN="${EXECUTOR_ROLE_ARN:-$(jq -r '.executor_role_arn' "$BOOTSTRAP_OUTPUT")}"
  PLANNER_ROLE_ARN="${PLANNER_ROLE_ARN:-$(jq -r '.planner_role_arn' "$BOOTSTRAP_OUTPUT")}"
else
  warn "${BOOTSTRAP_OUTPUT} not found — falling back to environment variables"
  [ -n "${ACCOUNT_ID:-}" ] || die "ACCOUNT_ID is required when ${BOOTSTRAP_OUTPUT} is absent"
  AWS_REGION="${AWS_REGION:-us-east-1}"
  REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
  STATE_BUCKET="${STATE_BUCKET:-${PROJECT}-tfstate-${ACCOUNT_ID}}"
  EXECUTOR_ROLE_ARN="${EXECUTOR_ROLE_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT}-terraform-executor}"
  PLANNER_ROLE_ARN="${PLANNER_ROLE_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/${PROJECT}-terraform-planner}"
fi

DOMAIN_NAME="${DOMAIN_NAME:-}"
ALERT_EMAIL="${ALERT_EMAIL:-}"

# Both are needed by every plan. Rather than writing an empty variable that
# fails opaquely inside Terraform, ask for them here where the message is clear.
if [ -z "$DOMAIN_NAME" ]; then
  DOMAIN_NAME="$(gh variable get DOMAIN_NAME --repo "$REPO" 2>/dev/null || true)"
fi
if [ -z "$ALERT_EMAIL" ]; then
  ALERT_EMAIL="$(gh variable get ALERT_EMAIL --repo "$REPO" 2>/dev/null || true)"
fi
[ -n "$DOMAIN_NAME" ] || die "DOMAIN_NAME is not set. Pass DOMAIN_NAME=example.org."
[ -n "$ALERT_EMAIL" ] || die "ALERT_EMAIL is not set. Pass ALERT_EMAIL=you@example.com."

VIEWER="$(gh api user --jq .login)"
REVIEWER="${PROD_REVIEWER:-$VIEWER}"

echo
echo "${BOLD}Fanos Bingo — GitHub bootstrap${NC}"
echo "  Repository: ${REPO}"
echo "  Account:    ${ACCOUNT_ID} (${AWS_REGION})"
echo "  Domain:     ${DOMAIN_NAME}"
echo "  Alerts:     ${ALERT_EMAIL}"
echo "  Reviewer:   ${REVIEWER} (required on prod)"
echo

# ---------------------------------------------------------------------------
# 1. Repository variables
#
# Variables, not secrets: none of these is confidential, and a variable is
# visible in the workflow log, which is what you want when debugging why a run
# targeted the wrong account.
# ---------------------------------------------------------------------------
info "Repository variables"

set_var() {
  local name="$1" value="$2"
  gh variable set "$name" --repo "$REPO" --body "$value" >/dev/null
  echo "  ${name} = ${value}"
}

set_var AWS_ACCOUNT_ID "$ACCOUNT_ID"
set_var AWS_REGION "$AWS_REGION"
set_var TF_STATE_BUCKET "$STATE_BUCKET"
set_var AWS_ROLE_ARN "$EXECUTOR_ROLE_ARN"
set_var AWS_PLANNER_ROLE_ARN "$PLANNER_ROLE_ARN"
set_var DOMAIN_NAME "$DOMAIN_NAME"
set_var ALERT_EMAIL "$ALERT_EMAIL"

# ---------------------------------------------------------------------------
# 2. Environments
#
# `gh api PUT /repos/{repo}/environments/{name}` both creates and updates, so
# this is idempotent by construction.
# ---------------------------------------------------------------------------
info "Environments"

create_environment() {
  local name="$1"
  gh api -X PUT "repos/${REPO}/environments/${name}" >/dev/null
  echo "  ${name} created"
}

for env_name in account dev prod; do
  create_environment "$env_name"
done

# The prod gate. Two independent controls, because either alone is insufficient:
#
#   * required reviewers -- a human approves before prod changes
#   * PROD_APPLY_ENABLED -- deliberately left UNSET here, so that merging to main
#                           plans prod and stops. Setting it is a conscious act
#                           taken when prod is genuinely ready, not something
#                           this script decides on your behalf.
info "Prod protection"

REVIEWER_ID="$(gh api "users/${REVIEWER}" --jq .id)"

# A JSON body rather than -f/-F flags: the reviewers field is an array of
# objects, and gh's field syntax does not express that reliably across versions.
require_reviewer() {
  local env_name="$1"

  jq -nc --argjson id "$REVIEWER_ID" '{
    wait_timer: 0,
    prevent_self_review: false,
    reviewers: [{type: "User", id: $id}],
    deployment_branch_policy: null
  }' | gh api -X PUT "repos/${REPO}/environments/${env_name}" --input - >/dev/null

  echo "  ${env_name}: required reviewer ${REVIEWER}"
}

# prod holds real balances; account owns the audit trail. Both are applied
# rarely and both are worth a second pair of eyes.
require_reviewer prod
require_reviewer account

# ---------------------------------------------------------------------------
# 3. Verify, rather than assume
#
# Creating a protection rule and confirming one is present are different things,
# and the whole point of this script is that the prod gate is real.
# ---------------------------------------------------------------------------
info "Verifying"

FAILURES=0

check() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  ${GREEN}ok${NC}   ${label}"
  else
    echo "  ${RED}BAD${NC}  ${label}: expected '${expected}', got '${actual}'"
    FAILURES=$((FAILURES + 1))
  fi
}

for env_name in account dev prod; do
  exists="$(gh api "repos/${REPO}/environments/${env_name}" --jq .name 2>/dev/null || echo "missing")"
  check "environment ${env_name} exists" "$exists" "$env_name"
done

for env_name in account prod; do
  reviewers="$(gh api "repos/${REPO}/environments/${env_name}" \
    --jq '[.protection_rules[]? | select(.type=="required_reviewers")] | length' 2>/dev/null || echo 0)"
  check "${env_name} has a required-reviewer rule" "$reviewers" "1"
done

# Unset is the correct state at bootstrap. Reported so it is a decision rather
# than an oversight.
PROD_ENABLED="$(gh variable get PROD_APPLY_ENABLED --repo "$REPO" 2>/dev/null || echo "unset")"
if [ "$PROD_ENABLED" = "true" ]; then
  warn "PROD_APPLY_ENABLED is 'true' — merges to main will APPLY to prod"
else
  echo "  ${GREEN}ok${NC}   PROD_APPLY_ENABLED is ${PROD_ENABLED} (merges plan prod and stop)"
fi

echo
if [ "$FAILURES" -ne 0 ]; then
  die "${FAILURES} check(s) failed. Do not treat prod as gated."
fi

cat <<EOF
${GREEN}${BOLD}GitHub bootstrap complete.${NC}

${BOLD}Secrets still need values.${NC} They are the one thing not derivable, and they
are set once, from here:

    gh secret set APP_JWT_SECRET              # openssl rand -hex 32
    gh secret set DB_APP_PASSWORD             # openssl rand -hex 24
    gh secret set DB_POSTGREST_PASSWORD       # openssl rand -hex 24
    gh secret set REALTIME_SECRET_KEY_BASE    # openssl rand -hex 32
    gh secret set REALTIME_DB_ENC_KEY         # EXACTLY 16 characters
    gh secret set REALTIME_METRICS_JWT_SECRET # openssl rand -hex 32
    gh secret set TELEGRAM_BOT_TOKEN
    gh secret set TELEGRAM_WEBHOOK_SECRET
    gh secret set APP_ADMIN_BOOTSTRAP_KEY
    gh secret set TLS_ORIGIN_CERT < origin.pem
    gh secret set TLS_ORIGIN_KEY  < origin.key

  Optional, and worth doing — it puts the last click-ops surface into code:

    gh secret set CLOUDFLARE_API_TOKEN
    gh variable set CLOUDFLARE_ZONE_ID --body '<zone id>'

${BOLD}Then everything else is workflows:${NC}

    gh workflow run terraform.yml    -f environment=account -f action=apply
    gh workflow run terraform.yml    -f environment=dev     -f action=apply
    gh workflow run sync-secrets.yml -f environment=dev
    gh workflow run deploy-services.yml -f service=ticker -f environment=dev
    gh workflow run db-migrate.yml   -f environment=dev -f dry_run=false

EOF
