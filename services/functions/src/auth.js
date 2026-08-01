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
 * @param {{check: (key: string|number) => {allowed: boolean, retryAfterSeconds: number}}} [limiter]
 *        Optional. See src/rate-limit.js for why the key is the telegram id and
 *        not the IP address.
 */
export async function authenticateTelegram(pool, initData, botToken, jwtSecret, limiter) {
  const verified = await verifyInitData(initData, botToken);

  if (!verified.ok) {
    // The caller gets a generic failure; the reason is logged. A prober should
    // not learn WHICH part of their forgery was wrong.
    //
    // Deliberately NOT rate limited: there is no trustworthy key for a request
    // that failed verification, and the only alternative -- the source IP -- is
    // shared by many players behind carrier NAT. These are also cheap: an HMAC
    // over a short payload, no database, no pool connection.
    return { ok: false, status: 401, reason: verified.reason };
  }

  const tg = verified.user;

  // RATE LIMIT HERE: after the HMAC proved who this is, before the write.
  //
  // This ordering is the point. The identity is now trustworthy, so the limit
  // cannot be evaded by changing address and cannot punish a player for sharing
  // one. And it is still ahead of the INSERT, which is the expensive part -- the
  // pool is max: 5, and exhausting it stalls the ticker's queries too, turning a
  // login flood into a frozen game rather than merely slow logins.
  if (limiter) {
    const verdict = limiter.check(tg.id);
    if (!verdict.allowed) {
      return {
        ok: false,
        status: 429,
        retryAfterSeconds: verdict.retryAfterSeconds,
        reason: 'rate limited',
        telegramUserId: tg.id,
      };
    }
  }

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
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function requireAuth(jwtSecret) {
  return (req, res, next) => {
    const header = req.get('authorization') ?? '';
    const [scheme, token] = header.split(' ');

    if (scheme?.toLowerCase() !== 'bearer' || !token) {
      return res.status(401).json({ error: 'missing bearer token' });
    }

    try {
      const claims = jwt.verify(token, jwtSecret, { algorithms: ['HS256'] });

      // A VALID SIGNATURE IS NOT AN IDENTITY.
      //
      // This used to accept any token this secret had signed. The ANON KEY is
      // such a token: scripts/mint-anon-key.mjs signs it with the same secret,
      // because PostgREST verifies both with one key. Its claims are
      //
      //     {"role":"anon","iss":"fanosbingo","iat":...}
      //
      // -- no `sub`, and no `exp`, so it never expires. And it is PUBLIC by
      // design: .env.example says so, and it is baked into every SPA bundle
      // where anyone can read it.
      //
      // So the public, permanent anon key passed this gate on every requireAuth
      // route, arriving as `uid: undefined` with role `anon`. The comment in
      // .env.example -- "it grants only what RLS allows anonymous users to see"
      // -- is true of PostgREST, where role=anon maps to the anon DATABASE role
      // and policies decide. It was never true here: this service reads
      // req.auth.uid and passes it to SECURITY DEFINER functions that assume it
      // identifies somebody.
      //
      // getAccessToken() makes it worse rather than academic: it FALLS BACK to
      // the anon key when Telegram authentication fails, so the SPA itself sends
      // it to authenticated routes from any browser outside Telegram.
      //
      // Two claims are therefore required, not one. `role` must be the one
      // auth.js issues, and `sub` must be the uuid it puts there -- the same
      // uuid auth.uid() casts to, and the same one db/20-post/004 scoped
      // telegram_users by.
      if (claims.role !== 'authenticated' || !UUID_RE.test(claims.sub ?? '')) {
        req.log?.warn?.({
          event: 'auth_rejected',
          reason: 'not a player token',
          role: claims.role ?? null,
          has_sub: Boolean(claims.sub),
        });
        return res.status(401).json({ error: 'invalid token' });
      }

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
