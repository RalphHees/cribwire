# CribWire — Task List

Derived from `docs/specs/ios-app.md`, `docs/specs/backend.md`, `docs/specs/security.md`.
Order within a phase is roughly dependency order; phases 2–4 each end in a testable
milestone.

## Phase 0 — Project foundations

- [x] Create Xcode project (SwiftUI, iOS 16 min) with app target + Notification
      Service Extension target; shared app group + Keychain access group
      — via `ios/project.yml` (XcodeGen); groups are build-setting placeholders
- [ ] Add WebRTC dependency (binary SPM package) and verify a trivial peer connection
      compiles on device — dependency declared; first real use lands in Phase 2
- [ ] Repo hygiene: SwiftLint/SwiftFormat, backend ESLint/Prettier, PR template
      — backend lint/format and PR template done; SwiftLint/SwiftFormat still missing
- [x] CI: GitHub Actions — iOS build + unit tests (macOS runner), backend lint +
      tests, Docker image build
- [x] Backend scaffold: Node 22/TypeScript, Fastify + `ws`, Postgres + Redis via
      docker-compose, migrations tooling, `/v1/health` + `/v1/version`
- [ ] Provisioning: Apple Developer setup, APNs `.p8` key, sandbox push working
      against a hello-world payload — **blocked: needs a human with an Apple
      Developer account** (see `.github/workflows/release-testflight.yml` preflight)

## Phase 1 — Pairing & security core

**Backend**
- [x] Postgres schema (`pairings`, `devices`) + daily hard-delete job for
      revoked/expired rows
- [x] `POST /v1/pairings` (create, 10-min TTL), `POST /v1/pairings/{id}/claim`
      (max 5 viewers), `DELETE` pairing / viewer
- [x] HMAC request authentication middleware (60 s timestamp window,
      Redis nonce cache) + rate limiting (per-IP and per-pairing)
- [x] `PUT /v1/devices/token` (APNs token rotation, 410-cleanup handler)

**iOS**
- [x] `CryptoCore` module: CSPRNG secret generation, HKDF key derivation
      (`K_auth/K_sig/K_evt/K_sas`), ChaCha20-Poly1305 seal/open with AAD —
      with unit tests and test vectors shared with the backend repo
- [x] Keychain storage (ThisDeviceOnly, non-sync) + app-group access for the
      notification extension; wipe-on-unpair and first-launch cleanup
- [x] Role selection UI (Camera / Viewer) + pairing state machine
- [x] Camera: QR generation (2-min regeneration, screen-capture protection) +
      pairing registration call
- [x] Viewer: QR scanning (VisionKit), key derivation, claim call
- [x] SAS confirmation screen on both devices; pairing list UI with revoke

**Protocol revision 1.1** (arose during Phase 1, see `shared/protocol.md`)
- [x] Per-device authentication keys — `K_auth` is pairing-wide, so it could prove
      pairing membership but not device identity, letting any viewer claim
      `role=camera` and revoke the pairing. Roles now come from the server-side
      device record; the principal is signed.
- [x] Pin every REST request/response body (1.0 left them to prose and the two
      implementations diverged: `ttlSeconds` vs `expiresInSeconds`)

**Milestone M1**: two physical devices pair via QR, show matching SAS codes, and the
pairing survives app restarts; revocation works. Crypto unit tests green on CI.
→ *Code complete and CI green. The two-device parts (matching SAS on two phones,
Keychain survival across reboot) are inherently device-only and remain unverified.*

## Phase 2 — Live streaming

**Backend** — complete
- [x] WebSocket signaling endpoint: HMAC-authenticated upgrade, opaque-blob routing
      envelope (16 KiB cap), presence events, heartbeat/idle handling
- [x] Redis pub/sub bridge for cross-instance message routing
- [x] coturn deployment (ephemeral `use-auth-secret` credentials) +
      `POST /v1/pairings/{id}/turn-credentials`

**iOS**
- [x] Sealed signaling layer: ChaCha20-Poly1305 blobs under `K_sig`, seq/replay
      protection, role AAD binding (unit-tested against fixture transcripts)
- [x] `StreamingEngine`: peer connection setup, Camera-as-offerer flow, ICE with
      STUN + TURN fallback — `PeerSession` + TURN fetch
