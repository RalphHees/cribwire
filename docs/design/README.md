# CribWire — Design

Visual design for the iOS app and the backend architecture, as self-contained HTML
mockups. Rendered PNGs live in [`screenshots/`](screenshots/).

## Files

- [`app-screens.html`](app-screens.html) — thirteen iPhone-frame mockups covering
  every screen the app has. In flow order:

  | # | Screen | Covers |
  |---|--------|--------|
  | 1 | Role selection | First launch, Camera vs Viewer |
  | 2 | Camera home | Start, pair, paired viewers, alerts, role switch |
  | 3 | Pairing — Camera shows QR | Rotating code, key-in-the-code warning |
  | 4 | Pairing — Viewer scans | Scanner reticle, key never reaches the server |
  | 5 | Pairing — Viewer confirms | SAS digits, mismatch warning |
  | 6 | Camera monitoring | Live state, alerts, link, battery, room-controls note, dimming |
  | 7 | Camera alerts | Noise + movement toggles, sensitivity, watch area, quiet period |
  | 8 | Viewer home | Decrypted last alert, watch, scan, paired cameras |
  | 9 | Viewer live | Verified video, hold-to-talk, mute / audio-only / room / snapshot |
  | 10 | Viewer room controls | Music, talk-back volume, light, picture brightness, night boost |
  | 11 | Viewer playlist picker | Recently played, then library favourites |
  | 12 | Paired devices | Both roles, revocation and what it destroys |
  | 13 | Viewer lock screen | Push alert **and** the Live Activity |

- [`backend-architecture.html`](backend-architecture.html) — one board showing the
  zero-knowledge topology: devices, signaling API, TURN, APNs, data stores, and the
  QR pairing channel that bypasses the server entirely.

## Design language

- **Night-first**: the app is used in dark rooms at night — deep indigo background
  (`#0f1220`), low-glare surfaces, no pure white.
- **Palette**: warm coral `#ff9e80` (primary actions, Camera role), periwinkle
  `#8e9bff` (Viewer role, secondary), green `#5ad7a0` reserved for live/secure
  states, amber `#ffd166` for warnings, red `#e04444` for destructive actions only.
- **Role colour is consistent**: every Camera-side screen accents coral, every
  Viewer-side screen periwinkle — including buttons, sliders and toggles.
- **Trust made visible**: every screen that touches keys or alerts states the
  security property in plain words ("This code contains your encryption key",
  "Alerts are end-to-end encrypted").
- **Type**: SF Pro (system), generous sizes, tabular numerals for the SAS and
  countdowns. In code, faces are declared against system **text styles**, never
  fixed point sizes, so the app scales with Dynamic Type — a parent reading this
  at 3 a.m. without their glasses is the normal case. `Font.system(size:)` is for
  SF Symbols glyphs only, never for text.

## Screenshot dimensions

The app ships for iPhone **and** iPad (`TARGETED_DEVICE_FAMILY: "1,2"`), and the
store asks for a set per device. The thirteen numbered PNGs are rendered at a
size App Store Connect accepts, so the design reference and the masters uploaded
with the listing are the same files:

| Display | Canvas | Rendered | Also accepted | Written to |
|---------|--------|----------|---------------|------------|
| iPhone 6.5" (default) | 414 × 896 pt @3x | **1242 × 2688 px** | 2688 × 1242 | `screenshots/` |
| iPhone 6.7" | 428 × 926 pt @3x | **1284 × 2778 px** | 2778 × 1284 | `screenshots/` |
| iPad Pro 12.9" | 1024 × 1366 pt @2x | **2048 × 2732 px** | 2732 × 2048 | `screenshots/ipad/` |
| iPad Pro 13" | 1032 × 1376 pt @2x | **2064 × 2752 px** | 2752 × 2064 | `screenshots/ipad/` |

App Store Connect rejects anything else at upload, so the render script
measures every PNG it writes against the list for that device and fails the run
rather than leave an off-size file behind. The mockups are portrait-only; the
landscape sizes are listed because the store accepts them, not because anything
here produces one. iPad shots land in their own directory so the two sets, which
share filenames, do not overwrite each other.

The canvas is not a browser flag — it is a block of custom properties in
[`app-screens.html`](app-screens.html) that the device frame is drawn from, so
the mockup on screen is the pixel grid that ships. Nothing else in the sheet
hard-codes a device dimension, which is what lets one file render all four.

## What changes on iPad

The same thirteen boards render as iPad screens; the device variables carry the
differences, which are the ones the app itself makes:

- **`--col-max: 560px`** — text and controls cap at
  `Theme.Metrics.readableWidth` and centre rather than stretching, matching what
  the app does on a regular-width screen (`docs/TASKS.md` Phase 5, iPad). It is
  applied as side padding on the content container, so on a phone — where the
  screen is narrower than the cap — the padding resolves to the screen's own
  gutter and the phone renders are untouched, byte for byte.
- **Video stays full-bleed.** Only the controls over it are constrained, which
  is the rule in the app too.
- **No Dynamic Island**, a shorter status bar and a gentler corner radius.

`0-app-overview.png` is the contact sheet, not a store upload: it is the whole
row at 1x with the device frames left on, is not size-checked, and is rendered
for the phone set only — thirteen iPads in a row is 14 000 px of mostly empty
column.

## Re-rendering screenshots

Each mockup root carries the `shot` class with an `id` (`s1`…`s13`), and
[`render-screenshots.sh`](render-screenshots.sh) renders one board at a time by
hiding the rest. No dependency beyond a Chrome or Chromium binary:

```sh
./render-screenshots.sh                  # iPhone set + overview, 1242 × 2688
./render-screenshots.sh --display 6.7    # the same set at 1284 × 2778
./render-screenshots.sh --display 12.9   # iPad set, 2048 × 2732
./render-screenshots.sh --display 13     # iPad set, 2064 × 2752
./render-screenshots.sh --only s9        # just screenshots/9-viewer-live.png
CHROME=/path/to/chrome ./render-screenshots.sh
```

The script picks a browser from `$CHROME`, then from the usual install
locations. Some headless Chromium builds ignore `--window-size` for layout and
paint the excess as page background — which produces a *correctly sized* PNG
with the bottom of the screen missing, so measuring the file would not catch
it. The script asks the browser what viewport it took before rendering anything
and stops if the answer is wrong; pointing `CHROME` at a `headless_shell`
binary is the usual fix.

These mockups are the reference for `ios-architect`/`ios-engineer` when building
the SwiftUI screens; visual details (spacing, exact shades) may evolve in code, but
the palette, role colours and the tokens in `ios/CribWire/Design/Theme.swift` are
meant to stay in step with this file.
