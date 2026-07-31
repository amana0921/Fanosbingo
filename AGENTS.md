# Fanos Bingo — Engineering Handover

Orientation for whoever picks this up next, human or agent. Written to be read
top to bottom once, then used as reference.

**Read §6 (Gotchas) before writing any code.** Most of it was learned expensively.

> ## This repository is a FORK, and the distinction matters
>
> Original: `djibril611` / `Fanos-Web-3`. The AWS infrastructure, the CI/CD, the
> containers and the security work are this fork's own.
>
> **Claims in this document therefore come from two different places**, and
> conflating them has already caused real confusion — the Supabase functions
> were read as a live deployment and their flaws reported as an active breach.
> They are source code. There is no Supabase project here: no `config.toml`, no
> `.env`, no project ref, only `your-project.supabase.co` placeholders.
>
> | Mark | Meaning |
> |---|---|
> | ✅ | Verified against this account's live infrastructure, with the date |
> | 📥 | Inherited from upstream. Describes THEIR deployment or credentials |
> | ❓ | Asserted somewhere, never checked. Treat as a hypothesis |
>
> If you are about to act on something consequential and it carries no mark,
> verify it first. That is cheaper than the alternative every single time.

---

## 0. Start here

**If you are picking this up cold, do these three things first.**

1. **Read §6 (Gotchas).** Ten CI round trips were burned on symptoms that
   actively mislead. Fifteen minutes there saves hours.
2. **Verify locally before pushing.** Podman, psql and arm64 emulation are
   installed for exactly this. See §5 — it is the single biggest factor in how
   fast this work goes.
3. **Check what is actually running** before trusting this document:
   ```bash
   aws sts get-caller-identity          # `aws login` if the session expired
   aws ecs describe-services --cluster fanosbingo-dev \
     --services ticker postgrest realtime caddy \
     --query 'services[].[serviceName,runningCount]' --output text
   ./scripts/probe-public-access.sh https://api.yisakmesifin.org
   ./scripts/verify-detections.sh       # are the security alarms real?
   ```

   All three run weekly on their own — `.github/workflows/verify.yml`, Mondays
   07:00 UTC. Check its last run before trusting anything below; a red one means
   a control that is supposed to be protecting real money has drifted.

### The next task, in one line

**Apply `db/20-post/004`.** It is written, tested and unapplied, and until it
lands the live dev API lets an unauthenticated caller read every player's
balance and execute the functions that move money. Two findings, both found by
`curl` against the running system rather than by reading policies:

```bash
# returns telegram_user_id, username, balance, won_balance, wallet_address
curl https://api.yisakmesifin.org/rest/v1/telegram_users?select=*

# no token, no apikey -- and it EXECUTES
curl -X POST https://api.yisakmesifin.org/rest/v1/rpc/transfer_balance \
  -H 'content-type: application/json' \
  -d '{"from_telegram_id":<a real player>,"transfer_amount":999999999,"to_telegram_id":<attacker>}'
# {"success": false, "error": "Insufficient won balance"}
```

That second response is a **business-logic** rejection, not an authorization
one. The amount was chosen to exceed the balance so the probe returned before
any write; with an amount the balance covered, the transfer would have
completed. The first finding supplies the `telegram_user_id` the second needs.

Causes, and why nothing caught them: an inherited policy
(`20251229180739_fix_telegram_users_rls_for_lobby.sql`) grants `anon` a
`USING (true)` read and is never dropped; `db/20-post/001` granted `EXECUTE ON
ALL FUNCTIONS` to `anon`, and 30 of the 58 functions in `public` are
`SECURITY DEFINER` with eight taking the caller's identity as an unchecked
parameter. The guard in `003` asserted exactly this and passed, because it
counted **rows** on a table that was empty every time migrations ran. See §6.

```bash
gh workflow run db-migrate.yml -f environment=dev -f dry_run=true
gh workflow run db-migrate.yml -f environment=dev
./scripts/probe-public-access.sh https://api.yisakmesifin.org   # must be green after
```

`scripts/probe-public-access.sh` now fails on both, so this cannot regress
silently. **Do not deploy the contract before this is applied** — funding the
money path while an unauthenticated transfer route is open converts an exposure
into a loss.

### Then: port the routes the app still calls but the API does not serve

The Mini App
runs inside Telegram today and calls `/functions/v1/get-card-layouts`, among
others, which 404s — those are inherited Deno function names the rebuilt service
never implemented.

Find the full list from the app itself rather than from this document:

```bash
grep -rnoE "functions\.invoke\(['\"][a-z-]+|functions/v1/[a-z-]+" src/ | sed -E "s/.*(invoke\(['\"]|v1\/)//" | sort -u
```

Then, for each, ask the question that governs this codebase: **why can RLS not
do this?** Most are plain data access and should become `supabase.from()` calls
against PostgREST, not routes. See §7.

**Two other things are one step from working:**

- The contract needs deploying, which needs the dev wallet funded. Free, from a
  faucet: `https://testnet.bnbchain.org/faucet-smart` → `0xE509727904C1B057E58BCe7f4eC5bFb120D5adDF`,
  then `node scripts/deploy-contract.mjs dev --broadcast`. Everything else on the
  money path is written and tested behind it.
- The bot webhook is unbuilt. Requirements are recorded in
  `services/functions/src/index.js`.

### Three things that are true and easy to get wrong

- **The game no longer depends on a browser being open.** `game_tick()` owns
  number calling, game start, countdown rolls, claim-window finalization and
  next-game creation. Do not reintroduce client-driven game logic.
- **`rds.force_ssl` stays on**, and every service verifies TLS against
  `docker/rds-global-bundle.pem`. Do not weaken this to accommodate a client.
- **Secrets never enter Terraform state.** GitHub Secrets → SSM SecureString →
  injected at container start. The hot-wallet key is non-exportable in KMS.

### Operational hardening that has landed since

**Applied to `dev` and `account`. Prod is written, plans cleanly, never applied.**

✅ Verified 2026-07-29, against the running system rather than assumed:

- **five** services `ACTIVE 1/1` — ticker, postgrest, realtime, caddy, functions
- the Mini App loads inside Telegram and the game loop counts down
- `app.yisakmesifin.org` serves the SPA; the bundle names this API and no
  `supabase.co`; the anon key extracted FROM the served bundle is accepted by
  PostgREST
- ten alarms `OK`, CloudTrail logging, twelve detector assertions passing
- a dev plan reporting no changes

| Change | Why |
|---|---|
| `modules/app_stack`, called by dev **and prod** | Prod defined no services at all. Applying it would have produced infrastructure with no application |
| Game-loop alarm, `treat_missing_data = "breaching"` | The ticker's own Dockerfile said liveness was asserted by an alarm that did not exist |
| `infra/environments/account` — CloudTrail + `kms:Sign` alarm | The wallet design's preventive half was strong; its detective half was a comment |
| Read-only planner role for pull requests | Every workflow ran as AdministratorAccess, including `plan` on a PR |
| Scoped `-github-deploy` role actually used | It was written carefully and then never referenced |
| Image pointers in SSM | Deploying used to end in "now go set a GitHub variable and re-dispatch" |
| AMI pinned, bumped by PR | An unrelated apply could replace the instance |
| Deployment circuit breaker | A bad image left the service down instead of rolling back |
| Cloudflare in Terraform | Half the origin lock was dashboard state |
| Monthly restore drill | The `~25 min` MTTR had never been measured. It is now 8–11 min to a restored instance |
| `bootstrap-github.sh` | The prod gate depended on somebody having ticked a checkbox |
| `services/functions` — auth service | Rebuilt rather than ported. All 25 inherited functions bypassed RLS with the service-role key |
| SPA served from Caddy at `app.<domain>` | The frontend had never been hosted anywhere, so there was no URL for BotFather |
| SPA authenticates against this API | It took its identity from `initDataUnsafe` — Telegram's own word for "not verified" |

Between them these changes surfaced **six defects that `terraform validate` could
not catch**, every one found by running the thing rather than checking it:

1. A job declaring `environment:` presents `environment:<name>` as its OIDC
   subject, not `pull_request` — so the planner role could never be assumed.
2. Terraform cannot adopt an SSM parameter that already exists, so it should
   never have owned the image pointers.
3. The `dev` branch policy blocked the migration dry run, which declared
   `environment: dev` for no reason.
4. Restoring an encrypted snapshot needs `kms:CreateGrant`; the error names three
   causes and the real one is a fourth.
5. A restore with no `--vpc-security-group-ids` lands in the VPC default group —
   and reports success *with a plausible RTO* before failing at verification.
6. `cache_level = "bypass"` is not a valid zone setting; bypass is a cache RULE.
   The provider types the value as a string, so only Cloudflare rejects it.
