/**
 * In-process rate limiting for the authentication route.
 *
 * WHY THIS IS NOT DONE AT THE EDGE, where it belongs.
 *
 * It was meant to be. There is a Cloudflare rate-limiting rule for exactly this,
 * it applies cleanly, Cloudflare reports `enabled: true`, and it DOES NOT
 * ENFORCE -- measured 2026-07-30 with 160 requests from one IP to a covered path
 * across two bursts, zero blocked, and a path deliberately excluded from the
 * expression behaving identically. Cause unestablished; diagnosing it needs the
 * dashboard's rate-limiting analytics. See AGENTS.md §7.
 *
 * So the edge is not a control today, and /auth/telegram is the only
 * unauthenticated route on this service. This is the floor underneath it.
 *
 * THE KEY IS THE TELEGRAM USER ID, NOT THE IP ADDRESS, and that is the whole
 * design decision.
 *
 * Keying on ip.src is what the Cloudflare rule does and it is a poor fit for
 * this player base: they reach Telegram over Ethiopian mobile networks, where
 * large numbers of subscribers share a small pool of carrier-NAT addresses. "One
 * IP" is not one person, so any threshold low enough to stop a script is also
 * low enough to lock out players who did nothing but open the app during a busy
 * evening -- and the symptom is a login that fails for some users and not
 * others, with nothing wrong in the logs.
 *
 * A verified telegram_user_id has neither problem. It identifies one person
 * regardless of how many share an egress address, and it CANNOT BE FORGED: the
 * id is taken from initData only after its HMAC has been verified against the bot
 * token. An attacker who could mint arbitrary ids here would already hold the bot
 * token, at which point rate limiting is not the problem they present.
 *
 * WHERE THIS SITS IN THE REQUEST, and why:
 *
 *   verify HMAC  ->  RATE LIMIT  ->  INSERT/UPDATE telegram_users  ->  sign JWT
 *
 * After verification, because that is where a trustworthy key first exists.
 * Before the database write, because that is the expensive part -- the pool is
 * `max: 5` on a t4g.small shared with four other containers, and exhausting it
 * stalls the game loop's own queries, not just logins.
 *
 * WHAT THIS DELIBERATELY DOES NOT DO: limit requests whose initData FAILS
 * verification. Those have no trustworthy key, so the only option is IP, which
 * brings back the carrier-NAT problem to punish shared-address users for one bad
 * actor. They are also cheap -- an HMAC over a short payload, no database, no
 * pool connection -- and they now answer 401 rather than 500, so they no longer
 * trip Caddy's health check either. Volume abuse of that path is a job for the
 * edge, and it is honestly not covered while the edge rule is inert.
 *
 * SINGLE PROCESS, IN MEMORY. There is one instance and one container, so a
 * shared store would be complexity for nothing. At Stage 2 this becomes wrong --
 * two instances would each permit the full budget -- and the note in the header
 * of services/ticker/src/index.js about the advisory lock is the model to follow:
 * move the counter into PostgreSQL, or accept 2x and say so.
 */

/**
 * Fixed-window counter.
 *
 * Fixed window rather than a token bucket, because the failure mode being
 * prevented is "thousands of writes in a few seconds" and a fixed window stops
 * that with one integer per key. A bucket's smoother behaviour buys nothing when
 * the legitimate rate is roughly one request per player per fifteen minutes.
 *
 * @param {object} opts
 * @param {number} opts.limit     requests permitted per window, per key
 * @param {number} opts.windowMs  window length
 * @param {number} opts.maxKeys   hard cap on tracked keys, so this cannot itself
 *                                become the memory problem it exists to prevent
 */
export function createRateLimiter({ limit = 10, windowMs = 60_000, maxKeys = 10_000 } = {}) {
  /** @type {Map<string, {count: number, resetAt: number}>} */
  const windows = new Map();

  // Swept on access rather than on a timer. A setInterval would keep the event
  // loop alive and interfere with the SIGTERM drain, and it would need unref()
  // and a clearInterval on shutdown to avoid that -- machinery for a job that a
  // counter can do for free.
  let sinceSweep = 0;
  const SWEEP_EVERY = 500;

  function sweep(now) {
    for (const [key, w] of windows) {
      if (w.resetAt <= now) windows.delete(key);
    }
  }

  return {
    /**
     * @param {string|number} rawKey
     * @returns {{allowed: boolean, retryAfterSeconds: number, remaining: number}}
     */
    check(rawKey) {
      const key = String(rawKey);
      const now = Date.now();

      if (++sinceSweep >= SWEEP_EVERY) {
        sinceSweep = 0;
        sweep(now);
      }

      const existing = windows.get(key);

      if (!existing || existing.resetAt <= now) {
        // Only enforce the cap when adding a NEW key, and evict rather than
        // reject. Keys are verified telegram ids, so growth is bounded by real
        // players rather than by anything an attacker controls -- but "bounded
        // by real players" is not the same as bounded, and this process has
        // roughly 256 MB.
        if (!existing && windows.size >= maxKeys) {
          sweep(now);
          if (windows.size >= maxKeys) {
            // Map iteration order is insertion order, so the first entry is the
            // oldest window. Evicting it forgives one player's count, which is
            // the right way to fail: a limiter that starts REJECTING when full
            // would hand an attacker a way to lock everyone out by filling it.
            const oldest = windows.keys().next().value;
            if (oldest !== undefined) windows.delete(oldest);
          }
        }

        windows.set(key, { count: 1, resetAt: now + windowMs });
        return { allowed: true, retryAfterSeconds: 0, remaining: limit - 1 };
      }

      if (existing.count >= limit) {
        return {
          allowed: false,
          retryAfterSeconds: Math.max(1, Math.ceil((existing.resetAt - now) / 1000)),
          remaining: 0,
        };
      }

      existing.count += 1;
      return { allowed: true, retryAfterSeconds: 0, remaining: limit - existing.count };
    },

    /** Exposed for tests and for a future metric; not used by the request path. */
    size() {
      return windows.size;
    },
  };
}
