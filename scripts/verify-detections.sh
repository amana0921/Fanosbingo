#!/usr/bin/env bash
#
# Prove the CloudTrail detections actually detect.
#
# A detector that has never seen a positive is not a detector. The Trivy secret
# rules and scripts/probe-public-access.sh were each verified against
# deliberately malicious bait before being trusted; the kms:Sign alarm gets the
# same treatment here.
#
# WHAT THIS DOES NOT DO
#
# It does not call kms:Sign. The hot-wallet key signs 32-byte digests, and a
# digest you did not construct carefully is potentially a valid BSC transaction
# hash -- "just testing" is not a safe reason to produce a signature over
# attacker-chosen bytes with a key that controls real funds.
#
# Instead it tests the deployed filter patterns against synthetic CloudTrail
# events with `aws logs test-metric-filter`, which is the same matching engine
# CloudWatch runs in production. Two assertions per detection, and the second
# one is the one people skip:
#
#   1. Bait matches      -- the detection fires on the thing it is for
#   2. Benign traffic does NOT match -- it is not simply matching everything
#
# A filter that matches everything looks identical to a working one until the
# day it pages you at 3am about a legitimate withdrawal.
#
# The patterns are read from the DEPLOYED filters rather than restated here, so
# this cannot pass against a pattern that differs from what is actually running.
#
# Usage:
#   ./scripts/verify-detections.sh [project_name]

set -euo pipefail

PROJECT="${1:-${PROJECT:-fanosbingo}}"
LOG_GROUP="/aws/cloudtrail/${PROJECT}"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
pass()  { echo "  ${GREEN}PASS${NC} $*"; }
fail()  { echo "  ${RED}FAIL${NC} $*"; FAILURES=$((FAILURES + 1)); }
info()  { echo "${GREEN}==>${NC} $*"; }
warn()  { echo "${YELLOW}==>${NC} $*"; }

FAILURES=0

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

echo
echo "${BOLD}Detection verification — ${PROJECT}${NC}"
echo "  Log group: ${LOG_GROUP}"
echo

if ! aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
     --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -qx "$LOG_GROUP"; then
  echo "${RED}ERROR:${NC} log group ${LOG_GROUP} does not exist." >&2
  echo "Apply the account root first: gh workflow run terraform.yml -f environment=account -f action=apply" >&2
  exit 1
fi

# Reads the pattern that is actually deployed. Restating it here would let this
# script pass while the live filter says something else entirely.
get_pattern() {
  local filter_name="$1"
  aws logs describe-metric-filters \
    --log-group-name "$LOG_GROUP" \
    --filter-name-prefix "$filter_name" \
    --query 'metricFilters[0].filterPattern' \
    --output text 2>/dev/null
}

# Returns the number of synthetic events the pattern matched.
count_matches() {
  local pattern="$1" event="$2"
  aws logs test-metric-filter \
    --filter-pattern "$pattern" \
    --log-event-messages "$event" \
    --query 'length(matches)' \
    --output text 2>/dev/null || echo "ERROR"
}

assert_matches() {
  local label="$1" pattern="$2" event="$3"
  local n; n="$(count_matches "$pattern" "$event")"
  if [ "$n" = "1" ]; then pass "$label"; else fail "$label (expected a match, got '$n')"; fi
}

assert_no_match() {
  local label="$1" pattern="$2" event="$3"
  local n; n="$(count_matches "$pattern" "$event")"
  if [ "$n" = "0" ]; then pass "$label"; else fail "$label (expected NO match, got '$n')"; fi
}

# A CloudTrail record for an assumed-role caller. The principal lives in
# sessionContext.sessionIssuer.userName -- userIdentity.userName is absent for
# role sessions, and a filter on an absent field silently never matches, which
# is precisely the failure this script exists to catch.
kms_sign_event() {
  local role="$1"
  jq -nc --arg role "$role" '{
    eventVersion: "1.09",
    eventSource:  "kms.amazonaws.com",
    eventName:    "Sign",
    awsRegion:    "us-east-1",
    eventType:    "AwsApiCall",
    userIdentity: {
      type: "AssumedRole",
      arn:  "arn:aws:sts::292123551166:assumed-role/\($role)/session",
      sessionContext: { sessionIssuer: { type: "Role", userName: $role } }
    }
  }'
}

# ---------------------------------------------------------------------------
info "Detection: kms:Sign by an unexpected principal"

SIGN_PATTERN="$(get_pattern "${PROJECT}-unexpected-kms-sign")"
if [ -z "$SIGN_PATTERN" ] || [ "$SIGN_PATTERN" = "None" ]; then
  fail "filter ${PROJECT}-unexpected-kms-sign is not deployed"
