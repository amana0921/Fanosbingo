/**
 * Tests for telegram-auth.js.
 *
 * IMPORTS THE REAL MODULE. It does not restate the algorithm, because a test
 * that carries its own copy can drift from the implementation and keep passing
 * while the deployed code is wrong. That is exactly the failure mode
 * verify-detections.sh avoids by reading the metric filter back from CloudWatch
 * rather than repeating it. Same rule here.
 *
 * Asserts BOTH directions. A verifier that accepts everything passes every
 * "does it accept a valid payload" test ever written, and a verifier that
 * rejects everything passes every rejection test. Only both together say
 * anything.
 *
 *   node supabase/functions/_shared/telegram-auth.test.mjs
 *
 * No dependencies: Node's Web Crypto is the same API Deno gives the function.
 */

import { webcrypto } from 'node:crypto';
import {
  timingSafeEqual,
  verifyInitData,
  verifyWebhookSecret,
} from './telegram-auth.js';

if (!globalThis.crypto) globalThis.crypto = webcrypto;

const BOT_TOKEN = '123456:TEST-TOKEN-not-a-real-secret';
const enc = new TextEncoder();

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

// Builds a genuine initData exactly as Telegram's servers would, so the
// "accepts" cases are testing against a real signature rather than against the
// verifier's own output.
async function signInitData(fields) {
  const hmac = async (keyData, msg) => {
    const k = await crypto.subtle.importKey(
      'raw', keyData, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
    );
    return new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(msg)));
  };
  const hex = (b) => Array.from(b).map((x) => x.toString(16).padStart(2, '0')).join('');

  const p = new URLSearchParams(fields);
  const dcs = [...p.entries()].map(([k, v]) => `${k}=${v}`).sort().join('\n');
  const secretKey = await hmac(enc.encode('WebAppData'), BOT_TOKEN);
  p.set('hash', hex(await hmac(secretKey, dcs)));
  return p.toString();
}

const now = () => Math.floor(Date.now() / 1000);
const USER = JSON.stringify({ id: 987654321, username: 'player', first_name: 'A' });

console.log('\ntimingSafeEqual');
check('equal strings match', timingSafeEqual('abc123', 'abc123'));
check('different strings do not', !timingSafeEqual('abc123', 'abc124'));
check('different lengths do not', !timingSafeEqual('abc', 'abcd'));
check('empty strings match', timingSafeEqual('', ''));
check('a prefix does not match the whole', !timingSafeEqual('abc', 'abcdef'));

console.log('\nverifyInitData — accepts what it should');
const good = await signInitData({ user: USER, auth_date: String(now()), query_id: 'AAxyz' });
const okResult = await verifyInitData(good, BOT_TOKEN);
check('accepts a genuinely signed payload', okResult.ok === true);
check('returns the signed user id', okResult.ok && okResult.user.id === 987654321);
check('returns the signed username', okResult.ok && okResult.user.username === 'player');

console.log('\nverifyInitData — rejects what it should');
check('rejects a tampered user id',
  !(await verifyInitData(good.replace('987654321', '111111111'), BOT_TOKEN)).ok);
check('rejects a payload signed by a different bot token',
  !(await verifyInitData(good, 'other:TOKEN')).ok);
check('rejects a stripped hash',
  !(await verifyInitData(good.replace(/&?hash=[a-f0-9]+/, ''), BOT_TOKEN)).ok);
check('rejects empty initData', !(await verifyInitData('', BOT_TOKEN)).ok);
check('rejects a missing bot token', !(await verifyInitData(good, '')).ok);

// A correctly signed payload that is simply old. Without this window a captured
// initData is a permanent credential for that account.
const stale = await signInitData({ user: USER, auth_date: String(now() - 90000) });
check('rejects a correctly signed but STALE payload',
  !(await verifyInitData(stale, BOT_TOKEN)).ok);
check('accepts that same payload with a wider window',
  (await verifyInitData(stale, BOT_TOKEN, 100000)).ok === true);

const future = await signInitData({ user: USER, auth_date: String(now() + 9999) });
check('rejects a payload dated in the future',
  !(await verifyInitData(future, BOT_TOKEN)).ok);

const noUser = await signInitData({ auth_date: String(now()) });
check('rejects a signed payload carrying no user',
  !(await verifyInitData(noUser, BOT_TOKEN)).ok);

console.log('\nverifyWebhookSecret');
const withHeader = (v) =>
  new Request('https://example.test', {
    method: 'POST',
    headers: v === null ? {} : { 'X-Telegram-Bot-Api-Secret-Token': v },
  });

check('accepts the matching secret',
  verifyWebhookSecret(withHeader('s3cret'), 's3cret').ok === true);
check('rejects a wrong secret',
  verifyWebhookSecret(withHeader('wrong'), 's3cret').ok === false);
// The case that matters: a forger simply omits the header.
check('rejects a MISSING header rather than waving it through',
  verifyWebhookSecret(withHeader(null), 's3cret').ok === false);
check('rejects when no secret is configured at all',
  verifyWebhookSecret(withHeader('anything'), '').ok === false);

console.log('');
if (failures > 0) {
  console.error(`${failures} assertion(s) failed.`);
  process.exit(1);
}
console.log('All assertions passed.');
