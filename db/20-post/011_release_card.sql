/*
  # Releasing a card you have selected
  #
  # src/components/Lobby.tsx has always offered this and it has always been a
  # 404: it POSTs /functions/v1/deselect-card, an inherited Deno name the rebuilt
  # API never implemented. A player who picked the wrong card could not put it
  # back. The optimistic update rolls back and they get a toast, so it fails
  # visibly rather than silently -- but it fails.
  #
  # WHY THIS IS A FUNCTION AND NOT PLAIN DATA ACCESS.
  #
  # The question db/20-post/004 and AGENTS.md §7 ask of every 404 route is "why
  # can RLS not do this?" For get-card-layouts and force-finish-game the answer
  # was "it can", and both were deleted rather than ported. Here it genuinely
  # cannot, for two reasons that only became true recently:
  #
  #   1. Deleting a players row fires refund_player_stake(), which moves money.
  #      An RLS policy can say WHICH rows you may delete; it cannot express "and
  #      only while the game has not started", because that condition lives on a
  #      different table and the refund is unconditional.
  #
  #   2. db/20-post/008 revoked DELETE on players from anon and authenticated
  #      outright, because `CREATE POLICY "Anyone can delete players" USING (true)`
  #      let any player remove any other -- and let a player remove THEMSELVES
  #      mid-game for a refund, which is a free option on every round.
  #
  # So the capability comes back here, scoped, rather than as a table privilege.
  #
  # THE WINDOW IS THE WHOLE POINT.
  #
  # Releasing is only legitimate while selection is still open. After that, a
  # release is a refund on a game you are already losing -- exactly the exploit
  # 008 closed, rebuilt with a friendlier name. Two conditions, both checked
  # under a row lock:
  #
  #   the game is still 'waiting'
  #   selection_closed_at has not passed
  #
  # The second is not redundant. game_tick() flips waiting -> playing when
  # starts_at arrives, and selection_closed_at is five seconds EARLIER (see
  # db/20-post/002 step 3) -- so there is a window where the game is still
  # 'waiting' but the board is locked. Checking only the status would allow a
  # release inside it.
  #
  # KNOWN QUIRK, INHERITED, NOT FIXED HERE: refund_player_stake() always credits
  # deposited_balance, even when the stake was partly covered by won_balance.
  # A player who releases can therefore convert won_balance into
  # deposited_balance, which db/20-post/007 does not pay out. It disadvantages
  # the player rather than the house, so it is a correctness bug to fix on its
  # own evidence -- not something to change inside a migration whose job is to
  # restore a capability safely.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

CREATE OR REPLACE FUNCTION release_card(
  p_telegram_user_id bigint,
  p_player_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_player players%ROWTYPE;
  v_game   games%ROWTYPE;
BEGIN
  IF p_telegram_user_id IS NULL OR p_player_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'INVALID_ARGUMENTS');
  END IF;

  -- Lock the row first. Two concurrent releases of the same player would
  -- otherwise both pass their checks and the second would refund a row the
  -- first had already deleted -- or, worse, both would fire the trigger.
  SELECT * INTO v_player
    FROM players
   WHERE id = p_player_id
     FOR UPDATE;

  IF NOT FOUND THEN
    -- Covers "already released" and "never existed". Not distinguished: a
    -- caller who may not act on this row should not learn whether it is there.
    RETURN jsonb_build_object('success', false, 'error_code', 'NOT_FOUND');
  END IF;

  -- OWNERSHIP. The caller's telegram id comes from the verified JWT, never from
  -- the request body -- that is the defect services/functions/src/auth.js exists
  -- to remove, and the inherited deselect-card call site sent it in the body
  -- alongside the ANON key.
  IF v_player.telegram_user_id IS DISTINCT FROM p_telegram_user_id THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'NOT_YOURS');
  END IF;

  SELECT * INTO v_game
    FROM games
   WHERE id = v_player.game_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'GAME_NOT_FOUND');
  END IF;

  IF v_game.status <> 'waiting' THEN
    RETURN jsonb_build_object(
      'success', false, 'error_code', 'GAME_STARTED', 'status', v_game.status);
  END IF;

  -- See the header: 'waiting' alone is not sufficient, because the board locks
  -- five seconds before the status changes.
  IF v_game.selection_closed_at IS NOT NULL AND v_game.selection_closed_at <= now() THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'SELECTION_CLOSED');
  END IF;

  -- The refund is the trigger's job (refund_player_stake, BEFORE DELETE), which
  -- also adjusts total_pot and winner_prize. Deliberately not duplicated here:
  -- two places crediting one refund is how a balance gets credited twice.
  DELETE FROM players WHERE id = v_player.id;

  RETURN jsonb_build_object(
    'success', true,
    'player_id', v_player.id,
    'card_number', v_player.selected_number,
    'game_id', v_player.game_id
  );
END;
$$;

-- ---------------------------------------------------------------------------
-- service_role only, for the reason db/20-post/004 established
--
-- It takes an identity as a parameter and cannot verify it. Exposed to
-- `authenticated`, a player could pass somebody else's telegram id and release
-- their card -- which is the same griefing 008 closed, through a different door.
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION release_card(bigint, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION release_card(bigint, uuid) TO service_role;

DO $$
BEGIN
  IF has_function_privilege('authenticated', 'release_card(bigint,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'release_card is callable by authenticated; a player could release somebody else''s card.';
  END IF;

  -- The privilege 008 revoked must stay revoked. This function is the only way
  -- a client should reach a DELETE on players, and if the table privilege came
  -- back the window check above would be bypassable entirely.
  IF has_table_privilege('authenticated', 'public.players', 'DELETE') THEN
    RAISE EXCEPTION
      'authenticated can DELETE players directly, so release_card''s game-status window can be bypassed. db/20-post/008 should have revoked this.';
  END IF;

  RAISE NOTICE 'release_card: own row only, while selection is open';
END $$;
