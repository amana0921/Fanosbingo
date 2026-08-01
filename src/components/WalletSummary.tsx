/**
 * The two balances, named — and what is currently in flight against them.
 *
 * WHY TWO NUMBERS RATHER THAN ONE.
 *
 * The lobby used to render `deposited_balance + won_balance` as a single figure,
 * and show the winnings separately only when they were above zero. Both halves
 * of that are wrong for this system, because the split is not presentational --
 * db/20-post/007 pays out `won_balance` ONLY. Deposits are deliberately not
 * withdrawable (20251217172433), since paying them out would make the game a way
 * to move money in and straight back out, which is the shape of every laundering
 * complaint a payment provider will ever make about one.
 *
 * So a player with 10.00 deposited and nothing won sees a Withdraw button that
 * is greyed out, a balance that says 10.00, and NOTHING on screen connecting the
 * two. Summing the balances hides the rule the database enforces. Hiding the won
 * balance at zero hides it at exactly the moment it needs explaining.
 *
 * Both are always shown, therefore, with the words "play" and "win" doing the
 * work an icon cannot.
 *
 * WHY PENDING IS SHOWN AGAINST THE WIN BALANCE.
 *
 * request_bank_withdrawal() computes what you may ask for as
 *
 *     won_balance - everything already pending or processing
 *
 * and payouts here are an operator sending money by hand from their own bank
 * account, which can sit for hours. A player who requests 50 and then looks at
 * their balance sees a number that does not match what they can actually
 * withdraw; if they ask again they get INSUFFICIENT_BALANCE for a reason that is
 * invisible from this screen, and it reads as the game being broken.
 *
 * Showing the pending figure is what makes that arithmetic legible. It is the
 * one thing a faster, automated competitor does not need and we do.
 *
 * EVERY READ HERE IS PLAIN DATA ACCESS, under policies that already exist:
 * 006 scopes deposit_requests to `player_id = auth.uid()`, 007 scopes
 * withdrawal_requests through telegram_users. Neither needs a route -- 006 says
 * so explicitly -- so this component talks to PostgREST and RLS decides what it
 * sees. If it ever returns somebody else's row, that is a policy bug and not a
 * bug here.
 */

import { useState, useEffect, useCallback } from 'react';
import { supabase } from '../lib/supabase';
import { formatBnb } from '../utils/formatBalance';

interface WalletSummaryProps {
  telegramUserId: number | null;
  depositedBalance: number;
  wonBalance: number;
  isDarkMode: boolean;
  /**
   * Bumped when the realtime subscription sees this player's row change.
   *
   * Two jobs. It flashes the panel -- the lobby used to do that on the summed
   * balance cell that this component replaced, and losing the signal would be a
   * regression: an approved deposit is the moment a player most wants
   * confirmation, and they may have been waiting on an operator for a while.
   *
   * And it re-reads the activity list, so a claim moving pending -> approved
   * shows up immediately rather than on the next 30s poll. The subscription
   * already exists; this just stops the two views disagreeing for half a minute.
   */
  changeSignal?: number;
}

interface Activity {
  id: string;
  kind: 'deposit' | 'withdrawal';
  amount: number;
  status: string;
  at: string;
  detail: string | null;
}

