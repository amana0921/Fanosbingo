#!/usr/bin/env bash
#
# Anonymous-access probe against the live API.
#
# WHY THIS EXISTS: a live Telegram bot token was readable by anyone at
# /rest/v1/settings for as long as that endpoint was up. It was found by
# running curl against it, not by reading policies -- and the first attempt to
# fix it reported success while changing nothing, because DROP POLICY on a
# misspelled name is a silent no-op.
#
# This runs the same probe automatically, so a permissive policy fails a build
# instead of waiting to be discovered by hand.
#
# It complements, rather than replaces, the SET ROLE anon assertions in
# db/20-post/003. Those test RLS directly against real data; this tests the
# WHOLE CHAIN -- Cloudflare, Caddy, PostgREST, JWT handling, RLS -- exactly as
# an attacker would reach it.
#
# Usage:
#   ./scripts/probe-public-access.sh https://api.yisakmesifin.org

set -uo pipefail

BASE_URL="${1:-${API_BASE_URL:-}}"
[ -n "$BASE_URL" ] || { echo "Usage: $0 <base-url>" >&2; exit 2; }

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

# Settings keys that must NEVER be readable without authentication.
SECRET_KEYS="telegram_bot_token sms_api_key deposit_bsc_rpc_url
             withdrawal_contract_private_key deposit_contract_private_key
             telegram_webhook_secret jwt_secret admin_key"

# Tables holding money, identity or audit data. None should return rows to an
# anonymous caller.
SENSITIVE_TABLES="telegram_users deposit_transactions withdrawal_requests
                  bnb_withdrawal_requests user_sms_submissions
                  referral_bonuses balance_transfers"

failures=0
inconclusive=0

echo
echo "${BOLD}Anonymous access probe: ${BASE_URL}${NC}"
echo

# ---------------------------------------------------------------------------
# 1. Reachability. A probe that silently tests nothing is worse than no probe,
#    so treat an unreachable endpoint as a hard failure rather than a pass.
# ---------------------------------------------------------------------------
health=$(curl -s -m 15 -o /dev/null -w "%{http_code}" "${BASE_URL}/healthz" 2>/dev/null)
if [ "$health" != "200" ]; then
  echo "${RED}FAIL${NC}  endpoint unreachable (/healthz -> ${health})"
  echo "      Cannot conclude anything about exposure. Treating as failure."
  exit 1
fi
echo "${GREEN}ok${NC}    endpoint reachable"

# ---------------------------------------------------------------------------
# 2. settings -- the definitive check.
#
#    Key names always exist regardless of how much data is present, so this
#    cannot be a false pass on an empty database.
# ---------------------------------------------------------------------------
body=$(curl -s -m 15 "${BASE_URL}/rest/v1/settings?select=id" 2>/dev/null)
visible=$(printf '%s' "$body" | python3 -c "
import json,sys
try:
    print(' '.join(sorted(r.get('id','') for r in json.load(sys.stdin))))
except Exception:
    print('__UNPARSEABLE__')" 2>/dev/null)

if [ "$visible" = "__UNPARSEABLE__" ]; then
  echo "${GREEN}ok${NC}    settings not readable anonymously"
else
  leaked=""
  for k in $SECRET_KEYS; do
    case " $visible " in *" $k "*) leaked="$leaked $k" ;; esac
  done
  if [ -n "$leaked" ]; then
    echo "${RED}FAIL${NC}  settings exposes secret keys:${leaked}"
    failures=$((failures + 1))
  else
    n=$(printf '%s' "$visible" | wc -w)
    echo "${GREEN}ok${NC}    settings exposes only ${n} non-secret keys"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Sensitive tables.
#
#    HONEST CAVEAT: zero rows on an empty table proves nothing about RLS. This
#    reports that distinction rather than claiming a pass it has not earned --
#    the migration-time SET ROLE anon assertions are the authoritative check.
# ---------------------------------------------------------------------------
for t in $SENSITIVE_TABLES; do
  resp=$(curl -s -m 15 "${BASE_URL}/rest/v1/${t}?limit=25" 2>/dev/null)
  rows=$(printf '%s' "$resp" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(len(d) if isinstance(d,list) else -1)
except Exception:
    print(-1)" 2>/dev/null)

  if [ "$rows" = "-1" ]; then
    printf "%sok%s    %-26s not readable anonymously\n" "$GREEN" "$NC" "$t"
  elif [ "$rows" -gt 0 ] 2>/dev/null; then
    printf "%sFAIL%s  %-26s returned %s rows to an anonymous caller\n" "$RED" "$NC" "$t" "$rows"
    failures=$((failures + 1))
  else
    printf "%s~%s     %-26s 0 rows (inconclusive: table may be empty)\n" "$YELLOW" "$NC" "$t"
    inconclusive=$((inconclusive + 1))
  fi
done

echo
if [ "$failures" -gt 0 ]; then
  echo "${RED}${BOLD}${failures} exposure(s) found.${NC}"
  exit 1
fi

echo "${GREEN}${BOLD}No exposures found.${NC}"
[ "$inconclusive" -gt 0 ] && echo "${YELLOW}${inconclusive} check(s) inconclusive on empty tables; RLS is asserted directly at migration time.${NC}"
exit 0
