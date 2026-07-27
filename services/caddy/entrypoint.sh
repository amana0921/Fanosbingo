#!/bin/sh
#
# Materialise the TLS certificate from the environment, then hand off to Caddy.
#
# ECS injects secrets as environment variables, but Caddy wants a certificate
# and key on disk. This bridges the two without the certificate ever being
# baked into the image or committed to the repository.
#
# Written to a tmpfs-backed path with restrictive permissions, so the private
# key never touches the container's writable layer.

set -eu

CERT_DIR=/etc/caddy/certs

if [ -z "${ORIGIN_CERT:-}" ] || [ -z "${ORIGIN_KEY:-}" ]; then
  echo "FATAL: ORIGIN_CERT and ORIGIN_KEY must be set." >&2
  echo "Generate a Cloudflare Origin Certificate and store both in SSM." >&2
  exit 1
fi

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

# The values arrive with literal \n rather than real newlines, because that is
# what survives being passed through SSM and the ECS task definition. PEM
# parsing fails on the literal form with an error that points at the
# certificate rather than at the encoding, so convert explicitly.
printf '%b\n' "$ORIGIN_CERT" > "$CERT_DIR/origin.pem"
printf '%b\n' "$ORIGIN_KEY"  > "$CERT_DIR/origin.key"

chmod 600 "$CERT_DIR/origin.pem" "$CERT_DIR/origin.key"

# Fail here, with a clear message, rather than letting Caddy fail later with a
# generic TLS load error.
if ! grep -q "BEGIN CERTIFICATE" "$CERT_DIR/origin.pem"; then
  echo "FATAL: ORIGIN_CERT does not look like PEM (no BEGIN CERTIFICATE)." >&2
  exit 1
fi
if ! grep -q "PRIVATE KEY" "$CERT_DIR/origin.key"; then
  echo "FATAL: ORIGIN_KEY does not look like PEM (no PRIVATE KEY)." >&2
  exit 1
fi

echo "TLS material written to $CERT_DIR"

exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
