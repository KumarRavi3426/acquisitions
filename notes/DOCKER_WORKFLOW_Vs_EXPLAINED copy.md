# Docker, Compose, Scripts, Workflows, and Testing

This document describes the Docker workflow currently implemented by the
Acquisitions API. It explains how the [`Dockerfile`](../Dockerfile),
Docker Compose files, [`scripts/dev.sh`](../scripts/dev.sh),
[`scripts/prod.sh`](../scripts/prod.sh), automated tests, and GitHub Actions fit
together.

## 1. Workflow at a glance

There are three related, but separate, execution paths:

1. **Local development** uses `dev.sh` and `docker-compose.dev.yml`.
   Compose runs the API and a Neon Local database proxy.
2. **Production-style execution** uses `prod.sh` and
   `docker-compose.prod.yml`. Compose runs only the API; the API connects to
   Neon Cloud.
3. **Continuous integration and publishing** uses the GitHub Actions files.
   Linting, formatting, and Jest tests run directly on an Ubuntu runner.
   The Docker workflow separately builds and publishes a multi-architecture
   image when `main` receives a push or when manually dispatched.

The workflows are related by the source repository and the shared
`package.json`, but GitHub Actions does not currently declare dependencies
between the lint, test, and Docker jobs. The Docker publish workflow is not
configured with `needs:` on the lint or test workflows.

```text
Developer
  |
  +-- npm run dev:docker --> scripts/dev.sh
  |                           |
  |                           +--> docker-compose.dev.yml
  |                                  +--> neon-local
  |                                  +--> app (Dockerfile: development)
  |
  +-- npm run prod:docker --> scripts/prod.sh
                              |
                              +--> docker-compose.prod.yml
                                     +--> app (Dockerfile: production)

GitHub push / pull request
  +--> lint-and-format.yml  (npm ci, ESLint, Prettier)
  +--> tests.yml            (npm ci, Jest, coverage artifact)

Push to main / manual dispatch
  +--> docker-build-and-push.yml
         +--> Buildx: linux/amd64 and linux/arm64
         +--> Docker Hub
```

## 2. The Dockerfile
[`Dockerfile`](../Dockerfile) is a multi-stage Dockerfile based on
`node:20-alpine`.

### 2.1 `base` stage

The `base` stage:

1. Sets `/app` as the working directory.
2. Copies `package.json` and `package-lock.json`.
3. Runs `npm ci --omit=dev`, installing only runtime dependencies.
4. Copies the application source into the image.
5. Creates the non-root `nodejs` user and group with UID/GID `1001`.
6. Gives that user ownership of `/app` and switches to it.
7. Documents port `3000`.
8. Defines a Docker health check against `GET /health`.

Copying the package manifests before the source creates a useful Docker cache
boundary: source-only changes can reuse the dependency-install layer. The
`--omit=dev` install keeps the base suitable for production.

The health check uses Node's built-in HTTP client, so the image does not need
`curl`. A container is healthy only when the application returns HTTP 200 from
`/health`. That endpoint is implemented in [`src/app.js`](../src/app.js).

### 2.2 `development` stage

The `development` stage inherits from `base`, temporarily switches to root,
and runs a second `npm ci` without `--omit=dev`. This adds development
dependencies such as Jest, ESLint, Prettier, and Drizzle Kit. It then switches
back to the non-root user and runs:

```text
npm run dev
```

`npm run dev` is `node --watch src/index.js`, so the process restarts when
mounted source files change.

### 2.3 `production` stage

The `production` stage inherits the runtime-only `base` installation and runs:

```text
npm start
```

`npm start` is `node src/index.js`. The production image does not contain
development dependencies, which is why the production script runs Drizzle
migrations from the deployment host rather than from the application
container.

## 3. Development: Compose and `dev.sh` together

### 3.1 Compose services

[`docker-compose.dev.yml`](../docker-compose.dev.yml) defines two services on the
`acquisition-network` bridge network.

#### `neon-local`

- Uses `neondatabase/neon_local:latest`.
- Publishes container port `5432` to host port `5432`.
- Reads Neon Local settings from `.env.development`.
- Mounts `.neon_local` for local Neon state.
- Mounts `.git/HEAD` read-only so branch-aware local state can be associated
  with the checked-out Git branch.
- Runs `pg_isready` as its health check.

Within the Compose network, other containers reach this service by the DNS
name `neon-local`, not by `localhost`.

#### `app`

- Builds [`Dockerfile`](../Dockerfile) with `target: development`.
- Publishes container port `3000` as host port `3000`.
- Reads application settings from `.env.development`.
- Mounts `./src` read-only at `/app/src` for hot reload.
- Mounts `package.json` read-only.
- Uses an anonymous `/app/node_modules` volume so host dependencies do not
  overwrite Linux dependencies installed in the container.
