import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};

interface UpdateSettingRequest {
  key: string;
  value: string;
  adminKey: string;
}

/**
 * Constant-time string comparison, so the admin key cannot be recovered by
 * timing the response. Length is compared first and then every byte is mixed in
 * regardless of early mismatches.
 */
function timingSafeEqual(a: string | undefined, b: string): boolean {
  if (typeof a !== "string") return false;
  const encoder = new TextEncoder();
  const bufA = encoder.encode(a);
  const bufB = encoder.encode(b);
  if (bufA.length !== bufB.length) return false;
  let diff = 0;
  for (let i = 0; i < bufA.length; i++) {
    diff |= bufA[i] ^ bufB[i];
  }
  return diff === 0;
}

/**
 * Keys an admin may change at runtime.
 *
 * Anything not listed here is rejected. Previously this function upserted ANY
 * key, which meant an ADMIN_KEY compromise let an attacker repoint
 * `deposit_contract_address` or `deposit_bsc_rpc_url` at infrastructure they
 * control, or overwrite `withdrawal_contract_private_key` outright.
 *
 * Contract addresses, chain IDs and RPC URLs are deliberately absent: they are
 * deploy-time infrastructure, not operator tunables. Change them through a
 * migration or the infra pipeline, not from a browser. The client only ever
 * READS them (WalletDepositModal.tsx:116, BnbWithdrawalModal.tsx:219), so
 * excluding them breaks nothing.
 */
const ALLOWED_KEYS = new Set<string>([
  // Telegram / presentation
  "telegram_bot_token", // TODO(phase4): move to the secret store, then drop from this list
  "telegram_bot_username",
  "support_contact",
  "user_instructions",
  "game_url",
  // Economics
  "commission_rate",
  "deposit_conversion_rate",
  "deposit_minimum_bnb",
  "deposit_required_confirmations",
  "withdrawal_credits_to_bnb_rate",
  "withdrawal_min_bnb",
  "withdrawal_max_daily_bnb",
  "withdrawal_max_weekly_bnb",
  "withdrawal_low_balance_threshold",
  // Admin connectivity check (Admin.tsx:421)
  "test",
]);

/**
 * Keys that must never be writable through this endpoint, called out separately
 * so the rejection is explicit rather than an incidental allowlist miss.
 */
const FORBIDDEN_KEYS = new Set<string>([
  "withdrawal_contract_private_key",
  "deposit_contract_private_key",
  "deposit_contract_address",
  "withdrawal_contract_address",
  "deposit_bsc_rpc_url",
  "deposit_contract_chain_id",
]);

/** Bounds for numeric settings that directly move money. */
const NUMERIC_BOUNDS: Record<string, { min: number; max: number }> = {
  commission_rate: { min: 0, max: 50 },
  deposit_conversion_rate: { min: 1, max: 100_000_000 },
  deposit_required_confirmations: { min: 1, max: 100 },
  withdrawal_credits_to_bnb_rate: { min: 1, max: 100_000_000 },
};

function validateSetting(key: string, value: string): string | null {
  if (FORBIDDEN_KEYS.has(key)) {
    return `Setting '${key}' cannot be changed here. It is deploy-time infrastructure or a secret.`;
  }
  if (!ALLOWED_KEYS.has(key)) {
    return `Unknown setting '${key}'.`;
  }

  const bounds = NUMERIC_BOUNDS[key];
  if (bounds) {
    const parsed = Number(value);
    if (!Number.isFinite(parsed)) {
      return `Setting '${key}' must be a number.`;
    }
    if (parsed < bounds.min || parsed > bounds.max) {
      return `Setting '${key}' must be between ${bounds.min} and ${bounds.max}.`;
    }
  }

  return null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 200,
      headers: corsHeaders,
    });
  }

  try {
    const { key, value, adminKey }: UpdateSettingRequest = await req.json();
    const validAdminKey = Deno.env.get("ADMIN_KEY");

    if (!validAdminKey || !timingSafeEqual(adminKey, validAdminKey)) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        {
          status: 401,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json",
          },
        }
      );
    }

    if (key === undefined || key === null || key === '' || value === undefined || value === null) {
      return new Response(
        JSON.stringify({ error: "key and value are required" }),
        {
          status: 400,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json",
          },
        }
      );
    }

    const validationError = validateSetting(key, value);
    if (validationError) {
      console.error(`Rejected settings write: key=${key}`);
      return new Response(
        JSON.stringify({ error: validationError }),
        {
          status: 403,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json",
          },
        }
      );
    }

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const { data, error } = await supabaseClient
      .from("settings")
      .upsert({
        id: key,
        value: value,
        updated_at: new Date().toISOString(),
        updated_by: "admin",
      }, {
        onConflict: "id"
      })
      .select()
      .maybeSingle();

    if (error) {
      // Log the detail server-side; do not leak raw DB errors to the caller.
      console.error("Settings upsert failed:", error.message);
      return new Response(
        JSON.stringify({ error: "Failed to update setting" }),
        {
          status: 500,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json",
          },
        }
      );
    }

    return new Response(
      JSON.stringify({ success: true, data }),
      {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      }
    );
  } catch (error) {
    console.error("Error updating setting:", error);
    return new Response(
      JSON.stringify({ error: error.message }),
      {
        status: 500,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      }
    );
  }
});