/**
 * Proving who the player is, once, to the API.
 *
 * WHAT THIS REPLACES
 *
 * The app used to take its identity from `WebApp.initDataUnsafe` — the word
 * "Unsafe" is Telegram's, not ours — and then query with
 * `.eq('telegram_user_id', thatId)`. Nothing verified it. Anyone could edit the
 * value in a console and read another player's rows, because every request went
 * to the API as `anon` and the server had no way to know better.
 *
 * `WebApp.initData` is the *signed* form of the same payload. The API verifies
 * its HMAC against the bot token and, if it holds, returns a short-lived JWT
 * whose claims the database understands:
 *
 *   sub  = telegram_users.id   the UUID auth.uid() casts to
 *   role = authenticated       the role the RLS policies name
 *
 * From then on PostgREST puts those claims in `request.jwt.claims` and row level
 * security decides what this player can see — in the database, on every query,
 * rather than in whichever component remembered to filter.
 *
 * WHY THIS FILE HOLDS THE TOKEN RATHER THAN A REACT STATE
 *
 * supabase-js asks for the current token on every request through its
 * `accessToken` hook, including from Realtime reconnects that no component is
 * watching. It has to be readable synchronously from outside React.
 */

import WebApp from '@twa-dev/sdk';

const API_BASE = import.meta.env.VITE_API_BASE_URL ?? '';

/** The anon JWT. Requests carrying it are `anon`; RLS decides what that sees. */
const ANON_KEY = import.meta.env.VITE_SUPABASE_ANON_KEY ?? '';

export interface AuthenticatedUser {
  id: string;
  telegram_user_id: string;
  username?: string;
  first_name: string;
}

let token: string | null = null;
let expiresAt = 0;
let user: AuthenticatedUser | null = null;
let inFlight: Promise<AuthenticatedUser | null> | null = null;

/** Refresh this far before expiry, so a request never races the deadline. */
const REFRESH_MARGIN_MS = 60_000;

export function getAuthenticatedUser(): AuthenticatedUser | null {
  return user;
}

export function isAuthenticated(): boolean {
  return Boolean(token) && Date.now() < expiresAt;
}

/**
 * Exchange the signed initData for a session token.
 *
 * Concurrent callers share one request: the app authenticates from several
 * places at startup, and three simultaneous exchanges would create three
 * sessions for no reason.
 */
export async function authenticate(): Promise<AuthenticatedUser | null> {
  if (isAuthenticated() && user) return user;
  if (inFlight) return inFlight;

  inFlight = (async () => {
    try {
      // The SIGNED payload. initDataUnsafe is the parsed convenience form and
      // carries no signature — it must never be what we send.
      const initData = WebApp.initData;

      if (!initData) {
        // Opened outside Telegram: a browser tab, or a preview. Not an error,
        // just not a player we can identify.
        return null;
      }

      const res = await fetch(`${API_BASE}/functions/v1/auth/telegram`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ initData }),
      });

      if (!res.ok) {
        // A rejection here means the signature did not verify — a stale
        // payload, or the wrong bot token deployed. Both need a human.
        console.error('[auth] rejected by the API', res.status);
        return null;
      }

      const body = await res.json();

      token = body.token;
      // Deliberately early, by the margin: a token that expires mid-request
      // fails a query the player has already started.
      expiresAt = Date.now() + body.expires_in * 1000 - REFRESH_MARGIN_MS;
      user = body.user;

      return user;
    } catch (err) {
      console.error('[auth] exchange failed', err);
      return null;
    } finally {
      inFlight = null;
    }
  })();

  return inFlight;
}

/**
 * What supabase-js should send on the next request.
 *
 * Called on EVERY request and on every Realtime reconnect, so it must be cheap
 * and must never throw — returning the anon key is the correct degradation, and
 * RLS then shows the player only what anonymous users may see.
 */
export async function getAccessToken(): Promise<string | null> {
  if (isAuthenticated()) return token;

  // Expired or never obtained. Re-exchange; initData stays valid for the
  // session, so this is silent to the player.
  const refreshed = await authenticate();

  return refreshed ? token : ANON_KEY || null;
}

/** For sign-out and for tests. */
export function clearSession(): void {
  token = null;
  expiresAt = 0;
  user = null;
}
