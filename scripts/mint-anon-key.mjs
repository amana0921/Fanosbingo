/**
 * Mint the anonymous API key.
 *
 * WHAT IT IS
 *
 * A JWT carrying `role: anon`, signed with the same secret PostgREST verifies
 * with (`/<env>/app/jwt_secret`). It is the direct equivalent of Supabase's anon
 * key, and it works the same way: PostgREST reads the role from the token and
 * RLS decides what that role may see.
 *
 * IT IS PUBLIC, AND THAT IS FINE
 *
 * It ships inside the compiled bundle — every VITE_ variable does — so treat it
 * as published the moment it is built. It is not a secret and it is not a
 * password. Its authority is exactly "whatever the RLS policies grant to anon",
 * which for this schema is the settings whitelist and public game state.
 *
 * What it is NOT is a way to read player data. That requires a token from
 * /functions/v1/auth/telegram, which requires a signature from Telegram.
 *
 * NO EXPIRY, DELIBERATELY
 *
 * An expiring anon key would break every published build on a schedule, for no
 * security benefit — rotating it means rotating app/jwt_secret, which
 * invalidates every player session too. Rotate the secret if it needs revoking.
 *
 * Usage:
 *   node scripts/mint-anon-key.mjs dev
 *   node scripts/mint-anon-key.mjs prod
 */

import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';

const ENVIRONMENT = process.argv[2] ?? 'dev';

const base64url = (input) =>
  Buffer.from(input).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

let secret;
try {
  secret = execFileSync(
    'aws',
    [
      'ssm', 'get-parameter',
      '--name', `/fanosbingo-${ENVIRONMENT}/app/jwt_secret`,
      '--with-decryption',
      '--query', 'Parameter.Value',
      '--output', 'text',
    ],
    { encoding: 'utf8' },
  ).trim();
} catch {
  console.error(
    `ERROR: could not read /fanosbingo-${ENVIRONMENT}/app/jwt_secret. Is the AWS session valid?`,
  );
  process.exit(1);
}

if (!secret || secret === 'PLACEHOLDER_SET_ME_OUT_OF_BAND') {
  console.error(
    `ERROR: app/jwt_secret is unset or still the placeholder in ${ENVIRONMENT}.\n` +
      'Run: gh workflow run sync-secrets.yml -f environment=' + ENVIRONMENT,
  );
  process.exit(1);
}

const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
const payload = base64url(
  JSON.stringify({
    role: 'anon',
    iss: 'fanosbingo',
    iat: Math.floor(Date.now() / 1000),
    // No `exp`. See the header comment.
  }),
);

const signature = crypto
  .createHmac('sha256', secret)
  .update(`${header}.${payload}`)
  .digest('base64')
  .replace(/\+/g, '-')
  .replace(/\//g, '_')
  .replace(/=+$/, '');

const jwt = `${header}.${payload}.${signature}`;

console.log(`
Anonymous key for ${ENVIRONMENT}:

${jwt}

Set it WITHOUT copying it by hand -- transcribing a token is how a variable
ends up holding a description of a token rather than one:

  gh variable set SPA_ANON_KEY --body "$(node scripts/mint-anon-key.mjs ${ENVIRONMENT} | grep -E '^eyJ')"

It is PUBLIC — it ends up in the compiled bundle. Its authority is whatever RLS
grants the anon role, and nothing more. Reading player data needs a token from
/functions/v1/auth/telegram, which needs a signature from Telegram.
`);
