/**
 * "Log in with Telegram" for a desktop browser.
 *
 * WHY THIS EXISTS. The admin panel needs a proven Telegram identity, and a
 * browser has no initData -- so the queues were reachable only from a phone,
 * inside the Mini App. An operator working a deposit backlog against their own
 * bank statement is doing keyboard work, and asking them to do it on a phone is
 * how a claim sits for a day.
 *
 * SAME IDENTITY, NOT A SECOND ONE. Telegram's Login Widget signs the same user
 * for a web page that initData signs for a Mini App. The token minted from it is
 * indistinguishable -- same uuid in `sub`, same 15-minute life, same role -- so
 * there is no second kind of admin, no second credential to store, and nothing
 * new for requireAdmin to understand. The `is_admin` flag on the row decides,
 * exactly as it does in the app.
 *
 * That is the whole reason to use the widget rather than invent a password: this
 * codebase already removed one shared-string admin key (see src/admin.js), and
 * adding a login form would be walking back to it by a different route.
 *
 * WHAT IT NEEDS FROM BOTFATHER: /setdomain, pointed at the origin this is served
 * from. Telegram refuses to render the widget on a domain the bot has not
 * claimed, which is exactly what stops any other site collecting logins for this
 * bot. If the button does not appear, that is the first thing to check.
 *
 * THE SCRIPT IS LOADED FROM TELEGRAM, which is worth being explicit about since
 * nothing else in this bundle is third-party at runtime. There is no way around
 * it -- the widget is Telegram's own, and self-hosting a copy would mean the
 * signature flow no longer involves the party that issues it. It is confined to
 * this component, which is lazily imported, so a player who never opens the
 * login page never fetches it.
 */

import { useEffect, useRef, useState } from 'react';

const API = import.meta.env.VITE_SUPABASE_URL;

/** Telegram calls this by name on `window`; the widget offers no other hook. */
declare global {
  interface Window {
    onTelegramAuth?: (user: Record<string, unknown>) => void;
  }
}

interface TelegramWebLoginProps {
  botUsername: string;
  onAuthenticated: (token: string) => void;
}

export function TelegramWebLogin({ botUsername, onAuthenticated }: TelegramWebLoginProps) {
  const holder = useRef<HTMLDivElement>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    window.onTelegramAuth = async (user) => {
      setBusy(true);
      setError(null);
      try {
        // The payload goes to the server EXACTLY as Telegram produced it.
        //
        // Nothing is read from it here, and nothing may be: the hash covers
        // every field, so trusting `user.id` before the server has checked the
        // signature would be the same defect auth.js exists to remove -- an
        // identity asserted by the client rather than proven.
        const res = await fetch(`${API}/functions/v1/auth/telegram/web`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(user),
        });

        const body = await res.json().catch(() => ({}));

        if (!res.ok || !body.token) {
          setError(
            res.status === 429
              ? 'Too many attempts. Wait a moment and try again.'
              : 'Telegram could not verify that login. Try again.',
          );
          return;
        }

        onAuthenticated(body.token);
      } catch {
        setError('Could not reach the server.');
      } finally {
        setBusy(false);
      }
    };

    // Injected rather than placed in index.html: it must not load for the
    // players who never see this screen, and the callback above has to exist
    // before the script runs.
    const script = document.createElement('script');
    script.src = 'https://telegram.org/js/telegram-widget.js?22';
    script.async = true;
    script.setAttribute('data-telegram-login', botUsername);
    script.setAttribute('data-size', 'large');
    script.setAttribute('data-userpic', 'false');
    script.setAttribute('data-request-access', 'write');
    script.setAttribute('data-onauth', 'onTelegramAuth(user)');

    const node = holder.current;
    node?.appendChild(script);

    return () => {
      delete window.onTelegramAuth;
      if (node) node.innerHTML = '';
    };
  }, [botUsername, onAuthenticated]);

  return (
    <div className="space-y-3">
      <div ref={holder} className="flex justify-center min-h-[48px] items-center">
        {busy && <span className="text-sm text-gray-500">Verifying…</span>}
      </div>

      {error && (
        <p className="text-sm text-red-600 text-center">{error}</p>
      )}

      <p className="text-xs text-gray-500 text-center">
        Signs you in as the same Telegram account you play with. Admin access is a
        flag on that account, checked by the server on every request.
      </p>
    </div>
  );
}
