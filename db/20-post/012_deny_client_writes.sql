/*
  # No table in this schema is writable by a client
  #
  # THE ROOT CAUSE db/20-post/008 TREATED SYMPTOMATICALLY.
  #
  # 008 revoked INSERT/UPDATE/DELETE on `games` and `players`, because those two
  # were demonstrably exploitable: a single PATCH on games set winner_ids and
  # winner_prize_each, and payout_winners() credited them. That fixed the two
  # tables somebody had already found. It did not fix the reason they were open.
  #
  # The reason is one line, db/20-post/001_rds_deltas.sql:121:
  #
  #   GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public
  #     TO authenticated;
  #
  # plus its forward-looking twin in db/00-bootstrap/001:
  #
  #   ALTER DEFAULT PRIVILEGES IN SCHEMA public
  #     GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
  #
  # Together those say: every table that exists, and every table anyone adds
  # later, is writable by any logged-in player unless a restrictive RLS policy
  # happens to stand in the way. That is grant-by-default with RLS as the only
  # brake -- and the brake is per-table, written by hand, and was missing on
  # exactly the two tables that mattered most.
  #
  # It is the same shape 004 fixed for functions, one layer down. 004's argument
  # applies verbatim: "a function added tomorrow is anon-callable the moment it
  # is created, with nobody having granted anything." Replace "function" with
  # "table".
  #
  # ---------------------------------------------------------------------------
  # WHY THE ALLOWLIST IS EMPTY, which is the surprising part
  # ---------------------------------------------------------------------------
  #
  # Enumerated from source rather than assumed -- every .insert/.update/.upsert/
  # .delete the SPA issues against any table:
  #
  #   telegram_users   WalletConnect.tsx, setting wallet_address
  #
  # That is the entire list, and it is not even live. It sits behind
  # VITE_CRYPTO_ENABLED, which is off, and it has ALREADY been failing silently:
  # 004 gave telegram_users a SELECT policy and no UPDATE policy, so the update
  # matches nothing and affects zero rows. PostgREST reports that as success,
  # because filtering is not an error. After this migration it fails loudly
  # instead, which is strictly better.
  #
  # Everything that legitimately writes does so through a SECURITY DEFINER
  # function, and therefore as the table OWNER rather than as the caller:
  #
  #   select_card_atomic          joining a game        (/select-card)
  #   atomic_claim_bingo          claiming a win        (/claim-bingo)
  #   release_card                releasing a card      (/deselect-card)
  #   request_bank_withdrawal     filing a payout       (/withdrawals/request)
  #   complete/reject_bank_withdrawal, approve/reject_deposit_request
  #   admin_end_game              ending a game         (/admin/games/:id/end)
  #   game_tick                   the game loop         (ticker)
  #
  # and the ticker, functions and realtime containers connect as app_service,
  # which holds service_role and BYPASSRLS. None of them is affected by a grant
  # to `authenticated`.
  #
  # So the client genuinely needs no write anywhere. That is not a coincidence --
  # it is what services/functions/src/index.js means by "routes are added
  # deliberately, each one answering why can RLS not do this". Every write in
  # this system goes through a function that checks something first.
  #
  # ---------------------------------------------------------------------------
  # IF AN EXCEPTION IS EVER GENUINELY NEEDED
  # ---------------------------------------------------------------------------
  #
  # Add it here, by name, with a WITH CHECK policy and a sentence saying why a
  # function cannot do it. Do not re-grant on ALL TABLES. The whole value of this
  # file is that the next table added to the schema is not writable by anybody
  # because nobody thought about it.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

-- ---------------------------------------------------------------------------
-- 1. Existing tables
-- ---------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public
  FROM PUBLIC, anon, authenticated;

-- Reading stays, scoped by RLS. 003 allowlists which settings rows are visible,
-- 004 scopes telegram_users to the owning player, 006 and 007 scope the deposit
-- and withdrawal queues. Those policies are what make SELECT safe; this file is
-- about the other three verbs.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Tables added in future
--
-- AND THIS ONE ACTUALLY WORKS, unlike the case 004 documents at length -- the
-- difference is worth stating because conflating them is easy.
--
-- 004 found that
--     ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC
-- reports success and does nothing, because "functions are executable by PUBLIC"
-- is a DATABASE-WIDE built-in default and a per-schema entry can only ADD to it.
--
-- Here we are revoking a default this project EXPLICITLY GRANTED, in
-- db/00-bootstrap/001, with a matching `IN SCHEMA public` and the same grantor
-- role. That removes the pg_default_acl entry rather than trying to subtract a
-- built-in, so it takes effect. Section 3 proves it rather than asserting it.
-- ---------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLES FROM authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLES FROM anon;

-- ---------------------------------------------------------------------------
-- 3. Assertions
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bad text;
BEGIN
  -- Every table, every write verb, both client roles. Enumerated from the
  -- catalogue so a table added tomorrow is covered without editing this list.
  SELECT string_agg(format('%s:%s:%s', r.rolname, c.relname, v.verb), '; ')
    INTO v_bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   CROSS JOIN (SELECT unnest(ARRAY['anon','authenticated']) AS rolname) r
   CROSS JOIN (SELECT unnest(ARRAY['INSERT','UPDATE','DELETE']) AS verb) v
   WHERE n.nspname = 'public'
     AND c.relkind IN ('r', 'p')
     AND has_table_privilege(r.rolname, c.oid, v.verb);

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION
      'A client role can still write: %. Every write in this system goes through a SECURITY DEFINER function; a table privilege here is how that gets bypassed.',
      v_bad;
  END IF;

  -- The lobby must still be able to read.
  IF NOT has_table_privilege('anon', 'public.games', 'SELECT') THEN
    RAISE EXCEPTION 'anon cannot SELECT games; the lobby needs it.';
  END IF;

  -- And the game loop must still be able to write.
  IF NOT has_table_privilege('service_role', 'public.games', 'UPDATE') THEN
    RAISE EXCEPTION 'service_role cannot UPDATE games; the game loop is broken.';
  END IF;
END $$;

-- The default-privileges change, PROVEN rather than assumed.
--
-- Creates a table, asks whether `authenticated` may write it, and drops it. This
-- is exactly how 004 established that the FUNCTIONS form silently does nothing
-- -- "verified on PostgreSQL 16.14 by issuing it, creating a function, and
-- asking has_function_privilege, which answered true". The same method, applied
-- to the claim this file makes.
--
-- Worth the four statements: if this default is ever reintroduced upstream, the
-- symptom is a NEW table quietly writable by every player, and nothing else in
-- the system would notice.
DO $$
DECLARE
  v_writable boolean;
BEGIN
  CREATE TABLE public._default_privilege_probe (id integer);

  SELECT has_table_privilege('authenticated', 'public._default_privilege_probe', 'INSERT')
      OR has_table_privilege('anon', 'public._default_privilege_probe', 'INSERT')
    INTO v_writable;

  DROP TABLE public._default_privilege_probe;

  IF v_writable THEN
    RAISE EXCEPTION
      'A newly created table is still writable by a client role. The ALTER DEFAULT PRIVILEGES revoke did not take effect -- check that this file runs as the same role that issued the GRANT in db/00-bootstrap/001.';
  END IF;

  RAISE NOTICE 'client writes: denied on every table, now and for tables added later';
END $$;
