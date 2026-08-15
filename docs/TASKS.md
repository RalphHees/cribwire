# CribWire — Task List

Derived from `docs/specs/ios-app.md`, `docs/specs/backend.md`, `docs/specs/security.md`.
Order within a phase is roughly dependency order; phases 2–4 each end in a testable
milestone.

## Phase 0 — Project foundations

- [x] Create Xcode project (SwiftUI, iOS 26 min) — via `ios/project.yml`
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
      level meter, ≥ 1 s trigger window. Fed by `AudioLevelMonitor`, an
      `AVAudioEngine` input tap that runs the A-weighting on the audio thread
- [x] Movement detector: 160×120 luma diff, consecutive-frame trigger,
      region-of-interest editor. Fed by `CapturerFrameTap`, which sits between the
      capturer and the WebRTC video source so detection sees the encoded frames
      without a second camera client
- [x] Detection settings: independent enable toggles (default off), sensitivity,
      cooldown (1–10 min); background-audio mode keeps noise detection alive
- [x] Event pipeline: `DetectionCoordinator` seals with `K_evt` and posts to
      `/v1/events`; low-battery event driven from the Camera screen's battery
      readings through `LowBatteryMonitor`
- [~] Detector tuning: `DetectionScenarioTests` covers the named false-positive
      cases (silence, transients, intermittent pet noise, background hum, dawn
      light, auto-exposure jumps, a curtain inside and outside the region) with
      **synthesised** signals. Tuning against *recorded* clips of a real baby, pet
      and curtain — and a measured false-positive/negative rate — is still open and
      needs media the repo does not have.

**iOS (Viewer)**
- [x] Notification permission flow + settings deep-link when denied. iOS shows the
      prompt once, so a denial is surfaced on the Viewer's home screen with a link
      into Settings, and the status is re-read on every return to the foreground
- [x] In-app payload decryption (`PushNotificationCoordinator`): decrypt with
      `K_evt` from the Keychain, specific alert text, generic fallback on any
      decrypt failure. Replaces the Notification Service Extension
- [x] Notification tap → deep-link into that Camera's live view. `pendingPairingID`
      now drives a navigation destination and is cleared on dismissal; an alert
      naming a pairing this device no longer holds gets an explanation rather than
      a blank screen

**Milestone M3**: clapping near the Camera produces a push on the Viewer within 5 s;
payload verified opaque in APNs traffic. With the Viewer app closed the alert reads
"Activity detected" and resolves to "Noise detected" once the app is opened — with
no Notification Service Extension nothing may rewrite a push before iOS displays it,
and the server cannot read the event to describe it itself.
→ *Code complete; all suites green. **Unverified**, and for the same reason as M2:
every clause of that milestone is on-device behaviour. Nothing has clapped, no push
has been observed in APNs traffic, and the microphone tap has never run.*

> **The risk worth knowing about**: `AudioLevelMonitor` opens the microphone with
> `AVAudioEngine` while WebRTC's `RTCAudioSession` also holds it for streaming.
> Whether both can hold the input at once depends on the device and the route, and
> it cannot be tested in a simulator. `start()` therefore reports failure instead
> of assuming success, and the Camera status screen shows "Microphone unavailable"
> rather than looking like a quiet room. If it turns out the two cannot coexist,
> the fix is to feed the detector from WebRTC's audio device module instead — the
> detector itself takes a level and does not care where it came from.

## Phase 4 — Hardening, polish, release

- [x] CI surfaces Swift compile diagnostics instead of burying them in the
      xcodebuild transcript
- [x] Certificate pinning — **implemented, then deliberately removed.** It pinned
      the CA (a Let's Encrypt leaf key rotates every 60–90 days, so a leaf pin
      would have bricked the fleet at the first renewal), but even at the CA it
      coupled every installed app to the backend's certificate chain: a CA or
      intermediate rotation would break every device and could only be repaired
      through App Store review.
      The accepted risk is bounded, because TLS is not what protects the product.
      Media is end-to-end encrypted and events are sealed under `K_evt`, so an
      attacker holding a mis-issued certificate sees ciphertext — they could
      disrupt pairing setup and REST metadata, not watch a nursery. Reasoning
      recorded in `docs/specs/security.md` §7; implementation is in git history.
- [ ] Battery profiling of Camera mode (< 20 %/h target) + capture teardown checks
      — **needs a physical device**; nothing here can measure it
- [x] Interruption recovery: calls, Siri, route changes, backgrounding.
      `AudioInterruptionMonitor` separates "resume permitted" from "interruption
      over but someone else still owns the session", reacts to a disconnected
      output device, and rebuilds on a media-services reset. An interruption that
      ends while the app is backgrounded is recovered on the next foreground,
      because the resume notification is never delivered in that case.
