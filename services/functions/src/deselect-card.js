/**
 * Releasing a card you selected — the inverse of /select-card.
 *
 * src/components/Lobby.tsx has always offered this and it has always answered
 * 404: it POSTed the inherited Deno name /functions/v1/deselect-card, which the
 * rebuilt API never implemented. The route now exists.
 *
 * TWO THINGS THE OLD CALL SITE DID THAT THIS DOES NOT.
 *
 * It sent the ANON KEY as its bearer token, and `telegramUserId` in the request
 * body. That is identity asserted rather than proven -- the exact defect
 * services/functions/src/auth.js was written to remove, and the same shape
 * db/20-post/004 found in eight SECURITY DEFINER functions. Here the telegram id
 * comes from the verified JWT and the body carries only which player row to
 * release.
 *
 * WHY THE ROUTE EXISTS AT ALL, since the question AGENTS.md §7 asks of every 404
 * is "why can RLS not do this?":
 *
 *   Deleting a players row fires refund_player_stake(), which moves money, and
 *   it must only be allowed while selection is still open -- a condition that
 *   lives on the GAMES row, not the players row. An RLS policy can scope which
 *   rows you may delete; it cannot express that. db/20-post/011 does, under a
 *   row lock, and db/20-post/008 revoked the DELETE privilege that would
 *   otherwise let a client go around it.
 *
 * The window matters more than it looks. A release after the game has started is
 * a refund on a game you are already losing -- a free option on every round, and
 * one of the two exploits 008 closed.
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Error codes from release_card, mapped to what a client should do about them.
 *
 * GAME_STARTED and SELECTION_CLOSED are 409 rather than 403: the request was
 * legitimate when the player pressed the button and stopped being legitimate
 * while it was in flight. That is a conflict with state, and the right client
 * response is to re-render the lobby -- not to report a permissions problem the
 * player cannot act on.
 *
 * NOT_YOURS is 403 and deliberately not merged with NOT_FOUND. They are
 * different bugs: the first means the client sent someone else's player id,
 * which should never happen and is worth seeing in the logs.
 */
export function statusForReleaseError(code) {
  switch (code) {
    case 'NOT_FOUND':
      return 404;
    case 'NOT_YOURS':
      return 403;
    case 'GAME_STARTED':
    case 'SELECTION_CLOSED':
      return 409;
    default:
      return 400;
  }
}

/** POST /deselect-card  { playerId }  ->  release_card's result */
export function createDeselectCardHandler(pool) {
  return async function deselectCard(req, res) {
    const playerId = req.body?.playerId;

    if (typeof playerId !== 'string' || !UUID_RE.test(playerId)) {
      return res.status(400).json({ success: false, error: 'playerId must be a uuid' });
    }

    // A string in the claim, because a Telegram id exceeds what JSON numbers
    // represent exactly. node-pg passes it through as text and PostgreSQL casts;
    // checked here so a malformed token is a 400 rather than a cast error from
    // inside the function.
    const telegramUserId = req.auth?.telegramUserId;
    if (typeof telegramUserId !== 'string' || !/^[0-9]{1,19}$/.test(telegramUserId)) {
      return res.status(400).json({ success: false, error: 'token carries no telegram id' });
    }

    const { rows } = await pool.query('SELECT release_card($1, $2) AS result', [
      telegramUserId,
      playerId,
    ]);

    const result = rows[0]?.result ?? { success: false, error_code: 'INTERNAL_ERROR' };

    if (!result.success) {
      // NOT_YOURS is logged at warn: a correct client cannot produce it, so it
      // means either a bug or somebody trying player ids that are not theirs.
      const log = result.error_code === 'NOT_YOURS' ? req.log?.warn : req.log?.warn;
      log?.({
        event: 'release_refused',
        player_id: playerId,
        uid: req.auth.uid,
        reason: result.error_code,
      });
      return res.status(statusForReleaseError(result.error_code)).json(result);
    }

    req.log?.warn?.({
      event: 'card_released',
      player_id: playerId,
      uid: req.auth.uid,
      card_number: result.card_number,
    });

    return res.json(result);
  };
}
