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

import {
  verify as verifyTotp,
  generateSecret as generateTotpSecret,
  otpauthUri as totpUri,
} from './totp.js';

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

/**
 * POST /admin/games/:id/end
 *
 * Ending a game as an operator. Exists because db/20-post/008 revoked UPDATE on
 * `games` from the browser -- that privilege was what let any player set
 * winner_ids and have payout_winners() credit them.
 *
 * The route passes an id and the admin's proven uid, and NOTHING ELSE. It
 * deliberately accepts no winner or prize field from the request: admin_end_game
 * writes status and finished_at only, matching what game_tick() does, so a game
 * ended here pays out whatever atomic_claim_bingo already recorded and nothing
 * if nobody claimed. Accepting those columns here would rebuild the hole 008
 * closed, one authorization level up.
 */
export function createEndGameHandler(pool) {
  const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  return async function endGame(req, res) {
    const id = req.params?.id;
    if (typeof id !== 'string' || !UUID_RE.test(id)) {
      return res.status(400).json({ success: false, error: 'id must be a uuid' });
    }

    const { rows } = await pool.query('SELECT admin_end_game($1, $2) AS result', [
      id,
      req.auth.uid,
    ]);

    const result = rows[0]?.result ?? { success: false, error_code: 'INTERNAL_ERROR' };

    if (!result.success) {
      // NOT_ENDABLE covers "already finished" and "does not exist". A conflict,
      // not an error: it is what a double-clicked button produces.
      const code = result.error_code === 'NOT_ENDABLE' ? 409 : 400;
      req.log?.warn?.({ event: 'end_game_refused', game_id: id, reason: result.error_code });
      return res.status(code).json(result);
    }

    // Ending a game can trigger a payout. Logged at warn for the same reason the
    // deposit approval is.
    req.log?.warn?.({
      event: 'game_ended_by_admin',
      game_id: id,
      admin_uid: req.auth.uid,
      previous_status: result.previous_status,
    });

    return res.json(result);
  };
}

/**
 * POST /admin/settings  { key, value }
 *
 * Replaces the inherited update-settings route, which 404'd and which saved SIX
 * keys -- the first of them telegram_bot_token.
 *
 * That key is deliberately not writable. db/20-post/003 exists because
 * `curl /rest/v1/settings` returned a live bot token to an anonymous caller, and
 * it both excluded the key from the read allowlist AND redacted the stored
 * value. It is the HMAC key Telegram uses to sign initData, so holding it means
 * forging any player's identity. Porting the route faithfully would have written
 * a live one straight back into the table 003 cleared, while looking like a
 * feature being restored. It lives in SSM; rotating it is put-parameter plus a
 * redeploy.
 *
 * The allowlist is enforced by admin_update_setting(), not here. This validates
 * shape and reports; the database decides what may be written, so a second route
 * added later cannot widen it by forgetting.
 */
export function createUpdateSettingHandler(pool) {
  return async function updateSetting(req, res) {
    const key = typeof req.body?.key === 'string' ? req.body.key.trim() : '';
    const value = req.body?.value;

    if (!key) {
      return res.status(400).json({ success: false, error: 'key is required' });
    }

    // Values are presentation strings. Bounded so a paste accident cannot put a
    // megabyte into a row every player reads.
    if (typeof value !== 'string' || value.length > 4000) {
      return res
        .status(400)
        .json({ success: false, error: 'value must be a string of at most 4000 characters' });
    }

    const { rows } = await pool.query('SELECT admin_update_setting($1, $2, $3) AS result', [
      key,
      value,
      req.auth.uid,
    ]);

    const result = rows[0]?.result ?? { success: false, error_code: 'INTERNAL_ERROR' };

    if (!result.success) {
      // NOT_WRITABLE is a 403 rather than a 400: the request is well formed and
      // the key simply is not the operator's to change. The response names the
      // writable set, which is not a secret -- it is in db/20-post/013.
      const code = result.error_code === 'NOT_WRITABLE' ? 403 : 400;
      req.log?.warn?.({
        event: 'setting_write_refused',
        key,
        admin_uid: req.auth.uid,
        reason: result.error_code,
      });
      return res.status(code).json(result);
    }

    // commission_rate decides the prize/fee split, so a change to it is logged
    // with its value. The others are presentation and are logged by key only --
    // there is no reason to copy user_instructions into CloudWatch.
    req.log?.warn?.({
      event: 'setting_updated',
      key,
      admin_uid: req.auth.uid,
      ...(key === 'commission_rate' ? { value } : {}),
    });

    return res.json(result);
  };
}

/**
 * SECOND FACTOR, ON THE ACTION.
 *
 * Mounted after requireAdmin on the two operations that can invent or discharge
 * money: approving a deposit and completing a withdrawal. Not on the login, and
 * that is the design rather than an accident of where it was easy to put --
 * a factor presented once at sign-in leaves fifteen minutes of session in which
 * everything is single-factor again, and that window is exactly when the damage
 * happens. See db/20-post/016.
 *
 * NOT MOUNTED on reads, on ending a game, or on settings. Six digits per
 * approval is a real imposition on somebody clearing an overnight queue, and it
 * is worth paying only where the operation moves money.
 *
 * NOT ENFORCED UNTIL ENROLLED, deliberately. An operator who has not enrolled
 * keeps working exactly as before. Enforcing on an un-enrolled admin would lock
 * the queue the moment this deploys -- and a deposit queue that cannot be
 * cleared is the failure `deposits-waiting-too-long` exists to catch, caused by
 * the control meant to protect it. Enrolment is therefore a decision, and the
 * gap until it is made is stated rather than hidden.
 */