- [x] Picture-in-Picture on Viewer. WebRTC renders into nothing AVKit understands,
      so frames are converted to `CMSampleBuffer`s and enqueued on an
      `AVSampleBufferDisplayLayer`. Backgrounding keeps the stream alive **only**
      while PiP is active — otherwise the Viewer still tears down.
- [x] Accessibility + EN/NL localization. **168 of 168 extracted strings
      translated**, verified by diffing the compiler's `.stringsdata` against the
      String Catalog rather than by eye. Permission prompts are localised too, via
      `InfoPlist.xcstrings`.
      `Theme.Typography` now declares faces against system text styles instead of
      fixed point sizes, so the app responds to Dynamic Type at all — it did not
      before. Default sizes shift a point or two as a result; scaling is worth
      more than matching the mock at one text size. The SAS digits stay fixed on
      purpose: six digits must not wrap.
      Components taking `String` (`KCSecurityNote`, `KCPill`, `KCRoleCard`) now
      take `LocalizedStringKey` — as `String` they silently skipped the catalog.
- [~] Security review: dependency audit **clean** — `npm audit` reports 0
      vulnerabilities with and without dev dependencies; the Swift graph is three
      packages (`swift-crypto` 3.15.1, `swift-asn1` 1.7.1, `stasel/WebRTC`), all
      first-party Apple or a binary distribution of libwebrtc. The
      sealed-signaling design review and the external pen test are **not done**
      and cannot be — both need people, not tooling.
- [ ] Backend production deploy: EU region, TLS/HSTS, Prometheus + alerting,
      secrets manager, Terraform, load test (10 k WS / 1 k TURN targets)
      — **not started**; needs cloud credentials this environment does not have
- [x] Ops runbook + on-call alerts — `docs/ops/RUNBOOK.md`. Incident playbooks,
      the metrics worth paging on, and the two failure modes that do not look like
      outages: silent APNs failure (video fine, alerts dead) and a CA change
      (breaks every installed app, unfixable server-side).
- [~] App Store: privacy labels (`docs/appstore/PRIVACY-LABELS.md`) and review
      notes (`docs/appstore/REVIEW-NOTES.md`) written, including the two-device
      testing instructions and the likeliest-rejection response. Screenshots and
      the TestFlight beta need a human with an Apple Developer account and two
      physical devices.
- [ ] Public 1.0 release

## Phase 5 — Second-device experience

Promoted from the v1.1 backlog. These five share a theme: the Viewer stops being a
passive window and the pairing stops depending on the internet.

- [x] **iPad interface** — `TARGETED_DEVICE_FAMILY: "1,2"`, plus upside-down
      orientation, which a tablet in a stand needs and a phone does not. Layouts
      cap at `Theme.Metrics.readableWidth` and centre rather than stretching: a
      full-width iPad column turns a two-sentence security note into one very long
      line, which is the text a user most needs to actually read. Video stays
      full-bleed; only the controls are constrained.
- [x] **Viewer sees the Camera's battery** — a `status` payload on the sealed
      signalling channel, so the server never learns it. Sent on every reading and
      again the moment a Viewer verifies, otherwise a newly-joined Viewer shows
      "unknown" until the level next changes — hours, on a charging Camera. Shown
      as nothing rather than as "unknown": an empty gauge on a baby monitor reads
      as bad news. Only an *uncharging* Camera is coloured.
- [x] **Talk-back (Viewer → Camera push-to-talk)** — the Viewer's audio track is
      attached after the offer is applied and before the answer is built, so in
      Unified Plan it reuses the receive-only transceiver the offer created and
      the answer comes back `sendrecv` with no follow-up renegotiation. The track
      lives in the SDP permanently but **disabled**, so pressing is instant, and
      the button is held rather than toggled — a nursery microphone left open by
      accident is the one failure this feature must not have.
- [x] **Live Activity showing connection/detection state** — `CribWireWidgets`,
      a widget extension (ActivityKit renders out of process, so unlike the
      notification-decryption case it cannot live in the app). It reports that
      monitoring is running, the link state and the Camera's battery, and
      deliberately **never what was detected**: this is drawn on a locked screen
      anyone in the room can see, and "Noise detected at 03:14" is a statement
      about someone's child. "Watching" means verified, not merely connected.
