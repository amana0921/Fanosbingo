/**
 * Fanos Bingo functions service.
 *
 * The API surface that is not plain data access. Everything that IS plain data
 * access goes straight to PostgREST, where RLS enforces authorization on every
 * query — which is the point of this service issuing tokens rather than acting
 * on players' behalf.
 *
 * WHAT THIS DELIBERATELY IS NOT
 *
 * It is not a port of the 25 inherited Deno functions. Those were written for a
 * hosted Supabase project this fork never had; all 25 used the service-role key
 * and so bypassed every RLS policy, and all 25 trusted a caller identity taken
 * from the request body. Porting them would have carried both properties onto
 * infrastructure built specifically to avoid them.
 *
 * Nothing depends on the old behaviour — no deployment, no users — so this is
 * the cheapest moment this design will ever be changed. Routes are added here
 * deliberately, each one answering "why can RLS not do this?".
 *
 * Legitimate answers so far:
 *   - minting a token (the client cannot sign one)
 *   - signing a withdrawal with KMS (the key is reachable by exactly one role)
 *   - talking to Telegram or a chain RPC (secrets that must not reach a browser)
 */

import express from 'express';
import pg from 'pg';
import fs from 'node:fs';
import { authenticateTelegram, requireAuth } from './auth.js';

const {
  PORT = '8080',
  ENVIRONMENT = 'dev',
  ALLOWED_ORIGIN,
  JWT_SECRET,
  TELEGRAM_BOT_TOKEN,
  PGSSLROOTCERT,
  PGSSLMODE = 'verify-full',
} = process.env;

/** Structured JSON, so CloudWatch Logs Insights can query the fields. */
function log(level, message, fields = {}) {
  process.stdout.write(
    JSON.stringify({
      ts: new Date().toISOString(),
      level,
      service: 'functions',
      env: ENVIRONMENT,
      message,
      ...fields,
    }) + '\n',
  );
}

// Fail at boot on missing configuration rather than at the first request.
//
// A service that starts without JWT_SECRET looks healthy, passes its health
// check, and rejects every login — an outage that presents as a client bug.
for (const [name, value] of Object.entries({ JWT_SECRET, TELEGRAM_BOT_TOKEN })) {
  if (!value) {
    log('error', `${name} is not set; refusing to start`, { missing: name });
    process.exit(1);
  }
}

// Same reasoning as the ticker: verify TLS to RDS against Amazon's committed CA
// bundle, and FAIL rather than silently downgrading. rejectUnauthorized:false
// encrypts the connection while verifying nothing, which for the process that
// reads player balances is not a trade worth making.
function buildSslConfig() {
  if (PGSSLMODE === 'disable') {
    log('warn', 'TLS disabled for the database connection');
    return false;
  }
  if (!PGSSLROOTCERT || !fs.existsSync(PGSSLROOTCERT)) {
    log('error', 'CA bundle missing; refusing to fall back to unverified TLS', {
      path: PGSSLROOTCERT ?? null,
    });
    process.exit(1);
  }
  return { ca: fs.readFileSync(PGSSLROOTCERT, 'utf8'), rejectUnauthorized: true };
}

const pool = new pg.Pool({
  ssl: buildSslConfig(),
  application_name: 'functions',
  max: 5,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 10_000,
});

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));

// CORS locked to one origin.
//
// Every inherited function sent `Access-Control-Allow-Origin: *`, including the
// ones that move money — meaning any page on the internet could make a browser
// issue those requests. Falls back to "null" rather than "*" when unset, so a
// misconfiguration fails closed instead of silently restoring the old
// behaviour.
app.use((req, res, next) => {
  res.set('Access-Control-Allow-Origin', ALLOWED_ORIGIN || 'null');
  res.set('Vary', 'Origin');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.set('Access-Control-Max-Age', '600');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  return next();
});

app.use((req, _res, next) => {
  req.log = {
    warn: (f) => log('warn', 'request', { path: req.path, ...f }),
    error: (f) => log('error', 'request', { path: req.path, ...f }),
  };
  next();
});

// Touches no upstream, so it stays useful while diagnosing one that is down.
// Caddy health-checks this path.
app.get('/healthz', (_req, res) => res.status(200).send('ok'));

// Readiness is a different question from liveness: this one asks whether the
// database is reachable, and it is the one that should gate traffic.
app.get('/readyz', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.status(200).json({ ready: true });
  } catch (err) {
    log('warn', 'readiness check failed', { error: err.message });
    res.status(503).json({ ready: false });
  }
});

/**
 * POST /auth/telegram  { initData }  ->  { token, expires_in, user }
 *
 * The only unauthenticated route, and necessarily so: it is where a caller
 * proves who they are. initData is signed by Telegram with a key derived from
 * the bot token, so a forged one fails the HMAC.
 */
app.post('/auth/telegram', async (req, res) => {
  const initData = req.body?.initData;

  if (typeof initData !== 'string' || !initData) {
    return res.status(400).json({ error: 'initData is required' });
  }

  try {
    const result = await authenticateTelegram(
      pool,
      initData,
      TELEGRAM_BOT_TOKEN,
      JWT_SECRET,
    );

    if (!result.ok) {
      // Logged with the reason, answered without it.
      log('warn', 'authentication rejected', { reason: result.reason });
      return res.status(result.status).json({ error: 'authentication failed' });
    }

    log('info', 'authenticated', { telegram_user_id: result.user.telegram_user_id });

    return res.json({
      token: result.token,
      expires_in: result.expires_in,
      user: result.user,
    });
  } catch (err) {
    log('error', 'authentication error', { error: err.message, stack: err.stack });
    return res.status(500).json({ error: 'internal error' });
  }
});

/**
 * GET /auth/whoami -> the identity the token proves.
 *
 * Exists so the auth path can be verified end to end without a money-moving
 * side effect. If this returns the right uuid through Caddy, then PostgREST
 * will read the same claims and RLS will resolve the same player.
 */
app.get('/auth/whoami', requireAuth(JWT_SECRET), (req, res) => {
  res.json({
    uid: req.auth.uid,
    telegram_user_id: req.auth.telegramUserId,
    role: req.auth.role,
  });
});

app.use((req, res) => res.status(404).json({ error: 'not found', path: req.path }));

// eslint-disable-next-line no-unused-vars -- Express identifies error handlers by arity
app.use((err, _req, res, _next) => {
  log('error', 'unhandled', { error: err.message, stack: err.stack });
  res.status(500).json({ error: 'internal error' });
});

const server = app.listen(Number(PORT), () => {
  log('info', 'listening', {
    port: Number(PORT),
    allowed_origin: ALLOWED_ORIGIN || '(unset — CORS will deny browsers)',
  });
});

// ECS sends SIGTERM and kills after stopTimeout. Draining means in-flight
// requests finish rather than being cut mid-transaction.
async function shutdown(signal) {
  log('info', 'shutting down', { signal });
  server.close(async () => {
    try {
      await pool.end();
    } catch (err) {
      log('warn', 'error closing the pool', { error: err.message });
    }
    process.exit(0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
