/*
  # An admin is a flag on a proven identity, not a shared string
  #
  # WHAT IT REPLACES, and this was live rather than theoretical.
  #
  # src/components/Admin.tsx validated its access key like this:
  #
  #     const response = await fetch('.../functions/v1/update-settings', ...)
  #     if (response.status === 401) { alert('Invalid access key') }
  #     else { setIsAuthenticated(true) }
  #
  # /functions/v1/update-settings is one of the inherited Deno names the rebuilt
  # service never implemented. It answers 404. 404 is not 401, so the else branch
  # ran and ANY string logged you in. Visiting /admin and typing one character was
  # enough.
  #
  # The blast radius happened to be small -- every write in that panel also posts
  # to a 404, and RLS blocks direct table writes -- but the panel is about to be
  # given the ability to credit player balances, which is why this is being fixed
  # before that and not after.
  #
  # WHY A FLAG ON telegram_users.
  #
  # This system already proves who somebody is: Telegram signs initData with a key
  # derived from the bot token, services/functions/src/auth.js verifies the HMAC,
  # and the resulting uuid is what auth.uid() returns. An admin is therefore a
  # property of an identity that has ALREADY been established cryptographically,
  # and needs no second credential to be invented, stored, rotated or leaked.
  #
  # WHAT THIS DELIBERATELY IS NOT: multi-factor. Whoever controls that Telegram
  # account is an admin. There is no TOTP here, and an unlocked phone is enough.
  # That is a real weakness and it is chosen deliberately over the shared string it
  # replaces, not over something stronger -- README §"What is left" still calls for
  # Cognito with TOTP, and this does not close that item. It removes a bypass and
  # gives the audit trail somewhere to point.
  #
  # ENFORCEMENT IS IN THE ROUTE, NOT IN RLS, on purpose. The admin routes run as
  # app_service, which inherits service_role and therefore BYPASSES RLS -- the same
  # shape as /select-card and /claim-bingo, where the check is in the handler
  # because the operation is not expressible as "which rows may this player see".
  # A policy referencing is_admin would be a second, weaker copy of the same rule.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

-- ---------------------------------------------------------------------------
-- 1. The flag
--
-- NOT NULL DEFAULT false, so a row that predates this column is not an admin by
-- omission. Every authorization default in this schema should fail closed, and
-- a nullable boolean has three states where the question has two.
-- ---------------------------------------------------------------------------
ALTER TABLE telegram_users
  ADD COLUMN IF NOT EXISTS is_admin boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN telegram_users.is_admin IS
  'Grants the admin API. Checked by requireAdmin() in the functions service, not by RLS -- admin routes run as app_service and bypass RLS. Single factor: whoever holds the Telegram account holds this.';

-- Partial index: admins are a handful of rows in a table of players, and every
-- lookup asks "is THIS user an admin" or "are there ANY admins". Indexing only
-- the true rows keeps it tiny.
CREATE INDEX IF NOT EXISTS idx_telegram_users_is_admin
  ON telegram_users (id) WHERE is_admin;

-- ---------------------------------------------------------------------------
-- 2. is_admin is NOT readable by players, and not writable by anyone over HTTP
--
-- db/20-post/004 already scoped telegram_users reads to `id = auth.uid()`, so a
-- player can see their own row -- including this column. That is fine and even
-- useful: the Mini App can hide the admin entry point for everyone else.
--
-- What matters is that nothing can WRITE it. `authenticated` holds a table-level
-- UPDATE grant from db/20-post/001, so the only thing standing between a player
-- and making themselves an admin is the absence of an UPDATE policy. There is
-- none today, and this asserts that rather than trusting it to stay that way.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(format('%s (%s)', policyname, cmd), '; ')
  INTO v_bad
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'telegram_users'
    AND cmd IN ('UPDATE', 'ALL', 'INSERT')
    AND NOT ('service_role' = ANY(roles));

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION
      'telegram_users has a non-service_role write policy: %. A player could set their own is_admin.',
      v_bad;
  END IF;

  RAISE NOTICE 'telegram_users: no write policy outside service_role';
END $$;

-- ---------------------------------------------------------------------------
-- 3. Promotion is a database action, deliberately
--
-- There is no route that grants admin to somebody else. The bootstrap route in
-- the functions service promotes ONLY the caller, and only while no admin exists
-- at all -- so it disarms itself the moment it is used and cannot be replayed to
-- add a second one.
--
-- Every admin after the first is added here, by someone with database access,
-- through the SSM tunnel:
--
--   source scripts/db-tunnel.sh dev
--   psql "$DATABASE_URL" -c "UPDATE telegram_users SET is_admin = true
--                            WHERE telegram_user_id = 123456789"
--
-- That is intentionally inconvenient. Granting the ability to credit balances
-- should require the same access as changing the schema, and it leaves a trace in
-- CloudTrail via the tunnel session.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count FROM telegram_users WHERE is_admin;
  RAISE NOTICE 'Admins currently: %', v_count;
  IF v_count = 0 THEN
    RAISE NOTICE 'None yet. POST /admin/bootstrap with the key in /<env>/app/admin_bootstrap_key to promote the first.';
  END IF;
END $$;
