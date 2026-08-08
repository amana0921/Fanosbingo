import { useState, useEffect, useCallback } from 'react';
import { RefreshCw, Check, X, AlertTriangle } from 'lucide-react';
import { getAccessToken } from '../lib/auth';

/**
 * The operator's deposit worklist.
 *
 * WHAT THE OPERATOR IS ACTUALLY DOING, which the UI should make obvious rather
 * than hide: reading their own bank statement and deciding whether the money
 * arrived. Nothing on this screen knows whether a claim is genuine. The claimed
 * amount is what the player typed into a box.
 *
 * TWO DELIBERATE UI DECISIONS, both of which encode a security property:
 *
 *   The amount field starts EMPTY. It is not prefilled with the claimed amount,
 *   because prefilling turns "what the player said" into "what we credited" for
 *   anyone who approves without looking -- which is precisely the mistake the
 *   separate credited_amount column exists to prevent. The operator types what
 *   the statement shows.
 *
 *   The claimed amount is labelled "player says". It is a hint for finding the
 *   transaction, not a number to trust.
 *
 * A 409 means somebody already decided this one -- a double-clicked button, or a
 * second operator working the same queue. It reloads rather than retrying,
 * because the correct response is to see the current state.
 */

interface DepositRequest {
  id: string;
  bank_name: string;
  reference_number: string;
  claimed_amount: number;
  credited_amount: number | null;
  status: string;
  created_at: string;
  decided_at: string | null;
  admin_note: string | null;
  telegram_user_id: number;
  telegram_username: string | null;
  telegram_first_name: string | null;
  deposited_balance: number;
  won_balance: number;
}

const API = import.meta.env.VITE_SUPABASE_URL;