/** Compact and unambiguous — "3h" beats a timestamp nobody reads on a phone. */
function ago(iso: string): string {
  const mins = Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

export function WalletSummary({
  telegramUserId,
  depositedBalance,
  wonBalance,
  isDarkMode,
  changeSignal = 0,
}: WalletSummaryProps) {
  const [pending, setPending] = useState(0);
  const [activity, setActivity] = useState<Activity[]>([]);

  // TRANSIENT. Driven off changeSignal rather than read from it directly:
  // `changeSignal > 0` is true forever after the first change, which is a
  // permanent 2% scale rather than a flash. The first render is skipped too --
  // an initial mount is not a balance change and should not animate.
  const [flash, setFlash] = useState(false);
  useEffect(() => {
    if (changeSignal === 0) return;
    setFlash(true);
    const t = setTimeout(() => setFlash(false), 1200);
    return () => clearTimeout(t);
  }, [changeSignal]);

  const load = useCallback(async () => {
    if (telegramUserId === null) return;

    // Both reads are owner-scoped by RLS. The filters below are for efficiency
    // and clarity, NOT for authorization -- removing them would return the same
    // rows, because the policy is what decides.
    const [{ data: withdrawals }, { data: deposits }] = await Promise.all([
      supabase
        .from('withdrawal_requests')
        .select('id, amount, status, requested_at, bank_name, rejection_reason')
        .order('requested_at', { ascending: false })
        .limit(5),
      supabase
        .from('deposit_requests')
        .select('id, claimed_amount, credited_amount, status, created_at, bank_name, admin_note')
        .order('created_at', { ascending: false })
        .limit(5),
    ]);

    // Matches request_bank_withdrawal's own definition of what is in flight.
    setPending(
      (withdrawals ?? [])
        .filter((w) => w.status === 'pending' || w.status === 'processing')
        .reduce((sum, w) => sum + Number(w.amount), 0),
    );

    const merged: Activity[] = [
      ...(withdrawals ?? []).map((w) => ({
        id: `w-${w.id}`,
        kind: 'withdrawal' as const,
        amount: Number(w.amount),
        status: w.status,
        at: w.requested_at,
        detail: w.status === 'rejected' ? w.rejection_reason : w.bank_name,
      })),
      ...(deposits ?? []).map((d) => ({
        id: `d-${d.id}`,
        kind: 'deposit' as const,
        // The CREDITED amount once decided, not what the player typed. Those are
        // separate columns precisely because the operator reads a statement --
        // showing the claim after a decision would misreport what they received.
        amount: Number(d.credited_amount ?? d.claimed_amount),
        status: d.status,
        at: d.created_at,
        detail: d.status === 'rejected' ? d.admin_note : d.bank_name,
      })),
    ]
      .sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime())
      .slice(0, 5);

    setActivity(merged);
  }, [telegramUserId]);

  useEffect(() => {
    void load();
    // The poll is the floor, not the mechanism. It catches an operator decision
    // made while this tab was backgrounded and the realtime event was missed.
    const t = setInterval(() => { if (!document.hidden) void load(); }, 30_000);
    return () => clearInterval(t);
  }, [load, changeSignal]);

  const available = Math.max(0, wonBalance - pending);
  const dim = isDarkMode ? 'text-gray-500' : 'text-gray-400';
  const card = isDarkMode
    ? 'bg-gray-800/60 border-gray-700/40'
    : 'bg-white border-gray-200/70';

  return (
    <div className={`mb-3 space-y-2 transition-transform duration-500 ${flash ? 'scale-[1.02]' : ''}`}>
      <div className="grid grid-cols-2 gap-2">
        <div className={`rounded-xl border p-3 ${card}`}>
          <p className={`text-[10px] font-semibold uppercase tracking-wide ${dim}`}>
            Play balance
          </p>
          <p className={`text-lg font-bold tabular-nums ${isDarkMode ? 'text-emerald-400' : 'text-emerald-600'}`}>
            {formatBnb(depositedBalance)}
          </p>
          <p className={`text-[10px] ${dim}`}>For joining games</p>
        </div>

        <div className={`rounded-xl border p-3 ${card}`}>
          <p className={`text-[10px] font-semibold uppercase tracking-wide ${dim}`}>
            Winnings
          </p>
          <p className={`text-lg font-bold tabular-nums ${isDarkMode ? 'text-yellow-400' : 'text-yellow-600'}`}>
            {formatBnb(available)}
          </p>
          {/* The line that stops "why is Withdraw greyed out?" being a support
              message. Shown at zero too -- that is when it is needed most. */}
          <p className={`text-[10px] ${dim}`}>
            {pending > 0 ? `${formatBnb(pending)} awaiting payout` : 'Withdrawable'}
          </p>
        </div>
      </div>

      {activity.length > 0 && (
        <div className={`rounded-xl border p-3 ${card}`}>
          <p className={`text-[10px] font-semibold uppercase tracking-wide mb-2 ${dim}`}>
            Recent activity
          </p>
          <ul className="space-y-1.5">
            {activity.map((a) => (
              <li key={a.id} className="flex items-baseline justify-between gap-2 text-xs">
                <span className={`truncate ${isDarkMode ? 'text-gray-300' : 'text-gray-700'}`}>
                  {a.kind === 'deposit' ? 'Deposit' : 'Withdrawal'}
                  {a.detail ? <span className={dim}> · {a.detail}</span> : null}
                </span>
                <span className="flex shrink-0 items-baseline gap-2">
                  <span className={`tabular-nums ${isDarkMode ? 'text-gray-200' : 'text-gray-900'}`}>
                    {formatBnb(a.amount)}
                  </span>
                  <span
                    className={
                      a.status === 'rejected'
                        ? 'text-red-400'
                        : a.status === 'pending' || a.status === 'processing'
                          ? isDarkMode ? 'text-amber-400' : 'text-amber-600'
                          : isDarkMode ? 'text-emerald-400' : 'text-emerald-600'
                    }
                  >
                    {a.status === 'completed' ? 'paid' : a.status}
                  </span>
                  <span className={dim}>{ago(a.at)}</span>
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
