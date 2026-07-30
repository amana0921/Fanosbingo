/**
 * Tests for select-card.js.
 *
 * The assertions that matter are the two holes this route closes, and both are
 * checked by inspecting what actually reaches the database:
 *
 *   1. the identity passed to select_card_atomic comes from req.auth, and a
 *      telegramUserId in the BODY is ignored
 *   2. the card layout comes from get_or_create_card_layout, and a cardLayout in
 *      the BODY is ignored
 *
 * The second is the one worth having. select_card_atomic inserts p_card_numbers
 * straight into `players`, so a client that could choose its own layout could join
 * with a card made of numbers already called.
 *
 * Run: node src/select-card.test.mjs
 */

import {
  buildMarkedCells,
  displayName,
  statusForErrorCode,
  validateJoinRequest,
  createSelectCardHandler,
} from './select-card.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

const GAME = '15be4be3-0571-483f-9668-d21013034b24';
const SERVER_LAYOUT = [[1, 2, 3, 4, 5], [16, 17, 18, 19, 20], [31, 32, 0, 34, 35], [46, 47, 48, 49, 50], [61, 62, 63, 64, 65]];
const ATTACKER_LAYOUT = [[7, 7, 7, 7, 7], [7, 7, 7, 7, 7], [7, 7, 0, 7, 7], [7, 7, 7, 7, 7], [7, 7, 7, 7, 7]];

/** Records every query so the test can assert on what reached the database. */
function fakePool({ userRows, atomicResult }) {
  const queries = [];
  const client = {
    query: async (sql, params) => {
      queries.push({ sql, params });
      if (sql.includes('FROM telegram_users')) return { rows: userRows };
      if (sql.includes('get_or_create_card_layout')) return { rows: [{ layout: SERVER_LAYOUT }] };
      if (sql.includes('select_card_atomic')) return { rows: [{ result: atomicResult }] };
      return { rows: [] };
    },
    released: false,
    release() { this.released = true; },
  };
  return { pool: { connect: async () => client }, queries, client };
}

const mkRes = () => ({
  code: null, body: null,
  status(c) { this.code = c; return this; },
  json(b) { this.body = b; return this; },
});

const USER = [{
  telegram_user_id: 424946351,
  telegram_username: 'victim',
  telegram_first_name: 'V',
  telegram_last_name: null,
}];

console.log('\nbuildMarkedCells');
{
  const m = buildMarkedCells();
  check('is 5x5', m.length === 5 && m.every((c) => c.length === 5));
  check('only the centre starts marked', m[2][2] === true && m.flat().filter(Boolean).length === 1);
}

console.log('\ndisplayName');
check('prefers @username', displayName({ telegram_username: 'bob', telegram_first_name: 'B' }) === '@bob');
check('falls back to first name', displayName({ telegram_first_name: 'B' }) === 'B');
check('falls back again rather than showing undefined', displayName({}) === 'Player');

console.log('\nvalidateJoinRequest');
check('rejects a non-uuid gameId', validateJoinRequest({ gameId: 'nope', cardNumber: 1 }).ok === false);
check('rejects a missing gameId', validateJoinRequest({ cardNumber: 1 }).ok === false);
check('rejects card number 0', validateJoinRequest({ gameId: GAME, cardNumber: 0 }).ok === false);
check('rejects card number 401', validateJoinRequest({ gameId: GAME, cardNumber: 401 }).ok === false);
check('rejects a non-integer card number', validateJoinRequest({ gameId: GAME, cardNumber: 1.5 }).ok === false);
check('rejects a string card number', validateJoinRequest({ gameId: GAME, cardNumber: '5' }).ok === false);
check('accepts a valid pair', validateJoinRequest({ gameId: GAME, cardNumber: 42 }).ok === true);

