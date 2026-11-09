# Acquisitions API — Full Architecture Reference

> **Interview-ready deep-dive** into every layer of the system: design decisions, data flow, security model, and the "why" behind each choice. Docker/CI-CD details are covered in [`DOCKER_WORKFLOW_EXPLAINED.md`](./DOCKER_WORKFLOW_EXPLAINED.md).

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Tech Stack & Why Each Was Chosen](#2-tech-stack--why-each-was-chosen)
3. [Folder Structure & Module Aliases](#3-folder-structure--module-aliases)
4. [Application Entrypoint & Bootstrap Flow](#4-application-entrypoint--bootstrap-flow)
5. [Layered Architecture (Request Lifecycle)](#5-layered-architecture-request-lifecycle)
6. [Middleware Pipeline (In Order)](#6-middleware-pipeline-in-order)
7. [Security Layer — Arcjet](#7-security-layer--arcjet)
8. [Authentication & Authorization System](#8-authentication--authorization-system)
9. [Database Layer — Drizzle ORM + Neon Postgres](#9-database-layer--drizzle-orm--neon-postgres)
10. [Data Model](#10-data-model)
11. [API Routes Reference](#11-api-routes-reference)
12. [Validation Layer — Zod](#12-validation-layer--zod)
13. [Service Layer — Business Logic](#13-service-layer--business-logic)
14. [Utility Modules](#14-utility-modules)
15. [Logging — Winston](#15-logging--winston)
16. [Error Handling Strategy](#16-error-handling-strategy)
17. [RBAC — Role-Based Access Control](#17-rbac--role-based-access-control)
18. [Environment & Configuration](#18-environment--configuration)
19. [Testing Strategy](#19-testing-strategy)
20. [End-to-End Request Walkthrough](#20-end-to-end-request-walkthrough)
21. [Common Interview Q&A](#21-common-interview-qa)

---

## 1. Project Overview

**Acquisitions** is a production-grade **RESTful API** built with **Node.js + Express 5**, serving as a user management backend. It handles:

- User registration and authentication (JWT-based, cookie-delivered)
- Role-based access control (admin vs. user)
- Secure CRUD operations on user records
- Multi-layer security via Arcjet (bot detection, WAF shield, rate limiting)
- Serverless Postgres via Neon, accessed through Drizzle ORM

It is a **pure backend API** — no frontend, no template rendering. All responses are JSON.

---

## 2. Tech Stack & Why Each Was Chosen

| Concern | Technology | Why |
|---|---|---|
| Runtime | **Node.js 20** | LTS, native ESM, `--watch` for dev hot-reload |
| Framework | **Express 5** | Familiar, minimal, async error propagation built-in |
| Database | **Neon Postgres** | Serverless, scales to zero, branch-per-dev via Neon Local |
| ORM | **Drizzle ORM** | Type-safe SQL builder, schema-as-code, lightweight |
| Auth | **JWT + bcrypt** | Stateless auth; bcrypt (cost factor 10) for password hashing |
| Validation | **Zod 4** | Schema-first, TypeScript-compatible, works at runtime |
| Security | **Arcjet** | Cloud WAF + bot detection + rate-limiting in one SDK |
| Logging | **Winston** | Structured JSON logs, multiple transports, log-level control |
| HTTP logging | **Morgan** | Per-request combined logs piped into Winston |
| Cookie handling | **cookie-parser** | Parse `httpOnly` cookies from requests |
| Hardening | **Helmet** | Sets 14 security-related HTTP headers automatically |
| Testing | **Jest + Supertest** | Zero-config test runner; Supertest for HTTP integration tests |
| Module aliases | **package.json `imports`** | Cleaner `#config/` imports, no path traversal |
| Code quality | **ESLint + Prettier** | Enforced in CI before merge |

---

## 3. Folder Structure & Module Aliases

```
acquisitions/
├── src/
│   ├── index.js          ← process entry — just imports server.js
│   ├── server.js         ← binds Express app to PORT
│   ├── app.js            ← Express app config (middleware stack + routes)
│   ├── config/
│   │   ├── database.js   ← Drizzle + Neon client setup
│   │   ├── arcjet.js     ← Arcjet client + base rules
│   │   └── logger.js     ← Winston logger instance
│   ├── controllers/
│   │   ├── auth.controller.js    ← HTTP layer for auth endpoints
│   │   └── users.controller.js   ← HTTP layer for user CRUD
│   ├── middleware/
│   │   ├── auth.middleware.js     ← JWT cookie verification + requireRole
│   │   └── security.middleware.js ← Arcjet runtime enforcement
│   ├── models/
│   │   └── user.model.js  ← Drizzle schema definition (source of truth)
│   ├── routes/
│   │   ├── auth.routes.js   ← /api/auth route registration
│   │   └── users.routes.js  ← /api/users route registration + middleware wiring
│   ├── services/
│   │   ├── auth.service.js   ← createUser, authenticateUser, password ops
│   │   └── users.service.js  ← getAllUsers, getUserById, updateUser, deleteUser
│   ├── utils/
│   │   ├── jwt.js      ← jwttoken.sign / jwttoken.verify wrapper
│   │   ├── cookies.js  ← cookie set/clear/get with security defaults
│   │   └── format.js   ← formatValidationError helper
│   └── validations/
│       ├── auth.validation.js   ← signupSchema, signInSchema (Zod)
│       └── users.validation.js  ← userIdSchema, updateUserSchema (Zod)
├── drizzle/              ← auto-generated SQL migrations
├── tests/
│   └── app.test.js       ← Supertest integration tests
├── logs/
│   ├── combined.log      ← all log levels
│   └── error.lg          ← error level only
├── scripts/
│   ├── dev.sh            ← docker-compose dev startup
│   └── prod.sh           ← docker-compose prod startup
└── notes/
    └── DOCKER_WORKFLOW_EXPLAINED.md
```

### Module Aliases (Node.js `imports` field)

Defined in `package.json`, these map `#prefix/` to physical paths:

```json
"imports": {
  "#src/*":          "./src/*",
  "#config/*":       "./src/config/*",
  "#controllers/*":  "./src/controllers/*",
  "#middleware/*":   "./src/middleware/*",
  "#models/*":       "./src/models/*",
  "#routes/*":       "./src/routes/*",
  "#services/*":     "./src/services/*",
  "#utils/*":        "./src/utils/*",
  "#validations/*":  "./src/validations/*"
}
```

> **Why use these instead of relative paths?**  
> `import logger from '#config/logger.js'` works from any depth of the tree without fragile `../../..` traversal. This is a Node.js built-in feature — no Babel or bundler needed.

---

## 4. Application Entrypoint & Bootstrap Flow

```
node src/index.js
      │
      └─ imports src/app.js (Express app)
              │
              └─ app.listen(PORT) in src/server.js
```

The split is intentional:

| File | Responsibility |
|---|---|
| `index.js` | 2-line entry — just `import app` |
| `server.js` | Calls `app.listen(PORT)` — separates binding from app config |
| `app.js` | Full Express config — importable in tests *without* binding a port |

This pattern is essential for testing: `supertest` imports `app.js` directly and handles port binding internally.

---

## 5. Layered Architecture (Request Lifecycle)

```
HTTP Request
     │
     ▼
┌─────────────────────────────────────┐
│          Global Middleware           │  Helmet, CORS, JSON parser,
│         (applied to ALL routes)      │  cookie-parser, Morgan, Arcjet
└─────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────┐
│              Router                  │  /api/auth  or  /api/users
└─────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────┐
│         Route Middleware             │  authenticateToken, requireRole
│    (applied to specific routes)      │  (only on protected routes)
└─────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────┐
│            Controller                │  Validates input (Zod),
│       (HTTP boundary layer)          │  calls service, sends response
└─────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────┐
│             Service                  │  Business logic,
│        (business logic layer)        │  DB queries via Drizzle
└─────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────┐
│           Drizzle ORM                │  Type-safe SQL builder
└─────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────┐
│        Neon Postgres (cloud)         │  Serverless PostgreSQL
└─────────────────────────────────────┘
```

**Key principle:** Each layer has one job. Controllers don't touch the DB; services don't send HTTP responses.

---

## 6. Middleware Pipeline (In Order)

Middleware is registered in `app.js` in this exact order. Order matters.

```js
app.use(helmet());           // 1. Set security headers
app.use(cors());             // 2. Handle CORS preflight
app.use(express.json());     // 3. Parse JSON body
app.use(express.urlencoded({ extended: true })); // 4. Parse form data
app.use(cookieParser());     // 5. Parse cookies (needed for JWT cookie)
app.use(morgan('combined')); // 6. Log each request to Winston
app.use(securityMiddleware); // 7. Arcjet bot/shield/rate-limit check
```

### Why this order?

- **Helmet first** — headers sent as early as possible, before any error can skip them.
- **Body parsers before cookie-parser** — no dependency, but logical: parse request fully before inspecting it.
- **Morgan after parsers** — logs the fully-parsed request.
- **Arcjet last in globals** — has access to the full parsed request to make security decisions.

### Helmet
Sets headers like `X-Content-Type-Options`, `X-Frame-Options`, `Strict-Transport-Security`, `Content-Security-Policy` etc. — 14 headers by default with zero config.

### CORS
Default config allows all origins. In production this should be tightened to a whitelist.

---

## 7. Security Layer — Arcjet

**Files:** `src/config/arcjet.js` + `src/middleware/security.middleware.js`

Arcjet is a cloud-based application security layer. The project uses it for three distinct protections:

### Base Rules (in `arcjet.js`)

```js
arcjet({
  key: process.env.ARCJET_KEY,
  rules: [
    shield({ mode: 'LIVE' }),               // WAF — blocks SQLi, XSS, path traversal
    detectBot({ mode: 'LIVE',               // Bot detection
      allow: ['CATEGORY:SEARCH_ENGINE',     //   allow Googlebot etc.
               'CATEGORY:PREVIEW'] }),
    slidingWindow({ mode: 'LIVE',           // Global rate limit
      interval: '2s', max: 5 }),            //   5 req / 2s baseline
  ],
})
```

### Dynamic Per-Role Rate Limiting (in `security.middleware.js`)

The middleware dynamically adds a **per-role sliding window** on top of the base rules:

```
guest → 5  requests / 1 minute
user  → 10 requests / 1 minute
admin → 20 requests / 1 minute
```

The role is read from `req.user?.role` (populated by `authenticateToken` middleware, or `'guest'` if unauthenticated). This creates a tiered rate limiting system.

### Decision Handling

| Arcjet Decision | HTTP Response |
|---|---|
| `isDenied() && isBot()` | 403 — "Automated requests are not allowed" |
| `isDenied() && isShield()` | 403 — "Request blocked by security policy" |
| `isDenied() && isRateLimit()` | 403 — "Too many requests" |
| Allowed | `next()` — continues to route handler |

> **Interview note:** Arcjet runs in the cloud but decisions happen in-process via the SDK. It evaluates the request against rules and returns a decision object — no network round-trip blocking the critical path in the same sense as a proxy.

---

## 8. Authentication & Authorization System

### JWT Strategy

- **Algorithm:** HS256 (default for `jsonwebtoken`)
- **Secret:** `process.env.JWT_SECRET`
- **Expiry:** `1d` (24 hours), hardcoded in `src/utils/jwt.js`
- **Transport:** `httpOnly` cookie named `token`

### Why cookies instead of `Authorization: Bearer` headers?

| Factor | Cookie | Header |
|---|---|---|
| XSS vulnerability | ❌ Not accessible to JS (`httpOnly`) | ✅ Accessible to JS (vulnerable) |
| CSRF risk | ✅ Mitigated with `sameSite: 'strict'` | ❌ N/A (not auto-sent) |
| Client implementation | Automatic by browser | Manual — must store & attach |

The project chose cookies because the `httpOnly` + `sameSite: strict` combination gives stronger XSS protection than storing a token in `localStorage` or `sessionStorage`.

### Cookie Security Options (`src/utils/cookies.js`)

```js
{
  httpOnly: true,                                     // JS cannot read it
  secure: process.env.NODE_ENV === 'production',      // HTTPS only in prod
  sameSite: 'strict',                                 // No cross-site sending
  maxAge: 15 * 60 * 1000,                            // 15 minutes (900,000 ms)
}
```

> **Note:** The JWT expiry is `1d` but the cookie `maxAge` is 15 minutes. The browser discards the cookie after 15 minutes, even though the JWT itself would still be valid for up to 24h. This is a stricter UX-driven timeout.

### Auth Flow — Sign Up

```
POST /api/auth/sign-up
  │
  ├─ Zod validates: name, email, password, role
  ├─ auth.service: check email uniqueness in DB
  ├─ bcrypt.hash(password, 10)
  ├─ db.insert(users)
  ├─ jwt.sign({ id, email, role })
  ├─ res.cookie('token', jwt, { httpOnly, ... })
  └─ 201 { user: { id, name, email, role } }
```

### Auth Flow — Sign In

```
POST /api/auth/sign-in
  │
  ├─ Zod validates: email, password
  ├─ auth.service: fetch user by email
  ├─ bcrypt.compare(plaintext, hash)
  ├─ jwt.sign({ id, email, role })
  ├─ res.cookie('token', jwt)
  └─ 200 { user: { id, name, email, role } }
```

### Auth Flow — Sign Out

```
POST /api/auth/sign-out
  │
  └─ res.clearCookie('token') → 200
```

### Token Verification (`auth.middleware.js`)

```
Request hits protected route
  │
  ├─ Read req.cookies.token
  ├─ jwt.verify(token, JWT_SECRET)
  ├─ Attach decoded payload → req.user
  └─ next()
```

If no cookie or invalid token → `401 Authentication required`.

---

## 9. Database Layer — Drizzle ORM + Neon Postgres

**File:** `src/config/database.js`

### Neon vs. Traditional Postgres

Neon is a **serverless Postgres** provider. Key differences:

| Feature | Traditional Postgres | Neon |
|---|---|---|
| Connection | TCP persistent | HTTP (via `neon()` driver) |
| Scaling | Manual | Auto, scales to zero |
| Dev branching | Separate instances | Branch per developer |
| Cost | Always running | Pay per query |

### Connection Setup

```js
import { neon } from '@neondatabase/serverless';
import { drizzle } from 'drizzle-orm/neon-http';

// Development override: redirect to neon-local Docker container
if (process.env.NODE_ENV === 'development') {
  neonConfig.fetchEndpoint = 'http://neon-local:5432/sql';
  neonConfig.useSecureWebSocket = false;
  neonConfig.poolQueryViaFetch = true;
}

const sql = neon(process.env.DATABASE_URL); // HTTP-based query function
const db = drizzle(sql);                    // ORM wrapper
```

In development, queries go to a local `neon-local` Docker container (a Neon proxy) instead of the cloud. The app code never changes — just the env variable.

### Drizzle ORM

Drizzle is a **query builder with an ORM-like API** — it generates SQL but stays close to it. No magic like Sequelize associations; every query is explicit.

```js
// Example from users.service.js
await db.select({ id: users.id, email: users.email })
        .from(users)
        .where(eq(users.id, id))
        .limit(1);
```

### Migrations

Generated by `drizzle-kit` from the schema in `src/models/*.js`:

```bash
npm run db:generate  # → creates SQL file in drizzle/
npm run db:migrate   # → runs pending migrations against DB
npm run db:studio    # → opens Drizzle Studio (GUI)
```

The migration file `drizzle/0000_long_tombstone.sql` is the initial schema DDL, version-controlled alongside the code.

---

## 10. Data Model

**File:** `src/models/user.model.js`

```js
export const users = pgTable('users', {
  id:         serial('id').primaryKey(),              // AUTO_INCREMENT integer PK
  name:       varchar('name', { length: 255 }).notNull(),
  email:      varchar('email', { length: 255 }).notNull().unique(),
  password:   varchar('password', { length: 255 }).notNull(), // bcrypt hash
  role:       varchar('role', { length: 50 }).notNull().default('user'),
  created_at: timestamp().defaultNow().notNull(),
  updated_at: timestamp().defaultNow().notNull(),
});
```

### Generated SQL

```sql
CREATE TABLE "users" (
  "id"         serial PRIMARY KEY NOT NULL,
  "name"       varchar(255) NOT NULL,
  "email"      varchar(255) NOT NULL,
  "password"   varchar(255) NOT NULL,
  "role"       varchar(50) DEFAULT 'user' NOT NULL,
  "created_at" timestamp DEFAULT now() NOT NULL,
  "updated_at" timestamp DEFAULT now() NOT NULL,
  CONSTRAINT "users_email_unique" UNIQUE("email")
);
```

### Design Decisions

- **`serial` PK** — auto-incrementing integer. Simple, predictable.
- **`email` UNIQUE constraint** enforced at the DB level (not just application level).
- **Password stored as bcrypt hash** — raw password never persisted.
- **`role` as `varchar`** — flexible; could add new roles without schema change.
- **`updated_at` manual update** — the service layer sets `updated_at: new Date()` on every update call. There's no DB trigger; this is intentional for portability.
- **Password never returned in queries** — all `select()` calls explicitly list columns, omitting `password`.

---

## 11. API Routes Reference

### Auth Routes — `/api/auth`

No authentication required (public endpoints).

| Method | Path | Controller | Description |
|---|---|---|---|
| `POST` | `/api/auth/sign-up` | `signup` | Register new user |
| `POST` | `/api/auth/sign-in` | `signIn` | Login, receive JWT cookie |
| `POST` | `/api/auth/sign-out` | `signOut` | Clear JWT cookie |

### User Routes — `/api/users`

All routes require `authenticateToken` middleware.

| Method | Path | Extra Middleware | Controller | Access |
|---|---|---|---|---|
| `GET` | `/api/users/` | — | `fetchAllUsers` | Any authenticated user |
| `GET` | `/api/users/:id` | — | `fetchUserById` | Any authenticated user |
| `PUT` | `/api/users/:id` | — | `updateUserById` | Own profile or admin |
| `DELETE` | `/api/users/:id` | `requireRole(['admin'])` | `deleteUserById` | Admin only |

### System Routes

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Hello message |
| `GET` | `/health` | `{ status, timestamp, uptime }` — used by Docker HEALTHCHECK |
| `GET` | `/api` | API running confirmation |

### 404 Handler

The last `app.use()` in `app.js` catches all unmatched routes:
```js
app.use((req, res) => res.status(404).json({ error: 'Route not found' }));
```

---

## 12. Validation Layer — Zod

Zod schemas are the **contract** between HTTP and business logic. Validation runs in controllers *before* any service call.

### Auth Validation (`auth.validation.js`)

```js
signupSchema = z.object({
  name:     z.string().min(2).max(255).trim(),
  email:    z.email().max(255).toLowerCase().trim(),
  password: z.string().min(6).max(128),
  role:     z.enum(['user', 'admin']).default('user'),
});

signInSchema = z.object({
  email:    z.email().toLowerCase().trim(),
  password: z.string().min(1),
});
```

### Users Validation (`users.validation.js`)

```js
userIdSchema = z.object({
  id: z.string()
        .regex(/^\d+$/, 'ID must be a valid number')
        .transform(Number)        // string → number
        .refine(val => val > 0, 'ID must be a positive number'),
});

updateUserSchema = z.object({
  name:  z.string().min(2).max(255).trim().optional(),
  email: z.email().max(255).toLowerCase().trim().optional(),
  role:  z.enum(['user', 'admin']).optional(),
}).refine(data => Object.keys(data).length > 0, {
  message: 'At least one field must be provided for update',
});
```

### Validation Pattern in Controllers

```js
const result = schema.safeParse(req.body); // Does NOT throw
if (!result.success) {
  return res.status(400).json({
    error: 'Validation failed',
    details: formatValidationError(result.error), // human-readable string
  });
}
const data = result.data; // safe to use
```

`safeParse` is used instead of `parse` to avoid unhandled exceptions. Errors are caught inline.

### `formatValidationError` (`utils/format.js`)

```js
export const formatValidationError = errors => {
  if (Array.isArray(errors.issues))
    return errors.issues.map(i => i.message).join(', ');
  return JSON.stringify(errors);
};
```

Flattens Zod's nested error structure into a readable comma-separated string.

---

## 13. Service Layer — Business Logic

Services are pure functions — no `req`/`res`, no HTTP concerns. They throw meaningful errors that controllers catch and map to HTTP codes.

### auth.service.js

| Function | What it does |
|---|---|
| `hashPassword(password)` | `bcrypt.hash(password, 10)` — cost factor 10 |
| `comparePassword(plain, hash)` | `bcrypt.compare(plain, hash)` → boolean |
| `createUser({ name, email, password, role })` | Check duplicate email → hash pw → DB insert → return safe user |
| `authenticateUser({ email, password })` | Fetch by email → compare pw → return safe user |

### users.service.js

| Function | What it does |
|---|---|
| `getAllUsers()` | `SELECT id, email, name, role, created_at, updated_at FROM users` |
| `getUserById(id)` | Fetch by PK, throws `'User not found'` if missing |
| `updateUser(id, updates)` | Check existence → check email uniqueness if changing → `UPDATE ... RETURNING` |
| `deleteUser(id)` | Check existence → `DELETE ... RETURNING` |

### Error Convention

Services throw plain `Error` objects with specific message strings:

```
'User with this email already exists'   → 409 in controller
'User not found'                        → 404 in controller
'Invalid password'                      → 401 in controller
'Email already exists'                  → 409 in controller
```

Controllers catch these known strings and map them to appropriate HTTP codes. Unknown errors propagate to Express's default error handler via `next(e)`.

---

## 14. Utility Modules

### `utils/jwt.js` — JWT Wrapper

```js
export const jwttoken = {
  sign: payload => jwt.sign(payload, JWT_SECRET, { expiresIn: '1d' }),
  verify: token => jwt.verify(token, JWT_SECRET),
};
```

Wraps `jsonwebtoken` with unified error handling. Both methods throw `'Failed to authenticate token'` on failure.

**JWT Payload structure:**
```json
{ "id": 1, "email": "user@example.com", "role": "user", "iat": 1234567890, "exp": 1234654290 }
```

### `utils/cookies.js` — Cookie Helper

Centralizes cookie security options in one place. Any change to `httpOnly`, `secure`, or `sameSite` applies everywhere:

```js
getOptions: () => ({
  httpOnly: true,
  secure: process.env.NODE_ENV === 'production',
  sameSite: 'strict',
  maxAge: 15 * 60 * 1000,  // 15 minutes
}),
set:   (res, name, value) => res.cookie(name, value, cookies.getOptions()),
clear: (res, name)        => res.clearCookie(name, cookies.getOptions()),
get:   (req, name)        => req.cookies[name],
```

### `utils/format.js` — Zod Error Formatter

Converts Zod's nested `issues` array into a flat human-readable string for API responses.

---

## 15. Logging — Winston

**File:** `src/config/logger.js`

### Configuration

```js
winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.errors({ stack: true }),
    winston.format.json()
  ),
  defaultMeta: { service: 'acquisitions-api' },
  transports: [
    new File({ filename: 'logs/error.lg',      level: 'error' }),
    new File({ filename: 'logs/combined.log' }),  // all levels
    // + Console in non-production (colorized, simple format)
  ],
});
```

### Log Levels Used

| Level | Used for |
|---|---|
| `error` | Exceptions, auth failures, DB errors |
| `warn` | Bot blocked, rate limit hit, access denied |
| `info` | Successful operations, request lifecycle |
| `debug` | Verbose dev-only output (LOG_LEVEL=debug) |

### Morgan Integration

Morgan's HTTP request log is piped into Winston:
```js
morgan('combined', {
  stream: { write: message => logger.info(message.trim()) }
})
```

This means all HTTP access logs appear in `logs/combined.log` alongside application logs — single log sink, structured JSON format.

---

## 16. Error Handling Strategy

### Three-tier error flow

```
Service throws Error('User not found')
        │
        ▼
Controller catches it
        │
        ├─ known message → res.status(404).json(...)
        └─ unknown error → next(e)
                                │
                                ▼
                    Express default error handler
                    (500 Internal Server Error)
```

### Key Design: Don't Leak Error Details

Controllers map internal error messages to safe generic responses:
```js
// Service throws: 'Invalid password'
// Controller sends: { error: 'Invalid credentials' }  ← no hint about what failed
```

This prevents username enumeration attacks.

### Express 5 Async Error Propagation

Express 5 automatically catches unhandled promise rejections in route handlers — no need for `try/catch` wrappers around async middleware. The project still uses explicit `try/catch` for fine-grained control over which errors to map vs. propagate.

---

## 17. RBAC — Role-Based Access Control

The system has two roles: `'user'` and `'admin'`.

### Permission Matrix

| Action | guest | user | admin |
|---|---|---|---|
| Sign up / Sign in | ✅ | ✅ | ✅ |
| View all users | ❌ | ✅ | ✅ |
| View user by ID | ❌ | ✅ | ✅ |
| Update own profile | ❌ | ✅ | ✅ |
| Update any profile | ❌ | ❌ | ✅ |
| Change roles | ❌ | ❌ | ✅ |
| Delete any user | ❌ | ❌ | ✅ |
| Delete own account | ❌ | ❌ | ❌ (even admin blocked) |

### Implementation

**Route-level:** `requireRole(['admin'])` middleware added to DELETE route.

**Controller-level (updateUserById):**
```js
// Users can only update their own profile
if (req.user.role !== 'admin' && req.user.id !== id) → 403

// Only admins can change roles
if (updates.role && req.user.role !== 'admin') → 403

// Strip role from non-admin updates silently
if (req.user.role !== 'admin') delete updates.role;
```

**Self-deletion protection (deleteUserById):**
```js
if (req.user.id === id) → 403 "You cannot delete your own account"
```

### `requireRole` Middleware

```js
export const requireRole = allowedRoles => (req, res, next) => {
  if (!allowedRoles.includes(req.user.role)) → 403
  else next();
};
```

This is a **middleware factory** — it returns a middleware function. The route uses it as:
```js
router.delete('/:id', authenticateToken, requireRole(['admin']), deleteUserById);
```

---

## 18. Environment & Configuration

### Environment Files

| File | Purpose |
|---|---|
| `.env` | Local defaults (not committed with real secrets) |
| `.env.development` | Dev Docker config — points DB to `neon-local` |
| `.env.production` | Prod config — real Neon cloud DB URL |
| `.env.production.example` | Template for onboarding |

### Required Environment Variables

| Variable | Description |
|---|---|
| `DATABASE_URL` | Neon Postgres connection string |
| `JWT_SECRET` | Secret key for JWT signing |
| `ARCJET_KEY` | Arcjet API key |
| `NODE_ENV` | `development` or `production` |
| `PORT` | Server port (default: 3000) |
| `LOG_LEVEL` | Winston log level (default: `info`) |
| `NEON_API_KEY` | Neon API key (for `neon-local` in dev) |
| `NEON_PROJECT_ID` | Neon project (for `neon-local` in dev) |
| `PARENT_BRANCH_ID` | Neon branch to clone in dev |

### How `dotenv` Is Loaded

`database.js` imports `dotenv/config` at the top as a side-effect import:
```js
import 'dotenv/config';
```

This loads `.env` into `process.env` before any DB config runs. It's the first module resolved in the import chain.

---

## 19. Testing Strategy

**File:** `tests/app.test.js`

### Setup

- **Runner:** Jest with `--experimental-vm-modules` (required for ESM)
- **HTTP layer:** Supertest (wraps the Express app without binding a port)
- **Coverage:** V8 provider, outputs to `coverage/`

### Current Tests

```js
describe('API Endpoints', () => {
  it('GET /health → 200 { status: "OK", timestamp, uptime }')
  it('GET /api    → 200 { message: "Acquisitions API is running!" }')
  it('GET /nonexistent → 404 { error: "Route not found" }')
})
```

These are **integration tests** — they test the full Express middleware stack against real route handlers. The Arcjet middleware is called but won't block in test environments.

### Jest Config Key Points

```js
{
  testEnvironment: 'node',
  collectCoverage: true,
  coverageProvider: 'v8',
  coverageDirectory: 'coverage',
  clearMocks: true,
}
```

### Module Alias Resolution in Jest

The `package.json` `imports` field (`#config/*` etc.) is resolved automatically by Node.js when running Jest with `NODE_OPTIONS=--experimental-vm-modules`. No `moduleNameMapper` needed in `jest.config.mjs`.

---

## 20. End-to-End Request Walkthrough

### Example: `PUT /api/users/5` (user updating their own profile)

```
1. HTTP Request arrives: PUT /api/users/5
   Body: { "name": "New Name" }
   Cookie: token=<jwt>

2. Helmet sets security headers on the response object

3. cors() checks Origin header

4. express.json() parses body → req.body = { name: "New Name" }

5. cookieParser() parses Cookie header → req.cookies.token = "<jwt>"

6. morgan() logs: PUT /api/users/5 200 ...

7. securityMiddleware (Arcjet):
   - req.user is undefined at this point → role = 'guest'
   - Applies 5 req/min limit for guest
   - Shield + bot check passes
   - decision.isAllowed() → next()

8. Router matches /api/users/:id → users.routes.js

9. authenticateToken middleware:
   - Reads req.cookies.token
   - jwt.verify(token) → { id: 5, email: "u@e.com", role: "user" }
   - Sets req.user = { id: 5, email: "u@e.com", role: "user" }
   - next()

10. updateUserById controller:
    a. Zod validates req.params.id = "5" → transforms to Number 5
    b. Zod validates req.body → { name: "New Name" } ✅
    c. req.user.role !== 'admin' && req.user.id (5) === id (5) → allowed ✅
    d. No role in updates → role check skipped
    e. Calls updateUser(5, { name: "New Name" })

11. users.service.updateUser(5, { name: "New Name" }):
    a. getUserById(5) → user exists ✅
    b. No email in updates → skip email uniqueness check
    c. db.update(users)
         .set({ name: "New Name", updated_at: new Date() })
         .where(eq(users.id, 5))
         .returning(...)
    d. Returns updated user object (no password field)

12. Controller sends:
    200 { message: "User updated successfully", user: { id, email, name, role, ... } }
```

---

## 21. Common Interview Q&A

**Q: Why Express 5 instead of Express 4?**  
A: Express 5 has built-in async error handling — rejected promises in route handlers are automatically forwarded to error middleware. No need for `try/catch` or `express-async-errors` wrapper.

**Q: Why Drizzle ORM instead of Prisma or Sequelize?**  
A: Drizzle is closer to raw SQL, so there's no "magic" — queries are predictable. It's also lighter and works well with serverless environments (no connection pool manager required). Prisma's client generation adds complexity; Sequelize is heavier and more opinionated.

**Q: Why store JWT in a cookie vs. localStorage?**  
A: `httpOnly` cookies are inaccessible to JavaScript, eliminating XSS token theft. `sameSite: 'strict'` prevents CSRF. With localStorage, any injected script can read the token.

**Q: How does bcrypt's cost factor work?**  
A: bcrypt hashes are computed with `2^cost` iterations. Cost 10 means 1024 iterations. This makes brute-force attacks computationally expensive while keeping login time acceptable (~100ms).

**Q: What is Arcjet's shield rule?**  
A: Shield is a WAF rule that inspects request payloads for attack patterns — SQL injection, XSS, path traversal, etc. It runs in `LIVE` mode meaning it actively blocks (not just logs).

**Q: How does the sliding window rate limiter work?**  
A: A sliding window counts requests in a moving time window (not fixed buckets). For a 1-minute window with max 10, it counts requests in the past 60 seconds from the current moment — smoother than a fixed window that resets abruptly.

**Q: What happens when two users try to register with the same email simultaneously?**  
A: There's an application-level check (`SELECT` before `INSERT`) but also a **database-level unique constraint** on `email`. Even if the app check passes for both concurrent requests, the second `INSERT` will fail at the DB level with a constraint violation, which the service layer catches and rethrows.

**Q: Why is `password` never returned in API responses?**  
A: All `db.select()` calls explicitly list the columns they want (id, name, email, role, timestamps). The `password` column is never included. This is safer than relying on response serialization to strip it.

**Q: Explain the module alias system (`#config/*`)**  
A: Node.js `package.json` `imports` field lets you define path aliases using the `#` prefix. These are resolved natively by Node.js without any build step. For example, `#config/logger.js` resolves to `./src/config/logger.js` from anywhere in the project.

**Q: Why split `index.js`, `server.js`, and `app.js`?**  
A: `app.js` creates and exports the Express app without starting a server. Tests import `app.js` directly and Supertest handles binding. `server.js` is only concerned with `app.listen()`. `index.js` is the process entry point. This separation means the full middleware stack is testable in isolation.

**Q: How does `neon-local` work in development?**  
A: Neon Local is a Docker container that acts as a Neon proxy. It creates a temporary branch of your Neon project, serves it locally on port 5432, and cleans it up on shutdown. The app points to `http://neon-local:5432/sql` via Docker's internal DNS. The production app code is unchanged — only `DATABASE_URL` differs.

**Q: What does `updated_at: new Date()` in the service mean? Why not a DB trigger?**  
A: The project updates `updated_at` explicitly in the application layer for portability — no need for DB-specific trigger syntax. The tradeoff is that direct DB edits won't update the timestamp, but for an API-first system this is acceptable.

**Q: What would you improve in production?**  
A: Refresh token rotation (the current 15-min cookie with 1-day JWT creates an inconsistency), tighten CORS to a whitelist, add request ID tracking across logs, add index on `email` column (though the UNIQUE constraint creates one implicitly), add pagination to `getAllUsers`, and expand test coverage to controllers and services with mocked DB.
