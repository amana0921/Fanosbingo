/**
 * Tests for withdrawals.js.
 *
 * The assertions that matter, and why each one is here rather than being
 * obvious:
 *
 *   - the telegram id passed to request_bank_withdrawal comes from the TOKEN,
 *     and the bank name from OUR withdrawal_bank_options row rather than from
 *     the request. Both are the defect db/20-post/004 and services/functions
 *     exist to remove, and both are one careless edit away from returning.
 *   - an amount with more than two decimal places is refused, because
 *     numeric(10,2) would silently round it and the player would be told they
 *     asked for something they did not.
 *   - INSUFFICIENT_BALANCE is a 409 carrying the real numbers, not a 400.
 *   - a duplicate payout reference is a 409 the operator can act on. That index
 *     is what stops one bank transfer being recorded as two payouts, so it must
 *     not surface as a 500.
 *   - completing REQUIRES an explicit reference and rejecting REQUIRES a reason.
 *
 * Run: node src/withdrawals.test.mjs
 */

import {
  validateWithdrawalRequest,
  createAvailableBalanceHandler,
  createRequestWithdrawalHandler,
  createListWithdrawalsHandler,
  createCompleteWithdrawalHandler,
  createRejectWithdrawalHandler,
} from './withdrawals.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

const UID = '81f73524-2cd8-4f9b-ac38-dd71cdfd56e7';
const TG = '7391104822';
const BANK = '11111111-1111-4111-8111-111111111111';
const REQ_ID = '22222222-2222-4222-8222-222222222222';

const GOOD = {
  bankOptionId: BANK,
  amount: 250,
  accountNumber: '1000123456789',
  accountName: 'Abebe Bekele',
};

function fakePool({ bankRows, fnResult, fnError, listRows = [], available = 0 } = {}) {
  const queries = [];
  const run = async (sql, params) => {
    queries.push({ sql, params });
    if (sql.includes('FROM withdrawal_bank_options')) {
      return { rows: bankRows ?? [{ id: BANK, bank_name: 'Telebirr' }] };
    }
    if (sql.includes('get_available_balance')) return { rows: [{ available }] };
    if (sql.includes('FROM withdrawal_requests')) return { rows: listRows };
    if (fnError) throw fnError;
    return { rows: [{ result: fnResult }] };
  };
  const client = {
    query: run,
    released: false,
    release() {
      this.released = true;
    },
  };
  return { queries, client, connect: async () => client, query: run };
}

const mkRes = () => ({
  code: 200,
  body: null,
  status(c) {
    this.code = c;
    return this;
  },
  json(b) {
    this.body = b;
    return this;
  },
});

const mkReq = (over = {}) => ({
  auth: { uid: UID, telegramUserId: TG },
  body: {},
  query: {},
  params: {},
  log: { warn: () => {}, error: () => {} },
  ...over,
});

// ---------------------------------------------------------------------------
console.log('\nvalidateWithdrawalRequest');

check('rejects a non-uuid bank option', validateWithdrawalRequest({ ...GOOD, bankOptionId: 'x' }).ok === false);
check('rejects a zero amount', validateWithdrawalRequest({ ...GOOD, amount: 0 }).ok === false);
check('rejects a negative amount', validateWithdrawalRequest({ ...GOOD, amount: -5 }).ok === false);
check('rejects a string amount', validateWithdrawalRequest({ ...GOOD, amount: '250' }).ok === false);
check('rejects NaN', validateWithdrawalRequest({ ...GOOD, amount: NaN }).ok === false);
check('rejects Infinity', validateWithdrawalRequest({ ...GOOD, amount: Infinity }).ok === false);
check('rejects beyond numeric(10,2)', validateWithdrawalRequest({ ...GOOD, amount: 100_000_000 }).ok === false);

// The one that catches a tautological decimal check: 10.005 must NOT pass,
// because numeric(10,2) would store 10.01 and the receipt would disagree with
// the request.
check('rejects three decimal places', validateWithdrawalRequest({ ...GOOD, amount: 10.005 }).ok === false);
check('accepts two decimal places', validateWithdrawalRequest({ ...GOOD, amount: 10.01 }).ok === true);
check('accepts one decimal place', validateWithdrawalRequest({ ...GOOD, amount: 0.1 }).ok === true);
check('accepts a whole number', validateWithdrawalRequest({ ...GOOD, amount: 250 }).ok === true);

