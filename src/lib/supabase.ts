/**
 * The data client.
 *
 * Still supabase-js, pointed at self-hosted infrastructure rather than a hosted
 * Supabase project. That is deliberate and is why this migration is tractable:
 * the URL shape was preserved (`/rest/v1`, `/realtime/v1`, `/functions/v1`), so
 * the ~200 `supabase.from()` call sites and the realtime subscriptions work
 * unchanged against PostgREST and the Realtime container we run ourselves.
 *
 * THE ONE REAL CHANGE IS `accessToken`.
 *
 * supabase-js calls that hook for every request and every Realtime reconnect,
 * and sends whatever it returns as the bearer token. Supplying it also turns
 * OFF supabase-js's built-in auth, which is what we want — identity comes from
 * Telegram, verified by our own API, not from GoTrue.
 *
 * The effect is that every query now arrives at PostgREST as a PROVEN player
 * rather than as `anon`, so the 47 RLS policies in the migrations finally do
 * something. Before this, identity was a telegram id the client asserted and
 * the server believed.
 */

import { createClient } from '@supabase/supabase-js';
import { getAccessToken } from './auth';

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL;
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error(
    'VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY are required. ' +
      'See .env.example — the URL is now this project\'s own API, not a supabase.co host.',
  );
}

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  // Returns the player's token once they have authenticated, and the anon key
  // before that. Never throws: a failure here would break every query, and
  // degrading to `anon` shows the player only what anonymous users may see.
  accessToken: getAccessToken,
});

export interface Game {
  id: string;
  status: 'waiting' | 'playing' | 'finished';
  current_number: number | null;
  called_numbers: number[];
  host_id: string;
  winner_ids: string[];
  winner_prize_each: number;
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
  starts_at: string;
  game_number: number;
  stake_amount: number;
  total_pot: number;
  winner_prize: number;
  claim_window_start: string | null;
  return_to_lobby_at: string | null;
}

export interface Player {
  id: string;
  game_id: string;
  name: string;
  card: number[][];
  card_numbers: number[][];
  marked_cells: boolean[][];
  is_host: boolean;
  joined_at: string;
  is_connected: boolean;
  selected_number: number;
  is_disqualified: boolean;
  disqualified_at: string | null;
  stake_paid: boolean;
  winning_pattern?: {
    type: string;
    description: string;
    cells: [number, number][];
  } | null;
}
