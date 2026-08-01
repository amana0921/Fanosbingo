# Fanos Bingo

A real-time, multiplayer bingo game built as a Telegram Mini App with full on-chain integration on Binance Smart Chain (BSC). Players compete in live bingo rounds where the prize pool is distributed transparently through smart contracts.

---

## Table of Contents

- [Project status](#project-status)
- [Running it](#running-it)
- [What is left](#what-is-left)
- [Overview](#overview)
- [How It Works](#how-it-works)
- [Game Mechanics](#game-mechanics)
- [Blockchain Integration](#blockchain-integration)
- [Deposits](#deposits)
- [Withdrawals](#withdrawals)
- [Telegram Bot](#telegram-bot)
- [Admin Panel](#admin-panel)
- [Architecture](#architecture)
- [Vision](#vision)

---

## Project status

**Self-hosted on AWS, ~$30/month.** The server side was originally a hosted
Supabase project belonging to the upstream repository this is forked from. It is
being rebuilt on infrastructure this project owns.

**The game runs.** It loads inside Telegram at
[app.yisakmesifin.org](https://app.yisakmesifin.org), the board renders and the
countdown ticks — driven by a server-side game loop, not by a browser tab.

| Layer | State |
|---|---|
| Infrastructure (VPC, RDS, ECS, KMS, CloudTrail) | live in **dev**, Terraform, applied through CI |
| Database | PostgreSQL 16 on RDS, 114 migrations, PITR, restore drilled monthly |
| API (PostgREST) · realtime · game loop · TLS | running |
| Auth service | running — Telegram `initData` verified, JWT enforced by RLS |
| Mini App | served from Caddy at `app.<domain>`, built into the image |
| Joining and claiming | **working** — `/select-card` and `/claim-bingo`, identity and card layout derived server-side |
| Bank deposit (TeleBirr / CBE) | **working** — player claims, operator approves against their own statement. No wallet, no contract |
| Bank withdrawal | **working** — player requests, operator pays by hand and records the reference. `db/20-post/007` + `/withdrawals/*` |
| Admin | Telegram identity + `is_admin`, single factor. Bootstrap route promotes only the first admin, then disarms |
| Database authorization | **enforced** — EXECUTE is an allowlist, `telegram_users` is owner-scoped, game state is read-only to clients, verified by `probe-public-access.sh` |
| Crypto (wallet login, BNB deposit/withdrawal) | **deferred, not removed** — every surface is behind `VITE_CRYPTO_ENABLED`, off by default. Ethiopian players overwhelmingly do not hold cryptocurrency, so birr is the currency that matters. Code, contract and KMS key all retained |
| Smart contract | **not deployed** — and not on the critical path while crypto is deferred |
| Production | Terraform written, plans cleanly, never applied |

**The money round trip is closed:** deposit by bank, play, withdraw by bank. That is
the whole loop, with no wallet anywhere in it.

> **Deploy order matters once.** `db/20-post/008` closes a path that let any
> authenticated player mint an arbitrary `won_balance` with a single `PATCH` on
> `games` — a permissive inherited policy plus a blanket table grant plus a
> payout trigger that reads `winner_ids` straight from the update. That balance
> previously had no exit; the bank withdrawal routes give it one. **Apply `008`
> before deploying them.**

### Routes the SPA no longer calls

The inherited Deno function names are not being ported. Each was resolved by
asking the question in `AGENTS.md` §7 — "why can RLS not do this?" — and most
answered "it can":

| Route | Resolution |
|---|---|
| `get-card-layouts` · `force-finish-game` | deleted; `get_all_card_layouts()` and `game_tick()` already did the work |
| `submit-deposit` · `record-withdrawal` · `manage-bnb-withdrawal` · `claim-winnings-to-contract` · `get-withdrawal-wallet-info` · `monitor-deposits` | crypto, deferred with the flag |
| `deselect-card` | rebuilt as `/deselect-card` + `release_card()`. RLS could not express "only while selection is open" — that condition lives on the `games` row |
| `update-settings` | rebuilt as `/admin/settings` + `admin_update_setting()`, **minus `telegram_bot_token`**. Writing that key back would have undone `db/20-post/003`, which redacted it after `curl /rest/v1/settings` returned a live one anonymously. It signs every player's login; it lives in SSM |
| `setup-telegram-webhook` | **not built.** The button that claimed to do it POSTed a 404 and did nothing. Now says so, rather than failing silently. The receiving route must verify `X-Telegram-Bot-Api-Secret-Token` strictly, and `setWebhook` must be re-registered with that secret **before** the check ships |

Engineering detail, decisions and their reasons live in **[AGENTS.md](AGENTS.md)**.
Read it before changing anything; most of it was learned expensively.

> **The other markdown files in this directory are inherited from the upstream
> project** and describe its Supabase deployment, which does not exist here. Each
> carries a banner saying so. Their design reasoning is often still worth
> reading; their setup steps are not. Do not follow an instruction from one
> without checking it against the three documents above.

### Security posture, in one paragraph

Authorization is enforced by the **database**, not by application code
remembering to check. A player proves their Telegram identity once, receives a
short-lived JWT whose claims match what PostgREST expects, and every subsequent
query runs under row-level security as that player. The hot wallet is a
**non-exportable KMS key** — no plaintext copy has ever existed — and exactly one
IAM role may ask it to sign, with a CloudTrail alarm on anything else. The origin
accepts traffic only from Cloudflare's published ranges.

That was true of the HTTP layer, which was rebuilt, and **not** of the database
underneath it until `db/20-post/004` — the SQL migrations were inherited wholesale
from a Supabase deployment where the edge functions used the service-role key and
RLS was decorative, so a permissive policy and a blanket `GRANT EXECUTE` survived
into a system that depends on neither being there. Both were found by `curl`, not
by review.

`004` is applied and `scripts/probe-public-access.sh` reports no exposures.
EXECUTE is now an allowlist rather than a blanket grant, so a function added in
future is not reachable by omission.

---

## Running it

Nothing reaches AWS except through GitHub Actions. There are no manual
`terraform apply` runs.

```bash
# infrastructure
gh workflow run terraform.yml -f environment=dev -f action=plan
gh workflow run terraform.yml -f environment=dev -f action=apply

# ship a service (build -> ECR -> SSM pointer -> rolling deploy)
gh workflow run deploy-services.yml -f service=functions -f environment=dev

# database migrations, through an SSM tunnel (RDS has no public endpoint)
gh workflow run db-migrate.yml -f environment=dev -f dry_run=true

# prove the security controls still work (also runs weekly on its own)
gh workflow run verify.yml -f environment=dev
```

Local checks that need no AWS:

```bash
npm --prefix services/functions install
npm run test:functions        # 189 assertions, 8 suites
./scripts/test-migrations.sh   # applies db/20-post to a throwaway postgres, twice
node scripts/check-migrations.mjs
terraform fmt -check -recursive infra/
```

---

## What is left

Ordered by what unblocks the most. Engineering detail for every item is in
**[AGENTS.md](AGENTS.md)** §0.

**1. Bank withdrawal routes and UI.** `db/20-post/007` has the correctness layer —
overdraft prevention, one payout per request, decided rows frozen — and nothing
calls it. `services/functions/src/deposits.js` is the worked example to mirror.
The player-facing button is deliberately absent rather than 404ing.

**2. Fund the wallet from the testnet faucet.** Free, and the only thing blocking
the three on-chain routes (`submit-deposit`, `record-withdrawal`,
`manage-bnb-withdrawal`). Note the faucet now wants ≥0.002 BNB on **mainnet** as
an anti-abuse gate, and the dev wallet has nothing on either network.

Bank deposits work today without it, so this no longer blocks players.

**3. Build the bot webhook.** `POST /telegram/webhook` was never ported.
`/start` to @BingoNovaaBot does nothing. Requirements are recorded in
`services/functions/src/index.js` — verify the secret token strictly, and
re-register with `secret_token` BEFORE deploying the check or the bot goes silent.

**4. Replace single-factor admin auth.** TOTP on `telegram_users`, and put the
second factor on the **action** rather than the login — a session left open
otherwise credits freely.

**5. Production.** Terraform is written and plans cleanly, never applied. Needs
mainnet values and a funded wallet. Run the restore drill against prod once —
dev's 8–11 minute figure is not prod's.

**Known and not accepted:** no capacity data at all (the spike test has never run,
and `k6` is not installed — the npm entry is an autocomplete stub); the Cloudflare
rate-limit rule applies cleanly and **does not enforce**, so it is not a control
until somebody reads the dashboard analytics.

**Known and accepted:** single instance in a single AZ (~3–5 min MTTR); the SPA is
served from that instance, so a replacement blanks it for anyone who misses
Cloudflare's cache.

---

## Overview

Fanos Bingo is a skill and speed-based competitive game - not gambling. Every round has deterministic, code-enforced rules. Winners are decided by who completes a valid bingo pattern first on their card. Prize distribution is handled by a BSC smart contract, ensuring full transparency and no custodial risk.

The game runs entirely inside Telegram as a Mini App, making it accessible to millions of users without any app installation.

---

## How It Works

### Player Journey

1. Open the Fanos Bingo Telegram Mini App
2. Fund the account — **by bank transfer (TeleBirr or CBE), or with BNB**. A crypto
   wallet is needed only for the BNB path; bank deposits and playing need none
3. Deposit BNB to receive in-game credits (1 BNB = 100,000 credits by default)
4. Enter the lobby and pick a card number (1-99)
5. Wait for the round to start and play in real-time
6. If you complete a bingo pattern first, claim your win and receive the prize

---

## Game Mechanics

### Cards

Each player gets a standard 5x5 bingo card with numbers distributed across five columns:

| Column | Range  |
|--------|--------|
| B      | 1-15   |
| I      | 16-30  |
| N      | 31-45  |
| G      | 46-60  |
| O      | 61-75  |

The center cell (N column, row 3) is a free space.

### Winning Patterns

A player wins by completing any of the following:

- Any horizontal row (5 cells)
- Any vertical column (5 cells)
- Either diagonal (5 cells)
- Four corners

### Number Calling

Numbers are called automatically every 3.5 seconds by a scheduled backend function. Numbers range from 1 to 75 and are never repeated within the same round.

### Auto-Mark

When a called number matches a number on a player's card, that cell is automatically marked. Players do not need to manually mark cells.

### Claiming a Win

When a player completes a valid winning pattern, a 1-second claim window opens. The first valid claim within that window wins the round. This prevents race conditions and ensures fairness when multiple players complete patterns simultaneously.

### Staking

Each player stakes a fixed amount of credits to enter a round. The total staked amount forms the prize pool.

- Winner receives 75% of the prize pool
- 25% is retained as a platform fee
- If a player leaves before the round starts, their stake is fully refunded

---

## Blockchain Integration

Fanos Bingo uses Binance Smart Chain (BSC) for all financial operations. Two smart contracts power the system:

### Deposit Contract (`FanosBingoDeposit.sol`)

Handles incoming BNB deposits and converts them to in-game credits.

- Accepts BNB and records the depositing wallet and linked Telegram user ID
- Configurable conversion rate (owner-adjustable)
- Minimum deposit enforced on-chain
- Emits events for every deposit, withdrawal, and rate change so the backend can track them off-chain

### Withdrawal Contract

Handles outgoing payments from won balance to player wallets.

- Signature-based authentication ensures only legitimate withdrawals are processed
- Daily and weekly withdrawal limits per user
- Functions: `withdraw()`, `claimAndWithdraw()`, `claimWithSignature()`
- Tracks each user's remaining limits

---

## Deposits

### Crypto (BNB) Deposits

1. Connect wallet inside the app
2. Send BNB to the deposit contract address
3. Submit the transaction hash inside the app
4. The backend monitors BSC for the transaction and waits for 3 confirmations
5. Credits are added to your deposited balance automatically

### Bank Deposits (Optional)

An optional SMS-based deposit flow supports Ethiopian bank transfers:

1. User makes a bank transfer and the bank sends an SMS confirmation
2. The SMS is forwarded to the backend via the `receive-bank-sms` edge function
3. The system extracts the amount and reference number automatically
4. An admin verifies and approves the deposit

---

## Withdrawals

Players withdraw their won balance to their own wallet at any time. The design
is **non-custodial**: the backend never sends a player's funds and never signs a
withdrawal.

1. The player wins; the backend credits that amount on-chain with
   `addWinCredits()`, signed by a KMS key no human can export
2. The player calls `withdraw()` on the contract **themselves**
3. BNB moves from the contract to their wallet, without the operator in the path

Withdrawal limits are enforced **on-chain** by the contract, per day and per
week. Database-side tracking is kept for analytics and is not authoritative.

> Earlier revisions had the backend generate a signed authorization the player
> then submitted. That was replaced (migration `20260216`) precisely to keep the
> operator out of the withdrawal path — the backend's only signing job now is
> crediting wins.

---

## Telegram Bot

The Telegram bot handles notifications and commands:

- Notifies players when a game is starting, when they win, and when deposits or withdrawals are processed
- Accepts balance transfer commands (move credits between deposited and won balance)
- Sends formatted messages with inline action buttons

### Referral System

Each user gets a unique referral code. When a new user signs up using your code, both you and the new user receive a bonus. Referrals are capped at 20 per user to prevent abuse.

---

## Admin Panel

The admin panel is protected by multi-step authentication:

1. Access key
2. Time-based one-time password (TOTP / 2FA)

Admin capabilities:

- View all active games and player activity
- Force-finish a game if needed
- Manage bank deposit options
- Approve or reject manual deposit requests
- Manage BNB withdrawal requests
- Configure game settings (stake amount, commission rate, contract addresses, bot token, etc.)
- View financial reports through the accountant dashboard

---

## Architecture

```
Telegram Mini App (React + Vite)
        |
        | Supabase Realtime (live game updates)
        |
Supabase Edge Functions (Deno)
        |
        |--- PostgreSQL Database (game state, balances, users)
        |--- BSC Smart Contracts (deposits, withdrawals)
        |--- Telegram Bot API (notifications, commands)
        |--- Cron Jobs (auto number caller every 3.5s)
```

### Key Technologies

| Layer | Technology |
|-------|------------|
| Frontend | React 18, TypeScript, Vite, TailwindCSS |
| Wallet | Wagmi v3, Viem v2, Reown (WalletConnect v3) |
| Backend | Supabase Edge Functions (Deno runtime) |
| Database | Supabase PostgreSQL with Row Level Security |
| Realtime | Supabase Realtime channels |
| Blockchain | Binance Smart Chain, Solidity 0.8.20 |
| Messaging | Telegram Bot API, Telegram Mini App SDK |

### Security

- Row Level Security (RLS) enforced on every database table
- Admin 2FA with TOTP
- Wallet address validation before crediting
- Blockchain confirmation threshold before deposits are accepted
- Signature-based authorization for withdrawals
- Referral abuse prevention with per-user caps

---

## Vision

Fanos Bingo is the foundation for a broader ecosystem of on-chain competitive mini-games.

The next major milestone is integrating autonomous AI agents that can participate as players. These agents will learn game patterns, compete against human players, and eventually enable fully agent-vs-agent matches. All outcomes will be recorded on-chain, creating provably fair, transparent competition between humans and AI.



