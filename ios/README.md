# KidsCam — iOS

SwiftUI app (iOS 16+) plus a Notification Service Extension, backed by
`KidsCamKit`, a local Swift package holding everything that is pure logic:
crypto, the wire formats from [`shared/protocol.md`](../shared/protocol.md), the
pairing state machine, and the REST client.

## Layout

```
ios/
├── project.yml              XcodeGen spec — the .xcodeproj is generated, not committed
├── KidsCamKit/              Local Swift package: crypto + protocol + pairing logic
│   ├── Sources/KidsCamKit/
│   │   ├── CryptoCore/      Root secret, HKDF, SAS, sealed envelope
│   │   ├── Protocol/        QR payload, KidsCam-HMAC authenticator, roles
│   │   ├── Pairing/         Camera + Viewer pairing state machines
│   │   └── API/             Async REST client and its transport seam
│   └── Tests/               Vector contract tests + state machine + client tests
├── KidsCam/                 App target (SwiftUI)
│   ├── App/                 Entry point, service graph, config, pairing registry
│   ├── Design/              Palette, type scale, shared components
│   ├── Features/            Role selection, pairing (camera + viewer), device list
│   └── Security/            Keychain layer
├── NotificationService/     Notification Service Extension (Phase 3 skeleton)
└── KidsCamTests/            App-target unit tests
```

## Generate and build

XcodeGen is required; the `.xcodeproj` is intentionally not in version control.

```sh
brew install xcodegen          # or: mint install yonaskolb/XcodeGen
cd ios
xcodegen generate             # writes KidsCam.xcodeproj
open KidsCam.xcodeproj
```

Command line (what CI runs on a macOS runner):

```sh
# 1. Pure-logic tests — no simulator, no signing, fastest signal.
swift test --package-path ios/KidsCamKit

# 2. App + extension build and app-target tests.
cd ios && xcodegen generate
xcodebuild test \
  -project ios/KidsCam.xcodeproj \
  -scheme KidsCam \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  CODE_SIGNING_ALLOWED=NO
```

`KidsCamKit` also builds and tests on Linux: it imports `CryptoKit` where it
exists and [swift-crypto](https://github.com/apple/swift-crypto) everywhere else,
via `#if canImport(CryptoKit)`. swift-crypto is only linked on non-Apple
platforms (`.when(platforms: [.linux, .windows])`).

## Test vectors

`KidsCamKit/Tests/KidsCamKitTests/Resources/kidscam-v1.json` is a **symlink** to
[`shared/test-vectors/kidscam-v1.json`](../shared/test-vectors/kidscam-v1.json),
and the Xcode test target references the same file directly. Nothing is copied:
the iOS and backend suites must never be able to drift onto different vectors.
The suite reproduces, byte for byte, the HKDF outputs, the SAS code, both sealed
envelopes (plus tamper, wrong-key, wrong-role and wrong-pairing rejection), both
`KidsCam-HMAC` examples, and the QR payload round trip.

Changing any format means regenerating the vector file and updating both
implementations in one change set — see the note at the top of
`shared/protocol.md`.

## Configuration placeholders

`project.yml` carries placeholders that must be replaced before a signed build:

| Setting | Placeholder | Notes |
|---|---|---|
| `DEVELOPMENT_TEAM` | empty | Apple Developer team ID |
| `PRODUCT_BUNDLE_IDENTIFIER` | `example.kidscam.*` | app, extension, tests |
| `KIDSCAM_APP_GROUP` | `group.example.kidscam.shared` | app group, shared with the extension |
| `KIDSCAM_KEYCHAIN_ACCESS_GROUP` | same as the app group | see below |
| `KIDSCAM_API_BASE_URL` | `https://api.kidscam.example` | Camera-side default only |

The app group doubles as the Keychain access group: `kSecAttrAccessGroup`
accepts an app-group identifier, so no separate `keychain-access-groups`
entitlement is needed.

### Which key lives where

`KeychainStore` has two scopes, and the split is deliberate:

- **`.appPrivate`** (the app's own default access group) — the root secret `S`,
  `K_auth`, `K_sig`, `K_sas`. The extension cannot read these.
- **`.sharedWithExtension`** (the app group) — `K_evt` only. That is all the
  Notification Service Extension needs to decrypt an event payload
  (`security.md` §5), so it is all it gets.

Every item is written with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
`kSecAttrSynchronizable = false`: unreadable while locked, never in iCloud
Keychain, never in an encrypted backup.

## What is stubbed for Phase 2 (and later)

- **WebRTC** — `stasel/WebRTC` is wired into the app target's dependency graph so
  resolution and linking are proven, but **no source file imports it yet**. The
  `StreamingEngine`, the Camera-as-offerer flow, ICE/TURN and DTLS fingerprint
  binding are all Phase 2.
- **Signaling WebSocket** — the Camera currently has no way to learn that a
  Viewer claimed the pairing; `security.md` §3.3 step 2 delivers that over the
  authenticated socket, which is Phase 2 backend work. Until then
  `CameraPairingViewModel.handleViewerClaim(pairingID:viewerDeviceID:)` is the
  seam that event will drive.
- **Sealed signaling** — `SealedEnvelope` is complete and vector-tested, but the
  `seq`/replay layer around it (`security.md` §4) is Phase 2.
- **APNs tokens** — the pairing view models take an `apnsToken` parameter and
  currently pass an empty string. Push registration, the Notification Service
  Extension's decryption, and `PUT /v1/devices/token` wiring are Phase 3.
- **Detection** — noise and movement detection, their settings and the event
  pipeline are Phase 3. Both detectors ship **disabled** and are independently
  toggleable, per `ios-app.md` §2.5.
- **Certificate pinning** — `URLSessionTransport` is the single place SPKI
  pinning will be added (Phase 4).
- **Camera/Viewer home screens** — Phase 1 versions cover pairing and the device
  list. The monitoring pulse, dimming, battery warnings, live view, PiP and
  audio-only mode are Phase 2.
- **Localization** — strings are inline English. EN/NL localization is Phase 4.

## Needs a physical device to verify

Nothing in the automated suite can cover these; they are two-device, on-hardware
checks:

- End-to-end QR pairing between two phones, and matching SAS codes on both
  screens (Milestone M1).
- QR scanning through `DataScannerViewController` (VisionKit needs an A12 device;
  the `AVCaptureMetadataOutput` fallback needs an older one, e.g. an iPhone 8).
- Screen-capture protection: that the QR really is excluded from screenshots and
  screen recordings, and that `ScreenCaptureMonitor` hides it during recording,
  AirPlay mirroring and QuickTime capture.
- Keychain access groups: that the extension can read `K_evt` and cannot read the
  root secret. Access groups do not behave the same way in the Simulator.
- Pairing survival across app restarts and device reboots
  (`WhenUnlockedThisDeviceOnly` items are unavailable until first unlock).
