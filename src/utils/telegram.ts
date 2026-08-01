import WebApp from '@twa-dev/sdk';

export interface TelegramUser {
  id: number;
  first_name: string;
  last_name?: string;
  username?: string;
  language_code?: string;
  is_premium?: boolean;
  photo_url?: string;
}

export interface TelegramWebAppData {
  user: TelegramUser | null;
  isAvailable: boolean;
  platform: string;
}

/**
 * Telegram's deep-link parameter, from `t.me/<bot>/<app>?startapp=<value>`.
 *
 * THIS COMES FROM initDataUnsafe, AND THAT IS FINE HERE -- but only because of
 * what it is used for.
 *
 * `initDataUnsafe` is Telegram's own word for "parsed but not verified", and
 * this codebase is right to be suspicious of it: the identity used to come from
 * there and was sent to the API as a telegram id the server could not check.
 * services/functions/src/auth.js exists to remove exactly that.
 *
 * Routing is not authorization. This value decides WHICH SCREEN RENDERS, and
 * nothing else. The admin panel it opens then asks the server `/admin/whoami`
 * with a token minted from VERIFIED initData, and every admin route enforces
 * requireAdmin server-side. Somebody who forges `startapp=admin` gets the login
 * form and a 403, which is what a non-admin gets by typing the URL today.
 *
 * The rule to keep: unverified input may choose a view. It may never grant one.
 */
export function getStartParam(): string | null {
  try {
    const raw = WebApp?.initDataUnsafe?.start_param;
    if (typeof raw !== 'string' || raw === '') return null;
    // Bounded and alphanumeric. It is used only for comparison, never
    // interpolated into a URL or the DOM, but an unbounded string from outside
    // has no business flowing anywhere unchecked.
    return /^[a-z0-9_-]{1,32}$/i.test(raw) ? raw : null;
  } catch {
    return null;
  }
}

export function initTelegram(): TelegramWebAppData {
  try {
    console.log('[Telegram] Initializing WebApp SDK...', {
      hasWindow: typeof window !== 'undefined',
      hasWebApp: !!WebApp,
      webAppVersion: WebApp?.version,
      platform: WebApp?.platform,
    });

    if (typeof window !== 'undefined' && WebApp) {
      WebApp.ready();
      WebApp.expand();

      console.log('[Telegram] WebApp.initDataUnsafe:', WebApp.initDataUnsafe);
      console.log('[Telegram] WebApp.initData:', WebApp.initData);

      const user = WebApp.initDataUnsafe?.user;

      if (user) {
        console.log('[Telegram] User detected:', {
          id: user.id,
          username: user.username,
          first_name: user.first_name,
        });

        return {
          user: {
            id: user.id,
            first_name: user.first_name,
            last_name: user.last_name,
            username: user.username,
            language_code: user.language_code,
            is_premium: user.is_premium,
            photo_url: user.photo_url,
          },
          isAvailable: true,
          platform: WebApp.platform,
        };
      } else {
        console.warn('[Telegram] WebApp initialized but no user data found');
      }
    } else {
      console.warn('[Telegram] WebApp SDK not available');
    }

    return {
      user: null,
      isAvailable: false,
      platform: 'unknown',
    };
  } catch (error) {
    console.error('[Telegram] Error initializing Telegram Web App:', error);
    return {
      user: null,
      isAvailable: false,
      platform: 'unknown',
    };
  }
}

export function getTelegramDisplayName(user: TelegramUser | null): string {
  if (!user) return '';

  if (user.username) {
    return `@${user.username}`;
  }

  return user.first_name + (user.last_name ? ` ${user.last_name}` : '');
}

export function closeTelegramApp(): void {
  try {
    if (WebApp) {
      WebApp.close();
    }
  } catch (error) {
    console.error('Error closing Telegram Web App:', error);
  }
}

export function showTelegramAlert(message: string): void {
  try {
    if (WebApp) {
      WebApp.showAlert(message);
    } else {
      alert(message);
    }
  } catch (error) {
    console.error('Error showing Telegram alert:', error);
    alert(message);
  }
}

export function enableTelegramClosingConfirmation(): void {
  try {
    if (WebApp) {
      WebApp.enableClosingConfirmation();
    }
  } catch (error) {
    console.error('Error enabling closing confirmation:', error);
  }
}

export function disableTelegramClosingConfirmation(): void {
  try {
    if (WebApp) {
      WebApp.disableClosingConfirmation();
    }
  } catch (error) {
    console.error('Error disabling closing confirmation:', error);
  }
}