export function requireSecondFactor(pool) {
  return async function secondFactor(req, res, next) {
    const uid = req.auth?.uid;
    if (!uid) {
      req.log?.error?.({ event: 'second_factor_misconfigured' });
      return res.status(500).json({ error: 'route misconfigured' });
    }

    let row;
    try {
      const { rows } = await pool.query(
        'SELECT totp_secret, totp_confirmed_at FROM telegram_users WHERE id = $1',
        [uid],
      );
      row = rows[0];
    } catch (err) {
      req.log?.error?.({ event: 'second_factor_lookup_failed', error: err.message });
      return res.status(500).json({ error: 'internal error' });
    }

    // Not enrolled: proceed, and say so in the log every time. A gap that is
    // recorded on each use is one somebody eventually closes; a silent one is
    // one that is discovered afterwards.
    if (!row?.totp_secret || !row?.totp_confirmed_at) {
      req.log?.warn?.({ event: 'money_action_without_second_factor', admin_uid: uid, path: req.path });
      return next();
    }

    const token = req.get('X-Admin-TOTP') ?? req.body?.totp;

    if (!verifyTotp(row.totp_secret, typeof token === 'string' ? token.trim() : token)) {
      // 428, not 401 or 403. The caller IS authenticated and IS an admin -- the
      // request is refused because a precondition is unmet, and a client that
      // reads 401 as "log in again" would send the operator round a loop that
      // cannot fix anything.
      req.log?.warn?.({
        event: 'second_factor_rejected',
        admin_uid: uid,
        path: req.path,
        supplied: typeof token === 'string' && token.length > 0,
      });
      return res.status(428).json({
        error: 'second factor required',
        code: 'TOTP_REQUIRED',
      });
    }

    return next();
  };
}

/**
 * POST /admin/totp/enroll -> { secret, uri }
 *
 * Returns the secret ONCE, in the only response that will ever contain it.
 * db/20-post/016 revokes SELECT on the column from anon and authenticated, so
 * it cannot be read back through PostgREST afterwards -- which is the point: a
 * stolen session must not be able to read the second factor it is trying to
 * bypass.
 *
 * REFUSES TO OVERWRITE A CONFIRMED ENROLMENT. Otherwise this route is itself a
 * single-factor way to replace the second factor, which is the same as not
 * having one. Losing the phone is recovered by a human with database access,
 * through the SSM tunnel -- the same bar as becoming an admin in the first place.
 */
export function createTotpEnrollHandler(pool) {
  return async function totpEnroll(req, res) {
    const uid = req.auth.uid;

    try {
      const { rows } = await pool.query(
        'SELECT totp_confirmed_at FROM telegram_users WHERE id = $1',
        [uid],
      );

      if (rows[0]?.totp_confirmed_at) {
        return res.status(409).json({
          error: 'already enrolled',
          code: 'TOTP_ALREADY_ENROLLED',
        });
      }

      const secret = generateTotpSecret();

      // Confirmed_at stays null: a secret written but never proven is not
      // enforced, so an abandoned enrolment cannot lock the operator out.
      await pool.query(
        'UPDATE telegram_users SET totp_secret = $2, totp_confirmed_at = NULL WHERE id = $1',
        [uid, secret],
      );

      req.log?.warn?.({ event: 'totp_enrolment_started', admin_uid: uid });

      return res.json({
        secret,
        uri: totpUri(secret, `admin-${req.auth.telegramUserId}`),
      });
    } catch (err) {
      req.log?.error?.({ event: 'totp_enroll_failed', error: err.message });
      return res.status(500).json({ error: 'internal error' });
    }
  };
}

/**
 * POST /admin/totp/confirm { totp } -> { confirmed: true }
 *
 * Proves the operator can actually generate codes before anything starts
 * depending on it. Without this step an enrolment that was mis-scanned would
 * only be discovered at the moment somebody needed to approve a deposit.
 */
export function createTotpConfirmHandler(pool) {
  return async function totpConfirm(req, res) {
    const uid = req.auth.uid;
    const token = typeof req.body?.totp === 'string' ? req.body.totp.trim() : null;

    try {
      const { rows } = await pool.query(
        'SELECT totp_secret, totp_confirmed_at FROM telegram_users WHERE id = $1',
        [uid],
      );

      if (!rows[0]?.totp_secret) {
        return res.status(409).json({ error: 'not enrolled', code: 'TOTP_NOT_ENROLLED' });
      }
      if (rows[0].totp_confirmed_at) {
        return res.status(409).json({ error: 'already enrolled', code: 'TOTP_ALREADY_ENROLLED' });
      }
      if (!verifyTotp(rows[0].totp_secret, token)) {
        req.log?.warn?.({ event: 'totp_confirm_rejected', admin_uid: uid });
        return res.status(400).json({ error: 'invalid code', code: 'TOTP_INVALID' });
      }

      await pool.query(
        'UPDATE telegram_users SET totp_confirmed_at = now() WHERE id = $1',
        [uid],
      );

      req.log?.warn?.({ event: 'totp_enrolment_confirmed', admin_uid: uid });
      return res.json({ confirmed: true });
    } catch (err) {
      req.log?.error?.({ event: 'totp_confirm_failed', error: err.message });
      return res.status(500).json({ error: 'internal error' });
    }
  };
}
