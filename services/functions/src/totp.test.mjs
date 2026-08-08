/**
 * Tests for totp.js.
 *
 * The important ones are not mine. RFC 6238 Appendix B publishes test vectors --
 * a fixed secret, fixed timestamps, expected codes -- and those are what make a
 * hand-rolled TOTP defensible rather than reckless. If this file passes, the
 * implementation agrees with the standard every authenticator app implements.
 *
 * The RFC's vectors are 8 digits; this implementation produces 6, so the
 * expected values below are the LAST SIX of each published code. That is exactly
 * what truncating to 6 digits means (code mod 10^6), not a fudge.
 *
 * Run: node src/totp.test.mjs
 */

import crypto from 'node:crypto';
import { generate, verify, generateSecret, base32Encode, base32Decode, otpauthUri } from './totp.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

console.log('\nTOTP');

// --- RFC 6238 Appendix B, the SHA-1 rows ---------------------------------
//
// The RFC's seed is the ASCII "12345678901234567890". Expressed in base32
// because that is this implementation's input format.
{
  const seed = base32Encode(Buffer.from('12345678901234567890', 'ascii'));

  // [unix seconds, published 8-digit code]
  const vectors = [
    [59, '94287082'],
    [1111111109, '07081804'],
    [1111111111, '14050471'],
    [1234567890, '89005924'],
    [2000000000, '69279037'],
    [20000000000, '65353130'],
  ];

  for (const [secs, eight] of vectors) {
    const expected = eight.slice(-6);
    const actual = generate(seed, secs * 1000);
    check(`RFC 6238 vector at t=${secs} -> ${expected}`, actual === expected);
  }
}

// --- the window, which is the part with a security cost -------------------
{
  const secret = generateSecret();
  const t = 1_700_000_000_000;

  check('accepts the current step', verify(secret, generate(secret, t), t));
  check('accepts one step back (clock skew)', verify(secret, generate(secret, t - 30_000), t));
  check('accepts one step forward', verify(secret, generate(secret, t + 30_000), t));

  // The boundary that matters: two steps is a minute of validity, which is
  // twice what was intended.
  check('REFUSES two steps back', verify(secret, generate(secret, t - 60_000), t) === false);
  check('REFUSES two steps forward', verify(secret, generate(secret, t + 60_000), t) === false);
}

// --- malformed input must not throw, and must not pass --------------------
//
// This route is reachable by an authenticated admin, so a crash here is a
// denial of service on the queue; and anything that returns true is a bypass.
{
  const secret = generateSecret();
  const t = 1_700_000_000_000;

  for (const bad of ['', '12345', '1234567', 'abcdef', '12 34 56', null, undefined, 123456, {}, []]) {
    let threw = false;
    let result = null;
    try {
      result = verify(secret, bad, t);
    } catch {
      threw = true;
    }
    check(`${JSON.stringify(bad)} is refused without throwing`, threw === false && result === false);
  }
}

// --- a wrong code from a valid-looking secret -----------------------------
{
  const a = generateSecret();
  const b = generateSecret();
  const t = 1_700_000_000_000;
  check("another enrolment's code does not verify", verify(a, generate(b, t), t) === false);
  check('000000 does not verify by accident', verify(a, '000000', t) === (generate(a, t) === '000000'));
}

// --- base32 round trip ----------------------------------------------------
{
  for (let i = 0; i < 50; i++) {
    const buf = crypto.randomBytes(1 + (i % 32));
    if (!base32Decode(base32Encode(buf)).equals(buf)) {
      check(`base32 round trip at ${buf.length} bytes`, false);
      break;
    }
    if (i === 49) check('base32 round-trips at every length 1..32', true);
  }
  check('a generated secret is 32 base32 chars (160 bits)', generateSecret().length === 32);
}

// --- the enrolment URI ----------------------------------------------------
{
  const uri = otpauthUri('JBSWY3DPEHPK3PXP', 'operator');
  check('is an otpauth totp uri', uri.startsWith('otpauth://totp/'));
  check('carries the secret', uri.includes('secret=JBSWY3DPEHPK3PXP'));
  check('names SHA1, which is what apps implement', uri.includes('algorithm=SHA1'));
  check('declares 6 digits and a 30s period', uri.includes('digits=6') && uri.includes('period=30'));
}

console.log(failures ? `\n${failures} assertion(s) failed.` : '\nAll TOTP tests passed.');
process.exit(failures ? 1 : 0);
