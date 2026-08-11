import CryptoKit
import Foundation
import CribWireKit

/// An event push after it has been opened.
struct DecodedEvent: Equatable, Sendable {
    let pairingID: UUID
    let event: DetectionEvent
}

/// Turns the `userInfo` of an APNs push into a `DetectionEvent`.
///
/// This is the work a Notification Service Extension used to do in its own
/// process. It runs in the app now, which does not change the rule it has to
/// obey: *any* failure — payload that is not ours, a pairing this device no
/// longer holds, a wrong key, tampered bytes — yields `nil`, and `nil` means the
/// generic alert. The caller must not be able to tell those cases apart, and
/// nothing here logs (`security.md` §5).
///
/// `K_evt` is the only key touched on this path. The root secret, `K_sig` and
/// the device key are never read to display a notification.
struct EventNotificationDecoder: Sendable {

    /// Resolves `K_evt` for a pairing. A closure rather than the store itself so
    /// the decision table above can be tested without a Keychain.
    private let eventKey: @Sendable (UUID) async -> SymmetricKey?

    init(secrets: PairingSecretsStore) {
        self.eventKey = { pairingID in try? await secrets.eventKey(for: pairingID) }
    }

    init(eventKey: @escaping @Sendable (UUID) async -> SymmetricKey?) {
        self.eventKey = eventKey
    }

    func open(_ payload: EventNotificationPayload) async -> DecodedEvent? {
        guard let key = await eventKey(payload.pairingID),
              let event = try? DetectionEvent.open(
                  sealed: payload.ciphertext,
                  using: key,
                  pairingID: payload.pairingID
              )
        else {
            return nil
        }
        return DecodedEvent(pairingID: payload.pairingID, event: event)
    }

    /// Parse and open in one step.
    func decode(userInfo: [AnyHashable: Any]) async -> DecodedEvent? {
        guard let payload = EventNotificationPayload(userInfo: userInfo) else { return nil }
        return await open(payload)
    }
}
