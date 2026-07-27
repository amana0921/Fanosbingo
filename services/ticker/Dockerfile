# Ticker: the game loop.
#
# Built for arm64 to match the Graviton (t4g.small) container instance. Build
# with --platform linux/arm64 from an x86 machine, or let CI use a native arm64
# runner.

FROM node:22-alpine AS deps

WORKDIR /app

# Copy manifests only, so a source-only change reuses the cached dependency
# layer rather than reinstalling on every build.
COPY package.json package-lock.json* ./

# --omit=dev: nothing here needs a build step, so dev dependencies would only
# enlarge the image and its vulnerability surface.
RUN npm ci --omit=dev --no-audit --no-fund 2>/dev/null || \
    npm install --omit=dev --no-audit --no-fund

# ---------------------------------------------------------------------------

FROM node:22-alpine

# dumb-init makes PID 1 forward signals properly. Without it Node receives no
# SIGTERM on ECS task replacement, never runs its shutdown handler, and never
# releases the advisory lock -- so a standby waits for the TCP connection to be
# reaped instead of taking over immediately.
RUN apk add --no-cache dumb-init

ENV NODE_ENV=production
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

# Run unprivileged. The node image ships a `node` user for exactly this.
USER node

# No HEALTHCHECK: this service exposes no port and has no endpoint to probe.
# Liveness is asserted externally by the SecondsSinceLastNumberCalled alarm,
# which is a far better signal — a process can be running happily while the
# game is frozen.

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/index.js"]
