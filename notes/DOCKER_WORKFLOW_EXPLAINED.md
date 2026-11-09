# Docker Workflow — Acquisitions API

> A complete end-to-end reference: how the **Dockerfile**, **docker-compose** files, **shell scripts**, **GitHub Actions workflows**, and **Jest tests** all wire together into a single, consistent DevOps pipeline.

---

## Table of Contents

1. [Big-Picture Architecture](#1-big-picture-architecture)
2. [Dockerfile — Multi-Stage Build](#2-dockerfile--multi-stage-build)
3. [.dockerignore — What Never Enters the Image](#3-dockerignore--what-never-enters-the-image)
4. [docker-compose.dev.yml — Development Stack](#4-docker-composedevyml--development-stack)
5. [docker-compose.prod.yml — Production Stack](#5-docker-composeprodymll--production-stack)
6. [dev.sh — Development Startup Script](#6-devsh--development-startup-script)
7. [prod.sh — Production Startup Script](#7-prodsh--production-startup-script)
8. [npm Scripts — The Entry Points](#8-npm-scripts--the-entry-points)
9. [GitHub Actions Workflows](#9-github-actions-workflows)
   - [Lint & Format](#lint--format-check-lint-and-formatyml)
   - [Tests](#tests-testsyml)
   - [Docker Build & Push](#docker-build--push-docker-build-and-pushyml)
10. [Jest Testing Setup](#10-jest-testing-setup)
11. [Environment Files](#11-environment-files)
12. [Complete Dev Flow — Step by Step](#12-complete-dev-flow--step-by-step)
13. [Complete Prod Flow — Step by Step](#13-complete-prod-flow--step-by-step)
14. [CI/CD Pipeline — End to End](#14-cicd-pipeline--end-to-end)
15. [Key Design Decisions](#15-key-design-decisions)

---

## 1. Big-Picture Architecture

```
Developer Workstation
│
├─ npm run dev:docker  →  scripts/dev.sh
│       │
│       └─ docker-compose.dev.yml
│               ├─ neon-local  (Neon DB proxy container)
│               └─ app         (Node 20 dev container, hot-reload via --watch)
│
└─ npm run prod:docker  →  scripts/prod.sh
        │
        └─ docker-compose.prod.yml
                └─ app  (Node 20 prod container, no devDeps, resource-capped)


GitHub Push / PR
│
├─ .github/workflows/lint-and-format.yml   → ESLint + Prettier
├─ .github/workflows/tests.yml             → Jest (Node env, coverage upload)
└─ .github/workflows/docker-build-and-push.yml
        └─ BuildKit multi-platform image → Docker Hub
                (linux/amd64 + linux/arm64)
```

---

## 2. Dockerfile — Multi-Stage Build

**File:** [`Dockerfile`](file:///d:/WebD%20Projects/Projects/acquisitions/Dockerfile)

The Dockerfile uses **two named stages** that share a common `base` layer.

```
base  ──────────────────────────────────────────────────────────
│  FROM node:20-alpine
│  WORKDIR /app
│  COPY package*.json ./
│  RUN npm ci --omit=dev          ← prod deps only (fast, reproducible)
│  COPY . .                       ← full source (after lockfile install)
│  RUN addgroup/adduser nodejs    ← non-root user (security hardening)
│  USER nodejs
│  EXPOSE 3000
│  HEALTHCHECK (HTTP GET /health every 30s)
│
├── development  (FROM base AS development)
│       USER root
│       RUN npm ci                ← re-runs to ADD devDependencies (nodemon, jest…)
│       USER nodejs
│       CMD ["npm", "run", "dev"] ← node --watch src/index.js
│
└── production   (FROM base AS production)
        CMD ["npm", "start"]      ← node src/index.js (base already has prod deps)
```

### Why this shape?

| Concern | Choice | Reason |
|---|---|---|
| Base image | `node:20-alpine` | Minimal attack surface, small image (~60 MB) |
| Dep install order | `package*.json` → `npm ci` → `COPY .` | Docker layer cache: only re-runs `npm ci` when lockfile changes |
| `--omit=dev` in base | Yes | Production image never bundles test/lint/drizzle-kit tools |
| devDeps in dev stage | `USER root` → `npm ci` (no `--omit`) | Adds back devDependencies on top of base; user drops back to `nodejs` |
| Non-root user | `nodejs` (uid 1001) | Limits container privilege even if exploited |
| Healthcheck | Inline Node HTTP call | No extra `curl`/`wget` binary required; works on Alpine |

---

## 3. .dockerignore — What Never Enters the Image

**File:** [`.dockerignore`](file:///d:/WebD%20Projects/Projects/acquisitions/.dockerignore)

Key exclusions and why they matter:

| Excluded | Why |
|---|---|
| `node_modules/` | Rebuilt inside container via `npm ci`; host modules have native binaries for the wrong OS |
| `.env`, `.env.*` | Secrets injected via `env_file` in Compose at runtime — never baked into image layers |
| `tests/`, `*.test.js` | Tests are not needed at runtime; shrinks production image |
| `.git/`, `*.md`, `docs/` | Metadata only; reduces build context sent to Docker daemon |
| `coverage/`, `dist/`, `build/` | Ephemeral build/test artifacts |
| `.neon_local/` | Local Neon branch state, dev-only |
| `Dockerfile*`, `docker-compose*.yml` | No reason to ship Docker configs inside the image itself |
| `logs/`, `*.log` | Mounted as a volume in prod; not baked in |

> [!TIP]
> A lean `.dockerignore` directly speeds up `docker build` because Docker sends less **build context** to the daemon before it even starts reading the Dockerfile.

---

## 4. docker-compose.dev.yml — Development Stack

**File:** [`docker-compose.dev.yml`](file:///d:/WebD%20Projects/Projects/acquisitions/docker-compose.dev.yml)

```yaml
services:
  neon-local:   # Neon DB local proxy
  app:          # Node.js dev server (hot-reload)

networks:
  acquisition-network: { driver: bridge }
```

### `neon-local` service

```yaml
image: neondatabase/neon_local:latest
ports: ['5432:5432']
env_file: .env.development          # Neon credentials
volumes:
  - ./.neon_local/:/tmp/.neon_local # Persists branch state across restarts
  - ./.git/HEAD:/tmp/.git/HEAD:ro   # Lets Neon create per-git-branch DB branches
healthcheck:
  test: [CMD, pg_isready, ...]      # Checked by app's depends_on
  interval: 10s / timeout: 5s / retries: 5 / start_period: 30s
```

**What it does:** Neon Local is a proxy that talks to Neon Cloud. It creates an **ephemeral database branch** tied to the current git branch, so each feature branch gets a clean database fork. The `.git/HEAD` volume mount is read-only so the proxy knows the current branch name.

### `app` service

```yaml
build:
  context: .
  dockerfile: Dockerfile
  target: development          # ← picks the "development" stage

ports: ['3000:3000']
env_file: .env.development
volumes:
  - ./src:/app/src:ro          # ← HOST src mounted into container (hot-reload)
  - ./package.json:/app/package.json:ro
  - /app/node_modules          # ← anonymous volume (keeps container's node_modules)

depends_on:
  neon-local:
    condition: service_healthy  # app only starts once DB is ready

restart: unless-stopped
stdin_open: true / tty: true   # Interactive terminal in dev
```

#### Volume trick — the "anonymous volume" pattern

```
./src  ──────────────────────►  /app/src      (host files, writable by watcher)
/app/node_modules  ◄────────   (container's own node_modules — host doesn't override this)
```

Without the anonymous volume `/app/node_modules`, the host mount of the project root would shadow the container's `node_modules`, losing the Alpine-native binaries (like `bcrypt`). The anonymous volume "wins" over any host bind-mount for that path.

---

## 5. docker-compose.prod.yml — Production Stack

**File:** [`docker-compose.prod.yml`](file:///d:/WebD%20Projects/Projects/acquisitions/docker-compose.prod.yml)

```yaml
services:
  app:
    build:
      target: production        # ← base stage + npm start

    ports:
      - '127.0.0.1:${PORT:-3000}:3000'  # loopback only — behind nginx/reverse proxy

    env_file: .env.production   # Neon Cloud DATABASE_URL (no local proxy)

    volumes:
      - ./logs:/app/logs        # Persist Winston logs on host

    deploy:
      resources:
        limits:   { memory: 512M, cpus: '0.5' }
        reservations: { memory: 256M, cpus: '0.25' }

    restart: unless-stopped
```

### Dev vs. Prod Compose comparison

| Feature | Dev | Prod |
|---|---|---|
| Dockerfile target | `development` | `production` |
| devDependencies | ✅ installed | ❌ omitted |
| Hot-reload (`--watch`) | ✅ | ❌ |
| Database | `neon-local` container proxy | Neon Cloud direct URL |
| Source volume mount | `./src:/app/src:ro` | ❌ (baked in image) |
| Port binding | `0.0.0.0:3000` | `127.0.0.1:${PORT}` (loopback) |
| Resource limits | ❌ | ✅ (memory + CPU caps) |
| Log volume | ❌ | ✅ (`./logs:/app/logs`) |
| `neon-local` service | ✅ | ❌ |

---

## 6. dev.sh — Development Startup Script

**File:** [`scripts/dev.sh`](file:///d:/WebD%20Projects/Projects/acquisitions/scripts/dev.sh)

This script is the **orchestrator** for the dev environment. It does more than `docker compose up`.

```
scripts/dev.sh
│
├─ 1. Guard checks
│       ├─ .env.development exists?  → exit 1 if not
│       └─ docker info succeeds?     → exit 1 if Docker not running
│
├─ 2. Prepare filesystem
│       ├─ mkdir -p .neon_local
│       └─ append ".neon_local/" to .gitignore (idempotent)
│
├─ 3. Start neon-local only (detached)
│       docker compose -f docker-compose.dev.yml up -d neon-local
│
├─ 4. Wait for DB to be ready
│       docker compose exec neon-local sh -c 'until pg_isready ...; do sleep 2; done'
│
├─ 5. Run Drizzle migrations
│       docker compose exec -e DATABASE_URL="postgres://neon:npg@localhost:5432/neondb" \
│         neon-local sh -c 'cd /app && npm run db:migrate'
│       # Falls back to: npm run db:migrate  (host)
│
└─ 6. Start all remaining services (with build, foreground)
        docker compose -f docker-compose.dev.yml up --build
```

### Why run migrations from inside the neon-local container?

The Neon Local proxy listens on `localhost:5432` **inside** the `neon-local` container. From the host, `localhost:5432` is port-forwarded, but `drizzle-kit` is a devDependency not available in the prod image — so migrations are run either from within the proxy container or directly on the host as a fallback (the `||` in the script).

> [!IMPORTANT]
> The script uses `set -e` — any command failure aborts the entire script immediately. This prevents a partially started environment.

---

## 7. prod.sh — Production Startup Script

**File:** [`scripts/prod.sh`](file:///d:/WebD%20Projects/Projects/acquisitions/scripts/prod.sh)

```
scripts/prod.sh
│
├─ 1. Guard checks
│       ├─ .env.production exists?
│       └─ docker info succeeds?
│
├─ 2. Build + start production container (detached)
│       docker compose -f docker-compose.prod.yml up --build -d
│
└─ 3. Run Drizzle migrations on HOST
        export $(grep -v '^#' .env.production | xargs)
        npx drizzle-kit migrate
        # drizzle-kit is a devDep → not in prod image → must run on host
```

> [!NOTE]
> In production the database is **Neon Cloud** (remote). There is no local proxy container. The `DATABASE_URL` in `.env.production` points directly to Neon's cloud endpoint. Migrations run from the host because `drizzle-kit` is excluded from the production image (`--omit=dev`).

---

## 8. npm Scripts — The Entry Points

**File:** [`package.json`](file:///d:/WebD%20Projects/Projects/acquisitions/package.json)

```jsonc
{
  "scripts": {
    "dev":          "node --watch src/index.js",   // bare Node, no Docker
    "start":        "node src/index.js",            // production entrypoint

    "dev:docker":   "sh ./scripts/dev.sh",          // full Docker dev stack
    "prod:docker":  "sh ./scripts/prod.sh",         // full Docker prod stack

    "lint":         "eslint .",
    "lint:fix":     "eslint . --fix",
    "format":       "prettier --write .",
    "format:check": "prettier --check .",

    "db:generate":  "drizzle-kit generate",
    "db:migrate":   "drizzle-kit migrate",
    "db:studio":    "drizzle-kit studio",

    "test":         "cross-env NODE_OPTIONS=--experimental-vm-modules jest"
  }
}
```

| Script | When used |
|---|---|
| `npm run dev` | Local dev without Docker |
| `npm run dev:docker` | Full Docker dev env (recommended) |
| `npm run prod:docker` | Deploy to EC2 / local prod test |
| `npm test` | Local test run; also called in CI |
| `npm run lint` / `format:check` | Pre-commit or CI gate |

---

## 9. GitHub Actions Workflows

All three workflows live in [`.github/workflows/`](file:///d:/WebD%20Projects/Projects/acquisitions/.github/workflows).

---

### Lint & Format Check (`lint-and-format.yml`)

**File:** [`.github/workflows/lint-and-format.yml`](file:///d:/WebD%20Projects/Projects/acquisitions/.github/workflows/lint-and-format.yml)

**Triggers:** push or PR to `main` or `staging`

```
Checkout → Setup Node 20 (npm cache) → npm ci
  │
  ├─ npm run lint        (ESLint)
  │     fail → error annotation + hint to run lint:fix
  │
  └─ npm run format:check  (Prettier)
        fail → error annotation + hint to run format
```

No secrets needed. Pure static analysis. Fastest of the three pipelines.

---

### Tests (`tests.yml`)

**File:** [`.github/workflows/tests.yml`](file:///d:/WebD%20Projects/Projects/acquisitions/.github/workflows/tests.yml)

**Triggers:** push or PR to `main` or `staging`

```
Checkout → Setup Node 20 (npm cache) → npm ci
  │
  └─ npm test
        env:
          NODE_ENV: test
          NODE_OPTIONS: --experimental-vm-modules   ← ESM support in Jest
          DATABASE_URL: ${{ secrets.TEST_DATABASE_URL }}
          JWT_SECRET: test-secret-for-ci
          LOG_LEVEL: error
        │
        ├─ SUCCESS → Upload coverage/ + test-results.xml (30-day artifact)
        └─ FAILURE → Annotate with error + next-steps hint
```

> [!NOTE]
> `NODE_OPTIONS=--experimental-vm-modules` is required because the project uses `"type": "module"` (ESM). Jest's VM isolation needs this flag to handle native ES modules correctly. This matches the local `npm test` script which uses `cross-env` for cross-platform compat.

---

### Docker Build & Push (`docker-build-and-push.yml`)

**File:** [`.github/workflows/docker-build-and-push.yml`](file:///d:/WebD%20Projects/Projects/acquisitions/.github/workflows/docker-build-and-push.yml)

**Triggers:** push to `main` only + manual `workflow_dispatch`

```
Checkout
  │
  ├─ docker/setup-buildx-action@v3
  │     driver: docker-container
  │     platforms: linux/amd64, linux/arm64   ← multi-arch (EC2 x86 + Apple M-series)
  │
  ├─ docker/login-action@v3
  │     registry: docker.io
  │     username/password: secrets.DOCKER_USERNAME / DOCKER_PASSWORD
  │
  ├─ docker/metadata-action@v5  → generate tags:
  │     • branch name  (e.g. main)
  │     • SHA prefix   (e.g. main-a1b2c3d)
  │     • latest       (only for default branch)
  │     • prod-YYYYMMDD-HHmmss  (timestamped prod tag)
  │     • custom suffix (workflow_dispatch input)
  │
  └─ docker/build-push-action@v5
        context: .
        platforms: linux/amd64,linux/arm64
        push: true
        cache-from/to: type=gha     ← GitHub Actions cache (fast rebuilds)
        build-args:
          NODE_ENV=production
          BUILD_DATE, GIT_SHA, GIT_REF
```

#### Image Tags Published

```
docker.io/<DOCKER_USERNAME>/acquisitions:main
docker.io/<DOCKER_USERNAME>/acquisitions:main-a1b2c3d
docker.io/<DOCKER_USERNAME>/acquisitions:latest
docker.io/<DOCKER_USERNAME>/acquisitions:prod-20261031-124850
```

> [!IMPORTANT]
> This workflow does **not** depend on the Tests or Lint workflows. On a mature project you'd add `needs: [test, lint]` to enforce quality gates before publishing an image. Currently it only triggers on `main` — that branch should be protected to require passing checks before merge.

---

## 10. Jest Testing Setup

**Files:** [`jest.config.mjs`](file:///d:/WebD%20Projects/Projects/acquisitions/jest.config.mjs), [`tests/app.test.js`](file:///d:/WebD%20Projects/Projects/acquisitions/tests/app.test.js)

### Configuration highlights

```js
// jest.config.mjs
export default {
  clearMocks: true,           // Reset mocks between tests
  collectCoverage: true,      // Always collect coverage
  coverageDirectory: 'coverage',
  coverageProvider: 'v8',     // Fast native V8 coverage (no instrumentation)
  testEnvironment: 'node',    // No jsdom — pure Node.js API
};
```

### How tests run

```
npm test
  = cross-env NODE_OPTIONS=--experimental-vm-modules jest

Jest discovers tests/app.test.js
  │
  └─ supertest wraps app (no live server port needed)
        │
        ├─ GET /health        → expect 200 + { status: 'OK', timestamp, uptime }
        ├─ GET /api           → expect 200 + { message: 'Acquisitions API is running!' }
        └─ GET /nonexsistent  → expect 404 + { error: 'Route not found' }
```

`supertest` makes in-process HTTP requests against the Express `app` instance directly — **no server needs to listen** on a real port, and **no database connection** is needed for these smoke tests (they hit routes that don't query the DB).

### Coverage output

```
coverage/
├── lcov-report/      ← HTML report (open index.html in browser)
└── clover.xml        ← Machine-readable (consumed by CI artifact upload)
```

---

## 11. Environment Files

| File | Used by | Purpose |
|---|---|---|
| `.env.development` | `dev.sh`, `docker-compose.dev.yml` | Neon Local credentials, dev JWT secret |
| `.env.production` | `prod.sh`, `docker-compose.prod.yml` | Neon Cloud URL, prod secrets |
| `.env.example` | Developers onboarding | Template — copy to `.env.development` |
| `.env.production.example` | Ops | Template — copy to `.env.production` |
| `.env` | Local bare `npm run dev` | Not committed, not used in Docker |

> [!CAUTION]
> All `.env.*` files are listed in both `.gitignore` and `.dockerignore`. They are **never** committed or baked into images. Secrets reach containers only through the `env_file:` directive in Compose (dev) or through CI secrets / AWS Secrets Manager (prod).

---

## 12. Complete Dev Flow — Step by Step

```
Developer types: npm run dev:docker
                      │
              scripts/dev.sh starts
                      │
         ┌────────────▼────────────┐
         │  Guard checks           │
         │  • .env.development?    │
         │  • Docker running?      │
         └────────────┬────────────┘
                      │
         ┌────────────▼────────────────────────────────┐
         │  docker compose up -d neon-local             │
         │                                              │
         │  Pulls neondatabase/neon_local:latest        │
         │  Mounts .neon_local/ + .git/HEAD             │
         │  Creates ephemeral Neon branch for git HEAD  │
         │  PostgreSQL proxy on 0.0.0.0:5432            │
         └────────────┬────────────────────────────────┘
                      │  (waits until pg_isready passes)
         ┌────────────▼─────────────────┐
         │  Drizzle migrate             │
         │  (inside neon-local OR host) │
         └────────────┬─────────────────┘
                      │
         ┌────────────▼──────────────────────────────────────┐
         │  docker compose up --build  (all services)        │
         │                                                    │
         │  Builds Dockerfile target=development              │
         │    base:  npm ci --omit=dev, copy source           │
         │    dev:   npm ci (adds devDeps)                    │
         │                                                    │
         │  Mounts ./src → /app/src                          │
         │  Runs: node --watch src/index.js                   │
         │  Hot-reload: file change → Node restarts server   │
         │                                                    │
         │  App healthcheck: GET /health every 30s            │
         └───────────────────────────────────────────────────┘

App available at http://localhost:3000
DB available at  postgres://neon:npg@localhost:5432/neondb
```

---

## 13. Complete Prod Flow — Step by Step

```
Server/EC2: npm run prod:docker
                 │
          scripts/prod.sh starts
                 │
    ┌────────────▼───────────────┐
    │  Guard checks              │
    │  • .env.production?        │
    │  • Docker running?         │
    └────────────┬───────────────┘
                 │
    ┌────────────▼───────────────────────────────────────┐
    │  docker compose -f docker-compose.prod.yml         │
    │           up --build -d                            │
    │                                                    │
    │  Builds Dockerfile target=production               │
    │    base: npm ci --omit=dev                        │
    │    (no devDeps, no test files via .dockerignore)  │
    │    Runs as non-root user nodejs                    │
    │                                                    │
    │  Port: 127.0.0.1:3000 (loopback only)             │
    │  Logs: ./logs/  (host volume)                      │
    │  Resources: 512MB RAM / 0.5 CPU capped             │
    │  restart: unless-stopped                           │
    └────────────┬───────────────────────────────────────┘
                 │
    ┌────────────▼──────────────────────┐
    │  Drizzle migrate on HOST          │
    │  (drizzle-kit not in prod image)  │
    │  npx drizzle-kit migrate          │
    └───────────────────────────────────┘

App: http://localhost:3000 (behind nginx/reverse proxy)
DB:  Neon Cloud (remote, via DATABASE_URL in .env.production)
```

---

## 14. CI/CD Pipeline — End to End

```
git push → main / PR to main|staging
           │
           ├──────────────────────────────────────┐
           │                                      │
    lint-and-format.yml                      tests.yml
    (ubuntu-latest)                          (ubuntu-latest)
           │                                      │
    npm ci                                  npm ci
    eslint .                                NODE_ENV=test
    prettier --check .                      NODE_OPTIONS=--experimental-vm-modules
           │                                jest
           │                                      │
    ✅ pass / ❌ annotate               ✅ pass → upload coverage artifact
                                        ❌ annotate + next-steps


git push → main only
           │
    docker-build-and-push.yml
    (ubuntu-latest)
           │
    docker/setup-buildx-action   ← Docker BuildKit, multi-arch
    docker/login-action          ← Docker Hub auth (secrets)
    docker/metadata-action       ← generate tags (main, sha, latest, prod-ts)
    docker/build-push-action
           │
           ├─ Build context sent to BuildKit daemon
           ├─ Layer cache: type=gha (GitHub Actions cache)
           ├─ Platforms: linux/amd64 + linux/arm64
           └─ Push to docker.io/<user>/acquisitions
                    :latest
                    :main
                    :main-<sha>
                    :prod-YYYYMMDD-HHmmss
```

---

## 15. Key Design Decisions

### Multi-stage Dockerfile over separate Dockerfiles

A single Dockerfile with `base → development | production` stages keeps the builds DRY. Both environments share the same base layer — same Alpine version, same source copy, same non-root user setup. Only the final CMD and installed packages differ.

### Neon Local vs. a Plain Postgres Container

Instead of `postgres:16` as the dev database, the project uses `neondatabase/neon_local`. This proxy creates **branch-per-git-branch** databases, so:
- Each feature branch has isolated DB state
- No manual `DROP TABLE` / `pg_restore` between branches
- Schema matches production (Neon Cloud) exactly

### `--omit=dev` in base, re-install in dev stage

```dockerfile
# base: lean production deps
RUN npm ci --omit=dev

# development: add devDeps on top
FROM base AS development
USER root
RUN npm ci        # installs ALL deps including devDependencies
USER nodejs
```

This avoids duplicating the `npm ci` RUN in a completely separate stage and takes advantage of Docker's layer cache — the prod-only install is cached independently from the dev install.

### Source volume mount for hot-reload

```yaml
volumes:
  - ./src:/app/src:ro         # host → container
  - /app/node_modules          # container-only (not shadowed)
```

`node --watch` inside the container sees host file changes instantly because `./src` is bind-mounted. The anonymous volume for `node_modules` prevents the host directory from overwriting the container's Alpine-compiled native modules.

### Loopback-only port in production

```yaml
ports:
  - '127.0.0.1:${PORT:-3000}:3000'
```

Binding to `127.0.0.1` instead of `0.0.0.0` means the Node process is **not directly reachable** from the internet — it must go through the host's reverse proxy (nginx / Caddy). This is a defence-in-depth measure on EC2.

### ESM + Jest (`--experimental-vm-modules`)

The project is `"type": "module"` (native ESM). Jest's default CommonJS transform doesn't handle `import`/`export` in `.js` files. The `NODE_OPTIONS=--experimental-vm-modules` flag enables Jest's experimental ESM support, which the CI and local test scripts both set consistently.

### Coverage always collected

`collectCoverage: true` in `jest.config.mjs` means every `npm test` run produces coverage data — locally and in CI. The CI artifact upload preserves reports for 30 days, enabling trend analysis without a separate coverage service.
