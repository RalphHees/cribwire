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

## Re-rendering screenshots

Each mockup root carries the `shot` class with an `id` (`s1`…`s13`). Open the HTML
in a browser, or render headlessly — no dependency needed beyond Chrome, which
takes a per-board shot when the other boards are hidden:

```sh
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
sed 's|</head>|<style>body{padding:0;display:block}.board{display:none}\
.board:has(#s9){display:block}.board h2,.board .note{display:none}</style></head>|' \
  app-screens.html > /tmp/s9.html
"$CHROME" --headless --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=390,844 \
  --screenshot=screenshots/9-viewer-live.png file:///tmp/s9.html
```

`0-app-overview.png` is the whole sheet at 1x (`--window-size=6100,1150`, no board
hidden).

These mockups are the reference for `ios-architect`/`ios-engineer` when building
the SwiftUI screens; visual details (spacing, exact shades) may evolve in code, but
the palette, role colours and the tokens in `ios/CribWire/Design/Theme.swift` are
meant to stay in step with this file.
