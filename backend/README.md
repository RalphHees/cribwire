# KidsCam backend

Zero-knowledge pairing and signaling API — Node 22, TypeScript (strict),
Fastify, Postgres, Redis. The service authenticates devices, stores the minimum
needed to route and push (`pairings`, `devices`), and never sees plaintext: it
holds `K_auth` only, which authenticates but decrypts nothing.

Specs: [`docs/specs/backend.md`](../docs/specs/backend.md),
[`docs/specs/security.md`](../docs/specs/security.md). Wire formats:
[`shared/protocol.md`](../shared/protocol.md) with fixtures in
[`shared/test-vectors/kidscam-v1.json`](../shared/test-vectors/kidscam-v1.json).

## Setup

```bash
npm install
cp .env.example .env

docker compose up -d postgres redis   # Postgres 16 + Redis 7
npm run migrate                       # apply SQL migrations
npm run dev                           # http://localhost:8080/v1/health
```

Without Docker the service still starts: set `DATABASE_URL` to any reachable
Postgres. `REDIS_URL` may be omitted in development (per-process nonce cache and
rate limits); production refuses to start without it.

### Scripts

| Command             | Purpose                                                     |
| ------------------- | ----------------------------------------------------------- |
| `npm run build`     | Type-check and emit `dist/`                                 |
| `npm run typecheck` | `tsc --noEmit`                                              |
| `npm run lint`      | ESLint (type-aware)                                         |
| `npm run format`    | Prettier                                                    |
| `npm test`          | Vitest; integration tests skip when Postgres/Redis are down |
| `npm run migrate`   | Apply pending SQL migrations                                |
| `npm run purge`     | One-shot hard delete of revoked/expired pairings            |

### Docker

```bash
docker compose --profile api up --build   # api + postgres + redis
```

## Layout

```
migrations/          plain SQL, applied in filename order
src/auth/            KidsCam-HMAC canonicalisation, verification, nonce cache
src/ratelimit/       token buckets (Redis + in-memory)
src/repositories/    Postgres and in-memory implementations of one port
src/routes/          REST handlers
src/jobs/            daily purge job (+ CLI)
test/contract/       shared test-vector conformance
test/unit/           auth, limits, endpoints (in-memory repository)
test/integration/    real Postgres/Redis, auto-skipped when unreachable
```

## Endpoints (v1)

| Method | Path                                 | Auth                            | Notes                                |
| ------ | ------------------------------------ | ------------------------------- | ------------------------------------ |
| GET    | `/v1/health`                         | none                            | `{"status":"ok"}`                    |
| GET    | `/v1/version`                        | none                            | service/version/api/commit           |
| POST   | `/v1/pairings`                       | self-authenticating (see below) | camera registers pairing, 10-min TTL |
| POST   | `/v1/pairings/:id/claim`             | `KidsCam-HMAC`, role `viewer`   | max 5 viewers, activates the pairing |
| DELETE | `/v1/pairings/:id`                   | `KidsCam-HMAC`, role `camera`   | hard-deletes pairing + all tokens    |
| DELETE | `/v1/pairings/:id/viewers/:deviceId` | `KidsCam-HMAC`, role `camera`   | hard-deletes one viewer              |
| PUT    | `/v1/devices/token`                  | `KidsCam-HMAC`                  | rotates the caller's APNs token      |

Errors are `{"error":{"code":"…","message":"…"}}`. Auth failures are always
`401` (never revealing whether a pairing exists), authorization failures `403`,
rate limits `429` with `Retry-After`.

### Authentication

Exactly as pinned in `shared/protocol.md`:

```
canonical = METHOD \n PATH \n TIMESTAMP \n lowercase-hex(SHA-256(body))
mac       = lowercase-hex(HMAC-SHA256(K_auth, canonical))
header    = Authorization: KidsCam-HMAC <pairingId>:<role>:<timestamp>:<mac>
```

- `PATH` is the path only (no query); the server canonicalises the request
  target verbatim, so clients must sign the exact bytes they send.
