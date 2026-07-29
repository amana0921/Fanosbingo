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
| Database | PostgreSQL 16 on RDS, 109 migrations, PITR, restore drilled monthly |
| API (PostgREST) · realtime · game loop · TLS | running |
| Auth service | running — Telegram `initData` verified, JWT enforced by RLS |
| Mini App | served from Caddy at `app.<domain>`, built into the image |
| Some API routes | **404** — inherited function names the rebuilt service never implemented |
| Smart contract | **not deployed** — blocked on a free faucet visit |
| Production | Terraform written, plans cleanly, never applied |

Engineering detail, decisions and their reasons live in **[AGENTS.md](AGENTS.md)**.
Read it before changing anything; most of it was learned expensively.

### Security posture, in one paragraph

Authorization is enforced by the **database**, not by application code
remembering to check. A player proves their Telegram identity once, receives a
short-lived JWT whose claims match what PostgREST expects, and every subsequent
query runs under row-level security as that player. The hot wallet is a
**non-exportable KMS key** — no plaintext copy has ever existed — and exactly one
IAM role may ask it to sign, with a CloudTrail alarm on anything else. The origin
accepts traffic only from Cloudflare's published ranges.

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
npm run test:functions        # 47 assertions
terraform fmt -check -recursive infra/
```

---

## What is left

Ordered by what unblocks the most.

**1. Serve the routes the app calls.** The Mini App calls
`/functions/v1/get-card-layouts` and others that 404 — inherited Deno function
names the rebuilt service never implemented. Get the real list from the app:

```bash
grep -rnoE "functions\.invoke\(['\"][a-z-]+|functions/v1/[a-z-]+" src/ \
  | sed -E "s/.*(invoke\(['\"]|v1\/)//" | sort -u
```

For each, ask **"why can RLS not do this?"** Most are plain data access and
belong in PostgREST as `supabase.from()` calls, not as routes.

**2. Deploy the smart contract.** Free, and the only blocker on the money path.
Fund the wallet from the BSC testnet faucet, then:

```bash
node scripts/deploy-contract.mjs dev              # dry run — checks everything
node scripts/deploy-contract.mjs dev --broadcast  # deploys, verifies owner()
```

The deploying wallet becomes the contract owner **permanently**, so this must be
signed by the KMS key. The script does that and reads `owner()` back to prove it.

**3. Finish the API surface.** `POST /telegram/webhook` (verify the secret
strictly), `POST /wins/credit` (needs the contract), `POST /deposits/confirm`.
Requirements for each are recorded in `services/functions/src/index.js`.

**4. Replace the admin key.** A shared string compared with `!==` in browser
state. Cognito with TOTP, and an audit log on every privileged mutation.

**5. Production.** Terraform is written and plans cleanly, but has never been
applied. Needs mainnet values, a funded wallet, and `PROD_APPLY_ENABLED=true`.
Run the restore drill against prod once — dev's 8–11 minute figure is not prod's.

**Known gaps, deliberately accepted:** single instance in a single AZ (~3–5 min
MTTR); the SPA is served from that same instance, so a replacement blanks it for
anyone who misses Cloudflare's cache; no load test yet at the 400-concurrent
target, so `t4g.small` is unvalidated under load; runbooks unwritten.

---

## Overview

Fanos Bingo is a skill and speed-based competitive game - not gambling. Every round has deterministic, code-enforced rules. Winners are decided by who completes a valid bingo pattern first on their card. Prize distribution is handled by a BSC smart contract, ensuring full transparency and no custodial risk.

The game runs entirely inside Telegram as a Mini App, making it accessible to millions of users without any app installation.

---

## How It Works

### Player Journey

1. Open the Fanos Bingo Telegram Mini App
2. Connect a crypto wallet (MetaMask, Trust Wallet, or any WalletConnect-compatible wallet)
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



