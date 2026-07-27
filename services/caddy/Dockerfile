# Caddy: TLS termination and routing.
#
# Stock image, no xcaddy build. TLS uses a Cloudflare Origin Certificate rather
# than Let's Encrypt DNS-01, which would have required compiling a custom Caddy
# with the Cloudflare DNS module -- a Go build under QEMU emulation on every CI
# run, for maybe ten minutes a time.
#
# That trade is easy: Origin Certificates are valid for FIFTEEN YEARS, so the
# renewal automation being given up is a task due in 2041. It also avoids
# issuing an API token with DNS-edit permissions.
#
# BUILD CONTEXT IS THE REPOSITORY ROOT:
#   docker build -f services/caddy/Dockerfile .

FROM docker.io/library/caddy:2.8-alpine

COPY services/caddy/Caddyfile /etc/caddy/Caddyfile
COPY services/caddy/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

# 80 is not exposed: Cloudflare connects to the origin on 443 only, and the
# security group admits nothing else.
EXPOSE 443

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
