/*
  # Deliberate-edit reconciliation for already-applied migrations
  #
  # Runs in 00-bootstrap, BEFORE the versioned migrations, because the runner
  # checks each file's checksum as it iterates. A reconciliation placed in
  # 20-post never executes: the run aborts on the changed file long before
  # reaching it. That is exactly what happened on the first attempt.
  #
  # Only ever add an entry here for an edit that is genuinely intended. The
  # checksum guard exists because editing an applied migration is how a database
  # silently drifts from its own history -- every other database misses the
  # change. Bypassing it should be a conscious, reviewed act, which is why each
  # entry carries a reason.
*/

-- The runner creates schema_migrations before this file runs, but guard anyway
-- so a brand-new database does not fail here.
CREATE TABLE IF NOT EXISTS schema_migrations (
  version     text PRIMARY KEY,
  source      text NOT NULL,
  checksum    text NOT NULL,
  applied_at  timestamptz NOT NULL DEFAULT now(),
  duration_ms integer
);

-- 20251213115718_add_settings_table
--
-- REASON: contained a live Telegram bot token as a SQL literal. It was
-- publicly readable through PostgREST until db/20-post/003 closed the RLS hole,
-- and the token has since been revoked. Leaving a real credential in the
-- repository was not acceptable, so the literal was replaced with an empty
-- string.
--
-- Safe retroactively: the INSERT uses ON CONFLICT DO NOTHING, so the edit only
-- affects databases built from scratch. Existing rows are untouched, and
-- db/20-post/003 has already redacted them in place.
UPDATE schema_migrations
SET checksum = 'fbb9c1326068e7f8e1bc7b44f1eebe2d3ab4d0b9f8f1d48ad91ca7047db70ae5'
WHERE version = '20251213115718_add_settings_table'
  AND checksum <> 'fbb9c1326068e7f8e1bc7b44f1eebe2d3ab4d0b9f8f1d48ad91ca7047db70ae5';
