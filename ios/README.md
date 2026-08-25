# CribWire — iOS

One SwiftUI app target (iOS 26+), backed by `CribWireKit`, a local Swift package
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
│   │   ├── Nursery/         Music, light, picture-brightness and alert command
│   │   │                    vocabulary, plus the playlist shortlist
│   │   └── API/             Async REST client and its transport seam
│   └── Tests/               Vector contract tests + state machine + client tests
├── CribWire/                 App target (SwiftUI) — the only app binary
│   ├── App/                 Entry point, app delegate, service graph, config, registry
│   ├── Design/              Palette, type scale, shared components
│   ├── Features/            Role selection, pairing, device list, notifications,
│   │                        streaming, detection, nursery music + light
│   └── Security/            Keychain layer
├── CribWireWidgets/          Widget extension — the Live Activity, and nothing else
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
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO
```

`CribWireKit` also builds and tests on Linux: it imports `CryptoKit` where it
exists and [swift-crypto](https://github.com/apple/swift-crypto) everywhere else,
via `#if canImport(CryptoKit)`. swift-crypto is only linked on non-Apple
platforms (`.when(platforms: [.linux, .windows])`).

## Running the Live Activity

`CribWireWidgets` is a widget extension that contains **only** an
`ActivityConfiguration`. It ships no Home Screen and no Lock Screen widget, and
that is a deliberate product decision, not an omission — see the header of
`CribWireActivityAttributes.swift` for why the payload stays this thin.

It follows that the extension cannot be launched on its own. Xcode's widget Run
action works by asking SpringBoard to place a widget for the extension's bundle
id; with no widget in the bundle, WidgetKit has no descriptors to return and the
run fails:

```
Failed to show Widget 'com.ralphhees.cribwire.CribWire.Widgets' …
SBAvocadoDebuggingControllerErrorDomain Code=1
"Failed to get descriptors for extensionBundleID (com.ralphhees.cribwire.CribWire.Widgets)"
… The request to open "com.apple.springboard" failed.
```

The `CribWireWidgets` scheme in `project.yml` is checked in specifically to
prevent this: it builds the extension but launches the **app**, which is how the
activity is meant to start. To see it:

1. Run the `CribWire` (or `CribWireWidgets`) scheme on a device or simulator.
2. Start a Viewer session — `LiveActivityController.start` is what calls
   `Activity.request`; nothing renders until a real activity exists.
3. Lock the screen, or use the Dynamic Island on a Pro device.

To break on the drawing code in `CribWireLiveActivity.swift`, attach once the
activity is on screen: **Debug ▸ Attach to Process ▸ CribWireWidgets**. It runs
in its own process, so breakpoints hit only after that attach.

If nothing appears at all, it is almost always that Live Activities are switched
off for CribWire in Settings ▸ CribWire. That is what
`ActivityAuthorizationInfo().areActivitiesEnabled` reports,
`LiveActivityController.isAvailable` surfaces, and the app then silently degrades
past by design — a missing Live Activity is never worth an error in front of
someone watching their child.

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
| `CRIBWIRE_TIDAL_CLIENT_ID` | undefined | Leave unset unless this build should offer TIDAL — see below |
| `CRIBWIRE_TIDAL_REDIRECT_URI` | undefined | Only if the TIDAL registration uses something other than `cribwire://tidal-auth` |
| `CRIBWIRE_SPOTIFY_CLIENT_ID` | undefined | Leave unset unless this build should offer Spotify — see below |
| `CRIBWIRE_SPOTIFY_REDIRECT_URI` | undefined | Only if the Spotify registration uses something other than `cribwire://spotify-auth` |

### Music services

Apple Music needs one thing that is not in this repository: the **MusicKit** app
service enabled on the App ID in the Apple Developer portal. Without it
`MusicAuthorization.request()` returns denied with no prompt, which on screen is
indistinguishable from the user refusing. `NSAppleMusicUsageDescription` is already
in `project.yml`; both are required.

TIDAL is implemented through TIDAL's own SDK
(`github.com/tidal-music/tidal-sdk-ios`, products `Auth`, `Player`,
`EventProducer` and `TidalAPI`, all four wired in `project.yml`), because it
permits third-party playback by no other route. What it needs that is not in this
repository is an **application registered at `developer.tidal.com`**, which
supplies two things:

1. a **client id**, set either as `CRIBWIRE_TIDAL_CLIENT_ID` here or — better —
   served by the backend as `TIDAL_CLIENT_ID` through `GET /v1/config`, which
   makes rotating it a configuration change rather than a release. A build with
   neither does not offer TIDAL at all, rather than offering a service nobody
   registered it for;
2. a **redirect URI** listed on that application. The default is
   `cribwire://tidal-auth`, whose scheme `project.yml` registers under
   `CFBundleURLTypes`; a registration that uses something else sets
   `CRIBWIRE_TIDAL_REDIRECT_URI` and adds its scheme there.

