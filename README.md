# CribWire

**Secure babyphone next to your crib.**

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

## Development agents

The repo ships Claude Code agents (`.claude/agents/`) for working on the project:

| Agent | Model | Role |
|---|---|---|
| `orchestrator` | opus | Coordinates whole features/milestones: decomposes work, delegates to the agents below, integrates and verifies |
| `ios-architect` | opus | Designs iOS features against the specs (read-only, produces implementation plans) |
| `ios-engineer` | opus | Implements the Swift/SwiftUI app, streaming engine, detection, and tests |
| `backend-architect` | opus | Designs backend features, guarding the zero-knowledge invariant (read-only) |
| `backend-engineer` | opus | Implements the Node/TypeScript API, signaling, TURN/APNs integration, and tests |
| `security-reviewer` | opus | Reviews security-sensitive changes against `docs/specs/security.md` (read-only) |
| `cicd-engineer` | opus | Designs and implements GitHub Actions pipelines, signing, TestFlight and deploy automation |

For multi-step or cross-stack work, start with the `orchestrator`; it runs the
architect → engineer flow per domain and routes anything touching pairing, crypto,
auth, or signaling through `security-reviewer` before calling it done.

## Architecture at a glance

- **iOS app** (Swift/SwiftUI): one codebase, two roles. WebRTC (DTLS-SRTP) for
  low-latency streaming; on-device noise and movement detection.
- **Backend** (Node/TypeScript + coturn): relays only ciphertext — it authenticates
  devices and routes messages but holds no decryption keys and stores no media.
- **Trust anchor**: a QR code shown on the Camera and scanned by the Viewer carries
  the root secret; all encryption keys derive from it, so the server can never read
  or man-in-the-middle the stream.
