import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// This device's own 32-byte API authentication key (`shared/protocol.md`
/// revision 1.1, "Why per-device keys").
///
/// `K_auth` proves *membership of the pairing* — every device that scanned the QR
/// has it — so it can never prove *which* device is calling. It therefore
/// authenticates only the two bootstrap calls (`POST /v1/pairings` and
/// `POST /v1/pairings/{id}/claim`). At that moment the device generates this key
/// from the CSPRNG, uploads it once inside the bootstrap-authenticated body, and
/// signs every later request with it; the server reads the caller's role from the
/// device row rather than from the request, which closes the escalation hole
/// where a viewer could assert `camera` and revoke the pairing.
///
/// Like `K_auth`, a device key authenticates and decrypts nothing.
/// `@unchecked Sendable`: `SymmetricKey` is an immutable value type but is not
/// declared `Sendable` in every SDK version we build against.
public struct DeviceKey: @unchecked Sendable {
    public static let byteCount = 32

    /// Not public: raw access stays inside KidsCamKit. Callers get the base64
    /// upload form or the Keychain bytes, nothing else.
    let key: SymmetricKey

    // MARK: - Creation

    /// A fresh key from the system CSPRNG. Called exactly once per device per
    /// pairing, at bootstrap time.
    public static func generate() throws -> DeviceKey {
        DeviceKey(key: try SecureRandom.symmetricKey(byteCount: byteCount))
    }

    /// Rebuilds a key read back from the Keychain.
    /// - Throws: `CryptoError.invalidDeviceKeyLength` if it is not 32 bytes.
    public init<Bytes: ContiguousBytes>(bytes: Bytes) throws {
        let data = bytes.kc_dataRepresentation
        guard data.count == Self.byteCount else {
            throw CryptoError.invalidDeviceKeyLength(
                expected: Self.byteCount,
                actual: data.count
            )
        }
        self.key = SymmetricKey(data: data)
    }

    init(key: SymmetricKey) {
        self.key = key
    }

    // MARK: - Encoding

    /// Standard base64 with padding — the form the bootstrap request body
    /// carries (`shared/protocol.md`, "REST bodies").
    public var base64EncodedForUpload: String {
        key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    /// Raw bytes, for writing to the Keychain only. The device key lives in the
    /// app's **private** access group — the notification extension has no use
    /// for it (`security.md` §5).
    public var rawBytesForKeychainStorage: Data {
        key.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Redaction

extension DeviceKey: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "DeviceKey(<redacted 32 bytes>)" }
    public var debugDescription: String { description }
}
