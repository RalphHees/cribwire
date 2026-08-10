import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if canImport(Security)
import Security
#endif

/// The 32-byte root secret `S` that the QR code carries (`security.md` §3.1).
///
/// Every key in the system is derived from this value, so it is the single most
/// sensitive object in the app. It is stored in `SymmetricKey` (which zeroes its
/// backing buffer on deallocation), never printed, and never written anywhere
/// except the Keychain.
/// `@unchecked Sendable`: `SymmetricKey` is an immutable value type but is not
/// declared `Sendable` in every SDK version we build against.
public struct RootSecret: @unchecked Sendable {
    public static let byteCount = 32

    /// Not `public`: raw access stays inside KidsCamKit. Callers get the derived
    /// keys or the base64url form for the QR, nothing else.
    let key: SymmetricKey

    // MARK: - Creation

    /// Generates a fresh root secret from the system CSPRNG.
    ///
    /// `security.md` §7 mandates `SecRandomCopyBytes` on Apple platforms. On
    /// non-Darwin platforms (Linux CI running `swift test`) swift-crypto's
    /// `SymmetricKey(size:)` is used, which draws from the platform CSPRNG.
    public static func generate() throws -> RootSecret {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            throw CryptoError.randomGenerationFailed(status: Int32(status))
        }
        defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
        return RootSecret(key: SymmetricKey(data: bytes))
        #else
        return RootSecret(key: SymmetricKey(size: .bits256))
        #endif
    }

    /// Rebuilds a root secret from stored/scanned bytes.
    /// - Throws: `CryptoError.invalidRootSecretLength` if it is not 32 bytes.
    public init<Bytes: ContiguousBytes>(bytes: Bytes) throws {
        let data = bytes.kc_dataRepresentation
        guard data.count == Self.byteCount else {
            throw CryptoError.invalidRootSecretLength(
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

    /// base64url without padding, the form used in the `s` query parameter.
    ///
    /// Only the pairing screen should ever call this, and only to hand the value
    /// straight to the QR renderer.
    public var base64URLEncoded: String {
        key.withUnsafeBytes { Data($0).kc_base64URLEncodedString }
    }

    /// Raw bytes, for writing to the Keychain only.
    public var rawBytesForKeychainStorage: Data {
        key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Derivation

    /// Derives the four per-pairing keys (`security.md` §3.2).
    public func deriveKeys() -> PairingKeys {
        PairingKeys(rootSecret: self)
    }
}

// MARK: - Redaction

extension RootSecret: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "RootSecret(<redacted 32 bytes>)" }
    public var debugDescription: String { description }
}

private extension Array where Element == UInt8 {
    mutating func resetBytes(in range: Range<Int>) {
        for index in range { self[index] = 0 }
    }
}
