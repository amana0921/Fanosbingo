/**
 * Tests for claim-bingo.js.
 *
 * The assertion that matters is ownership: a player id belonging to somebody else
 * must be refused BEFORE atomic_claim_bingo is called. That function validates the
 * winning pattern, so this is not a way to invent a win — but it is a way to spend
 * a rival's single claim, and a losing claim disqualifies them.
 *
 * Run: node src/claim-bingo.test.mjs
 */

import { validateClaimRequest, statusForClaim, createClaimBingoHandler } from './claim-bingo.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

const MINE = '11111111-1111-4111-8111-111111111111';
const THEIRS = '22222222-2222-4222-8222-222222222222';
const UID = '81f73524-2cd8-4f9b-ac38-dd71cdfd56e7';

function fakePool({ owns, claimResult }) {
  const queries = [];
  const client = {
    query: async (sql, params) => {
      queries.push({ sql, params });
      if (sql.includes('FROM players')) {
        return { rows: owns ? [{ id: params[0] }] : [] };
      }
      if (sql.includes('atomic_claim_bingo')) return { rows: [{ result: claimResult }] };
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
const mkReq = (playerId, extra = {}) => ({
  auth: { uid: UID, telegramUserId: '424946351' },
  body: { playerId, claimId: 'client-side-dedup-token', ...extra },
  log: { warn: () => {} },
});

console.log('\nvalidateClaimRequest');
check('rejects a missing playerId', validateClaimRequest({}).ok === false);
check('rejects a non-uuid playerId', validateClaimRequest({ playerId: 'x' }).ok === false);
check('accepts a uuid', validateClaimRequest({ playerId: MINE }).ok === true);
check('tolerates the client-side claimId it does not use',
  validateClaimRequest({ playerId: MINE, claimId: 'abc' }).ok === true);

console.log('\nstatusForClaim');
check('a win is 200', statusForClaim({ success: true }) === 200);
check('no winning pattern is 409, not 500',
  statusForClaim({ success: false, error: 'No winning pattern found' }) === 409);
check('player not found is 404',
  statusForClaim({ success: false, error: 'Player not found' }) === 404);
check('disqualified is 403',
  statusForClaim({ success: false, error: 'Player is disqualified' }) === 403);
check('a null result is not 200', statusForClaim(null) !== 200);

console.log('\ncreateClaimBingoHandler — ownership');
{
  // Somebody else's player row.
  const { pool, queries, client } = fakePool({ owns: false, claimResult: { success: true } });
  const res = mkRes();
  await createClaimBingoHandler(pool)(mkReq(THEIRS), res);

  check("claiming for another player's row is 403", res.code === 403);
  check(
    'and atomic_claim_bingo was NEVER called',
    !queries.some((q) => q.sql.includes('atomic_claim_bingo')),
  );
  check('the refusal does not reveal whether the player exists',
    res.body?.error === 'not your player');
  check('the connection is released', client.released === true);
}
{
  // Own row, winning claim.
  const { pool, queries, client } = fakePool({
    owns: true,
    claimResult: { success: true, is_winner: true, prize: 100 },
  });
  const res = mkRes();
  await createClaimBingoHandler(pool)(mkReq(MINE), res);

  check('claiming for your own row is allowed', res.code === 200);
  check('and returns the function result', res.body?.success === true);

  const own = queries.find((q) => q.sql.includes('FROM players'));
  check('ownership is checked against the token uuid, not the body',
    own?.params?.[1] === UID);
  check('ownership is checked for the requested row', own?.params?.[0] === MINE);

  const claim = queries.find((q) => q.sql.includes('atomic_claim_bingo'));
  check('the claim is made for that row', claim?.params?.[0] === MINE);
  check('the connection is released', client.released === true);
}
{
  // Own row, losing claim.
  const { pool } = fakePool({
    owns: true,
    claimResult: { success: false, error: 'No winning pattern found' },
  });
  const res = mkRes();
  await createClaimBingoHandler(pool)(mkReq(MINE), res);
  check('a losing claim is 409 and reports why', res.code === 409 && res.body?.success === false);
}
{
  const { pool, queries } = fakePool({ owns: true, claimResult: null });
  const res = mkRes();
  await createClaimBingoHandler(pool)(mkReq('not-a-uuid'), res);
  check('a bad playerId is 400 and reaches no query',
    res.code === 400 && queries.length === 0);
}

console.log(failures ? `\n${failures} assertion(s) failed.` : '\nAll assertions passed.');
process.exit(failures ? 1 : 0);
