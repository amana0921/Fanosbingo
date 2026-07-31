#!/usr/bin/env bash
#
# Add or update a house deposit account in `bank_options`.
#
# WHY THIS IS A SCRIPT AND NOT A MIGRATION.
#
# These are real account numbers, a real phone number and a real person's name.
# This repository is PUBLIC. A migration containing them would put them in git
# history permanently -- harvestable by scrapers, indexed by search, and still
# there attached to a name long after the account is closed.
#
# They are not secret: every depositor has to see them, which is the whole point
# of the table. But "not secret" and "should be published in a public git
# repository forever" are different claims, and only the first one is true.
#
# `bank_options` is DATA. Its own migration (20251214094731) says the intent was
# always "allow admin to manage bank options". So the values live in the
# database, where they can be changed without a deploy and disappear when the row
# is deleted.
#
# This script is the bootstrap for that, until the admin UI can manage them.
#
# RDS has no public endpoint, so this goes through the SSM tunnel like every
# other database operation here.
#
# Usage:
#   source scripts/db-tunnel.sh dev
#   ./scripts/seed-bank-options.sh
#
# It PROMPTS rather than taking arguments, so the values do not land in your
# shell history either.

set -euo pipefail

GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { echo "${GREEN}==>${NC} $*"; }
warn() { echo "${YELLOW}==>${NC} $*"; }
die()  { echo "${RED}ERROR:${NC} $*" >&2; exit 1; }

[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is not set. Run: source scripts/db-tunnel.sh <env>"
command -v psql >/dev/null 2>&1 || die "psql not found."

echo
echo "${BOLD}Add a deposit account${NC}"
echo
echo "  Displayed to every player in the deposit modal, so use the form a"
echo "  customer will recognise:"
echo
echo "    TeleBirr   the local 09… number, not +251…  (e.g. 0975302814)"
echo "    CBE        the 13-digit account number"
echo

read -r -p "Bank name as players will see it (e.g. Telebirr, CBE): " BANK_NAME
[ -n "$BANK_NAME" ] || die "bank name is required"

read -r -p "Account or phone number: " ACCOUNT_NUMBER
[ -n "$ACCOUNT_NUMBER" ] || die "account number is required"

read -r -p "Account holder name: " ACCOUNT_NAME

echo
echo "Instructions shown under the account details. Amharic is fine."
echo "Press Ctrl-D on a blank line when finished."
INSTRUCTIONS="$(cat)"

read -r -p "Display order (lower shows first) [1]: " DISPLAY_ORDER
DISPLAY_ORDER="${DISPLAY_ORDER:-1}"

case "$DISPLAY_ORDER" in ''|*[!0-9]*) die "display order must be a number" ;; esac

echo
echo "${BOLD}About to write:${NC}"
echo "  bank    ${BANK_NAME}"
echo "  account ${ACCOUNT_NUMBER}"
echo "  holder  ${ACCOUNT_NAME:-(none)}"
echo "  order   ${DISPLAY_ORDER}"
echo
read -r -p "Write this to the ${BOLD}live${NC} database? [y/N] " CONFIRM
[ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || die "aborted"

# Passed as psql variables rather than interpolated into the SQL text, so an
# apostrophe in a name -- or anything else -- cannot break the statement.
#
# Upserts on bank_name so re-running this to correct a typo updates the row
# instead of creating a second account with the same label. There is no unique
# constraint on bank_name in the schema, so the UPDATE-then-INSERT is explicit.
psql "$DATABASE_URL" --no-psqlrc --quiet --set ON_ERROR_STOP=1 \
  --set bank_name="$BANK_NAME" \
  --set account_number="$ACCOUNT_NUMBER" \
  --set account_name="$ACCOUNT_NAME" \
  --set instructions="$INSTRUCTIONS" \
  --set display_order="$DISPLAY_ORDER" <<'SQL'
WITH upsert AS (
  UPDATE bank_options
     SET account_number = :'account_number',
         account_name   = NULLIF(:'account_name', ''),
         instructions   = :'instructions',
         display_order  = :'display_order'::integer,
         is_active      = true,
         updated_at     = now()
   WHERE bank_name = :'bank_name'
  RETURNING id
)
INSERT INTO bank_options (bank_name, account_number, account_name, instructions, display_order, is_active)
SELECT :'bank_name', :'account_number', NULLIF(:'account_name', ''), :'instructions', :'display_order'::integer, true
 WHERE NOT EXISTS (SELECT 1 FROM upsert);

SELECT bank_name, account_number, account_name, display_order, is_active
  FROM bank_options
 ORDER BY display_order, bank_name;
SQL

echo
info "Done. Players see active options in the deposit modal, ordered by display_order."
warn "Deactivate an account without deleting its history:"
echo "    UPDATE bank_options SET is_active = false WHERE bank_name = '<name>';"
