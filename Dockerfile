# syntax=docker/dockerfile:1
# Corella assistant HTTP service. Runtime dependency is zod only, so the image is the Bun
# slim base plus node_modules, src/ and corpus/. Pinned by digest; bump deliberately.
ARG BUN_IMAGE=oven/bun:1-slim@sha256:cb3bbbb08e13a4a2ff400f24c7a2a1d5efa83f6ef8544d52d95a519631e2fc61

FROM ${BUN_IMAGE} AS deps
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --production --frozen-lockfile

FROM ${BUN_IMAGE} AS runtime
# The pinned base lags Debian security updates (Trivy flagged fixed CVEs in perl-base and
# friends on 2026-09-23), so take the distro's patched packages before adding anything.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8080

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY corpus ./corpus

# Build identity, surfaced by GET /version and in every request log line.
ARG GIT_SHA=dev
ARG BUILD_TIME=unknown
ENV GIT_SHA=${GIT_SHA} \
    BUILD_TIME=${BUILD_TIME}

# The base image ships a non-root `bun` user.
USER bun
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["bun", "-e", "fetch('http://127.0.0.1:8080/healthz').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]

CMD ["bun", "src/server.ts"]