check('rejects a 3-character account number', validateWithdrawalRequest({ ...GOOD, accountNumber: '123' }).ok === false);
check('rejects a 1-character account name', validateWithdrawalRequest({ ...GOOD, accountName: 'A' }).ok === false);
check('rejects a missing account name', validateWithdrawalRequest({ ...GOOD, accountName: undefined }).ok === false);
check(
  'trims a hand-typed destination',
  validateWithdrawalRequest({ ...GOOD, accountNumber: '  1000123456789  ' }).accountNumber ===
    '1000123456789',
);

// ---------------------------------------------------------------------------
console.log('\nPOST /withdrawals/request');

{
  const pool = fakePool({ fnResult: { success: true, request_id: REQ_ID, available_after: 750 } });
  const res = mkRes();
  await createRequestWithdrawalHandler(pool)(mkReq({ body: GOOD }), res);

  check('creates the request with 201', res.code === 201 && res.body.success === true);

  const call = pool.queries.find((q) => q.sql.includes('request_bank_withdrawal'));
  check('passes the telegram id from the TOKEN, not the body', call.params[0] === TG);
  check('passes the bank name from OUR row, not the body', call.params[2] === 'Telebirr');
  check('passes the validated amount', call.params[1] === 250);
  check('releases the connection', pool.client.released === true);
}

{
  // A body naming a different bank must not change what is recorded.
  const pool = fakePool({ fnResult: { success: true, request_id: REQ_ID } });
  await createRequestWithdrawalHandler(pool)(
    mkReq({ body: { ...GOOD, bankName: 'Bank Of Attacker', telegramUserId: '1' } }),
    mkRes(),
  );
  const call = pool.queries.find((q) => q.sql.includes('request_bank_withdrawal'));
  check('ignores a bankName supplied in the body', call.params[2] === 'Telebirr');
  check('ignores a telegramUserId supplied in the body', call.params[0] === TG);
}

{
  const pool = fakePool({ bankRows: [] });
  const res = mkRes();
  await createRequestWithdrawalHandler(pool)(mkReq({ body: GOOD }), res);
  check('refuses an unknown or inactive bank', res.code === 400);
  check('still releases the connection on refusal', pool.client.released === true);
}

{
  const pool = fakePool({
    fnResult: {
      success: false,
      error_code: 'INSUFFICIENT_BALANCE',
      available: 100,
      requested: 250,
      won_balance: 400,
      already_pending: 300,
    },
  });
  const res = mkRes();
  await createRequestWithdrawalHandler(pool)(mkReq({ body: GOOD }), res);
  check('INSUFFICIENT_BALANCE is a 409', res.code === 409);
  check('and carries the real numbers back to the form', res.body.available === 100 && res.body.already_pending === 300);
}

{
  const pool = fakePool({ fnResult: { success: false, error_code: 'USER_NOT_FOUND' } });
  const res = mkRes();
  await createRequestWithdrawalHandler(pool)(mkReq({ body: GOOD }), res);
  check('USER_NOT_FOUND is a 404, not a validation error', res.code === 404);
}

{
  const res = mkRes();
  await createRequestWithdrawalHandler(fakePool())(
    mkReq({ body: GOOD, auth: { uid: UID, telegramUserId: 'not-a-number' } }),
    res,
  );
  check('a token with a non-numeric telegram id is a 400', res.code === 400);
}

// ---------------------------------------------------------------------------
console.log('\nGET /withdrawals/available');

{
  const pool = fakePool({ available: '412.50' });
  const res = mkRes();
  await createAvailableBalanceHandler(pool)(mkReq(), res);
  check('returns the available balance as a number', res.body.available === 412.5);
  check('asks with the telegram id from the token', pool.queries[0].params[0] === TG);
}

// ---------------------------------------------------------------------------
console.log('\nGET /admin/withdrawals');

{
  const pool = fakePool({ listRows: [{ id: REQ_ID }] });
  const res = mkRes();
  await createListWithdrawalsHandler(pool)(mkReq(), res);
  check('defaults to the pending queue', res.body.status === 'pending' && res.body.count === 1);
}

{
  const res = mkRes();
  await createListWithdrawalsHandler(fakePool())(mkReq({ query: { status: 'anything' } }), res);
  check('rejects an unknown status', res.code === 400);
}

