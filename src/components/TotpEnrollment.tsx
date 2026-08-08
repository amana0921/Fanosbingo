/**
 * Enrolling the second factor for money-moving admin actions.
 *
 * WHY THIS COMPONENT EXISTS AT ALL: the endpoints shipped without it, so the
 * only way to enrol was to POST to the API by hand with a bearer token. An
 * operator opening https://app.<domain>/admin/totp/enroll saw the game, because
 * `app.` is the SPA and Caddy falls back to index.html for any unknown path --
 * the endpoint lives on `api.`, is a POST, and needs a token. A control nobody
 * can turn on is not a control.
 *
 * NO QR CODE, DELIBERATELY.
 *
 * The obvious design shows a QR for the operator to scan. That is exactly wrong
 * here: this is a Telegram Mini App, so the operator is holding the phone the
 * QR would be displayed ON, and a phone cannot scan its own screen. They would
 * need a second device to enrol on the first.
 *
 * So the secret is shown as text to type into an authenticator, and the
 * otpauth:// URI is offered as a LINK -- tapping it on the same phone opens the
 * authenticator app and pre-fills the entry, which is faster than a QR would
 * have been and needs no QR library in a bundle these players download over
 * Ethiopian mobile networks.
 */

import { useState } from 'react';
import { getAccessToken } from '../lib/auth';

const API = import.meta.env.VITE_API_BASE_URL ?? import.meta.env.VITE_SUPABASE_URL;

interface Props {
  /** From /admin/whoami. */
  enrolled: boolean;
  started: boolean;
  onEnrolled: () => void;
}

export function TotpEnrollment({ enrolled, started, onEnrolled }: Props) {
  const [secret, setSecret] = useState<string | null>(null);
  const [uri, setUri] = useState<string | null>(null);
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function post(path: string, body?: unknown) {
    const token = await getAccessToken();
    const res = await fetch(`${API}/functions/v1/admin/totp/${path}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body ?? {}),
    });
    return { res, json: await res.json().catch(() => ({})) };
  }

  async function begin() {
    setBusy(true);
    setError(null);
    try {
      const { res, json } = await post('enroll');
      if (!res.ok) {
        setError(json.error ?? `Could not start enrolment (${res.status})`);
        return;
      }
      setSecret(json.secret);
      setUri(json.uri);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Network error');
    } finally {
      setBusy(false);
    }
  }

  async function confirm() {
    setBusy(true);
    setError(null);
    try {
      const { res, json } = await post('confirm', { totp: code.trim() });
      if (!res.ok) {
        // The most likely failure by far is a mistyped code or a phone whose
        // clock has drifted, so say both rather than "invalid".
        setError(
          json.code === 'TOTP_INVALID'
            ? 'That code was not accepted. Check you typed the current one, and that your phone clock is correct.'
            : (json.error ?? `Could not confirm (${res.status})`),
        );
        return;
      }
      setSecret(null);
      setUri(null);
      setCode('');
      onEnrolled();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Network error');
    } finally {
      setBusy(false);
    }
  }

  if (enrolled) {
    return (
      <div className="rounded-xl border border-green-200 bg-green-50 p-4">
        <p className="font-semibold text-green-900">Two-factor is on for money actions</p>
        <p className="mt-1 text-sm text-green-800">
          Approving a deposit or recording a payout will ask for a 6-digit code. Reading the
          queues, ending a game and changing settings will not.
        </p>
        <p className="mt-2 text-xs text-green-700">
          Lost your phone? This cannot be reset from here on purpose — a self-service reset
          would be a one-factor way to remove the second factor. It needs database access.
        </p>
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-amber-200 bg-amber-50 p-4">
      <p className="font-semibold text-amber-900">Two-factor is not set up</p>
      <p className="mt-1 text-sm text-amber-800">
        Anyone with your open session can approve deposits and record payouts. Setting this up
        means those two actions ask for a code from your phone — nothing else changes.
      </p>

      {error && (
        <p className="mt-3 rounded-lg bg-red-100 px-3 py-2 text-sm text-red-800">{error}</p>
      )}

      {!secret && (
        <button
          onClick={begin}
          disabled={busy}
          className="mt-3 rounded-lg bg-amber-600 px-4 py-2 font-medium text-white hover:bg-amber-700 disabled:opacity-50"
        >
          {busy ? 'Starting…' : started ? 'Start again' : 'Set up two-factor'}
        </button>
      )}

      {secret && (
        <div className="mt-4 space-y-3">
          <div>
            <p className="text-sm font-medium text-amber-900">
              1. Add this key to your authenticator app
            </p>
            {/* Selectable and monospace: this gets typed or copied, and a
                mis-read character produces codes that never work with no
                indication of why. */}
            <code className="mt-1 block select-all break-all rounded-lg bg-white px-3 py-2 font-mono text-sm tracking-wider text-gray-900">
              {secret}
            </code>
            {uri && (
              <a
                href={uri}
                className="mt-2 inline-block text-sm font-medium text-amber-800 underline"
              >
                Or tap here to open your authenticator app
              </a>
            )}
            <p className="mt-1 text-xs text-amber-700">
              Shown once. It cannot be read back after you leave this screen.
            </p>
          </div>

          <div>
            <p className="text-sm font-medium text-amber-900">
              2. Enter the 6-digit code it shows
            </p>
            <div className="mt-1 flex gap-2">
              <input
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
                inputMode="numeric"
                autoComplete="one-time-code"
                placeholder="123456"
                className="w-32 rounded-lg border border-amber-300 px-3 py-2 font-mono tracking-widest"
              />
              <button
                onClick={confirm}
                disabled={busy || code.length !== 6}
                className="rounded-lg bg-amber-600 px-4 py-2 font-medium text-white hover:bg-amber-700 disabled:opacity-50"
              >
                {busy ? 'Checking…' : 'Confirm'}
              </button>
            </div>
            <p className="mt-1 text-xs text-amber-700">
              Nothing is enforced until this succeeds, so a mistake here cannot lock you out of
              your own queue.
            </p>
          </div>
        </div>
      )}
    </div>
  );
}
