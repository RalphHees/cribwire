import Foundation

/// Errors raised by `CryptoCore`.
///
/// Deliberately coarse: nothing here carries key material, plaintext or any other
/// value that could end up in a log line or crash report.
public enum CryptoError: Error, Equatable, Sendable {
    /// The system CSPRNG refused to produce bytes. `status` is the raw
    /// `SecRandomCopyBytes` return value on Apple platforms.
    case randomGenerationFailed(status: Int32)

    /// A root secret was not exactly `RootSecret.byteCount` bytes long.
    case invalidRootSecretLength(expected: Int, actual: Int)

    /// The sealed envelope was not valid base64, or was shorter than
    /// nonce(12) + tag(16).
    case malformedEnvelope

    /// ChaCha20-Poly1305 authentication failed: wrong key, wrong AAD, or the
    /// envelope was tampered with. Callers must treat all three the same way.
    case authenticationFailed
}

extension CryptoError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .randomGenerationFailed(let status):
            return "CryptoError.randomGenerationFailed(status: \(status))"
        case .invalidRootSecretLength(let expected, let actual):
            return "CryptoError.invalidRootSecretLength(expected: \(expected), actual: \(actual))"
        case .malformedEnvelope:
            return "CryptoError.malformedEnvelope"
        case .authenticationFailed:
            return "CryptoError.authenticationFailed"
        }
    }
}
