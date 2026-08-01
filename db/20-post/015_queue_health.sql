/*
  # How long money has been sitting in a queue nobody is watching
  #
  # FOUND BY LOOKING AT A PLAYER'S SCREEN. The activity panel added alongside the
  # named balances showed:
  #
  #     Deposit · Telebirr    0.10    pending    1d ago
  #
  # against a PLAY BALANCE of 0.00. That player had been unable to join a game
  # for a day, while the deposit form told them "we check the account and credit
  # you, usually within a few minutes".
  #
  # Nothing was broken. The queue worked, the policy worked, the route worked.
  # There was simply no signal to the operator that anything was in it, so a
  # promise the UI makes had no mechanism behind it.
  #
  # This is the same shape as the game loop, and db/20-post/002 already states
  # the principle: the health signal exists so "an alarm on it is what turns a
  # frozen game from a support ticket into a page". A deposit pending overnight
  # is a support ticket that should have been a page.
  #
  # ---------------------------------------------------------------------------
  # WHY A SEPARATE FUNCTION RATHER THAN A FIELD ON game_tick()
  # ---------------------------------------------------------------------------
  #
  # game_tick() runs ONCE A SECOND and is the game loop. Queue age does not
  # change meaningfully faster than a minute, and putting these queries there
  # would add work to the hottest path in the system to measure something that
  # moves 3600x slower. It would also couple "is the game running" to "is anyone
  # approving deposits", which are different failures with different responders.
  #
  # The ticker calls this on its own, slower schedule.
  #
  # THE QUERIES ARE CHEAP BY CONSTRUCTION. 006 and 007 each created a partial
  # index on their pending rows -- deposit_requests_pending and
  # withdrawal_requests_pending -- so both max() calls scan only what is
  # outstanding, which is the number an operator is expected to clear.
  #
  # ---------------------------------------------------------------------------
  # WHAT THIS IS NOT
  # ---------------------------------------------------------------------------
  #
  # It is NOT a notification that a claim arrived. Alarming a solo operator four
  # minutes after every deposit would page them through the night and teach them
  # to ignore the alarm, which is worse than having none. Per-claim notification
  # belongs to the Telegram bot, when the webhook route it needs is built --
  # services/functions/src/index.js records what that requires.
  #
  # This is the backstop underneath that: nobody is looking, or the queue is
  # stuck. The thresholds in modules/monitoring are set in hours for that reason
  # and are deliberately variables.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

CREATE OR REPLACE FUNCTION queue_health()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    -- Ages in MINUTES rather than seconds. The game loop's signal is in seconds
    -- because thirty of them is an outage; this one is measured against an
    -- operator's working day, and a metric in seconds would put the useful
    -- thresholds at four and five significant figures.
    'oldest_pending_deposit_minutes', coalesce((
      SELECT max(extract(epoch FROM (now() - created_at)) / 60)
        FROM deposit_requests WHERE status = 'pending'), 0)::integer,

    'oldest_pending_withdrawal_minutes', coalesce((
      SELECT max(extract(epoch FROM (now() - requested_at)) / 60)
        FROM withdrawal_requests WHERE status IN ('pending', 'processing')), 0)::integer,

    -- Counts alongside the ages, because they answer different questions. One
    -- old claim is somebody forgotten; forty recent ones is a queue that is not
    -- being worked at all, and the age alone would not say so.
    'pending_deposits', (
      SELECT count(*) FROM deposit_requests WHERE status = 'pending'),

    'pending_withdrawals', (
      SELECT count(*) FROM withdrawal_requests WHERE status IN ('pending', 'processing')),

    -- Money owed but not yet sent. Worth publishing because it is the operator's
    -- float requirement: if this exceeds what is in the house account, the queue
    -- cannot be cleared no matter how promptly somebody looks at it.
    'pending_withdrawal_total', coalesce((
      SELECT sum(amount) FROM withdrawal_requests
       WHERE status IN ('pending', 'processing')), 0)
  );
$$;

COMMENT ON FUNCTION queue_health IS
  'Age and size of the manual money queues, published by the ticker as CloudWatch metrics. Backstop for "nobody is looking", not a per-claim notification -- see db/20-post/015.';

-- ---------------------------------------------------------------------------
-- service_role only, for the reason db/20-post/004 established
--
-- It reveals how much money is outstanding and how long the operator has been
-- ignoring it. Neither is a player's business, and the counts alone would tell
-- an attacker how closely the queue is being watched.
-- ---------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION queue_health() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION queue_health() TO service_role;

DO $$
DECLARE
  v jsonb;
BEGIN
  IF has_function_privilege('anon', 'queue_health()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'queue_health()', 'EXECUTE') THEN
    RAISE EXCEPTION 'queue_health is callable by a client; it reports outstanding money and operator responsiveness.';
  END IF;

  -- Run it, rather than asserting it compiles. A STABLE sql function with a bad
  -- column reference is accepted at CREATE and fails at the first call -- which,
  -- for something only the ticker invokes, would be discovered from a gap in a
  -- CloudWatch graph rather than from an error anybody sees.
  SELECT queue_health() INTO v;

  IF NOT (v ? 'oldest_pending_deposit_minutes'
          AND v ? 'oldest_pending_withdrawal_minutes'
          AND v ? 'pending_deposits'
          AND v ? 'pending_withdrawals'
          AND v ? 'pending_withdrawal_total') THEN
    RAISE EXCEPTION 'queue_health() returned an unexpected shape: %. The ticker reads these keys by name.', v;
  END IF;

  RAISE NOTICE 'queue health: % pending deposit(s), oldest % min; % pending withdrawal(s), oldest % min',
    v ->> 'pending_deposits', v ->> 'oldest_pending_deposit_minutes',
    v ->> 'pending_withdrawals', v ->> 'oldest_pending_withdrawal_minutes';
END $$;
