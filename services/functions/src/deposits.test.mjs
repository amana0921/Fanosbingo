/**
 * Tests for deposits.js.
 *
 * The assertions that matter:
 *
 *   - a claim's player_id comes from the token, and its bank_name from OUR
 *     bank_options row rather than from the request
 *   - a duplicate reference is a 409 the client can act on, not a 500
 *   - approve REQUIRES an explicit amount and never defaults to the claimed one
 *   - NOT_PENDING is 409, because that is what a double-clicked button and a
 *     second operator both produce
 *
 * Run: node src/deposits.test.mjs
 */

import {
  validateClaim,
  createDepositClaimHandler,
  createListDepositsHandler,
  createApproveDepositHandler,
  createRejectDepositHandler,
} from './deposits.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

const UID = '81f73524-2cd8-4f9b-ac38-dd71cdfd56e7';
const BANK = '11111111-1111-4111-8111-111111111111';
const REQ_ID = '22222222-2222-4222-8222-222222222222';

function fakePool({ bankRows, insertError, fnResult, listRows = [] } = {}) {
  const queries = [];
  const client = {
    query: async (sql, params) => {
      queries.push({ sql, params });
      if (sql.includes('FROM bank_options')) {
        return { rows: bankRows ?? [{ id: BANK, bank_name: 'Telebirr' }] };
      }
      if (sql.startsWith('INSERT INTO deposit_requests')) {
        if (insertError) throw insertError;
        return { rows: [{ id: REQ_ID, status: 'pending', created_at: 'now' }] };
      }
      return { rows: [] };
    },
    released: false,
    release() { this.released = true; },
  };
  return {
    queries,
    client,
    connect: async () => client,
    query: async (sql, params) => {
      queries.push({ sql, params });
      if (sql.includes('FROM deposit_requests')) return { rows: listRows };
      return { rows: [{ result: fnResult }] };
    },
  };
}

const mkRes = () => ({
  code: 200, body: null,
  status(c) { this.code = c; return this; },
  json(b) { this.body = b; return this; },
});
const mkReq = (over = {}) => ({
  auth: { uid: UID },
  body: {}, query: {}, params: {},
  log: { warn: () => {}, error: () => {} },
  ...over,
});

console.log('\nvalidateClaim');
check('rejects a non-uuid bank option', validateClaim({ bankOptionId: 'x', referenceNumber: 'FT1', claimedAmount: 1 }).ok === false);
check('rejects a 2-character reference', validateClaim({ bankOptionId: BANK, referenceNumber: 'ab', claimedAmount: 1 }).ok === false);
check('rejects a zero amount', validateClaim({ bankOptionId: BANK, referenceNumber: 'FT123', claimedAmount: 0 }).ok === false);
check('rejects a fractional amount', validateClaim({ bankOptionId: BANK, referenceNumber: 'FT123', claimedAmount: 1.5 }).ok === false);
check('trims a hand-typed reference', validateClaim({ bankOptionId: BANK, referenceNumber: '  FT123  ', claimedAmount: 5 }).reference === 'FT123');

console.log('\nPOST /deposits/claim');
{
  const pool = fakePool({});
  const res = mkRes();
  await createDepositClaimHandler(pool)(
    mkReq({ body: { bankOptionId: BANK, referenceNumber: 'FT25ABC', claimedAmount: 1000, playerId: 'someone-else' } }),
    res,
  );
  check('a valid claim is 201', res.code === 201);

  const ins = pool.queries.find((q) => q.sql.startsWith('INSERT INTO deposit_requests'));
  check('player_id comes from the token', ins?.params?.[0] === UID);
  check('a playerId in the body is ignored', !ins?.params?.includes('someone-else'));
  check('bank_name comes from OUR row, not the request', ins?.params?.[2] === 'Telebirr');
  check('the connection is released', pool.client.released === true);
}
{
  const pool = fakePool({ bankRows: [] });
  const res = mkRes();
  await createDepositClaimHandler(pool)(
    mkReq({ body: { bankOptionId: BANK, referenceNumber: 'FT1', claimedAmount: 1 } }), res,
  );
  check('an inactive or unknown bank is refused', res.code === 400);
}
{
  const dup = Object.assign(new Error('dup'), { code: '23505' });
  const pool = fakePool({ insertError: dup });
  const res = mkRes();
  await createDepositClaimHandler(pool)(
    mkReq({ body: { bankOptionId: BANK, referenceNumber: 'FT25ABC', claimedAmount: 1000 } }), res,
  );
  check('a duplicate reference is 409, not 500', res.code === 409);
  check('and says something the player can act on', /already been submitted/.test(res.body?.error ?? ''));
  check('the connection is still released', pool.client.released === true);
}

