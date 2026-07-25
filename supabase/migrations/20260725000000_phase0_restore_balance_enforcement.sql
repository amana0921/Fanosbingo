/*
  # Phase 0 — Restore Balance Enforcement (PRE-MAINNET BLOCKER)

  1. Problem
    Two migrations disabled balance enforcement for testnet convenience:
      - 20260214120304_..._remove_balance_checks_for_testnet.sql removed the
        insufficient-balance check from `select_card_atomic`.
      - 20260216113940_fix_select_card_atomic_ambiguous_overload.sql changed
        `deduct_stake_from_balance` to silently `RETURN NEW` when the user
        cannot afford the stake, instead of rejecting the join.

    Combined effect: a user with zero balance can join games for free and win
    real credits into `won_balance`, which is withdrawable to BNB. This must be
    reverted before any mainnet traffic.

  2. Changes
    - `select_card_atomic`: reject with error_code 'INSUFFICIENT_BALANCE' before
      inserting the player. The edge function (select-card/index.ts:95) and the
      client (Lobby.tsx:591) already handle this code, so no app change is needed.
    - `deduct_stake_from_balance`: RAISE EXCEPTION instead of silently skipping,
      and take a row lock (`FOR UPDATE`) before the read-modify-write. This is
      defense-in-depth: any insert path into `players` that bypasses
      `select_card_atomic` is now also covered.
    - Non-negative CHECK constraints on balance columns as a final backstop.
      Added NOT VALID so legacy rows do not block the migration; new writes are
      enforced immediately. Validate separately after reconciling any bad rows.
    - Partial UNIQUE index on `bnb_withdrawal_requests.transaction_hash` so a
      replayed on-chain withdrawal cannot be recorded twice.
      (`deposit_transactions.transaction_hash` already has UNIQUE NOT NULL.)

  3. Race condition fixed
    `deduct_stake_from_balance` previously read balances with a bare
    `SELECT ... INTO` and then UPDATEd. Two concurrent joins by the same user
    could both read the pre-deduction balance and both pass the affordability
    check. `select_card_atomic` happened to shield this by locking the user row
    first, but the trigger fires on any `players` INSERT. Now it locks its own row.
*/

-- ---------------------------------------------------------------------------
-- 1. select_card_atomic — restore the affordability check
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION select_card_atomic(
  p_game_id uuid,
  p_card_number integer,
  p_telegram_user_id bigint,
  p_player_name text,
  p_card jsonb DEFAULT NULL,
  p_card_numbers jsonb DEFAULT NULL,
  p_marked_cells jsonb DEFAULT NULL,
  p_telegram_username text DEFAULT NULL,
  p_telegram_first_name text DEFAULT NULL,
  p_telegram_last_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_game RECORD;
  v_user RECORD;
  v_existing_player uuid;
  v_current_time timestamptz;
  v_player_id uuid;
  v_total_available integer;
BEGIN
  v_current_time := now();

  SELECT id, status, stake_amount, selection_closed_at, starts_at, allow_late_joins
  INTO v_game
  FROM games
  WHERE id = p_game_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Game not found',
      'error_code', 'GAME_NOT_FOUND'
    );
  END IF;

  IF v_game.status != 'waiting' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Game is no longer accepting players',
      'error_code', 'GAME_NOT_WAITING'
    );
  END IF;

  IF v_game.allow_late_joins THEN
    IF v_current_time > v_game.selection_closed_at + interval '2 seconds' THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Selection window has closed',
        'error_code', 'SELECTION_CLOSED',
        'closed_at', v_game.selection_closed_at,
        'current_time', v_current_time
      );
    END IF;
  ELSE
    IF v_current_time > v_game.selection_closed_at THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Selection window has closed',
        'error_code', 'SELECTION_CLOSED',
        'closed_at', v_game.selection_closed_at,
        'current_time', v_current_time
      );
    END IF;
  END IF;

  SELECT id INTO v_existing_player
  FROM players
  WHERE game_id = p_game_id
  AND selected_number = p_card_number
  FOR UPDATE SKIP LOCKED;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Card number already taken',
      'error_code', 'CARD_TAKEN'
    );
  END IF;

  SELECT deposited_balance, won_balance
  INTO v_user
  FROM telegram_users
  WHERE telegram_user_id = p_telegram_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'User not found',
      'error_code', 'USER_NOT_FOUND'
    );
  END IF;

  -- RESTORED: reject the join when the player cannot cover the stake.
  v_total_available := COALESCE(v_user.deposited_balance, 0) + COALESCE(v_user.won_balance, 0);

  IF v_total_available < v_game.stake_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Insufficient balance to join this game',
      'error_code', 'INSUFFICIENT_BALANCE',
      'required', v_game.stake_amount,
      'available', v_total_available
    );
  END IF;

  INSERT INTO players (
    game_id,
    name,
    card,
    card_numbers,
    marked_cells,
    selected_number,
    telegram_user_id,
    telegram_username,
    telegram_first_name,
    telegram_last_name
  ) VALUES (
    p_game_id,
    p_player_name,
    p_card,
    p_card_numbers,
    p_marked_cells,
    p_card_number,
    p_telegram_user_id,
    p_telegram_username,
    p_telegram_first_name,
    p_telegram_last_name
  )
  RETURNING id INTO v_player_id;

  RETURN jsonb_build_object(
    'success', true,
    'player_id', v_player_id,
    'card_number', p_card_number,
    'selection_closed_at', v_game.selection_closed_at,
    'starts_at', v_game.starts_at
  );

