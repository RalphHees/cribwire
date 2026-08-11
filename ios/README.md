# CribWire — iOS

One SwiftUI app target (iOS 16+), backed by `CribWireKit`, a local Swift package
holding everything that is pure logic: crypto, the wire formats from
[`shared/protocol.md`](../shared/protocol.md), the pairing state machine, and the
REST client.

There is no Notification Service Extension — decrypting an event push is done by
the app itself, in `CribWire/Features/Notifications`. See
[Notifications](#notifications) for what that changes.

## Layout

```
ios/
├── project.yml              XcodeGen spec — the .xcodeproj is generated, not committed
├── CribWireKit/              Local Swift package: crypto + protocol + pairing logic
│   ├── Sources/CribWireKit/
│   │   ├── CryptoCore/      Root secret, HKDF, SAS, sealed envelope
│   │   ├── Protocol/        QR payload, CribWire-HMAC authenticator, roles
│   │   ├── Pairing/         Camera + Viewer pairing state machines
│   │   └── API/             Async REST client and its transport seam
│   └── Tests/               Vector contract tests + state machine + client tests
├── CribWire/                 App target (SwiftUI) — the only app binary
│   ├── App/                 Entry point, app delegate, service graph, config, registry
│   ├── Design/              Palette, type scale, shared components
│   ├── Features/            Role selection, pairing, device list, notifications
│   └── Security/            Keychain layer
└── CribWireTests/            App-target unit tests
```

## Generate and build

XcodeGen is required; the `.xcodeproj` is intentionally not in version control.

```sh
brew install xcodegen          # or: mint install yonaskolb/XcodeGen
cd ios
xcodegen generate             # writes CribWire.xcodeproj
open CribWire.xcodeproj
```

Command line (what CI runs on a macOS runner):

```sh
# 1. Pure-logic tests — no simulator, no signing, fastest signal.
swift test --package-path ios/CribWireKit

# 2. App build and app-target tests.
cd ios && xcodegen generate
xcodebuild test \
  -project ios/CribWire.xcodeproj \
  -scheme CribWire \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  CODE_SIGNING_ALLOWED=NO
```

`CribWireKit` also builds and tests on Linux: it imports `CryptoKit` where it
exists and [swift-crypto](https://github.com/apple/swift-crypto) everywhere else,
via `#if canImport(CryptoKit)`. swift-crypto is only linked on non-Apple
platforms (`.when(platforms: [.linux, .windows])`).

## Test vectors

`CribWireKit/Tests/CribWireKitTests/Resources/cribwire-v1.json` is a **symlink** to
[`shared/test-vectors/cribwire-v1.json`](../shared/test-vectors/cribwire-v1.json),
and the Xcode test target references the same file directly. Nothing is copied:
the iOS and backend suites must never be able to drift onto different vectors.
The suite reproduces, byte for byte, the HKDF outputs, the SAS code, both sealed
envelopes (plus tamper, wrong-key, wrong-role and wrong-pairing rejection), both
`CribWire-HMAC` examples, and the QR payload round trip.

Changing any format means regenerating the vector file and updating both
implementations in one change set — see the note at the top of
`shared/protocol.md`.

## Configuration placeholders

`project.yml` carries placeholders that must be replaced before a signed build:

| Setting | Placeholder | Notes |
|---|---|---|
| `DEVELOPMENT_TEAM` | empty | Apple Developer team ID |
| `PRODUCT_BUNDLE_IDENTIFIER` | `example.cribwire.*` | app and tests — one app bundle id |
| `CRIBWIRE_API_BASE_URL` | `https://api.cribwire.example` | Camera-side default only |

### Where the keys live

All of them in the app's own Keychain access group: the root secret `S`,
`K_auth`, `K_sig`, `K_evt`, `K_sas`, and this device's API identity. There is no
app group and no `keychain-access-groups` entitlement, because no other binary
reads a CribWire key — `K_evt` used to sit in a shared group only so the
Notification Service Extension could open a push, and that extension is now part
of the app (`security.md` §5).

Every item is written with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and
`kSecAttrSynchronizable = false`: unreadable while locked, never in iCloud
Keychain, never in an encrypted backup.

## Notifications

`PushNotificationCoordinator` owns permission, APNs registration and the
decryption that used to be an extension's whole job. What that costs, and why it
is only about timing:

| App state | What the user sees |
|---|---|
| Foreground | The push is opened and re-posted with the real text — "Noise detected" |
| Background / closed | iOS shows the server's generic "Activity detected"; nothing is running that could rewrite it |
| Reopened | Notifications delivered earlier are rewritten in place with their real text, silently |
| Tapped | The pairing is resolved from the payload (`pendingPairingID`); the live view it should open is Phase 2 |

Only an extension may rewrite a push before iOS displays it, and the backend
cannot describe an event it cannot read, so the closed-app row above is the
inherent trade-off of a single target. Every failure to open a payload — no key,
wrong pairing, tampered bytes, unknown shape — falls back to the generic text and
is indistinguishable from the others.

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
- **APNs tokens** — registration happens (the pairing screens ask for permission
  and the token is registered with `POST /v1/pairings` / `.../claim`), but
  rotation through `PUT /v1/devices/token` is not wired yet, so a token that
  changes after pairing goes stale until the pairing is redone. Phase 3.
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
- Push delivery end to end: that a sealed event arrives, that the app's decrypted
  text replaces the generic alert in the foreground, and that reopening the app
  rewrites one delivered while it was closed. APNs does not work in the
  Simulator without a real token.
- Pairing survival across app restarts and device reboots
  (`WhenUnlockedThisDeviceOnly` items are unavailable until first unlock).
