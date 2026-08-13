# CribWire — Task List

Derived from `docs/specs/ios-app.md`, `docs/specs/backend.md`, `docs/specs/security.md`.
Order within a phase is roughly dependency order; phases 2–4 each end in a testable
milestone.

## Phase 0 — Project foundations

- [x] Create Xcode project (SwiftUI, iOS 16 min) — via `ios/project.yml`
      (XcodeGen). One app target: the Notification Service Extension was merged
      into the app, which also removed the shared app group and Keychain access
      group it existed for
- [ ] Add WebRTC dependency (binary SPM package) and verify a trivial peer connection
      compiles on device — dependency declared; first real use lands in Phase 2
- [ ] Repo hygiene: SwiftLint/SwiftFormat, backend ESLint/Prettier, PR template
      — backend lint/format and PR template done; SwiftLint/SwiftFormat still missing
- [x] CI: GitHub Actions — iOS build + unit tests (macOS runner), backend lint +
      tests, Docker image build
- [x] Backend scaffold: Node 22/TypeScript, Fastify + `ws`, Postgres + Redis via
      docker-compose, migrations tooling, `/v1/health` + `/v1/version`
- [x] Provisioning: Apple Developer setup, APNs `.p8` key, sandbox push working
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
- [x] Keychain storage (ThisDeviceOnly, non-sync) in the app's own access group —
      no app group, since nothing outside the app reads a key; wipe-on-unpair and
      first-launch cleanup
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

- [x] Camera learns of a claim over its WebSocket (`security.md` §3.3 step 2).
      The claim is a REST call the Camera never sees, so without this it sat on
      the QR screen for ever and the SAS never appeared on it. The Camera now
      holds a signaling socket per live candidate and treats a viewer's
      `peer-online` as the claim; the Viewer connects right after claiming, which
      is what raises that event.

**Milestone M1**: two physical devices pair via QR, show matching SAS codes, and the
pairing survives app restarts; revocation works. Crypto unit tests green on CI.
→ *Code complete and CI green. The two-device parts (matching SAS on two phones,
Keychain survival across reboot) are inherently device-only and remain unverified.*

> **Known gap:** `PUT /v1/devices/token` exists on the backend and in `APIClient`,
> but nothing in the app calls it, so a rotated APNs token never reaches the
> server. Scheduled with the Phase 3 event pipeline.

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
      STUN + TURN fallback. Owns the `RTCPeerConnectionFactory`, drives
      offer/answer/ICE through the sealed channel, and holds one `PeerSession` per
      viewer
- [x] DTLS fingerprint binding: carry `a=fingerprint` in sealed blobs, verify peer
      cert post-handshake, hard-fail on mismatch. Both halves are now enforced by
      the engine: a mismatched SDP is refused before DTLS starts, and the
      negotiated certificate is re-checked before any frame is shown
- [x] Camera capture pipeline: `RTCCameraVideoCapturer` + audio track, hardware
      H.264, adaptive resolution driven by `AdaptiveQualityController`, low-light
      boost, capture-only mode when no viewer and a detector needs the frames
- [x] Viewer live view: Metal video rendering, mute, snapshot to Photos,
      connection-quality indicator, audio-only mode. Video stays covered until the
      fingerprint check passes
- [x] Reconnect logic: backoff/ICE-restart policy in `CribWireKit`
      (`ReconnectPolicy`), now wired to `NWPathMonitor` — a path change triggers an
      ICE restart, a dead socket a full rebuild, and a fingerprint mismatch neither
- [x] Camera status screen: dimming, idle-timer disable, battery warnings,
      Guided Access setup instructions

**Milestone M2**: live video+audio Camera→Viewer on LAN and across networks (TURN),
< 1.5 s latency, surviving a Wi-Fi→cellular switch. Verified MITM resistance test:
a modified signaling server cannot complete a handshake.
→ *Code complete; app, Kit and backend suites green. Everything in the milestone
statement itself is two-device, on-hardware behaviour and is **unverified**: no
video has been observed flowing, no latency measured, no network switch survived,
and the MITM test needs a modified server run against real devices. The simulator
has no camera, so the capture pipeline in particular has never executed.*

> **What is actually asserted by tests**: the sealed-signaling protocol, the
> fingerprint value type, the quality ladder, the reconnect ladder, the presence
> parsing, the link-quality mapping and the snapshot frame tap. The AVFoundation
> and WebRTC glue compiles and is exercised by nothing.

## Phase 3 — Detection & push notifications

**Backend** — complete
- [x] `POST /v1/events`: ciphertext passthrough, per-pairing rate limit,
      APNs HTTP/2 fan-out to all viewers, generic-alert payload format
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
- [ ] Notification permission flow + settings deep-link when denied — permission is
      requested from the pairing screens; the denied-state UI is still missing
- [x] In-app payload decryption (`PushNotificationCoordinator`): decrypt with
      `K_evt` from the Keychain, specific alert text, generic fallback on any
      decrypt failure. Replaces the Notification Service Extension
- [ ] Notification tap → deep-link into that Camera's live view — the tap already
      resolves to a pairing (`pendingPairingID`); the live view it should open is
      Phase 2

**Milestone M3**: clapping near the Camera produces a push on the Viewer within 5 s;
payload verified opaque in APNs traffic. With the Viewer app closed the alert reads
"Activity detected" and resolves to "Noise detected" once the app is opened — with
no Notification Service Extension nothing may rewrite a push before iOS displays it,
and the server cannot read the event to describe it itself.

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
