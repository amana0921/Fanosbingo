/*
  # game_tick(): the server-authoritative game loop
  #
  # Replaces FIVE behaviours that the browser currently owns. Today the game
  # only progresses while somebody has a tab open: if the last player closes the
  # lobby mid-countdown, the game never starts; if nobody is watching a stalled
  # game, it never recovers. That is not a property a real-money game can have.
  #
  #   1. Call the next number          (was pg_cron @ 4s -- unschedulable on RDS)
  #   2. Start a game when its countdown expires   (was Lobby.tsx:433)
  #   3. Roll the countdown when nobody joined     (was Lobby.tsx:445)
  #   4. Close an expired claim window and finish  (was a setTimeout AFTER the
  #                                                 HTTP response in claim-bingo)
  #   5. Ensure a waiting game always exists       (was Lobby.tsx:483)
  #
  # Point 4 deserves emphasis: claim-bingo/index.ts:52 schedules payout
  # finalization with setTimeout AFTER returning its response. Serverless
  # runtimes may freeze the isolate the moment a response is sent, so that
  # callback is not guaranteed to run -- and when it does not, winners are never
  # paid and the game never leaves 'playing'. It also queried
  # status='playing' with no game-id filter, so with two concurrent games it
  # could finalize the wrong one.
  #
  # Everything happens in ONE transaction with row locks. The previous
  # call_next_bingo_number() read last_number_called_at with a plain SELECT and
  # then UPDATEd, so two concurrent callers could both observe the same value
  # and both append a number. FOR UPDATE SKIP LOCKED makes that impossible.
  #
  # Returns a jsonb summary the ticker uses for logging and CloudWatch metrics.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

CREATE OR REPLACE FUNCTION game_tick(
  p_call_interval_ms   integer DEFAULT 3500,
  p_claim_window_ms    integer DEFAULT 1000,
  p_countdown_seconds  integer DEFAULT 25,
  p_selection_lead_ms  integer DEFAULT 5000,
  p_max_numbers        integer DEFAULT 75
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_game               RECORD;
  v_new_number         integer;
  v_remaining          integer[];
  v_numbers_called     integer := 0;
  v_games_started      integer := 0;
  v_games_finished     integer := 0;
  v_countdowns_rolled  integer := 0;
  v_claims_closed      integer := 0;
  v_game_created       boolean := false;
  v_player_count       integer;
  v_next_game_number   integer;
  v_new_game_id        uuid;
  v_oldest_call_age_ms integer := 0;
BEGIN
  -- =========================================================================
  -- 1. Close expired claim windows
  --
  -- Runs BEFORE number calling so a game whose window has closed is finished
  -- rather than having another number called into it.
  --
  -- Setting status='finished' fires the payout_winners() trigger, which credits
  -- winners and sets winners_paid. That trigger is idempotent.
  -- =========================================================================
  FOR v_game IN
    SELECT id, claim_window_start
    FROM games
    WHERE status = 'playing'
      AND claim_window_start IS NOT NULL
      AND claim_window_start <= now() - make_interval(secs => p_claim_window_ms / 1000.0)
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE games
    SET status = 'finished',
        finished_at = now()
    WHERE id = v_game.id
      AND status = 'playing';

    v_claims_closed := v_claims_closed + 1;
    v_games_finished := v_games_finished + 1;
  END LOOP;

  -- =========================================================================
  -- 2. Call the next number
  --
  -- SKIP LOCKED rather than blocking: if another ticker somehow holds this row,
  -- the correct behaviour is to leave it alone this tick, not to queue up and
  -- call a number late.
  -- =========================================================================
  FOR v_game IN
    SELECT id, called_numbers, last_number_called_at
    FROM games
    WHERE status = 'playing'
      AND claim_window_start IS NULL
      AND (
        last_number_called_at IS NULL
        OR last_number_called_at <= now() - make_interval(secs => p_call_interval_ms / 1000.0)
      )
    FOR UPDATE SKIP LOCKED
  LOOP
    -- Exhausted the board: finish rather than spin.
    IF coalesce(array_length(v_game.called_numbers, 1), 0) >= p_max_numbers THEN
      UPDATE games
      SET status = 'finished',
          finished_at = now()
      WHERE id = v_game.id;

      v_games_finished := v_games_finished + 1;
      CONTINUE;
    END IF;

    v_remaining := ARRAY(
      SELECT n FROM generate_series(1, p_max_numbers) n
      WHERE n <> ALL(coalesce(v_game.called_numbers, ARRAY[]::integer[]))
    );

    IF coalesce(array_length(v_remaining, 1), 0) = 0 THEN
      UPDATE games
      SET status = 'finished',
          finished_at = now()
      WHERE id = v_game.id;

      v_games_finished := v_games_finished + 1;
      CONTINUE;
    END IF;

    v_new_number := v_remaining[1 + floor(random() * array_length(v_remaining, 1))::int];

    UPDATE games
    SET current_number = v_new_number,
        called_numbers = array_append(called_numbers, v_new_number),
        last_number_called_at = now()
    WHERE id = v_game.id;

    v_numbers_called := v_numbers_called + 1;
  END LOOP;

  -- =========================================================================
  -- 3. Start games whose countdown expired, or roll the countdown
  --
  -- A game with no players must not start: it would produce a zero-pot round
  -- and immediately finish. Rolling the countdown keeps the lobby alive without
  -- needing a browser to do it.
  -- =========================================================================
  FOR v_game IN
    SELECT id, starts_at
    FROM games
    WHERE status = 'waiting'
      AND starts_at <= now()
    FOR UPDATE SKIP LOCKED
  LOOP
    SELECT count(*) INTO v_player_count FROM players WHERE game_id = v_game.id;

    IF v_player_count > 0 THEN
      UPDATE games
      SET status = 'playing',
          started_at = now(),
          -- Seed so the first number is called on the NEXT tick rather than
          -- instantly, giving players the moment the countdown promised.
          last_number_called_at = now()
      WHERE id = v_game.id
        AND status = 'waiting';

      v_games_started := v_games_started + 1;
    ELSE
      UPDATE games
      SET starts_at = now() + make_interval(secs => p_countdown_seconds),
          selection_closed_at =
            now() + make_interval(secs => p_countdown_seconds)
                  - make_interval(secs => p_selection_lead_ms / 1000.0)
      WHERE id = v_game.id;

      v_countdowns_rolled := v_countdowns_rolled + 1;
    END IF;
  END LOOP;

  -- =========================================================================
  -- 4. Ensure a waiting game exists
  --
  -- Previously done by whichever browser noticed first, via a non-atomic
  -- "check then insert" that let two clients create two games. Here the
  -- ticker's advisory lock already serialises it.
  -- =========================================================================
  IF NOT EXISTS (SELECT 1 FROM games WHERE status = 'waiting') THEN
    SELECT coalesce(max(game_number), 0) + 1 INTO v_next_game_number FROM games;

    -- Column list mirrors ensure_waiting_game_exists(), which is the reliable
    -- reference for the CURRENT shape of this table. `code` was in the original
    -- CREATE TABLE but dropped by the second migration
    -- (20251109203630_update_bingo_auto_games), so reading the initial schema
    -- and stopping there gets you a column that has not existed for months.
    INSERT INTO games (
      status, host_id, called_numbers, game_number,
      starts_at, selection_closed_at, current_number, winner_ids,
      stake_amount, total_pot, winner_prize, winner_prize_each
    ) VALUES (
      'waiting',
      'system',
      ARRAY[]::integer[],
      v_next_game_number,
      now() + make_interval(secs => p_countdown_seconds),
      now() + make_interval(secs => p_countdown_seconds)
            - make_interval(secs => p_selection_lead_ms / 1000.0),
      NULL,
      ARRAY[]::uuid[],
      10, 0, 0, 0
    )
    RETURNING id INTO v_new_game_id;

    v_game_created := true;
  END IF;

  -- =========================================================================
  -- 5. Health signal
  --
  -- The age of the least-recently-called playing game. The ticker publishes
  -- this as SecondsSinceLastNumberCalled; an alarm on it is what turns a frozen
  -- game from a support ticket into a page.
  -- =========================================================================
  SELECT coalesce(
    max(extract(epoch FROM (now() - last_number_called_at)) * 1000)::integer, 0)
  INTO v_oldest_call_age_ms
  FROM games
  WHERE status = 'playing' AND last_number_called_at IS NOT NULL;

  RETURN jsonb_build_object(
    'numbers_called',       v_numbers_called,
    'games_started',        v_games_started,
    'games_finished',       v_games_finished,
    'countdowns_rolled',    v_countdowns_rolled,
    'claims_closed',        v_claims_closed,
    'waiting_game_created', v_game_created,
    'oldest_call_age_ms',   v_oldest_call_age_ms,
    'active_games', (SELECT count(*) FROM games WHERE status = 'playing')
  );
END;
$$;

COMMENT ON FUNCTION game_tick IS
  'Server-authoritative game loop, called once per second by the ticker container while it holds the advisory lock. Replaces the browser-driven state machine and the unschedulable 4-second pg_cron job.';

-- Only privileged server-side code may drive the game. Explicitly revoked from
-- anon and authenticated: a player being able to call the next number early
-- would be a straightforward way to cheat.
REVOKE ALL ON FUNCTION game_tick FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION game_tick TO service_role;
