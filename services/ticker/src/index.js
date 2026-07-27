/**
 * Fanos Bingo ticker.
 *
 * The game's heartbeat. Calls game_tick() once per second while holding a
 * PostgreSQL advisory lock, which guarantees exactly one caller across however
 * many instances are running.
 *
 * Why this exists at all:
 *
 *   Supabase drove the game with `cron.schedule_in_database('call-bingo-numbers',
 *   '4 seconds', ...)`. That six-field sub-minute syntax is a fork extension.
 *   Stock pg_cron on RDS has one-minute granularity and does not reject a
 *   sub-minute schedule — it simply never fires it. A game heartbeat that
 *   silently stops is the worst failure mode in this system.
 *
 *   Everything else the loop now owns (starting games, rolling countdowns,
 *   closing claim windows, creating the next game) was previously done by
 *   whichever browser happened to have the lobby open. The game literally did
 *   not progress if nobody was watching.
 *
 * Design notes:
 *
 *   - The advisory lock is session-scoped and held on a DEDICATED connection.
 *     If this process dies, the connection drops, PostgreSQL releases the lock,
 *     and a standby acquires it on its next attempt. No lease renewal, no
 *     expiry tuning, no split brain.
 *
 *   - A non-holder polls rather than exiting, so `instance_count = 2` at Stage 2
 *     gives fast failover with no further code changes.
 *
 *   - All game logic lives in game_tick(). This process is deliberately dumb:
 *     one round trip per tick, one transaction, correct locking in the database
 *     where it belongs.
 */

import pg from 'pg';
import { CloudWatchClient, PutMetricDataCommand } from '@aws-sdk/client-cloudwatch';

const {
  DATABASE_URL,
  TICK_INTERVAL_MS = '1000',
  CALL_INTERVAL_MS = '3500',
  CLAIM_WINDOW_MS = '1000',
  COUNTDOWN_SECONDS = '25',
  METRIC_NAMESPACE,
  ENVIRONMENT = 'dev',
  AWS_REGION = 'us-east-1',
  METRICS_ENABLED = 'true',
} = process.env;

// Arbitrary but fixed. Any process using this same key contends for the same
// lock, which is exactly what we want; it must never be reused for anything else.
const GAME_LOOP_LOCK_KEY = 728451923;

const TICK_MS = Number(TICK_INTERVAL_MS);
const metricsEnabled = METRICS_ENABLED === 'true' && Boolean(METRIC_NAMESPACE);

const cloudwatch = metricsEnabled
  ? new CloudWatchClient({ region: AWS_REGION })
  : null;

/** Structured JSON so CloudWatch Logs Insights can query these fields. */
function log(level, message, fields = {}) {
  process.stdout.write(
    JSON.stringify({
      ts: new Date().toISOString(),
      level,
      service: 'ticker',
      env: ENVIRONMENT,
      message,
      ...fields,
    }) + '\n'
  );
}

if (!DATABASE_URL) {
  log('error', 'DATABASE_URL is not set');
  process.exit(1);
}

let shuttingDown = false;
let lockClient = null;
let pool = null;

/**
 * Take the game-loop lock.
 *
 * pg_try_advisory_lock returns immediately rather than queuing: a standby
 * should keep polling and stay ready, not block forever on a lock the holder
 * will keep for its entire lifetime.
 */
async function tryAcquireLock() {
  const client = new pg.Client({ connectionString: DATABASE_URL, application_name: 'ticker-lock' });
  await client.connect();

  const { rows } = await client.query('SELECT pg_try_advisory_lock($1) AS acquired', [
    GAME_LOOP_LOCK_KEY,
  ]);

  if (rows[0].acquired) {
    lockClient = client;
    return true;
  }

  await client.end();
  return false;
}

