/**
 * Everything that depends on the wallet stack, behind ONE dynamic import.
 *
 * WHY THIS FILE EXISTS, and why gating the modals was not enough.
 *
 * src/App.tsx used to import WagmiProvider at the top level and wrap the whole
 * application in it, and src/lib/walletConfig.ts calls createAppKit() at module
 * scope. Both are static imports, so wagmi, @reown/appkit and viem all landed in
 * the ENTRY chunk and were downloaded before a single pixel rendered.
 *
 * Lazily importing only WalletDepositModal and BnbWithdrawalModal would
 * therefore have saved almost nothing: the expensive part was already on the
 * wire. The PROVIDER is what has to move, which is what this file is.
 *
 * Measured against the current build: ~2.2 MB raw / ~804 KB gzipped total, with
 * identifiable wallet chunks at parseSignature 34 KB gz, w3m-modal 11 KB, swaps
 * 10 KB, secp256k1 10 KB, send 7 KB, plus wagmi and appkit inside the entry
 * chunk itself. These players reach Telegram over Ethiopian mobile networks --
 * the same networks modules/cloudflare reasons about at length when choosing a
 * rate-limit threshold, because one carrier-NAT address is many people. Not
 * shipping a deferred feature to them is the largest payload win available here.
 *
 * NOTHING IS DELETED. Crypto is deferred, not abandoned: Ethiopian players
 * overwhelmingly do not hold cryptocurrency today, so birr through TeleBirr and
 * CBE is the currency that matters. Set VITE_CRYPTO_ENABLED=true and this file
 * loads again, unchanged. See src/lib/features.ts.
 *
 * @tanstack/react-query comes along because nothing else in the SPA uses it --
 * it is wagmi's dependency, and QueryClientProvider was only ever here to serve
 * it. Verified by grep before moving it.
 */

import { useEffect, useRef, type ReactNode } from 'react';
import { WagmiProvider, useAccount } from 'wagmi';
import { QueryClientProvider } from '@tanstack/react-query';
import { config, queryClient } from '../lib/walletConfig';
import { supabase } from '../lib/supabase';
import type { TelegramUser } from '../utils/telegram';

interface CryptoProviderProps {
  children: ReactNode;
  /**
   * Called once a connected wallet resolves to a player row.
   *
   * A callback rather than context because the consumer -- AppContent -- must
   * keep working when this file is never loaded at all. A context it could not
   * read would mean AppContent needing its own fallback for the crypto-disabled
   * case, which is the branch this design exists to avoid having.
   */
  onWalletUser: (user: TelegramUser) => void;
  /**
   * Whether an identity is still needed. False once Telegram has already
   * authenticated, so a player inside the Mini App who also happens to have a
   * wallet connected is not re-identified as the wallet account.
   */
  needsIdentity: boolean;
}

/**
 * The wallet-login path: a connected address becomes a player row.
 *
 * Lifted out of AppContent verbatim. It lived there only because that was the
 * component already inside WagmiProvider, and useAccount() is what pinned the
 * whole stack into the entry chunk.
 *
 * NOTE FOR WHEN CRYPTO COMES BACK: get_or_create_wallet_user is SECURITY DEFINER
 * and takes a wallet address as an unchecked parameter, which is why
 * db/20-post/004 allowlists it for `anon` explicitly rather than by accident --
 * there is no JWT at this point by construction. While crypto is off it has no
 * caller, and an anon-callable SECURITY DEFINER function with no caller is
 * exactly the surface 004 exists to remove. Revoking it there and re-granting it
 * in the same change that flips VITE_CRYPTO_ENABLED is the coupled pair.
 */
function WalletIdentity({ onWalletUser, needsIdentity }: Omit<CryptoProviderProps, 'children'>) {
  const { address, isConnected } = useAccount();
  const registered = useRef(false);

  useEffect(() => {
    if (!needsIdentity || !isConnected || !address || registered.current) return;

    const registerWalletUser = async () => {
      try {
        registered.current = true;
        const { data, error } = await supabase.rpc('get_or_create_wallet_user', {
          p_wallet_address: address,
        });

        if (error || !data?.success) {
          registered.current = false;
          return;
        }

        const user = data.user;
        onWalletUser({
          id: user.telegram_user_id,
          first_name: user.telegram_first_name || `${address.slice(0, 6)}...${address.slice(-4)}`,
          username: user.telegram_username || undefined,
        });
      } catch {
        registered.current = false;
      }
    };

    void registerWalletUser();
  }, [isConnected, address, needsIdentity, onWalletUser]);

  // Reset so disconnecting and reconnecting can register again.
  useEffect(() => {
    if (!isConnected && needsIdentity) registered.current = false;
  }, [isConnected, needsIdentity]);

  return null;
}

export default function CryptoProvider({
  children,
  onWalletUser,
  needsIdentity,
}: CryptoProviderProps) {
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <WalletIdentity onWalletUser={onWalletUser} needsIdentity={needsIdentity} />
        {children}
      </QueryClientProvider>
    </WagmiProvider>
  );
}
