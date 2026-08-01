/**
 * Feature flags.
 *
 * WHY THIS EXISTS, rather than deleting the code it gates.
 *
 * The crypto path -- wallet login, on-chain deposit, on-chain withdrawal -- is
 * DEFERRED, not abandoned. Ethiopian players overwhelmingly do not hold
 * cryptocurrency, so the currency that matters today is birr moving through
 * TeleBirr and CBE. The contract, the KMS signing key and services/functions/
 * src/kms-signer.js all stay exactly where they are.
 *
 * Deleting the UI would mean rebuilding it later from memory, and the parts most
 * worth keeping are precisely the ones that were learned expensively -- see the
 * header of src/lib/walletConfig.ts on why this build must not hardcode chain 56.
 * That reasoning is not recoverable by rewriting; it is only recoverable by
 * leaving the file alone.
 *
 * So the code stays and the SURFACES are gated. Turning crypto back on is a
 * build variable, not a merge.
 *
 * WHY AN EXPLICIT FLAG, and not "is the contract address set?"
 *
 * VITE_DEPOSIT_CONTRACT_ADDRESS being present is NECESSARY for the crypto path
 * and nowhere near sufficient: the routes it calls -- submit-deposit,
 * record-withdrawal, manage-bnb-withdrawal, claim-winnings-to-contract,
 * get-withdrawal-wallet-info -- are all 404 on this infrastructure. Deriving the
 * flag from the address would mean that deploying the contract silently lights
 * up a UI whose backend does not exist, and the failure lands on a player
 * mid-withdrawal.
 *
 * Two independent things must be true, so they are two independent switches, and
 * this one defaults OFF. The safe direction to fail is "the button is not there",
 * never "the button is there and does nothing".
 *
 * WHAT GATING ACTUALLY BUYS, measured rather than assumed.
 *
 * The built bundle is ~2.2 MB raw / ~804 KB gzipped, and the wallet stack is a
 * large share of it -- parseSignature (34 KB gz), w3m-modal (11 KB), swaps
 * (10 KB), secp256k1 (10 KB), send (7 KB), plus wagmi and @reown/appkit inside
 * the entry chunk. These players reach Telegram over Ethiopian mobile networks;
 * the same networks the Cloudflare rate-limit reasoning is written around.
 * Not shipping a deferred feature to them is the single largest payload win
 * available, and it costs nothing because those routes 404 today anyway.
 *
 * THE CATCH, and it is the reason gating has to reach further than the modals.
 *
 * src/App.tsx wraps the whole application in <WagmiProvider>, and
 * src/lib/walletConfig.ts calls createAppKit() at module scope. Both are
 * top-level imports, so the entire wallet stack lands in the ENTRY chunk and is
 * downloaded before anything renders. Lazily importing only the modals would
 * therefore save almost nothing -- the expensive part is already loaded.
 *
 * The provider itself has to move behind a dynamic import for the split to be
 * real. That is what src/components/CryptoProvider.tsx is for.
 */

/**
 * Set VITE_CRYPTO_ENABLED=true to restore wallet login, on-chain deposits and
 * on-chain withdrawals.
 *
 * Compile-time, like every VITE_ variable: this is baked into the bundle, so
 * flipping it requires a rebuild and a caddy redeploy -- the same as the anon key
 * and the contract address. That is the right granularity here. A runtime toggle
 * would let the settings table decide whether money can move on chain, and
 * services/functions is explicit that application data must never make that class
 * of decision.
 */
export const CRYPTO_ENABLED = import.meta.env.VITE_CRYPTO_ENABLED === 'true';

/**
 * The on-chain deposit contract, or null.
 *
 * Read here rather than in each component so the shape check lives in one place.
 * A malformed address is treated as absent: the deposit modal then says deposits
 * are unavailable rather than showing a form pointing at nowhere, which is the
 * behaviour .env.example already describes.
 */
export const DEPOSIT_CONTRACT_ADDRESS: string | null = (() => {
  const value = import.meta.env.VITE_DEPOSIT_CONTRACT_ADDRESS ?? '';
  return /^0x[0-9a-fA-F]{40}$/.test(value) ? value : null;
})();

/**
 * Both conditions, together. This is what a crypto surface should actually test.
 *
 * Kept as a derived constant rather than asking callers to remember the `&&`,
 * because "somebody forgets one of the two checks" is exactly how a deferred
 * feature comes back early in one place and not another.
 */
export const CRYPTO_READY = CRYPTO_ENABLED && DEPOSIT_CONTRACT_ADDRESS !== null;