7. `ALLOWED_ORIGIN` was the apex while the app is served from `app.<domain>`.
   The preflight answered 204 forty-one times, the access log looked healthy,
   and the browser silently never sent a single POST — so the app fell back to
   the unverified identity and *appeared to work*.

Four of the seven were in code paths that had never executed before. Tightening
permissions moves failures from "never happens" to "happens the first time you
actually use it", which is why exercising each path once matters more than the
configuration being valid.

### What is NOT done

- **`db/20-post/004` is not applied.** Written and tested against PostgreSQL
  16.14; the live dev database is still exposed until it runs. See the top of
  this section.
- **The routes the app still calls.** `get-card-layouts` and friends are
  inherited Deno names the rebuilt service never implemented. They 404 today.
- **Wallet login proves nothing.** `get_or_create_wallet_user` and the wallet
  branch of `get_lobby_data_instant` trust a caller-supplied address: connecting
  a wallet is not a signature. Left working deliberately rather than breaking
  the flow, and it needs a sign-in-with-Ethereum challenge before mainnet. The
  Telegram path is now proven end to end.
- **The admin count.** `Admin.tsx:206` counts all of `telegram_users` and will
  return 0 once 004 lands. It only worked because the table was world-readable;
  it should come back as an explicit admin policy.
- **The bot webhook.** Requirements in `services/functions/src/index.js`.
- **The contract.** Written, deployable, blocked on a free faucet visit.
- **Prod.** Terraform is complete and plans cleanly; it has never been applied.
- **The admin surface.** Still a shared string compared with `!==`. No admin path
  should be built on the new service until that is replaced.
- **A load test.** `stress-test/k6-spike-test.js` has never run at its
  400-concurrent target, so `t4g.small` is unvalidated under load.

---

## 1. What this is, and where it stands

Fanos Bingo is a real-money multiplayer bingo game delivered as a Telegram Mini
App, with BNB (BSC) deposits/withdrawals and Ethiopian bank-SMS deposits.

