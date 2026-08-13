# App Store privacy labels — CribWire

What to enter in App Store Connect → App Privacy, and the reasoning behind each
answer so a reviewer (or a future maintainer) can check it rather than trust it.

**The short version: CribWire collects nothing.** Every answer below follows from
one architectural fact — the backend relays ciphertext it holds no key for
(`docs/specs/security.md` §4–5) — rather than from a policy promise.

---

## The answer to give

**Data Used to Track You:** None.
**Data Linked to You:** None.
**Data Not Linked to You:** None.

In App Store Connect this is the "**Data Not Collected**" declaration for every
category.

---

## Category-by-category justification

| Apple category | Answer | Why |
|---|---|---|
| Contact Info | Not collected | No account, no email, no sign-up. The app has no notion of a user identity. |
| Health & Fitness | Not collected | — |
| Financial Info | Not collected | No purchases, no payment SDK. |
| Location | Not collected | No location API is linked. `NSLocalNetworkUsageDescription` is about LAN peer connections, not geolocation. |
| Sensitive Info | Not collected | — |
| Contacts | Not collected | — |
| User Content | **Not collected** | Video and audio are end-to-end encrypted between the two paired devices and never reach the server in a readable form. See the note below — this is the row most likely to be questioned. |
| Browsing History | Not collected | — |
| Search History | Not collected | — |
| Identifiers | **Not collected** | The APNs device token is stored server-side to deliver alerts. See the note below. |
| Purchases | Not collected | — |
| Usage Data | Not collected | No analytics SDK, no telemetry, no crash reporter that transmits. |
| Diagnostics | Not collected | Nothing is sent off-device. Server metrics are aggregate operational counters with no per-user dimension. |
| Other Data | Not collected | — |

---

## The two rows worth being able to defend

### User Content — "but it streams video"

Video and audio never exist on the server in readable form. The media path is
peer-to-peer WebRTC with DTLS-SRTP, and the signalling that sets it up is itself
sealed with a key derived from the QR code (`security.md` §4). When a TURN relay
is used, the server forwards encrypted packets it cannot decrypt.

Apple's definition is data "collected" by the app — transmitted off the device and
retained by the developer. None of the media is. Nothing is recorded server-side,
and there is no storage bucket for it to be recorded into.

**If a reviewer challenges this**, the demonstration is: the pairing key is
derived from a QR code that never leaves the two devices, so the operator has no
key. There is no support flow, admin tool, or subpoena response that can produce a
user's video, because the data to produce does not exist.

### Identifiers — the APNs token

The backend stores an APNs device token per paired device, which is required to
deliver a push at all. Apple's guidance treats the push token as part of the
delivery mechanism rather than as a collected identifier, and it is:

- not linked to any user identity — there is no account to link it to;
- not used for tracking, advertising, or analytics;
- never shared with third parties other than Apple's own APNs;
- deleted on revocation and by the daily purge job, and deleted automatically on an APNs `410 Unregistered`.

Push payloads carry a pairing id and a ciphertext. The server cannot read the
event; the alert text Apple sees is the constant string "Activity detected".

**If in doubt, declaring the token under "Identifiers → Not Linked to You" is the
conservative answer** and costs nothing in the product's positioning. Prefer that
over an argument if review pushes back.

---

## Tracking

CribWire does **not** call `App Tracking Transparency` and must not. There is no
advertising identifier, no third-party SDK of any kind, and no data shared with
data brokers.

Third-party code in the shipping app, in full:

| Dependency | Purpose | Network access |
|---|---|---|
| `stasel/WebRTC` | Binary distribution of Google's libwebrtc | Peer connections and TURN only |
| `apple/swift-crypto` | Cryptographic primitives | None |
| `apple/swift-asn1` | Transitive dependency of swift-crypto | None |

No analytics, no crash reporting, no attribution, no ad SDK.

---

## Encryption / export compliance

- `ITSAppUsesNonExemptEncryption`: **YES** — CribWire uses ChaCha20-Poly1305, HKDF-SHA256 and HMAC-SHA256 beyond what an exemption covers.
- It qualifies for the standard exemption for **mass-market software using published cryptographic standards**, but this needs the French declaration and a CCATS/self-classification report depending on jurisdiction. **Confirm with counsel before the first submission** — this is the one item in this document that is a legal question rather than a technical one.

---

## Keeping this honest

This file is only true while the app ships no analytics. If any SDK is ever added,
these labels must change **before** the release that adds it. A privacy label that
lags the code by one release is a false statement to Apple and to users.
