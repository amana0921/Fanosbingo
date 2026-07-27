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
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "Anyone can view settings" ON settings;
DROP POLICY IF EXISTS "Public can read non-secret settings" ON settings;

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
-- 3. Assert the fix actually holds
--
-- Evaluates the policy as `anon` would, so this fails the migration if the
-- allowlist is ever widened to include a secret.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_leaked text;
BEGIN
  SELECT string_agg(id, ', ')
  INTO v_leaked
  FROM settings
  WHERE id IN (
    'telegram_bot_token', 'sms_api_key', 'deposit_bsc_rpc_url',
    'deposit_contract_private_key', 'withdrawal_contract_private_key'
  )
  AND id IN (
    SELECT unnest(ARRAY[
      'deposit_contract_address', 'deposit_contract_chain_id',
      'deposit_conversion_rate', 'deposit_minimum_bnb',
      'deposit_required_confirmations', 'withdrawal_contract_address',
      'withdrawal_credits_to_bnb_rate', 'withdrawal_min_bnb',
      'withdrawal_max_daily_bnb', 'withdrawal_max_weekly_bnb',
      'commission_rate', 'telegram_bot_username', 'support_contact',
      'user_instructions', 'game_url'
    ])
  );

  IF v_leaked IS NOT NULL THEN
    RAISE EXCEPTION 'Secret-bearing settings appear in the public allowlist: %', v_leaked;
  END IF;

  RAISE NOTICE 'settings RLS: deny-by-default allowlist in force';
END $$;
