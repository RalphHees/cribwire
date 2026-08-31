# App Store Connect metadata — CribWire

Text to paste into App Store Connect → App Information / App Store tabs. Field
names and character limits below match what App Store Connect shows.

---

## Promotional Text (170 characters max)

```
A private baby monitor between two iPhones. Video and audio are end-to-end encrypted, paired by scanning a QR code. No account, no cloud storage — ever.
```

152 characters. This field can be edited without a new build review, so it's
the right place for anything time-sensitive (a holiday note, a "now with
iPad support" callout) later.

---

## Description (4,000 characters max)

```
CribWire is a private baby monitor built from two iPhones — no extra hardware to buy, no cloud account, no subscription.

One phone becomes the Camera in your child's room. A second becomes the Viewer, wherever you are in the house. Video and audio stream directly between the two devices, end-to-end encrypted, so nothing you see or hear ever reaches a server in a readable form.

HOW PAIRING WORKS
Point the Viewer's camera at a QR code shown on the Camera device. That single scan is the only way the two devices ever trust each other — there's no account to create and no password to remember. Both phones then show the same six digits so you can confirm, at a glance, that the connection is genuine. The QR code itself refreshes every two minutes, so a code seen once can't be reused later.

WHY IT'S PRIVATE
CribWire's server never holds an encryption key. It only relays already-encrypted traffic between your two devices — for setting up the connection, and, when your Wi-Fi doesn't allow a direct link, for the video stream itself. There is no recording, no cloud storage, and no way for us — or anyone else — to view your child's room. No account, no login, no analytics, no ads.

NOISE & MOVEMENT ALERTS
Turn on-device detection on, and the Camera can notify the Viewer when it hears noise or sees movement — useful for the moments you've stepped away from the live view. Detection runs entirely on the Camera device, and alert notifications are themselves encrypted so only your paired Viewer can read what triggered them.

BUILT FOR THE WHOLE HOME
• Works over your home Wi-Fi for the lowest latency
• Falls back to a relay automatically when a direct connection isn't possible, without ever exposing your stream in the clear
• A universal app for iPhone and iPad
• Complete English and Dutch localization

WHAT CRIBWIRE DOESN'T DO
No account creation. No cloud recording or playback. No ads, trackers, or analytics SDKs. No data sold or shared — because none is collected in the first place.

CribWire needs two devices to work: one iPhone (or iPad) set up as the Camera, a second as the Viewer. Pair them once, and check in on the crib with complete privacy.
```

2,173 characters.

---

## Keywords (100 characters max, comma-separated, no spaces after commas)

```
baby monitor,babyphone,nanny cam,e2e encryption,privacy,noise detection,movement,crib,nursery,cam
```

97 characters. Don't repeat words already in the app name ("CribWire") or
whatever subtitle is entered alongside it — Apple's keyword field doesn't
reward duplicates.

---

## Support URL (required)

```
https://cribwire.ralphhees.nl/support
```

Placeholder following the existing `apicribwire.ralphhees.nl` naming pattern
(`ios/project.yml`). **This page needs to actually exist and answer basic
questions before submission** — App Store review checks that it resolves.
Given there's no account or backend user data, a single static page
(what the app does, the two-device pairing flow, a contact email) is enough;
it doesn't need to be a full support system.

## Marketing URL (optional)

```
https://cribwire.ralphhees.nl
```

Optional — leave the App Store Connect field blank if no marketing site
exists yet rather than pointing it at a page that isn't live.

---

## Version

```
1.0
```

This is the *App Store version string* shown to users, independent of the
build's internal `CURRENT_PROJECT_VERSION`. Note `ios/project.yml` currently
sets `MARKETING_VERSION: "0.1.0"` — bump that to `1.0.0` before archiving the
build submitted as version 1.0, so the binary's `CFBundleShortVersionString`
matches what's entered here.

---

## Copyright

```
2026 Ralph Hees
```

Format Apple expects is `YYYY Entity name`. Confirm the exact legal name to
use (individual vs. a registered business name) before submitting — this
document assumes the individual developer, matching the `ralphhees.nl` /
`com.ralphhees.cribwire` naming used throughout the project.
