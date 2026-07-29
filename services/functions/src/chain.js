/**
 * Chain identity: one authoritative source, verified against reality at boot.
 *
 * THE HAZARD THIS EXISTS TO REMOVE
 *
 * A signed EVM transaction commits to a chain id (EIP-155). Sign with 56 and
 * the result is a valid BSC MAINNET transaction, whatever you believed you were
 * doing at the time. It can be broadcast by anyone who sees it, against real
 * funds, at any point in the future.
 *
 * Dev was in exactly that position. Three sources disagreed:
 *
 *   RPC endpoint (data-seed-prebsc)          -> 97   testnet
 *   SSM /fanosbingo-dev/bsc/chain_id         -> 97   testnet
 *   settings.deposit_contract_chain_id       -> 56   MAINNET
 *
 * Nothing signs yet, so nothing has gone wrong. But the day a handler reads the
 * settings row -- an ordinary-looking table any admin path can write -- every
 * "testnet" signature becomes a live mainnet transaction. The failure is silent
 * on testnet and expensive on mainnet, which is the worst possible ordering.
 *
 * TWO RULES, AND THE SECOND IS THE ONE THAT SCALES
 *
 *   1. Chain id comes from SSM, which Terraform sets per environment. It is
 *      infrastructure configuration, not application data. The settings table
 *      is writable by application code and must never determine what a
 *      signature commits to.
 *
 *   2. Verify it against the RPC at startup and refuse to run on a mismatch.
 *      Rule 1 fixes today's contradiction; rule 2 means the next one cannot
 *      reach production, whether it comes from a typo, a copied tfvars, or an
 *      RPC endpoint quietly repointed.
 */

/**
 * Ask an RPC endpoint which chain it actually serves.
 *
 * @param {string} rpcUrl
 * @param {number} timeoutMs
 * @returns {Promise<number>} the chain id
 */
export async function fetchChainId(rpcUrl, timeoutMs = 10_000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(rpcUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', method: 'eth_chainId', params: [], id: 1 }),
      signal: controller.signal,
    });

    if (!res.ok) throw new Error(`RPC returned HTTP ${res.status}`);

    const body = await res.json();
    if (body.error) throw new Error(`RPC error: ${body.error.message}`);
    if (typeof body.result !== 'string') throw new Error('RPC returned no chainId');

    const id = Number.parseInt(body.result, 16);
    if (!Number.isInteger(id) || id <= 0) {
      throw new Error(`RPC returned an unusable chainId: ${body.result}`);
    }

    return id;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Confirm the RPC serves the chain we intend to sign for.
 *
 * Returns a result rather than throwing, so the caller decides whether a
 * mismatch is fatal — it always should be for anything that signs, but a
 * read-only path may reasonably prefer to start and report degraded.
 *
 * @param {string} rpcUrl
 * @param {number} expectedChainId
 */
export async function verifyChainId(rpcUrl, expectedChainId) {
  if (!Number.isInteger(expectedChainId) || expectedChainId <= 0) {
    return { ok: false, reason: `configured chain id is not a positive integer: ${expectedChainId}` };
  }

  let actual;
  try {
    actual = await fetchChainId(rpcUrl);
  } catch (err) {
    // Unreachable is NOT the same as mismatched, and the distinction matters:
    // one is an outage to retry, the other is a configuration error to fix.
    return { ok: false, unreachable: true, reason: `could not reach the RPC: ${err.message}` };
  }

  if (actual !== expectedChainId) {
    return {
      ok: false,
      actual,
      reason:
        `RPC serves chain ${actual} but this environment is configured for ${expectedChainId}. ` +
        `Signing would commit transactions to the wrong chain — and a signature for chain 56 ` +
        `is a valid BSC mainnet transaction regardless of where it was produced.`,
    };
  }

  return { ok: true, chainId: actual };
}

/**
 * Names for the chains this project uses, so log lines and errors say something
 * a human can act on rather than a bare integer.
 */
export function chainName(id) {
  switch (id) {
    case 56:
      return 'BSC mainnet';
    case 97:
      return 'BSC testnet';
    default:
      return `chain ${id}`;
  }
}
