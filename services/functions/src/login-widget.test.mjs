/**
 * Tests for verifyLoginWidget.
 *
 * The assertion that matters most is the one about the KEY DERIVATION. The
 * widget signs under SHA256(bot_token); a Mini App signs under
 * HMAC_SHA256("WebAppData", bot_token). Same shape, different secret -- so a
 * copy-paste between the two verifiers fails in one direction by rejecting every
 * genuine login, and in the other by ACCEPTING payloads Telegram never signed
 * for that context.
 *
 * So this file signs fixtures both ways and asserts each verifier takes only its
 * own. That pair is the reason the two are separate functions rather than one
 * with a flag.
 *
 * Run: node src/login-widget.test.mjs
 */

import crypto from 'node:crypto';
import { verifyLoginWidget, verifyInitData } from './telegram-auth.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

const BOT = '123456:AAHfake-token-for-tests';
const now = () => Math.floor(Date.now() / 1000);
const dcsOf = (f) => Object.keys(f).sort().map((k) => `${k}=${f[k]}`).join('\n');

/** Sign a payload the way Telegram's Login Widget does: SHA256(bot_token). */
function signWidget(fields, botToken = BOT) {
  const secret = crypto.createHash('sha256').update(botToken).digest();
  return { ...fields, hash: crypto.createHmac('sha256', secret).update(dcsOf(fields)).digest('hex') };
}

/** Sign the SAME fields the way a Mini App would -- the wrong secret here. */
function signMiniAppStyle(fields, botToken = BOT) {
  const secret = crypto.createHmac('sha256', 'WebAppData').update(botToken).digest();
  return { ...fields, hash: crypto.createHmac('sha256', secret).update(dcsOf(fields)).digest('hex') };
}

const base = () => ({ id: 7391104822, first_name: 'Y', username: 'yisak', auth_date: now() });

console.log('\nverifyLoginWidget');

{
  const r = await verifyLoginWidget(signWidget(base()), BOT);
  check('accepts a genuine widget payload', r.ok === true);
  check('and returns the telegram id as a number', r.user?.id === 7391104822);
  check('and the username', r.user?.username === 'yisak');
}

{
  // THE ONE. A payload signed with the Mini App derivation must not pass here.
  const r = await verifyLoginWidget(signMiniAppStyle(base()), BOT);
  check('REFUSES a payload signed with the Mini App key derivation', r.ok === false);
}

{
  // The mirror: a widget-signed payload must not pass verifyInitData either.
  const f = base();
  const secret = crypto.createHash('sha256').update(BOT).digest();
  const hash = crypto.createHmac('sha256', secret).update(dcsOf(f)).digest('hex');
  const asInitData = new URLSearchParams({
    ...f,
    user: JSON.stringify({ id: f.id }),
    hash,
  }).toString();
  const r = await verifyInitData(asInitData, BOT);
  check('and verifyInitData refuses a widget-signed payload', r.ok === false);
}

{
  const r = await verifyLoginWidget(signWidget(base(), 'a-different-bot-token'), BOT);
  check('refuses a payload signed by another bot', r.ok === false);
}

{
  const p = signWidget(base());
  p.first_name = 'Somebody Else';
  const r = await verifyLoginWidget(p, BOT);
  check('refuses a payload whose fields were edited after signing', r.ok === false);
}

{
  // Replay. Telegram signs no nonce, so the freshness window IS the defence --
  // a captured payload is otherwise a permanent credential for that account.
  const r = await verifyLoginWidget(signWidget({ ...base(), auth_date: now() - 3600 }), BOT);
  check('refuses an hour-old payload (replay)', r.ok === false);
}

{
  const r = await verifyLoginWidget(signWidget({ ...base(), auth_date: now() - 120 }), BOT);
  check('accepts a two-minute-old payload (a slow human)', r.ok === true);
}

{
  const r = await verifyLoginWidget(signWidget({ ...base(), auth_date: now() + 3600 }), BOT);
  check('refuses a payload dated in the future', r.ok === false);
}

{
  const p = signWidget(base());
  delete p.hash;
  const r = await verifyLoginWidget(p, BOT);
  check('refuses a payload with no hash', r.ok === false);
}

{
  const r = await verifyLoginWidget(signWidget(base()), '');
  check('refuses when no bot token is configured', r.ok === false);
}

{
  const r = await verifyLoginWidget(null, BOT);
  check('refuses a null payload without throwing', r.ok === false);
}

console.log(failures === 0 ? '\nAll login widget tests passed\n' : `\n${failures} FAILED\n`);
process.exit(failures === 0 ? 0 : 1);
