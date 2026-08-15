# CribWire — iOS App Specification

Version 0.1 — 2026-08-10 — Status: Draft

## 1. Purpose

CribWire turns two iOS devices into a private baby monitor. One device acts as the
**Camera** (placed in the child's room), the other as the **Viewer** (carried by the
parent). Video and audio stream live from Camera to Viewer with end-to-end encryption,
and the Camera can send push notifications to the Viewer when it detects noise or
movement.

## 2. Roles and core user flows

### 2.1 Role selection

- On first launch the user picks a role: **Camera** or **Viewer**. The role can be
  switched at any time from Settings (a device is never both simultaneously).
- No account or sign-up is required. Identity is established purely by pairing
  (see §2.2 and `security.md`).

### 2.2 Pairing (QR code)

- The Camera device shows a QR code on screen. The Viewer device scans it with its
  camera to pair. The QR code carries the pairing ID, the shared secret from which all
  encryption keys are derived, and the backend URL — see `security.md` §3 for the exact
  payload and key derivation.
- Pairing is complete when both devices show the same 6-digit confirmation code
  (short authentication string) and the user taps **Confirm** on the Viewer.
- Multiple Viewers may pair with one Camera (max 5). Each pairing can be revoked
  individually from the Camera device.
- Paired devices are remembered; keys are stored in the iOS Keychain
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, non-synchronizable so keys never
  enter iCloud Keychain).

### 2.3 Camera mode

- Streams rear (default) or front camera plus microphone audio when at least one
  Viewer is connected; otherwise the capture pipeline runs only for local
  noise/movement detection.
- Screen shows a minimal status view (connection state, number of connected viewers,
  detection status) and dims after 30 s to save battery and avoid lighting the room.
- Night-vision assist: a single **picture brightness** setting (`CameraSensitivity`,
  `0…1`) that the Camera turns into exposure compensation (up to +2 EV), the
  hardware low-light boost where supported, and — in the top half of its range — a
  frame-rate ceiling (20 fps, then 15) so each frame is exposed for longer. It is
  stored on the Camera, applied before the first frame, and re-applied after every
  capture restart, since the adaptive ladder discards the session's exposure
  settings each time it moves a rung. Editable **on the Camera and from a Viewer**
  (§2.4); there is no infrared illuminator, so a room with no light in it at all
  stays black whatever this is set to.
- Runs while locked/backgrounded as far as iOS allows: audio background mode keeps
  noise detection alive in the background; video capture requires the app to be
  foreground (documented limitation — the recommended setup is a dedicated device,
  plugged in, with Guided Access enabled).
- Disables the idle timer, shows a "plug in charger" warning below 20 % battery, and
  sends a low-battery push to Viewers at 15 %.

### 2.4 Viewer mode

- Shows a list of paired Cameras with live connection state, then a full-screen live
  view with: mute/unmute audio, snapshot (saved to app-private storage, not the photo
  library, by default), connection quality indicator, and elapsed-time overlay.
- Audio-only mode: video can be turned off to save bandwidth/battery while keeping
  the audio stream and notifications.
- Talk-back (push-to-talk from Viewer to Camera) — v1.1, not MVP.
- Picture-in-Picture when the app is backgrounded (AVKit PiP with the WebRTC track
  rendered via `AVSampleBufferDisplayLayer`).

### 2.4a Nursery controls — music, light, picture and alerts

The Viewer can act on the room, not only watch it: play music through the Camera's
speaker, switch the Camera's light on, change how bright the picture is, and change
what the Camera raises an alert about. The first two are comforts layered on the
monitor and neither may compromise it — every call in the path is best-effort, and a
music service that hangs or a torch that refuses can never stop the stream.

The last two are **settings rather than actuators**: the Camera stores them, applies
them, and reports them back, so a change made from a Viewer survives a reconnect and
a restart of the Camera. They are reachable from the Viewer for one reason — the
person who discovers that the picture is black, or that the noise threshold is
wrong, is the one being woken by it in another room, holding the Viewer.

**Transport.** Two message types on the existing sealed signaling channel
(`CribWireKit/Nursery`, carried by `SignalingPayload`):

- `control` — Viewer → Camera. Play/pause/toggle, next, previous, volume, choose a
  playlist, switch service, refresh the playlist list; for the light, on/off and
  brightness; the talk-back gain; the picture-brightness boost and its night-boost
  switch; and the complete `DetectionSettings` for the alerts. Every field is
  advisory: the Camera clamps it, may refuse it, and reports what actually happened.
