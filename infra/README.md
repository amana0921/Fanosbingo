# Fanos Bingo — Infrastructure

Terraform for the AWS migration. Target: **~$30/month** at ~200 users, structured so
growth is a configuration change rather than a rewrite.

## Layout

```
infra/
├── environments/
│   ├── dev/     # BSC testnet. NOT always-on — apply, test, destroy.
│   └── prod/    # BSC mainnet. Always-on.
└── modules/
    ├── vpc/              VPC, 2 public + 2 isolated subnets, IGW, routes
    ├── security_groups/  sg-app (Cloudflare-locked), sg-rds
    ├── kms/              encryption CMK + secp256k1 wallet signing key
    ├── ssm/              config and secrets (values set out-of-band)
    ├── iam/              GitHub OIDC, EC2 instance role, ECS task roles
    ├── rds/              PostgreSQL 16 + parameter group
    ├── ecr/              image repositories
    ├── ecs/              cluster, EC2 capacity provider, ASG, launch template
    ├── s3_cloudfront/    SPA hosting (Phase 5)
    └── monitoring/       Budgets, SNS, baseline alarms
```

## Design decisions that drive the cost

| Decision | Saves | Trade |
|---|---|---|
| ECS on **EC2** capacity provider, not Fargate | ~$53/mo | Same task definitions. Stage 3 swaps the capacity provider to `FARGATE`. |
| **No ALB** — Cloudflare proxies to the Elastic IP | ~$17/mo | Requires the Cloudflare origin lock (below) to stay correct. |
| **No AWS WAF** — Cloudflare free plan | ~$13/mo | Cloudflare's managed ruleset instead. |
| **No NAT Gateway, no VPC endpoints** | ~$61/mo | Instance in a public subnet with locked ingress. |
| **SSM Parameter Store**, not Secrets Manager | ~$2/mo | No managed rotation, which none of these values use. |

Single instance, single AZ. An instance failure is a 3–5 minute outage while the
ASG replaces it; a database failure is a ~25 minute PITR restore. That is the
deliberate trade for the budget. Stage 2 (`instance_count = 2`, `multi_az = true`)
buys it back for ~$30 more.

## The Cloudflare origin lock

`sg-app` admits port 443 **only** from Cloudflare's published IPv4 ranges, fetched
at plan time from `https://www.cloudflare.com/ips-v4`. This is what makes a
public-subnet instance safe — without it, anyone could bypass Cloudflare's WAF
and rate limiting by hitting the Elastic IP directly.

Two consequences:

- `api.<domain>` and `rt.<domain>` **must be proxied** (orange cloud). DNS-only
  records will be black-holed by the security group.
- A `terraform plan` needs network access to that endpoint. There is a
  precondition that fails the plan if the fetch returns fewer than 10 or more
  than 40 ranges, so a bad response cannot silently produce a broken rule set.

## How changes reach AWS

Through a pull request, and only through a pull request.

```
PR opened   ──▶  fmt · validate · trivy · plan ──▶ plan posted as a PR comment
PR merged   ──▶  apply to prod  (gated by the `prod` GitHub Environment)
Manual      ──▶  plan / apply / destroy any environment (workflow_dispatch)
```

Authentication is OIDC — there is no AWS access key anywhere in this repository.
Dev is deliberately not applied on merge; it is on-demand infrastructure you
stand up to test something and destroy afterwards.

## One-time bootstrap

Exactly one step is manual, and it is unavoidable: GitHub Actions authenticates
via an OIDC role, but something already authenticated has to create that role.

```bash
./scripts/bootstrap-aws.sh
```

Idempotent — re-running it repairs drift rather than failing. It creates the
state bucket (versioned, encrypted, private, with a 90-day lifecycle on old
versions), the GitHub OIDC provider, and the `terraform-executor` role. It then
prints the three GitHub variables to set.

Two roles exist deliberately, with different privilege levels:

| Role | Created by | Used by | Can do |
|---|---|---|---|
| `terraform-executor` | bootstrap | infra workflows | manage infrastructure |
| `github-deploy` | Terraform | app workflows | push ECR, roll ECS, sync S3 |

An application deploy must never be able to delete the database. The executor
role is broad, but it carries deny guardrails preventing it from widening its own
trust policy or deleting the state bucket — the real control is its *trust*
policy, which names one repository and specific branches and environments.

### GitHub configuration

Variables (`Settings > Secrets and variables > Actions > Variables`):

| Variable | Value |
|---|---|
| `AWS_ROLE_ARN` | printed by the bootstrap script |
| `AWS_REGION` | `us-east-1` |
| `TF_STATE_BUCKET` | printed by the bootstrap script |
| `DOMAIN_NAME` | `fanosbingo.com` |
| `ALERT_EMAIL` | where alarms go |

Secrets (`... > Secrets`), consumed by the *Sync secrets to SSM* workflow:

`TELEGRAM_BOT_TOKEN` · `TELEGRAM_WEBHOOK_SECRET` · `APP_JWT_SECRET` ·
`APP_ADMIN_BOOTSTRAP_KEY` · `DB_POSTGREST_PASSWORD` · `DB_APP_PASSWORD`

