# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# StreamFlix React frontend.
#
# Build context is ./frontend
#   docker build -f frontend/Dockerfile ./frontend
#
# Create React App inlines every REACT_APP_* value at BUILD time, so they are
# passed as build args. They default to same-origin relative paths that the
# bundled nginx reverse proxy resolves (see nginx/default.conf.template) --
# that keeps one image portable across local / dev / prod with no rebuild.
# ---------------------------------------------------------------------------

# ---------- Stage 1: compile the SPA ----------
FROM node:18-alpine AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY . .

ARG REACT_APP_AUTH_API_URL=/svc/auth/api
ARG REACT_APP_STREAMING_API_URL=/svc/streaming/api
ARG REACT_APP_STREAMING_PUBLIC_URL=/svc/streaming
ARG REACT_APP_ADMIN_API_URL=/svc/admin/api/admin
ARG REACT_APP_CHAT_API_URL=/svc/chat/api/chat
# "/" is the same-origin form for socket.io-client: it is read as a namespace,
# so the client derives the host from window.location and connects to
# /socket.io on this origin, which nginx proxies to the chat service.
# It must NOT be empty — src/config/env.js treats '' as unset and falls back
# to http://localhost:3004, which would break every deployed build.
ARG REACT_APP_CHAT_SOCKET_URL="/"

ENV REACT_APP_AUTH_API_URL=${REACT_APP_AUTH_API_URL} \
    REACT_APP_STREAMING_API_URL=${REACT_APP_STREAMING_API_URL} \
    REACT_APP_STREAMING_PUBLIC_URL=${REACT_APP_STREAMING_PUBLIC_URL} \
    REACT_APP_ADMIN_API_URL=${REACT_APP_ADMIN_API_URL} \
    REACT_APP_CHAT_API_URL=${REACT_APP_CHAT_API_URL} \
    REACT_APP_CHAT_SOCKET_URL=${REACT_APP_CHAT_SOCKET_URL} \
    GENERATE_SOURCEMAP=false \
    CI=false

RUN npm run build

# ---------- Stage 2: serve with unprivileged nginx ----------
# nginx-unprivileged runs as uid 101 and binds 8080, so the pod needs no
# root and no NET_BIND_SERVICE capability.
FROM nginxinc/nginx-unprivileged:1.27-alpine AS runtime

USER root
RUN apk add --no-cache curl
COPY nginx/proxy-common.conf /etc/nginx/proxy-common.conf
# Files in /etc/nginx/templates are envsubst-rendered into conf.d at startup
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/build /usr/share/nginx/html
RUN chown -R 101:101 /usr/share/nginx/html /etc/nginx
USER 101

# Defaults match the Helm chart's Service names; docker-compose overrides them.
ENV AUTH_UPSTREAM=streamingapp-auth:3001 \
    STREAMING_UPSTREAM=streamingapp-streaming:3002 \
    ADMIN_UPSTREAM=streamingapp-admin:3003 \
    CHAT_UPSTREAM=streamingapp-chat:3004 \
    MAX_UPLOAD_SIZE=1024m \
    NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx/conf.d

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1

# Stated explicitly rather than inherited, so the run command is visible here.
# The base image's ENTRYPOINT (/docker-entrypoint.sh) still runs first and is
# what renders /etc/nginx/templates/*.template through envsubst.
CMD ["nginx", "-g", "daemon off;"]
