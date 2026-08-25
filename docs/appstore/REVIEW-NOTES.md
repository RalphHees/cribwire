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

The live-view screenshots must not show a real, identifiable child. Use a doll, a
pet, or an empty cot. Required set:

1. Role selection ("Secure babyphone next to your crib")
2. Camera showing the pairing QR
3. The six-digit confirmation on both devices
4. Viewer live view with the connection indicator
5. Alert settings, showing both detectors off by default
6. A notification on the lock screen

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
- [ ] French encryption declaration filed with ANSSI and its receipt, plus the
      signed `CribWire-French-Encryption-Declaration.pdf`, uploaded under Export
      Compliance
- [ ] Privacy labels entered as "Data Not Collected" across every category
- [ ] Two-device demo video uploaded or linked in the review notes
- [ ] Tested on the oldest supported OS (iOS 26) as well as the newest