console.log('\nstatusForErrorCode');
check('CARD_TAKEN is 409, so a client can retry', statusForErrorCode('CARD_TAKEN') === 409);
check('INSUFFICIENT_BALANCE is 402', statusForErrorCode('INSUFFICIENT_BALANCE') === 402);
check('GAME_NOT_FOUND is 404', statusForErrorCode('GAME_NOT_FOUND') === 404);
check('SELECTION_CLOSED is 409', statusForErrorCode('SELECTION_CLOSED') === 409);
check('INTERNAL_ERROR is 500', statusForErrorCode('INTERNAL_ERROR') === 500);
check('an unknown code is not 200', statusForErrorCode('SOMETHING_NEW') !== 200);

console.log('\ncreateSelectCardHandler — the two holes it closes');
{
  const { pool, queries, client } = fakePool({
    userRows: USER,
    atomicResult: { success: true, player_id: 'p1', card_number: 42 },
  });

  const req = {
    auth: { uid: '00000000-0000-4000-8000-000000000001', telegramUserId: '424946351' },
    // Everything an attacker would put here:
    body: {
      gameId: GAME,
      cardNumber: 42,
      telegramUserId: 999000111,          // someone else's account
      playerName: '@notme',
      telegramUsername: 'notme',
      cardLayout: ATTACKER_LAYOUT,        // a card of all-sevens
    },
    log: { warn: () => {} },
  };
  const res = mkRes();

  await createSelectCardHandler(pool)(req, res);

  check('a valid join answers 200', res.code === 200);
  check('and returns the function result', res.body?.success === true);

  const userLookup = queries.find((q) => q.sql.includes('FROM telegram_users'));
  check('the player is looked up by req.auth.uid', userLookup?.params?.[0] === req.auth.uid);

  const atomic = queries.find((q) => q.sql.includes('select_card_atomic'));
  check(
    'identity sent to the database is the VERIFIED one, not the body',
    atomic?.params?.[2] === 424946351,
  );
  check(
    'the body telegramUserId (999000111) appears nowhere in the call',
    !atomic?.params?.includes(999000111),
  );
  check(
    'the layout sent is the SERVER layout',
    atomic?.params?.[5] === JSON.stringify(SERVER_LAYOUT),
  );
  check(
    'the attacker layout is not sent anywhere',
    !JSON.stringify(atomic?.params).includes('[7,7,7,7,7]'),
  );
  check(
    'the display name is derived from the stored row, not the body',
    atomic?.params?.[3] === '@victim',
  );
  check('the layout is fetched by card number',
    queries.find((q) => q.sql.includes('get_or_create_card_layout'))?.params?.[0] === 42);
  check('the connection is released', client.released === true);
}

console.log('\ncreateSelectCardHandler — refusals');
{
  for (const [code, expected] of [['CARD_TAKEN', 409], ['INSUFFICIENT_BALANCE', 402], ['GAME_NOT_FOUND', 404]]) {
    const { pool } = fakePool({ userRows: USER, atomicResult: { success: false, error_code: code } });
    const res = mkRes();
    await createSelectCardHandler(pool)(
      { auth: { uid: 'u' }, body: { gameId: GAME, cardNumber: 1 }, log: { warn: () => {} } },
      res,
    );
    check(`${code} -> ${expected}`, res.code === expected);
  }
}

console.log('\ncreateSelectCardHandler — edges');
{
  const { pool, client } = fakePool({ userRows: [], atomicResult: null });
  const res = mkRes();
  await createSelectCardHandler(pool)(
    { auth: { uid: 'gone' }, body: { gameId: GAME, cardNumber: 1 }, log: { warn: () => {} } },
    res,
  );
  check('a token for a deleted player is 409, not 500', res.code === 409);
  check('and the connection is still released', client.released === true);
}
{
  const { pool } = fakePool({ userRows: USER, atomicResult: null });
  const res = mkRes();
  await createSelectCardHandler(pool)(
    { auth: { uid: 'u' }, body: { gameId: 'not-a-uuid', cardNumber: 1 }, log: { warn: () => {} } },
    res,
  );
  check('a bad gameId is 400 and never reaches the database', res.code === 400);
}

console.log(failures ? `\n${failures} assertion(s) failed.` : '\nAll assertions passed.');
process.exit(failures ? 1 : 0);
