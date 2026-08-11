import Foundation

/// The APNs payload the backend fans out for a detection event, and the text the
/// user reads for it.
///
/// The backend copies the camera's `ciphertext` through byte for byte and adds
/// nothing it could not already see (`backend.md` §3); everything meaningful is
/// sealed under `K_evt`. So the app receives two useful fields, and both are
/// named here rather than spelled as string literals at the call site.
public struct EventNotificationPayload: Equatable, Sendable {

    /// `userInfo` keys, pinned by `backend.md` §3.
    public static let pairingIDKey = "pairingId"
    public static let ciphertextKey = "ciphertext"

    public let pairingID: UUID
    /// Sealed `DetectionEvent`, base64. Opaque to the backend and to Apple.
    public let ciphertext: String

    public init(pairingID: UUID, ciphertext: String) {
        self.pairingID = pairingID
        self.ciphertext = ciphertext
    }

    /// Parses `UNNotificationRequest.content.userInfo`.
    ///
    /// - Returns: `nil` for anything that is not a sealed CribWire event — a
    ///   local notification the app posted itself, or a payload from a protocol
    ///   version this build does not know. Callers must treat that exactly like
    ///   a failed decryption: show the generic text (`security.md` §5).
    public init?(userInfo: [AnyHashable: Any]) {
        guard let pairingIDString = userInfo[Self.pairingIDKey] as? String,
              let pairingID = UUID(uuidString: pairingIDString),
              let ciphertext = userInfo[Self.ciphertextKey] as? String,
              !ciphertext.isEmpty
        else {
            return nil
        }
        self.init(pairingID: pairingID, ciphertext: ciphertext)
    }
}

/// The strings shown for an event push.
///
/// The generic body is what the *server* asks Apple to display (the
/// `EVENT_GENERIC` localizable key): the backend cannot read the event, so it
/// cannot say more than "something happened". Once the app has opened the
/// envelope it can replace that with the specific sentence.
public enum EventAlert {

    public static let title = "CribWire"

    /// Shown whenever the payload cannot be opened — no key, wrong pairing,
    /// tampered bytes, unknown payload shape. All four look identical on
    /// purpose: the alert must never hint at key state (`security.md` §5).
    public static let genericBody = "Activity detected"

    public static func body(for event: DetectionEvent) -> String {
        switch event.type {
        case .noise:
            return "Noise detected"
        case .motion:
            return "Movement detected"
        case .lowBattery:
            return "Camera battery low"
        }
    }
}