The registration also has to carry the scopes `collection.read`,
`playlists.read`, `playback` and `user.read` — `TidalSession` asks for exactly
those and no more, and TIDAL fails the whole authorize request rather than
degrading if one is missing.

There is no client *secret* anywhere in the app, and there must not be: the phone
runs the authorization-code + PKCE flow, which is a public-client flow with no
secret in it. `TIDAL_CLIENT_SECRET` stays in the backend's environment and is
never served to a device.

Spotify is implemented through Spotify's own SDK (`github.com/spotify/ios-sdk`,
product `SpotifyiOS`, wired in `project.yml`) plus the Web API for listing
playlists. It differs from the other two in a way worth knowing before setting it
up: **CribWire does not play the audio.** Spotify permits no third-party app to
play its catalogue, so `SPTAppRemote` drives the Spotify app on the same phone,
which means that phone needs the **Spotify app installed** and the account needs
**Premium**. The Camera says both in as many words on its Music accounts screen.

What it needs that is not in this repository is an **application registered at
`developer.spotify.com`**, supplying:

1. a **client id**, set either as `CRIBWIRE_SPOTIFY_CLIENT_ID` here or — better —
   served by the backend as `SPOTIFY_CLIENT_ID` through `GET /v1/config`, exactly
   like TIDAL's. A build with neither does not offer Spotify at all;
2. a **redirect URI** listed on that application: `cribwire://spotify-auth` by
   default, overridable with `CRIBWIRE_SPOTIFY_REDIRECT_URI`. This one does
   double duty — it is the OAuth callback *and* the URL the Spotify app opens
   CribWire back on after the App Remote hand-off, which is a real
   `application(_:open:)` forwarded by `AppDelegate`.

The scopes asked for are `app-remote-control`, `streaming`,
`playlist-read-private`, `playlist-read-collaborative`, `user-library-read` and
`user-read-private` — the last being what answers whether the account is Premium
before a parent taps play rather than after a room stays silent.

There is no Spotify client secret anywhere, and unlike TIDAL there is none in the
backend either: nothing server-side ever calls Spotify.

`project.yml` also registers `spotify` under `LSApplicationQueriesSchemes`.
Without it iOS answers `canOpenURL(spotify:)` with `false` on a phone that has
the app, and the Camera reports Spotify as permanently unavailable on exactly the
phones where it works.

Signing in happens on the **Camera's own screen**, through
`ASWebAuthenticationSession` — never from a Viewer's tap, for the same reason as
Apple Music's permission prompt. The same screen is where a parent signs *out*
and back in again: see `MusicAccountsView`.

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

- **WebRTC** — wired end to end as of Phase 2: `StreamingEngine` owns the
  factory, `CameraCaptureController` the capture pipeline, and `PeerSession` one
  peer connection each. None of it has ever run — the simulator has no camera —
  so treat every line of the AVFoundation and WebRTC glue as compiled but
  unexercised until it has been on two devices.
- **APNs tokens** — registration happens (the pairing screens ask for permission
  and the token is registered with `POST /v1/pairings` / `.../claim`), but
  rotation through `PUT /v1/devices/token` is not wired yet, so a token that
  changes after pairing goes stale until the pairing is redone. Phase 3.
- **Detection** — wired end to end: `AudioLevelMonitor` feeds the noise detector,
  `CapturerFrameTap` the movement detector, and `DetectionCoordinator` seals what
  they decide with `K_evt` and posts it. Both detectors ship **disabled** and are
  independently toggleable, per `ios-app.md` §2.5. The microphone tap has never
  run on hardware — see the coexistence note in `docs/TASKS.md` Phase 3.
- **Certificate pinning** — built, then deliberately removed. It coupled every
  installed app to the backend's CA, so a CA or intermediate rotation would brick
  the fleet and could only be repaired through App Store review. Because media and
  events are end-to-end encrypted, an attacker with a mis-issued certificate sees
  ciphertext, so system TLS is judged sufficient. Reasoning in
  `docs/specs/security.md` §7; the implementation is in git history if the
  trade-off ever changes.
- **Camera/Viewer home screens** — pairing, device list, live view, dimming,
  battery warnings and audio-only mode are all in. Picture-in-Picture is not —
  see `docs/TASKS.md` Phase 4 for why it was removed after being built.
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
- Music playback on the Camera while it streams: that MusicKit plays through the
  WebRTC audio session at all, and how loud the room actually gets. `.videoChat`
  runs voice processing that both cancels the music out of what the Viewer hears
  (wanted — the point is to hear the child) and can attenuate playback on some
  hardware (not wanted). Nothing about this can be asserted on a build machine.
- The torch as a night light: that it holds at the mapped level for hours without
  iOS shutting it off thermally, that it survives a quality-ladder restart, and that
  it goes out when capture stops.
- That the Camera's system volume actually moves via `MPVolumeView` on current iOS.
  `SystemVolumeController.canSetVolume` reports whether it can, and the Viewer hides
  the slider when it cannot — but which of those happens is a device question.
