/**
 * Signing BSC transactions with a KMS key that cannot be exported.
 *
 * WHY THIS SHAPE
 *
 * The original project kept the hot-wallet private key in the `settings` table
 * and, at one point, in a committed script. That key was public on GitHub. The
 * structural fix is not "store it more carefully" -- it is to make a plaintext
 * copy impossible: an `ECC_SECG_P256K1` key in KMS, non-exportable, with
 * `kms:Sign` granted to exactly one IAM role.
 *
 * The cost of that guarantee is this file. KMS speaks ASN.1 DER and knows
 * nothing about Ethereum, so the gap has to be bridged in three places, each of
 * which is a well-known way to produce signatures that verify as valid and
 * resolve to the wrong account.
 *
 *   1. DER -> (r, s).  KMS returns a DER SEQUENCE of two INTEGERs. DER INTEGERs
 *      are signed and minimally encoded, so a value whose top bit is set gains a
 *      leading 0x00 byte. Slicing 32 bytes blindly gives a wrong r about half
 *      the time.
 *
 *   2. s must be in the LOWER half of the curve order (EIP-2). secp256k1 admits
 *      two valid signatures per message, (r, s) and (r, n - s). Ethereum rejects
 *      the high form -- it was a transaction malleability vector -- and KMS will
 *      happily return either.
 *
 *   3. v is not returned at all. It is the recovery id, and the only honest way
 *      to obtain it is to try both candidates and keep the one that recovers to
 *      the address we know we are. Guessing is how funds go to nowhere.
 *
 * Every signature is a CloudTrail event, and task_functions is the only
 * principal permitted to call Sign -- which is what makes the
 * `fanosbingo-unexpected-kms-sign` alarm a real signal rather than noise.
 */

import { KMSClient, SignCommand, GetPublicKeyCommand } from '@aws-sdk/client-kms';
import { keccak256, recoverAddress, getAddress, serializeTransaction } from 'viem';

/** secp256k1 group order. s above half of this is the malleable form. */
const SECP256K1_N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const SECP256K1_HALF_N = SECP256K1_N / 2n;

const kms = new KMSClient({ region: process.env.AWS_REGION ?? 'us-east-1' });

/**
 * Bytes to a 0x-prefixed hex string.
 *
 * The RETURN TYPE is annotated, and it is load-bearing rather than decorative.
 *
 * TypeScript infers a template literal as plain `string`, so without this every
 * value derived from hex() -- which is `r` and `s` on the signing path -- reached
 * viem as `string` where its types demand `0x${string}`. viem uses that template
 * type deliberately: it is the difference between "some text" and "something that
 * can be parsed as hex", and the check it enables is exactly the one worth having
 * on a function that serialises a transaction.
 *
 * Nothing was wrong at runtime; this function has always returned a 0x-prefixed
 * string. But it was the only thing asserting that, and it was asserting it to
 * nobody. Found by pointing checkJs at this service for the first time -- four of
 * its six findings traced back to this single line.
 *
 * @param {Uint8Array|Buffer|ArrayLike<number>} buf
 * @returns {`0x${string}`}
 */
const hex = (buf) => /** @type {`0x${string}`} */ (`0x${Buffer.from(buf).toString('hex')}`);

/**
 * Pull (r, s) out of a DER SEQUENCE { INTEGER r, INTEGER s }.
 *
 * Written out rather than pulled from a library because the failure mode of
 * getting it subtly wrong is a valid-looking signature for the wrong account,
 * and that is worth being able to read.
 */
export function parseDerSignature(der) {
  const bytes = Buffer.from(der);

  if (bytes[0] !== 0x30) throw new Error('signature is not a DER SEQUENCE');

  // [0]=0x30 [1]=len [2]=0x02 [3]=rLen [4..]=r
  let offset = 2;
  if (bytes[offset] !== 0x02) throw new Error('expected an INTEGER for r');
  const rLen = bytes[offset + 1];
  let r = bytes.subarray(offset + 2, offset + 2 + rLen);

  offset = offset + 2 + rLen;
  if (bytes[offset] !== 0x02) throw new Error('expected an INTEGER for s');
  const sLen = bytes[offset + 1];
  let s = bytes.subarray(offset + 2, offset + 2 + sLen);

  // DER INTEGERs are signed: a leading 0x00 exists only to keep a value with
  // its high bit set from reading as negative. Strip it, then left-pad back to
  // 32 bytes, because Ethereum wants fixed width.
  const normalise = (v) => {
    let out = v;
    while (out.length > 32 && out[0] === 0x00) out = out.subarray(1);
    if (out.length > 32) throw new Error('integer longer than 32 bytes');
    return Buffer.concat([Buffer.alloc(32 - out.length), out]);
  };

  return { r: normalise(r), s: normalise(s) };
}

