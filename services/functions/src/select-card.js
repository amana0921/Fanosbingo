/**
 * POST /select-card — joining a game.
 *
 * WHY THIS ROUTE EXISTS AT ALL, given the rule that plain data access belongs in
 * PostgREST: joining deducts a stake. `select_card_atomic` is SECURITY DEFINER,
 * takes the player's identity as an ordinary parameter, and does not check it —
 * so exposing it directly through PostgREST would let any caller join a game as
 * anybody else and spend their balance. db/20-post/004 revoked EXECUTE on it from
 * `anon` and `authenticated` for exactly that reason. This route is the only
 * caller, and it supplies the identity the token proved.
 *
 * IT ALSO CLOSES A SECOND HOLE, which is not obvious from the 404 it replaces.
 *
 * The Mini App used to POST this:
 *
 *   { gameId, cardNumber, telegramUserId, playerName,
 *     telegramUsername, telegramFirstName, telegramLastName, cardLayout }
 *
 * Two of those fields are the caller describing themselves — `telegramUserId` is
 * the identity, asserted not proven, which is the defect services/functions/src/auth.js
 * exists to remove. And `cardLayout` is THE PLAYER CHOOSING THEIR OWN BINGO CARD.
 * `select_card_atomic` inserts `p_card_numbers` straight into `players`, so a
 * crafted request could join with a card made entirely of numbers already called
 * — an instant, unfalsifiable win.
 *
 * Nothing here is taken from the body except the game and the card NUMBER:
 *
 *   identity      req.auth  — the verified JWT, never the body
 *   display name  telegram_users, looked up by that identity
 *   card layout   get_or_create_card_layout(cardNumber), server-side and
 *                 deterministic. The same card number always yields the same
 *                 board, for everyone, permanently.
 *
 * The client keeps choosing a card NUMBER, which is the actual game decision. It
 * no longer chooses what is printed on it.
 */

/** The centre square is free in bingo, so it starts marked. */
export function buildMarkedCells() {
  return Array.from({ length: 5 }, (_, col) =>
    Array.from({ length: 5 }, (_, row) => col === 2 && row === 2),
  );
}

/**
 * Display name, derived the same way the Mini App used to derive it — but from
 * the row the server stores rather than from what the caller claims to be called.
 */
export function displayName(user) {
  if (user?.telegram_username) return `@${user.telegram_username}`;
  return user?.telegram_first_name || 'Player';
}

/**
 * Map select_card_atomic's error_code to HTTP.
 *
 * All of these are `success: false` from a function that ran correctly, so
 * answering 500 would be wrong — and answering 200 would make a client treat a
 * refused join as a successful one. The distinction matters most for CARD_TAKEN,
 * which is the normal outcome of two players tapping the same number at once and
 * must be retryable rather than fatal.
 */
export function statusForErrorCode(code) {
  switch (code) {
    case 'GAME_NOT_FOUND':
      return 404;
    case 'USER_NOT_FOUND':
      // The token verified, so the player exists as far as auth is concerned;
      // their row not being there is a server-side inconsistency, not a bad
      // request.
      return 409;
    case 'CARD_TAKEN':
    case 'GAME_NOT_WAITING':
    case 'SELECTION_CLOSED':
      return 409;
    case 'INSUFFICIENT_BALANCE':
      return 402;
    case 'INTERNAL_ERROR':
      return 500;
    default:
      return 409;
  }
}

/** A uuid, loosely — enough to reject obvious rubbish before it reaches Postgres. */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Validate what the client IS allowed to choose.
 *
 * Card numbers are bounded 1–400 here as well as inside
 * get_or_create_card_layout, which RAISEs outside that range. Checking first
 * turns a 500 from an uncaught exception into a 400 that says what was wrong.
 */
export function validateJoinRequest(body) {
  const gameId = body?.gameId;
  const cardNumber = body?.cardNumber;

  if (typeof gameId !== 'string' || !UUID_RE.test(gameId)) {
    return { ok: false, error: 'gameId must be a uuid' };
  }
  if (!Number.isInteger(cardNumber) || cardNumber < 1 || cardNumber > 400) {
    return { ok: false, error: 'cardNumber must be an integer between 1 and 400' };
  }
  return { ok: true, gameId, cardNumber };
}

/**
 * Express handler factory.
 *
 * Takes the pool rather than importing it, so the route is testable against a
 * fake and so index.js keeps owning connection configuration.
 */
export function createSelectCardHandler(pool) {
  return async function selectCard(req, res) {
    const parsed = validateJoinRequest(req.body);
    if (!parsed.ok) {
      return res.status(400).json({ success: false, error: parsed.error });
    }

    const { gameId, cardNumber } = parsed;

    // One connection for all three statements. They are not in an explicit
    // transaction because select_card_atomic does its own locking internally --
    // wrapping it would hold the layout lookup's snapshot open across the join
    // for no benefit.
    const client = await pool.connect();

    try {
      // The player, by the identity the token proved. NOT by anything in the body.
      const { rows: userRows } = await client.query(
        `SELECT telegram_user_id, telegram_username, telegram_first_name, telegram_last_name
           FROM telegram_users
          WHERE id = $1`,
        [req.auth.uid],
      );

      if (userRows.length === 0) {
        // The token verified against a player row that no longer exists.
        req.log?.warn?.({ event: 'join_no_player_row', uid: req.auth.uid });
        return res.status(409).json({ success: false, error: 'player not found' });
      }

      const user = userRows[0];

      // The board, derived server-side. Deterministic per card number.
      const { rows: layoutRows } = await client.query(
        'SELECT get_or_create_card_layout($1) AS layout',
        [cardNumber],
      );

      const layout = layoutRows[0]?.layout;
      if (!layout) {
        return res.status(500).json({ success: false, error: 'card layout unavailable' });
      }

      const markedCells = buildMarkedCells();

      const { rows } = await client.query(
        `SELECT select_card_atomic($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) AS result`,
        [
          gameId,
          cardNumber,
          user.telegram_user_id,
          displayName(user),
          JSON.stringify(layout),
          JSON.stringify(layout),
          JSON.stringify(markedCells),
          user.telegram_username,
          user.telegram_first_name,
          user.telegram_last_name,
        ],
      );

      const result = rows[0]?.result ?? { success: false, error_code: 'INTERNAL_ERROR' };

      if (result.success) {
        return res.status(200).json(result);
      }

      // Logged with the code so a spike in CARD_TAKEN (contention) is
      // distinguishable from a spike in INSUFFICIENT_BALANCE (players out of
      // funds), which are very different problems wearing the same 409.
      req.log?.warn?.({
        event: 'join_refused',
        error_code: result.error_code,
        card_number: cardNumber,
      });

      return res.status(statusForErrorCode(result.error_code)).json(result);
    } finally {
      client.release();
    }
  };
}
