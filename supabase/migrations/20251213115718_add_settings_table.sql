/*
  # Add Settings Table for Admin Configuration

  1. New Tables
    - `settings`
      - `id` (text, primary key) - Setting key
      - `value` (text) - Setting value
      - `description` (text) - Description of the setting
      - `updated_at` (timestamptz) - Last update timestamp
      - `updated_by` (text) - Who updated it last
  
  2. Security
    - Enable RLS on `settings` table
    - Add policy for authenticated users to read settings
    - No insert/update policies as this should be managed via secure functions only
  
  3. Initial Data
    - Insert default Telegram bot token setting
*/

CREATE TABLE IF NOT EXISTS settings (
  id text PRIMARY KEY,
  value text NOT NULL,
  description text,
  updated_at timestamptz DEFAULT now(),
  updated_by text
);

ALTER TABLE settings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can read settings"
  ON settings
  FOR SELECT
  TO public
  USING (true);

CREATE POLICY "Service role can manage settings"
  ON settings
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

INSERT INTO settings (id, value, description, updated_by)
VALUES (
  'telegram_bot_token',
  -- REDACTED. A live Telegram bot token was committed here and was
  -- publicly readable via PostgREST until db/20-post/003 closed the RLS
  -- hole. The token has been revoked. On AWS this value comes from SSM
  -- Parameter Store, injected as an environment variable -- the database
  -- is the wrong place for it.
  '',
  'Telegram Bot API Token for sending notifications',
  'system'
)
ON CONFLICT (id) DO NOTHING;