console.log('\nGET /admin/deposits');
{
  const pool = fakePool({ listRows: [{ id: REQ_ID }] });
  const res = mkRes();
  await createListDepositsHandler(pool)(mkReq({ query: {} }), res);
  check('defaults to the pending queue', res.body?.status === 'pending');

  const q = pool.queries.find((x) => x.sql.includes('FROM deposit_requests'));
  check('oldest first, so the queue is fair by default', /ORDER BY d\.created_at ASC/.test(q?.sql ?? ''));
  check('joins the player so the operator sees who is claiming', /JOIN telegram_users/.test(q?.sql ?? ''));

  const res2 = mkRes();
  await createListDepositsHandler(pool)(mkReq({ query: { status: 'nonsense' } }), res2);
  check('an unknown status is refused', res2.code === 400);
}

console.log('\nPOST /admin/deposits/:id/approve');
{
  const res = mkRes();
  await createApproveDepositHandler(fakePool({}))(
    mkReq({ params: { id: REQ_ID }, body: {} }), res,
  );
  check('refuses without an explicit amount', res.code === 400);
  check('and says to use the statement', /statement/.test(res.body?.error ?? ''));
}
{
  const pool = fakePool({ fnResult: { success: true, credited: 500, claimed: 1000 } });
  const res = mkRes();
  await createApproveDepositHandler(pool)(
    mkReq({ params: { id: REQ_ID }, body: { actualAmount: 500, note: 'statement shows 500' } }), res,
  );
  check('approves with the amount the operator typed', res.code === 200 && res.body?.credited === 500);

  const call = pool.queries.find((q) => q.sql.includes('approve_deposit_request'));
  check('passes the ADMIN uid from the token', call?.params?.[2] === UID);
  check('and never substitutes the claimed amount', call?.params?.[1] === 500);
}
{
  const res = mkRes();
  await createApproveDepositHandler(fakePool({ fnResult: { success: false, error_code: 'NOT_PENDING' } }))(
    mkReq({ params: { id: REQ_ID }, body: { actualAmount: 500 } }), res,
  );
  check('NOT_PENDING is 409 — a double click or a second operator', res.code === 409);
}
{
  const res = mkRes();
  await createApproveDepositHandler(fakePool({}))(
    mkReq({ params: { id: 'not-a-uuid' }, body: { actualAmount: 5 } }), res,
  );
  check('a bad id is 400', res.code === 400);
}

console.log('\nPOST /admin/deposits/:id/reject');
{
  const pool = fakePool({ fnResult: { success: true, request_id: REQ_ID } });
  const res = mkRes();
  await createRejectDepositHandler(pool)(
    mkReq({ params: { id: REQ_ID }, body: { note: 'nothing in the statement' } }), res,
  );
  check('rejects with a note', res.code === 200 && res.body?.success === true);
  const call = pool.queries.find((q) => q.sql.includes('reject_deposit_request'));
  check('records which admin rejected it', call?.params?.[1] === UID);
}
{
  const res = mkRes();
  await createRejectDepositHandler(fakePool({ fnResult: { success: false, error_code: 'NOT_PENDING' } }))(
    mkReq({ params: { id: REQ_ID }, body: {} }), res,
  );
  check('rejecting a decided request is 409', res.code === 409);
}

console.log(failures ? `\n${failures} assertion(s) failed.` : '\nAll assertions passed.');
process.exit(failures ? 1 : 0);
