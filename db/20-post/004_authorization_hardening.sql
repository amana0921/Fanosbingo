/*
  # Authorization hardening: telegram_users, and who may EXECUTE what
  #
  # FOUND BY PROBING THE LIVE dev API, not by reading policies. Two findings,
  # and they chain into one another.
  #
  # ---------------------------------------------------------------------------
  # 1. telegram_users was readable by an ANONYMOUS caller
  # ---------------------------------------------------------------------------
  #
  #   curl https://api.<domain>/rest/v1/telegram_users?select=*
  #
  # returned the full row for every registered player: telegram_user_id,
  # username, real name, balance, deposited_balance, won_balance,
  # total_deposited, total_withdrawn, referral_code and wallet_address.
  #
  # The cause is inherited:
  #
  #   supabase/migrations/20251229180739_fix_telegram_users_rls_for_lobby.sql
  #     CREATE POLICY "Anon users can read telegram_users for lobby"
  #       ON telegram_users FOR SELECT TO anon, public USING (true);
  #
  # Its own header argues this is safe because the table holds "only public
  # profile information (username, first_name, balance)". It holds balances.
  # That policy was written against a Supabase deployment where the edge
  # functions used the service-role key and RLS was decorative; here it is the
  # only thing standing between an anonymous request and the ledger.
  #
  # Nothing in the 104 migrations ever drops it.
  #
  # WHY THE EXISTING GUARD DID NOT CATCH IT. db/20-post/003 asserted exactly
  # this, as anon, and passed:
  #
  #     SELECT count(*) INTO v_count FROM telegram_users;
  #     IF v_count > 0 THEN RAISE EXCEPTION ...
  #
  # It counts ROWS, not POLICIES. The table was empty when migrations last ran,
  # so it passed vacuously; the exposure appeared the moment a real player
  # registered. A security assertion whose result depends on how much data
  # happens to be present is not an assertion. The replacement in section 4
  # interrogates pg_policies and has_function_privilege directly, so it holds on
  # an empty database and on a full one.
  #
  # ---------------------------------------------------------------------------
  # 2. Any anonymous caller could execute the money-moving functions
  # ---------------------------------------------------------------------------
  #
  # db/20-post/001 ended with:
  #
  #     GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated, service_role;
  #
  # There are 58 functions in public, 30 of them SECURITY DEFINER -- meaning
  # they run as the owner and RLS does not apply inside them. Eight take the
  # CALLER'S OWN IDENTITY as an ordinary parameter and never check it:
  #
  #     transfer_balance(from_telegram_id, transfer_amount, to_telegram_id, ...)
  #     process_bnb_withdrawal_request(p_telegram_user_id, p_wallet_address, ...)
  #     record_user_withdrawal(p_telegram_user_id, p_wallet_address, ...)
  #     select_card_atomic(..., p_telegram_user_id, ...)
  #     handle_referral_bonus(new_user_telegram_id, referrer_code)
  #     check_bnb_withdrawal_limits(p_telegram_user_id, p_amount_bnb)
  #     get_lobby_data_instant(user_telegram_id, user_wallet_address)
  #     get_or_create_wallet_user(p_wallet_address)
  #
  # Verified against the live dev API with no token and no apikey:
  #
  #   POST /rest/v1/rpc/transfer_balance
  #     {"from_telegram_id": <a real player>, "transfer_amount": 999999999,
  #      "to_telegram_id": <attacker>}
  #   -> {"success": false, "error": "Insufficient won balance"}
  #
  # That is a BUSINESS-LOGIC rejection, not an authorization one. The function
  # ran. An amount above the balance was chosen deliberately so the probe would
  # return before any write; with an amount the balance covered, the transfer
  # would have completed. Finding 1 supplies the telegram_user_id that this
  # needs as its parameter.
  #
  # This is precisely the defect services/functions/src/auth.js was written to
  # eliminate -- "identity was asserted, not proven". It was removed from the
  # HTTP layer and left untouched in the database layer beneath it.
  #
  # ---------------------------------------------------------------------------
  # THE FIX, and why it is shaped this way
  # ---------------------------------------------------------------------------
  #
  # Deny by default, allow by name -- the same shape as the settings allowlist
  # in 003, for the same reason: a function added in future is not exposed by
  # somebody forgetting to think about it.
  #
  # Six of the eight are not reachable from the SPA at all. They were called by
  # the inherited Deno edge functions, which do not exist on this
  # infrastructure and answer 404. Revoking EXECUTE closes them outright and
  # breaks nothing that currently works -- a stronger fix than an internal
  # guard, because it removes the call path rather than checking it.
  #
  # The two the SPA does call are handled individually in section 3.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

-- ---------------------------------------------------------------------------
-- 1. telegram_users: owner-scoped reads
--
-- Drops existing SELECT policies by ENUMERATION rather than by name, for the
-- reason 003 documents at length: DROP POLICY IF EXISTS on a name that does not
-- match is a SILENT no-op, PostgreSQL ORs permissive policies together, and the
-- migration reports success while the data stays readable. That mistake has
-- already been made once in this repository.
--
-- EVERY read the SPA performs against this table is the caller's OWN row --
-- src/App.tsx:285, src/components/Lobby.tsx:128/138/152/162 and
-- src/components/WalletConnect.tsx:31/57 all filter by the current user's
-- telegram_user_id or wallet_address. So `id = auth.uid()` costs the
-- application nothing.
--
-- The one exception is src/components/Admin.tsx:206, a `count(*)` over the
-- whole table for the admin dashboard. That count will now return 0. This is
-- correct: it was only ever working because the table was world-readable, and
-- admin authorization is a separate unsolved problem here (there is an
-- admin_bootstrap_key in SSM and nothing yet consuming it). It should come back
-- as an explicit admin policy, not as a side effect of anonymous access.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_policy record;
BEGIN
  FOR v_policy IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'telegram_users'
      AND cmd IN ('SELECT', 'ALL')
      -- Privileged server-side code keeps its access. Matched on the ROLE, not
      -- on a policy name -- the first version of this exempted the literal
      -- 'Service role has full access to telegram_users' and the live database
      -- turned out to have one called 'Service role can manage telegram users',
      -- which was therefore dropped. Same class of mistake as guessing a name
      -- in DROP POLICY, which this file already warns about two lines up.
      -- service_role also holds BYPASSRLS, so nothing broke; the point is that
      -- name-matching keeps being wrong here.
      AND NOT ('service_role' = ANY(roles))
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON telegram_users', v_policy.policyname);
    RAISE NOTICE 'Dropped policy % on telegram_users', v_policy.policyname;
  END LOOP;
END $$;

-- auth.uid() is the `sub` claim, which services/functions/src/auth.js sets to
-- telegram_users.id (the uuid, NOT the Telegram bigint). See the header of that
-- file: putting the bigint in `sub` makes the uuid cast fail and every policy
-- match nothing, which presents as "the app loads but all the data is empty".
CREATE POLICY "Players can read their own row"
  ON telegram_users
  FOR SELECT
  TO authenticated
  USING (id = auth.uid());

-- Deliberately NO policy for anon. An unauthenticated caller has no row of
-- their own, so there is nothing for them to legitimately read here. The
-- pre-authentication lookups the SPA needs go through get_or_create_wallet_user
-- and get_lobby_data_instant, which are SECURITY DEFINER and are scoped in
-- section 3.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'telegram_users'
      AND policyname = 'Service role has full access to telegram_users'
  ) THEN
    CREATE POLICY "Service role has full access to telegram_users"
      ON telegram_users FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
END $$;

-- Enabled, deliberately NOT forced. FORCE would subject the table owner to RLS
-- as well, and the SECURITY DEFINER functions that legitimately span all
-- players -- payout_winners, the deposit-credit triggers, get_or_create_wallet_user
-- -- run as the owner. Forcing here would break the game rather than harden it.
-- What protects the table from those functions is section 2: they are no longer
-- reachable from the API at all.
ALTER TABLE telegram_users ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 2. EXECUTE: deny by default, allow by name
--
-- Three separate things have to be shut off, and missing any one of them leaves
-- the surface open:
--
--   a. the blanket grant db/20-post/001 issued on every previous run
--   b. PostgreSQL's own default, which grants EXECUTE to PUBLIC on every new
--      function -- so a function added tomorrow is anon-callable the moment it
--      is created, with nobody having granted anything
--   c. ALTER DEFAULT PRIVILEGES, so (b) stops happening for future migrations
--
-- ROUTINES rather than FUNCTIONS: the latter does not cover procedures.
--
-- TRIGGER FUNCTIONS ARE NOT AFFECTED, which is the obvious worry here.
-- PostgreSQL checks EXECUTE on a trigger function when the trigger is CREATED,
-- against the trigger's owner -- not per-invocation against whoever issued the
-- INSERT. Revoking from anon and authenticated therefore cannot break
-- deduct_stake_on_join, the deposit-credit triggers, or any of the others.
--
-- Nor are RLS policies affected: no policy in this schema calls a function in
-- `public` (auth.uid() and auth.role() live in the `auth` schema, which is
-- granted separately in db/00-bootstrap/001).
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA public FROM PUBLIC, anon, authenticated;

-- NOTE THE MISSING `IN SCHEMA public`, which is not an oversight.
--
-- The obvious statement here is:
--
--   ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
--
-- It reports ALTER DEFAULT PRIVILEGES, records nothing in pg_default_acl, and
-- has NO EFFECT: a function created afterwards still grants EXECUTE to PUBLIC.
-- Verified on PostgreSQL 16.14 by issuing it, creating a function, and asking
-- has_function_privilege('public', ...) -- which answered true. The `REVOKE ALL`
-- variant behaves identically.
--
-- The built-in "functions are executable by PUBLIC" rule is a DATABASE-WIDE
-- default. A per-schema default-privileges entry can only add to it; there is
-- no per-schema entry that subtracts it. So the revoke has to be issued without
-- IN SCHEMA, and then it works -- pg_default_acl records {owner=X/owner} and
-- new functions are no longer public.
--
-- This is exactly the failure mode 003 documents for DROP POLICY on a misspelt
-- name: a security statement that succeeds, changes nothing, and leaves the
-- migration reporting success. Assertion 4d exists because of it, and caught
-- this while the file was being written.
--
-- The blast radius of the database-wide form is bounded: it applies only to
-- objects created BY THIS ROLE (the migration runner), and only from now on.
-- The one thing that genuinely depended on the PUBLIC default is the auth shim
-- -- auth.uid() is called by every RLS policy -- so db/00-bootstrap/001 now
-- grants EXECUTE on those three functions explicitly rather than inheriting it.
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Privileged server-side code -- the ticker and the functions service, which
-- connect as app_service and inherit service_role -- keeps everything.
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA public TO service_role;

-- ---------------------------------------------------------------------------
-- 2b. Drop the superseded get_lobby_data_instant overload
--
-- FOUND WHEN THIS MIGRATION FAILED against the real database, which is the only
-- place it could have been found: `GRANT ... ON FUNCTION public.<name>` raised
--
--   ERROR: function name "public.get_lobby_data_instant" is not unique
--
-- Three migrations define this function and they do not agree on its arity:
--
--   20251222083326  get_lobby_data_instant(bigint)
--   20251222115912  get_lobby_data_instant(bigint)              <- redefines it
--   20260216092910  get_lobby_data_instant(bigint, text)        <- ADDS a second
--
-- CREATE OR REPLACE only replaces a function with a MATCHING signature, so the
-- last of those did not supersede the first two -- it created an overload and
-- left the one-argument version in place, still carrying its original body.
--
-- That is not merely untidy. Section 3 below rewrites the two-argument version
-- so identity comes from the JWT; the one-argument version would have kept
-- trusting the telegram id in the request body, and PostgREST resolves
-- {"user_telegram_id": N} to it by exact arity. The guard would have been
-- shipped, reported as a fix, and bypassable by omitting one field.
--
-- Dropping it is safe: the two-argument version defaults user_wallet_address to
-- NULL, so every call the one-argument version served resolves to it unchanged.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_lobby_data_instant(bigint);

-- The allowlist.
--
-- Derived from what the SPA actually calls, enumerated from source rather than
-- assumed:
--
--   grep -rhoE "\.rpc\(['\"][a-z0-9_]+" src/ | sed -E "s/.*['\"]//" | sort -u
--
-- which yields exactly six: create_game_with_server_time,
-- get_bnb_withdrawal_stats, get_lobby_data_instant, get_or_create_card_layout,
-- get_or_create_wallet_user, get_server_timestamp_ms.
--
-- Anything not named below is now unreachable over HTTP. If a future route
-- needs one, adding it here is a deliberate, reviewable line -- which is the
-- whole point.
DO $$
DECLARE
  v_fn text;
  -- Callable before the caller has proved anything. Keep this list short and
  -- justify every entry.
  v_anon text[] := ARRAY[
    -- Clock. Returns no user data. The SPA reads it to align its countdown with
    -- the server before authenticating.
    'get_server_timestamp_ms',
    'get_server_timestamp',
    -- The wallet-login path. There is no JWT at this point by construction, so
    -- this cannot be moved behind authentication without redesigning that flow.
    -- See the WALLET LOGIN note in section 3.
    'get_or_create_wallet_user',
    -- Lobby. Rewritten in section 3 so that an unauthenticated caller gets the
    -- public game state and NO user record.
    'get_lobby_data_instant',
    -- Card layouts: READ ONLY, and anon genuinely needs them.
    --
    -- These return the board for a card number -- deterministic, permanent by
    -- design (20251227075119 "permanent card layouts system"), and containing no
    -- player data whatsoever. Knowing which numbers are on card 42 is not an
    -- advantage; every player can see it before choosing.
    --
    -- Anon is required rather than merely convenient. src/App.tsx authenticates
    -- ASYNCHRONOUSLY on mount, so the Lobby can render before a token exists,
    -- and outside Telegram -- a browser tab, a preview -- there is never one at
    -- all, which App.tsx's own comment says must keep working. The card grid
    -- would be blank in both cases.
    --
    -- This is also the status quo, not a widening: the SPA has always fetched
    -- these with the anon key.
    --
    -- get_or_create_card_layout is deliberately NOT here and stays at
    -- authenticated. It WRITES a row when one is absent, and there is no reason
    -- an unauthenticated caller needs to cause that -- get_all_card_layouts
    -- covers what the app reads.
    'get_all_card_layouts',
    'get_card_layouts_batch'
  ];
  -- Callable once a player holds a token this system issued.
  v_authenticated text[] := ARRAY[
    'get_server_timestamp_ms',
    'get_server_timestamp',
    'get_or_create_wallet_user',
    'get_lobby_data_instant',
    -- Card layouts are deterministic, permanent, and hold no player data.
    'get_or_create_card_layout',
    'get_all_card_layouts',
    'get_card_layouts_batch',
    -- The ticker creates games now (ensure_waiting_game_exists). This stays
    -- reachable for the lobby's first-run path, but not anonymously: an
    -- unauthenticated caller has no business creating rounds.
    'create_game_with_server_time',
    -- Aggregate withdrawal totals. Not per-player, but it is still house
    -- financial data and was readable by anyone before this.
    'get_bnb_withdrawal_stats'
  ];
  v_sig text;
  v_n integer;
BEGIN
  -- GRANTS ARE ISSUED PER SIGNATURE, not per name.
  --
  -- `GRANT ... ON FUNCTION public.<name>` requires the name to be unique and
  -- fails outright when it is not -- which is how the stale overload in 2b was
  -- discovered. oid::regprocedure renders the full identity
  -- (`public.f(bigint,text)`), so overloads are addressed unambiguously and a
  -- future one cannot silently go ungranted.
  FOREACH v_fn IN ARRAY v_anon LOOP
    v_n := 0;
    FOR v_sig IN
      SELECT p.oid::regprocedure::text
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = v_fn
    LOOP
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon', v_sig);
      v_n := v_n + 1;
    END LOOP;

    IF v_n = 0 THEN
      RAISE NOTICE 'Allowlisted function %() does not exist; skipping', v_fn;
    ELSIF v_n > 1 THEN
      -- Not fatal, but say so. An allowlisted name with several signatures
      -- means several bodies are reachable, and only the ones this file
      -- rewrites have been read.
      RAISE NOTICE 'Allowlisted %() has % overloads; all granted to anon', v_fn, v_n;
    END IF;
  END LOOP;

  FOREACH v_fn IN ARRAY v_authenticated LOOP
    FOR v_sig IN
      SELECT p.oid::regprocedure::text
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = v_fn
    LOOP
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', v_sig);
    END LOOP;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3. get_lobby_data_instant: identity from the token, not from the argument
--
-- Redefined verbatim from
-- supabase/migrations/20260216092910_add_wallet_based_user_registration.sql
-- with ONE change, in the identity block. The game/players/takenNumbers halves
-- are byte-identical; only who the `user` key describes has changed.
--
-- Before: whichever telegram_user_id the caller typed into the request body.
-- After:  whoever the JWT says the caller is.
--
-- The discriminator is session_user, which is the LOGIN role and cannot be
-- changed by SET ROLE:
--
--   authenticator  -- arrived over HTTP through PostgREST. Untrusted.
--   app_service    -- the ticker and functions containers. Trusted; they have
--                     already authenticated the player themselves.
--
-- Note it is NOT `current_user` (inside a SECURITY DEFINER function that is the
-- owner) and NOT a pg_has_role check against service_role (authenticator is
-- granted service_role in db/00-bootstrap/001, so that test would pass for
-- exactly the caller we are trying to catch).
--
-- WALLET LOGIN, stated plainly rather than quietly closed. The wallet branch
-- still trusts the address it is handed, because that flow has no signature
-- challenge anywhere in this codebase -- connecting a wallet proves nothing to
-- the server today. Removing the branch would break wallet login outright;
-- keeping it means anyone who knows an address can read that account's
-- balances. It is left working and recorded here as a gap that must be closed
-- with a sign-in-with-Ethereum challenge before this touches mainnet funds.
-- The Telegram path -- the one with real players on it -- is now proven.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_lobby_data_instant(
  user_telegram_id bigint DEFAULT NULL,
  user_wallet_address text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result json;
  game_data json;
  user_data json;
  taken_nums bigint[];
  players_data json;
  server_time bigint;
  v_over_http boolean;
  v_uid uuid;
BEGIN
  server_time := FLOOR(EXTRACT(EPOCH FROM now() AT TIME ZONE 'UTC') * 1000);

  SELECT json_build_object(
    'id', g.id,
    'game_number', g.game_number,
    'status', g.status,
    'total_pot', g.total_pot,
    'stake_amount', g.stake_amount,
    'winner_prize', g.winner_prize,
    'starts_at', FLOOR(EXTRACT(EPOCH FROM g.starts_at AT TIME ZONE 'UTC') * 1000)
  )
  INTO game_data
  FROM games g
  WHERE g.status IN ('waiting', 'playing')
  ORDER BY g.created_at DESC
  LIMIT 1;

  IF game_data IS NOT NULL THEN
    SELECT array_agg(p.selected_number)
    INTO taken_nums
    FROM players p
    WHERE p.game_id = (game_data->>'id')::uuid;

    SELECT json_agg(
      json_build_object(
        'id', p.id,
        'selected_number', p.selected_number,
        'name', p.name,
        'telegram_user_id', p.telegram_user_id
      )
    )
    INTO players_data
    FROM players p
    WHERE p.game_id = (game_data->>'id')::uuid;
  END IF;

  v_over_http := session_user = 'authenticator';
  v_uid       := auth.uid();

  IF v_over_http AND v_uid IS NOT NULL THEN
    -- Authenticated player. The telegram id in the request body is IGNORED --
    -- the token decides whose balances come back.
    SELECT json_build_object(
      'telegram_user_id', u.telegram_user_id,
      'balance', u.balance,
      'deposited_balance', u.deposited_balance,
      'won_balance', u.won_balance,
      'telegram_username', u.telegram_username,
      'telegram_first_name', u.telegram_first_name,
      'referral_code', u.referral_code,
      'total_referrals', u.total_referrals
    )
    INTO user_data
    FROM telegram_users u
    WHERE u.id = v_uid;

  ELSIF v_over_http AND user_wallet_address IS NOT NULL THEN
    -- Wallet login. Unproven identity; see the WALLET LOGIN note above.
    SELECT json_build_object(
      'telegram_user_id', u.telegram_user_id,
      'balance', u.balance,
      'deposited_balance', u.deposited_balance,
      'won_balance', u.won_balance,
      'telegram_username', u.telegram_username,
      'telegram_first_name', u.telegram_first_name,
      'referral_code', u.referral_code,
      'total_referrals', u.total_referrals
    )
    INTO user_data
    FROM telegram_users u
    WHERE lower(u.wallet_address) = lower(user_wallet_address);

  ELSIF NOT v_over_http THEN
    -- Server-side caller (ticker, functions service). It has authenticated the
    -- player itself, so the parameters are honoured as before.
    IF user_telegram_id IS NOT NULL THEN
      SELECT json_build_object(
        'telegram_user_id', u.telegram_user_id,
        'balance', u.balance,
        'deposited_balance', u.deposited_balance,
        'won_balance', u.won_balance,
        'telegram_username', u.telegram_username,
        'telegram_first_name', u.telegram_first_name,
        'referral_code', u.referral_code,
        'total_referrals', u.total_referrals
      )
      INTO user_data
      FROM telegram_users u
      WHERE u.telegram_user_id = user_telegram_id;
    ELSIF user_wallet_address IS NOT NULL THEN
      SELECT json_build_object(
        'telegram_user_id', u.telegram_user_id,
        'balance', u.balance,
        'deposited_balance', u.deposited_balance,
        'won_balance', u.won_balance,
        'telegram_username', u.telegram_username,
        'telegram_first_name', u.telegram_first_name,
        'referral_code', u.referral_code,
        'total_referrals', u.total_referrals
      )
      INTO user_data
      FROM telegram_users u
      WHERE lower(u.wallet_address) = lower(user_wallet_address);
    END IF;
  END IF;
  -- Remaining case: over HTTP, no token, no wallet address -> user_data stays
  -- NULL. An anonymous caller passing someone else's telegram id now gets the
  -- public game state and nothing about that player.

  result := json_build_object(
    'game', game_data,
    'takenNumbers', COALESCE(taken_nums, ARRAY[]::bigint[]),
    'players', COALESCE(players_data, '[]'::json),
    'user', user_data,
    'serverTime', server_time
  );

  RETURN result;
END;
$$;

-- CREATE OR REPLACE resets the function's ACL, so restate the grants.
REVOKE EXECUTE ON FUNCTION public.get_lobby_data_instant(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_lobby_data_instant(bigint, text)
  TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Assertions
--
-- These interrogate the CATALOGUE -- pg_policies and has_function_privilege --
-- rather than counting rows. That distinction is the entire lesson of this
-- migration: the check these replace passed on an empty table while the
-- exposure was live, and would have kept passing until a player registered.
--
-- A catalogue assertion holds on a fresh database, on a restored snapshot, and
-- on production with ten thousand players in it.
-- ---------------------------------------------------------------------------

-- 4a. No unrestricted SELECT policy on telegram_users, for any role.
DO $$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(format('%s (roles: %s)', policyname, array_to_string(roles, ',')), '; ')
  INTO v_bad
  FROM pg_policies
  WHERE schemaname = 'public'
    AND tablename = 'telegram_users'
    AND cmd IN ('SELECT', 'ALL')
    AND coalesce(qual, 'true') = 'true'
    AND NOT ('service_role' = ANY(roles));

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION
      'telegram_users still has an unrestricted read policy: %. Balances are readable.',
      v_bad;
  END IF;

  RAISE NOTICE 'telegram_users: no unrestricted read policy';
END $$;

-- 4b. anon cannot execute anything outside the allowlist.
--
-- Names the offenders rather than reporting a count, so the failure message is
-- the fix list.
DO $$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(DISTINCT p.proname, ', ' ORDER BY p.proname)
  INTO v_bad
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND has_function_privilege('anon', p.oid, 'EXECUTE')
    -- Must stay in step with v_anon in section 2. Restated rather than shared,
    -- deliberately: an assertion that reads the same variable as the code it
    -- checks proves only that the variable equals itself. Adding to one list and
    -- not the other fails this check, which is the intended behaviour.
    AND p.proname <> ALL (ARRAY[
      'get_server_timestamp_ms', 'get_server_timestamp',
      'get_or_create_wallet_user', 'get_lobby_data_instant',
      'get_all_card_layouts', 'get_card_layouts_batch'
    ]);

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION
      'anon can execute functions outside the allowlist: %', v_bad;
  END IF;

  RAISE NOTICE 'anon: EXECUTE limited to the allowlist';
END $$;

-- 4c. The specific escalation paths are closed. Named individually because
--     these are the ones that move money, and a regression on any of them is
--     worth its own line in the failure message rather than being folded into
--     the list above.
DO $$
DECLARE
  v_fn text;
  v_role text;
  v_bad text := '';
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'transfer_balance',
    'process_bnb_withdrawal_request',
    'record_user_withdrawal',
    'select_card_atomic',
    'handle_referral_bonus',
    'check_bnb_withdrawal_limits'
  ] LOOP
    FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = v_fn
          AND has_function_privilege(v_role, p.oid, 'EXECUTE')
      ) THEN
        v_bad := v_bad || format(' %s(%s)', v_fn, v_role);
      END IF;
    END LOOP;
  END LOOP;

  IF v_bad <> '' THEN
    RAISE EXCEPTION
      'Money-moving functions are still callable from the API:%. These take the caller identity as a parameter and do not check it.',
      v_bad;
  END IF;

  RAISE NOTICE 'Money-moving functions: not callable by anon or authenticated';
END $$;

-- 4e. Exactly one get_lobby_data_instant survives, and it is the guarded one.
--
--     Section 3 rewrites the two-argument signature. A surviving one-argument
--     overload would keep the old body -- trusting the telegram id in the
--     request body -- and PostgREST resolves {"user_telegram_id": N} to it by
--     exact arity, so the guard would be bypassable by omitting a field. That
--     was the live state until 2b dropped it, and this is what stops a future
--     migration from reintroducing it unnoticed.
DO $$
DECLARE
  v_sigs text;
  v_count integer;
BEGIN
  SELECT count(*), string_agg(p.oid::regprocedure::text, ', ')
  INTO v_count, v_sigs
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_lobby_data_instant';

  IF v_count <> 1 THEN
    RAISE EXCEPTION
      'Expected exactly one get_lobby_data_instant, found %: %. An overload this file did not rewrite still trusts the caller-supplied telegram id.',
      v_count, v_sigs;
  END IF;

  RAISE NOTICE 'get_lobby_data_instant: one signature, identity taken from the token';
END $$;

-- 4f. app_service actually bypasses RLS.
--
--     Every server-side route -- the ticker's game loop, /select-card,
--     /claim-bingo, the admin queue -- reads tables as app_service and assumes it
--     sees everything. It did not. BYPASSRLS is a role ATTRIBUTE and attributes do
--     not travel through GRANT, so `GRANT service_role TO app_service` made it a
--     MEMBER with rolbypassrls = false.
--
--     That is invisible until a table has no `TO service_role` policy, because
--     membership satisfies a policy even when the attribute is absent. Every table
--     the game touches had one; bank_options did not, and the deposit route read
--     zero rows from it and reported the account as unknown.
--
--     A missing policy reads as an empty table rather than as an error, which is
--     why this is asserted rather than left to be noticed.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_service' AND rolbypassrls) THEN
    RAISE EXCEPTION
      'app_service does not have BYPASSRLS. Membership of service_role does not confer it -- attributes are not inherited. Server-side reads will silently return zero rows on any table without a service_role policy.';
  END IF;
  RAISE NOTICE 'app_service: BYPASSRLS set on the role itself';
END $$;

-- 4d. A function created by the NEXT migration is not anon-callable the moment
--     it exists.
--
--     PostgreSQL's built-in default is `GRANT EXECUTE ... TO PUBLIC`, which is
--     how six money-moving functions became reachable without anyone ever
--     writing a GRANT for them. The ALTER DEFAULT PRIVILEGES in section 2
--     removes it; this proves it took effect, because a silently ineffective
--     ALTER DEFAULT PRIVILEGES leaves no other visible trace.
--
--     In an ACL string, a grant to PUBLIC is the entry with an EMPTY grantee --
--     it renders as `=X/owner`, as distinct from `anon=X/owner`.
DO $$
DECLARE
  v_acl text[];
  v_entry text;
BEGIN
  -- defaclnamespace = 0 is the database-wide entry. A schema-scoped row would
  -- not answer this question; see the note on the ALTER above.
  SELECT defaclacl::text[] INTO v_acl
  FROM pg_default_acl d
  WHERE d.defaclobjtype = 'f'
    AND d.defaclnamespace = 0
    AND d.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = current_user);

  IF v_acl IS NULL THEN
    RAISE EXCEPTION
      'No default privileges recorded for functions in schema public. New functions will be granted EXECUTE to PUBLIC on creation.';
  END IF;

  FOREACH v_entry IN ARRAY v_acl LOOP
    IF v_entry LIKE '=%' THEN
      RAISE EXCEPTION
        'Default privileges still grant to PUBLIC (%). A function added by a future migration would be anon-callable on creation.',
        v_entry;
    END IF;
  END LOOP;

  RAISE NOTICE 'Default privileges: new functions are not granted to PUBLIC';
END $$;
