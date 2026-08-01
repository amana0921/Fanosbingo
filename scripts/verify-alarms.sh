#!/usr/bin/env bash
#
# Prove an alarm reaches a human, and say which ones cannot.
#
# scripts/verify-detections.sh establishes the principle for metric filters: "a
# detector that has never seen a positive is not a detector." Nothing did the
# equivalent for ALARMS, and the failure modes are worse because every one of
# them is silent:
#
#   * The metric never publishes. The alarm sits at OK forever, because
#     treat_missing_data says not to worry, and OK is indistinguishable from
#     healthy. This is what prompted the script -- a deposit alarm was created,
#     a deposit had been pending for a day, and no email arrived.
#
#   * The SNS subscription is unconfirmed. Terraform reports the subscription as
#     created while it sits in "pending confirmation"; modules/monitoring warns
#     about this in a comment and nothing checked it.
#
#   * The alarm has no actions at all, or points at a topic nobody is on.
#
# Usage:
#   ./scripts/verify-alarms.sh dev              # report only, changes nothing
#   ./scripts/verify-alarms.sh dev --fire NAME  # force one alarm, prove delivery
#
# --fire uses SetAlarmState, which triggers the alarm ACTION and therefore the
# whole path: alarm -> SNS -> subscription -> inbox. CloudWatch re-evaluates from
# real data on the next period, so the forced state is transient. It fires the
# OK transition afterwards too, so you get both emails and can see the pair.

set -euo pipefail

ENVIRONMENT="${1:-dev}"
PREFIX="fanosbingo-${ENVIRONMENT}"
NAMESPACE="FanosBingo/${PREFIX}"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
pass() { echo "  ${GREEN}PASS${NC} $*"; }
warn() { echo "  ${YELLOW}WARN${NC} $*"; }
fail() { echo "  ${RED}FAIL${NC} $*"; failures=$((failures + 1)); }
failures=0

command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 1; }

# ---------------------------------------------------------------------------
# --fire: force one alarm through a full transition
# ---------------------------------------------------------------------------
if [ "${2:-}" = "--fire" ]; then
  TARGET="${3:?usage: verify-alarms.sh <env> --fire <alarm-name>}"

  case "$TARGET" in
    "${PREFIX}"-*) ;;
    *) echo "${RED}Refusing:${NC} '$TARGET' is not a ${PREFIX} alarm." >&2; exit 1 ;;
  esac

  echo "${BOLD}Forcing ${TARGET} through ALARM -> OK${NC}"
  echo "This sends real notifications. CloudWatch re-evaluates from real data on"
  echo "the next period, so nothing is left misreporting."
  echo

  aws cloudwatch set-alarm-state --alarm-name "$TARGET" --state-value ALARM \
    --state-reason "Delivery test from scripts/verify-alarms.sh at $(date -u +%FT%TZ)"
  echo "  ${GREEN}sent${NC} ALARM"

  sleep 10

  aws cloudwatch set-alarm-state --alarm-name "$TARGET" --state-value OK \
    --state-reason "Delivery test complete"
  echo "  ${GREEN}sent${NC} OK"

  echo
  echo "Expect TWO emails. If neither arrives, the alarm's actions or its SNS"
  echo "subscription are the problem, not the metric."
  exit 0
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo
echo "${BOLD}Alarm delivery — ${PREFIX}${NC}"
echo

alarms_json="$(aws cloudwatch describe-alarms --alarm-name-prefix "$PREFIX" \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue,actions:AlarmActions,ns:Namespace,metric:MetricName,missing:TreatMissingData}' \
  --output json)"

count="$(echo "$alarms_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
echo "${BOLD}${count} alarm(s)${NC}"
echo

