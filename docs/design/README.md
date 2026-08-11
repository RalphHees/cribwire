# CribWire — Design

Visual design for the iOS app and the backend architecture, as self-contained HTML
mockups. Rendered PNGs live in [`screenshots/`](screenshots/).

## Files

- [`app-screens.html`](app-screens.html) — seven iPhone-frame mockups covering the
  core flows: role selection, QR pairing, SAS confirmation, Camera monitoring,
  Viewer live view, detection settings, and the lock-screen alert.
- [`backend-architecture.html`](backend-architecture.html) — one board showing the
  zero-knowledge topology: devices, signaling API, TURN, APNs, data stores, and the
  QR pairing channel that bypasses the server entirely.

## Design language

- **Night-first**: the app is used in dark rooms at night — deep indigo background
  (`#0f1220`), low-glare surfaces, no pure white.
- **Palette**: warm coral `#ff9e80` (primary actions, Camera role), periwinkle
  `#8e9bff` (Viewer role, secondary), green `#5ad7a0` reserved for live/secure
  states, amber for warnings.
- **Trust made visible**: every screen that touches keys or alerts states the
  security property in plain words ("This code contains your encryption key",
  "Alerts are end-to-end encrypted").
- **Type**: SF Pro (system), generous sizes, tabular numerals for timers.

## Re-rendering screenshots

Open either HTML file in a browser, or render with Playwright/Chromium: each
mockup root carries the `shot` class with an `id`; screenshot those elements at
`deviceScaleFactor: 2`.

These mockups are the reference for `ios-architect`/`ios-engineer` when building
the SwiftUI screens; visual details (spacing, exact shades) may evolve in code.
