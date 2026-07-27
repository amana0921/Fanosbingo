#!/usr/bin/env node
/**
 * Derive the BSC wallet address from a KMS secp256k1 key.
 *
 * This replaces the deleted get-wallet-address.mjs, which hardcoded a private
 * key in source and leaked it to a public GitHub repository. The difference is
 * total: KMS never releases the private half, so there is nothing here that
 * COULD be committed. The address is derived from the public key alone.
 *
 * Usage:
 *   node scripts/derive-wallet-address.mjs <kms-key-id>
 *   node scripts/derive-wallet-address.mjs alias/fanosbingo-dev-wallet-signing
 *
 * Requires the AWS CLI on PATH and credentials with kms:GetPublicKey.
 */

import { execFileSync } from 'node:child_process';
import { keccak256 } from 'viem';

const keyId = process.argv[2];

if (!keyId) {
  console.error('Usage: node scripts/derive-wallet-address.mjs <kms-key-id|alias>');
  process.exit(1);
}

/**
 * KMS returns the public key as DER-encoded SubjectPublicKeyInfo. For
 * ECC_SECG_P256K1 that wraps a 65-byte uncompressed EC point which always
 * begins 0x04. Rather than write a DER parser for one field, locate that
 * 65-byte run from the end — the point is the final element of the structure.
 */
function extractUncompressedPoint(der) {
  const start = der.length - 65;
  if (start < 0 || der[start] !== 0x04) {
    throw new Error(
      `Unexpected key format: expected a 65-byte uncompressed EC point ending the DER structure. ` +
      `Is ${keyId} really an ECC_SECG_P256K1 key?`
    );
  }
  return der.subarray(start);
}

let publicKeyB64;
try {
  publicKeyB64 = execFileSync(
    'aws',
    ['kms', 'get-public-key', '--key-id', keyId, '--query', 'PublicKey', '--output', 'text'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }
  ).trim();
} catch (error) {
  console.error(`Failed to read the public key for ${keyId}.`);
  console.error(error.stderr?.toString().trim() || error.message);
  process.exit(1);
}

const der = Buffer.from(publicKeyB64, 'base64');
const point = extractUncompressedPoint(der);

// Drop the 0x04 prefix; the address is the last 20 bytes of keccak256(X || Y).
const xy = point.subarray(1);
const hash = keccak256(`0x${xy.toString('hex')}`);
const address = `0x${hash.slice(-40)}`;

// EIP-55 checksum casing, so the address is safe to paste anywhere.
const hashOfLower = keccak256(
  new TextEncoder().encode(address.slice(2).toLowerCase())
).slice(2);

const checksummed = '0x' + address
  .slice(2)
  .toLowerCase()
  .split('')
  .map((ch, i) => (parseInt(hashOfLower[i], 16) >= 8 ? ch.toUpperCase() : ch))
  .join('');

if (process.env.OUTPUT_FORMAT === 'plain') {
  process.stdout.write(checksummed);
} else {
  console.log('');
  console.log('  KMS key:  ' + keyId);
  console.log('  Address:  ' + checksummed);
  console.log('');
  console.log('  Fund this address with BNB to process withdrawals.');
  console.log('  The private key exists only inside KMS and cannot be exported.');
  console.log('');
}