It **was** a Vite/React SPA with no backend of its own — the entire server side
was a hosted Supabase project (📥 upstream's; this fork never had one). It is
being rebuilt on self-hosted AWS infrastructure, at a budget of
**~$30/month**.

The practical consequence: `supabase/functions/` and `supabase/migrations/` are
**inherited source**, not a running system. The migrations have been applied to
this fork's RDS (✅ 109 recorded, confirmed by the restore drill). The 25 edge
functions have never run here, and porting them is a decision rather than an
obligation — see §7.

### Migration status

| Phase | Scope | State |
|---|---|---|
| 0 | Security remediation | ✅ code done; two operator actions outstanding (§7) |
| 1 | Terraform foundation + CI/CD | ✅ complete, applied to dev |
| 2 | Database on RDS | ✅ complete — 107 migrations applied |
| 3 | Containers | 🔶 4 of 5 running; **25 edge functions not yet ported** |
| 4 | Auth hardening | ⬜ not started |
| 5 | Frontend + CDN | ⬜ not started |
| 6 | Observability + cutover | 🔶 alarms, audit trail and DR drill landed; runbooks and load test outstanding |

### Live right now (dev environment) — ✅ verified 2026-07-29

```
https://api.yisakmesifin.org     Caddy -> PostgREST / (functions, not yet built)
https://rt.yisakmesifin.org      Caddy -> Realtime websockets
AWS account 292123551166, us-east-1, Elastic IP 35.153.122.186
```

| Service | State |
|---|---|
| ticker | running, 60 ticks/min |
| postgrest | running, 22 relations / 46 functions |
| realtime | running, v2.120.0 |
| caddy | running, TLS via Cloudflare Origin Cert (expires 2041) |
| **functions** | **running — auth service, built here, not ported** |
| RDS | `available`, PostgreSQL 16.13, db.t4g.micro |

Verified reachable end to end (✅ 2026-07-29):

```
/functions/v1/healthz   200    /functions/v1/readyz  200 {"ready":true}
whoami without a token  401    forged initData       401
```

**prod exists in Terraform but has never been applied.** `PROD_APPLY_ENABLED` is
deliberately unset, so merging to main plans prod and stops.

> Until recently that statement was more optimistic than the code. Prod defined
> the platform — VPC, RDS, ECS cluster, IAM — and **no services at all**, so
> applying it would have produced infrastructure with no application on it. The
> service definitions now live in `modules/app_stack` and both roots call it, so
> the two environments cannot diverge that way again.

### Three roots, not two

| Root | What it is | Applied |
|---|---|---|
| `infra/environments/account` | CloudTrail, the `kms:Sign` and root-usage alarms, account-wide guardrails | On demand. Singleton — a second trail would bill for duplicate events |
| `infra/environments/dev` | Testnet environment. Disposable | On demand |
| `infra/environments/prod` | Mainnet. Real balances | Never yet |

---

## 2. Architecture, and why it is shaped this way

The decisions below are load-bearing. Changing one without understanding the
reason will cost you a day.

### The core insight

Rather than rewriting the app for AWS-native services, we **self-host the same
open-source components Supabase runs**. That preserves ~7,800 lines of frontend
and all 104 SQL migrations unchanged:

| Supabase gave us | We run | Why not the AWS-native option |
|---|---|---|
| PostgREST | PostgREST container | Rewriting ~200 `supabase.from()` call sites to API Gateway + Lambda is weeks of work and discards RLS as the authorization layer |
| Realtime | `supabase/realtime` container | AppSync means reimplementing RLS-aware row-change fan-out — the genuinely hard part |
| `pg_cron` @ 4s | **ticker container** | RDS `pg_cron` is minute-granularity; Supabase's 6-field sub-minute syntax is a fork extension that **fails silently** |

### Cost decisions

Target ≤$30/mo. Four choices get there:

| Decision | Saves | Trade |
|---|---|---|
| ECS on **EC2** capacity provider, not Fargate | ~$53/mo | See ENI caveat below |
| **No ALB** — Cloudflare proxies to the Elastic IP | ~$17/mo | Depends on the origin lock staying correct |
| **No AWS WAF** — Cloudflare free plan | ~$13/mo | Coarser rules |
| **No NAT Gateway / VPC endpoints** | ~$61/mo | Instance in a public subnet, ingress locked to Cloudflare |

Net: **single instance, single AZ.** ~3–5 min MTTR on instance failure (ASG
replaces); on database failure, **8–11 minutes to a restored instance**, measured
(see below). Deliberate at this budget.

> **Correction to earlier claims:** EC2 → Fargate is *not* "a one-line capacity
> provider change". `awsvpc` allocates one ENI per task and a `t4g.small`
> supports three interfaces total, so five tasks do not fit. Services run in
> `bridge` mode with static host ports; Caddy runs in `host` mode to own :443.
> Migrating to Fargate also means moving every service to `awsvpc` plus Cloud Map
> service discovery for Caddy.

### The Cloudflare origin lock — read this before touching networking

`sg-app` admits port 443 **only from Cloudflare's published IP ranges**, fetched
live at plan time from `https://www.cloudflare.com/ips-v4`.

This single control is what makes a public-subnet instance safe, and what lets us
skip the ALB and WAF. Consequences:

- `api.` and `rt.` DNS records **must be proxied (orange cloud)**. A DNS-only
  record is black-holed by the security group — you get a timeout with no error.
- A `terraform plan` needs network access to that Cloudflare endpoint. There is a
  precondition that fails the plan if the fetch returns fewer than 10 or more
  than 40 ranges, so a bad response cannot silently produce broken rules.

### Cloudflare settings that are not optional

| Setting | Value | Why |
|---|---|---|
| SSL/TLS mode | **Full (strict)** | Anything less loops or sends plaintext to origin |
| Bot Fight Mode | **Off** | Challenges non-browser clients — Telegram's webhook caller and WebSocket upgrades look exactly like that. Telegram doesn't solve challenges; it retries then *disables your webhook* |
| `api.` / `rt.` records | **Proxied** | Required by the origin lock |

**All but one of these is now Terraform** (`infra/modules/cloudflare`), gated on
`cloudflare_zone_id` being set. Set `CLOUDFLARE_API_TOKEN` as a repository secret
and `CLOUDFLARE_ZONE_ID` as a variable, and the DNS records, SSL mode, minimum
TLS version, WebSocket support, cache bypass and a rate limit on the
money-moving endpoints all become reviewable code.

Bot Fight Mode is the exception: it has no Terraform resource on the free plan.
`scripts/verify-cloudflare.sh` asserts it is off, along with proxy status and SSL
mode — read from Cloudflare's API rather than from Terraform state, because a
dashboard edit does not update state.

> **The API token needs `Zone > Bot Management > Read`** for that assertion to
> work — it is grantable on the free plan, and it is NOT covered by
> `Zone Settings: Edit`. Without it the endpoint returns `403 / 10000
> Authentication error`.
>
> Full token scope: `Zone:Read`, `DNS:Edit`, `Zone Settings:Edit`,
> `Zone WAF:Edit`, `Bot Management:Read` — scoped to this zone, not all zones.
>
> Getting here took two bugs stacked on each other: the missing permission, and
> a `jq '// empty'` that discarded `fight_mode: false`. The first version
> reported both as one warning and exited zero, so the single control that
> cannot be enforced any other way sat unverified behind a green run.

**Exactly one root may own the zone.** Dev and prod share a domain, so they share
a zone, and two Terraform states managing one DNS record is a fight neither wins
— each apply reverts the other, and the losing side presents as unexplained DNS
flapping. `manage_cloudflare` is `true` in dev (which serves `api.<domain>`
today) and `false` in prod. **At cutover, flip prod on and dev off, in that
order**, as its own change with its own plan.

**Records that already exist must be imported, not created.** Cloudflare permits
several A records on one name, so a plain apply creates a *second* `api.` record
beside the live one — no error, and Terraform then manages a record nobody
resolves while the real one stays editable in the dashboard.

Dev's records were adopted this way on **2026-07-28**. If you destroy and rebuild
dev, or stand up prod, do it again — the record ids are environment-specific and
a stale one fails the apply with "record not found":

```bash
gh workflow run cloudflare-import.yml -f environment=dev
```

Merge the PR it opens, apply, then **delete** the generated
`cloudflare-imports.tf`. An import block is a one-time instruction, not desired
state; git holds the history, so there is nothing to preserve by keeping the
file.

This mattered more than it looked. The origin lock has two halves; half one
(`sg-app` admitting Cloudflare ranges) was always Terraform, and half two was a
list in this document ending in "set these in the dashboard".

---

## 3. Available tooling

Verified on this workstation, ✅ 2026-07-29. Check rather than assume — the
versions below were read from the tools, not remembered.

| Tool | Version | Notes |
|---|---|---|
| `aws` | 2.36.2 | **`aws login` when the session expires** — it will, mid-task |
| `gh` | 2.96.0 | authenticated as `amana0921`, default repo set |
| `terraform` | 1.15.8 | 1.11+ needed for S3-native state locking (`use_lockfile`) |
| `podman` | 5.7.0 | **rootless** — use instead of docker |
| `psql` | 18.4 | client only; server via podman |
| `node` / `npm` | 22.22.1 / 9.2.0 | |
| `python3` | 3.14.4 | used for YAML/JSON validation throughout |
| `jq` | 1.8.1 | |
| `git` | 2.53.0 | SSH auth to GitHub |
| `openssl` | 3.5.5 | |
| `curl` | 8.18.0 | |

**arm64 emulation is registered** (`qemu-aarch64` binfmt), so Graviton images
build and run locally.

### npm packages that matter

| Package | Where | For |
|---|---|---|
| `viem` | root + functions | keccak, address derivation, tx serialization, RPC |
| `@aws-sdk/client-kms` | root (dev) + functions | signing |
| `solc` | root (dev) | compiling the contract at deploy time |
| `@noble/curves` | transitive via viem | used by the signer tests to produce DER signatures |
| `express`, `pg`, `jsonwebtoken` | functions | the service itself |

### NOT installed, and each absence has a consequence

| Missing | Consequence |
|---|---|
| `session-manager-plugin` | **no SSM tunnel to RDS.** CI installs it per-run; install it locally before touching the database |
| `supabase` | cannot deploy or delete Supabase functions. Does not matter — see §1, there is no Supabase project |
| `deno` | cannot run `supabase/functions/`. Also does not matter; they are not being ported |
| `docker` | deliberate. Podman is rootless; docker needs a group change that will not take effect in an already-running shell |
| `shellcheck` | shell scripts are checked with `bash -n` only. Worth installing |
| `trivy` | runs in CI. To reproduce locally: `podman run --rm -v "$PWD:/src:ro" -w /src docker.io/aquasec/trivy:latest config --severity HIGH,CRITICAL infra/` |
| `forge` / `hardhat` | not needed. `scripts/deploy-contract.mjs` compiles with `solc` directly |

### Rootless podman quirks you will hit

```bash
# 1. Unqualified image names are refused. Always use the full registry:
podman build -f services/postgrest/Dockerfile .      # FROM docker.io/... required

# 2. Cannot bind ports below 1024. Caddy's listen port is parameterised for this:
podman run -e HTTPS_PORT=8443 ...
```

### Running the tests

```bash
npm --prefix services/functions install    # once
npm run test:functions                     # 47 assertions, no AWS or network
```

They need no credentials. The signer tests generate their own secp256k1 key and
never call KMS — signing arbitrary bytes with the wallet key is not a reasonable
thing to do for a test, and would fire `unexpected-kms-sign`.

## 4. How to do things

### The golden rule

**Everything reaches AWS through GitHub Actions.** There are no manual
`terraform apply` runs and no `aws` mutations by hand, except break-glass.

```
PR         → fmt · validate · trivy config · trivy secrets · plan → posted as a comment
merge main → plan + apply PROD, behind TWO gates
dispatch   → plan / apply / destroy any environment
```

Prod apply requires **both** `PROD_APPLY_ENABLED == "true"` *and* the `prod`
GitHub Environment's required reviewers. Two gates, because a missing GitHub
Environment is created **implicitly and without protection rules** — the
environment alone would be no gate at all. `scripts/bootstrap-github.sh` creates
the environment *with* the reviewer attached and then verifies it, so the gate
does not depend on somebody having clicked the right checkbox.

### Which role a workflow runs as, and why it matters

There are three, and using the wrong one is how a pull request ends up holding
admin over the account.

| Context | Role | Scope |
|---|---|---|
| `plan` on a pull request | `fanosbingo-terraform-planner` | ReadOnlyAccess + state lock. Can decrypt **dev** parameters only, by resource tag |
| `apply` / `destroy` | `fanosbingo-terraform-executor` | AdministratorAccess, trusted only from `main` and the environments |
| deploy · secrets · migrate · drill | `fanosbingo-<env>-github-deploy` | ECR, ECS, this environment's SSM tree, the SSM tunnel, and a restore drill scoped to `*-restore-drill` |

A pull request runs workflow code **taken from the PR branch**. That is the
whole reason for the split: previously every workflow used the executor, so a
modified workflow file in a PR was an admin credential. GitHub withholds
`id-token: write` from fork PRs, which bounded it — but that bound is a GitHub
default, not something this account controls.

Prod's deploy role is unreachable from a pull request: obtaining it requires
declaring `environment: prod`, and declaring it puts the job behind prod's
required reviewers.

### Deploying a service no longer has manual steps

The old flow ended with a warning telling you to run `gh variable set
<SVC>_IMAGE` and then re-dispatch Terraform. It now ends with the service
running:

```
build → push to ECR by git SHA
      → write /fanosbingo-<env>/images/<service> in SSM
      → roll the ECS service, or dispatch terraform.yml if it does not exist yet
```

Terraform *reads* those pointers and never writes them. A service whose pointer
still says `none` has never been built, and is not created — an ECS service
referencing a non-existent image retries forever without saying why.

The legacy `TICKER_IMAGE`/`POSTGREST_IMAGE`/… repository variables still work as
a fallback and can be deleted once each service has deployed once.

### Common operations

```bash
# Infrastructure
gh workflow run terraform.yml -f environment=dev -f action=plan
gh workflow run terraform.yml -f environment=dev -f action=apply
gh workflow run terraform.yml -f environment=dev -f action=destroy   # refuses prod and account

# Account-wide security baseline (CloudTrail, guardrails). Rarely.
gh workflow run terraform.yml -f environment=account -f action=apply

# Disaster recovery: restore from a snapshot, time it, verify it, delete it.
# Runs monthly on its own; this is how you force one.
gh workflow run db-restore-drill.yml -f environment=dev

# Database (SSM tunnel, no public endpoint)
gh workflow run db-migrate.yml -f environment=dev -f dry_run=true
gh workflow run db-migrate.yml -f environment=dev -f dry_run=false

# Containers (arm64 build → ECR by git SHA → rolling deploy)
gh workflow run deploy-services.yml -f service=ticker -f environment=dev -f deploy=true

# Secrets: GitHub Secrets → SSM SecureStrings
gh workflow run sync-secrets.yml -f environment=dev

# Watch
gh run list --limit 5
gh run view <id> --log-failed
```

### Adding a new service

Order matters — getting it wrong wastes CI cycles:

1. `services/<name>/Dockerfile` (build context is the **repo root**)
2. Add `<name>` to `repository_names` in `infra/modules/ecr/variables.tf`
3. **`terraform apply`** — creates the ECR repository
4. `deploy-services.yml` — builds and pushes (warns that the service doesn't exist; that's expected)
5. `gh variable set <NAME>_IMAGE --env dev --body "<image>"`
6. Wire `module "service_<name>"` in `infra/environments/dev/main.tf`, count-gated on the image local
7. **`terraform apply`** — creates the service

### Working with the database locally

```bash
# Needs session-manager-plugin
source scripts/db-tunnel.sh dev     # exports DATABASE_URL, defines stop_db_tunnel
psql "$DATABASE_URL" -c "SELECT count(*) FROM games"
stop_db_tunnel
```

Or spin a throwaway Postgres that matches production's settings:

```bash
podman run -d --name pgtest -e POSTGRES_PASSWORD=testpass -e POSTGRES_DB=fanosbingo \
  -p 55432:5432 docker.io/library/postgres:16-alpine \
  -c wal_level=logical -c max_replication_slots=5 -c max_wal_senders=5
```

### Migration system

Two kinds, borrowing Flyway's distinction:

| Kind | Path | Behaviour |
|---|---|---|
| **Versioned** | `supabase/migrations/` | Applied once. Editing one **fails the run** — that is how a database drifts from its own history |
| **Repeatable** | `db/00-bootstrap/`, `db/20-post/` | Re-applied whenever content changes. Declarative, idempotent |

Order: `00-bootstrap` → `supabase/migrations` → `20-post`.

`db/00-bootstrap/001` is the Supabase compatibility layer — roles, the
`auth.uid()` shim, `pg_cron`/`pgcrypto`, the `supabase_realtime` publication, the
`_realtime` schema. **Without it all 104 migrations fail.**

To deliberately edit an applied migration, record the new checksum in
`db/00-bootstrap/002_checksum_reconciliation.sql` **with a written reason**. It
must live in `00-bootstrap` — the runner aborts on the changed file long before
reaching `20-post`.

---

## 5. Verification discipline

This project got significantly faster and less error-prone when local
verification started preceding every push. **Keep doing it.**

Roughly ten CI round trips were burned on bugs that a 60-second local check would
have caught. Then:

```bash
# Does the image actually contain what the config expects?
podman build --platform linux/arm64 -f services/postgrest/Dockerfile -t check .
podman create --name c check && podman cp c:/opt/rds-global-bundle.pem /tmp/x && podman rm c

# Does the container actually start with this config?
podman run --network=host -e ... docker.io/supabase/realtime:v2.120.0

# Does the Terraform expression actually behave?
#   Write a 10-line standalone .tf with the locals and outputs, terraform apply.

# Does the routing rewrite actually work?
#   Run stub upstreams that echo path + Host, proxy through Caddy, curl it.
```

Two principles, both learned the hard way:

**A static assertion about a security control is not a test of that control.** An
assertion that compared two hardcoded lists passed cheerfully while secrets were
publicly readable. Assertions now `SET LOCAL ROLE anon` and query the table —
the same path an HTTP request takes.

**Prove your detectors detect.** The Trivy rules and
`scripts/probe-public-access.sh` were each verified against deliberately
malicious bait before being trusted. A detector that has never seen a positive is
not a detector.

`scripts/verify-detections.sh` applies the same rule to the CloudTrail alarms. It
tests the **deployed** filter patterns — read back from CloudWatch, not restated
in the script — against synthetic events, and asserts both directions:

- bait matches (`kms:Sign` by an arbitrary role fires the alarm)
- benign traffic does **not** match (signing by `*-task-functions`, `kms:Decrypt`
  during secret injection, an unrelated service)

The second assertion is the one people skip. A filter matching everything looks
identical to a working one until it pages you about a legitimate withdrawal.

It deliberately never calls `kms:Sign`. The hot-wallet key signs 32-byte digests,
and a digest you did not construct carefully is potentially a valid transaction
hash — "just testing" is not a safe reason to sign attacker-chosen bytes with a
key that controls funds.

**A claim you have never measured is not a number.** The `~25 min` database MTTR
was an estimate nobody had tested. `db-restore-drill.yml` now restores from a
real snapshot monthly, times it, checks the schema and migration ledger came
back, and deletes the copy. Its cleanup runs `if: always()`, so a cancelled run
does not leave an instance billing.

**Measured, 2026-07-28, dev:**

| Run | Restore to `available` | Verified |
|---|---|---|
| 1 | 7m 39s | — (failed later, see below) |
| 2 | 11m 9s | 22 tables, 109 migrations, `games` readable |

So: **8–11 minutes**, and quote the range rather than the better number — the two
runs differ by 45%.

Three things that number is NOT:

- **It is a floor.** It excludes DNS, service restarts, and the human minutes
  spent deciding to restore. The end-to-end figure is still unmeasured.
- **It is dev's data volume.** Restore time scales with data. Run the drill
  against prod once prod exists; a dev number is not a prod estimate.
- **It is not evidence the application recovers.** The drill never wires the
  restored instance to anything. It proves the DATA comes back.

Worth knowing what it cost to get there. The drill found three defects before it
passed, none of them reachable by `terraform validate`, and two in code paths
that had never executed under the scoped roles:

1. Missing `kms:CreateGrant` — restoring an *encrypted* snapshot makes RDS create
   a grant on the CMK. Presents as `KMSKeyNotAccessibleFault`, which names three
   possible causes, none of which is the real one.
2. No `--vpc-security-group-ids`, so the copy landed in the VPC **default**
   security group. This one is the dangerous shape: the instance comes up
   healthy and the restore reports success *and a plausible RTO*, and only the
   verification fails — looking exactly like a broken tunnel.
3. Missing `ssm:DescribeInstanceInformation`, masked by `2>/dev/null` in
   `db-tunnel.sh` swallowing the AccessDenied message entirely.

---

## 6. Gotchas — read before writing code

Every one of these cost real time.

### Database / SQL

| Symptom | Cause |
|---|---|
| `syntax error at or near ":"` | psql does **not** interpolate `:'var'` inside `$$...$$`. Dollar-quoted blocks are opaque strings. Use `\gexec` |
| `function gen_random_bytes does not exist` | pgcrypto. `gen_random_UUID()` is native in PG13+; `gen_random_BYTES()` is not |
| `column "code" does not exist` | plpgsql resolves columns at **execution**, not `CREATE FUNCTION`. It parses fine and fails when called |
| `no schema has been selected to create in` | **Textually identical** whether the schema is missing *or* the role lacks CREATE on it. Check ownership before assuming absence |
| `must not contain non-printable control characters` | RDS treats any non-ASCII as non-printable. **Keep every AWS-bound string plain ASCII** (an em-dash in a description fails the apply) |
| A `DROP POLICY IF EXISTS` that does nothing | Wrong name = **silent no-op**, and PostgreSQL **ORs permissive policies**. Enumerate `pg_policies`; never guess a name |
| An RLS assertion that passes while the data is exposed | `SELECT count(*) ... IF count > 0 THEN RAISE` tests **rows**, not **policies**, and passes vacuously on an empty table. Assert against `pg_policies` / `has_function_privilege` instead — those hold on an empty database *and* a full one |
| `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` | Reports success, writes **no** `pg_default_acl` row, and has **no effect**. The PUBLIC-executes-functions rule is a **database-wide** default; a per-schema entry can only add to it. Drop `IN SCHEMA` and it works. Verified on PG 16.14 |
| `permission denied for function uid` on every query | Something revoked the PUBLIC EXECUTE default and `auth.uid()` was relying on it. `db/00-bootstrap/001` now grants it explicitly — do not remove that |
| `PGRST203 Could not choose the best candidate function` after a **successful** migration | PostgREST builds its schema cache **at boot** and does not notice DDL. Dropping or changing a function signature leaves it serving from a database that no longer exists. `db-migrate.sh` now sends `NOTIFY pgrst, 'reload schema'`; if that ever fails, `aws ecs update-service --service postgrest --force-new-deployment`. This took the lobby down once |
| `CREATE OR REPLACE FUNCTION` that does not replace | It only replaces a **matching signature**. Add a parameter and you have created an **overload**, with the old body still live and still reachable. Three migrations did this to `get_lobby_data_instant`. Check `pg_proc` for the name before assuming your version is the only one |

### AWS

| Symptom | Cause |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | GitHub emits an **immutable subject prefix** with numeric IDs: `repo:owner@123/repo@456:...`, not `repo:owner/repo:...`. Check with `gh api repos/OWNER/NAME/actions/oidc/customization/sub` |
| `Client.InvalidKMSKey.InvalidState` | **Misleading.** The key is fine — Auto Scaling lacks key-policy permission. `aws_kms_key_policy` **replaces** the default policy, so "root has kms:*" does not cover service-linked roles |
| `Volume of size 20GB is smaller than snapshot` | The ECS-optimized AL2023 arm64 AMI ships a 30 GiB snapshot |
| `Container.image should not be null or empty` | An unset GitHub variable arrives as `TF_VAR_x=""` — an **empty string, not null**. Use `try(trimspace(x), "") == ""`, not `coalesce` (which errors on all-empty args) |
| Terraform changes config but never rolls it out | Do **not** put `ignore_changes = [task_definition]` on a service. Point it at `max(terraform_revision, latest_revision)` instead |
| An unrelated apply replaced the instance | The ECS AMI used to resolve from the SSM `recommended` pointer at plan time. Combined with `instance_refresh`, the day AWS publishes an image, the *next* apply — for any reason — takes an unscheduled outage. It is pinned in `ami.tf` now; `ami-bump.yml` proposes the update by PR |
| `aws_ssm_parameter` data source fails a fresh plan | The singular data source errors on a missing parameter; `aws_ssm_parameters_by_path` returns an empty result. A new environment must be able to plan before anything has been deployed into it |
| A deployment left the service down | Enable `deployment_circuit_breaker` with `rollback`. On one instance with static host ports ECS must stop the old task first, so a bad image *ends* the service rather than degrading it |
| `wait services-stable` succeeded but the old code is running | The circuit breaker rolled back. Stable ≠ deployed. Compare the running task definition against the one you registered |
| `no pg_hba.conf entry ... no encryption` | RDS PostgreSQL 15+ ships `rds.force_ssl = 1` as the **engine default** |

### Containers

| Symptom | Cause |
|---|---|
| `ADD <url>` produces no file | Base-image specific. It worked in `node:22-alpine` and silently did nothing in `postgrest/postgrest`. **Always `COPY` a committed file** |
| `self-signed certificate in certificate chain` | RDS's CA is not in default trust stores. `docker/rds-global-bundle.pem` is committed; **never** reach for `rejectUnauthorized: false` |
| Deployment stuck `IN_PROGRESS` forever | A health check whose binary is missing reports `UNKNOWN` indefinitely — it does not fail loudly. Verify the tool exists in the image |
| `exec format error` | x86 image on Graviton. Always build `linux/arm64` |

### Realtime (all found by running it locally)

- `_realtime` schema must **exist and be owned by the connecting role** before start
- `ECTO_IPV6=true` and `-proto_dist inet6_tcp` are **baked into the image**; override both
- `METRICS_JWT_SECRET` is **required from 2.120.0**; without it the VM dies at boot with an unreadable `System.EnvError`
- Tenant resolves by **Host subdomain**: `Host: <ip>` → 403; `Host: realtime-dev.<anything>` → 101
- WebSocket path is **`/socket/websocket`**, not `/realtime/v1/websocket`
- `DB_SSL_CA_CERT` is a **file path**. `DB_SSL=true` *without* it silently degrades to `verify: :verify_none`

### Auth, chains and signing

| Symptom | Cause |
|---|---|
| App loads but every table is empty | The JWT's `sub` is not a UUID. `auth.uid()` casts to uuid; a Telegram bigint fails the cast and every RLS policy matches nothing. No error anywhere |
| Recovery search finds no matching address | Signing the wrong bytes. `crypto.sign(null, digest, key)` HASHES its input; KMS with `MessageType: 'DIGEST'` does not. The signature then covers `sha256(digest)` |
| `jq '.x // "default"'` swallowed a `false` | `//` is an *alternative* operator, not a null-coalescer — it fires on `false` too. Cost a day on Bot Fight Mode. Use `has("x")` |
| A "testnet" signature is valid on mainnet | Chain id came from `settings` (56) not SSM (97). A signature commits to a chain id wherever it was produced |
| `unexpected-kms-sign` fired | Expected when a human signs, e.g. deploying the contract. Check CloudTrail shows your principal — that is the alarm working |
| The app loads and shows a name, but never logs in | CORS. The access log fills with `204` on `/functions/v1/auth/telegram` — that is the PREFLIGHT, and the POST is never sent. `ALLOWED_ORIGIN` must equal the app's origin exactly. `verify.yml` now asserts this |
| A `/functions/v1/...` route 404s | It is an inherited Deno function name the rebuilt service never implemented. Decide whether it should be a route at all, or plain data access through PostgREST under RLS |

### CI

- A **21-minute hang on "Assume AWS role"** has been observed once. Cancel and re-dispatch; do not wait it out.
- Piping `psql` into `sed` under `set -e -o pipefail` **discards the error text**. Capture with `2>&1` and print explicitly.
- `jq '.x // "default"'` fires on **`false`** as well as `null` — `//` is an *alternative* operator, not a null-coalescer. A check reading a boolean flag will silently discard `false`, which is usually the value you most wanted to see. Use `has("x")` to test presence, then stringify.
- Same shape, different command: `VAR="$(aws ... 2>/dev/null)"` turns an authorisation failure into a bare `exit code 254` with no message anywhere. `set -e` aborts on the assignment before the script's own error handling runs, and the CLI's explanation is already gone. `scripts/db-tunnel.sh` uses an `_aws` wrapper that captures stderr and prints it.
- A literal ESC byte (`0x1b`) in a workflow file makes YAML unparseable. Check with `grep -P '\x1b'`.

---

## 7. Outstanding work and known risks

### Replacing the container instance (the only planned-outage procedure)

There is one instance in one AZ, so replacing it is a **3–5 minute outage**. This
is the procedure for the AMI bumps `ami-bump.yml` proposes, and for any
launch-template change — `metadata_options`, `user_data`, `instance_type`.

**Terraform will not do it for you.** The ASG references `version = "$Latest"`, so
a launch-template change produces a new version, Terraform sees no diff on the
ASG, and `instance_refresh` never fires. The template updates and the running
instance keeps the old settings indefinitely. Confirmed on the plan for the IMDS
change: `1 to add, 1 to change` with the ASG absent from the change set.

Before starting, record the baseline — you want to be able to tell whether
anything came back *different*, not just whether it came back:

```bash
aws ec2 describe-launch-template-versions --launch-template-id <lt-id> \
  --query 'reverse(sort_by(LaunchTemplateVersions,&VersionNumber))[0].[VersionNumber,LaunchTemplateData.ImageId,LaunchTemplateData.MetadataOptions.HttpPutResponseHopLimit]'
aws ec2 describe-instances --instance-ids <id> \
  --query 'Reservations[].Instances[].[ImageId,MetadataOptions.HttpPutResponseHopLimit,PublicIpAddress]'
aws ec2 describe-addresses --query 'Addresses[0].[PublicIp,InstanceId]'
```

**Check the AMI in the template against the AMI on the instance.** If they differ,
the refresh is also an OS upgrade and you are taking two changes in one outage.
That is what the pin in `environments/<env>/ami.tf` exists to prevent — leave it
empty and every refresh silently carries whatever AWS last published.

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name <asg-name> \
  --preferences MinHealthyPercentage=0
```

`MinHealthyPercentage=0` because with one instance there is no way to roll without
a gap. Then verify, in this order — each one has failed before:

1. **the EIP reattached.** `user_data` claims it on boot via `ec2:AssociateAddress`.
   If that fails the instance is healthy and serving on an address Cloudflare does
   not resolve to, and the symptom is "the site is down and nothing looks wrong".
2. **all five ECS services are 1/1.** The new instance rejoins the cluster and
   pulls from the SSM image pointers, so a service whose pointer is `none` will
   not come back.
3. **the setting you changed is actually on the instance**, not just in the
   template.
4. **the game loop is advancing** — `starts_at` on the waiting game should move.
   The ticker reacquires its advisory lock on a new connection; a lock still held
   by a dead session is released when Postgres reaps the connection, not
   instantly.

### Operator actions

> **Read the provenance column before acting on any of these.** This repository
> is a FORK. The original is by `djibril611` / `Fanos-Web-3`; the AWS
> infrastructure is this fork's own work. Several items below were written for
> the upstream operator and describe **their** credentials, not yours — you
> cannot sweep another person's wallet or rotate another person's bot token, and
> none of it is your exposure.
>
> Establishing this took an embarrassing detour: the Supabase functions were
> treated as a live deployment and their flaws reported as an active breach
> risk. There is no Supabase project here — no `config.toml`, no `.env`, no
> project ref, only `your-project.supabase.co` placeholders. Nothing in
> `supabase/functions/` has ever run under this account.

| Item | Provenance | Action for THIS fork |
|---|---|---|
| Old BSC wallet unswept | 📥 upstream | **None.** That key was in `djibril611`'s history and controls their wallet. This fork's hot wallet is a non-exportable KMS `ECC_SECG_P256K1` key created by its own Terraform, with no plaintext copy that has ever existed |
| `Habeshabingo91bot` token live | 📥 upstream | **None.** Not your bot, not yours to delete |
| `sms_api_key` published | 📥 upstream | **None**, unless you reuse that provider account — in which case get your own key |
| Stale AWS secrets in GitHub | ✅ verified yours | Check and delete `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEPLOY_ROLE_ARN` if present. Everything now uses OIDC |
| Bot token in 2 git commits | 📥 upstream | Inert for you. Rewriting inherited history is optional cleanup |

**What IS yours, and worth doing:** create your own Telegram bot via `@BotFather`
and set `TELEGRAM_BOT_TOKEN`; generate `TELEGRAM_WEBHOOK_SECRET`; obtain your own
SMS provider credentials. None of the upstream credentials should be reused even
if they still work.

### Engineering roadmap

> **Recommended sequence: do Phase 4 (auth) BEFORE finishing Phase 3.**
>
> The functions port makes more endpoints reachable; auth decides whether that is
> safe. Porting money-moving handlers onto a surface where `initData` is never
> verified and CORS is `*` is the wrong order. If you want to keep momentum on
> the port instead, at minimum land the CORS lockdown and `initData` verification
> first — those two are small and close the widest holes.

---

#### Phase 3 — the API surface. **Rebuilt, not ported.**

The decision, and it is settled: **the 25 inherited Deno functions are not being
ported.** All 25 built their client with `SERVICE_ROLE_KEY`, which bypasses row
level security — so the 47 RLS policies and the working `auth.uid()` shim did
nothing on those paths — and all 25 took the caller's identity from the request
body. Porting would have carried both onto infrastructure built to avoid them.

Nothing depended on their behaviour: no deployment, no users, no Supabase
project. That made it the cheapest moment the design will ever be changed.

**What exists now** (`services/functions`, live in dev):

| Route | Auth |
|---|---|
| `POST /auth/telegram` | none — this is where identity is *proved*, via Telegram's `initData` HMAC |
| `GET /auth/whoami` | bearer token |
| `GET /healthz`, `/readyz` | none |

`POST /auth/telegram` returns a 15-minute JWT whose claims are shaped for the
database:

```
sub  = telegram_users.id   the UUID auth.uid() casts to
role = authenticated       the role the RLS policies name
```

Every other request goes to **PostgREST** carrying that token. PostgREST puts
the claims in `request.jwt.claims`, and RLS enforces authorization in the
database, on every query, whether or not anybody remembered to check.

> `sub` must be the UUID, not the Telegram bigint. The bigint fails the uuid cast
> in `auth.uid()`, every policy then matches nothing, and it presents as *"the
> app loads but all the data is empty"* rather than as an error. Verified by
> feeding real claims to the shim: `auth.uid()` resolved to the right row.

**The rule for every new route: "why can RLS not do this?"** Legitimate answers
are minting a token, signing with KMS, and talking to Telegram or a chain RPC.
Plain data access is not one, and goes straight to PostgREST. That rule is what
stops 25 insecure endpoints reappearing one convenience at a time.

**Still to build**, with the auth each needs — recorded in
`services/functions/src/index.js` so it sits where the work happens:

| Route | Notes |
|---|---|
| `POST /telegram/webhook` | verify `X-Telegram-Bot-Api-Secret-Token` **strictly**. `setWebhook` must be called WITH `secret_token`, and re-registered BEFORE the check is deployed or the bot goes silent |
| `POST /wins/credit` | `requireAuth`, debit in the DB, then `addWinCredits` on the contract signed by KMS. **Blocked on the contract existing** |
| `POST /deposits/confirm` | `requireAuth`. Credit `req.auth.uid` only, never an id from the body |

Card selection, cell marking and game state are deliberately absent — plain data
access, belongs in PostgREST under RLS.

---

#### Phase 4 — auth hardening. **Mostly done.**

| Gap | State |
|---|---|
| `initData` HMAC never verified | ✅ `verifyInitData`, 22 assertions, both directions |
| CORS `*` on every function | ✅ locked to one origin, falls back to `"null"` not `"*"` so misconfiguration fails closed |
| Identity taken from the request body | ✅ replaced by proven identity + RLS |
| No wallet signature challenge | ⬜ SIWE-style nonce, if wallet login is wanted |
| Admin = one shared string | ⬜ Cognito with TOTP, plus `admin_audit_log` |

The admin gap is the significant one left. It is a shared string compared with
`!==` in browser React state, and six inherited functions gate on it. None of
those functions run, so nothing is exposed today — but any admin surface built
on the new service must not reproduce it.

---

#### The money path — written, tested, blocked on one faucet visit

The design is **non-custodial**, and that is worth understanding before touching
it. From the `20260216` migration:

> Users call `withdraw()` directly on the smart contract.
> The backend only credits wins via `addWinCredits()`, and **never signs
> withdrawal transactions.**

So the KMS key's only job is crediting wins. A route that sends BNB from the hot
wallet would rebuild exactly the custodial model this moved away from.

| Piece | State |
|---|---|
| KMS signer — DER parsing, EIP-2 low-s, recovery id | ✅ 19 assertions |
| Chain-id guard | ✅ verified against the RPC at boot; refuses to start on mismatch |
| Contract deployment from the KMS key | ✅ `scripts/deploy-contract.mjs`, dry run passes |
| **Contract deployed** | ⬜ **blocked: the wallet has 0 tBNB** |
| `POST /wins/credit` | ⬜ needs the contract |

`FanosBingoDeposit` sets `owner = msg.sender` and `addWinCredits` is
`onlyOwner`, so **the deploying wallet owns it permanently**. Deploy from
anything other than the KMS key and the backend can never credit a win, with no
recovery. That is why deployment is a script that signs with KMS and reads
`owner()` back afterwards, rather than a README step.

> **Chain id comes from SSM, never from `settings`.** Three sources disagreed:
> the RPC and SSM said 97 (testnet), `settings.deposit_contract_chain_id` said
> **56 — mainnet**. A signature committing to 56 is a valid mainnet transaction
> wherever it was produced. The settings table is application data; it must never
> decide what a signature commits to.

---

#### Phase 5 — frontend and CDN

Point `VITE_SUPABASE_URL` at `https://api.<domain>`. **The URL shape was
preserved deliberately** (`/rest/v1`, `/realtime/v1`, `/functions/v1`), so all
~200 `supabase.from()` calls and 10 `postgres_changes` subscriptions should work
unchanged. That was the entire point of self-hosting PostgREST and Realtime.

Then: S3 + CloudFront with OAC (`infra/modules/s3_cloudfront` exists but is
**unused and unwritten**), a `deploy-spa.yml` workflow, service-worker cache
versioning in [public/sw.js](public/sw.js) with `skipWaiting`, and **deletion of
the client-side game logic the ticker replaced** (`Lobby.tsx` game creation,
game start, countdown roll).

Note: `vite.config.ts` sets `drop_console: true`, so all client logging vanishes
in production builds. Consider an error boundary before go-live.

---

#### Phase 6 — observability and cutover

Done:

- `fanosbingo-<env>-game-loop-stalled` on `SecondsSinceLastNumberCalled`, with
  `treat_missing_data = "breaching"` — one alarm covering both "the loop is
  stalled" and "the ticker is gone". The default of `missing` would have sat at
  INSUFFICIENT_DATA in exactly the case it exists to catch.
- `fanosbingo-<env>-tick-duration-high`, the leading indicator.
- CloudTrail with `kms:Sign`-by-an-unexpected-principal and root-usage alarms,
  plus `scripts/verify-detections.sh` proving both fire and both stay quiet.
- Monthly restore drill producing a measured RTO.

Still outstanding:

- Alarms on stuck games, payout failure and hot-wallet balance — all three need
  metrics the ticker does not publish yet
- Runbooks: game loop stalled, RDS restore, RPC failover, instance replacement
- Run `stress-test/k6-spike-test.js` at its 400-concurrent target
- Confirm instance memory stays under ~1.6 GB — this is what validates `t4g.small`
- Cutover: staging on testnet → maintenance window → DNS → re-register the
  Telegram webhook → keep the old Supabase warm for 7 days as rollback

---

#### Then: prod

**Prod has never been applied.** Before it can be:
- Run `./scripts/bootstrap-github.sh` — creates the `prod` environment with
  required reviewers and verifies the rule is actually present
- Set `PROD_APPLY_ENABLED=true` (deliberately unset — it is the second gate)
- Build each service against prod: `gh workflow run deploy-services.yml
  -f service=<name> -f environment=prod`. The image pointer and the follow-up
  apply are automatic; there are no `prod`-scoped image variables to set.
- Mainnet: `bsc_chain_id = 56`, real RPC endpoints, real contract addresses
- Consider `multi_az = true` and `instance_count = 2` — see the Stage 2 upgrade
  ladder in the plan file
- Run the restore drill against prod once, so the RTO number is prod's own

---

### Spectator mode is documented and dead

`App.tsx:300` defines `handleSpectateGame`, `App.tsx:355` passes it to `Lobby` as
`onSpectateGame`, and `Lobby.tsx` **never calls it**. There is no UI element that
invokes it. `SPECTATOR_MODE_IMPLEMENTATION.md` describes the feature as built.

Found because it is one of the 17 remaining `typecheck` findings — an unused prop,
which the compiler reports as noise and is in fact a feature that was wired
halfway. Deliberately **not** "fixed" by deleting the prop to satisfy the
compiler: that would remove the hook somebody intended, and leave the document
describing something with no trace in the code at all.

Several of the other unused `useState` setters may be the same story
(`setIsJoining`, `isTimeSynced`, `isLoadingData` in `Lobby.tsx`) — a state that is
declared and never updated is a spinner or a guard that never fires. Each needs
reading individually before it is either wired up or removed.

That is why `typecheck` is advisory in `test.yml` rather than a gate: the findings
are a to-do list, not lint. Promote it once each has been decided.

**Real type errors are not tolerated, and were fixed.** Five in `GameRoom.tsx`:
four `Property does not exist on type 'never'` in the winning-number display, and
one `No overload matches this call` on `new Date(string | null)` in the
return-to-lobby countdown. The `never` cascade is worth knowing about — annotating
the *variable* does not fix it, because control-flow analysis narrows a `let` to
`null` after `= null` and does not track assignment inside a `forEach` callback,
so the inferred **return type** was `null`. Annotating what the function returns
is what fixes it.

### The test suites ran nowhere until 2026-07-30

Sixty-one assertions across four suites — Telegram `initData` verification, KMS
signature recovery, chain-id mismatch refusal, request-body handling — and **no
workflow executed any of them**. `npm run test:functions` was a README
instruction, which means it ran when somebody remembered.

The only pull-request-triggered workflows were `db-migrate` (paths `db/**`) and
`terraform` (paths `infra/**`), so a change confined to `services/` triggered
nothing at all. And `deploy-services.yml` built, pushed, repointed SSM and rolled
out without running them either — so a service failing its own suite could ship.

Fixed with `test.yml` (pull requests touching `services/**`; no AWS, no secrets)
and a gate in `deploy-services.yml` before the image build. The gate detects
suites by glob rather than a hardcoded list, so a suite added to the ticker starts
gating its own deploys.

Same shape as `verify.yml`'s stated reason for existing, one layer down: these
tests were written carefully — `chain.test.mjs` runs a real HTTP server rather
than stubbing `fetch`, specifically so it cannot pass against code that could not
parse a real response — and then left unwired.

### Two things measured on 2026-07-30 that are NOT working

Recorded here rather than in a commit message, because a reader needs both
before they trust the edge with anything.

**1. The Cloudflare rate-limit rule is created, enabled, and does not enforce.**

Applied and confirmed in state: `phase = http_ratelimit`, `enabled = true`,
`action = block`, `period = 10`, `requests_per_period = 20`,
`characteristics = [ip.src, cf.colo.id]`, expression matching
`/functions/v1/auth` and `/rest/v1/rpc/get_or_create_wallet_user` on
`api.<domain>`. Cloudflare accepted it — the ruleset id is
`79478d40c4f74f338bb951c3a7593241`.

Then 160 requests to a covered path in a few seconds, from one IP, across two
bursts of 80 concurrent, several minutes after creation:

```
80 concurrent -> 80x 200
80 concurrent -> 80x 200      # immediately after
```

Zero `429`. A path deliberately left out of the expression behaved identically,
so there is no observable difference between covered and uncovered. **Do not
treat this rule as a control.** Cause not established; the plausible candidates
are a free-plan entitlement that is accepted at write time and ignored at
enforcement time, or an expression field free is not entitled to match on.
Diagnosing it needs the Cloudflare dashboard's rate-limiting analytics, which
needs a token this repository does not hold.

The reason this matters more than it looks: the money-moving RPCs are closed at
the **database** by `db/20-post/004`, which does hold. The rate limit was never
the thing protecting them. What it was supposed to protect is `/auth/telegram`.

**There is now a floor underneath it**, in `services/functions/src/rate-limit.js`
— ten authentications per minute **per verified telegram user id**, enforced
in-process after the HMAC and *before* the database write.

Keying on the telegram id rather than the IP is the whole point, and it is why
this is not simply the Cloudflare rule reimplemented. `ip.src` is a poor key for
this player base: they reach Telegram over Ethiopian carrier NAT, so one address
is many people, and any threshold tight enough to stop a script also locks out
players who did nothing but open the app. A verified telegram id is one person
regardless of egress address, and cannot be forged without the bot token.

What it does **not** cover, stated plainly: requests whose `initData` fails
verification. Those have no trustworthy key, and the only alternative is the IP,
which brings the NAT problem back. They are cheap — one HMAC, no database, no
pool connection — and they now answer 401 rather than 500, so they no longer trip
Caddy's health check either. Raw volume against that path remains an edge job,
and the edge is not doing it.

It is also **per process**. One instance today, so that is exact; at Stage 2 two
instances would each permit the full budget. Move the counter into PostgreSQL
then, or accept 2× and write it down.

**2. FIXED — three malformed request bodies took auth down for everybody.**

First recorded here as "falls over under trivial concurrency", from a burst of 60
concurrent requests that produced `3x 500` then `57x 503`. **That diagnosis was
wrong, and the truth is both simpler and worse.** Concurrency had nothing to do
with it. The `xargs -I{}` in the test had substituted a loop counter into
`-d '{}'`, so the bodies on the wire were bare numbers — and it takes three of
them, sent at any speed at all:

```
curl -X POST .../functions/v1/auth/telegram -H 'content-type: application/json' \
     --data-binary '7'
  -> 500, 500, 500

...then a perfectly valid request, from anyone:
  -> 503, 503, 503
```

Every link ordinary: `express.json()` throws → the generic handler answers **500**,
calling a client mistake a server failure → Caddy's `unhealthy_status 5xx` with
`max_fails 3` ejects the upstream for 10s → there is only ONE upstream, so
ejection has no peer to shed load onto and simply turns three bad requests from
one caller into an outage for every player. Repeat every ten seconds and nobody
logs in.

Fixed in two places, because it needed both:

- `services/functions/src/http-errors.js` — a body that does not parse is a
  **400**, so it never enters the bucket the health check watches. 14 assertions,
  including that a genuine server fault is *still* 500: this narrows what counts
  as 5xx rather than blinding the check.
- `services/caddy/Caddyfile` — `unhealthy_status 5xx` removed from both proxied
  routes. Ejection is the right behaviour when there is somewhere else to send
  traffic, and there is not until Stage 2. Reinstate it then.

**The load question is still open.** This was never a load finding, so it says
nothing about capacity. `stress-test/k6-spike-test.js` targets 400 concurrent and
has still never run.

### The balance ledger has no copy outside this region or account

PITR covers the failures that have actually been rehearsed — a bad migration, a
wrong `UPDATE`, a dropped table — and the restore drill measures them at 8–11
minutes. It covers nothing that takes the **region** or the **account** with it,
because the backups live in the same account and region as the instance:

- a principal holding `rds:DeleteDBInstance` and `rds:DeleteDBSnapshot` removes
  the ledger and its recovery points in one sitting. `deletion_protection` stops
  the careless case, not the deliberate one.
- a region-wide RDS impairment leaves nothing to restore *from*.

The fix is `aws_db_instance_automated_backups_replication` — backup **storage**
in a second region, not a standby, so no second instance-hour. Roughly $2–4/month
on 20 GB with 7-day retention.

**Deliberately not implemented yet, and this is the reason.** It was written and
then reverted, because it cannot be exercised:

```
Error: Provider configuration not present
  module.rds.provider["registry.terraform.io/hashicorp/aws"].replica is required
```

Making it work needs four things, none of which can be verified today:

1. `configuration_aliases = [aws.replica]` in `modules/rds`
2. a second aliased `provider "aws"` block in **both** environment roots
3. a customer-managed KMS key **in the destination region** — a KMS key is
   regional, so the key this instance is encrypted with cannot be reused, and
   passing it yields "KMS key not found in region", which reads like a
   permissions problem and is not one
4. `providers = { aws = aws, aws.replica = aws.replica }` on every `rds` call

Dev should never have it (throwaway data, torn down between sessions) and **prod
has never been applied**. So landing it would mean adding provider plumbing and a
second regional key that nothing has ever run — the "control that exists, is well
written, and is never exercised" pattern this repository keeps paying for. Build
it with the first prod apply, when the restore can actually be drilled from the
replica.

### Known-deliberate weaknesses, accepted at this tier

- **A pull request can read dev SecureStrings.** Terraform refreshes
  `aws_ssm_parameter` with `WithDecryption=true`, so a planner that cannot
  decrypt cannot plan — "read-only *and* unable to read any secret" is not a
  combination the data model allows. The grant is scoped by resource tag to keys
  tagged `Environment=dev`, and PRs only ever plan dev, so prod secrets are
  unreachable. Dev holds BSC **testnet** credentials by construction; nothing
  there should ever touch mainnet funds.
- **Single instance / single AZ** (§2). ~3–5 min MTTR on instance failure
- `telegram_bot_token` exists in SSM *and* is read by app code; Phase 4 should
  make SSM the only source
- The anonymous-access probe reports **"inconclusive"** on empty tables — it
  cannot prove RLS protects a table with no rows. The migration-time
  `SET ROLE anon` assertions are authoritative
- Trivy config scanning covers only `infra/`; secret scanning covers the whole
  repo. Accepted findings are in `.trivyignore` with written justifications

---

## 8. File map

```
infra/
  environments/account/       CloudTrail + account guardrails. Singleton
  environments/{dev,prod}/    Terraform roots. prod is complete but NEVER applied
    ami.tf                    One-line pinned AMI. Bumped by pull request
  modules/                    vpc · security_groups · kms · ssm · iam · rds
                              ecr · ecs · ecs_service · s3_cloudfront · monitoring
                              app_stack · cloudtrail · cloudflare
    app_stack/                ALL five services, called by both roots
    cloudtrail/               The trail, and the detections that justify it
    cloudflare/               DNS + zone settings: the origin lock's other half
db/
  00-bootstrap/               Repeatable. Runs FIRST. Supabase compat layer
    001_roles_and_auth_shim   roles, auth.uid(), extensions, publication, _realtime
    002_checksum_reconciliation  deliberate edits to applied migrations
  20-post/                    Repeatable. Runs LAST
    001_rds_deltas            removes the 4s cron job, schedules cleanups, asserts wal_level
    002_game_tick             THE GAME LOOP — server-authoritative, one transaction
    003_settings_rls_hardening  deny-by-default RLS + anon assertions
services/
  ticker/                     Node. Game loop
  postgrest/ realtime/ caddy/ Thin images over upstream (CA bundle, config)
  functions/                  Node/Express. Auth + operations RLS cannot express
    src/index.js              routes, CORS, chain check at boot
    src/auth.js               initData -> JWT shaped for auth.uid()
    src/telegram-auth.js      HMAC verification. PLAIN JS so the test imports it
    src/kms-signer.js         DER -> (r,s,v), EIP-2, recovery by checking
    src/chain.js              refuses to run if the RPC serves another chain
    src/*.test.mjs            47 assertions, no AWS, no network
scripts/
  bootstrap-aws.sh            One-time. Idempotent. State bucket, OIDC, both roles
  bootstrap-github.sh         One-time. Idempotent. Variables, environments,
                              prod's required reviewers -- then verifies them
  db-tunnel.sh                SSM port-forward to RDS. Takes an instance
                              identifier and optional credential overrides
  db-migrate.sh               Versioned + repeatable runner with checksums
  post-apply.sh               RDS reboot when pending, publishes wallet address
  probe-public-access.sh      Anonymous exposure probe (verified against bait)
  verify-detections.sh        Proves the CloudTrail alarms fire AND stay quiet
  verify-cloudflare.sh        Asserts what Terraform cannot enforce (Bot Fight Mode)
  derive-wallet-address.mjs   Address from the KMS public key
  cloudflare-import.sh        Emits import blocks for DNS that already exists
  deploy-contract.mjs         Deploys FROM the KMS key, then verifies owner()

.github/workflows/
  terraform.yml               plan/apply/destroy. Read-only role on PRs
  deploy-services.yml         build -> ECR -> SSM pointer -> roll (self-triggers TF)
  db-migrate.yml              versioned + repeatable, through the SSM tunnel
  sync-secrets.yml            GitHub Secrets -> SSM SecureStrings
  verify.yml                  WEEKLY. Runs all three assertion scripts
  db-restore-drill.yml        MONTHLY. Restores, times, verifies, deletes
  ami-bump.yml                WEEKLY. Opens a PR when a newer AMI ships
  cloudflare-import.yml       One-time DNS adoption, opens a PR
docker/rds-global-bundle.pem  Amazon RDS CA, 108 certs. COPYed into images
supabase/
  migrations/                 104 versioned migrations. NEVER EDIT (see §4)
  functions/                  25 Deno handlers — the port source
src/                          React SPA. Untouched so far
```

### Key configuration

| Where | What |
|---|---|
| GitHub repo variables | `AWS_ROLE_ARN` `AWS_REGION` `TF_STATE_BUCKET` `DOMAIN_NAME` `ALERT_EMAIL` |
| GitHub `dev` env variables | `TICKER_IMAGE` `POSTGREST_IMAGE` `REALTIME_IMAGE` `CADDY_IMAGE` |
| GitHub Secrets | Telegram, JWT, DB passwords, Realtime keys, TLS cert/key |
| SSM `/fanosbingo-dev/*` | Runtime config + secrets, injected at container start |
| Terraform state | `s3://fanosbingo-tfstate-292123551166`, versioned, `use_lockfile` |

**Secrets never enter Terraform state.** SecureStrings are created as
`PLACEHOLDER_SET_ME_OUT_OF_BAND` with `ignore_changes`; the sync workflow fills
them. The RDS master password is generated and rotated by RDS itself. The
hot-wallet key is a **non-exportable KMS `ECC_SECG_P256K1` key** — there is no
plaintext copy anywhere, which is the structural fix for how the original key
leaked.

### Rotating `app/jwt_secret` — read this before you need to

There is no way to do this without an auth outage. That is a property of the
design, not of the procedure, and it is better known now than discovered during
an incident.

**Who holds it.** One SSM parameter, `/{env}/app/jwt_secret`, injected into
**three** containers at start:

| Service | Variable | What breaks if it disagrees |
|---|---|---|
| functions | `JWT_SECRET` | mints tokens nobody else accepts |
| postgrest | `PGRST_JWT_SECRET` | rejects every authenticated query — RLS sees `anon` |
| realtime | `API_JWT_SECRET` | websocket refuses the same token the API accepted |

And a fourth consumer that is not a container: the **anon key is minted from this
same secret** (`scripts/mint-anon-key.mjs`) and **baked into the SPA bundle** at
build time, as the `SPA_ANON_KEY` GitHub variable. A rotation that forgets it
leaves every served bundle carrying a key signed with the old secret.

**Why there is no zero-downtime path.** HS256 with a single shared secret cannot
accept two secrets at once. None of the three components is configured for
key-id-based rotation, so there is no window in which both old and new tokens
verify. Any rotation is therefore: old tokens stop working, everywhere, at once.

**Writing the new secret to SSM changes nothing on its own** — containers read it
at start, so running tasks keep using the value they were given. The disruption
window is between the FIRST service restarting and the LAST, and both orderings
break something:

- functions first → it mints new-secret tokens, postgrest still on the old one
  rejects them. New logins fail.
- postgrest first → it accepts only new tokens, functions still minting old ones.
  All logins fail.

So restart all three as close together as possible and accept a few minutes.

```bash
# 1. new secret into SSM (nothing changes yet)
gh workflow run sync-secrets.yml -f environment=dev

# 2. re-mint the anon key FROM THE NEW SECRET and update the GitHub variable,
#    or the next SPA build ships a key the API will reject
node scripts/mint-anon-key.mjs dev
gh variable set SPA_ANON_KEY --body "<the minted key>"

# 3. restart the three consumers, back to back
for s in functions postgrest realtime; do
  gh workflow run deploy-services.yml -f service=$s -f environment=dev
done

# 4. rebuild the SPA so the served bundle carries the new anon key
gh workflow run deploy-services.yml -f service=caddy -f environment=dev
```

**What players see.** Every existing session is invalidated. In the Mini App that
is mostly invisible — the client re-sends `initData` and gets a new token — but
anyone mid-game loses their subscription until it reconnects. Do not do this
while a game is in `playing`.

**Verify afterwards**, because a half-rotation is quiet:

```bash
curl -X POST https://api.<domain>/functions/v1/auth/telegram \
  -H 'content-type: application/json' -d '{}'          # 400, not 500
./scripts/probe-public-access.sh https://api.<domain>  # anon still fenced
```
Then confirm a real client can log in and that the lobby's realtime channel
reconnects. If the API works and realtime does not, `API_JWT_SECRET` missed the
rotation.

**If this ever needs to be routine**, the fix is not a better runbook — it is
supporting two valid secrets during a window. That means a `kid` header on the
tokens and all three components able to verify against a set. PostgREST supports a
JWKS via `PGRST_JWT_SECRET` as a JWK set, which is the thread to pull.

---

## 9. If you change one thing, understand this first

1. **The Cloudflare origin lock** (§2) — break it and either the site dies or the
   WAF is bypassed.
2. **`game_tick()`** (`db/20-post/002`) — the game's heartbeat. It replaced five
   behaviours the *browser* used to own. Before it, the game did not progress
   unless somebody had a tab open.
3. **The migration checksum guard** — it exists because editing an applied
   migration is how databases silently diverge. Bypassing it should be a
   conscious, documented act.
4. **`rds.force_ssl` stays on.** It is the engine default and Realtime 2.120.0
   supports TLS. Do not disable it to accommodate an older client.
