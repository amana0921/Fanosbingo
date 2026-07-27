#!/usr/bin/env bash
#
# Post-apply operations.
#
# These are things Terraform cannot express as resources — they are operations
# on resources, not declarations of them. Running them from a script keeps them
# automated and repeatable rather than living in a runbook nobody reads.
#
# IDEMPOTENT: safe to run after every apply. Each step checks whether it is
# actually needed before doing anything.
#
# Usage:
#   ./scripts/post-apply.sh dev
#   ./scripts/post-apply.sh prod

set -euo pipefail

ENVIRONMENT="${1:-${ENVIRONMENT:-}}"
PROJECT="${PROJECT:-fanosbingo}"

[ -n "$ENVIRONMENT" ] || { echo "Usage: $0 <dev|prod>" >&2; exit 1; }

PREFIX="${PROJECT}-${ENVIRONMENT}"
DB_ID="${PREFIX}-pg"
WALLET_KEY_ALIAS="alias/${PREFIX}-wallet-signing"

GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { echo "${GREEN}==>${NC} $*"; }
warn() { echo "${YELLOW}==>${NC} $*"; }

echo
echo "${BOLD}Post-apply — ${ENVIRONMENT}${NC}"
echo

# ---------------------------------------------------------------------------
# 1. Reboot RDS if static parameters are pending
#
# rds.logical_replication and shared_preload_libraries are STATIC parameters:
# they do not take effect until the instance restarts. This matters more than it
# sounds — without wal_level=logical, the Realtime container starts cleanly,
# connects cleanly, and then silently delivers nothing. There is no error to
# chase, which makes it a genuinely expensive hour to debug.
#
# Only reboots when AWS reports the parameter group as pending-reboot, so this is
# a no-op on a steady-state apply.
# ---------------------------------------------------------------------------
info "Checking RDS parameter group status"

if ! aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
  warn "  $DB_ID not found — skipping (has terraform apply run?)"
else
  apply_status="$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].DBParameterGroups[0].ParameterApplyStatus' \
    --output text)"

  info "  status: $apply_status"

  if [ "$apply_status" = "pending-reboot" ]; then
    info "  rebooting to apply static parameters"
    aws rds reboot-db-instance --db-instance-identifier "$DB_ID" >/dev/null
    info "  waiting for availability (this takes a few minutes)"
    aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
    info "  reboot complete"
  else
    info "  no reboot needed"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Publish the hot-wallet address
#
# Derived from the KMS public key. The private half never leaves KMS, so unlike
# the wallet this replaces, there is nothing here that could be committed.
# Stored in SSM so the application reads it as configuration rather than having
# it hardcoded anywhere.
# ---------------------------------------------------------------------------
info "Deriving hot-wallet address"

if ! aws kms describe-key --key-id "$WALLET_KEY_ALIAS" >/dev/null 2>&1; then
  warn "  $WALLET_KEY_ALIAS not found — skipping"
elif [ ! -f "node_modules/viem/package.json" ]; then
  warn "  node_modules missing — run 'npm ci' first, skipping"
else
  address="$(OUTPUT_FORMAT=plain node scripts/derive-wallet-address.mjs "$WALLET_KEY_ALIAS")"
  info "  address: $address"

  current="$(aws ssm get-parameter --name "/${PREFIX}/bsc/hot_wallet_address" \
    --query 'Parameter.Value' --output text 2>/dev/null || echo "")"

  if [ "$current" = "$address" ]; then
    info "  already published to SSM"
  else
    aws ssm put-parameter \
      --name "/${PREFIX}/bsc/hot_wallet_address" \
      --type String --value "$address" --overwrite \
      --description "Derived from ${WALLET_KEY_ALIAS}; private key is non-exportable" \
      --no-cli-pager >/dev/null
    info "  published to /${PREFIX}/bsc/hot_wallet_address"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Report what still needs a human
# ---------------------------------------------------------------------------
echo
info "Remaining manual items"

unconfirmed="$(aws sns list-subscriptions-by-topic \
  --topic-arn "$(aws sns list-topics --query "Topics[?contains(TopicArn, '${PREFIX}-alerts')].TopicArn | [0]" --output text 2>/dev/null)" \
  --query "Subscriptions[?SubscriptionArn=='PendingConfirmation'].Endpoint" \
  --output text 2>/dev/null || echo "")"

if [ -n "$unconfirmed" ] && [ "$unconfirmed" != "None" ]; then
  warn "  SNS subscriptions awaiting confirmation: $unconfirmed"
  warn "  Until confirmed, every alarm fires into the void. AWS requires the"
  warn "  recipient to click the emailed link — it cannot be automated."
else
  info "  SNS subscriptions confirmed"
fi

placeholders="$(aws ssm get-parameters-by-path --path "/${PREFIX}" --recursive --with-decryption \
  --query "Parameters[?Value=='PLACEHOLDER_SET_ME_OUT_OF_BAND'].Name" --output text 2>/dev/null || echo "")"

if [ -n "$placeholders" ] && [ "$placeholders" != "None" ]; then
  warn "  Secrets still unset:"
  echo "$placeholders" | tr '\t' '\n' | sed 's/^/      /'
  warn "  Run the 'Sync secrets to SSM' workflow after setting the GitHub Secrets."
else
  info "  All secrets populated"
fi

echo
info "Done"
