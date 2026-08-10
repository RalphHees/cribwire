# kidscam

A private baby monitor built from two iOS devices: one streams as the **Camera**, the
other watches as the **Viewer**. Video and audio are end-to-end encrypted — pairing
happens by physically scanning a QR code, so only devices that scanned each other can
decrypt the stream. The Camera can optionally send push notifications when it detects
noise or movement.

## Documentation

| Document | Contents |
|---|---|
| [docs/specs/ios-app.md](docs/specs/ios-app.md) | iOS app: roles, streaming, noise/movement detection, UX, technical choices |
| [docs/specs/backend.md](docs/specs/backend.md) | Zero-knowledge backend: signaling, TURN relay, push delivery, API, data model |
| [docs/specs/security.md](docs/specs/security.md) | QR pairing protocol, key derivation, E2E stream encryption, threat model |
| [docs/TASKS.md](docs/TASKS.md) | Phased task list with milestones |

## Architecture at a glance

- **iOS app** (Swift/SwiftUI): one codebase, two roles. WebRTC (DTLS-SRTP) for
  low-latency streaming; on-device noise and movement detection.
- **Backend** (Node/TypeScript + coturn): relays only ciphertext — it authenticates
  devices and routes messages but holds no decryption keys and stores no media.
- **Trust anchor**: a QR code shown on the Camera and scanned by the Viewer carries
  the root secret; all encryption keys derive from it, so the server can never read
  or man-in-the-middle the stream.