{
  const pool = fakePool({ listRows: [] });
  await createListWithdrawalsHandler(pool)(mkReq({ query: { limit: '5000' } }), mkRes());
  check('caps the page size at 200', pool.queries[0].params[1] === 200);
}

// ---------------------------------------------------------------------------
console.log('\nPOST /admin/withdrawals/:id/complete');

{
  const res = mkRes();
  await createCompleteWithdrawalHandler(fakePool())(
    mkReq({ params: { id: REQ_ID }, body: {} }),
    res,
  );
  check('requires a payout reference', res.code === 400);
}

{
  const res = mkRes();
  await createCompleteWithdrawalHandler(fakePool())(
    mkReq({ params: { id: 'not-a-uuid' }, body: { payoutReference: 'FT2299' } }),
    res,
  );
  check('rejects a non-uuid id', res.code === 400);
}

{
  const pool = fakePool({ fnResult: { success: true, paid: 250, telegram_user_id: TG } });
  const res = mkRes();
  await createCompleteWithdrawalHandler(pool)(
    mkReq({ params: { id: REQ_ID }, body: { payoutReference: '  FT2299  ' } }),
    res,
  );
  check('completes with 200', res.code === 200 && res.body.success === true);

  const call = pool.queries.find((q) => q.sql.includes('complete_bank_withdrawal'));
  check('trims the pasted reference', call.params[2] === 'FT2299');
  check('passes the admin uid from the token', call.params[1] === UID);
}

{
  const err = new Error('duplicate key value violates unique constraint');
  err.code = '23505';
  const res = mkRes();
  await createCompleteWithdrawalHandler(fakePool({ fnError: err }))(
    mkReq({ params: { id: REQ_ID }, body: { payoutReference: 'FT2299' } }),
    res,
  );
  check('a duplicate payout reference is a 409, not a 500', res.code === 409);
  check('and is labelled so the UI can explain it', res.body.error_code === 'DUPLICATE_REFERENCE');
}

{
  const err = new Error('withdrawal ... would overdraw: won_balance 10 is below amount 250');
  err.code = '23514';
  const res = mkRes();
  await createCompleteWithdrawalHandler(fakePool({ fnError: err }))(
    mkReq({ params: { id: REQ_ID }, body: { payoutReference: 'FT2299' } }),
    res,
  );
  check('an overdraft or re-decide constraint is a 409', res.code === 409);
  check('and the operator is shown the actual message', /would overdraw/.test(res.body.error));
}

{
  const err = new Error('connection terminated');
  err.code = '08006';
  let threw = false;
  try {
    await createCompleteWithdrawalHandler(fakePool({ fnError: err }))(
      mkReq({ params: { id: REQ_ID }, body: { payoutReference: 'FT2299' } }),
      mkRes(),
    );
  } catch {
    threw = true;
  }
  check('an unrelated database error is NOT swallowed', threw === true);
}

{
  const res = mkRes();
  await createCompleteWithdrawalHandler(fakePool({ fnResult: { success: false, error_code: 'NOT_PENDING' } }))(
    mkReq({ params: { id: REQ_ID }, body: { payoutReference: 'FT2299' } }),
    res,
  );
  check('NOT_PENDING is a 409 — a double-click, not an error', res.code === 409);
}

// ---------------------------------------------------------------------------
console.log('\nPOST /admin/withdrawals/:id/reject');

{
  const res = mkRes();
  await createRejectWithdrawalHandler(fakePool())(mkReq({ params: { id: REQ_ID }, body: {} }), res);
  check('requires a reason — the player is shown it', res.code === 400);
}

{
  const pool = fakePool({ fnResult: { success: true, request_id: REQ_ID } });
  const res = mkRes();
  await createRejectWithdrawalHandler(pool)(
    mkReq({ params: { id: REQ_ID }, body: { reason: 'Account name does not match' } }),
    res,
  );
  check('rejects with 200', res.code === 200 && res.body.success === true);
  const call = pool.queries.find((q) => q.sql.includes('reject_bank_withdrawal'));
  check('passes the admin uid from the token', call.params[1] === UID);
}

// ---------------------------------------------------------------------------
console.log(failures === 0 ? '\nAll withdrawal tests passed\n' : `\n${failures} FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
