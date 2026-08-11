import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if canImport(Security)
import Security
#endif

/// The one place random bytes come from.
///
/// `security.md` §7 mandates `SecRandomCopyBytes` on Apple platforms; everything
/// that needs entropy (the root secret, per-device authentication keys) goes
/// through here so there is a single line to audit. On non-Darwin platforms
/// (Linux `swift test`) the platform CSPRNG behind `SystemRandomNumberGenerator`
/// is used instead — that path never runs in the shipping app.
enum SecureRandom {

    /// - Throws: `CryptoError.randomGenerationFailed` if the system CSPRNG
    ///   refuses. Never falls back to a weaker source.
    static func bytes(count: Int) throws -> Data {
        #if canImport(Security)
        var buffer = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &buffer)
        guard status == errSecSuccess else {
            throw CryptoError.randomGenerationFailed(status: Int32(status))
        }
        defer {
            for index in buffer.indices { buffer[index] = 0 }
        }
        return Data(buffer)
        #else
        var generator = SystemRandomNumberGenerator()
        var buffer = [UInt8]()
        buffer.reserveCapacity(count)
        for _ in 0..<count {
            buffer.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        defer {
            for index in buffer.indices { buffer[index] = 0 }
        }
        return Data(buffer)
        #endif
    }

    /// Random key material, handed straight to `SymmetricKey` so the bytes end
    /// up in storage that zeroes itself.
    static func symmetricKey(byteCount: Int) throws -> SymmetricKey {
        var data = try bytes(count: byteCount)
        defer { data.resetBytes(in: 0..<data.count) }
        return SymmetricKey(data: data)
    }
}
