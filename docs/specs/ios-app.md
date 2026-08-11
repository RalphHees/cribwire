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
- Night-vision assist: low-light boost via `AVCaptureDevice.isLowLightBoostEnabled`
  where supported, and an optional exposure/ISO bias slider.
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
- Debounce: after an event, the same detector stays silent for a cooldown period
  (default 3 min, configurable 1–10 min) to avoid notification storms.
- On an event the Camera calls the backend `POST /v1/events` endpoint; the backend
  fans the event out to all paired Viewers via APNs. The push payload contains only
  the event type and timestamp, encrypted with the pairing key (see `security.md` §5);
  a Notification Service Extension on the Viewer decrypts it for display.
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
- **Reconnect**: exponential backoff (1 s → 30 s cap) on network changes
  (`NWPathMonitor`), with ICE restart rather than full re-signaling where possible.
- Target glass-to-glass latency: < 500 ms on LAN, < 1.5 s over the internet.

## 4. Technical choices

| Area | Choice |
|---|---|
| Language / UI | Swift 5.10+, SwiftUI (iOS 16 minimum) |
| Architecture | MVVM + a `StreamingEngine` and `DetectionEngine` service layer; Swift Concurrency (`async/await`, actors) |
| Streaming | libwebrtc (`stasel/WebRTC` binary distribution or Google pod) |
| Capture | AVFoundation (`AVCaptureSession`, `AVAudioEngine`) |
| QR display / scan | Core Image (`CIQRCodeGenerator`) / `DataScannerViewController` (VisionKit) |
| Crypto | CryptoKit (X25519, HKDF-SHA256, ChaCha20-Poly1305); keys in Keychain |
| Push | UNUserNotificationCenter + Notification Service Extension for payload decryption |
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
