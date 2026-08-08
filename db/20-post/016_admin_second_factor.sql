/*
  # A second factor on the ACTION, not on the login

  ## Why this exists

  An admin is a boolean on a row (db/20-post/005), proven by a Telegram-signed
  identity and a 15-minute JWT. That is one factor, and it guards the two most
  consequential operations in the system:

    approve_deposit_request()      credits a balance from nothing
    complete_bank_withdrawal()     records money as paid

  Whoever holds an open operator session can do both. Telegram accounts are
  taken over -- SIM swap, a borrowed unlocked phone, a session left open on a
  desktop the login widget now supports (f5a4372) -- and the whole point of this
  system is that it moves real money in a place where that money matters.

  ## Why on the action rather than the login

  Because a session left open otherwise credits freely.

  Putting the second factor at sign-in means it is presented once, fifteen
  minutes of session follow, and everything inside that window is single-factor
  again. The window is exactly when the damage happens. Requiring a code AT THE
  MOMENT of approval means possession of the phone is proven for each
  money-moving act, not once per session.

  It costs the operator six digits per approval. That is a real imposition on
  someone clearing an overnight queue, and it is the correct trade for the two
  operations that can invent or discharge money. Every other admin route --
  reading the queues, ending a game, changing a setting -- is untouched.

  ## What is stored, and what is deliberately not

  A base32 TOTP secret, in plaintext.

  That reads wrong and is right for this threat model. The threat is a stolen
  SESSION or a stolen TELEGRAM ACCOUNT, not a stolen database. Anyone reading
  this table already reads every player balance and could set is_admin on
  themselves -- at which point the TOTP secret is the least of it. Encrypting it
  with a key the same process holds would move the secret, not protect it, and
  would add a decrypt to the path of every approval.

  What that means honestly: this defends against session and account takeover.
  It does NOT defend against database compromise, and nothing at this layer can.

  ## Enrolment is one-way

  totp_secret is written once at enrolment and confirmed by presenting a code
  from it. There is deliberately no "reset my second factor" route: that would
  be a single-factor path to disabling the second factor, which is the same as
  not having one. Recovery is a human with database access, through the SSM
  tunnel -- the same bar as adding an admin in the first place.
*/

-- ---------------------------------------------------------------------------
-- 1. The columns
-- ---------------------------------------------------------------------------
ALTER TABLE telegram_users
  ADD COLUMN IF NOT EXISTS totp_secret text,
  ADD COLUMN IF NOT EXISTS totp_confirmed_at timestamptz;

COMMENT ON COLUMN telegram_users.totp_secret IS
  'Base32 TOTP secret (RFC 6238). Written once at enrolment. Plaintext on purpose: the threat is session/account takeover, not database compromise -- see db/20-post/016.';

COMMENT ON COLUMN telegram_users.totp_confirmed_at IS
  'Set when the admin first presents a valid code. Until then the secret exists but is not enforced, so a half-finished enrolment cannot lock somebody out of their own queue.';

-- ---------------------------------------------------------------------------
-- 2. Do not let the browser read the secret back
--
-- THE COLUMN IS EXPOSED BY POSTGREST THE MOMENT IT EXISTS.
--
-- telegram_users has a SELECT policy for `authenticated` (005), and PostgREST
-- serves every column a role may read. Adding totp_secret therefore publishes
-- it at /rest/v1/telegram_users?select=totp_secret to any player whose row it
-- is -- and an attacker with a stolen session is exactly the person whose row
-- it is. They would read the secret and generate their own codes.
--
-- That is the same shape as the bot token that sat readable in `settings` until
-- db/20-post/003 redacted it: a secret that became public simply by being
-- stored next to things that were.
--
-- Column-level REVOKE is the fix. RLS decides which ROWS; column privileges
-- decide which COLUMNS, and only the latter can express "not this one, ever".
-- ---------------------------------------------------------------------------
REVOKE SELECT (totp_secret) ON telegram_users FROM anon, authenticated;

-- service_role keeps it: the functions service is what verifies codes.
GRANT SELECT (totp_secret) ON telegram_users TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Prove the revoke actually took
--
-- Same reasoning db/20-post/004 gives about statements that report success and
-- change nothing. A REVOKE that silently did not apply leaves the secret
-- readable while this file claims otherwise, and nothing would say so.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF has_column_privilege('authenticated', 'telegram_users', 'totp_secret', 'SELECT') THEN
    RAISE EXCEPTION 'totp_secret is still readable by authenticated; a stolen session could read the second factor and generate its own codes.';
  END IF;

  IF has_column_privilege('anon', 'telegram_users', 'totp_secret', 'SELECT') THEN
    RAISE EXCEPTION 'totp_secret is readable by anon.';
  END IF;

  RAISE NOTICE 'totp_secret is not readable by anon or authenticated.';
END $$;
