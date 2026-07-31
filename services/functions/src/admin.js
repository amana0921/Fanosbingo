/**
 * Admin authorization.
 *
 * WHAT THIS REPLACES was not weak, it was absent. src/components/Admin.tsx
 * validated its access key by POSTing to /functions/v1/update-settings and
 * treating anything other than 401 as success. That route answers 404, because
 * it is one of the inherited Deno names the rebuilt service never implemented.
 * So any string logged you in, and the panel about to be given the ability to
 * credit player balances had no door on it at all.
 *
 * AN ADMIN IS A FLAG ON AN IDENTITY THIS SYSTEM ALREADY PROVED.
 *
 * Telegram signs initData with a key derived from the bot token, auth.js verifies
 * that HMAC, and the uuid in `sub` is the player. `is_admin` is a column on that
 * row. There is no second password to store, rotate or leak, and no second login
 * for an operator who is already authenticated in Telegram.
 *
 * It is SINGLE FACTOR and that is a real limitation, stated rather than implied:
 * whoever holds the Telegram account holds the admin API. An unlocked phone is
 * enough. This is chosen over the shared string it replaces, not over TOTP, and
 * it does not close the "Cognito with TOTP" item in the README.
 *
 * READ FROM THE DATABASE ON EVERY REQUEST, not carried in the JWT.
 *
 * Putting is_admin in the token would save a query and cost correctness:
 * revoking an admin would take up to the token's 15-minute lifetime to take
 * effect, and the window during which a removed operator can still credit
 * balances should be zero. Admin traffic is a handful of requests, so the lookup
 * is free in any sense that matters.
 */

/**
 * Express middleware. Chain AFTER requireAuth, which puts the proven identity on
 * req.auth.
 *
 * @param {import('pg').Pool} pool
 */
export function requireAdmin(pool) {
  return async function adminGate(req, res, next) {
    // Defensive: reaching here without req.auth means the route was wired
    // without requireAuth, which is a programming error rather than a rejected
    // request. Fail closed and say so loudly.
    if (!req.auth?.uid) {
      req.log?.error?.({ event: 'admin_route_without_auth', path: req.path });
      return res.status(500).json({ error: 'route misconfigured' });
    }

    try {
      const { rows } = await pool.query(
        'SELECT is_admin FROM telegram_users WHERE id = $1',
        [req.auth.uid],
      );

      if (rows.length === 0 || rows[0].is_admin !== true) {
        // 403, not 404. The caller proved who they are; they are simply not an
        // admin, and pretending the route does not exist would be a lie the
        // client cannot act on. Logged with the uid because an authenticated
        // non-admin probing admin routes is worth seeing.
        req.log?.warn?.({ event: 'admin_denied', uid: req.auth.uid, path: req.path });
        return res.status(403).json({ error: 'not an admin' });
      }

      return next();
    } catch (err) {
      req.log?.error?.({ event: 'admin_check_failed', error: err.message });
      return res.status(500).json({ error: 'internal error' });
    }
  };
}

/**
 * GET /admin/whoami — is the caller an admin?
 *
 * Exists so the Mini App can decide whether to render the admin entry point
 * without guessing, and so the gate can be tested end to end without a
 * money-moving side effect. The UI treating this as decorative is fine: every
 * admin route enforces requireAdmin server-side regardless of what the client
 * chose to display.
 */
export function createAdminWhoamiHandler(pool) {
  return async function adminWhoami(req, res) {
    const { rows } = await pool.query(
      'SELECT is_admin FROM telegram_users WHERE id = $1',
      [req.auth.uid],
    );
    return res.json({ uid: req.auth.uid, is_admin: rows[0]?.is_admin === true });
  };
}

/**
 * POST /admin/bootstrap  { key }  — promote the CALLER to admin.
 *
 * The chicken-and-egg step: admins are added by someone with database access,
 * which leaves nobody able to add the first one.
 *
 * THREE PROPERTIES MAKE THIS SAFE TO LEAVE DEPLOYED.
 *
 *   1. It only works while there are ZERO admins. It disarms itself the moment
 *      it succeeds, so it cannot be replayed to add a second admin, and a leaked
 *      key is worthless once the first admin exists.
 *   2. It promotes ONLY the authenticated caller. There is no parameter naming
 *      who to promote, so it cannot be used to grant admin to anyone else --
 *      which is the difference between a bootstrap and a backdoor.
 *   3. It requires a proven Telegram identity first, so "who bootstrapped" is a
 *      real person in the audit trail rather than an anonymous request.
 *
 * The key is compared in constant time. A short-circuiting === leaks the length
 * of the shared prefix to anyone willing to measure, and this is the one place
 * where a timing signal would be worth an attacker's effort.
 */
export function createAdminBootstrapHandler(pool, bootstrapKey) {
  return async function adminBootstrap(req, res) {
    if (!bootstrapKey) {
      req.log?.error?.({ event: 'bootstrap_unconfigured' });
      return res.status(503).json({ error: 'bootstrap is not configured' });
    }

    const supplied = req.body?.key;
    if (typeof supplied !== 'string' || supplied.length === 0) {
      return res.status(400).json({ error: 'key is required' });
    }

    const { rows: existing } = await pool.query(
      'SELECT count(*)::int AS n FROM telegram_users WHERE is_admin',
    );

    if (existing[0].n > 0) {
      // Deliberately does not say whether the key was right. Once an admin
      // exists this route is closed, and confirming a correct key here would
      // turn a disarmed endpoint into an oracle for testing keys.
      req.log?.warn?.({ event: 'bootstrap_after_admin_exists', uid: req.auth.uid });
      return res.status(409).json({ error: 'an admin already exists' });
    }

    if (!timingSafeEqual(supplied, bootstrapKey)) {
      req.log?.warn?.({ event: 'bootstrap_bad_key', uid: req.auth.uid });
      return res.status(403).json({ error: 'invalid key' });
    }

    // WHERE NOT EXISTS re-checks the zero-admin condition inside the statement,
    // so two simultaneous bootstrap requests cannot both succeed. The check
    // above is the fast path; this is the one that actually holds.
    const { rows } = await pool.query(
      `UPDATE telegram_users
          SET is_admin = true
        WHERE id = $1
          AND NOT EXISTS (SELECT 1 FROM telegram_users WHERE is_admin)
      RETURNING id, telegram_user_id`,
      [req.auth.uid],
    );

    if (rows.length === 0) {
      return res.status(409).json({ error: 'an admin already exists' });
    }

    req.log?.warn?.({
      event: 'admin_bootstrapped',
      uid: rows[0].id,
      telegram_user_id: String(rows[0].telegram_user_id),
    });

    return res.json({ ok: true, uid: rows[0].id, is_admin: true });
  };
}

/**
 * Constant-time string comparison.
 *
 * Compares every character regardless of where the first difference is, so the
 * time taken does not reveal the length of a correct prefix. The length check is
 * separate and deliberately NOT short-circuited into the loop -- lengths differing
 * is not secret, the contents are.
 */
export function timingSafeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  if (a.length !== b.length) return false;

  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}