- Timestamps outside ±60 s are rejected.
- MACs are compared with `crypto.timingSafeEqual`.
- `(pairingId, mac)` is recorded in the nonce cache for 2× the window, making
  every authenticated request single-use. Only MAC-valid requests are recorded,
  so the cache cannot be poisoned with guesses.

#### Why `POST /v1/pairings` is self-authenticating

The pairing does not exist yet, so there is no stored `K_auth` to verify
against. The request body carries the `K_auth` being registered and the MAC
must verify **under that same key**, with the header's `pairingId` matching the
body's. This proves the caller possesses the key it is uploading — it does not
prove the caller is a known device, and it is not meant to. Abuse is bounded by
the per-IP creation limit (10/h), the 10-minute unclaimed TTL, and the fact
that a pairing is useless until a viewer that scanned the QR claims it.

#### Role binding (known protocol limitation)

`K_auth` is shared by every device in a pairing and the role travels in the
header, _outside_ the signed canonical string. A holder of `K_auth` can
therefore present either role. Route-level checks (`role_not_permitted`,
`pairing_mismatch`, and the requirement that a camera device actually exists)
raise the bar but cannot be an identity check: a viewer that still holds
`K_auth` can revoke the pairing. This matches `shared/protocol.md` v1 as
written and is covered by a test that documents the behaviour
(`test/unit/endpoints.test.ts`, "documented protocol limitation"). Fixing it
means adding the role to the canonical string, or issuing per-device keys — a
protocol change that must be made on both sides with regenerated vectors.

## Data and logging

- Only `pairings` and `devices` exist. No media, no events, no accounts.
- `DELETE /v1/pairings/:id` hard-deletes the row; the FK cascade removes every
  device token immediately, and `K_auth` is gone (security.md §6). The
  `revoked` status remains in the schema and `npm run purge` still clears such
  rows, but the revocation path does not leave a tombstone holding a key.
- `npm run purge` also deletes pending pairings older than the TTL. Run it
  daily (cron / Kubernetes CronJob); the service has no internal scheduler.
- Fastify request logging is off. Application logs are JSON on stderr and pass
  through a redactor that blanks keys such as `k_auth`, `apnsToken`,
  `authorization`, `mac`, `body`, and `ciphertext`.

## Limits

| Limit                 | Value              | Where                       |
| --------------------- | ------------------ | --------------------------- |
| Request body          | 16 KiB             | Fastify `bodyLimit` → `413` |
| Pairing creation      | 10 per hour per IP | token bucket                |
| Claim attempts        | 20 per hour per IP | token bucket                |
| Per-pairing requests  | 30 per hour        | token bucket                |
| Viewers per pairing   | 5                  | enforced in a transaction   |
| Unclaimed pairing TTL | 10 min             | claim returns `410`         |
| Timestamp window      | 60 s               | `401`                       |

All are configurable through the environment (see `.env.example`).

## Tests

```bash
npm test                      # unit + contract; integration skipped if no services
docker compose up -d postgres redis
npm test                      # integration tests now run
```

Integration tests probe Postgres and Redis at load time and use
`describe.skipIf`, so a machine without Docker still gets a green suite. They
use `TEST_DATABASE_URL` (default database `kidscam_test`, created by the
compose init script) so a run never touches development data.

The contract suite reads `shared/test-vectors/kidscam-v1.json` from disk — the
same file the iOS suite loads. Values are never copied into source.

## Not implemented yet (Phase 2+)

- `GET /v1/signal` WebSocket signaling: HMAC-authenticated upgrade, opaque-blob
  envelope routing, 16 KiB cap (the value is already in config), presence
  events, heartbeat, Redis pub/sub bridge. `ws` is installed and unused.
- `POST /v1/pairings/:id/turn-credentials` and coturn deployment.
- `POST /v1/events` and APNs fan-out, including the `410 Unregistered` cleanup
  path. The repository already exposes `deleteDevicesByApnsToken` for it.
- Prometheus metrics.
