# App Store review notes — CribWire

Paste the "For the reviewer" section into App Store Connect → App Review
Information → Notes. The rest of this file is context for whoever prepares the
submission.

This section is structured to answer, point by point, the "Guideline 2.1 -
Information Needed" request Apple sends on a new-app submission. Two items need
filling in by hand before each submission — marked **[FILL IN]** below — because
they depend on the actual test session, not on the app's design.

---

## For the reviewer

**1. Screen recording.** **[FILL IN: attach or link a recording, made on a
physical device on the current iOS release, that shows: launch → role selection
→ Camera pairing QR → Viewer scanning it → the six-digit confirmation on both
screens → live video/audio → a detection alert arriving. Record both devices,
either as two clips or side by side.]** There is no account/login, paid content,
or user-generated content to additionally capture — see point 4. The one
sensitive-capability prompt is Camera/Microphone/Notifications/Local Network
permissions during pairing and Camera mode; make sure the recording shows those
system prompts appearing, not just the app screens around them.

**2. Devices and OS tested.** **[FILL IN: list the physical iPhone/iPad models
and iOS versions this build was tested on, e.g. "iPhone 15 Pro, iOS 26.0" and
"iPad Air (5th gen), iOS 26.0". Include the oldest and newest supported OS —
the app's floor is iOS 26.0 (`IPHONEOS_DEPLOYMENT_TARGET`), and it ships for
both iPhone and iPad (`TARGETED_DEVICE_FAMILY: "1,2"`).]**

**3. Purpose and audience.** CribWire is a private baby monitor: it turns two
iOS devices into a Camera (placed in the child's room) and a Viewer (with the
parent), streaming live video and audio end-to-end encrypted between them, with
optional on-device noise/movement detection that sends a push alert to the
Viewer. It solves the problem commercial baby monitors create — a
manufacturer-operated cloud that can see into a family's home — by routing
video peer-to-peer and deriving all encryption keys from a QR code that never
leaves the two devices, so the operator holds no key and cannot access the
stream. Target audience: parents and caregivers of infants and young children
who want a monitor without a subscription or a cloud video feed.

**4. Setup instructions / demo access.** No account, login, or demo credentials
exist or are needed — there is no server-side user to authenticate against.
Trust is established by physically scanning a QR code between two devices, so
review requires **two physical devices**, not a login. Full steps:

1. On device A, choose **Camera** → **Pair a Viewer**. A QR code appears.
2. On device B, choose **Viewer** → **Scan a Camera**. Point it at device A's screen.
3. Both devices show the **same six digits** — a security confirmation, not a code to type. Compare them and tap **Codes match** on the Viewer.
4. On device A tap **Start the camera**; on device B tap **Watch**. Live video and audio flow directly between the devices.

If only one device is available, pairing cannot complete and the live view
cannot be reached, but role selection, the Camera's QR screen, the Viewer's
scanner, alert settings, and the paired-devices list are all reachable and
testable without a second device.

**5. External services.** Two, both used only to establish and deliver the
peer-to-peer connection — neither can read app content:
- **coturn (TURN/STUN relay)** — used only when the two devices cannot reach
  each other directly (e.g. restrictive NAT/Wi-Fi); it forwards
  end-to-end-encrypted media packets (SRTP ciphertext) it cannot decrypt.
- **Apple Push Notification service (APNs)** — delivers "activity detected"
  alerts to the Viewer. The payload is ciphertext the server itself cannot
  read; the alert text APNs and Apple see is the constant string "Activity
  detected."

