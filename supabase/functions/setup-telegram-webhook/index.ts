import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};

interface SetupWebhookRequest {
  adminKey: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 200,
      headers: corsHeaders,
    });
  }

  try {
    const { adminKey }: SetupWebhookRequest = await req.json();
    const validAdminKey = Deno.env.get("ADMIN_KEY");

    if (!validAdminKey || adminKey !== validAdminKey) {
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

    const supabaseClient = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const { data: settingData } = await supabaseClient
      .from("settings")
      .select("value")
      .eq("id", "telegram_bot_token")
      .single();

    const botToken = settingData?.value || Deno.env.get("TELEGRAM_BOT_TOKEN");
    
    if (!botToken) {
      return new Response(
        JSON.stringify({ error: "Bot token not configured" }),
        {
          status: 500,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json",
          },
        }
      );
    }

    const webhookUrl = `${Deno.env.get("SUPABASE_URL")}/functions/v1/telegram-bot-webhook`;

    // Refuse to register a webhook that cannot be authenticated. Registering
    // without a secret is precisely the state being repaired, so doing it
    // silently on a missing env var would quietly undo the fix.
    const webhookSecret = Deno.env.get("TELEGRAM_WEBHOOK_SECRET") ?? "";
    if (!webhookSecret) {
      return new Response(
        JSON.stringify({
          error: "TELEGRAM_WEBHOOK_SECRET is not set",
          detail:
            "Refusing to register a webhook with no secret_token -- Telegram would send no verifiable header and the handler would reject every delivery. Set it with: supabase secrets set TELEGRAM_WEBHOOK_SECRET=...",
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const telegramResponse = await fetch(
      `https://api.telegram.org/bot${botToken}/setWebhook`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        // secret_token is what makes the webhook verifiable at all. Telegram
        // echoes it in X-Telegram-Bot-Api-Secret-Token on every delivery, and
        // without it the handler has no way to tell Telegram from anyone else
        // who knows the URL -- which is how this webhook accepted forged
        // updates for months.
        //
        // Telegram accepts 1-256 chars of A-Z a-z 0-9 _ -
        body: JSON.stringify({
          url: webhookUrl,
          secret_token: webhookSecret,
        }),
      }
    );

    const result = await telegramResponse.json();

    if (!telegramResponse.ok || !result.ok) {
      return new Response(
        JSON.stringify({ error: "Failed to set webhook", details: result }),
        {
          status: 500,
          headers: {
            ...corsHeaders,
            "Content-Type": "application/json",
          },
        }
      );
    }

    const commandsResponse = await fetch(
      `https://api.telegram.org/bot${botToken}/setMyCommands`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          commands: [
            { command: "register", description: "Register your account" },
            { command: "play", description: "Play Bingo" },
            { command: "balance", description: "Check your balance" },
            { command: "deposit", description: "Deposit funds" },
            { command: "withdraw", description: "Withdraw funds" },
            { command: "transfer", description: "Transfer balance to another user" },
            { command: "invite", description: "Get your referral link & earn rewards" },
          ],
        }),
      }
    );

    const commandsResult = await commandsResponse.json();

    return new Response(
      JSON.stringify({ success: true, webhookUrl, webhook: result, commands: commandsResult }),
      {
        status: 200,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      }
    );
  } catch (error) {
    console.error("Error setting up webhook:", error);
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