- `nursery` — Camera → Viewer. Music availability, transport state, now-playing,
  volume, the playlist shortlist, the light's availability, on-state and level, the
  picture-brightness state (including whether the phone has hardware low-light
  boost and the exposure compensation it actually accepted), and the alert settings
  the Camera is running — plus whether it failed to open its microphone.

The Viewer holds **no** state of its own — it renders the Camera's report — so a
control can be slow but never wrong. Commands go through the same seal as offers and
ICE, so the server routes ciphertext and never learns that a light was switched on
or which playlist was chosen. The Camera obeys a `control` only from a Viewer whose
session has passed the DTLS fingerprint check (`security.md` §4), and only a Camera
ever acts on one.

**Playlists.** The Viewer is offered a shortlist, never a library: what CribWire
itself has played on this Camera (most recent first), then the service's recently
played, then favourites/library playlists, deduplicated and capped at
`PlaylistShortlist.limit`. The cap and the name-length cap are also what keep the
state message inside the 16 KiB signaling frame. Playlist names travel sealed and
are never sent to the backend.

**Services.** Apple Music is implemented through MusicKit's
`ApplicationMusicPlayer` — not `SystemMusicPlayer`, which would take over the Music
app on the Camera's own account. It needs the MusicKit service enabled on the App ID
and `NSAppleMusicUsageDescription`; authorisation is requested **from the Camera's
own screen only**, because a system prompt raised by a tap on another device is a
prompt nobody is standing in front of. TIDAL is behind the same `MusicProvider`
protocol and is offered only when a client id is compiled in — see
`TidalMusicProvider.swift` for what completing it requires (TIDAL permits third-party
playback only through its own SDK, under partner credentials).

**Volume** means the Camera device's output volume. Neither service exposes a
per-app gain, and for a phone playing into a room the device's volume is what
"turn it down in there" means anyway.

**Light** is the torch on the Camera's back camera, driven by the capture
controller because it owns the capture device. The Viewer's slider tops out at half
hardware power: full power is painful in a cot and is thermally unsustainable for a
night. The reported on-state is read from `isTorchActive`, not from intent, so a
torch iOS switched off for heat shows as off. It is switched off — and the intent
cleared — whenever capture stops, so a light can never come back on by itself.

**Picture brightness** is `CameraSensitivity` (§2.3), edited with the same view on
both devices. A command changes only the field it carries, so moving the slider
cannot also flip the night-boost switch. It is offered even while the Camera is
idle: the value is stored and applied at the next start, unlike the torch, which
needs a live capture session to reach.

**Alerts** carry the whole `DetectionSettings` value rather than a delta. A Viewer
edits what the Camera last reported, so what it sends is a complete picture the
Camera clamps on arrival; two Viewers editing at once end on whichever arrived last
rather than on a mixture of both. The movement watch area is drawn only on the
Camera — a Viewer has no preview to draw it over — but it rides through a Viewer's
edit untouched. The Camera persists the settings to the same store its own alerts
screen edits, hands them to the detection coordinator, and reports them back; the
alerts screen re-reads the store so a remote change cannot be silently written over
by the next local edit.

### 2.5 Noise and movement notifications

- Detection runs **on the Camera device** — raw audio/video never reaches the backend,
  so detection cannot happen server-side.
- **Noise detection**: `AVAudioEngine` tap computing A-weighted RMS over 500 ms
  windows; an event fires when the level exceeds the configured threshold for ≥ 1 s.
  Sensitivity presets: Low (−20 dBFS), Medium (−30 dBFS), High (−40 dBFS), plus a
  custom slider with a live level meter for calibration.
- **Movement detection**: frame differencing on downscaled (160×120) luma frames at
  2 fps; an event fires when the changed-pixel ratio exceeds the sensitivity threshold
  in ≥ 3 consecutive frames. A region-of-interest rectangle can be drawn to ignore
  e.g. a window with moving curtains.
- Both detectors can be enabled/disabled independently by the user (this is the
  "option to enable" — both default to **off** until explicitly turned on).
- Editable from **either device**: the Camera's own alerts screen, or a Viewer's room
  controls (§2.4a). Sliders bind to a `sensitivityFraction` (`0…1`, 1 = fires on the
  quietest room / smallest movement) rather than to the stored threshold, which runs
  the other way — −60 dBFS is the *most* sensitive noise setting.
- Debounce: after an event, the same detector stays silent for a cooldown period
  (default 3 min, configurable 1–10 min) to avoid notification storms.
