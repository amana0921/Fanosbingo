import { useState, useEffect, useCallback } from 'react';
import { RefreshCw, Check, X, AlertTriangle, Copy } from 'lucide-react';
import { getAccessToken } from '../lib/auth';

/**
 * The operator's payout worklist — the mirror of BankDepositQueue.
 *
 * WHAT THE OPERATOR IS ACTUALLY DOING: sending money from their own TeleBirr or
 * bank account, by hand, to the destination shown here, and then recording that
 * they did. Nothing on this screen moves money. Pressing "Mark paid" AFTER the
 * transfer is what deducts the balance.
 *
 * THE ASYMMETRY WITH DEPOSITS, and why this screen is stricter.
 *
 * A deposit approved wrongly costs the house what the player did not send. A
 * withdrawal paid TWICE is real money out of a real bank account, and a TeleBirr
 * transfer does not reverse. So:
 *
 *   The reference field starts EMPTY and is required. It is the receipt for the
 *   transfer the operator has already sent, and db/20-post/007 puts a unique
 *   index on lower(payout_reference) -- so recording the same receipt against a
 *   second request is refused by the DATABASE, not merely by this form. That
 *   index is the double-payment guard, and prefilling anything generated would
 *   make every payout trivially unique and disarm it.
 *
 *   The destination is copyable rather than retyped. An account number
 *   transcribed by eye is how money reaches the wrong person, and that error is
 *   not recoverable either.
 *
 *   Rejecting requires a reason, because the player is shown it. "Rejected" with
 *   no explanation generates a support message nobody can answer.
 *
 * A 409 means somebody already decided this one, or the reference is already
 * recorded elsewhere. Both reload rather than retry: the useful thing is the
 * current state, and a retry on a payout is the one thing that must not happen
 * automatically.
 */

