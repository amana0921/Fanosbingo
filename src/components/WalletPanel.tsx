/**
 * The Lobby's crypto surface: connect, deposit BNB, withdraw BNB.
 *
 * Lifted out of Lobby.tsx unchanged in behaviour, for one structural reason:
 * Lobby called useAccount() at its top level, so importing Lobby imported wagmi,
 * and Lobby is imported statically by App. Gating the JSX without moving the
 * hook would have left the whole wallet stack in the entry chunk regardless.
 * See src/components/CryptoProvider.tsx for the same problem one level up.
 *
 * Rendered only when CRYPTO_ENABLED, and only ever through React.lazy, so with
 * the flag off none of this -- nor WalletConnect, WalletDepositModal,
 * BnbWithdrawalModal, or anything they pull in -- is fetched.
 *
 * NOT DELETED, because crypto is deferred rather than abandoned. When it returns
 * this file is mounted again as-is. What must return WITH it, and is easy to
 * miss:
 *
 *   - the three routes these modals call are 404 today: submit-deposit,
 *     record-withdrawal, claim-winnings-to-contract. src/components/
 *     BnbWithdrawalModal.tsx does NOT check the response status before reporting
 *     success, so an on-chain withdrawal whose ledger write silently fails would
 *     leave the balance undeducted. Build claim-winnings-to-contract and
 *     record-withdrawal in ONE change, and make that fetch check res.ok.
 *   - db/20-post/004 allowlists get_or_create_wallet_user for `anon` to serve
 *     wallet login. While crypto is off it has no caller and should be revoked
 *     there, then re-granted alongside this.
 */

import { useEffect, lazy, Suspense } from 'react';
import { useAccount } from 'wagmi';
import WalletConnect from './WalletConnect';
import { formatBirr, CURRENCY_LABEL } from '../utils/formatBalance';

const WalletDepositModal = lazy(() =>
  import('./WalletDepositModal').then((m) => ({ default: m.WalletDepositModal })),
);
const BnbWithdrawalModal = lazy(() =>
  import('./BnbWithdrawalModal').then((m) => ({ default: m.BnbWithdrawalModal })),
);

interface WalletPanelProps {
  telegramUserId: number | null;
  wonBalance: number;
  depositedBalance: number;
  /** Null until the player's row has loaded; the panel's buttons wait for it. */
  isRegistered: boolean;
  isCheckingRegistration: boolean;
  stakeAmount: number | null;
  isDarkMode: boolean;
  depositOpen: boolean;
  withdrawOpen: boolean;
  onOpenDeposit: () => void;
  onOpenWithdraw: () => void;
  onCloseDeposit: () => void;
  onCloseWithdraw: () => void;
  onToast: (message: string, kind: 'success' | 'info' | 'error') => void;
  onRefresh: () => void;
  /**
   * Reports the connected address upward.
   *
   * Lobby renders the address in its header and passes it to
   * get_lobby_data_instant for the wallet-login path, so it needs the value --
   * but it must not call useAccount() itself, which is the whole point of this
   * component. A callback keeps the hook on this side of the dynamic import.
   */
  onAddressChange: (address: string | undefined) => void;
}

export default function WalletPanel({
  telegramUserId,
  wonBalance,
  depositedBalance,
  isRegistered,
  isCheckingRegistration,
  stakeAmount,
  isDarkMode,
  depositOpen,
  withdrawOpen,
  onOpenDeposit,
  onOpenWithdraw,
  onCloseDeposit,
  onCloseWithdraw,
  onToast,
  onRefresh,
  onAddressChange,
}: WalletPanelProps) {
  const { address, isConnected } = useAccount();

  useEffect(() => {
    onAddressChange(isConnected ? address : undefined);
  }, [address, isConnected, onAddressChange]);

  return (
    <>
      {/* Genuinely needs a wallet: there has to be somewhere to send BNB. */}
      {!isConnected && (
        <div
          className={`border-l-4 p-3 mb-3 rounded transition-colors duration-300 ${isDarkMode ? 'bg-yellow-900/20 border-yellow-600 text-yellow-300' : 'bg-yellow-50 border-yellow-400 text-yellow-800'}`}
        >
          <p className="text-sm font-semibold mb-2">Prefer crypto?</p>
          <p className="text-xs mb-2 opacity-90">
            Connect a BNB wallet to deposit or withdraw in BNB. Not needed to play.
          </p>
          <WalletConnect
            telegramUserId={telegramUserId || 0}
            onWalletConnected={() => onToast('Wallet connected!', 'success')}
          />
        </div>
      )}

      {isConnected && isRegistered && (
        <div
          className={`border-l-4 p-3 mb-3 rounded transition-colors duration-300 ${isDarkMode ? 'bg-emerald-900/20 border-emerald-600 text-emerald-300' : 'bg-emerald-50 border-emerald-400 text-emerald-800'}`}
        >
          <p className="text-sm font-semibold mb-2">Crypto (BNB) Deposits &amp; Withdrawals</p>
          <p className="text-xs mb-2 opacity-90">
            Deposit BNB to play or withdraw your winnings (
            {stakeAmount !== null ? formatBirr(stakeAmount) : '10'} {CURRENCY_LABEL} per game)
          </p>
          <div className="flex gap-2">
            <button
              onClick={onOpenDeposit}
              className="flex-1 py-2 px-4 rounded-lg font-semibold transition-colors bg-emerald-600 hover:bg-emerald-700 text-white"
            >
              Deposit BNB
            </button>
            <button
              onClick={onOpenWithdraw}
              disabled={!wonBalance || wonBalance === 0}
              className={`flex-1 py-2 px-4 rounded-lg font-semibold transition-colors ${
                wonBalance > 0
                  ? 'bg-yellow-600 hover:bg-yellow-700 text-white'
                  : isDarkMode
                    ? 'bg-gray-700 text-gray-500 cursor-not-allowed'
                    : 'bg-gray-200 text-gray-400 cursor-not-allowed'
              }`}
            >
              Withdraw BNB
            </button>
          </div>
        </div>
      )}

      {isConnected && !isRegistered && isCheckingRegistration && (
        <div
          className={`border-l-4 p-3 mb-3 rounded transition-colors duration-300 ${isDarkMode ? 'bg-blue-900/20 border-blue-600 text-blue-300' : 'bg-blue-50 border-blue-400 text-blue-800'}`}
        >
          <p className="text-sm font-medium">Setting up your account...</p>
        </div>
      )}

      {telegramUserId !== null && (
        <Suspense fallback={null}>
          {depositOpen && (
            <WalletDepositModal
              isOpen={depositOpen}
              onClose={onCloseDeposit}
              telegramUserId={telegramUserId}
              onSuccess={() => {
                onToast('Deposit successful! Your balance will be updated shortly.', 'success');
                onRefresh();
              }}
            />
          )}
          {withdrawOpen && (
            <BnbWithdrawalModal
              isOpen={withdrawOpen}
              onClose={onCloseWithdraw}
              telegramUserId={telegramUserId}
              wonBalance={wonBalance}
              depositedBalance={depositedBalance}
              onSuccess={() => {
                onToast('Withdrawal request submitted successfully!', 'success');
                onRefresh();
              }}
            />
          )}
        </Suspense>
      )}
    </>
  );
}
