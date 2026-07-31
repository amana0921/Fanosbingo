/*
  # A production-shaped schema, small enough to build in CI in a second.
  #
  # WHY THIS EXISTS. Nothing in CI executed migration SQL. `db-migrate.yml`'s
  # pull-request job runs `db-migrate.sh --dry-run`, which prints filenames and
  # `continue`s -- it never runs them -- and the `migrations` job in test.yml is a
  # static check over CREATE/DROP statements. Both reported success on a pull
  # request adding two migrations without executing either.
  #
  # So a syntax error, an unsatisfiable constraint or a failing assertion would
  # have merged green. The only thing standing between that and production was
  # somebody remembering to run psql by hand.
  #
  # WHY A FIXTURE RATHER THAN REPLAYING ALL 110 MIGRATIONS.
  #
  # db/00-bootstrap/001 asserts `wal_level = logical` and pg_cron in
  # shared_preload_libraries -- correctly, because Realtime silently delivers
  # nothing without the first and the game loop was moved off pg_cron because of
  # the second. Neither is available in a stock `postgres:16` service container,
  # so a full replay needs a custom image before it needs anything else.
  #
  # This builds the objects `db/20-post/003` onwards actually touch, which is
  # where every security decision in this repository lives. It is not a
  # substitute for the migration run against dev; it is the check that catches the
  # class of mistake that has actually happened here -- a migration that does not
  # apply, or an assertion that does not hold.
  #
  # IF IT DRIFTS FROM PRODUCTION, THE JOB FAILS. That is the right direction: a
  # missing column here is a loud CI failure rather than a quiet gap in coverage.
*/

-- Roles, as db/00-bootstrap/001 creates them.
CREATE ROLE anon NOLOGIN NOINHERIT;
CREATE ROLE authenticated NOLOGIN NOINHERIT;
CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
CREATE ROLE authenticator LOGIN NOINHERIT PASSWORD 'fixture';
CREATE ROLE app_service LOGIN INHERIT PASSWORD 'fixture';
GRANT anon, authenticated, service_role TO authenticator;
GRANT service_role TO app_service;

CREATE SCHEMA IF NOT EXISTS auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid
$$;
CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '')::text
$$;
GRANT EXECUTE ON FUNCTION auth.uid(), auth.role() TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE telegram_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  telegram_user_id bigint UNIQUE,
  telegram_username text,
  telegram_first_name text,
  telegram_last_name text,
  balance integer DEFAULT 0,
  deposited_balance integer DEFAULT 0,
  won_balance integer DEFAULT 0,
  total_deposited integer DEFAULT 0,
  total_spent integer DEFAULT 0,
  total_won integer DEFAULT 0,
  referral_code text,
  total_referrals integer DEFAULT 0,
  wallet_address text UNIQUE,
  last_active_at timestamptz DEFAULT now(),
  created_at timestamptz DEFAULT now()
);
ALTER TABLE telegram_users ENABLE ROW LEVEL SECURITY;

-- The permissive policies db/20-post/004 exists to remove. Present so the
-- migration is exercised against the state it was written for rather than
-- against an already-clean database, where its DROP loop would be a no-op.
CREATE POLICY "Anon users can read telegram_users for lobby"
  ON telegram_users FOR SELECT TO anon, public USING (true);
CREATE POLICY "Service role can manage telegram users"
  ON telegram_users FOR ALL TO service_role USING (true) WITH CHECK (true);

-- `balance` is maintained by a trigger, so nothing may write it directly.
CREATE OR REPLACE FUNCTION sync_total_balance() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.balance := COALESCE(NEW.deposited_balance,0) + COALESCE(NEW.won_balance,0); RETURN NEW; END $$;
CREATE TRIGGER sync_balance_on_change BEFORE INSERT OR UPDATE ON telegram_users
  FOR EACH ROW EXECUTE FUNCTION sync_total_balance();

CREATE TABLE settings (
  id text PRIMARY KEY,
  value text,
  description text,
  updated_at timestamptz DEFAULT now(),
  updated_by text
);
ALTER TABLE settings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read settings" ON settings FOR SELECT TO public USING (true);
CREATE POLICY "Service role can manage settings" ON settings FOR ALL TO service_role USING (true) WITH CHECK (true);
INSERT INTO settings (id, value) VALUES
  ('telegram_bot_token', 'a-secret-that-must-be-redacted'),
  ('sms_api_key', 'another-secret'),
  ('commission_rate', '20'),
  ('deposit_contract_address', ''),
  ('deposit_contract_chain_id', '97');

