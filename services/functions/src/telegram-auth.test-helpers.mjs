/**
 * Test helper: build a genuinely signed Telegram initData payload.
 *
 * Extracted from telegram-auth.test.mjs so rate-limit.test.mjs can exercise the
 * real verify-then-limit-then-write ordering without a second copy of the
 * signing logic drifting from the first.
 *
 * It signs the way TELEGRAM'S SERVERS do, deliberately, rather than by calling
 * anything in src/. A helper that reused the verifier's own hashing would make
 * every "accepts a valid payload" assertion vacuous -- it would prove the
 * verifier agrees with itself.
 *
 * The construction is Telegram's documented scheme:
 *   secret  = HMAC_SHA256(key="WebAppData", msg=bot_token)
 *   hash    = HMAC_SHA256(key=secret,       msg=sorted "k=v" lines joined by \n)
 */

const enc = new TextEncoder();

async function hmac(keyData, msg) {
  const k = await crypto.subtle.importKey(
    'raw',
    keyData,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(msg)));
}

const hex = (b) => Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join('');

/**
 * @param {string} botToken
 * @param {Record<string, string>} fields
 *        Passed through as-is. `user` must already be a JSON string, matching
 *        what Telegram sends -- the caller decides, because several tests
 *        deliberately omit it or malform it.
 * @returns {Promise<string>} url-encoded initData including a valid `hash`
 */
export async function signInitData(botToken, fields) {
  const p = new URLSearchParams(fields);
  const dcs = [...p.entries()].map(([k, v]) => `${k}=${v}`).sort().join('\n');
  const secretKey = await hmac(enc.encode('WebAppData'), botToken);
  p.set('hash', hex(await hmac(secretKey, dcs)));
  return p.toString();
}

/**
 * The common case: a valid, current payload for one user.
 *
 * @param {string} botToken
 * @param {{id: number, username?: string, first_name?: string}} user
 */
export async function signForUser(botToken, user) {
  return signInitData(botToken, {
    user: JSON.stringify(user),
    auth_date: String(Math.floor(Date.now() / 1000)),
  });
}
