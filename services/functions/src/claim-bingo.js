/**
 * POST /claim-bingo — claiming a win.
 *
 * The other half of making the game playable. `select-card` let players in;
 * without this, a completed card could not be claimed, and the route answered 404.
 *
 * WHY IT IS NOT IN PostgREST: `atomic_claim_bingo` is SECURITY DEFINER, it decides
 * who won and how the pot is split, and db/20-post/004 revoked EXECUTE on it from
 * `anon` and `authenticated`. This route is its only caller.
 *
 * THE AUTHORIZATION QUESTION IS OWNERSHIP, NOT IDENTITY, and it is different from
 * select-card's.
 *
 * `atomic_claim_bingo` takes a `p_player_id` — a row in `players`, not a telegram
 * id. So "use the identity from the token" is not sufficient on its own: the
 * caller still names WHICH player row is claiming, and the Mini App sent that id
 * straight from the body with the anon key as authorization.
 *
 * That row must be checked to belong to the caller. Without it, any authenticated
 * player could submit a claim on behalf of any other player in any game. The
 * function itself would still validate the pattern, so this is not a way to invent
 * a win — but it IS a way to spend somebody else's single claim at a moment of
 * your choosing, and `atomic_claim_bingo` disqualifies a player whose claim does
 * not hold:
 *
 *   - a losing claim submitted for a rival marks THEM disqualified
 *   - a winning claim submitted early, before they had marked their card, closes
 *     the claim window on terms they did not choose
 *
 * Both are griefing rather than theft, which is why this is a 403 and not a
 * headline. It is still somebody else's game being played for them.
 *
 * So: the token says who you are, and the row is checked to be yours. The claim
 * itself is then the database's decision, as it should be.
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function validateClaimRequest(body) {
  const playerId = body?.playerId;
  if (typeof playerId !== 'string' || !UUID_RE.test(playerId)) {
    return { ok: false, error: 'playerId must be a uuid' };
  }
  // `claimId` is accepted and ignored. The Mini App sends it to deduplicate its
  // own retries; atomic_claim_bingo takes no such parameter, so it has never had
  // server-side meaning. Rejecting it would break a client that sends it.
  return { ok: true, playerId };
}

/**
 * Claim outcomes are not all failures.
 *
 * `atomic_claim_bingo` returns `success: false` both for "you have not won" and
 * for "this game is over", and neither is a server error. A 500 would be wrong; a
 * 200 would let a client show a win that did not happen.
 */
export function statusForClaim(result) {
  if (result?.success) return 200;

  const error = String(result?.error ?? '');

  if (error.includes('Player not found')) return 404;
  if (error.includes('disqualified')) return 403;
  // "No winning pattern", "Game is not playing", "Claim window closed" and
  // friends are all a refused claim on a working game.
  return 409;
}

export function createClaimBingoHandler(pool) {
  return async function claimBingo(req, res) {
    const parsed = validateClaimRequest(req.body);
    if (!parsed.ok) {
      return res.status(400).json({ success: false, error: parsed.error });
    }

    const { playerId } = parsed;
    const client = await pool.connect();

    try {
      // OWNERSHIP. Join players to telegram_users through the uuid the token
      // proved, so a row belonging to somebody else simply does not match.
      //
      // Compared on telegram_users.id -- the uuid in the `sub` claim -- rather
      // than on players.telegram_user_id against the token's convenience claim,
      // because `sub` is what auth.uid() and every RLS policy use, and mixing the
      // two identifiers is how the uuid-vs-bigint confusion documented in auth.js
      // gets reintroduced.
      const { rows: ownRows } = await client.query(
        `SELECT p.id
           FROM players p
           JOIN telegram_users u ON u.telegram_user_id = p.telegram_user_id
          WHERE p.id = $1 AND u.id = $2`,
        [playerId, req.auth.uid],
      );

      if (ownRows.length === 0) {
        // Deliberately does NOT distinguish "no such player" from "not yours".
        // Telling a caller which of the two it was turns this into an oracle for
        // enumerating player ids in other games.
        req.log?.warn?.({ event: 'claim_not_owned', player_id: playerId, uid: req.auth.uid });
        return res.status(403).json({ success: false, error: 'not your player' });
      }

      const { rows } = await client.query(
        'SELECT atomic_claim_bingo($1) AS result',
        [playerId],
      );

      const result = rows[0]?.result ?? { success: false, error: 'no result' };

      if (!result.success) {
        req.log?.warn?.({ event: 'claim_refused', reason: result.error, player_id: playerId });
      }

      return res.status(statusForClaim(result)).json(result);
    } finally {
      client.release();
    }
  };
}
