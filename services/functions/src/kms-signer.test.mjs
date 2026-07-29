/**
 * Tests for kms-signer.js.
 *
 * DOES NOT CALL KMS, and specifically does not touch the production wallet key.
 * Signing arbitrary bytes with the key that controls real funds is not a
 * reasonable thing to do for a test — a 32-byte digest you did not construct
 * carefully is potentially a valid transaction hash. It would also fire
 * `fanosbingo-unexpected-kms-sign`, which is the alarm working.
 *
 * Instead it generates a real secp256k1 keypair and produces DER signatures
 * exactly as KMS does — over the DIGEST, with lowS disabled so the high form
 * actually occurs. Same curve, same encoding, same ambiguities, so the parsing,
 * the EIP-2 normalisation and the recovery-id search are exercised for real
 * against a key whose address is known.
 *
 * The first version of this test used crypto.sign(null, digest, key) and every
 * recovery failed. That was the TEST being wrong, not the signer: Node hashes
 * its input again, so the signature covered sha256(digest) rather than the
 * digest. Worth remembering — it presents exactly like a broken recovery
 * search.
 *
 * The three properties worth proving, because each has a failure mode that
 * produces a VALID signature for the WRONG account:
 *
 *   1. DER integers with a leading 0x00 are parsed correctly. This happens
 *      roughly half the time, so a naive parser is wrong half the time.
 *   2. High-s signatures are normalised to the lower half of the order.
 *   3. The recovery id is derived by checking, never assumed.
 *
 * Run: node src/kms-signer.test.mjs
 */

import { secp256k1 } from '@noble/curves/secp256k1';
import { keccak256, getAddress, recoverAddress } from 'viem';
import { parseDerSignature, normaliseS } from './kms-signer.js';

const SECP256K1_N =
  0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const HALF_N = SECP256K1_N / 2n;

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

const hex = (b) => `0x${Buffer.from(b).toString('hex')}`;

// --- a key that behaves exactly like the KMS one --------------------------
const privKeyBytes = secp256k1.utils.randomPrivateKey();
// Uncompressed point, exactly the shape KMS returns inside SubjectPublicKeyInfo.
const pubUncompressed = secp256k1.getPublicKey(privKeyBytes, false);

// Drop the 0x04 prefix; address is the last 20 bytes of keccak256(X || Y).
const ADDRESS = getAddress(
  `0x${keccak256(hex(pubUncompressed.subarray(1))).slice(-40)}`,
);

/**
 * A DER signature over a DIGEST, which is what KMS returns.
 *
 * NOT crypto.sign(null, digest, key). That hashes its input again, so the
 * signature covers sha256(digest) rather than the digest — and every recovery
 * then resolves to an address that is correct for a message we never meant to
 * sign. It looks like a broken recovery search and is not.
 *
 * KMS with MessageType: 'DIGEST' signs the 32 bytes as given, which is what
 * noble's sign() does here.
 *
 * `lowS: false` on purpose: noble would otherwise normalise s for us, and the
 * whole point of these tests is to exercise OUR normalisation against the high
 * form KMS can return.
 */
function signLikeKms(digestHex) {
  const sig = secp256k1.sign(digestHex.slice(2), privKeyBytes, { lowS: false });
  return Buffer.from(sig.toDERRawBytes());
}

/** The recovery search from signDigest, without the KMS round trip. */
async function recoverV(digest, r, s) {
  for (const yParity of [0, 1]) {
    const rec = await recoverAddress({
      hash: digest,
      signature: { r: hex(r), s: hex(s), yParity },
    });
    if (getAddress(rec) === ADDRESS) return yParity;
  }
  return null;
}

