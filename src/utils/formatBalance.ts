/**
 * Money, in the unit the database actually stores.
 *
 * THE BUG THIS REPLACES, and how it was proven.
 *
 * This file used to be:
 *
 *     const CREDITS_PER_BNB = 100;
 *     export function formatBnb(credits) { return (credits / 100).toFixed(2); }
 *
 * which was correct when the game was denominated in BNB and one BNB bought a
 * hundred credits. It stopped being correct when the bank rail became the only
 * rail: a player transfers BIRR, types the number of birr into the deposit form,
 * and `claimed_amount` stores exactly that integer.
 *
 * So the divisor turned every figure on the player's screen into one hundredth
 * of itself, while the operator's queue -- which prints the raw column -- showed
 * the real number. The same value appeared as both, on the same system:
 *
 *     deposit queue     credited 10
 *     player's balance  0.10 BNB
 *
 * Confirmed on the live dev environment rather than argued from the code. A
 * player deposited 10, then 40, and played one game at a stake of 10:
 *
 *     10 + 40 - 10 = 40   and the app displayed  0.40
 *
 * The arithmetic was right the whole time. Only the presentation was wrong, and
 * wrong by a factor of a hundred on the screen people use to decide whether they
 * can afford to play.
 *
 * AND THE LABEL WAS WRONG TOO. "0.10 BNB" is, at real rates, roughly sixty
 * dollars. The player had sent ten birr. An operator reconciling a bank
 * statement against that screen is reading a number in a currency nobody
 * involved is using.
 *
 * SO: no divisor, and the unit is named. One integer in the database is one
 * birr.
 *
 * WHAT ABOUT THE CRYPTO PATH? It is deferred behind VITE_CRYPTO_ENABLED, and
 * when it returns it needs a REAL conversion -- a rate, from somewhere
 * authoritative, not a constant compiled into the bundle. A fixed
 * CREDITS_PER_BNB was only defensible while the two currencies were the same
 * thing by definition, which they never were. See src/lib/features.ts.
 */

/** ISO code, for anywhere the Amharic label would be ambiguous. */
export const CURRENCY_CODE = 'ETB';

/** Amharic, for player-facing surfaces. */
export const CURRENCY_LABEL = 'ብር';

/**
 * Whole birr, grouped.
 *
 * NO DECIMALS. The column is an integer, every amount a player types is whole
 * birr, and rendering `40.00` invites somebody to try `40.50` in a field that
 * would floor it without saying so.
 *
 * The unit is a separate export so a call site can choose: a table with the
 * currency in its header should not repeat it on every row.
 */
export function formatBirr(amount: number): string {
  if (!Number.isFinite(amount)) return '0';
  return Math.round(amount).toLocaleString('en-US');
}

/** The amount with its unit, for standalone figures. */
export function formatBirrWithUnit(amount: number): string {
  return `${formatBirr(amount)} ${CURRENCY_LABEL}`;
}