Environments (`Settings > Environments`): create `dev` (no protection) and
`prod` (**enable required reviewers**). That approval gate is what stops an
accidental merge from reshaping the environment holding real money.

## Running it locally

Rarely needed, but for a quick plan:

```bash
cd infra/environments/dev
echo 'bucket = "fanosbingo-tfstate-<account-id>"' > backend.hcl   # gitignored
cp terraform.tfvars.example terraform.tfvars                      # gitignored
terraform init -backend-config=backend.hcl
terraform plan
```

## After an apply

`scripts/post-apply.sh` runs automatically at the end of the apply job. It is
idempotent, so it is a no-op on a steady-state apply. It handles:

- **Rebooting RDS when static parameters are pending.** `rds.logical_replication`
  and `shared_preload_libraries` do not take effect until the instance restarts.
  This matters more than it sounds: without `wal_level=logical` the Realtime
  container starts cleanly, connects cleanly, and then silently delivers nothing.
  There is no error to chase.
- **Publishing the hot-wallet address**, derived from the KMS public key and
  written to `/<prefix>/bsc/hot_wallet_address`. The private half never leaves
  KMS, so unlike the wallet this replaces, there is nothing that *could* be
  committed.
- **Reporting what still needs a human.**

### What is still genuinely manual

| Step | Why it cannot be automated |
|---|---|
| Confirming the SNS subscription email | AWS requires the recipient to click the emailed link. A Lambda→Telegram forwarder auto-confirms and removes this; planned for Phase 6. |
| Cloudflare DNS records | Automatable via the Cloudflare provider, deferred until there is a real Elastic IP to point at. Until then, set `api.` and `rt.` as **proxied** A records manually. |
| Funding the hot wallet | Moving money. Deliberately not automated. |

## Cloudflare settings that are not optional

| Setting | Value | Why |
|---|---|---|
| Bot Fight Mode | **Off** | Challenges non-browser clients — which is what Telegram's webhook caller and a WebSocket upgrade look like. |
| WAF skip rule | on `/functions/v1/telegram-bot-webhook` | Telegram does not solve challenges; it retries a few times and then disables your webhook. |
| SSL mode | **Full (strict)** | Anything less either loops or silently sends plaintext on the origin leg. |
| `api.` / `rt.` records | **Proxied** | Required by the origin lock. |
| Apex / `www` | **DNS-only** | Points at CloudFront; proxying would double-CDN for no gain. |

## Troubleshooting

### `Not authorized to perform sts:AssumeRoleWithWebIdentity`

Almost always the OIDC subject claim, not the permissions. GitHub emits subject
claims with an **immutable prefix containing numeric owner and repository IDs**:

```
repo:amana0921@221070182/Fanosbingo@1305204469:environment:dev
```

not the form the documentation shows:

```
repo:amana0921/Fanosbingo:environment:dev
```

A trust policy written the documented way therefore matches nothing, and STS
gives no hint which claim failed. Check what your repository actually emits:

```bash
gh api repos/OWNER/NAME/actions/oidc/customization/sub
```

`scripts/bootstrap-aws.sh` lists both forms and prints the emitted prefix when
it runs, so re-running it fixes this.

### Trivy fails the build

Findings are accepted in `.trivyignore`, each with a written justification.
Anything not listed there fails deliberately. Add an entry only when the finding
is a conscious architectural decision — and write down why, next to it.

Note that Trivy's config file (`.trivy.yaml`) has **no** per-ID ignore
mechanism; `.trivyignore` is the only one that works. Documenting suppressions
in config-file comments looks correct and does nothing.

### Realtime connects but delivers no row changes

`rds.logical_replication` did not take effect. It is a static parameter and
needs an instance reboot:

```bash
aws rds describe-db-instances --db-instance-identifier fanosbingo-prod-pg \
  --query 'DBInstances[0].DBParameterGroups[0].ParameterApplyStatus'
```

If that says `pending-reboot`, run `scripts/post-apply.sh <env>`. There is no
error message for this condition, which is what makes it costly.

### Instance is healthy but the site is unreachable

The Elastic IP was probably not re-associated on boot. Check the bootstrap log
on the instance:

```bash
aws ssm start-session --target <instance-id>
sudo cat /var/log/fanosbingo-bootstrap.log
```

The user-data script logs an explicit multi-line ERROR block on failure. The
usual cause is the instance role's `ec2:AssociateAddress` tag condition not
matching.

## Common operations

```bash
# Shell into the instance — no SSH key, no open port
aws ssm start-session --target <instance-id>

# Tear down dev when you are done testing
cd environments/dev && terraform destroy

# See what an apply would change
terraform plan -out=tfplan && terraform show tfplan
```

`*.tfplan` files are gitignored: plan output can contain secret values in
cleartext.

## Notes

- `.terraform.lock.hcl` **is** committed, so your machine and CI resolve
  identical provider versions.
- `terraform.tfvars` is **not** committed; `terraform.tfvars.example` is.
- Dev uses `10.30.0.0/16`, prod uses `10.20.0.0/16` — non-overlapping, so they
  could be peered later.
- The GitHub OIDC provider is account-wide. Whichever environment you apply
  first sets `create_github_oidc_provider = true`; the other sets it false.
