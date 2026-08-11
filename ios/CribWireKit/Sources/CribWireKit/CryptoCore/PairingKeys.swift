import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The four keys derived from a pairing's root secret.
///
/// `HKDF-SHA256(ikm: S, salt: empty, info: <label>, length: 32)` — the `info`
/// strings are normative (`shared/protocol.md`) and cross-implemented by the
/// backend, so they live in one place and are covered by vector tests.
/// `@unchecked Sendable`: the stored `SymmetricKey` values are immutable value
/// types, but CryptoKit did not declare `Sendable` conformance across all the SDK
/// versions we build against, so we vouch for it explicitly.
public struct PairingKeys: @unchecked Sendable {
    /// HKDF `info` labels. Changing any of these breaks interop with the backend.
    public enum Info {
        public static let auth = "cribwire/v1/auth"
        public static let signaling = "cribwire/v1/sig"
        public static let event = "cribwire/v1/event"
        public static let sas = "cribwire/v1/sas"
    }

    /// Derived key length in bytes, for all four keys.
    public static let keyByteCount = 32

    /// `K_auth` — HMAC authentication against the backend. The only key the
    /// server ever learns; it decrypts nothing.
    public let auth: SymmetricKey

    /// `K_sig` — seals signaling blobs. Never leaves the device.
    public let signaling: SymmetricKey

    /// `K_evt` — seals push event payloads. Shared with the Notification Service
    /// Extension through the app-group Keychain. Never leaves the device.
    public let event: SymmetricKey

    /// `K_sas` — source of the 6-digit confirmation code.
    public let sas: SymmetricKey

    init(rootSecret: RootSecret) {
        self.auth = Self.derive(from: rootSecret, info: Info.auth)
        self.signaling = Self.derive(from: rootSecret, info: Info.signaling)
        self.event = Self.derive(from: rootSecret, info: Info.event)
        self.sas = Self.derive(from: rootSecret, info: Info.sas)
    }

    /// Rebuilds the key set from individually stored keys (Keychain restore).
    public init(auth: SymmetricKey, signaling: SymmetricKey, event: SymmetricKey, sas: SymmetricKey) {
        self.auth = auth
        self.signaling = signaling
        self.event = event
        self.sas = sas
    }

    static func derive(from rootSecret: RootSecret, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: rootSecret.key,
            salt: Data(),
            info: Data(info.utf8),
            outputByteCount: keyByteCount
        )
    }

    /// The 6-digit short authentication string shown on both devices.
    public var sasCode: SASCode {
        SASCode(derivedFrom: sas)
    }
}

extension PairingKeys: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PairingKeys(<redacted>)" }
    public var debugDescription: String { description }
}
