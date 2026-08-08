/**
 * Tests for requireSecondFactor and the enrolment routes.
 *
 * totp.test.mjs proves the algorithm against RFC 6238. This proves the POLICY
 * around it, which is where the security actually lives:
 *
 *   - a wrong code does not move money
 *   - an un-enrolled admin is NOT blocked, because a control that locks the
 *     deposit queue on deploy causes the outage the queue alarm exists to catch
 *   - a confirmed enrolment cannot be overwritten by the route, or the second
 *     factor is replaceable with one factor and is therefore not a second factor
 *
 * Run: node src/second-factor.test.mjs
 */

import { requireSecondFactor, createTotpEnrollHandler, createTotpConfirmHandler } from './admin.js';
import { generate, generateSecret } from './totp.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

console.log('\nrequireSecondFactor');

const makeRes = () => {
  const r = { statusCode: null, body: null,
    status(c) { r.statusCode = c; return r; },
    json(b) { r.body = b; return r; } };
  return r;
};
const makeReq = (over = {}) => ({
  auth: { uid: 'uid-1', telegramUserId: 424946351 },
  body: {},
  path: '/admin/deposits/x/approve',
  get: () => undefined,
  log: { warn() {}, error() {} },
  ...over,
});
const poolOf = (row, onUpdate) => ({
  query: async (sql, params) => {
    if (/^UPDATE/i.test(sql.trim())) { onUpdate?.(sql, params); return { rows: [] }; }
    return { rows: row ? [row] : [] };
  },
});

const run = async (mw, req) => {
  const res = makeRes();
  let nexts = 0;
  await mw(req, res, () => nexts++);
  return { res, nexts };
};

// --- enrolled: the code decides -------------------------------------------
{
  const secret = generateSecret();
  const row = { totp_secret: secret, totp_confirmed_at: new Date() };
  const mw = requireSecondFactor(poolOf(row));

  const good = await run(mw, makeReq({ get: (h) => (h === 'X-Admin-TOTP' ? generate(secret) : undefined) }));
  check('a valid code reaches the handler', good.nexts === 1);

  const bad = await run(mw, makeReq({ get: () => '000000' }));
  check('a wrong code never reaches the handler', bad.nexts === 0);
  check('and is refused 428, not 401 -- the caller IS authenticated', bad.res.statusCode === 428);
  check('with a code the client can branch on', bad.res.body?.code === 'TOTP_REQUIRED');

  const none = await run(mw, makeReq());
  check('a missing code is refused', none.nexts === 0 && none.res.statusCode === 428);

  // The body is the fallback for clients that cannot set headers.
  const viaBody = await run(mw, makeReq({ body: { totp: generate(secret) } }));
  check('a code in the body is accepted too', viaBody.nexts === 1);
}

// --- not enrolled: must NOT block ------------------------------------------
{
  const mw = requireSecondFactor(poolOf({ totp_secret: null, totp_confirmed_at: null }));
  const r = await run(mw, makeReq());
  check('an UN-ENROLLED admin is not blocked', r.nexts === 1);

  const started = requireSecondFactor(poolOf({ totp_secret: generateSecret(), totp_confirmed_at: null }));
  const r2 = await run(started, makeReq());
  check('nor is a half-finished enrolment -- it cannot lock the queue', r2.nexts === 1);
}

// --- wiring and failure modes ---------------------------------------------
{
  const mw = requireSecondFactor(poolOf({ totp_secret: generateSecret(), totp_confirmed_at: new Date() }));
  const r = await run(mw, makeReq({ auth: undefined }));
  check('no req.auth is a 500, not a silent pass', r.nexts === 0 && r.res.statusCode === 500);

  const broken = requireSecondFactor({ query: async () => { throw new Error('db down'); } });
  const r2 = await run(broken, makeReq());
  check('a database error FAILS CLOSED rather than waving it through', r2.nexts === 0 && r2.res.statusCode === 500);
}

console.log('\nenrolment');

// --- enroll ----------------------------------------------------------------
{
  let updated = null;
  const h = createTotpEnrollHandler(poolOf({ totp_confirmed_at: null }, (_s, p) => { updated = p; }));
  const res = makeRes();
  await h(makeReq(), res);

  check('returns a secret and an otpauth uri', typeof res.body?.secret === 'string' && res.body.uri.startsWith('otpauth://'));
  check('and writes it', updated?.[1] === res.body.secret);

  const confirmed = createTotpEnrollHandler(poolOf({ totp_confirmed_at: new Date() }));
  const res2 = makeRes();
  await confirmed(makeReq(), res2);
  check('REFUSES to overwrite a confirmed enrolment', res2.statusCode === 409);
  check('which is what stops one factor replacing the second', res2.body?.code === 'TOTP_ALREADY_ENROLLED');
}

// --- confirm ---------------------------------------------------------------
{
  const secret = generateSecret();
  let updated = false;
  const h = createTotpConfirmHandler(poolOf({ totp_secret: secret, totp_confirmed_at: null }, () => { updated = true; }));

  const res = makeRes();
  await h(makeReq({ body: { totp: generate(secret) } }), res);
  check('a correct code confirms the enrolment', res.body?.confirmed === true && updated);

  const res2 = makeRes();
  updated = false;
  await h(makeReq({ body: { totp: '000000' } }), res2);
  check('a wrong code does not confirm', res2.statusCode === 400 && updated === false);

  const notEnrolled = createTotpConfirmHandler(poolOf({ totp_secret: null }));
  const res3 = makeRes();
  await notEnrolled(makeReq({ body: { totp: '123456' } }), res3);
  check('confirming without enrolling is a 409', res3.statusCode === 409);
}

console.log(failures ? `\n${failures} assertion(s) failed.` : '\nAll second-factor tests passed.');
process.exit(failures ? 1 : 0);
