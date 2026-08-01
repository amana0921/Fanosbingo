/*
  # Game state: the client may READ it and may not WRITE it
  #
  # ---------------------------------------------------------------------------
  # WHAT THIS CLOSES, stated plainly first because it is the worst defect found
  # in this codebase so far
  # ---------------------------------------------------------------------------
  #
  # Any authenticated player could credit themselves an arbitrary balance with a
  # single PostgREST request:
  #
  #   PATCH /rest/v1/games?id=eq.<any game>
  #   {"status":"finished","winner_ids":["<my player row id>"],
  #    "winner_prize_each":100000,"winners_paid":false}
  #
  # Three inherited pieces line up to make that work, and each is individually
  # defensible:
  #
  #   1. db/20-post/001_rds_deltas.sql:121
  #        GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public
  #          TO authenticated;
  #      A blanket write grant on every table.
  #
  #   2. 20251109203131_create_bingo_tables.sql
  #        CREATE POLICY "Hosts can update their games"
  #          ON games FOR UPDATE USING (true) WITH CHECK (true);
  #      There is no host in this game. The policy is a leftover from a
  #      lobby-owner model that never existed here, and it authorises everyone.
  #
  #   3. 20251218160619_fix_winner_payout_trigger.sql
  #        CREATE TRIGGER payout_on_game_finish BEFORE UPDATE ON games
  #          WHEN (NEW.status = 'finished' AND OLD.status != 'finished')
  #          EXECUTE FUNCTION payout_winners();
  #      payout_winners() reads NEW.winner_ids and NEW.winner_prize_each --
  #      FROM THE UPDATE ITSELF -- and credits won_balance accordingly.
  #
  # So the trigger faithfully pays out whatever the attacker put in the row. It
  # is not a bug in payout_winners(): it is correct code that assumed only
  # trusted server-side callers could ever set those columns. Nothing enforced
  # that assumption.
  #
  # WHY THIS IS URGENT NOW SPECIFICALLY. Minted won_balance previously had no
  # exit -- every on-chain withdrawal route is a 404 on this infrastructure. The
  # bank withdrawal path (db/20-post/007 plus /withdrawals/request) gives it one:
  # won_balance is exactly what it pays out, in cash, by hand, irreversibly.
  # THIS FILE MUST BE APPLIED BEFORE THOSE ROUTES ARE DEPLOYED.
  #
  # The same grant plus the equally permissive players policies also allowed:
  #
  #   DELETE /rest/v1/players?id=eq.<anyone>
  #     fires refund_stake_on_player_delete, so a player could remove ANY other
  #     player from a live game, and could remove THEMSELVES mid-game to get
  #     their stake back -- a free option on every round.
  #
  #   PATCH /rest/v1/players?id=eq.<anyone>
  #     rewrite another player's card or marked cells.
  #
  # ---------------------------------------------------------------------------
  # THE FIX, and why it is a revoke rather than a narrower policy
  # ---------------------------------------------------------------------------
  #
  # The client has NO legitimate write to either table. Enumerated from source
  # rather than assumed:
  #
  #   players   ZERO writes. Joining goes through select_card_atomic (via
  #             /select-card), claiming through atomic_claim_bingo (via
  #             /claim-bingo). Both are SECURITY DEFINER and both were already
  #             revoked from authenticated by db/20-post/004.
  #
  #   games     THREE writes, all of them client-driven game logic that
  #             db/20-post/002 already replaced:
  #
  #               Lobby.tsx  update starts_at/selection_closed_at   -> game_tick step 3
  #               Lobby.tsx  update status='playing'                 -> game_tick step 3
  #               Admin.tsx  update status='finished'                -> needs an admin route
  #
  #             The first two are exactly the case GameRoom.tsx documents for the
  #             force-finish-game route it deleted: "a game that only finishes
  #             when somebody has the tab open". game_tick() does both once a
  #             second whether or not a browser is watching.
  #
  # So a scoped policy would be modelling a permission nobody needs. Deny by
  # default, the same shape as the EXECUTE allowlist in 004 and the settings
  # allowlist in 003.
  #
  # WHAT KEEPS WORKING, and why:
  #
  #   SELECT stays open on both tables. The lobby must show who has joined and
  #   which cards are taken, and neither table holds a balance -- 004 is what
  #   scoped telegram_users, which is where the money lives.
  #
  #   Every SECURITY DEFINER function is unaffected. They run as the table owner,
  #   so table privileges granted to `authenticated` are not what they use:
  #   game_tick, select_card_atomic, atomic_claim_bingo, payout_winners,
  #   create_game_with_server_time (still callable, still on 004's allowlist).
  #
  #   The ticker and functions containers connect as app_service, which holds
  #   service_role and BYPASSRLS, and 001_rds_deltas grants ALL to service_role.
  #
  # ORDERING DEPENDENCY, stated because it is fragile: 001_rds_deltas re-issues
  # its blanket grant on every run, and these files are applied in filename
  # order, so this file must sort AFTER it. It does (008 > 001). If the numbering
  # scheme ever changes, this revoke silently stops holding.
  #
  # ROOT CAUSE NOT FIXED HERE: that blanket grant is itself the deny-by-default
  # failure, one level up -- it hands `authenticated` write access to every table
  # in the schema and is only harmless where a restrictive policy happens to
  # exist. Converting it to an allowlist is the right follow-up; it is not done
  # in the same change as an urgent fix, because the regression surface is every
  # table rather than these two.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

-- ---------------------------------------------------------------------------
-- 1. Drop permissive write policies, by ENUMERATION
--
-- By enumeration rather than by name, for the reason 003 and 004 both document
-- at length: DROP POLICY IF EXISTS on a name that does not match is a SILENT
-- no-op, PostgreSQL ORs permissive policies together, and the migration reports
-- success while the table stays writable. That mistake has already been made
-- twice in this repository.
--
-- service_role policies are matched on the ROLE and left alone -- 004 learned
-- that guessing at a policy NAME is what goes wrong here.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_table text;
  v_policy record;
BEGIN
  FOREACH v_table IN ARRAY ARRAY['games', 'players']
  LOOP
    FOR v_policy IN
      SELECT policyname
      FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = v_table
        AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        AND NOT ('service_role' = ANY(roles))
    LOOP
      EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_policy.policyname, v_table);
      RAISE NOTICE 'Dropped write policy % on %', v_policy.policyname, v_table;
    END LOOP;
  END LOOP;
END $$;

-- Privileged server-side code keeps full access. Created if absent rather than
-- assumed: on a fresh database (a restore drill, or the first prod apply) there
-- is no inherited policy to preserve.
DO $$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY['games', 'players']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'public' AND tablename = v_table
        AND 'service_role' = ANY(roles) AND cmd = 'ALL'
    ) THEN
      EXECUTE format(
        'CREATE POLICY %I ON public.%I FOR ALL TO service_role USING (true) WITH CHECK (true)',
        'Service role has full access to ' || v_table, v_table);
      RAISE NOTICE 'Created service_role policy on %', v_table;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Revoke the table privilege itself
--
-- BOTH gates, deliberately. A policy is only consulted after table-level
-- privilege lets the role touch the table at all, so revoking the privilege is
-- the stronger control -- it holds even if a permissive policy is reintroduced
-- by a future migration that nobody reads carefully.
--
-- Dropping the policies in section 1 is therefore not redundant: it removes the
-- misleading artefact that says everyone may write, so the next person to read
-- pg_policies is not told the opposite of what is true.
-- ---------------------------------------------------------------------------
REVOKE INSERT, UPDATE, DELETE ON public.games   FROM PUBLIC, anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.players FROM PUBLIC, anon, authenticated;

-- Reading stays open. Neither table holds money; telegram_users does, and
-- db/20-post/004 scoped that to the owning player.
GRANT SELECT ON public.games   TO anon, authenticated;
GRANT SELECT ON public.players TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Assertions
--
-- Interrogating privileges directly, so these hold on an empty database and on a
-- full one alike. 004 documents why that matters: the guard it replaced counted
-- ROWS, passed vacuously against an empty table, and the exposure appeared the
-- moment a real player registered.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_role text;
  v_table text;
  v_priv text;
BEGIN
  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated']
  LOOP
    FOREACH v_table IN ARRAY ARRAY['games', 'players']
    LOOP
      FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE']
      LOOP
        IF has_table_privilege(v_role, 'public.' || v_table, v_priv) THEN
          RAISE EXCEPTION
            '% can still % public.%. The game-state write path is open: a PATCH on games sets winner_ids and winner_prize_each, which payout_winners() credits.',
            v_role, v_priv, v_table;
        END IF;
      END LOOP;

      IF NOT has_table_privilege(v_role, 'public.' || v_table, 'SELECT') THEN
        RAISE EXCEPTION '% cannot SELECT public.%; the lobby needs it.', v_role, v_table;
      END IF;
    END LOOP;
  END LOOP;

  -- The ticker and the functions service must still be able to run the game.
  IF NOT has_table_privilege('service_role', 'public.games', 'UPDATE') THEN
    RAISE EXCEPTION 'service_role cannot UPDATE games; the game loop is broken.';
  END IF;

  RAISE NOTICE 'game state: clients read only, service_role writes';
END $$;