function waitingFor(iso: string): string {
  const mins = Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ${mins % 60}m`;
  return `${Math.floor(hours / 24)}d`;
}

export function BankDepositQueue() {
  const [requests, setRequests] = useState<DepositRequest[]>([]);
  const [status, setStatus] = useState<'pending' | 'approved' | 'rejected'>('pending');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [amounts, setAmounts] = useState<Record<string, string>>({});
  const [notes, setNotes] = useState<Record<string, string>>({});

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const token = await getAccessToken();
      const res = await fetch(`${API}/functions/v1/admin/deposits?status=${status}`, {
        headers: { Authorization: `Bearer ${token}` },
      });

      if (res.status === 403) {
        setError('This account is not an admin.');
        setRequests([]);
        return;
      }
      if (!res.ok) throw new Error(`API returned ${res.status}`);

      const data = await res.json();
      setRequests(data.requests ?? []);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not load the queue');
    } finally {
      setLoading(false);
    }
  }, [status]);

  useEffect(() => { void load(); }, [load]);

  const decide = async (id: string, action: 'approve' | 'reject') => {
    const note = notes[id]?.trim() || undefined;

    let body: Record<string, unknown> = { note };

    if (action === 'approve') {
      const typed = amounts[id]?.trim();
      const actualAmount = Number(typed);

      // Refused in the UI as well as the API. The API is the control; this is so
      // the operator gets an answer immediately rather than a round trip.
      if (!typed || !Number.isInteger(actualAmount) || actualAmount <= 0) {
        setError('Enter the amount shown on the bank statement before approving.');
        return;
      }
      body = { actualAmount, note };
    }

    setBusyId(id);
    setError(null);
    try {
      const token = await getAccessToken();
      const res = await fetch(`${API}/functions/v1/admin/deposits/${id}/${action}`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });


      if (res.status === 428) {
        // The second factor. NOT an auth failure -- the session is fine, and
        // treating it as one would send the operator to re-login, which cannot
        // help. Ask for the code and retry the same action.
        //
        // Prompted at the moment of approval rather than at sign-in, which is
        // the whole point: a session left open otherwise credits freely. See
        // db/20-post/016.
        const code = window.prompt(
          'Approving money requires your authenticator code.\n\nEnter the 6-digit code:',
        );
        if (!code) {
          setError('Cancelled. Nothing was approved.');
          return;
        }

        const retry = await fetch(`${API}/functions/v1/admin/deposits/${id}/${action}`, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${token}`,
            'Content-Type': 'application/json',
            'X-Admin-TOTP': code.trim(),
          },
          body: JSON.stringify(body),
        });

        if (retry.status === 428) {
          setError('That code was not accepted. Check your authenticator and try again.');
          return;
        }

        const retried = await retry.json();
        if (!retry.ok || !retried.success) {
          setError(retried.error ?? `Request failed (${retry.status})`);
          return;
        }

        await load();
        return;
      }

      if (res.status === 409) {
        // Already decided. Reload rather than retry: somebody else got there, or
        // the button was pressed twice, and the useful thing is the current state.
        setError('That request was already decided. Reloading the queue.');
        await load();
        return;
      }

      const result = await res.json();
      if (!res.ok || !result.success) {
        setError(result.error ?? `Request failed (${res.status})`);
        return;
      }

      await load();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Request failed');
    } finally {
      setBusyId(null);
    }
  };

  return (
    <div className="bg-white rounded-2xl shadow-xl p-6">
      <div className="flex items-center justify-between mb-4 flex-wrap gap-3">
        <div>
          <h2 className="text-2xl font-bold text-gray-900">Bank deposit queue</h2>
          <p className="text-sm text-gray-500 mt-1">
            Check your bank statement before approving. Amounts here are what the player typed.
          </p>
        </div>
        <div className="flex items-center gap-2">
          {(['pending', 'approved', 'rejected'] as const).map((s) => (
            <button
              key={s}
              onClick={() => setStatus(s)}
              className={`px-3 py-1.5 rounded-lg text-sm font-medium capitalize ${
                status === s ? 'bg-blue-600 text-white' : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
              }`}
            >
              {s}
            </button>
          ))}
          <button
            onClick={() => void load()}
            className="p-2 rounded-lg bg-gray-100 hover:bg-gray-200"
            aria-label="Refresh"
          >
            <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
          </button>
        </div>
      </div>

      {error && (
        <div className="mb-4 flex items-start gap-2 rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
          <span>{error}</span>
        </div>
      )}

      {loading && requests.length === 0 && (
        <p className="text-gray-500 py-8 text-center">Loading…</p>
      )}

      {!loading && requests.length === 0 && !error && (
        <p className="text-gray-500 py-8 text-center">Nothing {status}.</p>
      )}

      <div className="space-y-3">
        {requests.map((r) => (
          <div key={r.id} className="border border-gray-200 rounded-xl p-4">
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div className="min-w-0">
                <p className="font-semibold text-gray-900">
                  {r.telegram_username ? `@${r.telegram_username}` : r.telegram_first_name || 'Player'}
                  <span className="ml-2 text-xs font-normal text-gray-500">
                    id {r.telegram_user_id}
                  </span>
                </p>
                <p className="text-sm text-gray-600 mt-1">
                  <span className="font-medium">{r.bank_name}</span>
                  {' · ref '}
                  {/* Selectable and monospaced: the operator is comparing this
                      against a statement character by character. */}
                  <code className="select-all bg-gray-100 px-1.5 py-0.5 rounded">
                    {r.reference_number}
                  </code>
                </p>
                <p className="text-xs text-gray-500 mt-1">
                  waiting {waitingFor(r.created_at)} · balance {r.deposited_balance} deposited,{' '}
                  {r.won_balance} won
                </p>
              </div>

              <div className="text-right shrink-0">
                <p className="text-xs uppercase tracking-wide text-gray-400">player says</p>
                <p className="text-xl font-bold text-gray-900">{r.claimed_amount}</p>
              </div>
            </div>

            {r.status === 'pending' ? (
              <div className="mt-4 flex flex-wrap items-end gap-2">
                <div>
                  <label className="block text-xs font-medium text-gray-600 mb-1">
                    Amount on your statement
                  </label>
                  {/* NOT prefilled with claimed_amount, on purpose. See the header. */}
                  <input
                    type="number"
                    inputMode="numeric"
                    placeholder="required"
                    value={amounts[r.id] ?? ''}
                    onChange={(e) => setAmounts((a) => ({ ...a, [r.id]: e.target.value }))}
                    className="w-32 px-3 py-2 border border-gray-300 rounded-lg text-sm"
                  />
                </div>
                <div className="flex-1 min-w-[10rem]">
                  <label className="block text-xs font-medium text-gray-600 mb-1">Note (optional)</label>
                  <input
                    type="text"
                    value={notes[r.id] ?? ''}
                    onChange={(e) => setNotes((n) => ({ ...n, [r.id]: e.target.value }))}
                    className="w-full px-3 py-2 border border-gray-300 rounded-lg text-sm"
                  />
                </div>
                <button
                  disabled={busyId === r.id}
                  onClick={() => void decide(r.id, 'approve')}
                  className="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-green-600 text-white text-sm font-medium disabled:opacity-50"
                >
                  <Check className="w-4 h-4" /> Approve
                </button>
                <button
                  disabled={busyId === r.id}
                  onClick={() => void decide(r.id, 'reject')}
                  className="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-red-600 text-white text-sm font-medium disabled:opacity-50"
                >
                  <X className="w-4 h-4" /> Reject
                </button>
              </div>
            ) : (
              <div className="mt-3 text-sm text-gray-600">
                <span className={r.status === 'approved' ? 'text-green-700' : 'text-red-700'}>
                  {r.status}
                </span>
                {r.credited_amount !== null && (
                  <>
                    {' · credited '}
                    <span className="font-semibold">{r.credited_amount}</span>
                    {/* A mismatch is the interesting case and should not need
                        arithmetic to notice. */}
                    {r.credited_amount !== r.claimed_amount && (
                      <span className="text-amber-700"> (claimed {r.claimed_amount})</span>
                    )}
                  </>
                )}
                {r.admin_note && <span className="text-gray-500"> · {r.admin_note}</span>}
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
