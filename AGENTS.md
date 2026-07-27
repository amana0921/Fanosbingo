# Fanos Bingo — Engineering Handover

Orientation for whoever picks this up next, human or agent. Written to be read
top to bottom once, then used as reference.

**Read §6 (Gotchas) before writing any code.** Most of it was learned expensively.

---

## 1. What this is, and where it stands

Fanos Bingo is a real-money multiplayer bingo game delivered as a Telegram Mini
App, with BNB (BSC) deposits/withdrawals and Ethiopian bank-SMS deposits.

It **was** a Vite/React SPA with no backend of its own — the entire server side
was a hosted Supabase project. It is being migrated to self-hosted AWS
infrastructure, at a budget of **~$30/month**.

### Migration status

| Phase | Scope | State |
|---|---|---|
| 0 | Security remediation | ✅ code done; two operator actions outstanding (§7) |
| 1 | Terraform foundation + CI/CD | ✅ complete, applied to dev |
| 2 | Database on RDS | ✅ complete — 107 migrations applied |
| 3 | Containers | 🔶 4 of 5 running; **25 edge functions not yet ported** |
| 4 | Auth hardening | ⬜ not started |
| 5 | Frontend + CDN | ⬜ not started |
| 6 | Observability + cutover | ⬜ not started |

### Live right now (dev environment)

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
| RDS | `available`, PostgreSQL 16.13, db.t4g.micro |

**prod exists in Terraform but has never been applied.** `PROD_APPLY_ENABLED` is
deliberately unset, so merging to main plans prod and stops.

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
replaces), ~25 min on database failure (PITR restore). Deliberate at this budget.

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

---

## 3. Available tooling

Everything below is installed and verified on the workstation.

| Tool | Version | Notes |
|---|---|---|
| `aws` | 2.36.2 | Authenticated via SSO — **`aws login` when the session expires** (it will, mid-task) |
| `gh` | 2.96.0 | Authenticated as `amana0921`, default repo set |
| `terraform` | 1.15.8 | 1.11+ needed for S3-native state locking (`use_lockfile`) |
| `podman` | 5.7.0 | **Rootless.** Use instead of docker — no group membership needed |
| `psql` | 18.4 | Client only; server via podman |
| `node` / `npm` | 22.22.1 / 9.2.0 | |
| `python3` | 3.14.4 | Used for YAML/JSON validation throughout |
| `jq` | 1.8.1 | |
| `git` | 2.53.0 | SSH auth to GitHub (`git@github.com:amana0921/Fanosbingo.git`) |
| `openssl` | 3.5.5 | |

**arm64 emulation is registered** (`qemu-aarch64` binfmt), so you can build and
run Graviton images locally.

### Not installed, and it matters

- **`session-manager-plugin`** — needed for the SSM tunnel to RDS. CI installs it
  per-run. To work with the database locally, install it first.
- **Docker** — deliberately not used. Podman is rootless; docker would need a
  group change that does not take effect in an already-running shell.

### Rootless podman quirks you will hit

```bash
# 1. Unqualified image names are refused. Always use the full registry:
podman build -f services/postgrest/Dockerfile .      # FROM docker.io/... required

# 2. Cannot bind ports below 1024. Caddy's listen port is parameterised for this:
podman run -e HTTPS_PORT=8443 ...
```

---

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
environment alone would be no gate at all.

### Common operations

