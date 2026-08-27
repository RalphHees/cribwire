# App Store review notes — CribWire

Paste the "For the reviewer" section into App Store Connect → App Review
Information → Notes. The rest of this file is context for whoever prepares the
submission.

---

## For the reviewer

**CribWire needs two devices to test.** It is a baby monitor: one iPhone acts as
the Camera in the child's room, a second as the Viewer with the parent. A single
device cannot demonstrate the app, because pairing works by one device showing a
QR code and the other scanning it in person.

There is **no account and no login**. Nothing to sign up for, and no demo
credentials, because there is no server-side user to authenticate. Trust is
established by scanning the QR code face to face.

### How to test with two devices

1. On device A, choose **Camera** → **Pair a Viewer**. A QR code appears.
2. On device B, choose **Viewer** → **Scan a Camera**. Point it at device A's screen.
3. Both devices now show the **same six digits**. This is a security confirmation, not a code to type: compare them and tap **Codes match** on the Viewer.
4. On device A tap **Start the camera**; on device B tap **Watch**. Live video and audio flow directly between the devices.

**Both devices must be on a network that allows peer-to-peer connections.** Office
or guest Wi-Fi that blocks UDP will fall back to our TURN relay; if that is also
blocked, the connection will not establish. Testing on ordinary Wi-Fi or cellular
works.

### If only one device is available

Pairing cannot be completed, so the live view cannot be reached. Everything up to
the QR code is testable: role selection, the Camera's QR screen with its two-minute
rotation, the Viewer's scanner, alert settings, and the paired-devices list.

We are glad to supply a video of the full two-device flow on request.

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

Guideline 5.1.1 (data collection and storage) or 2.1 (incomplete information),
because a reviewer with one device cannot reach the main feature.

The response is the two-device explanation above plus a video of the full flow.
Have that video recorded **before** submitting rather than after a rejection —
it turns a multi-day round trip into a same-day one.

### Pre-submission checklist

- [ ] `CRIBWIRE_API_BASE_URL` points at production, not staging
- [ ] `aps-environment` is `production` in the release configuration
- [ ] `DEVELOPMENT_TEAM` and the bundle id are the real ones, not the placeholders in `ios/project.yml`
- [ ] Export-compliance answer confirmed with counsel (`PRIVACY-LABELS.md`)
- [ ] Privacy labels entered as "Data Not Collected" across every category
- [ ] iPhone screenshots are 1242 × 2688 / 2688 × 1242 or 1284 × 2778 / 2778 × 1284
- [ ] iPad screenshots are 2048 × 2732 / 2732 × 2048 or 2064 × 2752 / 2752 × 2064
- [ ] Two-device demo video uploaded or linked in the review notes
- [ ] Tested on the oldest supported OS (iOS 26) as well as the newest
