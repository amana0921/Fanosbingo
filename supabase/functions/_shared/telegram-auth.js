/**
 * Telegram request authentication.
 *
 * PLAIN JAVASCRIPT, not TypeScript, deliberately. telegram-auth.test.mjs
 * imports THIS FILE and exercises the real functions. A test that transcribes
 * the algorithm instead can drift from the implementation and keep passing
 * while the deployed code is wrong -- the same reason verify-detections.sh
 * reads the deployed metric filter rather than restating it.
 *
 * Deno imports .js from .ts without complaint, so callers are unaffected.
 *
 * Two mechanisms, for two different callers:
 *
 *   verifyWebhookSecret()  Telegram's servers calling our webhook. Telegram
 *                          echoes a secret we chose at registration time.
 *   verifyInitData()       A Mini App client calling us. Telegram signs the
 *                          payload with a key derived from the bot token.
 *
 * Neither existed before. The webhook accepted a POST from anyone, and no
 * function referenced initData at all -- identity was a telegram_id in the
 * request body, taken on trust.
 */

/**
 * Constant-time string comparison.
 *
 * `a === b` on a secret leaks its length and its matching prefix through
 * timing. That is a slow attack over a network and a real one, and the correct
 * version is short enough that there is no reason to skip it.
 *
 * Compares over the longer length so an early return cannot reveal which input
 * was shorter.
 */
export function timingSafeEqual(a, b) {
  const len = Math.max(a.length, b.length);
  let diff = a.length ^ b.length;

  for (let i = 0; i < len; i++) {
    diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }

  return diff === 0;
}

/**
 * Verify the secret Telegram echoes back on every webhook delivery.
 *
 * Telegram sends X-Telegram-Bot-Api-Secret-Token only if setWebhook was called
 * with a secret_token. If the webhook was registered WITHOUT one -- which is
 * how this project's was, until now -- the header never arrives and this
 * rejects every request.
 *
 * That is why the deploy order matters and is not merely tidy:
 *
 *   1. deploy setup-telegram-webhook (which now sends secret_token)
 *   2. RUN it, so Telegram re-registers and starts sending the header
 *   3. deploy this handler
 *
 * Reversing 2 and 3 takes the bot down until somebody notices.
 *
 * Deliberately NOT lenient about a missing header. A "verify it if present"
 * check is no check at all here: an attacker forging an update simply omits it.
 */
export function verifyWebhookSecret(req, expected) {
  if (!expected) {
    return {
      ok: false,
      reason:
        "no webhook secret is configured, so no request can be authenticated. Set TELEGRAM_WEBHOOK_SECRET and re-run setup-telegram-webhook.",
    };
  }

  const presented = req.headers.get("X-Telegram-Bot-Api-Secret-Token");

  if (!presented) {
    return {
      ok: false,
      reason:
        "no X-Telegram-Bot-Api-Secret-Token header. Either this is not Telegram, or the webhook was registered without a secret_token -- re-run setup-telegram-webhook.",
    };
  }

  if (!timingSafeEqual(presented, expected)) {
    return { ok: false, reason: "webhook secret does not match" };
  }

  return { ok: true };
}

/** @typedef {{id: number, username?: string, first_name?: string, last_name?: string}} TelegramUser */

/**
 * Verify a Telegram Mini App initData payload and return the user it proves.
 *
 * The algorithm is Telegram's, and every step of it matters:
 *
 *   secret_key       = HMAC_SHA256(key: "WebAppData", message: bot_token)
 *   data_check_string = every field except `hash`, as "k=v", sorted by key,
 *                       joined with newlines
 *   expected         = HMAC_SHA256(key: secret_key, message: data_check_string)
 *
 * Note the inversion in the first line -- "WebAppData" is the KEY and the bot
 * token is the MESSAGE. Getting that backwards produces a function that is
 * wrong for every input, which at least fails loudly.
 *
 * auth_date is checked too. Without a freshness window a captured initData
 * works forever, which turns a single leaked payload into a permanent
 * credential for that account.
 */
export async function verifyInitData(initData, botToken, maxAgeSeconds = 86400) {
  if (!initData) return { ok: false, reason: "no initData supplied" };
  if (!botToken) return { ok: false, reason: "no bot token configured" };

  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash) return { ok: false, reason: "initData has no hash field" };

  params.delete("hash");

  const dataCheckString = [...params.entries()]
    .map(([k, v]) => `${k}=${v}`)
    .sort()
    .join("\n");

  const encoder = new TextEncoder();

  const secretKeyMaterial = await crypto.subtle.importKey(
    "raw",
    encoder.encode("WebAppData"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const secretKey = await crypto.subtle.sign(
    "HMAC",
    secretKeyMaterial,
    encoder.encode(botToken),
  );

  const signingKey = await crypto.subtle.importKey(
    "raw",
    secretKey,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    signingKey,
    encoder.encode(dataCheckString),
  );

  const computed = Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  if (!timingSafeEqual(computed, hash)) {
    return { ok: false, reason: "initData signature does not match" };
  }

  const authDate = Number(params.get("auth_date") ?? 0);
  if (!authDate) return { ok: false, reason: "initData has no auth_date" };

  const age = Math.floor(Date.now() / 1000) - authDate;
  if (age > maxAgeSeconds) {
    return {
      ok: false,
      reason: `initData is ${age}s old, older than the ${maxAgeSeconds}s window`,
    };
  }
  // A payload dated in the future is either a clock problem or a forgery
  // attempt; neither is a request to serve.
  if (age < -300) {
    return { ok: false, reason: "initData auth_date is in the future" };
  }

  const rawUser = params.get("user");
  if (!rawUser) return { ok: false, reason: "initData has no user field" };

  /** @type {TelegramUser} */
  let user;
  try {
    user = JSON.parse(rawUser);
  } catch {
    return { ok: false, reason: "initData user field is not valid JSON" };
  }

  if (typeof user.id !== "number") {
    return { ok: false, reason: "initData user has no numeric id" };
  }

  return { ok: true, user };
}

/**
 * CORS headers locked to one origin.
 *
 * Every function in this project sent `Access-Control-Allow-Origin: *`,
 * including the ones that move money. `*` means any page on the internet can
 * make a browser issue these requests.
 *
 * Falls back to "null" rather than "*" when no origin is configured: a
 * misconfiguration should fail closed, not silently restore the thing being
 * fixed.
 */
export function corsHeaders() {
  // globalThis.Deno rather than a bare reference, so the Node test can import
  // this module without the whole file failing to load.
  const allowed = globalThis.Deno?.env.get("ALLOWED_ORIGIN") ?? "null";

  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers":
      "Content-Type, Authorization, X-Client-Info, Apikey, X-Telegram-Init-Data",
    "Vary": "Origin",
  };
}