- Waits for `neon-local` to become healthy through `depends_on`.
- Restarts unless explicitly stopped.

The Compose-level app health check also calls `/health`. The Dockerfile and
Compose health checks serve the same purpose, with Compose supplying the
development-specific timing and command.

### 3.2 Startup sequence in `dev.sh`

[`scripts/dev.sh`](../scripts/dev.sh) is an orchestration wrapper around Compose:

1. Resolves the repository root and changes into it, so the script works when
   invoked from another directory.
2. Requires `.env.development`.
3. Verifies that the Docker daemon responds to `docker info`.
4. Creates `.neon_local` and adds it to `.gitignore` when needed.
5. Starts only `neon-local` in detached mode.
6. Waits until `pg_isready` succeeds.
7. Attempts to apply Drizzle migrations using the local database URL. If the
   container-side migration command fails, it falls back to
   `npm run db:migrate` on the host.
8. Runs `docker compose ... up --build` for the full development stack. This
   builds the development target if needed and attaches to the logs.

The readiness wait is important: `depends_on` controls service startup order,
but the explicit wait ensures the database proxy is accepting connections
before migration work begins.

Start development with:

```bash
npm run dev:docker
# equivalent to: sh ./scripts/dev.sh
```

The API is available at `http://localhost:3000` and the local database proxy
at `localhost:5432`. Stop it with `Ctrl+C`, or from another terminal:

```bash
docker compose -f docker-compose.dev.yml down
```

### 3.3 Development database connection

When `NODE_ENV=development`, [`src/config/database.js`](../src/config/database.js)
configures the Neon client to use the Compose hostname `neon-local` and its
HTTP SQL endpoint. The application's `DATABASE_URL` still comes from the
environment file. This is different from the host, where `localhost:5432`
refers to the published port.

## 4. Production: Compose and `prod.sh` together

### 4.1 Production Compose behavior
[`docker-compose.prod.yml`](../docker-compose.prod.yml) defines one `app`
service:

- Builds the `production` target from [`Dockerfile`](../Dockerfile).
- Reads `.env.production`.
- Binds `${PORT:-3000}:3000` to `127.0.0.1`, not all host interfaces.
- Mounts `./logs` to `/app/logs`, preserving Winston log files across
  container recreation.
- Applies Compose resource limits of 512 MB memory and 0.5 CPU, with lower
  reservations.
- Restarts unless stopped.
- Checks `/health` every 30 seconds after a 40-second startup period.

The loopback binding means an external reverse proxy, such as Nginx or Caddy,
can terminate HTTPS and forward traffic to `127.0.0.1:3000` without exposing
the Node process directly to the Internet. This is also the binding described
by [`EC2_DEPLOYMENT.md`](../EC2_DEPLOYMENT.md).

There is no Neon Local service in production. The application uses the
production `DATABASE_URL` to connect directly to Neon Cloud, normally with
SSL enabled.

### 4.2 Startup sequence in `prod.sh`

[`scripts/prod.sh`](../scripts/prod.sh):

1. Resolves the repository root.
2. Requires `.env.production`.
3. Verifies that Docker is running.
4. Runs `docker compose -f docker-compose.prod.yml up --build -d`.
5. Exports values from `.env.production` into the host shell.
6. Runs `npx drizzle-kit migrate` on the host.
7. Prints the application URL and operational log commands.

The host-side migration is intentional: the production image installs runtime
dependencies only, so `drizzle-kit` is not present inside that image. The
deployment host must therefore have the project dependencies installed (or
otherwise provide `drizzle-kit`) and must have access to the production
database URL.

Start production with:

```bash
npm run prod:docker
# equivalent to: sh ./scripts/prod.sh
```

Useful checks:

```bash
docker compose -f docker-compose.prod.yml ps
curl http://127.0.0.1:3000/health
docker logs -f acquisitions-app-prod
```

### 4.3 `dockerForProd.yml`

[`dockerForProd.yml`](../dockerForProd.yml) is an alternate production Compose
definition. It uses a different network name and container name and includes
additional Swarm-style restart/resource settings and JSON log rotation.
Neither [`scripts/prod.sh`](../scripts/prod.sh) nor the EC2 instructions select
this file; they select `docker-compose.prod.yml`. Treat `dockerForProd.yml` as
an alternate/manual configuration unless the deployment process is explicitly
changed to use it.

## 5. Testing and quality checks

### 5.1 Local tests

The `test` script in [`package.json`](../package.json) runs Jest with:

