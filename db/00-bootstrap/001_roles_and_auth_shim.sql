/*
  # RDS bootstrap: Supabase compatibility layer
  #
  # Runs BEFORE the 128 Supabase migrations. Without it every one of them fails,
  # because Supabase provisions a lot implicitly that stock PostgreSQL does not.
  #
  # An audit of the migration set found the dependency surface is small:
  #
  #   auth.uid()                   9 call sites, in RLS policies
  #   anon / authenticated /
  #     service_role               roles named by 47 RLS policies
  #   pg_cron                      1 CREATE EXTENSION
  #   supabase_realtime            2 ALTER PUBLICATION
  #
  # gen_random_uuid() is used in 11 files but is native to PostgreSQL 13+, so no
  # pgcrypto is required. No crypt/digest/hmac usage exists.
  #
  # IDEMPOTENT: safe to re-run. Roles are cluster-wide, so every CREATE ROLE is
  # guarded.
  #
  # Requires :authenticator_password to be supplied by the migration runner:
  #   psql -v authenticator_password="$(...)" -f this_file.sql
*/

-- ---------------------------------------------------------------------------
-- 1. Roles
--
-- PostgREST connects as `authenticator`, which is deliberately near-powerless,
-- then SET ROLEs to anon or authenticated based on the JWT. That indirection is
-- what makes a leaked connection string far less damaging than a leaked
-- superuser credential.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;

  -- BYPASSRLS mirrors Supabase's service_role. Only privileged server-side code
  -- ever assumes it; it is never reachable from a client JWT.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    EXECUTE format(
      'CREATE ROLE authenticator LOGIN NOINHERIT PASSWORD %L',
      :'authenticator_password'
    );
  ELSE
    EXECUTE format(
      'ALTER ROLE authenticator WITH LOGIN NOINHERIT PASSWORD %L',
      :'authenticator_password'
    );
  END IF;
END $$;

GRANT anon, authenticated, service_role TO authenticator;

-- ---------------------------------------------------------------------------
-- 2. auth schema shim
--
-- PostgREST puts the verified JWT payload into the `request.jwt.claims` GUC for
-- the duration of each request. These functions read it, which is exactly how
-- Supabase implements them — so the 9 RLS policies referencing auth.uid() work
-- unchanged against self-hosted PostgREST.
--
-- The `true` second argument to current_setting suppresses the error when the
-- GUC is unset (background jobs, psql sessions), returning NULL instead. RLS
-- policies then simply match nothing, which is the correct failure direction.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS auth;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

-- Returns the subject claim as uuid. Call sites compare it against
-- telegram_users.id, which is uuid, so the cast is required.
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(
    current_setting('request.jwt.claims', true)::jsonb ->> 'sub',
    ''
  )::uuid
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(
    current_setting('request.jwt.claims', true)::jsonb ->> 'role',
    ''
  )::text
$$;

CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    nullif(current_setting('request.jwt.claims', true), ''),
    '{}'
  )::jsonb
$$;

-- ---------------------------------------------------------------------------
-- 3. Extensions
--
-- pg_cron must be created in the database named by the cron.database_name
-- parameter, which Terraform sets to this database. Creating it elsewhere
-- appears to succeed and then never runs anything.
--
-- NOTE: pg_cron on RDS has ONE-MINUTE granularity. The 4-second game loop that
-- Supabase ran here is NOT portable and is deliberately not recreated; see
-- db/20-post. The ticker container owns that job now.
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ---------------------------------------------------------------------------
-- 4. Realtime publication
--
-- Two migrations run `ALTER PUBLICATION supabase_realtime ADD TABLE ...`, which
-- fails outright if the publication does not already exist. Supabase creates it
-- for you; here we must.
--
-- Created empty. The migrations add `games` and `players` themselves.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5. Schema privileges and default grants
--
-- RLS decides WHICH ROWS a role may touch, but only after table-level
-- privileges let it touch the table at all. Supabase sets these defaults behind
-- the scenes; their absence presents as "permission denied for table games"
-- from PostgREST even though the RLS policies look correct.
--
-- ALTER DEFAULT PRIVILEGES applies to objects created later by the migration
-- runner's role, which is why this must run BEFORE the 128 migrations.
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO anon;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