console.log('\nDER parsing');
{
  // Hand-built: r has its high bit set, so DER prepends 0x00 and rLen is 33.
  // This is the case a naive 32-byte slice gets wrong.
  const r33 = Buffer.concat([Buffer.from([0x00]), Buffer.alloc(32, 0xff)]);
  const s32 = Buffer.alloc(32, 0x11);
  const der = Buffer.concat([
    Buffer.from([0x30, 4 + r33.length + s32.length]),
    Buffer.from([0x02, r33.length]), r33,
    Buffer.from([0x02, s32.length]), s32,
  ]);

  const { r, s } = parseDerSignature(der);
  check('strips the leading 0x00 from a high-bit r', r.length === 32 && r[0] === 0xff);
  check('leaves a normal s at 32 bytes', s.length === 32 && s[0] === 0x11);
}
{
  // The opposite: a SHORT integer, which must be left-padded back to 32.
  const rShort = Buffer.alloc(31, 0x22);
  const s32 = Buffer.alloc(32, 0x33);
  const der = Buffer.concat([
    Buffer.from([0x30, 4 + rShort.length + s32.length]),
    Buffer.from([0x02, rShort.length]), rShort,
    Buffer.from([0x02, s32.length]), s32,
  ]);
  const { r } = parseDerSignature(der);
  check('left-pads a short r back to 32 bytes', r.length === 32 && r[0] === 0x00 && r[1] === 0x22);
}
check('rejects a non-SEQUENCE', (() => {
  try { parseDerSignature(Buffer.from([0x31, 0x00])); return false; } catch { return true; }
})());

console.log('\nEIP-2 normalisation');
{
  const low = Buffer.from((HALF_N - 1n).toString(16).padStart(64, '0'), 'hex');
  const { s, flipped } = normaliseS(low);
  check('leaves a low s untouched', !flipped && hex(s) === hex(low));
}
{
  const high = Buffer.from((HALF_N + 1000n).toString(16).padStart(64, '0'), 'hex');
  const { s, flipped } = normaliseS(high);
  const asInt = BigInt(hex(s));
  check('flips a high s', flipped);
  check('flipped s is below half the order', asInt <= HALF_N);
  check('flipped s equals n - s', asInt === SECP256K1_N - (HALF_N + 1000n));
}

console.log('\nend to end, against a real secp256k1 key');
{
  // Many iterations, because whether r gains a leading zero and whether s lands
  // high are both random per signature. One run proves very little.
  let sawHighS = false;
  let sawPaddedR = false;
  let allRecovered = true;

  for (let i = 0; i < 40; i++) {
    const digest = keccak256(`0x${Buffer.alloc(32, i).toString('hex')}`);
    const der = signLikeKms(digest);

    if (der[3] === 0x21) sawPaddedR = true;

    const { r, s: rawS } = parseDerSignature(der);
    if (BigInt(hex(rawS)) > HALF_N) sawHighS = true;

    const { s } = normaliseS(rawS);
    const yParity = await recoverV(digest, r, s);

    if (yParity === null) {
      allRecovered = false;
      console.log(`       iteration ${i}: no recovery id resolved to the signer`);
      break;
    }
  }

  check('every signature recovers to the signing address', allRecovered);
  // If these never occurred the run above proved much less than it looks.
  check('the run actually exercised a high-s signature', sawHighS);
  check('the run actually exercised a padded r', sawPaddedR);
}

console.log('\nrefuses to lie about the signer');
{
  const digest = keccak256('0xdeadbeef');
  const der = signLikeKms(digest);
  const { r, s: rawS } = parseDerSignature(der);
  const { s } = normaliseS(rawS);

  // A different address must NOT be recoverable from this signature.
  const other = getAddress('0x000000000000000000000000000000000000dEaD');
  let matched = false;
  for (const yParity of [0, 1]) {
    const rec = await recoverAddress({ hash: digest, signature: { r: hex(r), s: hex(s), yParity } });
    if (getAddress(rec) === other) matched = true;
  }
  check('a signature never recovers to an unrelated address', !matched);
}

console.log('');
if (failures) {
  console.error(`${failures} assertion(s) failed.`);
  process.exit(1);
}
console.log('All assertions passed.');
