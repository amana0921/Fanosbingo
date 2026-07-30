/**
 * Tests for rate-limit.js.
 *
 * The assertions that matter are not "it counts to ten". They are:
 *
 *   - the window actually RESETS, so a limiter cannot become a permanent lockout
 *   - keys are independent, so one abusive player cannot block another (the whole
 *     reason this keys on telegram id rather than a shared NAT address)
 *   - at capacity it EVICTS rather than rejects, so filling it cannot be used to
 *     lock everyone out
 *   - the map does not grow without bound, so the limiter cannot become the
 *     memory exhaustion it exists to prevent
 *
 * Time is injected by shortening the window rather than by stubbing Date.now, so
 * the real clock path is exercised.
 *
 * Run: node src/rate-limit.test.mjs
 */

import { createRateLimiter } from './rate-limit.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

console.log('\ncreateRateLimiter');

// --- the budget -----------------------------------------------------------
{
  const rl = createRateLimiter({ limit: 3, windowMs: 60_000 });
  const verdicts = [rl.check(1), rl.check(1), rl.check(1), rl.check(1)];

  check('permits exactly the limit', verdicts.slice(0, 3).every((v) => v.allowed));
  check('refuses the one after', verdicts[3].allowed === false);
  check('reports remaining as it counts down', verdicts[0].remaining === 2 && verdicts[2].remaining === 0);
  check('gives a Retry-After a client can act on', verdicts[3].retryAfterSeconds >= 1);
}

// --- independence, which is the point of keying on the telegram id --------
{
  const rl = createRateLimiter({ limit: 2, windowMs: 60_000 });
  rl.check('player-a');
  rl.check('player-a');
  const aBlocked = rl.check('player-a');
  const bAllowed = rl.check('player-b');

  check('one player exhausting their budget is blocked', aBlocked.allowed === false);
  check('and does NOT block a different player', bAllowed.allowed === true);
}

// --- numbers and strings must be the same key ----------------------------
{
  const rl = createRateLimiter({ limit: 1, windowMs: 60_000 });
  rl.check(424946351);
  const asString = rl.check('424946351');
  check('a numeric id and its string form are one key', asString.allowed === false);
}

// --- the window resets ---------------------------------------------------
{
  const rl = createRateLimiter({ limit: 1, windowMs: 120 });
  rl.check('x');
  check('blocked inside the window', rl.check('x').allowed === false);
  await sleep(180);
  check('allowed again after it expires -- not a permanent lockout', rl.check('x').allowed === true);
}

// --- at capacity it evicts, and never rejects ----------------------------
//
// A limiter that started refusing new keys when full would hand an attacker a
// way to lock every player out by filling it. This asserts the opposite.
{
  const rl = createRateLimiter({ limit: 1, windowMs: 60_000, maxKeys: 5 });
  for (let i = 0; i < 5; i++) rl.check(`k${i}`);
  check('tracks up to the cap', rl.size() === 5);

  const newcomer = rl.check('k-new');
  check('a NEW key at capacity is still allowed', newcomer.allowed === true);
  check('and the cap is not exceeded', rl.size() <= 5);

  // Many more newcomers must not grow the map.
  for (let i = 0; i < 200; i++) rl.check(`flood-${i}`);
  check('200 further keys do not grow it past the cap', rl.size() <= 5);
}

// --- expired entries are reclaimed --------------------------------------
{
  const rl = createRateLimiter({ limit: 100, windowMs: 60, maxKeys: 10_000 });
  for (let i = 0; i < 600; i++) rl.check(`e${i}`);
  const before = rl.size();
  check('600 live keys are tracked', before === 600);

  await sleep(120); // every `e` window is now expired

  // The sweep runs on access, not on a timer. 600 checks above left the counter
  // at 100 of 500, so the sweep fires partway through this second batch.
  for (let i = 0; i < 600; i++) rl.check(`f${i}`);

  // The strict form. A weaker `size() < before + 600` would pass even if NOTHING
  // were reclaimed, since 600 < 1200 -- which is exactly the kind of assertion
  // that passes while the thing it claims to test is broken. If the 600 expired
  // `e` keys are gone, only the 600 `f` keys remain.
  check(
    `every expired window was reclaimed (${before} -> ${rl.size()}, expected <= 600)`,
    rl.size() <= 600,
  );
}

// --- the enforcing key is the verified id, checked through auth.js --------
//
// Wired here rather than left to the route, because the ordering -- verify, then
// limit, then write -- is the security property, and a test on the limiter alone
// would pass with the limiter called in the wrong place.
{
  const { authenticateTelegram } = await import('./auth.js');
  const { signForUser } = await import('./telegram-auth.test-helpers.mjs');

  const BOT_TOKEN = 'test-bot-token';
  let upserts = 0;
  const pool = {
    query: async () => {
      upserts++;
      return {
        rows: [{
          id: '00000000-0000-4000-8000-000000000001',
          telegram_user_id: 555,
          telegram_username: 'p',
          telegram_first_name: 'P',
        }],
      };
    },
  };

  const limiter = createRateLimiter({ limit: 2, windowMs: 60_000 });
  const initData = await signForUser(BOT_TOKEN, { id: 555, first_name: 'P' });

  const first = await authenticateTelegram(pool, initData, BOT_TOKEN, 'sekret', limiter);
  const second = await authenticateTelegram(pool, initData, BOT_TOKEN, 'sekret', limiter);
  const third = await authenticateTelegram(pool, initData, BOT_TOKEN, 'sekret', limiter);

  check('valid requests inside the budget succeed', first.ok === true && second.ok === true);
  check('the one past the budget is refused with 429', third.ok === false && third.status === 429);
  check('429 carries a Retry-After value', third.retryAfterSeconds >= 1);
  check(
    'and it did NOT reach the database -- the limit is ahead of the write',
    upserts === 2,
  );

  // A forged payload must be rejected before the limiter ever sees it, so a
  // flood of forgeries cannot consume a real player's budget.
  const forged = await authenticateTelegram(pool, 'hash=deadbeef&id=555', BOT_TOKEN, 'sekret', limiter);
  check('a forgery is 401, not 429', forged.ok === false && forged.status === 401);

  // Without a limiter the behaviour is unchanged, so this stays optional.
  const noLimiter = await authenticateTelegram(pool, initData, BOT_TOKEN, 'sekret');
  check('omitting the limiter leaves authentication working', noLimiter.ok === true);
}

console.log(failures ? `\n${failures} assertion(s) failed.` : '\nAll assertions passed.');
process.exit(failures ? 1 : 0);
