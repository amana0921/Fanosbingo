/**
 * Authentication: turning a Telegram identity into a database identity.
 *
 * THE ARCHITECTURAL POINT, because it is the whole reason this service exists.
 *
 * The inherited edge functions each built a Supabase client with
 * SERVICE_ROLE_KEY and took the caller's identity from the request body. Two
 * consequences, both bad:
 *
 *   - service_role BYPASSES row-level security, so all 47 RLS policies in the
 *     migrations protected nothing on those paths. The database's authorization
 *     model was present, correct, and completely unused.
 *   - identity was asserted, not proven. `{"from_telegram_id": 12345}` was
 *     taken at face value.
 *
 * So authorization depended on every handler remembering to check, forever, in
 * every future change. That is not a security model; it is a hope.
 *
 * This flips it. A player proves who they are ONCE, here, and receives a
 * short-lived JWT. Every subsequent request goes to PostgREST as the
 * `authenticated` role carrying that token, PostgREST puts the claims in the
 * request.jwt.claims GUC, and auth.uid() returns the player's uuid. RLS then
 * enforces authorization in the database, on every query, whether or not
 * anybody remembered.
 *
 * THE CLAIMS ARE NOT ARBITRARY. db/00-bootstrap/001 defines:
 *
 *   auth.uid()  -> request.jwt.claims ->> 'sub', cast to UUID
 *   auth.role() -> request.jwt.claims ->> 'role'
 *
 * `sub` must therefore be telegram_users.id, the UUID -- NOT telegram_user_id,
 * which is the Telegram bigint. Putting the bigint there makes the uuid cast
 * fail and every policy match nothing, which presents as "the app loads but all
 * the data is empty" rather than as an error.
 */

import jwt from 'jsonwebtoken';
import { verifyInitData } from './telegram-auth.js';

/** Short. A stolen token should stop working before it is useful. */
const TOKEN_TTL_SECONDS = 15 * 60;

/**
 * Exchange a Telegram initData payload for a database-scoped JWT.
 *
 * Creates the player row on first sight -- a Mini App user has no separate
 * signup, and the alternative is a first-run failure nobody can act on.
 *
 * @param {import('pg').Pool} pool
 * @param {string} initData raw payload from Telegram.WebApp.initData
 * @param {string} botToken
 * @param {string} jwtSecret shared with PostgREST and Realtime via SSM
 */
export async function authenticateTelegram(pool, initData, botToken, jwtSecret) {
  const verified = await verifyInitData(initData, botToken);

  if (!verified.ok) {
    // The caller gets a generic failure; the reason is logged. A prober should
    // not learn WHICH part of their forgery was wrong.
    return { ok: false, status: 401, reason: verified.reason };
  }

  const tg = verified.user;

  // ON CONFLICT so a returning player updates rather than collides, and so two
  // simultaneous first requests cannot race into a duplicate.
  //
  // Deliberately does NOT touch balance: that column has a default for new
  // rows, and an upsert that reset it on every login would erase winnings.
  const { rows } = await pool.query(
    `INSERT INTO telegram_users
       (telegram_user_id, telegram_username, telegram_first_name, telegram_last_name)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (telegram_user_id) DO UPDATE
       SET telegram_username   = EXCLUDED.telegram_username,
           telegram_first_name = EXCLUDED.telegram_first_name,
           telegram_last_name  = EXCLUDED.telegram_last_name,
           last_active_at      = now()
     RETURNING id, telegram_user_id, telegram_username, telegram_first_name`,
    [tg.id, tg.username ?? null, tg.first_name ?? 'Player', tg.last_name ?? null],
  );

  const user = rows[0];

  const token = jwt.sign(
    {
      // Read by auth.uid(). MUST be the uuid -- see the header.
      sub: user.id,
      // Read by auth.role(). The RLS policies name this role explicitly.
      role: 'authenticated',
      // Convenience for handlers that need the Telegram id without a lookup.
      telegram_user_id: String(user.telegram_user_id),
    },
    jwtSecret,
    { expiresIn: TOKEN_TTL_SECONDS, algorithm: 'HS256' },
  );

  return {
    ok: true,
    token,
    expires_in: TOKEN_TTL_SECONDS,
    user: {
      id: user.id,
      telegram_user_id: String(user.telegram_user_id),
      username: user.telegram_username,
      first_name: user.telegram_first_name,
    },
  };
}

/**
 * Express middleware requiring a token this service issued.
 *
 * Verifies the SAME secret PostgREST verifies with, so a token accepted here is
 * accepted there and vice versa. If those ever diverge, a player is
 * authenticated for the API and rejected by the data layer -- or worse, the
 * reverse.
 *
 * Sets req.auth = { uid, telegramUserId, role }. Handlers must use req.auth.uid
 * and never a user id from the request body; taking identity from the body is
 * the exact defect this service exists to remove.
 */
export function requireAuth(jwtSecret) {
  return (req, res, next) => {
    const header = req.get('authorization') ?? '';
    const [scheme, token] = header.split(' ');

    if (scheme?.toLowerCase() !== 'bearer' || !token) {
      return res.status(401).json({ error: 'missing bearer token' });
    }

    try {
      const claims = jwt.verify(token, jwtSecret, { algorithms: ['HS256'] });

      req.auth = {
        uid: claims.sub,
        telegramUserId: claims.telegram_user_id,
        role: claims.role,
      };

      return next();
    } catch (err) {
      // Distinguish expiry from forgery in the LOG, not in the response: a
      // client needs to know to re-authenticate, an attacker needs nothing.
      req.log?.warn?.({ event: 'auth_rejected', reason: err.message });

      return res
        .status(401)
        .json({ error: 'invalid token', expired: err.name === 'TokenExpiredError' });
    }
  };
}