CREATE TABLE games (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  game_number integer, status text, total_pot integer, stake_amount integer DEFAULT 10,
  winner_prize integer, called_numbers integer[] DEFAULT '{}',
  starts_at timestamptz DEFAULT now(), created_at timestamptz DEFAULT now()
);
ALTER TABLE games ENABLE ROW LEVEL SECURITY;
CREATE POLICY g_read ON games FOR SELECT TO anon, authenticated USING (true);

CREATE TABLE players (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id uuid REFERENCES games(id) ON DELETE CASCADE,
  selected_number integer, name text, telegram_user_id bigint,
  card_numbers jsonb, marked_cells jsonb, is_disqualified boolean DEFAULT false
);
ALTER TABLE players ENABLE ROW LEVEL SECURITY;

CREATE TABLE bank_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bank_name text NOT NULL, account_number text NOT NULL, account_name text,
  instructions text NOT NULL, is_active boolean DEFAULT true, display_order integer DEFAULT 0,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now()
);

CREATE TABLE card_layouts (
  card_number integer PRIMARY KEY,
  layout jsonb NOT NULL
);

-- ---------------------------------------------------------------------------
-- Functions 20-post grants, revokes or replaces. Bodies are stubs except where
-- a migration replaces them wholesale.
-- ---------------------------------------------------------------------------
CREATE FUNCTION transfer_balance(from_telegram_id bigint, transfer_amount integer, to_telegram_id bigint, balance_type_param text DEFAULT 'won')
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION process_bnb_withdrawal_request(p_telegram_user_id bigint, p_wallet_address text, p_amount_bnb numeric, p_signature text, p_nonce text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION record_user_withdrawal(p_telegram_user_id bigint, p_wallet_address text, p_amount_bnb numeric, p_transaction_hash text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION select_card_atomic(p_game_id uuid, p_card_number integer, p_telegram_user_id bigint, p_player_name text,
  p_card jsonb DEFAULT NULL, p_card_numbers jsonb DEFAULT NULL, p_marked_cells jsonb DEFAULT NULL,
  p_telegram_username text DEFAULT NULL, p_telegram_first_name text DEFAULT NULL, p_telegram_last_name text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;
CREATE FUNCTION atomic_claim_bingo(p_player_id uuid, p_claim_window_ms integer DEFAULT 1000)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;
CREATE FUNCTION handle_referral_bonus(new_user_telegram_id bigint, referrer_code text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION check_bnb_withdrawal_limits(p_telegram_user_id bigint, p_amount_bnb numeric)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION payout_winners(p_game_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN END $$;
CREATE FUNCTION get_server_timestamp_ms() RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT 0::bigint $$;
CREATE FUNCTION get_or_create_wallet_user(p_wallet_address text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;
CREATE FUNCTION get_or_create_card_layout(p_card_number integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;
CREATE FUNCTION get_all_card_layouts()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;
CREATE FUNCTION get_card_layouts_batch(p_card_numbers integer[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;
CREATE FUNCTION create_game_with_server_time()
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION get_bnb_withdrawal_stats()
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION game_tick(p_call_interval_ms integer DEFAULT 3500, p_claim_window_ms integer DEFAULT 1000, p_countdown_seconds integer DEFAULT 25)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::jsonb; END $$;

-- The stale one-argument overload db/20-post/004 drops. Present so that DROP is
-- exercised rather than skipped.
CREATE FUNCTION get_lobby_data_instant(user_telegram_id bigint DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;
CREATE FUNCTION get_lobby_data_instant(user_telegram_id bigint DEFAULT NULL, user_wallet_address text DEFAULT NULL)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$ BEGIN RETURN '{}'::json; END $$;

-- The blanket grants db/20-post/001 used to issue, which 004 replaces with an
-- allowlist. Present so the revoke has something to revoke.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated, service_role;

-- Real rows, so no assertion can pass merely because a table is empty -- which is
-- exactly how the vacuous check in the original 003 passed while balances were
-- readable.
INSERT INTO telegram_users (telegram_user_id, telegram_username, deposited_balance, won_balance)
VALUES (424946351, 'victim', 5000, 5000), (999000111, 'attacker', 0, 0);
INSERT INTO games (game_number, status) VALUES (1, 'waiting');
INSERT INTO bank_options (bank_name, account_number, instructions) VALUES ('Telebirr', '0900000000', 'test');