interface WithdrawalRequest {
  id: string;
  amount: number;
  bank_name: string;
  account_number: string;
  account_name: string;
  status: string;
  requested_at: string;
  processed_at: string | null;
  payout_reference: string | null;
  rejection_reason: string | null;
  admin_notes: string | null;
  telegram_user_id: number;
  telegram_username: string | null;
  telegram_first_name: string | null;
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

export function BankWithdrawalQueue() {
  const [requests, setRequests] = useState<WithdrawalRequest[]>([]);
  const [status, setStatus] = useState<'pending' | 'completed' | 'rejected'>('pending');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [references, setReferences] = useState<Record<string, string>>({});
  const [reasons, setReasons] = useState<Record<string, string>>({});
  const [copied, setCopied] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const token = await getAccessToken();
      const res = await fetch(`${API}/functions/v1/admin/withdrawals?status=${status}`, {
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

  useEffect(() => {
    void load();
  }, [load]);

  const copy = async (id: string, value: string) => {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(id);
      setTimeout(() => setCopied(null), 1500);
    } catch {
      /* clipboard unavailable; the value is selectable on screen anyway */
    }
  };

  const decide = async (id: string, action: 'complete' | 'reject') => {
    let body: Record<string, unknown>;

    if (action === 'complete') {
      const reference = references[id]?.trim();
      // Refused here as well as by the API. The API is the control; this is so
      // the operator gets an answer without a round trip.
      if (!reference || reference.length < 3) {
        setError('Enter the reference from the transfer you sent before marking it paid.');
        return;
      }
      body = { payoutReference: reference };
    } else {
      const reason = reasons[id]?.trim();
      if (!reason || reason.length < 3) {
        setError('Enter a reason. The player is shown it.');
        return;
      }
      body = { reason };
    }

    setBusyId(id);
    setError(null);
    try {
      const token = await getAccessToken();
      const res = await fetch(`${API}/functions/v1/admin/withdrawals/${id}/${action}`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });

      const result = await res.json().catch(() => ({}));

      if (res.status === 409) {
        // Three distinct causes, and the operator needs to know which.
        if (result.error_code === 'DUPLICATE_REFERENCE') {
          setError(
            'That payout reference is already recorded against another request. ' +
              'Check whether this one has already been paid before sending again.',
          );
        } else if (result.error_code === 'CONSTRAINT_VIOLATION') {
          setError(result.error ?? 'The database refused this payout.');
        } else {
          setError('That request was already decided. Reloading the queue.');
        }
        await load();
        return;
      }

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
          <h2 className="text-2xl font-bold text-gray-900">Bank withdrawal queue</h2>
          <p className="text-sm text-gray-500 mt-1">
            Send the money first, then record the reference. Marking paid deducts the balance.
          </p>
        </div>
        <div className="flex items-center gap-2">
          {(['pending', 'completed', 'rejected'] as const).map((s) => (
            <button
              key={s}
              onClick={() => setStatus(s)}
              className={`px-3 py-1.5 rounded-lg text-sm font-medium capitalize ${
                status === s
                  ? 'bg-blue-600 text-white'
                  : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
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
                  {r.telegram_username
                    ? `@${r.telegram_username}`
                    : r.telegram_first_name || 'Player'}
                  <span className="ml-2 text-xs font-normal text-gray-500">
                    id {r.telegram_user_id}
                  </span>
                </p>
                <p className="text-sm text-gray-600 mt-1">
                  <span className="font-semibold text-gray-900">{r.amount} ETB</span>
                  <span className="mx-2 text-gray-300">|</span>
                  {r.bank_name}
                  <span className="mx-2 text-gray-300">|</span>
                  <span className="text-gray-500">
                    won balance {r.won_balance} ETB
                  </span>
                </p>

                {/* Copyable, not retyped. A mistranscribed account number sends
                    money to the wrong person, and that does not reverse either. */}
                <div className="mt-2 rounded-lg bg-gray-50 border border-gray-200 px-3 py-2">
                  <p className="text-xs text-gray-500 mb-1">Send to</p>
                  <div className="flex items-center gap-2 flex-wrap">
                    <span className="font-mono text-sm text-gray-900">{r.account_number}</span>
                    <button
                      onClick={() => void copy(r.id, r.account_number)}
                      className="p-1 rounded hover:bg-gray-200"
                      aria-label="Copy account number"
                    >
                      <Copy className="w-3.5 h-3.5 text-gray-500" />
                    </button>
                    {copied === r.id && <span className="text-xs text-green-600">copied</span>}
                  </div>
                  <p className="text-sm text-gray-700 mt-1">{r.account_name}</p>
                </div>
              </div>

              <span className="text-xs text-gray-500 whitespace-nowrap">
                waiting {waitingFor(r.requested_at)}
              </span>
            </div>

            {r.status === 'pending' && (
              <div className="mt-3 flex flex-wrap items-center gap-2">
                <input
                  type="text"
                  value={references[r.id] ?? ''}
                  onChange={(e) => setReferences((p) => ({ ...p, [r.id]: e.target.value }))}
                  placeholder="Transfer reference"
                  className="px-3 py-1.5 border border-gray-300 rounded-lg text-sm w-44"
                />
                <button
                  onClick={() => void decide(r.id, 'complete')}
                  disabled={busyId === r.id}
                  className="inline-flex items-center gap-1 px-3 py-1.5 rounded-lg bg-green-600 text-white text-sm font-medium hover:bg-green-700 disabled:opacity-50"
                >
                  <Check className="w-4 h-4" /> Mark paid
                </button>

                <input
                  type="text"
                  value={reasons[r.id] ?? ''}
                  onChange={(e) => setReasons((p) => ({ ...p, [r.id]: e.target.value }))}
                  placeholder="Reason (if rejecting)"
                  className="px-3 py-1.5 border border-gray-300 rounded-lg text-sm w-52"
                />
                <button
                  onClick={() => void decide(r.id, 'reject')}
                  disabled={busyId === r.id}
                  className="inline-flex items-center gap-1 px-3 py-1.5 rounded-lg bg-gray-200 text-gray-800 text-sm font-medium hover:bg-gray-300 disabled:opacity-50"
                >
                  <X className="w-4 h-4" /> Reject
                </button>
              </div>
            )}

            {r.status !== 'pending' && (
              <p className="mt-2 text-xs text-gray-500">
                {r.status === 'completed'
                  ? `paid${r.payout_reference ? ` — ref ${r.payout_reference}` : ''}`
                  : `rejected${r.rejection_reason ? ` — ${r.rejection_reason}` : ''}`}
                {r.processed_at && ` on ${new Date(r.processed_at).toLocaleString()}`}
              </p>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
