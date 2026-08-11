# CribWire backend

Zero-knowledge pairing, signaling, and push API — Node 22, TypeScript (strict),
Fastify, `ws`, Postgres, Redis. The service authenticates devices, routes opaque
ciphertext, stores the minimum needed to route and push (`pairings`, `devices`),
and never sees plaintext: the keys it holds authenticate and decrypt nothing.

Specs: [`docs/specs/backend.md`](../docs/specs/backend.md),
[`docs/specs/security.md`](../docs/specs/security.md). Wire formats:
[`shared/protocol.md`](../shared/protocol.md) (revision 1.1) with fixtures in
[`shared/test-vectors/cribwire-v1.json`](../shared/test-vectors/cribwire-v1.json).

## Setup

```bash
npm install
cp .env.example .env

docker compose up -d postgres redis   # Postgres 16 + Redis 7
npm run migrate                       # apply SQL migrations
npm run dev                           # http://localhost:8080/v1/health
```

Without Docker the service still starts: set `DATABASE_URL` to any reachable
Postgres. `REDIS_URL` may be omitted in development (per-process nonce cache,
rate limits, and signaling bus); production refuses to start without it, and
also without `TURN_SHARED_SECRET`/`TURN_URIS` and the four `APNS_*` values.

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
docker compose --profile turn up          # coturn (host networking)
```

## Layout

```
migrations/          plain SQL, applied in filename order
src/auth/            CribWire-HMAC canonicalisation, verification, nonce cache
src/ratelimit/       token buckets (Redis + in-memory)
src/repositories/    Postgres and in-memory implementations of one port
src/routes/          REST handlers
src/ws/              signaling: upgrade, hub/router, Redis pub/sub bridge
src/push/            APNs port, HTTP/2 sender, event fan-out
src/turn/            ephemeral coturn credentials
src/metrics/         Prometheus registry and exposition
src/jobs/            daily purge job (+ CLI)
test/contract/       shared test-vector conformance
test/unit/           auth, limits, endpoints, signaling, push (in-memory)
test/integration/    real Postgres/Redis, auto-skipped when unreachable
```

## Endpoints (v1)

| Method | Path                                 | Principal        | Notes                                   |
| ------ | ------------------------------------ | ---------------- | --------------------------------------- |
| GET    | `/v1/health`                         | none             | `{"status":"ok"}`                       |
| GET    | `/v1/version`                        | none             | service/version/api/commit              |
| GET    | `/metrics`                           | none             | Prometheus text; own port if set        |
| POST   | `/v1/pairings`                       | `bootstrap`      | camera registers pairing, 10-min TTL    |
| POST   | `/v1/pairings/:id/claim`             | `bootstrap`      | max 5 viewers, activates the pairing    |
| DELETE | `/v1/pairings/:id`                   | device, camera   | hard-deletes pairing, keys, and tokens  |
| DELETE | `/v1/pairings/:id/viewers/:deviceId` | device, camera   | hard-deletes one viewer                 |
| POST   | `/v1/pairings/:id/turn-credentials`  | device, any role | ephemeral coturn credentials, 1 h       |
| PUT    | `/v1/devices/token`                  | device, any role | rotates the caller's APNs token → `204` |
| POST   | `/v1/events`                         | device, camera   | sealed event → APNs fan-out → `202`     |
| GET    | `/v1/signal`                         | device, any role | WebSocket upgrade (see below)           |

Request and response bodies are exactly those pinned in `shared/protocol.md`
§"REST bodies"; unknown request fields are rejected with `400`. Errors are
`{"error":"…","message":"…"}`. Auth failures are always `401` (never revealing
whether a pairing or device exists), authorization failures `403`, rate limits
`429` with `Retry-After`.

### Authentication (protocol.md 1.1)

```
canonical = METHOD \n PATH \n TIMESTAMP \n PRINCIPAL \n lowercase-hex(SHA-256(body))
mac       = lowercase-hex(HMAC-SHA256(key, canonical))
header    = Authorization: CribWire-HMAC <pairingId>:<principal>:<timestamp>:<mac>
```

- `PRINCIPAL` is the literal `bootstrap` for the two calls that establish a
  device — `POST /v1/pairings` and `POST /v1/pairings/:id/claim`, signed with
  the pairing-wide `K_auth` — and the calling device's UUID everywhere else,
  signed with that device's own key.
- `PATH` is the path only (no query); the server canonicalises the request
  target verbatim, so clients must sign the exact bytes they send.
- Timestamps outside ±60 s are rejected; MACs are compared with
  `crypto.timingSafeEqual`; `(pairingId, mac)` is recorded in the nonce cache
  for 2× the window, making every authenticated request single-use. Only
  MAC-valid requests are recorded, so the cache cannot be poisoned with guesses.
- A credential that resolves to no key — unknown pairing, unknown device,
  revoked pairing, or a `bootstrap` principal on a device route — fails as
  `unknown_principal`, one code for all of them so existence is not leaked.

#### Why `POST /v1/pairings` is self-authenticating

The pairing does not exist yet, so there is no stored key to verify against.
The body carries the `K_auth` being registered and the MAC must verify **under
that same key**, with the header's `pairingId` matching the body's. This proves
the caller possesses the key it is uploading — not that the caller is a known
device, and it is not meant to. Abuse is bounded by the per-IP creation limit
(10/h), the 10-minute unclaimed TTL, and the fact that a pairing is useless
until a viewer that scanned the QR claims it.

#### Roles come from the database, never from the request

`K_auth` proves _membership of the pairing_, never _which device is calling_ —
every device that scanned the QR holds it. Revision 1.1 therefore limits
`K_auth` to the two bootstrap calls. Each device generates its own random
32-byte key, uploads it once in the bootstrap-authenticated body (`deviceKey`),
and signs everything afterwards with it; the server stores it on the device row
and reads the caller's role **from that row**.

The consequence: a viewer presenting its own key on a camera-only route gets
`403 role_not_permitted`, and presenting the camera's _principal_ without the
camera's _key_ gets `401 invalid_signature`. There is nothing a client can put
in a request to change its role. This is covered by
`test/unit/endpoints.test.ts` ("viewer key on camera-only routes") and again
against real rows in `test/integration/postgres.test.ts`.

Device keys, like `K_auth`, decrypt nothing.

### Signaling (`GET /v1/signal`)

- The upgrade carries the same header with a device principal and `PATH` of
  `/v1/signal` (any query string is ignored and unsigned). A failed upgrade is
  answered with a plain `401` and never becomes a WebSocket.
- Client → server: `{"to": "camera" | "viewer:<deviceId>", "seq": n, "blob":
"<base64>"}`. Unknown fields are rejected. `to` must address a device in the
  sender's own pairing; `seq` must increase strictly per sender.
- Server → client frames are tagged with `type`:
  - `ready` — `{self, pairingId, heartbeatSeconds, idleTimeoutSeconds,
maxMessageBytes}` on connect,
  - `message` — `{from, to, seq, blob}`, the envelope as sent,
  - `peer-online` / `peer-offline` — `{peer}`,
  - `error` — `{error, message}` for a rejected frame.
    `backend.md` pins the client envelope and the presence event names; the
    frame envelope around them is this server's choice, documented here and
    mirrored by the iOS client.
- `blob` is sealed under `K_sig` and is opaque: the server measures it, routes
  it, and forwards it byte-for-byte. Nothing decodes it.
- Messages over 16 KiB close the connection with `1009`. Ping every 30 s; a
  peer that misses a pong between sweeps is terminated; a connection with no
  client message for 5 minutes is closed with `idle_timeout`.
- A second connection from the same device replaces the first (`replaced`), and
  revoking a pairing or evicting a viewer closes the affected sockets at once.
- Every message and presence event travels over a Redis pub/sub channel
  (`cribwire:signal:<pairingId>`), so two peers on different API instances talk
  normally. Without `REDIS_URL` the bus is per-process — development only.

### Push notifications

`POST /v1/events` takes `{ciphertext}` from the camera and fans it out to every
viewer of the pairing over APNs HTTP/2 with token (`.p8`) auth:
`apns-push-type: alert` and the payload from `backend.md` §3 with the ciphertext
copied verbatim. The visible text is the fixed `EVENT_GENERIC` key — the server
cannot say more, since it cannot read the event; the iOS app opens the
ciphertext itself and shows the detail. A `410 Unregistered`
answer deletes every device row holding that token. The sender is a port
(`src/push/apns.ts`); tests run against a fake and never touch Apple.

## Data and logging

- Only `pairings` and `devices` exist. No media, no events, no accounts.
- `DELETE /v1/pairings/:id` hard-deletes the row; the FK cascade removes every
  device key and token immediately (security.md §6). The `revoked` status
  remains in the schema and `npm run purge` still clears such rows, but the
  revocation path does not leave a tombstone holding a key.
- `npm run purge` also deletes pending pairings older than the TTL. Run it
  daily (cron / Kubernetes CronJob); the service has no internal scheduler.
- Fastify request logging is off. Application logs are JSON on stderr and pass
  through a redactor that blanks keys such as `k_auth`, `apnsToken`,
  `authorization`, `mac`, `body`, `blob`, and `ciphertext`.
- `/metrics` carries counters, a gauge, and one histogram over fixed labels
  only — no pairing id, device id, token, or IP. It can be bound to its own
  port with `METRICS_PORT` so it need not be publicly exposed.

## Limits

| Limit                 | Value                | Where                       |
| --------------------- | -------------------- | --------------------------- |
| Request body          | 16 KiB               | Fastify `bodyLimit` → `413` |
| WebSocket message     | 16 KiB               | `ws` `maxPayload` → `1009`  |
| Pairing creation      | 10 per hour per IP   | token bucket                |
| Claim attempts        | 20 per hour per IP   | token bucket                |
| Per-pairing requests  | 30 per hour          | token bucket                |
| Signaling upgrades    | 120 per hour per IP  | token bucket                |
| Events                | 1 per 30 s / pairing | token bucket (own key)      |
| Event posts per IP    | 240 per hour         | token bucket                |
| Viewers per pairing   | 5                    | enforced in a transaction   |
| Unclaimed pairing TTL | 10 min               | claim returns `410`         |
| Timestamp window      | 60 s                 | `401`                       |
| Signaling idle        | 5 min                | close `idle_timeout`        |

All are configurable through the environment (see `.env.example`).

## TURN

`POST /v1/pairings/:id/turn-credentials` issues coturn `use-auth-secret`
credentials: `username = <expiry>:<pairingId>`, `credential =
base64(HMAC-SHA1(TURN_SHARED_SECRET, username))`, TTL 1 h. Nothing is stored;
coturn recomputes the same HMAC. `docker/coturn/turnserver.conf` holds the
matching development configuration (`docker compose --profile turn up`). With
TURN unconfigured the endpoint answers `503 turn_unavailable`.

## Tests

```bash
npm test                      # unit + contract; integration skipped if no services
docker compose up -d postgres redis
npm test                      # integration tests now run
```

Integration tests probe Postgres and Redis at load time and use
`describe.skipIf`, so a machine without Docker still gets a green suite; CI
fails the build if anything skips while the services are up. They use
`TEST_DATABASE_URL` (default database `cribwire_test`, created by the compose
init script) so a run never touches development data.

The contract suite reads `shared/test-vectors/cribwire-v1.json` from disk — the
same file the iOS suite loads — and verifies all four pinned auth examples,
each under the key that signs it. Values are never copied into source.

## Not implemented yet

- Certificate pinning support material for the iOS client (Phase 4).
- TURN bandwidth metrics: coturn exposes them itself; the API does not proxy
  them yet.
