# CribWire — Security & Pairing Specification

Version 0.1 — 2026-08-10 — Status: Draft

## 1. Security goals

1. **End-to-end confidentiality**: only devices that took part in the physical QR
   pairing can decrypt the video/audio stream and the notification payloads. The
   backend (signaling, TURN, push) and any network observer see ciphertext only.
2. **Mutual authentication**: Camera and Viewer are certain they are talking to the
   device that displayed / scanned the QR code — the backend cannot insert itself as
   a man in the middle even if fully compromised.
3. **Least data**: the server stores only what routing and push delivery require
   (pairing ID, an authentication key, APNs tokens).
4. **Revocability**: unpairing a viewer immediately and permanently cuts its access.

Threat model: honest-but-curious to fully malicious backend operator; passive and
active network attackers; a lost/stolen Viewer device (mitigated by revocation and
Keychain protection). Out of scope: a compromised (jailbroken/malware-infected)
paired device, and physical access to an unlocked device.

## 2. Why the QR code is the trust anchor

The QR code is displayed on the Camera's screen and scanned by the Viewer's camera —
a physical, out-of-band channel the backend never touches. The secret it carries is
therefore shared **only** between the two devices, and every key in the system is
derived from it. Sharing the stream with someone means letting them scan the code in
person; there is no way to grant access through the server.

## 3. Pairing protocol

### 3.1 QR payload

```
cribwire://pair?v=1
  &id=<pairingId, UUIDv4>
  &s=<S, 32 random bytes, base64url>     ← root secret, CSPRNG (SecRandomCopyBytes)
  &api=<backend base URL>
```

The Camera generates `id` and `S` fresh for every pairing attempt, registers the
pairing with the backend (uploading only `id` and the derived `K_auth`, never `S`),
then renders the QR. The QR is regenerated (new `S`) every 2 minutes while displayed
and the pairing expires server-side after 10 minutes if unclaimed. The payload is
never written to disk, the pasteboard, or logs.

### 3.2 Key derivation (HKDF-SHA256, per pairing)

```
K_auth  = HKDF(S, info="cribwire/v1/auth",  32)  → API/WS HMAC authentication (shared with server)
K_sig   = HKDF(S, info="cribwire/v1/sig",   32)  → seals signaling blobs (never leaves devices)
K_evt   = HKDF(S, info="cribwire/v1/event", 32)  → seals push notification payloads (never leaves devices)
K_sas   = HKDF(S, info="cribwire/v1/sas",   32)  → 6-digit confirmation code shown on both screens
```

`S` and all derived keys are stored in the iOS Keychain with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and are excluded from iCloud Keychain
sync and device backups. `K_auth` is the only key the server ever learns; possession
of `K_auth` proves membership of the pairing but decrypts nothing.

### 3.3 Claim and confirmation

1. Viewer scans QR → derives keys → calls `POST /v1/pairings/{id}/claim`
   authenticated with `K_auth`, registering its APNs token.
2. Camera is notified over its WebSocket; both devices display the 6-digit SAS
   derived from `K_sas` (+ pairing ID). The user visually compares and confirms on
   the Viewer. This guards against QR substitution/shoulder-scan attacks.
3. On confirmation the pairing is `active`. A Viewer that fails to claim within the
   QR TTL must rescan a fresh code.

## 4. Stream encryption (E2E)

WebRTC media is always encrypted with **DTLS-SRTP** between the two peers. The known
weakness is that a malicious signaling server could substitute its own DTLS
fingerprints and MITM the handshake. CribWire closes that hole in two layers:

1. **Sealed signaling**: every signaling message (SDP offers/answers, ICE
   candidates) is encrypted and authenticated with ChaCha20-Poly1305 under `K_sig`
   before it enters the WebSocket, with the pairing ID and sender role bound as AAD
   and a per-message random 96-bit nonce plus a monotonic `seq` to reject replays
   and reordering attacks. The server routes envelopes; it cannot read or forge
   their contents.