No third-party authentication provider, no payment processor, no analytics or
crash-reporting SDK, and no AI/ML service. The only client-side third-party
code is `stasel/WebRTC` (Google's libwebrtc) and Apple's own `swift-crypto`.

**6. Regional differences.** None. The app functions identically in every
region — same features, same on-device processing, no region-gated content or
functionality. It ships localized in English and Dutch (168/168 strings,
including every permission prompt), which changes language only, not behavior.

**7. Regulated industry / protected material.** Not applicable. CribWire is not
a medical device and makes no medical claims (it is a monitor, not a health or
safety-certified device), holds no health data, and processes no protected
third-party material. It collects no personal data at all — see
[`PRIVACY-LABELS.md`](PRIVACY-LABELS.md) — so there is no account data or
minors' personal information handled that would implicate COPPA or similar
regimes; the video/audio path is peer-to-peer and end-to-end encrypted and
never reaches our servers in readable form.

---

**Both devices must be on a network that allows peer-to-peer connections.** Office
or guest Wi-Fi that blocks UDP will fall back to our TURN relay; if that is also
blocked, the connection will not establish. Testing on ordinary Wi-Fi or cellular
works.

### Why the app asks for each permission

| Permission | Asked when | Why |
|---|---|---|
| Camera | Pairing, and Camera mode | Scanning the QR code, and capturing the room to stream |
| Microphone | Camera mode | Streaming room audio, and detecting noise on-device |
| Local Network | First peer connection | Direct device-to-device streaming so video stays in the home |
| Notifications | Pairing | Delivering "activity detected" alerts to the Viewer |
| Photos (add only) | Tapping Snapshot | Saving a still from the live view. The app never reads the library |

### Two behaviours that may look like bugs

**1. Notification text changes after opening the app.** A delivered alert reads
"Activity detected"; once opened it becomes "Noise detected" or "Movement
detected". This is intentional and unavoidable. Alert contents are encrypted with
a key only the paired devices hold, so neither our server nor Apple can describe
the event. The app decrypts it and updates the text once it runs.

**2. The Camera's QR code changes every two minutes.** Also intentional. Each code
carries a fresh encryption key, limiting how long a code that was photographed or
observed remains usable. Codes already scanned stay valid for ten minutes so a
pairing in progress is not interrupted.

### Background behaviour

The Camera declares the `audio` background mode. It is used for two things: keeping
the audio stream alive while streaming, and keeping on-device noise detection
running so a Viewer is alerted while the Camera's screen is off. The app does not
play silent audio to stay alive and does not run background location or fetch.

---

## Notes for whoever submits (not for the reviewer)

### Age rating

4+. No user-generated content that is shared publicly, no web view, no chat, no
purchases, no third-party advertising.

### Screenshots

**Two sets are required, iPhone and iPad**, because the app ships for both
(`TARGETED_DEVICE_FAMILY: "1,2"`). App Store Connect rejects any other size at
upload rather than resizing it:

| Slot | Portrait | Landscape | Max |
|------|----------|-----------|-----|
| iPhone 6.5" / 6.7" | 1242 × 2688 or 1284 × 2778 | 2688 × 1242 or 2778 × 1284 | 10 |
| iPad 12.9" / 13" | 2048 × 2732 or 2064 × 2752 | 2732 × 2048 or 2752 × 2064 | 10 |

The rendered mockups can be uploaded as they are:
[`docs/design/screenshots/`](../design/screenshots/) is the iPhone set at
1242 × 2688 and [`docs/design/screenshots/ipad/`](../design/screenshots/ipad/)
is the iPad set at 2048 × 2732. `docs/design/render-screenshots.sh --display`
takes `6.5`, `6.7`, `12.9` or `13` if a slot wants one of the other sizes.

Real device captures are the alternative — an iPhone 11 Pro Max or XS Max
captures at 1242 × 2688, an iPhone 12/13/14 Plus or Pro Max at 1284 × 2778, an
iPad Pro 12.9" at 2048 × 2732 and the M4 13" at 2064 × 2752. Do not scale a
capture from another device up or down to reach those numbers: it lands soft,
and Apple sees it.

The live-view screenshots must not show a real, identifiable child. Use a doll, a
pet, or an empty cot. Required set, with the mockup that matches each — the same
six in both slots, since the iPad renders are the same screens:

1. Role selection ("Secure babyphone next to your crib") — `1-role-selection`
2. Camera showing the pairing QR — `3-pairing-qr`
3. The six-digit confirmation on both devices — `5-pairing-confirm`
4. Viewer live view with the connection indicator — `9-viewer-live`
5. Alert settings, showing both detectors off by default — `7-camera-alerts`
6. A notification on the lock screen — `13-lockscreen`

Thirteen screens are rendered but at most ten may be uploaded per slot, so the
remaining seven are reference, not a queue to work through.

The iPad shots are not stretched phone screens: they show what the app actually
does on a regular-width screen — content capped at `Theme.Metrics.readableWidth`
and centred, video full-bleed. A reviewer comparing the listing to the build
will see the same layout.

### Localization

The app ships **English and Dutch**. Both are complete: 168 of 168 strings are
translated, including every permission prompt. If App Store Connect metadata is
supplied in English only, the Dutch store listing will fall back to English while
the app itself is fully Dutch — worth avoiding.

### The likeliest rejection, and the answer

Guideline 2.1 ("Information Needed"), because a reviewer with one device cannot
reach the main feature and the Notes field didn't yet pre-empt their checklist.
This has already happened once — Apple's request maps directly onto the seven
numbered points in "For the reviewer" above. Filling in the two **[FILL IN]**
items and pasting that whole section into the Notes field before submitting is
the fix; don't wait for the request to arrive again.

### Pre-submission checklist

- [ ] `CRIBWIRE_API_BASE_URL` points at production, not staging
- [ ] `aps-environment` is `production` in the release configuration
- [ ] `DEVELOPMENT_TEAM` and the bundle id are the real ones, not the placeholders in `ios/project.yml`
- [ ] Export-compliance answer confirmed with counsel (`PRIVACY-LABELS.md`)
- [ ] Privacy labels entered as "Data Not Collected" across every category
- [ ] iPhone screenshots are 1242 × 2688 / 2688 × 1242 or 1284 × 2778 / 2778 × 1284
- [ ] iPad screenshots are 2048 × 2732 / 2732 × 2048 or 2064 × 2752 / 2752 × 2064
- [ ] Two-device demo video recorded and uploaded/linked (point 1 above)
- [ ] Devices/OS actually tested filled in (point 2 above)
- [ ] Tested on the oldest supported OS (iOS 26) as well as the newest
- [ ] Full "For the reviewer" section (all 7 points) pasted into App Review Information → Notes
