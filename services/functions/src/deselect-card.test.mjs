/**
 * Tests for deselect-card.js.
 *
 * The assertions that matter:
 *
 *   - the telegram id passed to release_card comes from the TOKEN. The
 *     inherited call site sent it in the request BODY alongside the anon key,
 *     so a test that pins this is the difference between the route being a fix
 *     and being a port of the defect.
 *   - GAME_STARTED and SELECTION_CLOSED are 409, not 403. They mean the lobby
 *     moved on while the request was in flight; the client should re-render,
 *     not tell the player they lack permission.
 *   - NOT_YOURS is 403 and stays distinct from NOT_FOUND.
 *
 * Run: node src/deselect-card.test.mjs
 */

import { statusForReleaseError, createDeselectCardHandler } from './deselect-card.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

const UID = '81f73524-2cd8-4f9b-ac38-dd71cdfd56e7';
const TG = '7391104822';
const PLAYER = '33333333-3333-4333-8333-333333333333';

function fakePool(fnResult) {
  const queries = [];
  return {
    queries,
    query: async (sql, params) => {
      queries.push({ sql, params });
      return { rows: [{ result: fnResult }] };
    },
  };
}

const mkRes = () => ({
  code: 200,
  body: null,
  status(c) { this.code = c; return this; },
  json(b) { this.body = b; return this; },
});

const mkReq = (over = {}) => ({
  auth: { uid: UID, telegramUserId: TG },
  body: { playerId: PLAYER },
  log: { warn: () => {}, error: () => {} },
  ...over,
});

console.log('\nstatusForReleaseError');
check('NOT_FOUND -> 404', statusForReleaseError('NOT_FOUND') === 404);
check('NOT_YOURS -> 403', statusForReleaseError('NOT_YOURS') === 403);
check('GAME_STARTED -> 409, not 403', statusForReleaseError('GAME_STARTED') === 409);
check('SELECTION_CLOSED -> 409', statusForReleaseError('SELECTION_CLOSED') === 409);
check('anything else -> 400', statusForReleaseError('INVALID_ARGUMENTS') === 400);

console.log('\nPOST /deselect-card');

{
  const pool = fakePool({ success: true, player_id: PLAYER, card_number: 42 });
  const res = mkRes();
  await createDeselectCardHandler(pool)(mkReq(), res);
  check('releases with 200', res.code === 200 && res.body.success === true);

  const call = pool.queries[0];
  check('passes the telegram id from the TOKEN', call.params[0] === TG);
  check('passes the player id from the body', call.params[1] === PLAYER);
}

{
  // The defining test: a body naming someone else must change nothing.
  const pool = fakePool({ success: true });
  await createDeselectCardHandler(pool)(
    mkReq({ body: { playerId: PLAYER, telegramUserId: '999', telegram_user_id: '999' } }),
    mkRes(),
  );
  check('ignores a telegramUserId supplied in the body', pool.queries[0].params[0] === TG);
}

{
  const res = mkRes();
  await createDeselectCardHandler(fakePool({}))(mkReq({ body: { playerId: 'nope' } }), res);
  check('rejects a non-uuid playerId', res.code === 400);
}

{
  const res = mkRes();
  await createDeselectCardHandler(fakePool({}))(
    mkReq({ auth: { uid: UID, telegramUserId: 'not-a-number' } }),
    res,
  );
  check('rejects a token with a non-numeric telegram id', res.code === 400);
}

{
  const res = mkRes();
  await createDeselectCardHandler(fakePool({ success: false, error_code: 'NOT_YOURS' }))(mkReq(), res);
  check('NOT_YOURS is a 403', res.code === 403);
}

{
  const res = mkRes();
  await createDeselectCardHandler(
    fakePool({ success: false, error_code: 'GAME_STARTED', status: 'playing' }),
  )(mkReq(), res);
  check('GAME_STARTED is a 409 the lobby can act on', res.code === 409);
  check('and carries the status back', res.body.status === 'playing');
}

{
  const res = mkRes();
  await createDeselectCardHandler(fakePool({ success: false, error_code: 'SELECTION_CLOSED' }))(
    mkReq(),
    res,
  );
  check('SELECTION_CLOSED is a 409', res.code === 409);
}

{
  const res = mkRes();
  await createDeselectCardHandler(fakePool(undefined))(mkReq(), res);
  check('a null result is refused rather than reported as success', res.code === 400 && res.body.success === false);
}

console.log(failures === 0 ? '\nAll deselect-card tests passed\n' : `\n${failures} FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