2. **Fingerprint binding**: the `a=fingerprint` (SHA-256 of the DTLS certificate)
   travels inside the sealed blob. After the DTLS handshake, each side checks the
   peer certificate against the sealed fingerprint and hard-fails the connection on
   mismatch.

Result: a fully compromised backend or TURN server can drop or delay traffic
(availability) but cannot decrypt or inject media (confidentiality/integrity). TURN
relays SRTP ciphertext only.

Media therefore never needs a second application-layer encryption pass; the E2E
property comes from binding DTLS to the QR-derived keys.

## 5. Push notification payload encryption

- Event payloads (`{type: noise|motion|low_battery, ts}`) are sealed with
  ChaCha20-Poly1305 under `K_evt` (random nonce, pairing ID as AAD) on the Camera
  before upload; the backend and Apple see only the ciphertext and a generic
  localizable alert key.
- The Viewer app decrypts the payload itself, with `K_evt` from its own Keychain
  access group. Decryption failure — no key, wrong pairing, tampered bytes — →
  generic "Activity detected" text, never an error leaking key state, and the four
  failure modes must be indistinguishable.
- There is no Notification Service Extension, so there is no second process and no
  shared app group: `K_evt` never leaves the app's private access group. The
  trade-off is timing, not confidentiality — a push that arrives while the app is
  closed is displayed with the generic text and is rewritten with the specific one
  when the app next opens, since only an extension may rewrite a push before it is
  displayed.

## 6. Key lifecycle

- **Rotation**: `S` is per pairing; re-pairing (rescanning) replaces all keys.
  A yearly in-app prompt suggests re-pairing. v1.1: automatic session-key rotation
  via X25519 ratchet inside the sealed signaling channel.
- **Revocation**: `DELETE` on the pairing removes `K_auth` and tokens server-side —
  a revoked Viewer can no longer authenticate to signaling/TURN or receive pushes.
  Because it still holds old keys, the Camera also discards the pairing locally and
  refuses its blobs (`seq`/role checks), and a new QR pairing generates fresh keys.
- **Deletion**: unpairing or app deletion wipes Keychain items
  (`SecItemDelete` on unpair; Keychain items do not survive app re-install usage via
  access-group cleanup on first launch).

## 7. Implementation requirements & review checklist

- All randomness from `SecRandomCopyBytes` / CryptoKit; no custom crypto primitives —
  CryptoKit only (X25519, HKDF-SHA256, ChaCha20-Poly1305, HMAC-SHA256).
- Constant-time comparison for all MAC/SAS checks (`ContiguousBytes` comparison via
  CryptoKit, not `==` on arrays where timing matters server-side; Node:
  `crypto.timingSafeEqual`).
- **Certificate pinning: deliberately not implemented.** Earlier revisions of this
  spec required SPKI pinning for the API/WSS connections. It was built, then
  removed: the operational cost is a hard coupling between the server's CA and
  every installed app, where a CA or intermediate rotation bricks the fleet and can
  only be repaired through App Store review — a multi-week path for a device
  families rely on nightly.
  The risk this accepts is bounded by the rest of this document. Media is
  end-to-end encrypted (§4) and event payloads are sealed under `K_evt` (§5), so an
  attacker holding a mis-issued certificate for the backend host sees ciphertext,
  not streams or alerts. They could disrupt pairing setup and the REST metadata
  path; they could not watch a nursery or read an alert. Standard TLS with system
  trust is judged sufficient for that surface.
  Revisit if the backend moves to a CA with a stable, self-controlled leaf key,
  which removes the rotation hazard that motivated the removal.
- No secrets in logs, crash reports, analytics, screenshots (screen-capture
  protection on the QR view via `UITextField.isSecureTextEntry` layer trick or
  `preventsCapture`), or the iOS app switcher snapshot.
- Jailbreak/debug detection is explicitly **not** relied upon; security must hold
  without it.
- Threat-model review + external pen test before public App Store release; the
  sealed-signaling protocol gets a dedicated design review (§4 is the highest-risk
  component).
