# CribWire — Backend Specification

Version 0.1 — 2026-08-10 — Status: Draft

## 1. Purpose and guiding principle

The backend exists only to (a) introduce paired devices to each other (signaling),
(b) relay encrypted media packets when a direct connection is impossible (TURN), and
(c) deliver push notifications. It is **zero-knowledge by design**: it never holds
decryption keys, never sees plaintext media, signaling payloads, or event details, and
stores no media at all. Everything it relays is opaque ciphertext produced by the
devices with keys exchanged via the QR code (see `security.md`).

## 2. Components

```
┌──────────┐   WSS (encrypted blobs)   ┌────────────────┐
│  Camera   │◄─────────────────────────►│  Signaling API  │──► Postgres (pairings,
│  device   │                           │  (Node/TS)      │        device tokens)
└─────┬────┘   POST /v1/events          └───────┬────────┘
      │                                         │ APNs HTTP/2
      │  SRTP (DTLS, E2E-authenticated)         ▼
      │  direct P2P when possible          ┌─────────┐
      ▼                                    │  APNs   │──► Viewer devices
┌──────────┐        relay fallback         └─────────┘
│  Viewer   │◄────────► coturn (TURN/STUN) — sees ciphertext only
└──────────┘
```

1. **Signaling & API service** — Node.js 22 / TypeScript, Fastify (REST) + `ws`
   (WebSocket). Stateless; horizontal scaling with a Redis pub/sub bridge so two
   peers connected to different instances can exchange messages.
2. **TURN/STUN** — coturn, long-term credentials replaced by the REST-based
   ephemeral credential mechanism (RFC 8489 STUN + RFC 8656 TURN,
   time-limited HMAC credentials issued by the API).
3. **Push service** — part of the API service; talks to APNs over HTTP/2 with
   token-based (`.p8`) authentication.
4. **Postgres** — pairings and device tokens only (schema in §5).
5. **Redis** — WebSocket session routing and rate-limit counters.

All public endpoints are TLS 1.3 (TLS 1.2 minimum), HSTS enabled.

## 3. API surface

Auth model: every request is authenticated per pairing with an HMAC bearer scheme —
`Authorization: CribWire-HMAC <pairingId>:<role>:<timestamp>:<hmac>` where the HMAC is
computed with the pairing's `K_auth` key (derived on-device from the QR secret,
`security.md` §3.2) over method, path, timestamp, and body hash. The server stores
only `K_auth` — it authenticates devices but cannot decrypt anything. Timestamps
older than 60 s are rejected (replay protection, together with a per-pairing nonce
cache in Redis).

### REST (`/v1`)

| Endpoint | Purpose |
|---|---|
| `POST /v1/pairings` | Camera registers a new pairing before showing the QR: uploads `pairingId` (UUID), `K_auth`, camera APNs token. Returns TTL. Unclaimed pairings expire after 10 min. |
| `POST /v1/pairings/{id}/claim` | Viewer (after scanning the QR) proves possession of `K_auth`, registers its APNs token, activates the pairing. Max 5 viewers per pairing. |
| `DELETE /v1/pairings/{id}` | Camera revokes the whole pairing; `DELETE .../viewers/{deviceId}` revokes one viewer. Deletes all associated tokens immediately. |
| `POST /v1/pairings/{id}/turn-credentials` | Returns ephemeral TURN credentials (TTL 1 h) for either role. |
| `POST /v1/events` | Camera posts a detection event: `{pairingId, ciphertext}` where `ciphertext` is the ChaCha20-Poly1305-encrypted event (type, timestamp). Server fans out to all viewer tokens via APNs without being able to read it. Rate-limited to 1 event / 30 s / pairing (client debounces harder; this is abuse protection). |
| `PUT /v1/devices/token` | Rotate an APNs device token. |
| `GET /v1/health`, `GET /v1/version` | Ops endpoints (unauthenticated, no data). |

### WebSocket (`/v1/signal?pairingId=…`)

- Authenticated with the same HMAC scheme during the upgrade request.
- Message envelope: `{ "to": "camera" | "viewer:<deviceId>", "seq": n, "blob":
  "<base64>" }`. The `blob` is sealed by the sender with the pairing signaling key
  (`K_sig`); the server routes on the envelope only and enforces a 16 KiB message cap.
- Server emits presence events (`peer-online`, `peer-offline`) so the Camera knows
  when to create an offer.
- Heartbeat ping/pong every 30 s; idle connections closed after 5 min.

### Push notifications

- APNs token-based auth (`.p8` key), `apns-push-type: alert`, `mutable-content: 1`
  so the Viewer's Notification Service Extension can decrypt the payload.
- Payload: `{"aps": {"alert": {"loc-key": "EVENT_GENERIC"}, "mutable-content": 1},
  "pairingId": "…", "ciphertext": "…"}` — the visible text before decryption is a
  generic "Activity detected"; the extension replaces it with the decrypted
  noise/movement detail. If decryption fails the generic text is shown.
- Feedback handling: `410 Unregistered` responses delete the stored token.

## 4. TURN/STUN

- coturn behind the same domain (`turn.cribwire.example`), UDP 3478 + TLS 5349
  (turns), relayed port range 49152–65535.
- Ephemeral credentials: `username = <expiry-unix>:<pairingId>`, `password =
  base64(HMAC-SHA1(turn_shared_secret, username))` (coturn `use-auth-secret` mode).
  Issued only through the authenticated API endpoint.
- Per-session bandwidth cap (target: 2 Mbps per allocation) and total-relay quota
  alerts; TURN sees and forwards only SRTP ciphertext.

## 5. Data model (Postgres)

```sql
pairings(
  id uuid primary key,
  k_auth bytea not null,          -- HMAC auth key (cannot decrypt anything)
  status text not null,           -- pending | active | revoked
  created_at timestamptz, claimed_at timestamptz
);
devices(
  id uuid primary key,
  pairing_id uuid references pairings on delete cascade,
  role text not null,             -- camera | viewer
  apns_token text not null,
  apns_environment text not null, -- sandbox | production
  created_at timestamptz, last_seen_at timestamptz
);
```

No media, no event history, no user accounts, no IP logging beyond 24 h operational
logs. Revoked/expired pairings are hard-deleted by a daily job.

## 6. Non-functional requirements

- **Latency**: signaling round-trip < 200 ms P95 in-region; event → APNs handoff
  < 1 s P95.
- **Scale target (v1)**: 10 k concurrent WebSocket connections, 1 k concurrent TURN
  allocations per node; both horizontally scalable.
- **Availability**: 99.5 % monthly; stateless API allows rolling deploys.
- **Abuse controls**: per-IP and per-pairing rate limits (Redis token bucket) on all
  endpoints; pairing creation limited per IP per hour; message-size caps on the
  socket.
- **Observability**: structured logs (no payloads, no tokens), Prometheus metrics
  (connections, event fan-out latency, APNs error rates, TURN bandwidth), alerting on
  APNs failure spikes.
- **Deployment**: Docker images; docker-compose for development, single-region
  Kubernetes or equivalent for production; EU region hosting (GDPR); Terraform for
  infra. Secrets (APNs `.p8`, TURN shared secret, DB creds) in a secrets manager,
  never in the repo.
- **Compliance**: GDPR — APNs tokens are personal data; DPA with the hosting
  provider, deletion on unpair, no cross-border transfer outside the EU except the
  unavoidable APNs delivery to Apple.

## 7. Explicit non-goals

Media recording or storage, server-side detection/transcoding/SFU, user accounts and
password auth, analytics on stream content. Adding any of these must not weaken the
zero-knowledge property without an explicit spec revision.
