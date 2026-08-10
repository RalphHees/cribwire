# KidsCam v1 — Normative Wire Formats

This file pins the exact byte-level encodings that are cross-implemented by the
iOS app (CryptoKit) and the backend (Node crypto). `docs/specs/security.md`
defines the design; this file defines the bits. Both implementations MUST
reproduce `shared/test-vectors/kidscam-v1.json` byte-for-byte, and any change
here requires regenerating the vectors and updating both sides in one change set.

## Key derivation

`HKDF-SHA256(ikm = S, salt = empty, info, length = 32)` with `info` strings
exactly: `kidscam/v1/auth`, `kidscam/v1/sig`, `kidscam/v1/event`,
`kidscam/v1/sas` (UTF-8, no terminator).

## SAS confirmation code

First 4 bytes of `K_sas` interpreted as a big-endian unsigned 32-bit integer,
`mod 1_000_000`, left-padded with zeros to 6 digits.

## QR payload

`kidscam://pair?v=1&id=<pairingId>&s=<S>&api=<url>` where `id` is the lowercase
UUID, `s` is base64url without padding, `api` is the percent-encoded base URL.
Unknown query parameters MUST be ignored; a `v` other than `1` MUST be rejected.

## Sealed envelope (signaling blobs and event ciphertext)

```
sealed = base64( nonce(12) || ChaCha20-Poly1305-ct || tag(16) )
```

- Nonce: 12 random bytes per message (fixed only in test vectors).
- AAD (UTF-8): signaling → `<pairingId>|<senderRole>` where role is `camera` or
  `viewer`; events → `<pairingId>|event`.
- Standard base64 with padding.
- Plaintext is a UTF-8 JSON document; its schema may evolve, the envelope may not.

## Request authentication (`KidsCam-HMAC`)

```
canonical = METHOD + "\n" + PATH + "\n" + TIMESTAMP + "\n" + lowercase-hex(SHA-256(body))
mac       = lowercase-hex(HMAC-SHA256(K_auth, canonical))
header    = Authorization: KidsCam-HMAC <pairingId>:<role>:<timestamp>:<mac>
```

- `METHOD` uppercase; `PATH` is the path only (no scheme/host/query… query
  strings are not used on authenticated endpoints in v1).
- `TIMESTAMP` is the Unix time in seconds, as a decimal string; the server
  rejects requests older/newer than 60 s.
- An empty or absent body hashes the empty string.
- WebSocket upgrades authenticate with the same header on the upgrade request
  (PATH is the WS path without query).
- Server compares MACs in constant time and replay-checks `(pairingId, mac)`
  within the timestamp window.

## Test vectors

`shared/test-vectors/kidscam-v1.json` contains: HKDF outputs for the fixed root
secret `000102…1f`, the SAS code, a QR example, sealed envelopes for a
signaling blob and an event, and two complete auth examples (POST with body,
GET without). Both test suites load this file directly — do not copy values
into source code.
