#!/usr/bin/env bash
#
# Open an SSM port-forwarding tunnel to RDS.
#
# RDS lives in isolated subnets with no route to the internet, which is the
# correct place for a database holding player balances. That leaves a real
# question: how does anything ever run a migration against it?
#
# The wrong answers are making it publicly accessible, or putting a bastion host
# on the internet. Both create a permanent attack surface to solve an occasional
# problem.
#
# This uses AWS-StartPortForwardingSessionToRemoteHost: SSM tunnels through the
# existing ECS container instance to RDS:5432. No inbound port is opened, no
# bastion exists, no SSH key is involved, and every session is a CloudTrail
# event attributable to an IAM principal.
#
# Sourcing this script exports:
#   DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DATABASE_URL TUNNEL_PID
#
# Usage:
#   source scripts/db-tunnel.sh dev
#   psql "$DATABASE_URL" -c 'SELECT 1'
#   stop_db_tunnel
#
# Requires: aws CLI, session-manager-plugin, and IAM permission for
# ssm:StartSession plus secretsmanager:GetSecretValue on the RDS master secret.

set -euo pipefail

ENVIRONMENT="${1:-${ENVIRONMENT:-dev}}"
PROJECT="${PROJECT:-fanosbingo}"
LOCAL_PORT="${LOCAL_PORT:-15432}"

PREFIX="${PROJECT}-${ENVIRONMENT}"
DB_IDENTIFIER="${PREFIX}-pg"

GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
_info() { echo "${GREEN}==>${NC} $*" >&2; }
_warn() { echo "${YELLOW}==>${NC} $*" >&2; }
_die()  { echo "${RED}ERROR:${NC} $*" >&2; return 1; }

command -v aws >/dev/null 2>&1 || _die "AWS CLI not found"
command -v session-manager-plugin >/dev/null 2>&1 \
  || _die "session-manager-plugin not found. Install: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"

# ---------------------------------------------------------------------------
# Find the tunnel host
#
# Looked up by tag, never hardcoded: the ASG replaces instances, so the id
# changes. Filtering on running state avoids picking a terminated one.
# ---------------------------------------------------------------------------
_info "Locating tunnel host"

INSTANCE_ID="$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PREFIX}-app" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text 2>/dev/null)"

[ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ] \
  || _die "No running instance tagged ${PREFIX}-app. Has terraform apply run?"

# An instance can be running while its SSM agent is not yet registered, which
# fails the session with a far less obvious message.
PING="$(aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)"

[ "$PING" = "Online" ] \
  || _die "Instance ${INSTANCE_ID} SSM agent is '${PING}', not Online. Wait ~60s after launch and retry."

_info "  ${INSTANCE_ID} (SSM Online)"

# ---------------------------------------------------------------------------
# Database connection details
# ---------------------------------------------------------------------------
_info "Reading database details"

read -r DB_HOST DB_PORT DB_NAME DB_USER SECRET_ARN <<<"$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].[Endpoint.Address,Endpoint.Port,DBName,MasterUsername,MasterUserSecret.SecretArn]' \
  --output text)"

[ -n "$DB_HOST" ] && [ "$DB_HOST" != "None" ] || _die "Could not resolve ${DB_IDENTIFIER}"

# The master password is generated and rotated by RDS in Secrets Manager and has
# never passed through Terraform state.
DB_PASSWORD="$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query SecretString --output text | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')"

[ -n "$DB_PASSWORD" ] || _die "Could not read the master password from Secrets Manager"

_info "  ${DB_NAME} on ${DB_HOST}"

# ---------------------------------------------------------------------------
# Open the tunnel
#
# Pick a free local port rather than assuming one. A previous session's port can
# still be held for a while after it closes, and the failure mode is a bare
# "tunnel did not become ready" that looks like an SSM or network problem rather
# than a port collision.
# ---------------------------------------------------------------------------
_port_free() {
  ! (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null
}

_start_port="$LOCAL_PORT"
for _ in $(seq 0 20); do
  _port_free "$LOCAL_PORT" && break
  LOCAL_PORT=$((LOCAL_PORT + 1))
done

_port_free "$LOCAL_PORT" || _die "No free local port found between ${_start_port} and ${LOCAL_PORT}"
[ "$LOCAL_PORT" = "$_start_port" ] || _warn "Port ${_start_port} busy; using ${LOCAL_PORT}"

_info "Opening tunnel localhost:${LOCAL_PORT} -> ${DB_HOST}:${DB_PORT}"

aws ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${DB_HOST}\"],\"portNumber\":[\"${DB_PORT}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}" \
  >/tmp/db-tunnel-${ENVIRONMENT}.log 2>&1 &

TUNNEL_PID=$!

# Poll rather than sleeping a fixed interval: the session takes anywhere from
# one to fifteen seconds depending on SSM latency, and a fixed sleep is either
# slow or flaky.
_info "Waiting for the tunnel"
for _ in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/${LOCAL_PORT}) 2>/dev/null; then
    exec 3<&- 2>/dev/null || true
    exec 3>&- 2>/dev/null || true
    break
  fi
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    _warn "Tunnel process exited. Log:"
    cat /tmp/db-tunnel-${ENVIRONMENT}.log >&2
    _die "Tunnel failed to start"
  fi
  sleep 1
done

(exec 3<>/dev/tcp/127.0.0.1/${LOCAL_PORT}) 2>/dev/null \
  || _die "Tunnel did not become ready within 30s"
exec 3<&- 2>/dev/null || true
exec 3>&- 2>/dev/null || true

_info "  ready (pid ${TUNNEL_PID})"

# ---------------------------------------------------------------------------
# Exports
#
# The password is URL-encoded: RDS-generated passwords contain characters that
# are structurally meaningful in a URI, and an unencoded one produces a baffling
# "could not translate host name" rather than an auth error.
# ---------------------------------------------------------------------------
DB_PASSWORD_ENC="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$DB_PASSWORD")"

export DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD TUNNEL_PID
export DB_LOCAL_PORT="$LOCAL_PORT"
export DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD_ENC}@127.0.0.1:${LOCAL_PORT}/${DB_NAME}"
export PGSSLMODE="${PGSSLMODE:-require}"

stop_db_tunnel() {
  if [ -n "${TUNNEL_PID:-}" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
    echo "${GREEN}==>${NC} Tunnel closed" >&2
  fi
}

_info "DATABASE_URL exported. Close with: stop_db_tunnel"
