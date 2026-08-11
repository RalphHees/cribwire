import Foundation

/// Which side of a pairing this device is.
///
/// The raw values are normative: they appear in the sealed-envelope AAD and in
/// the `CribWire-HMAC` Authorization header, and the backend matches on them.
public enum PairingRole: String, Codable, CaseIterable, Sendable {
    case camera
    case viewer

    /// The peer on the other end of the pairing.
    public var peer: PairingRole {
        switch self {
        case .camera: return .viewer
        case .viewer: return .camera
        }
    }
}