else
  echo "  pattern: ${SIGN_PATTERN}"

  # Bait: signing by a principal that is not on the permitted list.
  assert_matches "fires on signing by an arbitrary role" \
    "$SIGN_PATTERN" "$(kms_sign_event "some-random-role")"

  assert_matches "fires on signing by the terraform executor" \
    "$SIGN_PATTERN" "$(kms_sign_event "${PROJECT}-terraform-executor")"

  # Benign: the roles that are supposed to sign, and an unrelated KMS call.
  for env in dev prod; do
    assert_no_match "stays quiet for ${PROJECT}-${env}-task-functions" \
      "$SIGN_PATTERN" "$(kms_sign_event "${PROJECT}-${env}-task-functions")"
  done

  assert_no_match "stays quiet for kms:Decrypt (secret injection, constant traffic)" \
    "$SIGN_PATTERN" "$(jq -nc '{
      eventSource: "kms.amazonaws.com", eventName: "Decrypt", eventType: "AwsApiCall",
      userIdentity: { type: "AssumedRole",
        sessionContext: { sessionIssuer: { userName: "fanosbingo-dev-task-execution" } } }
    }')"

  assert_no_match "stays quiet for an unrelated service" \
    "$SIGN_PATTERN" "$(jq -nc '{
      eventSource: "s3.amazonaws.com", eventName: "GetObject", eventType: "AwsApiCall",
      userIdentity: { type: "AssumedRole",
        sessionContext: { sessionIssuer: { userName: "some-random-role" } } }
    }')"
fi

echo

# ---------------------------------------------------------------------------
info "Detection: root credential use"

ROOT_PATTERN="$(get_pattern "${PROJECT}-root-account-used")"
if [ -z "$ROOT_PATTERN" ] || [ "$ROOT_PATTERN" = "None" ]; then
  fail "filter ${PROJECT}-root-account-used is not deployed"
else
  echo "  pattern: ${ROOT_PATTERN}"

  assert_matches "fires on a root API call" \
    "$ROOT_PATTERN" "$(jq -nc '{
      eventSource: "iam.amazonaws.com", eventName: "CreateUser", eventType: "AwsApiCall",
      userIdentity: { type: "Root", arn: "arn:aws:iam::292123551166:root" }
    }')"

  # AWS itself acts as Root for routine service events. Alarming on those would
  # make the detection useless within a day.
  assert_no_match "stays quiet for an AWS service event" \
    "$ROOT_PATTERN" "$(jq -nc '{
      eventSource: "s3.amazonaws.com", eventName: "PutObject", eventType: "AwsServiceEvent",
      userIdentity: { type: "Root", invokedBy: "cloudtrail.amazonaws.com" }
    }')"

  assert_no_match "stays quiet for a normal role call" \
    "$ROOT_PATTERN" "$(jq -nc '{
      eventSource: "ecs.amazonaws.com", eventName: "UpdateService", eventType: "AwsApiCall",
      userIdentity: { type: "AssumedRole",
        sessionContext: { sessionIssuer: { userName: "fanosbingo-dev-github-deploy" } } }
    }')"
fi

echo

# ---------------------------------------------------------------------------
info "Trail is actually logging"

TRAIL_STATUS="$(aws cloudtrail get-trail-status --name "$PROJECT" \
  --query 'IsLogging' --output text 2>/dev/null || echo "ERROR")"

if [ "$TRAIL_STATUS" = "True" ]; then
  pass "trail ${PROJECT} is logging"
else
  fail "trail ${PROJECT} reports IsLogging=${TRAIL_STATUS}"
fi

# An alarm with no confirmed subscriber is a detection that reports to nobody.
TOPIC_ARN="$(aws sns list-topics \
  --query "Topics[?ends_with(TopicArn, ':${PROJECT}-security-alerts')].TopicArn | [0]" \
  --output text 2>/dev/null || echo "None")"

if [ "$TOPIC_ARN" = "None" ] || [ -z "$TOPIC_ARN" ]; then
  fail "security alerts topic not found"
else
  CONFIRMED="$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
    --query "length(Subscriptions[?SubscriptionArn != 'PendingConfirmation'])" \
    --output text 2>/dev/null || echo 0)"
  if [ "$CONFIRMED" -gt 0 ]; then
    pass "${CONFIRMED} confirmed subscriber(s) on the security topic"
  else
    fail "no CONFIRMED subscribers -- these alarms currently notify nobody. Click the SNS confirmation email."
  fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "${GREEN}${BOLD}All detections verified.${NC}"
  exit 0
fi

echo "${RED}${BOLD}${FAILURES} check(s) failed.${NC}"
warn "Do not treat these alarms as coverage until this passes."
exit 1