EXCEPTION
  -- Surface the trigger's affordability rejection as a clean error code rather
  -- than a generic INTERNAL_ERROR, in case the pre-check above is ever bypassed.
  WHEN check_violation THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM,
      'error_code', 'INSUFFICIENT_BALANCE'
    );
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM,
      'error_code', 'INTERNAL_ERROR'
    );
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. deduct_stake_from_balance — reject instead of silently skipping, and lock
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION deduct_stake_from_balance()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  stake_amount_val integer;
  user_deposited integer;
  user_won integer;
  total_available integer;
  deduct_from_deposited integer;
  deduct_from_won integer;
BEGIN
  SELECT stake_amount INTO stake_amount_val
  FROM games
  WHERE id = NEW.game_id;

  IF stake_amount_val IS NULL THEN
    RAISE EXCEPTION 'Game not found';
  END IF;

  -- FOR UPDATE: without this, two concurrent joins by the same user both read
  -- the pre-deduction balance and both pass the affordability check below.
  SELECT COALESCE(deposited_balance, 0), COALESCE(won_balance, 0)
  INTO user_deposited, user_won
  FROM telegram_users
  WHERE telegram_user_id = NEW.telegram_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User % not found', NEW.telegram_user_id;
  END IF;

  total_available := user_deposited + user_won;

  -- RESTORED: previously `RETURN NEW`, which let the player join without paying.
  IF total_available < stake_amount_val THEN
    RAISE EXCEPTION 'INSUFFICIENT_BALANCE: stake % exceeds available balance %',
      stake_amount_val, total_available
      USING ERRCODE = 'check_violation';
  END IF;

  IF user_deposited >= stake_amount_val THEN
    deduct_from_deposited := stake_amount_val;
    deduct_from_won := 0;
  ELSE
    deduct_from_deposited := user_deposited;
    deduct_from_won := stake_amount_val - user_deposited;
  END IF;

  UPDATE telegram_users
  SET
    deposited_balance = deposited_balance - deduct_from_deposited,
    won_balance = won_balance - deduct_from_won,
    balance = balance - stake_amount_val,
    total_spent = total_spent + stake_amount_val
  WHERE telegram_user_id = NEW.telegram_user_id;

  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3. Non-negative balance backstop (NOT VALID: enforced on new writes only)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'telegram_users_balances_non_negative'
  ) THEN
    ALTER TABLE telegram_users
      ADD CONSTRAINT telegram_users_balances_non_negative
      CHECK (
        COALESCE(deposited_balance, 0) >= 0
        AND COALESCE(won_balance, 0) >= 0
      ) NOT VALID;
  END IF;
END $$;

-- After reconciling any pre-existing negative rows, run:
--   ALTER TABLE telegram_users VALIDATE CONSTRAINT telegram_users_balances_non_negative;
-- Find them with:
--   SELECT telegram_user_id, deposited_balance, won_balance FROM telegram_users
--   WHERE deposited_balance < 0 OR won_balance < 0;

-- ---------------------------------------------------------------------------
-- 4. Prevent duplicate withdrawal records for the same on-chain transaction
-- ---------------------------------------------------------------------------
-- record_user_withdrawal (20260216090101) guards duplicates with a
-- non-transactional SELECT-then-INSERT in record-withdrawal/index.ts:58-77.
-- This index makes the guard structural. Partial, because admin-created
-- requests legitimately have a NULL hash until they are broadcast.
CREATE UNIQUE INDEX IF NOT EXISTS idx_bnb_withdrawal_requests_tx_hash_unique
  ON bnb_withdrawal_requests (transaction_hash)
  WHERE transaction_hash IS NOT NULL;
