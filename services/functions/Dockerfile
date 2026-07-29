# Functions service: auth, and the operations RLS cannot express.
#
# Built for arm64 to match the Graviton (t4g.small) instance. An x86 image
# pushes happily and then fails at runtime with "exec format error".
#
# BUILD CONTEXT IS THE REPOSITORY ROOT, so the RDS CA bundle in docker/ is
# shared rather than duplicated:
#   podman build -f services/functions/Dockerfile .

FROM docker.io/library/node:22-alpine AS deps

WORKDIR /app

# Manifests only, so a source-only change reuses the cached dependency layer
# rather than reinstalling under QEMU emulation on every CI run.
COPY services/functions/package.json services/functions/package-lock.json* ./

RUN npm install --omit=dev --no-audit --no-fund

# ---------------------------------------------------------------------------

FROM docker.io/library/node:22-alpine

# dumb-init so PID 1 forwards signals. Without it Node never receives SIGTERM on
# task replacement, never drains, and in-flight requests are cut mid-transaction.
RUN apk add --no-cache dumb-init

# Amazon's RDS CA bundle. RDS presents a certificate signed by a CA that is not
# in Node's default trust store, so an unconfigured connection dies with
# "self-signed certificate in certificate chain". Baking the published bundle in
# lets us verify properly instead of reaching for rejectUnauthorized:false,
# which encrypts while verifying nothing.
COPY docker/rds-global-bundle.pem /opt/rds-global-bundle.pem
ENV PGSSLROOTCERT=/opt/rds-global-bundle.pem

ENV NODE_ENV=production
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY services/functions/package.json ./
COPY services/functions/src ./src

# Run unprivileged. The node image ships a `node` user for exactly this.
USER node

EXPOSE 8080

# No HEALTHCHECK here. A container health check whose binary is missing reports
# UNKNOWN forever and hangs the ECS deployment at IN_PROGRESS -- which cost real
# time on postgrest. Caddy health-checks /healthz instead, which tests the path
# traffic actually takes.

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/index.js"]
