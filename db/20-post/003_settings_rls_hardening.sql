/*
  # Settings table: deny-by-default read access, and redact secrets
  #
  # FOUND IN PRODUCTION-SHAPED TESTING, not in review:
  #
  #   curl https://api.<domain>/rest/v1/settings
  #
  # returned every row to an ANONYMOUS caller, including a live
  # telegram_bot_token and sms_api_key. The cause is in
  # 20251213115718_add_settings_table.sql:
  #
  #   CREATE POLICY "Anyone can view settings" ON settings
  #     FOR SELECT TO public USING (true);
  #
  # That policy is fine for a table of display strings and became dangerous the
  # moment secrets were stored beside them.
  #
  # WHY THE BOT TOKEN IS THE WORST OF THESE: it is not merely "send messages as
  # the bot". It is the HMAC key Telegram Mini Apps use to sign initData.
  # Anyone holding it can forge a valid initData payload for ANY telegram user
  # id -- i.e. authenticate as any player and act on their balance through the
  # application's own logic. It is closer to a signing key than to an API key.
  #
  # Two changes here:
  #   1. Replace the blanket policy with an explicit ALLOWLIST. Deny by default,
  #      so a secret added to this table in future is not exposed by omission.
  #   2. Redact secret-bearing rows. On AWS these values come from SSM Parameter
  #      Store, injected as environment variables at container start; the
  #      database is the wrong place for them entirely.
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

-- ---------------------------------------------------------------------------
-- 1. Deny-by-default read policy
--
-- Drops every existing SELECT policy by ENUMERATION rather than by name.
--
-- The first attempt at this migration hardcoded DROP POLICY "Anyone can view
-- settings". The actual policy is "Anyone can read settings" -- view vs read.
-- DROP POLICY IF EXISTS on a wrong name is a SILENT no-op, and because
-- PostgreSQL ORs permissive policies together, the original USING (true)
-- survived and the secrets stayed readable. The migration reported success.
--
-- Enumerating pg_policies removes the guess entirely, and keeps working if
-- someone adds another permissive policy later.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_policy record;
BEGIN
  FOR v_policy IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'settings'
      AND cmd IN ('SELECT', 'ALL')
      -- Leave the service_role policy alone: privileged server-side code needs it.
      AND policyname <> 'Service role can manage settings'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON settings', v_policy.policyname);
    RAISE NOTICE 'Dropped policy % on settings', v_policy.policyname;
  END LOOP;
END $$;

CREATE POLICY "Public can read non-secret settings"
  ON settings
  FOR SELECT
  TO public
  USING (
    id IN (
      -- Chain and contract configuration the SPA legitimately needs.
      -- WalletDepositModal.tsx:116 and BnbWithdrawalModal.tsx:219 read the
      -- contract address, so removing it would break deposits.
      'deposit_contract_address',
      'deposit_contract_chain_id',
      'deposit_conversion_rate',
      'deposit_minimum_bnb',
      'deposit_required_confirmations',
      'withdrawal_contract_address',
      'withdrawal_credits_to_bnb_rate',
      'withdrawal_min_bnb',
      'withdrawal_max_daily_bnb',
      'withdrawal_max_weekly_bnb',
      'commission_rate',
      -- Presentation.
      'telegram_bot_username',
      'support_contact',
      'user_instructions',
      'game_url'
    )
  );

-- Deliberately NOT in the allowlist, and each for a specific reason:
--
--   telegram_bot_token   HMAC key for Mini App initData -- forges any identity
--   sms_api_key          authenticates the bank-SMS deposit pipeline
--   deposit_bsc_rpc_url  an attacker-controlled RPC can lie about deposits
--   *_private_key        custody. These must never exist in this table at all
--   withdrawal_low_balance_threshold   operational signal, no reason to publish

-- ---------------------------------------------------------------------------
-- 2. Redact secrets that live here for historical reasons
--
-- On AWS these arrive from SSM as environment variables. Leaving a real value
-- in the table means a future policy mistake re-exposes it, and it is one more
-- place to remember during rotation.
--
-- Set to the empty string rather than deleted, so any code still reading the
-- row gets a falsy value it can detect instead of a null-reference surprise.
-- ---------------------------------------------------------------------------
UPDATE settings
SET value = '',
    updated_at = now()
WHERE id IN (
  'telegram_bot_token',
  'deposit_contract_private_key',
  'withdrawal_contract_private_key'
)
AND value <> '';

-- ---------------------------------------------------------------------------
-- 3. Assert the fix actually holds, BY EXECUTING IT AS anon
--
-- The previous version of this check compared two hardcoded lists, which is
-- worthless: it verified that a string I wrote was absent from another string I
-- wrote, and passed cheerfully while the real policy still exposed everything.
--
-- This one SET ROLE anon and queries the table. It is the same code path an
-- anonymous HTTP request takes through PostgREST, so it cannot pass while the
-- data is reachable. A static assertion about a security control is not a test
-- of that control.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_visible text;
BEGIN
  SET LOCAL ROLE anon;

  SELECT string_agg(id, ', ')
  INTO v_visible
  FROM settings
  WHERE id IN (
    'telegram_bot_token', 'sms_api_key', 'deposit_bsc_rpc_url',
    'deposit_contract_private_key', 'withdrawal_contract_private_key'
  );

  RESET ROLE;

  IF v_visible IS NOT NULL THEN
    RAISE EXCEPTION
      'anon can still read secret settings: %. RLS is NOT protecting this table.',
      v_visible;
  END IF;

  RAISE NOTICE 'Verified as anon: no secret settings are readable';
END $$;

-- Same technique for the rest of the sensitive tables, so a permissive policy
-- anywhere else fails the migration instead of being found by probing the live
-- endpoint -- which is how the settings exposure was actually discovered.
DO $$
DECLARE
  v_count bigint;
BEGIN
  SET LOCAL ROLE anon;

  SELECT count(*) INTO v_count FROM telegram_users;
  IF v_count > 0 THEN
    RESET ROLE;
    RAISE EXCEPTION 'anon can read % rows from telegram_users (balances).', v_count;
  END IF;

  RESET ROLE;
  RAISE NOTICE 'Verified as anon: telegram_users is not readable';
END $$;

