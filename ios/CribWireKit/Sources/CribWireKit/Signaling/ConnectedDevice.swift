import Foundation

/// A device on the other end of a pairing, as it introduces itself.
///
/// Names exist because "Camera" and "Viewer" stop being useful the moment a
/// household has two of either: a parent looking at a list of paired devices, or
/// at who is currently watching the nursery, needs to know *which* phone. So each
/// device carries a name a person chose and sends it to its peers.
///
/// Three things are deliberately true of that name.
///
/// **It is chosen, not read off the device.** iOS has not let an app read the
/// user's device name since iOS 16 — `UIDevice.name` answers the model instead —
/// and that is the right default anyway: a name that travels to another phone
/// should be one someone decided to share, not one they set years ago for
/// AirDrop.
///
/// **It travels sealed, like everything else.** The relay routes ciphertext and
/// never learns that a phone called "Nursery" exists, let alone which account it
/// belongs to.
///
/// **It is untrusted input.** It arrives from another device, it is drawn on a
/// screen, and it is stored — so it is trimmed, capped and stripped of line
/// breaks on the way in. See `DeviceName.sanitized`.
public struct ConnectedDevice: Codable, Equatable, Identifiable, Sendable {

    /// The peer's device id: backend-issued on a server pairing, self-minted on
    /// a local-network one. Opaque here, and the identity the roster is keyed
    /// on — two viewers may legitimately share a name.
    public var deviceID: String

    /// What to call it, already sanitised. `nil` when the peer is running a
    /// build that predates names, which is drawn as a role rather than as a
    /// blank row.
    public var name: String?

    /// When this device's session was verified — not when it connected.
    ///
    /// The distinction matters on a screen that says who is watching: a peer
    /// that has exchanged SDP but failed the fingerprint check is not watching
    /// anything, and must never appear as though it were.
    public var since: Date?

    public var id: String { deviceID }

    public init(deviceID: String, name: String? = nil, since: Date? = nil) {
        self.deviceID = deviceID
        self.name = name.flatMap(DeviceName.sanitized)
        self.since = since
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "d"
        case name = "n"
        case since = "t"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceID = try container.decode(String.self, forKey: .deviceID)
        // Sanitised on the way in as well as the way out. The encoder that
        // produced this is another device, on another build, which this one has
        // no say over.
        let name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.name = name.flatMap(DeviceName.sanitized)
        self.since = try? container.decodeIfPresent(Date.self, forKey: .since)
    }
}

/// The rules a device name has to obey to be put on the wire and drawn.
public enum DeviceName {

    /// Longest name carried.
    ///
    /// The roster rides inside the sealed `status` message, which shares a
    /// 16 KiB frame cap with everything else on the signaling channel. Five
    /// viewers — the pairing limit — at this length is under a kilobyte, which
    /// keeps the message sendable with no dynamic trimming anywhere.
    public static let maxLength = 40

    /// The most viewers a roster ever carries, matching the pairing limit. A
    /// peer claiming more than this is either broken or malicious, and either
    /// way the answer is to stop reading rather than to render it.
    public static let maxRoster = 5

    /// Trimmed, stripped of line breaks, capped — and `nil` when what is left
    /// says nothing.
    ///
    /// Line breaks in particular: a name is drawn in a single-line row beside a
    /// "Remove" button, and a peer that sent forty newlines could otherwise push
    /// that button off the screen on the device it is paired with. Cheap to
    /// prevent, impossible to fix once stored.
    public static func sanitized(_ raw: String) -> String? {
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "…"
    }
}
