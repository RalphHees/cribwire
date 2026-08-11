import Foundation

/// Who a signaling envelope is addressed to (`docs/specs/backend.md` §WebSocket).
///
/// The wire form is `camera` or `viewer:<deviceId>`; the server routes on this
/// and on nothing else, because it is the only part of a signaling message it
/// can read.
public enum SignalingRecipient: Equatable, Hashable, Sendable {
    case camera
    case viewer(deviceID: String)

    public var wireValue: String {
        switch self {
        case .camera:
            return "camera"
        case .viewer(let deviceID):
            return "viewer:\(deviceID)"
        }
    }

    public init?(wireValue: String) {
        if wireValue == "camera" {
            self = .camera
        } else if wireValue.hasPrefix("viewer:") {
            let deviceID = String(wireValue.dropFirst("viewer:".count))
            guard !deviceID.isEmpty else { return nil }
            self = .viewer(deviceID: deviceID)
        } else {
            return nil
        }
    }
}

/// The routing envelope the server sees: `{to, seq, blob}`.
///
/// `blob` is a `SealedEnvelope` under `K_sig`. Everything meaningful — SDP, ICE
/// candidates, the DTLS fingerprint — is inside it, so a malicious backend can
/// drop or delay messages but can neither read nor forge one (`security.md` §4).
///
/// `seq` sits *outside* the seal because the server needs it to reason about
/// ordering, which means the server can also rewrite it. The sender therefore
/// repeats the sequence number inside the sealed payload
/// (``SignalingPayload/seq``) and the receiver requires the two to match; a
/// rewritten `seq` fails that check.
public struct SignalingEnvelope: Codable, Equatable, Sendable {
    /// Maximum size of one WebSocket message (`backend.md`: 16 KiB cap).
    public static let maxMessageBytes = 16 * 1024

    public let to: String
    public let seq: Int
    public let blob: String

    public init(to: SignalingRecipient, seq: Int, blob: String) {
        self.to = to.wireValue
        self.seq = seq
        self.blob = blob
    }

    public init(to: String, seq: Int, blob: String) {
        self.to = to
        self.seq = seq
        self.blob = blob
    }

    public var recipient: SignalingRecipient? {
        SignalingRecipient(wireValue: to)
    }
}

/// A presence notification from the server: a peer connected or went away.
///
/// The server emits these so the Camera knows when to create an offer
/// (`backend.md` §WebSocket) — and it is also how the Camera first learns that a
/// Viewer claimed the pairing, which is the event `security.md` §3.3 step 2 needs.
///
/// Only the two event names are pinned; the fields alongside them are not, so
/// every one of them is optional here and nothing security-relevant is derived
/// from them. Presence is a *hint to act*, never an authorisation: whatever the
/// server says, the peer still has to produce a blob that opens under `K_sig`.
public struct SignalingPresence: Equatable, Sendable {
    public let role: PairingRole?
    public let deviceID: String?

    public init(role: PairingRole?, deviceID: String?) {
        self.role = role
        self.deviceID = deviceID
    }
}

/// One decoded inbound WebSocket message.
public enum SignalingInboundMessage: Equatable, Sendable {
    case envelope(SignalingEnvelope)
    case peerOnline(SignalingPresence)
    case peerOffline(SignalingPresence)
    /// Anything else the server sends — heartbeats, future message types. Never
    /// an error: an unknown message must not tear down a working stream.
    case unknown(type: String?)

    /// Pinned event names (`backend.md` §WebSocket).
    public static let peerOnlineType = "peer-online"
    public static let peerOfflineType = "peer-offline"

    /// Parses a text frame.
    ///
    /// A frame carrying `blob` is an envelope; otherwise the `type` field names
    /// the event. Deliberately tolerant — the server is untrusted, so a
    /// malformed frame is a shrug, not a crash.
    public static func parse(_ text: String) -> SignalingInboundMessage? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let blob = object["blob"] as? String,
           let to = object["to"] as? String,
           let seq = object["seq"] as? Int {
            return .envelope(SignalingEnvelope(to: to, seq: seq, blob: blob))
        }

        // `type` is the shape the backend spec implies; `event` is accepted as
        // an alias so a small naming difference on the server cannot silently
        // cost us presence (see the contract note in ios/README.md).
        let type = (object["type"] as? String) ?? (object["event"] as? String)
        let presence = SignalingPresence(
            role: (object["role"] as? String).flatMap(PairingRole.init(rawValue:)),
            deviceID: object["deviceId"] as? String
        )

        switch type {
        case peerOnlineType:
            return .peerOnline(presence)
        case peerOfflineType:
            return .peerOffline(presence)
        default:
            return .unknown(type: type)
        }
    }
}
