# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# adminService  ->  listens on 3003, health probe at /api/health
# Build context MUST be ./backend  (docker build -f adminService/Dockerfile ./backend)
# ---------------------------------------------------------------------------

# ---------- Stage 1: install production dependencies ----------
FROM node:18-alpine AS deps
WORKDIR /app
COPY adminService/package.json adminService/package-lock.json ./
# npm ci gives a reproducible install straight from the lockfile
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

# ---------- Stage 2: minimal runtime ----------
FROM node:18-alpine AS runtime

# tini reaps zombies and forwards SIGTERM so Kubernetes rolling updates are graceful
RUN apk add --no-cache tini curl \
    && addgroup -g 10001 -S nodejs \
    && adduser  -u 10001 -S nodeapp -G nodejs

ENV NODE_ENV=production \
    PORT=3003 \
    NPM_CONFIG_LOGLEVEL=warn

WORKDIR /app

COPY --from=deps --chown=10001:10001 /app/node_modules ./node_modules
COPY --chown=10001:10001 adminService/ ./

# Drop root before running the app
USER 10001:10001

EXPOSE 3003

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:${PORT}/api/health || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "index.js"]
