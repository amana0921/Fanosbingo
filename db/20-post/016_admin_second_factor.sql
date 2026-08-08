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

  ## A SEPARATE TABLE, and the first attempt is why

  The obvious design is a `totp_secret` column on telegram_users. That was
  written, and it was wrong, and the assertion at the bottom of this file caught
  it before it reached a database:

    ERROR: totp_secret is still readable by authenticated;
           a stolen session could read the second factor

  telegram_users carries a TABLE-LEVEL `GRANT SELECT` to `authenticated`, from
  the ALTER DEFAULT PRIVILEGES in db/00-bootstrap. A column-level REVOKE does not
  override a table-level grant -- the table grant already implies every column,
  including ones added later. Removing it would mean revoking SELECT on the whole
  table and re-granting every column except this one, which then breaks silently
  the next time somebody adds a column and forgets to grant it.

  PostgREST serves every column a role may read, so the failure mode was
  specific and severe: /rest/v1/telegram_users?select=totp_secret would have
  returned the secret to the owner of that row -- who is precisely the attacker
  holding a stolen session. They would read it and generate their own codes.
  Exactly the shape of the bot token that sat readable in `settings` until
  db/20-post/003.

  A separate table with RLS enabled and NO policy for anon or authenticated is
  simply invisible to them: PostgREST returns an empty result, not a filtered
  one. service_role reaches it through BYPASSRLS. Nothing to enumerate, nothing
  to keep in step, and adding a column to telegram_users stays a normal thing to
  do.

  ## What is stored, and what is deliberately not

  A base32 TOTP secret, in plaintext.

  That reads wrong and is right for this threat model. The threat is a stolen
  SESSION or a stolen TELEGRAM ACCOUNT, not a stolen database. Anyone reading
  this table already reads every player balance and could set is_admin on
  themselves -- at which point the TOTP secret is the least of it. Encrypting it
  with a key the same process holds would move the secret, not protect it.

  Stated honestly: this defends against session and account takeover. It does
  NOT defend against database compromise, and nothing at this layer can.

  ## Enrolment is one-way

  The secret is written once and confirmed by presenting a code from it. There
  is deliberately no "reset my second factor" route: that would be a
  single-factor path to disabling the second factor, which is the same as not
  having one. Recovery is a human with database access through the SSM tunnel --
  the same bar as adding an admin in the first place.
*/

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS admin_totp (
  user_id      uuid PRIMARY KEY REFERENCES telegram_users (id) ON DELETE CASCADE,
  secret       text        NOT NULL,
  confirmed_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE admin_totp IS
  'TOTP secrets for admin second factor. SEPARATE from telegram_users on purpose: that table grants SELECT to `authenticated` at table level, and PostgREST would serve the secret to the owner of the row. See db/20-post/016.';

COMMENT ON COLUMN admin_totp.secret IS
  'Base32 TOTP secret (RFC 6238). Plaintext on purpose: the threat is session/account takeover, not database compromise.';

COMMENT ON COLUMN admin_totp.confirmed_at IS
  'Set when the admin first presents a valid code. Until then the secret exists but is NOT enforced, so a half-finished enrolment cannot lock somebody out of their own queue.';

-- ---------------------------------------------------------------------------
-- 2. Invisible to the browser
--
-- RLS on with NO policy for anon or authenticated. That is not a restrictive
-- policy -- it is the ABSENCE of any permissive one, which under RLS means no
-- row is visible at all. PostgREST returns [] rather than a filtered result.
--
-- No GRANT to anon/authenticated either, so the table is refused before RLS is
-- even consulted. Both, because ALTER DEFAULT PRIVILEGES in db/00-bootstrap
-- grants on tables created LATER by the migration runner -- which includes this
-- one -- so the grant has to be revoked explicitly rather than assumed absent.
-- ---------------------------------------------------------------------------
ALTER TABLE admin_totp ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON admin_totp FROM anon, authenticated, PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON admin_totp TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Prove it, rather than asserting it in a comment
--
-- Same reasoning db/20-post/004 gives about statements that report success and
-- change nothing -- and the reason this file exists in its current shape at all:
-- the first version of this migration DID fail here, which is what surfaced the
-- table-level grant. An assertion that has already caught something once is
-- worth keeping.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF has_table_privilege('authenticated', 'admin_totp', 'SELECT') THEN
    RAISE EXCEPTION 'admin_totp is readable by authenticated; a stolen session could read the second factor and generate its own codes.';
  END IF;

  IF has_table_privilege('anon', 'admin_totp', 'SELECT') THEN
    RAISE EXCEPTION 'admin_totp is readable by anon.';
  END IF;

  IF NOT has_table_privilege('service_role', 'admin_totp', 'SELECT') THEN
    RAISE EXCEPTION 'service_role cannot read admin_totp; the functions service could not verify a code.';
  END IF;

  RAISE NOTICE 'admin_totp: invisible to anon and authenticated, readable by service_role.';
END $$;
