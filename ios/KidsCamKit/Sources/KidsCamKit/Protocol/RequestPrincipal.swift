import Foundation

/// Who is calling, as it appears in the canonical string and in the
/// `KidsCam-HMAC` header (`shared/protocol.md` revision 1.1).
///
/// Revision 1.1 removed the role from the wire entirely. A client asserting its
/// own role was the escalation hole: `K_auth` is derived from `S`, which every
/// paired device holds, so a viewer could sign a request claiming to be the
/// camera and revoke the pairing. Now the wire carries an *identity* — either the
/// literal `bootstrap` (signed with `K_auth`, valid only for pairing creation and
/// claim) or this device's UUID (signed with this device's own random key) — and
/// the server looks the role up on the device row.
public enum RequestPrincipal: Equatable, Hashable, Sendable {
    /// The two calls that establish a device, signed with `K_auth`:
    /// `POST /v1/pairings` and `POST /v1/pairings/{id}/claim`.
    case bootstrap
    /// Every other authenticated request, signed with the device's own key.
    /// The payload is the device UUID exactly as the backend issued it.
    case device(String)

    /// The literal that stands in for a device id on the bootstrap calls.
    public static let bootstrapToken = "bootstrap"

    /// Convenience for a device id already parsed as a UUID; the wire form is
    /// lowercase, like every other identifier in the protocol.
    public static func device(id: UUID) -> RequestPrincipal {
        .device(id.kc_lowercasedString)
    }

    /// The exact string that goes into line 4 of the canonical string and into
    /// the header's second field.
    public var stringValue: String {
        switch self {
        case .bootstrap:
            return Self.bootstrapToken
        case .device(let identifier):
            return identifier
        }
    }

    /// Parses a principal back from the wire. `bootstrap` is reserved, so a
    /// device id can never collide with it.
    public init(stringValue: String) {
        self = stringValue == Self.bootstrapToken ? .bootstrap : .device(stringValue)
    }

    /// True for the two calls `K_auth` is still allowed to sign.
    public var isBootstrap: Bool {
        self == .bootstrap
    }
}
