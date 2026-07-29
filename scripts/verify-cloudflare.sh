#!/usr/bin/env bash
#
# Assert the Cloudflare settings that cannot be enforced in Terraform.
#
# Most of the zone is now code (infra/modules/cloudflare). Two things are not,
# and both can take the site down without producing an error anywhere:
#
#   BOT FIGHT MODE has no Terraform resource on the free plan. Switched on, it
#   challenges non-browser clients -- which is exactly what Telegram's webhook
#   caller and a WebSocket upgrade look like. Telegram does not solve
#   challenges. It retries, and then DISABLES your webhook. The failure arrives
#   as "the bot stopped working" some hours later.
#
#   PROXY STATUS is Terraform-managed, but a dashboard edit will silently
#   un-proxy a record, and the origin security group admits Cloudflare ranges
#   only. A grey-cloud record therefore black-holes: no 403, no log line, just a
#   timeout. Worth asserting independently of what state believes.
#
# Read-only. Needs a token with Zone:Read and Zone Settings:Read.
#
# Usage:
#   CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ZONE_ID=... DOMAIN_NAME=example.org \
#     ./scripts/verify-cloudflare.sh

set -euo pipefail

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
: "${CLOUDFLARE_ZONE_ID:?CLOUDFLARE_ZONE_ID is required}"
: "${DOMAIN_NAME:?DOMAIN_NAME is required}"

API="https://api.cloudflare.com/client/v4"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
pass() { echo "  ${GREEN}PASS${NC} $*"; }
fail() { echo "  ${RED}FAIL${NC} $*"; FAILURES=$((FAILURES + 1)); }
warn() { echo "  ${YELLOW}WARN${NC} $*"; }

FAILURES=0

command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

cf() {
  curl -fsS -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
       -H "Content-Type: application/json" "${API}$1"
}

echo
echo "${BOLD}Cloudflare verification — ${DOMAIN_NAME}${NC}"
echo

# ---------------------------------------------------------------------------
# The one that silently kills the Telegram integration
# ---------------------------------------------------------------------------
# Reported the failure as "could not read (token may lack ...)" and moved on,
# which is how the single check that cannot be enforced any other way ended up
# unverified behind a green tick. `2>/dev/null || echo unknown` collapses every
# possible cause -- wrong permission, wrong plan, network blip -- into one word,
# and the word is a guess.
#
# So: capture the status and the body, and let the CAUSE decide the severity.
# A missing permission is fixable and therefore a failure. A plan that does not
# expose the endpoint is not fixable and stays a warning, because a check that
# can never pass trains people to ignore red runs.
BFM_BODY="$(curl -sS -o /tmp/cf-bfm.json -w '%{http_code}' \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "${API}/zones/${CLOUDFLARE_ZONE_ID}/bot_management" 2>&1 || echo "000")"

# NOT `.result.fight_mode // empty`.
#
# jq's `//` is an ALTERNATIVE operator, and it fires on `false` as well as on
# `null`. So `false // empty` is empty -- and `false` is precisely the value
# this check wants to see, because it means Bot Fight Mode is OFF. The guard
# meant to handle a missing field was silently discarding the good answer.
#
# Ask whether the key EXISTS, then stringify whatever it holds.
BFM="$(jq -r 'if (.result? | objects | has("fight_mode")) then (.result.fight_mode | tostring) else "absent" end' /tmp/cf-bfm.json 2>/dev/null || echo "absent")"
BFM_ERR="$(jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")' /tmp/cf-bfm.json 2>/dev/null || true)"

case "${BFM_BODY}|${BFM}" in
  200\|false)
    pass "Bot Fight Mode is OFF"
    ;;
  200\|true)
    fail "Bot Fight Mode is ON. Telegram's webhook caller and WebSocket upgrades will be challenged, and Telegram responds by disabling the webhook. Turn it off: Security > Bots."
    ;;
  200\|absent)
    fail "the bot_management response has no fight_mode field. The API shape has changed, so this assertion is no longer checking anything -- fix it rather than trusting it."
    ;;
  403*|401*)
    fail "cannot read Bot Fight Mode -- HTTP ${BFM_BODY}: ${BFM_ERR:-no detail}. The token is missing a permission; add Zone > Zone Settings > Read and re-run. This is the ONE setting Terraform cannot enforce, so leaving it unreadable means it is unverified."
    ;;
  404*)
    warn "Bot Fight Mode endpoint returned 404 -- not exposed on this zone's plan. ${BFM_ERR:-} Check it by hand: Security > Bots. Not a failure, because no token can make this readable."
    ;;
  *)
    fail "cannot read Bot Fight Mode -- HTTP ${BFM_BODY}: ${BFM_ERR:-no detail}. Investigate rather than assume; this check exists because the setting cannot be enforced in Terraform."
    ;;
esac

rm -f /tmp/cf-bfm.json

# ---------------------------------------------------------------------------
# Proxy status — asserted against the API, not against Terraform state
# ---------------------------------------------------------------------------
for host in "api.${DOMAIN_NAME}" "rt.${DOMAIN_NAME}"; do
  RECORD="$(cf "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${host}" \
    | jq -r '.result[0] // empty')"

  if [ -z "$RECORD" ]; then
    fail "${host} has no DNS record"
    continue
  fi

  PROXIED="$(echo "$RECORD" | jq -r '.proxied')"
  CONTENT="$(echo "$RECORD" | jq -r '.content')"

  if [ "$PROXIED" = "true" ]; then
    pass "${host} is proxied (origin ${CONTENT})"
  else
    fail "${host} is DNS-only. The origin security group admits Cloudflare ranges only, so this resolves to an address that will never answer."
  fi
done

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------
SSL_MODE="$(cf "/zones/${CLOUDFLARE_ZONE_ID}/settings/ssl" | jq -r '.result.value')"
if [ "$SSL_MODE" = "strict" ]; then
  pass "SSL mode is Full (strict)"
else
  fail "SSL mode is '${SSL_MODE}', not 'strict'. Flexible sends plaintext to an origin that only listens on 443; Full does not verify the origin certificate."
fi

MIN_TLS="$(cf "/zones/${CLOUDFLARE_ZONE_ID}/settings/min_tls_version" | jq -r '.result.value')"
if [ "$MIN_TLS" = "1.2" ] || [ "$MIN_TLS" = "1.3" ]; then
  pass "minimum TLS version is ${MIN_TLS}"
else
  fail "minimum TLS version is ${MIN_TLS}"
fi

WS="$(cf "/zones/${CLOUDFLARE_ZONE_ID}/settings/websockets" | jq -r '.result.value')"
if [ "$WS" = "on" ]; then
  pass "WebSockets are enabled"
else
  fail "WebSockets are '${WS}'. Realtime cannot complete an upgrade."
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "${GREEN}${BOLD}Cloudflare configuration is correct.${NC}"
  exit 0
fi

echo "${RED}${BOLD}${FAILURES} check(s) failed.${NC}"
exit 1