- [x] **Local-network-only mode (Bonjour, fully offline)** — pairing *and*
      streaming with no backend reachable at all. A toggle on the Camera's pairing
      screen emits a QR with **no `api` parameter**, and that absence is what marks
      the pairing local for good; a *malformed* `api` stays an error, so a damaged
      scan can never silently become a different security posture.
      The two things the server used to provide are replaced rather than emulated:
      device ids are minted locally (offline an id is an address, not a
      credential), and a Viewer dialling in over Bonjour *is* the claim, so no
      presence event is needed. Each side introduces itself with a sealed `hello`
      whose sender id rides **inside** the seal.
      `LocalPeerSocket` implements `SignalingSocket`, so `SignalingClient` and the
      whole of `StreamingEngine` run unchanged over the direct link — sealing,
      sequence checks and role AAD binding all still apply. There is no
      `CribWire-HMAC` because there is no server to authenticate to; possession of
      the QR secret is the entire authentication, which is strictly stronger than
      the transport auth it replaces. A device on the same Wi-Fi that never scanned
      the code cannot produce one readable message. No STUN or TURN is fetched:
      both exist to cross the internet, and there is none on this path.
      Tested: `LocalFraming` reassembly (11 tests over the chunk boundaries a real
      network produces, including byte-at-a-time delivery and oversized announced
      lengths) and the QR's local-only encoding.
      **The trade, stated plainly**: no APNs, so a Viewer that leaves the house
      gets no alerts. The toggle says so.

**Milestone M5**: an iPad Viewer on the same Wi-Fi as an iPhone Camera pairs with
the backend switched off, shows the Camera's battery, talks back, and keeps a Live
Activity current on the Lock Screen.
→ *All five code-complete; Kit (189) and app (30) suites green, app builds for
iPhone and iPad. **Unverified on hardware**, for the same reason as M2 and M3:
battery reporting, talk-back audio, the Live Activity and Bonjour discovery are all
two-device behaviours, and no simulator can exercise them. What tests assert is the
framing layer, the QR encoding and the payload schema.*

## Phase 6 — Nursery controls (music and light)

- [x] **Sealed control channel.** Two message types on the existing signaling
      channel (`CribWireKit/Nursery`): `control` (Viewer → Camera) and `nursery`
      (Camera → Viewer). Same seal, same sequence ledger, same role AAD as offers
      and ICE, so the server routes ciphertext and never learns that a light was
      switched on or which playlist was picked. `control` is the only message in
      the protocol that *acts* on a device, so it carries two checks rather than
      one: only a Camera acts on it, and only from a Viewer whose session has
      passed the DTLS fingerprint check.
      Every field is forward-tolerant — an action a Camera has never heard of
      decodes as `.unknown` and costs that one command, not the message.
- [x] **Viewer controls.** Play/pause, previous, next, volume, playlist picker and
      a light switch with a brightness slider, behind one "Room" button on the live
      screen. The Viewer holds **no** state of its own: every control draws the
      Camera's last report, so a button can be slow but never wrong. Sliders report
      at a fixed rate while dragged and exactly once on release.
- [x] **Playlist shortlist** — the "recently used or favourites" rule. What
      CribWire has played *on this Camera* first, then the service's recently
      played, then library/favourites; deduplicated, merged, capped at 12. The cap
      and the 60-character name cap are also what keep the state message inside the
      16 KiB signaling frame, which is asserted rather than assumed.
- [x] **Apple Music** through `ApplicationMusicPlayer` — not `SystemMusicPlayer`,
      which would take over the Music app on the Camera's own account and leave a
      Viewer's pause still paused in the morning. Authorisation is requested from
      the Camera's own screen only: a system prompt raised by a tap on another
      device is a prompt nobody is standing in front of.
- [x] **Camera light** — the torch, driven by `CameraCaptureController` because it
      owns the capture device. The Viewer's slider tops out at half hardware power
      (full power is painful in a cot and iOS shuts it off thermally within
      minutes), the reported on-state is read from `isTorchActive` rather than from
      intent, the level is re-asserted after every quality-ladder restart, and it is
      switched off — with the intent cleared — whenever capture stops.
- [ ] **TIDAL** — control plane done, playback engine not. TIDAL permits
      third-party playback only through its own SDK under partner credentials from
      `developer.tidal.com`; everything above the playback call is already
      provider-agnostic and works. `TidalMusicProvider.swift` documents exactly what
      finishing it involves, and a build with no client id does not offer the
      service rather than offering one that plays nothing.

**Milestone M6**: a Viewer plays a lullaby on the Camera, skips a track, turns the
volume down and switches the nursery light on, and both screens agree throughout.
→ *Code-complete for Apple Music and the light; Kit and app suites cover the wire
format, the shortlist rule, the recents history, the frame-size bound and the torch
level mapping. **Unverified on hardware**: whether MusicKit plays at all through the
WebRTC audio session and how loud the room gets, whether the torch holds at the
mapped level for hours, and whether `MPVolumeView` still moves the system volume on
current iOS. See "Needs a physical device to verify" in `ios/README.md`.*

## v1.1 backlog (not scheduled)

- [x] Viewer can control the played audio at the camera. volume up, down, play pause, previous and next. → Phase 6
- [x] Option to cancel out the played audio to don't hear that. → the Camera's
      `.videoChat` audio session runs voice processing on the input, so the music
      it plays is largely cancelled out of what the Viewer hears. How complete that
      is in a real room is a two-device question.
- [ ] Apple Watch companion for notifications + audio level
- [ ] Automatic session-key rotation (X25519 ratchet in sealed signaling)
