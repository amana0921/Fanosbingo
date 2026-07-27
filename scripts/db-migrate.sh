#!/usr/bin/env bash
#
# Migration runner.
#
# Applies, in order:
#
#   db/00-bootstrap/     Supabase compatibility layer (roles, auth shim,
#                        pg_cron, the supabase_realtime publication).
#                        Must run first or all 128 migrations below fail.
#   supabase/migrations/ The 128 historical migrations, unmodified. This
#                        directory is the provenance record and is never edited.
#   db/20-post/          RDS reconciliation: remove the unschedulable 4-second
#                        cron job, schedule the orphaned cleanups, assert
#                        wal_level.
#
# Applied files are tracked in schema_migrations with a SHA-256 checksum. If a
# file changes after being applied the run FAILS rather than silently skipping
# it — the usual way a database drifts from its migration history is someone
# editing an old migration and everyone else's database never seeing the change.
#
# Each file runs in a single transaction, so a failure leaves nothing partial.
#
# Usage (expects DATABASE_URL, e.g. from scripts/db-tunnel.sh):
#   source scripts/db-tunnel.sh dev
#   ./scripts/db-migrate.sh
#   ./scripts/db-migrate.sh --dry-run     # list what would be applied

set -euo pipefail

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info() { echo "${GREEN}==>${NC} $*"; }
warn() { echo "${YELLOW}==>${NC} $*"; }
die()  { echo "${RED}ERROR:${NC} $*" >&2; exit 1; }

[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL is not set. Run: source scripts/db-tunnel.sh <env>"
command -v psql >/dev/null 2>&1 || die "psql not found. Install postgresql-client."

# ON_ERROR_STOP is essential: without it psql reports success after a failed
# statement, and a half-applied migration gets recorded as complete.
PSQL=(psql "$DATABASE_URL" --no-psqlrc --quiet --set ON_ERROR_STOP=1)

echo
echo "${BOLD}Database migrations${NC}"
"${PSQL[@]}" -tAc "SELECT '  ' || current_database() || ' on ' || inet_server_addr() || ' (PostgreSQL ' || current_setting('server_version') || ')'" \
  || die "Cannot connect. Is the tunnel up?"
echo

# ---------------------------------------------------------------------------
# Tracking table
# ---------------------------------------------------------------------------
"${PSQL[@]}" <<'SQL' >/dev/null
CREATE TABLE IF NOT EXISTS schema_migrations (
  version     text PRIMARY KEY,
  source      text NOT NULL,
  checksum    text NOT NULL,
  applied_at  timestamptz NOT NULL DEFAULT now(),
  duration_ms integer
);
COMMENT ON TABLE schema_migrations IS
  'Applied migrations. checksum is SHA-256 of the file; a mismatch means an already-applied migration was edited.';
SQL

# ---------------------------------------------------------------------------
# Build the ordered file list
#
# Bootstrap and post files are sorted within their directory; the Supabase
# migrations sort by their timestamp prefix, which is what makes their original
# order reproducible.
# ---------------------------------------------------------------------------
mapfile -t FILES < <(
  { find "$REPO_ROOT/db/00-bootstrap" -maxdepth 1 -name '*.sql' 2>/dev/null | sort
    find "$REPO_ROOT/supabase/migrations" -maxdepth 1 -name '*.sql' 2>/dev/null | sort
    find "$REPO_ROOT/db/20-post" -maxdepth 1 -name '*.sql' 2>/dev/null | sort
  }
)

[ "${#FILES[@]}" -gt 0 ] || die "No migration files found"
info "Found ${#FILES[@]} migration files"

applied=0; skipped=0; failed=0

for file in "${FILES[@]}"; do
  rel="${file#"$REPO_ROOT"/}"
  version="$(basename "$file" .sql)"
  # Namespace bootstrap and post files so a Supabase migration can never collide
  # with one of ours.
  case "$rel" in
    db/00-bootstrap/*) version="00-bootstrap/${version}" ;;
    db/20-post/*)      version="20-post/${version}" ;;
  esac

  checksum="$(sha256sum "$file" | cut -d' ' -f1)"

  # Version strings come from filenames we control, so simple interpolation is
  # safe here; there is no external input to inject with.
  recorded="$("${PSQL[@]}" -tAc \
    "SELECT checksum FROM schema_migrations WHERE version = '${version}'" 2>/dev/null || echo "")"
  recorded="$(echo "$recorded" | tr -d '[:space:]')"

  if [ -n "$recorded" ]; then
    if [ "$recorded" != "$checksum" ]; then
      echo "${RED}  CHANGED${NC} $rel"
      echo "          applied checksum: $recorded"
      echo "          current checksum: $checksum"
      failed=$((failed + 1))
      die "Migration '$version' was edited after being applied.
Editing an applied migration means every other database silently misses the
change. Write a NEW migration instead. If the edit is genuinely cosmetic,
update the recorded checksum deliberately:
  UPDATE schema_migrations SET checksum = '$checksum' WHERE version = '$version';"
    fi
    skipped=$((skipped + 1))
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "  ${YELLOW}would apply${NC} $rel"
    applied=$((applied + 1))
    continue
  fi

  printf "  applying %-70s" "$rel"
  start_ms=$(date +%s%3N)

  # --single-transaction so a failure rolls back cleanly. The bootstrap file
  # reads DB_AUTHENTICATOR_PASSWORD from the environment via \getenv rather than
  # a -v flag, so the password never lands in the process list.
  if ! output="$("${PSQL[@]}" \
        --single-transaction \
        -f "$file" 2>&1)"; then
    echo "${RED}FAILED${NC}"
    echo "$output" | sed 's/^/      /'
    failed=$((failed + 1))
    die "Migration failed: $rel (nothing was committed)"
  fi

  duration=$(( $(date +%s%3N) - start_ms ))

  "${PSQL[@]}" -c \
    "INSERT INTO schema_migrations (version, source, checksum, duration_ms)
     VALUES ('$version', '$rel', '$checksum', $duration)" >/dev/null

  echo "${GREEN}ok${NC} (${duration}ms)"
  # Surface RAISE NOTICE output; the post-migration file uses it to report what
  # it unscheduled and scheduled.
  echo "$output" | grep -E "^(NOTICE|WARNING):" | sed 's/^/      /' || true
  applied=$((applied + 1))
done

echo
if [ "$DRY_RUN" = true ]; then
  info "Dry run: ${applied} would be applied, ${skipped} already recorded"
else
  info "Applied ${applied}, skipped ${skipped} already-recorded"
fi
