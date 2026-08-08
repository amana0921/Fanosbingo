/**
 * Tests for admin.js.
 *
 * The assertions that matter are the ones about the bootstrap route, because it
 * is the only path that can create an admin from nothing and it is left deployed:
 *
 *   - it promotes ONLY the caller, so it cannot grant admin to anyone else
 *   - it refuses once any admin exists, so it disarms itself and a leaked key
 *     becomes worthless
 *   - it does not reveal whether the key was correct after it has disarmed
 *   - the promoting UPDATE re-checks the zero-admin condition itself, so two
 *     simultaneous requests cannot both win
 *
 * Run: node src/admin.test.mjs
 */

import {
  requireAdmin,
  createAdminWhoamiHandler,
  createAdminBootstrapHandler,
  timingSafeEqual,
} from './admin.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

const UID = '81f73524-2cd8-4f9b-ac38-dd71cdfd56e7';
const KEY = 'correct-horse-battery-staple';

function fakePool({ isAdmin = false, adminCount = 0, promoted = true } = {}) {
  const queries = [];
  return {
    queries,
    connect: async () => ({ query: async () => ({ rows: [] }), release() {} }),
    query: async (sql, params) => {
      queries.push({ sql, params });
      if (sql.includes('count(*)')) return { rows: [{ n: adminCount }] };
      if (sql.startsWith('UPDATE telegram_users')) {
        return { rows: promoted ? [{ id: UID, telegram_user_id: 424946351 }] : [] };
      }
      // Matches both shapes: requireAdmin reads is_admin alone, while
      // /admin/whoami joins admin_totp and therefore selects `u.is_admin`.
      // Matching only the bare string silently returned no rows for whoami,
      // which read as "not an admin" rather than as a broken double.
      if (/SELECT\s+(u\.)?is_admin/.test(sql)) {
        return {
          rows: isAdmin === null
            ? []
            : [{ is_admin: isAdmin, totp_started: false, totp_enrolled: false }],
        };
      }
      return { rows: [] };
    },
  };
}

const mkRes = () => ({
  code: 200, body: null,
  status(c) { this.code = c; return this; },
  json(b) { this.body = b; return this; },
});
const mkReq = (body = {}) => ({
  auth: { uid: UID, telegramUserId: '424946351' },
  body,
  log: { warn: () => {}, error: () => {} },
});

console.log('\ntimingSafeEqual');
check('equal strings match', timingSafeEqual('abc', 'abc'));
check('different strings do not', !timingSafeEqual('abc', 'abd'));
check('different lengths do not', !timingSafeEqual('abc', 'abcd'));
check('a prefix does not match the whole', !timingSafeEqual('abc', 'abcdef'));
check('non-strings do not match', !timingSafeEqual(null, 'abc'));

console.log('\nrequireAdmin');
{
  let nexted = false;
  const res = mkRes();
  await requireAdmin(fakePool({ isAdmin: true }))(mkReq(), res, () => { nexted = true; });
  check('an admin passes through', nexted === true);
}
{
  let nexted = false;
  const res = mkRes();
  await requireAdmin(fakePool({ isAdmin: false }))(mkReq(), res, () => { nexted = true; });
  check('a non-admin is refused', nexted === false && res.code === 403);
  check('403, not 404 — the caller proved who they are', res.code === 403);
}
{
  const res = mkRes();
  await requireAdmin(fakePool({ isAdmin: null }))(mkReq(), res, () => {});
  check('a token for a deleted player is refused', res.code === 403);
}
{
  // Wired without requireAuth: a programming error, not a rejected request.
  const res = mkRes();
  let nexted = false;
  await requireAdmin(fakePool({ isAdmin: true }))({ body: {}, log: { error: () => {} } }, res, () => { nexted = true; });
  check('a route missing requireAuth fails closed, not open', nexted === false && res.code === 500);
}
{
  const pool = fakePool({ isAdmin: true });
  pool.query = async () => { throw new Error('connection reset'); };
  const res = mkRes();
  let nexted = false;
  await requireAdmin(pool)(mkReq(), res, () => { nexted = true; });
  check('a database error denies rather than admits', nexted === false && res.code === 500);
}

console.log('\nadmin/whoami');
{
  const res = mkRes();
  await createAdminWhoamiHandler(fakePool({ isAdmin: true }))(mkReq(), res);
  check('reports an admin', res.body?.is_admin === true);
  const res2 = mkRes();
  await createAdminWhoamiHandler(fakePool({ isAdmin: false }))(mkReq(), res2);
  check('reports a non-admin', res2.body?.is_admin === false);
}

console.log('\nadmin/bootstrap');
{
  const pool = fakePool({ adminCount: 0 });
  const res = mkRes();
  await createAdminBootstrapHandler(pool, KEY)(mkReq({ key: KEY }), res);
  check('the first admin is promoted with the right key', res.body?.ok === true);

  const upd = pool.queries.find((q) => q.sql.startsWith('UPDATE telegram_users'));
  check('it promotes the CALLER, by req.auth.uid', upd?.params?.[0] === UID);
  check(
    'the UPDATE re-checks the zero-admin condition itself, so a race cannot produce two',
    /NOT EXISTS \(SELECT 1 FROM telegram_users WHERE is_admin\)/.test(upd?.sql ?? ''),
  );
  check(
    'there is no parameter naming who to promote',
    (upd?.params?.length ?? 0) === 1,
  );
}
{
  const res = mkRes();
  await createAdminBootstrapHandler(fakePool({ adminCount: 0 }), KEY)(mkReq({ key: 'wrong' }), res);
  check('a wrong key is refused', res.code === 403);
}
{
  // Disarmed: an admin already exists.
  const pool = fakePool({ adminCount: 1 });
  const res = mkRes();
  await createAdminBootstrapHandler(pool, KEY)(mkReq({ key: KEY }), res);
  check('it refuses once any admin exists, even with the correct key', res.code === 409);
  check(
    'and does not reveal that the key was correct',
    res.body?.error === 'an admin already exists',
  );
  check(
    'no UPDATE was attempted',
    !pool.queries.some((q) => q.sql.startsWith('UPDATE')),
  );
}
{
  // The race: count said zero, but the UPDATE's own guard found otherwise.
  const res = mkRes();
  await createAdminBootstrapHandler(fakePool({ adminCount: 0, promoted: false }), KEY)(
    mkReq({ key: KEY }), res,
  );
  check('a lost race is a clean 409, not a false success', res.code === 409);
}
{
  const res = mkRes();
  await createAdminBootstrapHandler(fakePool({ adminCount: 0 }), '')(mkReq({ key: 'x' }), res);
  check('an unconfigured key is 503, not an open door', res.code === 503);
}
{
  const res = mkRes();
  await createAdminBootstrapHandler(fakePool({ adminCount: 0 }), KEY)(mkReq({}), res);
  check('a missing key is 400', res.code === 400);
}

console.log(failures ? `\n${failures} assertion(s) failed.` : '\nAll assertions passed.');
process.exit(failures ? 1 : 0);
