#!/usr/bin/env bash
#
# Apply db/20-post/*.sql to a throwaway PostgreSQL and prove they run.
#
# WHY: nothing in CI executed migration SQL. db-migrate.yml's pull-request job
# runs `db-migrate.sh --dry-run`, which prints filenames and continues -- it never
# executes them -- and the `migrations` job in test.yml is a static check over
# CREATE/DROP statements. Both reported success on a pull request adding two
# migrations without running either. A syntax error, an unsatisfiable constraint
# or a failing assertion would have merged green.
#
# WHAT IT COVERS: db/20-post/003 onwards, against db/test/fixture.sql. That is
# where every security decision in this repository lives -- the settings
# allowlist, the EXECUTE allowlist, the telegram_users scoping, the admin flag
# and the deposit queue.
#
# WHAT IT DOES NOT COVER, stated so nobody mistakes a green run for more than it
# is: db/00-bootstrap and the 104 inherited migrations. The bootstrap asserts
# wal_level=logical and pg_cron in shared_preload_libraries, correctly, and
# neither is available in a stock postgres:16. Replaying everything needs a custom
# image; this is the check that catches the mistakes that have actually happened.
#
# Usage:
#   ./scripts/test-migrations.sh                     # uses podman, ephemeral
#   DATABASE_URL=postgres://... ./scripts/test-migrations.sh   # bring your own

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { echo "${GREEN}==>${NC} $*"; }
die()  { echo "${RED}ERROR:${NC} $*" >&2; exit 1; }

command -v psql >/dev/null 2>&1 || die "psql not found. Install postgresql-client."

CONTAINER=""
cleanup() { [ -n "$CONTAINER" ] && podman rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if [ -z "${DATABASE_URL:-}" ]; then
  command -v podman >/dev/null 2>&1 || die "podman not found, and DATABASE_URL is not set."
  CONTAINER="migration-test-$$"
  PORT="${MIGRATION_TEST_PORT:-55440}"

  info "Starting postgres:16 on :${PORT}"
  podman run -d --rm --name "$CONTAINER" \
    -e POSTGRES_PASSWORD=fixture -p "${PORT}:5432" \
    docker.io/library/postgres:16-alpine >/dev/null

  DATABASE_URL="postgresql://postgres:fixture@127.0.0.1:${PORT}/postgres"

  for _ in $(seq 1 40); do
    psql "$DATABASE_URL" -tAc 'SELECT 1' >/dev/null 2>&1 && break
    sleep 2
  done
  psql "$DATABASE_URL" -tAc 'SELECT 1' >/dev/null 2>&1 || die "postgres did not become ready"
fi

PSQL=(psql "$DATABASE_URL" --no-psqlrc --quiet --set ON_ERROR_STOP=1)

echo
echo "${BOLD}Migration test${NC}"
"${PSQL[@]}" -tAc "SELECT '  ' || version()" | head -1

info "Building the fixture"
"${PSQL[@]}" -f "$REPO_ROOT/db/test/fixture.sql" >/dev/null

failed=0

# 003 onwards. 001 and 002 assert wal_level and pg_cron, which a stock image does
# not provide -- see the header.
for f in "$REPO_ROOT"/db/20-post/*.sql; do
  base="$(basename "$f")"
  case "$base" in 001_*|002_*) continue ;; esac

  printf "  applying %-44s" "$base"

  # --single-transaction so a failure leaves nothing partial, exactly as
  # db-migrate.sh applies them in production.
  if output="$("${PSQL[@]}" --single-transaction -f "$f" 2>&1)"; then
    echo "${GREEN}ok${NC}"
    echo "$output" | grep -E '^(NOTICE|WARNING):' | sed 's/^/        /' || true
  else
    echo "${RED}FAILED${NC}"
    echo "$output" | sed 's/^/        /'
    failed=$((failed + 1))
  fi
done

echo
if [ "$failed" -gt 0 ]; then
  echo "${RED}${BOLD}${failed} migration(s) failed.${NC}"
  exit 1
fi

# Re-apply everything. db/20-post files are REPEATABLE by design -- db-migrate.sh
# re-runs them whenever their content changes -- so one that only works against a
# clean database is broken in a way a single pass cannot see.
info "Re-applying, because these are repeatable and must be idempotent"
for f in "$REPO_ROOT"/db/20-post/*.sql; do
  base="$(basename "$f")"
  case "$base" in 001_*|002_*) continue ;; esac
  printf "  re-applying %-41s" "$base"
  if output="$("${PSQL[@]}" --single-transaction -f "$f" 2>&1)"; then
    echo "${GREEN}ok${NC}"
  else
    echo "${RED}FAILED ON SECOND RUN${NC}"
    echo "$output" | sed 's/^/        /'
    failed=$((failed + 1))
  fi
done

echo
if [ "$failed" -gt 0 ]; then
  echo "${RED}${BOLD}${failed} migration(s) are not idempotent.${NC}"
  exit 1
fi

echo "${GREEN}${BOLD}All migrations applied, twice.${NC}"
echo "${YELLOW}Covers db/20-post only. The bootstrap and the 104 inherited migrations need pg_cron and wal_level=logical; see the header.${NC}"