# Which SNS topics are actually deliverable? An unconfirmed subscription has a
# SubscriptionArn of the literal string "PendingConfirmation".
declare -A topic_ok
for topic in $(echo "$alarms_json" | python3 -c '
import json,sys
print("\n".join(sorted({a for x in json.load(sys.stdin) for a in (x["actions"] or [])})))'); do
  confirmed="$(aws sns list-subscriptions-by-topic --topic-arn "$topic" \
    --query 'length(Subscriptions[?SubscriptionArn!=`PendingConfirmation`])' --output text 2>/dev/null || echo 0)"
  pendingn="$(aws sns list-subscriptions-by-topic --topic-arn "$topic" \
    --query 'length(Subscriptions[?SubscriptionArn==`PendingConfirmation`])' --output text 2>/dev/null || echo 0)"
  topic_ok["$topic"]="$confirmed"
  short="${topic##*:}"
  if [ "$confirmed" -gt 0 ]; then
    pass "topic ${short}: ${confirmed} confirmed subscriber(s)$([ "$pendingn" -gt 0 ] && echo ", ${pendingn} still pending")"
  else
    fail "topic ${short}: NO confirmed subscribers. Alarms firing here reach nobody."
  fi

  # CAN CLOUDWATCH ACTUALLY ENCRYPT TO IT?
  #
  # The check this script shipped without, and the one that would have caught
  # the bug that motivated the script. An SNS topic encrypted with a CMK needs
  # that key's policy to admit cloudwatch.amazonaws.com, or the publish fails
  # and the notification is dropped -- with the alarm in ALARM, the subscription
  # confirmed, and the metric publishing. Every other signal says healthy.
  key="$(aws sns get-topic-attributes --topic-arn "$topic" \
    --query 'Attributes.KmsMasterKeyId' --output text 2>/dev/null || echo "None")"

  if [ "$key" = "None" ] || [ -z "$key" ]; then
    pass "topic ${short}: not encrypted, so no key policy to satisfy"
  else
    if aws kms get-key-policy --key-id "$key" --policy-name default \
         --query Policy --output text 2>/dev/null |
       python3 -c '
import json,sys
pol = json.load(sys.stdin)
ok = any(
    "cloudwatch.amazonaws.com" in json.dumps(st.get("Principal", {}))
    and st.get("Effect") == "Allow"
    for st in pol.get("Statement", [])
)
sys.exit(0 if ok else 1)'; then
      pass "topic ${short}: its CMK admits cloudwatch.amazonaws.com"
    else
      fail "topic ${short}: encrypted with ${key}, whose policy does NOT admit cloudwatch.amazonaws.com. Every notification is dropped silently -- alarm state, subscription and metric all still look correct."
    fi
  fi
done
echo

# Per alarm: does it have an action, and is its metric actually publishing?
#
# THE CHECK THAT MATTERS. An alarm at OK with no datapoints is not healthy, it
# is unarmed -- and with treat_missing_data=notBreaching it will never say so.
echo "$alarms_json" | python3 -c '
import json,sys
for a in json.load(sys.stdin):
    print("\t".join([a["name"], a["state"], str(len(a["actions"] or [])),
                     a["ns"] or "", a["metric"] or "", a["missing"] or ""]))' |
while IFS=$'\t' read -r name state nactions ns metric missing; do
  echo "${BOLD}${name}${NC}  [${state}]"

  if [ "$nactions" -eq 0 ]; then
    fail "  no alarm actions - it can fire and tell nobody"
  fi

  if [ "$ns" = "$NAMESPACE" ]; then
    # Only our own metrics; AWS/RDS and AWS/EC2 always have data.
    points="$(aws cloudwatch get-metric-statistics \
      --namespace "$ns" --metric-name "$metric" \
      --dimensions Name=Environment,Value="$ENVIRONMENT" \
      --start-time "$(date -u -d '2 hours ago' +%FT%TZ)" \
      --end-time "$(date -u +%FT%TZ)" \
      --period 300 --statistics Maximum \
      --query 'length(Datapoints)' --output text 2>/dev/null || echo 0)"

    if [ "$points" -gt 0 ]; then
      latest="$(aws cloudwatch get-metric-statistics \
        --namespace "$ns" --metric-name "$metric" \
        --dimensions Name=Environment,Value="$ENVIRONMENT" \
        --start-time "$(date -u -d '2 hours ago' +%FT%TZ)" \
        --end-time "$(date -u +%FT%TZ)" \
        --period 300 --statistics Maximum \
        --query 'sort_by(Datapoints,&Timestamp)[-1].Maximum' --output text)"
      pass "  ${metric}: ${points} datapoint(s) in 2h, latest ${latest}"
    else
      # This is the silent one. Say exactly what it means.
      fail "  ${metric}: NO datapoints in 2h. treat_missing_data=${missing}, so this alarm cannot fire. It is not healthy, it is unarmed."
    fi
  fi
  echo
done

echo
if [ "$failures" -eq 0 ]; then
  echo "${GREEN}${BOLD}Every alarm has a confirmed recipient and a live metric.${NC}"
  echo "To prove delivery end to end:  $0 ${ENVIRONMENT} --fire ${PREFIX}-game-loop-stalled"
else
  echo "${RED}${BOLD}${failures} problem(s).${NC} An alarm that cannot fire is not coverage."
  exit 1
fi