- [x] DTLS fingerprint binding: carry `a=fingerprint` in sealed blobs, verify peer
      cert post-handshake, hard-fail on mismatch (tested with a tampering fake server)
- [ ] Camera capture pipeline: AVCaptureSession + audio, H.264/Opus config,
      adaptive resolution, low-light boost, capture-only mode when no viewer
- [ ] Viewer live view: video rendering, mute, snapshot, connection-quality
      indicator; audio-only mode
- [x] Reconnect logic: backoff/ICE-restart policy in `CribWireKit` (`ReconnectPolicy`);
      `NWPathMonitor` wiring still to do
- [ ] Camera status screen: dimming, idle-timer disable, battery warnings,
      Guided Access setup instructions

> **Remaining for Phase 2** is app-layer AVFoundation and UI only — the capture
> pipeline, the viewer live view and the camera status screen. The protocol,
> signaling, fingerprint-binding and quality/reconnect logic are done and tested.

**Milestone M2**: live video+audio Camera→Viewer on LAN and across networks (TURN),
< 1.5 s latency, surviving a Wi-Fi→cellular switch. Verified MITM resistance test:
a modified signaling server cannot complete a handshake.

## Phase 3 — Detection & push notifications

**Backend** — complete
- [x] `POST /v1/events`: ciphertext passthrough, per-pairing rate limit,
      APNs HTTP/2 fan-out to all viewers, `mutable-content` payload format
- [x] APNs error handling (token cleanup on 410), delivery metrics

**iOS (Camera)**
- [x] Noise detector: A-weighted RMS, threshold presets + custom slider with live
      level meter, ≥ 1 s trigger window — decision logic done and unit-tested;
      the AVAudioEngine tap that feeds it is not wired yet
- [x] Movement detector: 160×120 luma diff, consecutive-frame trigger,
      region-of-interest editor — same split: logic + editor done, capture feed not
- [x] Detection settings: independent enable toggles (default off), sensitivity,
      cooldown (1–10 min); background-audio mode keeps noise detection alive
- [ ] Event pipeline: seal with `K_evt` → `POST /v1/events`; low-battery event
- [ ] Detector tuning against recorded fixture clips (crying, silence, pets,
      curtain movement) with target false-positive/negative rates

**iOS (Viewer)**
- [ ] Notification permission flow + settings deep-link when denied
- [x] Notification Service Extension: decrypt with `K_evt` from app-group Keychain,
      localized alert text, generic fallback on decrypt failure
- [ ] Notification tap → deep-link into that Camera's live view

**Milestone M3**: with the Viewer app closed, clapping near the Camera produces a
decrypted "Noise detected" push within 5 s; payload verified opaque in APNs traffic.

## Phase 4 — Hardening, polish, release

- [x] CI surfaces Swift compile diagnostics instead of burying them in the
      xcodebuild transcript
- [ ] Certificate pinning (SPKI + backup pin) for API/WSS
- [ ] Battery profiling of Camera mode (< 20 %/h target) + capture teardown checks
- [ ] Interruption recovery: calls, Siri, route changes, backgrounding matrix
- [ ] Picture-in-Picture on Viewer
- [ ] Accessibility (VoiceOver, Dynamic Type) + EN/NL localization
- [ ] Security review: sealed-signaling design review, dependency audit,
      external pen test; fix findings
- [ ] Backend production deploy: EU region, TLS/HSTS, Prometheus + alerting,
      secrets manager, Terraform, load test (10 k WS / 1 k TURN targets)
- [ ] Ops runbook + on-call alerts (APNs failures, TURN bandwidth, error rates)
- [ ] App Store: privacy labels, screenshots, review notes (two-device testing
      instructions), TestFlight beta with ≥ 10 external testers
- [ ] Public 1.0 release

## v1.1 backlog (not scheduled)

- [ ] Talk-back (Viewer → Camera push-to-talk)
- [ ] Automatic session-key rotation (X25519 ratchet in sealed signaling)
- [ ] Apple Watch companion for notifications + audio level
- [ ] Live Activity showing connection/detection state
- [ ] Local-network-only mode (Bonjour discovery, works fully offline)
