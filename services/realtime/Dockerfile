# Supabase Realtime, mirrored into ECR unchanged.
#
# WHY MIRROR RATHER THAN PULL UPSTREAM DIRECTLY:
#
#   Anonymous Docker Hub pulls are rate-limited per source IP. An ECS task that
#   restarts during a rate-limit window cannot start, and the failure ("toomany
#   requests") arrives at the worst possible moment -- during a deploy or an
#   instance replacement. Mirroring also makes the tag immutable, so what runs
#   is always exactly what was reviewed.
#
# NO CA BUNDLE HERE, unlike postgrest and ticker. Realtime v2.34.47 exposes no
# DB_SSL setting and its runtime configuration contains no ssl references at
# all -- verified by grepping runtime.exs inside the image. It connects to
# PostgreSQL in plaintext. See the security note in infra/environments/dev
# where the service is defined; the practical consequence is that
# rds.force_ssl must NOT be enabled, or Realtime cannot connect at all.
#
# Pinned exactly. Realtime runs schema migrations against _realtime on every
# boot, so an unpinned tag means an unreviewed migration can run during an
# unrelated restart.

FROM docker.io/supabase/realtime:v2.34.47