```bash
# Infrastructure
gh workflow run terraform.yml -f environment=dev -f action=plan
gh workflow run terraform.yml -f environment=dev -f action=apply
gh workflow run terraform.yml -f environment=dev -f action=destroy   # refuses prod

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

### AWS

| Symptom | Cause |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | GitHub emits an **immutable subject prefix** with numeric IDs: `repo:owner@123/repo@456:...`, not `repo:owner/repo:...`. Check with `gh api repos/OWNER/NAME/actions/oidc/customization/sub` |
| `Client.InvalidKMSKey.InvalidState` | **Misleading.** The key is fine — Auto Scaling lacks key-policy permission. `aws_kms_key_policy` **replaces** the default policy, so "root has kms:*" does not cover service-linked roles |
| `Volume of size 20GB is smaller than snapshot` | The ECS-optimized AL2023 arm64 AMI ships a 30 GiB snapshot |
| `Container.image should not be null or empty` | An unset GitHub variable arrives as `TF_VAR_x=""` — an **empty string, not null**. Use `try(trimspace(x), "") == ""`, not `coalesce` (which errors on all-empty args) |
| Terraform changes config but never rolls it out | Do **not** put `ignore_changes = [task_definition]` on a service. Point it at `max(terraform_revision, latest_revision)` instead |
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

### CI

- A **21-minute hang on "Assume AWS role"** has been observed once. Cancel and re-dispatch; do not wait it out.
- Piping `psql` into `sed` under `set -e -o pipefail` **discards the error text**. Capture with `2>&1` and print explicitly.
- A literal ESC byte (`0x1b`) in a workflow file makes YAML unparseable. Check with `grep -P '\x1b'`.

---

## 7. Outstanding work and known risks

### Operator actions — nobody has done these

| Item | Severity | Action |
|---|---|---|
| **Old BSC wallet unswept** | **HIGH** | Private key was public on GitHub (`get-wallet-address.mjs`). Sweep any funds to a new wallet |
| `Habeshabingo91bot` token still live | MEDIUM | `@BotFather` → `/deletebot`. The app moved to `BingoNovaaBot`, so identity-forgery risk is gone; bot impersonation/phishing remains |
| `sms_api_key` was published | MEDIUM | Rotate it |
| Stale AWS secrets in GitHub | LOW | Delete `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEPLOY_ROLE_ARN` — leftovers from pre-OIDC. IAM user `nati` has no access keys, so they are inert, but they invite confusion |
| Bot token in 2 git commits | LOW | Rotation makes it inert. History rewrite is optional cleanup |

### Engineering work

**Phase 3 (remaining): port the 25 edge functions.** `supabase/functions/*` are
Deno handlers; they become routes in one Node/Express container (`services/functions`,
host port 8080 — Caddy already routes `/functions/v1/*` there). Mostly mechanical
(`Deno.serve` → route, `Deno.env.get` → `process.env`), with two real changes:

- **`claim-bingo`** — delete the post-response `setTimeout`. The ticker owns
  claim-window finalization now (`game_tick()`).
- **The three `ethers` signing functions** — take the key from **KMS**, not the
  `settings` table.

**Phase 4 (auth) matters before real money.** Right now:
- Telegram `initData` HMAC is **never verified** — anyone can claim any identity
- Wallet connection has no signature challenge
- Admin access is one shared string held in browser React state
- All 25 functions send `Access-Control-Allow-Origin: *`, including money-moving ones

**Known-deliberate weaknesses**, accepted at this tier:
- Single instance / single AZ (see §2)
- `telegram_bot_token` is still in SSM *and* readable by the app; Phase 4 should
  make SSM the only source
- The anonymous-access probe reports "inconclusive" on empty tables — it cannot
  prove RLS protects a table with no rows

---

## 8. File map

```
infra/
  environments/{dev,prod}/    Terraform roots. prod is written but NEVER applied
  modules/                    vpc · security_groups · kms · ssm · iam · rds
                              ecr · ecs · ecs_service · s3_cloudfront · monitoring
db/
  00-bootstrap/               Repeatable. Runs FIRST. Supabase compat layer
    001_roles_and_auth_shim   roles, auth.uid(), extensions, publication, _realtime
    002_checksum_reconciliation  deliberate edits to applied migrations
  20-post/                    Repeatable. Runs LAST
    001_rds_deltas            removes the 4s cron job, schedules cleanups, asserts wal_level
    002_game_tick             THE GAME LOOP — server-authoritative, one transaction
    003_settings_rls_hardening  deny-by-default RLS + anon assertions
services/
  ticker/                     Node. Game loop. Only genuinely new code
  postgrest/ realtime/ caddy/ Thin images over upstream (CA bundle, config)
  functions/                  EMPTY — Phase 3's remaining work
scripts/
  bootstrap-aws.sh            One-time. Idempotent. State bucket, OIDC, executor role
  db-tunnel.sh                SSM port-forward to RDS
  db-migrate.sh               Versioned + repeatable runner with checksums
  post-apply.sh               RDS reboot when pending, publishes wallet address
  probe-public-access.sh      Anonymous exposure probe (verified against bait)
  derive-wallet-address.mjs   Address from the KMS public key
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