/**
 * Enforce EIP-2: if s is in the upper half of the order, replace it with n - s.
 *
 * Both signatures are cryptographically valid; Ethereum only accepts the low
 * one. Returns whether it flipped, because flipping also flips the recovery id.
 */
export function normaliseS(sBuffer) {
  const s = BigInt(hex(sBuffer));

  if (s <= SECP256K1_HALF_N) return { s: sBuffer, flipped: false };

  const lowered = SECP256K1_N - s;
  const buf = Buffer.from(lowered.toString(16).padStart(64, '0'), 'hex');

  return { s: buf, flipped: true };
}

/**
 * The address this key controls, derived from its public key.
 *
 * Never configured by hand. A mistyped address here would mean signing with one
 * key and expecting another, and the recovery step below would then reject
 * every signature -- correctly, but confusingly.
 */
export async function getSignerAddress(keyId) {
  const { PublicKey } = await kms.send(new GetPublicKeyCommand({ KeyId: keyId }));

  const der = Buffer.from(PublicKey);

  // The uncompressed EC point inside SubjectPublicKeyInfo begins 0x04 and runs
  // 65 bytes. Locating it beats writing a full ASN.1 parser for one field --
  // the same approach scripts/derive-wallet-address.mjs takes.
  const start = der.indexOf(0x04, der.length - 65);
  if (start < 0 || der[start] !== 0x04) {
    throw new Error('could not locate the uncompressed EC point in the public key');
  }

  const xy = der.subarray(start + 1, start + 65);
  if (xy.length !== 64) throw new Error('EC point is not 64 bytes');

  // Address is the last 20 bytes of keccak256(X || Y).
  return getAddress(`0x${keccak256(hex(xy)).slice(-40)}`);
}

/**
 * Sign a 32-byte digest, returning Ethereum's (r, s, v).
 *
 * `expectedAddress` is required, not optional. It is what turns "we produced a
 * signature" into "we produced a signature that resolves to us" -- the only
 * check that catches a wrong recovery id, and the difference between a
 * withdrawal arriving and funds going to an address nobody holds.
 */
export async function signDigest(keyId, digest, expectedAddress) {
  const { Signature } = await kms.send(
    new SignCommand({
      KeyId: keyId,
      Message: Buffer.from(digest.slice(2), 'hex'),
      MessageType: 'DIGEST',
      SigningAlgorithm: 'ECDSA_SHA_256',
    }),
  );

  const { r, s: rawS } = parseDerSignature(Signature);
  const { s } = normaliseS(rawS);

  const want = getAddress(expectedAddress);

  // v is not returned by KMS. Try both recovery ids and keep the one that
  // recovers to us. Trying is not a fallback here -- it is the algorithm.
  for (const yParity of [0, 1]) {
    const recovered = await recoverAddress({
      hash: digest,
      signature: { r: hex(r), s: hex(s), yParity },
    });

    if (getAddress(recovered) === want) {
      return { r: hex(r), s: hex(s), yParity, v: BigInt(27 + yParity) };
    }
  }

  // Both failed. Signing with a key that is not the wallet, or a corrupted
  // digest. Refuse rather than broadcast something unattributable.
  throw new Error(
    `neither recovery id resolves to ${want}; the KMS key does not control this address`,
  );
}

/**
 * Sign a BSC transaction and return the raw bytes to broadcast.
 *
 * EIP-1559 (type 2). BSC supports it, and it avoids the legacy chainId-in-v
 * encoding that is easy to get wrong on a chain that is not mainnet Ethereum.
 */
export async function signTransaction(keyId, tx, expectedAddress) {
  // The digest is over the UNSIGNED serialization. Signing the wrong bytes
  // produces a signature that verifies against nothing.
  const unsigned = serializeTransaction(tx);
  const digest = keccak256(unsigned);

  const { r, s, yParity } = await signDigest(keyId, digest, expectedAddress);

  return serializeTransaction(tx, { r, s, yParity });
}
