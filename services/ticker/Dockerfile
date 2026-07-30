# Ticker: the game loop.
#
# Built for arm64 to match the Graviton (t4g.small) container instance.
#
# BUILD CONTEXT IS THE REPOSITORY ROOT, so the RDS CA bundle in docker/ is
# shared across services rather than duplicated. Build with:
#   docker build -f services/ticker/Dockerfile .

# --platform=$BUILDPLATFORM: install NATIVELY, do not emulate.
#
# Same change, and same reason, as services/functions/Dockerfile: running npm
# under QEMU arm64 killed a functions deploy with
#
#   qemu: uncaught target signal 4 (Illegal instruction) - core dumped
#
# and then hung rather than failing. This image has the same exposure -- pg and
# @aws-sdk/client-cloudwatch, both pure JavaScript -- so it gets the same fix
# before it bites here too, rather than after.
#
# The .node guard below is what keeps the assumption honest if a dependency with
# a native addon is ever added.
FROM --platform=$BUILDPLATFORM docker.io/library/node:22-alpine AS deps

WORKDIR /app

# Manifests only, so a source-only change reuses the cached dependency layer.
COPY services/ticker/package.json services/ticker/package-lock.json* ./

# --omit=dev: nothing here needs a build step, so dev dependencies would only
# enlarge the image and its vulnerability surface.
RUN npm ci --omit=dev --no-audit --no-fund

RUN if find node_modules -name '*.node' -print -quit 2>/dev/null | grep -q .; then \
      echo "FATAL: a dependency ships a native addon (.node):" >&2; \
      find node_modules -name '*.node' >&2; \
      echo "This stage installs on the BUILD architecture, so that binary would" >&2; \
      echo "be the wrong one for the arm64 runtime image. Either drop the" >&2; \
      echo "dependency or remove --platform=\$BUILDPLATFORM and accept QEMU." >&2; \
      exit 1; \
    fi

# ---------------------------------------------------------------------------

FROM docker.io/library/node:22-alpine

# dumb-init makes PID 1 forward signals properly. Without it Node receives no
# SIGTERM on ECS task replacement, never runs its shutdown handler, and never
# releases the advisory lock -- so a standby waits for the TCP connection to be
# reaped instead of taking over immediately.
RUN apk add --no-cache dumb-init

# Amazon's RDS CA bundle.
#
# RDS presents a certificate signed by an Amazon CA that is not in Node's
# default trust store, so an unconfigured connection dies with "self-signed
# certificate in certificate chain". Baking the published bundle in lets us
# verify properly instead of reaching for rejectUnauthorized:false, which
# encrypts the connection while verifying nothing.
#
# COPY from the repo rather than ADD from a URL: hermetic, no build-time network
# dependency, verifiable locally. (ADD from URL worked in this base image but
# silently produced no file in postgrest/postgrest, so both now use COPY.)
COPY docker/rds-global-bundle.pem /opt/rds-global-bundle.pem
ENV PGSSLROOTCERT=/opt/rds-global-bundle.pem

ENV NODE_ENV=production
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY services/ticker/package.json ./
COPY services/ticker/src ./src

# Run unprivileged. The node image ships a `node` user for exactly this.
USER node

# No HEALTHCHECK: this service exposes no port and has no endpoint to probe.
# Liveness is asserted externally by the SecondsSinceLastNumberCalled alarm,
# which is a far better signal -- a process can be running happily while the
# game is frozen.

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/index.js"]