async function publishMetrics(result, tickDurationMs) {
  if (!cloudwatch) return;

  const dims = [{ Name: 'Environment', Value: ENVIRONMENT }];

  try {
    await cloudwatch.send(
      new PutMetricDataCommand({
        Namespace: METRIC_NAMESPACE,
        MetricData: [
          {
            // THE alarm metric. If this climbs, the game is frozen and players
            // are staring at a board that stopped moving.
            MetricName: 'SecondsSinceLastNumberCalled',
            Value: (result.oldest_call_age_ms ?? 0) / 1000,
            Unit: 'Seconds',
            Dimensions: dims,
          },
          {
            MetricName: 'ActiveGames',
            Value: result.active_games ?? 0,
            Unit: 'Count',
            Dimensions: dims,
          },
          {
            MetricName: 'TickDuration',
            Value: tickDurationMs,
            Unit: 'Milliseconds',
            Dimensions: dims,
          },
        ],
      })
    );
  } catch (error) {
    // Never let a metrics failure stop the game.
    log('warn', 'Failed to publish metrics', { error: error.message });
  }
}

async function tick() {
  const started = Date.now();

  const { rows } = await pool.query(
    'SELECT game_tick($1, $2, $3) AS result',
    [Number(CALL_INTERVAL_MS), Number(CLAIM_WINDOW_MS), Number(COUNTDOWN_SECONDS)]
  );

  const result = rows[0].result;
  const duration = Date.now() - started;

  // Log only ticks where something happened. At one tick per second, logging
  // every no-op would be ~86k lines a day of nothing, and CloudWatch log
  // ingestion is a real cost line at this budget.
  const didSomething =
    result.numbers_called > 0 ||
    result.games_started > 0 ||
    result.games_finished > 0 ||
    result.claims_closed > 0 ||
    result.waiting_game_created;

  if (didSomething) {
    log('info', 'tick', { ...result, duration_ms: duration });
  }

  if (duration > TICK_MS) {
    // The loop cannot keep its cadence. At this point number calls drift and
    // players notice.
    log('warn', 'Tick exceeded its interval', {
      duration_ms: duration,
      interval_ms: TICK_MS,
    });
  }

  await publishMetrics(result, duration);
}

/**
 * Fixed-delay rather than setInterval: setInterval queues overlapping
 * executions if a tick ever runs long, which for a game loop means two
 * concurrent game_tick() calls.
 */
async function runLoop() {
  while (!shuttingDown) {
    const started = Date.now();

    try {
      await tick();
    } catch (error) {
      log('error', 'Tick failed', { error: error.message, stack: error.stack });
      // Deliberately keep going. A transient database blip should not take the
      // game down; the SecondsSinceLastNumberCalled alarm covers a real outage.
    }

    const elapsed = Date.now() - started;
    const wait = Math.max(0, TICK_MS - elapsed);
    await new Promise((resolve) => setTimeout(resolve, wait));
  }
}

async function main() {
  log('info', 'Starting', {
    tick_interval_ms: TICK_MS,
    call_interval_ms: Number(CALL_INTERVAL_MS),
    metrics: metricsEnabled,
  });

  pool = new pg.Pool({
    connectionString: DATABASE_URL,
    application_name: 'ticker',
    max: 2,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
  });

  // Fail fast on a bad connection string rather than looping on errors.
  await pool.query('SELECT 1');

  while (!shuttingDown) {
    if (await tryAcquireLock()) {
      log('info', 'Acquired game-loop lock; this instance is the caller');
      break;
    }
    log('info', 'Another instance holds the game-loop lock; standing by');
    await new Promise((resolve) => setTimeout(resolve, 5000));
  }

  if (!shuttingDown) await runLoop();
}

async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log('info', 'Shutting down', { signal });

  // Release explicitly so a standby takes over in milliseconds rather than
  // waiting for the server to notice a dropped connection.
  try {
    if (lockClient) {
      await lockClient.query('SELECT pg_advisory_unlock($1)', [GAME_LOOP_LOCK_KEY]);
      await lockClient.end();
    }
    if (pool) await pool.end();
  } catch (error) {
    log('warn', 'Error during shutdown', { error: error.message });
  }

  process.exit(0);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

main().catch((error) => {
  log('error', 'Fatal', { error: error.message, stack: error.stack });
  process.exit(1);
});
