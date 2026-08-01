/*
  # Ending a game, as an operator rather than as a browser
  #
  # db/20-post/008 revoked UPDATE on `games` from anon and authenticated, which
  # closed the path that let any player set winner_ids and be paid for it. It
  # also broke the one write on that table that was legitimate:
  # src/components/Admin.tsx ended a game with a direct
  #
  #   UPDATE games SET status='finished', finished_at=now() WHERE id = ...
  #
  # That is a real operator need -- a game wedged by a bad deploy, or one that
  # has to be stopped -- so it comes back here as a function the operator's route
  # can call, rather than as a table privilege the browser holds.
  #
  # WHAT THIS DELIBERATELY DOES NOT DO, and it is the entire design.
  #
  # It sets status and finished_at. NOTHING ELSE. It does not accept winner_ids,
  # winner_prize_each or winners_paid, and it does not compute them.
  #
  # Those three columns are what payout_winners() reads to decide who gets
  # credited and how much, so a function that took them as parameters would
  # rebuild the exact hole 008 just closed -- only reachable by an admin instead
  # of by anyone, which is a smaller hole rather than a different kind. An admin
  # account is one compromised Telegram session; it is not a reason to hand out
  # the ability to mint balance.
  #
  # So a game ended here pays out whatever atomic_claim_bingo already recorded,
  # and nothing if nobody claimed. That is exactly what game_tick() does when it
  # finishes a game -- steps 1 and 2 of db/20-post/002 both write precisely
  # `status='finished', finished_at=now()` -- and matching it means there is one
  # answer to "what happens when a game ends", not two.
  #
  # NO REFUND SEMANTICS ARE INVENTED HERE. Ending a game mid-play with no winner
  # leaves the stakes in the pot, which is what the direct UPDATE did before. If
  # that should refund, it is a product decision with its own migration, not
  # something to smuggle into a fix for a security regression.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

CREATE OR REPLACE FUNCTION admin_end_game(
  p_game_id uuid,
  p_admin_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row games%ROWTYPE;
BEGIN
  IF p_admin_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'NO_ADMIN');
  END IF;

  -- The status filter is the lock, the same shape 006 and 007 use for their
  -- decisions: a game already finished is not re-finished, so the payout trigger
  -- cannot fire twice for one game no matter how many times this is called.
  UPDATE games
     SET status      = 'finished',
         finished_at = now()
   WHERE id = p_game_id
     AND status IN ('waiting', 'playing')
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    -- Covers "already finished" and "does not exist" alike. The route answers
    -- 409, because that is what a double-clicked button produces and the right
    -- response is to reload rather than retry.
    RETURN jsonb_build_object('success', false, 'error_code', 'NOT_ENDABLE');
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'game_id', v_row.id,
    'previous_status', v_row.status,
    'winners_paid', v_row.winners_paid
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- service_role only, for the reason db/20-post/004 established
--
-- It takes an admin id and does not verify it. Exposed to `authenticated`, any
-- player could end any game -- griefing every player in it, and firing the
-- payout trigger at a moment of their choosing.
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION admin_end_game(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION admin_end_game(uuid, uuid) TO service_role;

DO $$
BEGIN
  IF has_function_privilege('authenticated', 'admin_end_game(uuid,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'admin_end_game is callable by authenticated; any player could end any game.';
  END IF;

  -- The guard that matters more than the grant: this function must never learn
  -- to write the payout columns. Checked against the source, so reintroducing
  -- them fails the migration rather than shipping quietly.
  IF EXISTS (
    SELECT 1 FROM pg_proc
    WHERE proname = 'admin_end_game'
      AND prosrc ~* '(winner_ids|winner_prize_each|winners_paid)\s*='
  ) THEN
    RAISE EXCEPTION
      'admin_end_game assigns a payout column. Those are what payout_winners() reads; writing them from an operator route rebuilds the hole db/20-post/008 closed.';
  END IF;

  RAISE NOTICE 'admin game control: service_role only, payout columns untouched';
END $$;
