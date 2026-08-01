/**
 * Tests for requireAuth.
 *
 * THE ONE THAT MATTERS: the anon key must not authenticate anybody.
 *
 * It is signed with the same secret this service verifies with, because
 * PostgREST verifies both with one key. Its claims are
 * {"role":"anon","iss":"fanosbingo","iat":...} -- no `sub`, and no `exp`, so it
 * never expires. And it is PUBLIC by design: baked into every SPA bundle, with
 * .env.example saying so out loud.
 *
 * A gate that checks only the signature therefore admits a permanent,
 * published credential as an authenticated player. The remaining assertions
 * pin the two claims that make a token a player token rather than merely a
 * genuine one.
 *
 * Run: node src/auth.test.mjs
 */

import jwt from 'jsonwebtoken';
import { requireAuth } from './auth.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

const SECRET = 'test-secret-not-a-real-one';
const UID = '81f73524-2cd8-4f9b-ac38-dd71cdfd56e7';

const mkRes = () => ({
  code: 200,
  body: null,
  status(c) { this.code = c; return this; },
  json(b) { this.body = b; return this; },
});

const run = (token) => {
  const req = {
    get: (h) => (h.toLowerCase() === 'authorization' && token ? `Bearer ${token}` : ''),
    log: { warn: () => {}, error: () => {} },
  };
  const res = mkRes();
  let passed = false;
  requireAuth(SECRET)(req, res, () => { passed = true; });
  return { req, res, passed };
};

console.log('\nrequireAuth');

// --- the defect this file exists for --------------------------------------
{
  // Exactly what scripts/mint-anon-key.mjs produces.
  const anonKey = jwt.sign({ role: 'anon', iss: 'fanosbingo' }, SECRET, { algorithm: 'HS256' });
  const { res, passed } = run(anonKey);
  check('the ANON KEY does not authenticate anybody', passed === false && res.code === 401);
}

{
  // A token with the right role but no subject is not an identity either.
  const noSub = jwt.sign({ role: 'authenticated' }, SECRET, { algorithm: 'HS256' });
  const { res, passed } = run(noSub);
  check('role=authenticated with no sub is refused', passed === false && res.code === 401);
}

{
  // And a subject that is not the uuid auth.uid() casts to. A Telegram id here
  // is the defect db/20-post/004 documents: every RLS policy then matches
  // nothing and it presents as "the app loads but all the data is empty".
  const bigintSub = jwt.sign({ role: 'authenticated', sub: '7391104822' }, SECRET, {
    algorithm: 'HS256',
  });
  const { res, passed } = run(bigintSub);
  check('a Telegram bigint as sub is refused, not silently accepted', passed === false && res.code === 401);
}

{
  const serviceRole = jwt.sign({ role: 'service_role', sub: UID }, SECRET, { algorithm: 'HS256' });
  const { passed, res } = run(serviceRole);
  check('a service_role token is refused on a player route', passed === false && res.code === 401);
}

// --- what must still work --------------------------------------------------
{
  const good = jwt.sign(
    { role: 'authenticated', sub: UID, telegram_user_id: '7391104822' },
    SECRET,
    { algorithm: 'HS256', expiresIn: '15m' },
  );
  const { req, passed } = run(good);
  check('a real player token passes', passed === true);
  check('and carries the uuid through as uid', req.auth?.uid === UID);
  check('and the telegram id', req.auth?.telegramUserId === '7391104822');
}

// --- the pre-existing behaviour, unchanged ---------------------------------
{
  const { res, passed } = run(null);
  check('a missing token is 401', passed === false && res.code === 401);
}

{
  const { res, passed } = run('not.a.jwt');
  check('a malformed token is 401', passed === false && res.code === 401);
}

{
  const wrongSecret = jwt.sign({ role: 'authenticated', sub: UID }, 'someone-elses-secret', {
    algorithm: 'HS256',
  });
  const { res, passed } = run(wrongSecret);
  check('a forged token is 401', passed === false && res.code === 401);
}

{
  const expired = jwt.sign({ role: 'authenticated', sub: UID }, SECRET, {
    algorithm: 'HS256',
    expiresIn: '-1s',
  });
  const { res, passed } = run(expired);
  check('an expired token is 401, and says so', passed === false && res.code === 401 && res.body.expired === true);
}

console.log(failures === 0 ? '\nAll requireAuth tests passed\n' : `\n${failures} FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