```text
cross-env NODE_OPTIONS=--experimental-vm-modules jest
```

This enables the repository's ES module test setup. Jest collects V8 coverage
into `coverage/`. [`tests/app.test.js`](../tests/app.test.js) uses Supertest to
exercise the Express app without starting a separate HTTP server:

- `GET /health` returns status `200` and status metadata.
- `GET /api` returns the API message.
- An unknown route returns `404` and the expected error body.

Run locally with:

```bash
npm test
npm run lint
npm run format:check
```

### 5.2 Relationship between tests and container health

The tests and Docker health checks share the `/health` contract, but they are
not the same test:

- Jest imports the Express app and uses Supertest in-process.
- Docker starts the real Node process and probes port `3000` over HTTP.

Therefore, Jest validates application behavior while the container health
check validates that the running image can start and serve the health route.
The current test suite does not start Docker Compose or Neon Local.

### 5.3 CI workflows

#### `lint-and-format.yml`

[`lint-and-format.yml`](../.github/workflows/lint-and-format.yml) runs on pushes
and pull requests targeting `main` or `staging`. It uses Node 20, restores the
npm cache, runs `npm ci`, then runs:

```text
npm run lint
npm run format:check
```

#### `tests.yml`

[`tests.yml`](../.github/workflows/tests.yml) runs on pushes and pull requests
targeting `main` or `staging`. It uses Node 20, runs `npm ci`, and runs
`npm test` with `NODE_ENV=test`, a CI JWT secret, and a test database URL.
Coverage and any `test-results.xml` file are uploaded as artifacts for 30
days. The workflow also writes a result summary to the GitHub Actions job
summary.

This CI job runs directly on the GitHub runner. It does not build the
Dockerfile or start `docker-compose.dev.yml`.

## 6. Docker image publishing workflow

[`docker-build-and-push.yml`](../.github/workflows/docker-build-and-push.yml)
triggers on pushes to `main` and on manual `workflow_dispatch`.

Its sequence is:

1. Check out the repository.
2. Configure Docker Buildx.
3. Log in to Docker Hub using `DOCKER_USERNAME` and `DOCKER_PASSWORD` secrets.
4. Generate image tags and OCI labels.
5. Build and push the image for `linux/amd64` and `linux/arm64`.
6. Reuse GitHub Actions layer cache with `cache-from: type=gha` and
   `cache-to: type=gha,mode=max`.
7. Write a build summary containing the image, tags, platforms, commit, and
   ref.

The workflow passes production-related build arguments, but the current
Dockerfile does not consume those arguments. The runtime environment is still
provided by `.env.production` or the deployment platform, not baked into the
image.

Tags include branch/SHA-derived tags, `latest` for the default branch, a
timestamped production tag, and an optional manual suffix. The resulting
image can be pulled by an EC2 deployment that has been configured with the
corresponding Docker Hub repository and tag.

## 7. End-to-end lifecycle

### Local development

```text
Edit source
  -> npm run dev:docker
  -> dev.sh validates environment and Docker
  -> Compose starts Neon Local
  -> dev.sh waits for pg_isready
  -> Drizzle migrations run
  -> Compose builds/starts the development app
  -> ./src is mounted and node --watch reloads changes
  -> /health is continuously available for container health checks
```

### Pull request validation

```text
Open PR or push to main/staging
  -> lint-and-format.yml checks ESLint and Prettier
  -> tests.yml runs Jest and uploads coverage
```

### Main branch image publication

```text
Push to main
  -> docker-build-and-push.yml
  -> Buildx builds both supported Linux architectures
  -> image is pushed to Docker Hub with generated tags
  -> EC2 or another host can pull the selected tag
  -> prod.sh starts the production Compose app and applies migrations
```

The Docker publish workflow currently runs independently of the test and lint
workflow results. If publication must be blocked by failed checks, the
repository would need a single workflow with job dependencies or an explicit
status-check gate.

## 8. Quick command reference

```bash
# Development
npm run dev:docker
docker compose -f docker-compose.dev.yml ps
docker logs -f acquisition-app-dev
docker compose -f docker-compose.dev.yml down

# Local quality checks
npm test
npm run lint
npm run format:check

# Production
npm run prod:docker
docker compose -f docker-compose.prod.yml ps
docker logs -f acquisitions-app-prod
docker compose -f docker-compose.prod.yml down

# Inspect resolved Compose configuration
docker compose -f docker-compose.dev.yml config
docker compose -f docker-compose.prod.yml config
```

Do not commit `.env.development` or `.env.production`. Supply real
credentials only through local secret files, deployment-host configuration, or
GitHub/Docker registry secrets.