- On an event the Camera calls the backend `POST /v1/events` endpoint; the backend
  fans the event out to all paired Viewers via APNs. The push payload contains only
  the event type and timestamp, encrypted with the pairing key (see `security.md` §5);
  the Viewer app decrypts it. There is no Notification Service Extension: decryption
  runs in the app, so the specific text ("Noise detected") is shown when the app is
  in the foreground and is filled in for notifications delivered earlier the next
  time the app is opened. While the app is closed iOS shows the generic
  "Activity detected" the server sent, because nothing may rewrite a push before
  display except an extension.
- Tapping the notification deep-links straight into the live view of that Camera.

## 3. Streaming design (client side)

- **Transport**: WebRTC (libwebrtc via the `WebRTC` SPM/CocoaPods binary), one peer
  connection per Camera↔Viewer pair. The Camera is the offerer.
- **Signaling**: WebSocket to the backend signaling server. All signaling payloads
  (SDP, ICE candidates) are encrypted and authenticated with the pairing-derived
  signaling key before they are sent, so the backend relays opaque blobs only.
- **Connectivity**: ICE with host + STUN candidates; TURN (from the backend, §backend
  spec) as relay fallback. On the same Wi-Fi the stream is fully local and works
  without internet once signaling has completed.
- **Media**: H.264 hardware encode (VideoToolbox via libwebrtc), 640×480 @ 15 fps
  default, adaptive up to 1280×720 @ 30 fps on good links and down to 320×240 on poor
  ones (standard WebRTC bandwidth estimation). Opus audio, 24 kbps mono, with
  high-pass filter and AGC enabled.
- **Encryption**: DTLS-SRTP for transport, plus pairing-key authentication of the
  DTLS fingerprints exchanged over the encrypted signaling channel — the backend can
  never man-in-the-middle the stream. Details in `security.md` §4.
- **Reconnect**: exponential backoff (1 s → 30 s cap) on network changes.
- **Recovery budget**: a Viewer returning to a paired Camera sees video within
  **10 s** (`StreamingEngine.recoveryBudget`). Two things exist to hold that: the
  Camera warms its capture pipeline when a Viewer *appears*, not after the
  handshake verifies, so restarting `AVCaptureSession` runs in parallel with
  negotiation rather than in series after it; and a Viewer that has signalling but
  no offer re-announces itself at half the budget, restarting the backoff ladder
  rather than waiting out a delay that has already grown past it.
  (`NWPathMonitor`), with ICE restart rather than full re-signaling where possible.
- Target glass-to-glass latency: < 500 ms on LAN, < 1.5 s over the internet.

## 4. Technical choices

| Area | Choice |
|---|---|
| Language / UI | Swift 5 language mode on the Swift 6.2 toolchain, SwiftUI (iOS 26 minimum) |
| Architecture | MVVM + a `StreamingEngine` and `DetectionEngine` service layer; Swift Concurrency (`async/await`, actors) |
| Streaming | libwebrtc (`stasel/WebRTC` binary distribution or Google pod) |
| Capture | AVFoundation (`AVCaptureSession`, `AVAudioEngine`) |
| QR display / scan | Core Image (`CIQRCodeGenerator`) / `DataScannerViewController` (VisionKit) |
| Crypto | CryptoKit (X25519, HKDF-SHA256, ChaCha20-Poly1305); keys in Keychain |
| Push | UNUserNotificationCenter; payload decryption in the app (single target, no extension) |
| Persistence | Small on-device store (SwiftData or plist) for pairings metadata; secrets only in Keychain |
| Testing | XCTest unit tests for crypto/pairing/detection logic; XCUITest smoke flow; detection tuned against recorded fixture clips |

Required `Info.plist` entries: `NSCameraUsageDescription`,
`NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription` (+ Bonjour services
if local discovery is added later), background modes: `audio`, `voip` (evaluate;
`voip` requires CallKit usage — if not used, audio-only background mode).

## 5. Non-functional requirements

- **Privacy**: no media or detection data stored server-side; no analytics SDKs in
  MVP; App Privacy label limited to "Identifiers (device token)". GDPR: no personal
  data beyond APNs tokens, which are deleted on unpair.
- **Battery**: Camera mode with screen dimmed shall consume < 20 %/hour on an
  iPhone XR-class device; capture pipeline stops entirely when no viewer is connected
  and both detectors are off.
- **Resilience**: Camera mode recovers automatically from interruptions
  (`AVCaptureSession` interruption notifications, audio session interruptions, route
  changes) without user interaction.
- **Accessibility**: VoiceOver labels on all controls; Dynamic Type in all
  non-video UI.
- **Localization**: English + Dutch at launch.

## 6. Out of scope (MVP)

Cloud recording/history, more than 5 viewers, Android/web clients, lullaby player,
temperature/humidity integrations, talk-back (v1.1), Apple Watch app.
