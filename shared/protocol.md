# CribWire v1 — Normative Wire Formats

Revision 1.1 (2026-08-10).

This file pins the exact byte-level encodings and JSON shapes that are
cross-implemented by the iOS app (CryptoKit) and the backend (Node crypto).
`docs/specs/security.md` defines the design; this file defines the bits. Both
implementations MUST reproduce `shared/test-vectors/cribwire-v1.json`
byte-for-byte, and any change here requires regenerating the vectors and
updating both sides in one change set.

## Revision history

- **1.1** — Introduced per-device authentication keys and folded the principal
  into the signed canonical string, closing a privilege-escalation hole (see
  "Why per-device keys" below). Pinned all REST request and response bodies,
  which 1.0 left to prose and the two implementations therefore diverged on.
- **1.0** — Initial contract.

## Key derivation

`HKDF-SHA256(ikm = S, salt = empty, info, length = 32)` with `info` strings
exactly: `cribwire/v1/auth`, `cribwire/v1/sig`, `cribwire/v1/event`,
`cribwire/v1/sas` (UTF-8, no terminator).

## SAS confirmation code

First 4 bytes of `K_sas` interpreted as a big-endian unsigned 32-bit integer,
`mod 1_000_000`, left-padded with zeros to 6 digits.

## QR payload

`cribwire://pair?v=1&id=<pairingId>&s=<S>&api=<url>` where `id` is the lowercase
UUID, `s` is base64url without padding, `api` is the percent-encoded base URL
and MUST use `https` (implementations MAY allow `http` only when explicitly
built for local development). Unknown query parameters MUST be ignored; a `v`
other than `1` MUST be rejected. Parsers MUST accept either case for `id` and
normalise to lowercase.

## Sealed envelope (signaling blobs and event ciphertext)

```
sealed = base64( nonce(12) || ChaCha20-Poly1305-ct || tag(16) )
```

- Nonce: 12 random bytes per message (fixed only in test vectors).
- AAD (UTF-8): signaling → `<pairingId>|<senderRole>` where role is `camera` or
  `viewer`; events → `<pairingId>|event`.
- Standard base64 with padding.
- Plaintext is a UTF-8 JSON document; its schema may evolve, the envelope may not.

## Authentication

### Why per-device keys

`K_auth` is derived from `S`, which every paired device obtains by scanning the
QR code. It therefore proves *membership of the pairing*, never *which device is
calling*. If the caller's role were taken from the request, any viewer could
assert `camera` and revoke the pairing or evict other viewers — defeating the
revocation guarantee in `security.md` §6, including against the stolen-Viewer
case that guarantee exists to cover. Signing the role would not help: a viewer
holds `K_auth` and can sign anything with it.

So `K_auth` authenticates **only** the two bootstrap calls that establish a
device. Each device generates its own random 32-byte key at that moment,
registers it in the bootstrap-authenticated body, and signs everything
afterwards with that key. The server stores the key on the device row and reads
the role **from that row** — the client never asserts a role. Device keys, like
`K_auth`, decrypt nothing.

### Canonical string and header

```
canonical = METHOD + "\n" + PATH + "\n" + TIMESTAMP + "\n" + PRINCIPAL + "\n" + lowercase-hex(SHA-256(body))
mac       = lowercase-hex(HMAC-SHA256(key, canonical))
header    = Authorization: CribWire-HMAC <pairingId>:<principal>:<timestamp>:<mac>
```

- `PRINCIPAL` is the literal string `bootstrap` for `POST /v1/pairings` and
  `POST /v1/pairings/:id/claim`, which are signed with `K_auth`. For every other
  authenticated request it is the calling device's UUID, signed with that
  device's own key.
- `METHOD` uppercase; `PATH` is the path only (no scheme/host/query — query
  strings are not used on authenticated endpoints in v1).
- `TIMESTAMP` is Unix time in seconds as a decimal string; the server rejects
  requests outside a ±60 s window.
- An empty or absent body hashes the empty string.
- WebSocket upgrades authenticate with the same header (PATH is the WS path
  without query), always with a device principal.
- The server MUST compare MACs in constant time, MUST replay-check
  `(pairingId, mac)` within the timestamp window, and MUST record the nonce only
  *after* the MAC verifies.

`POST /v1/pairings` is self-authenticating: the body carries the `kAuth` it is
signed with, and the header's `pairingId` MUST equal the body's. This proves
possession of the uploaded key, not device identity; abuse is bounded by the
per-IP rate limit and the pairing TTL.

## REST bodies

All bodies are JSON with the exact field names below. Binary values are base64
(standard, padded). Unknown response fields MUST be ignored by clients so the
server can add fields without breaking them; unknown *request* fields are
rejected. Timestamps are RFC 3339 UTC strings.

### `POST /v1/pairings` — camera creates a pairing (principal `bootstrap`)

```jsonc
// request
{ "pairingId": "<uuid>", "kAuth": "<base64, 32 bytes>",
  "deviceKey": "<base64, 32 bytes>",           // camera's own key
  "apnsToken": "<hex>", "apnsEnvironment": "sandbox" | "production" }
// 201
{ "pairingId": "<uuid>", "deviceId": "<uuid>", "role": "camera",
  "status": "pending", "ttlSeconds": 600, "expiresAt": "<rfc3339>" }
```

### `POST /v1/pairings/:id/claim` — viewer claims (principal `bootstrap`)

```jsonc
// request
{ "deviceKey": "<base64, 32 bytes>",           // viewer's own key
  "apnsToken": "<hex>", "apnsEnvironment": "sandbox" | "production" }
// 201
{ "pairingId": "<uuid>", "deviceId": "<uuid>", "role": "viewer",
  "status": "active", "claimedAt": "<rfc3339>" }
```

### `DELETE /v1/pairings/:id` — camera revokes the pairing → `204`, empty body

### `DELETE /v1/pairings/:id/viewers/:deviceId` — camera evicts a viewer → `204`

### `PUT /v1/devices/token` — rotate this device's APNs token

```jsonc
// request  (principal = the device itself; deviceId is NOT in the body)
{ "apnsToken": "<hex>", "apnsEnvironment": "sandbox" | "production" }
// 204, empty body
```

### `POST /v1/pairings/:id/turn-credentials` — either role

```jsonc
// request: empty body
// 200
{ "username": "<expiry>:<pairingId>", "credential": "<base64>",
  "ttlSeconds": 3600, "uris": ["turn:…:3478?transport=udp", "turns:…:5349?transport=tcp"] }
```

### `POST /v1/events` — camera posts a sealed detection event

```jsonc
// request
{ "ciphertext": "<sealed envelope, base64>" }
// 202, empty body
```

### Errors

```jsonc
{ "error": "<stable machine-readable code>", "message": "<human-readable>" }
```

Status codes: `400` malformed, `401` any authentication failure (a single status
so existence is not leaked, with distinct `error` codes), `403` role or pairing
mismatch, `404` unknown pairing/device, `409` viewer limit, duplicate pairing id,
or revoked, `410` expired pairing, `413` oversized body, `429` rate limited
(with `Retry-After`).

## Test vectors

`shared/test-vectors/cribwire-v1.json` contains: HKDF outputs for the fixed root
secret `000102…1f`, the SAS code, a QR example, the fixed device keys and ids,
sealed envelopes for a signaling blob and an event, and four complete auth
examples — both bootstrap calls plus a camera-principal and a viewer-principal
request. Both test suites load this file directly — do not copy values into
source code.
