import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - Byte helpers

extension ContiguousBytes {
    /// Copies the receiver's bytes into a `Data` value.
    ///
    /// Only use this for values that are safe to copy out of their protected
    /// storage (ciphertext, MACs, public material). Key material should stay
    /// inside `SymmetricKey` wherever possible.
    var kc_dataRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}

extension Data {
    /// Lowercase hexadecimal, as used by the `KidsCam-HMAC` scheme.
    var kc_hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Parses lowercase or uppercase hex. Returns `nil` for odd-length or
    /// non-hex input. Used by tests to load the shared vectors.
    static func kc_fromHex(_ string: String) -> Data? {
        guard string.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// base64url without padding, per `shared/protocol.md`.
    var kc_base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict base64url decoding: rejects padding and standard-base64 alphabet
    /// characters so a standard-base64 string is never silently accepted where
    /// the protocol requires base64url.
    static func kc_fromBase64URL(_ string: String) -> Data? {
        guard !string.isEmpty,
              !string.contains("="),
              !string.contains("+"),
              !string.contains("/")
        else { return nil }

        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: padded)
    }
}

// MARK: - Constant-time comparison

/// Constant-time equality built entirely from CryptoKit primitives.
///
/// `security.md` §7 requires MAC/SAS comparisons to be constant time and forbids
/// hand-rolled primitives, so instead of writing an XOR loop we MAC both operands
/// under a fresh random key and let `HMAC.isValidAuthenticationCode` — which is
/// constant time by contract — do the comparison.
enum ConstantTime {
    static func equal<A: ContiguousBytes, B: ContiguousBytes>(_ lhs: A, _ rhs: B) -> Bool {
        let ephemeralKey = SymmetricKey(size: .bits256)
        let lhsCode = HMAC<SHA256>.authenticationCode(
            for: lhs.kc_dataRepresentation,
            using: ephemeralKey
        )
        return HMAC<SHA256>.isValidAuthenticationCode(
            lhsCode,
            authenticating: rhs.kc_dataRepresentation,
            using: ephemeralKey
        )
    }

    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        equal(Data(lhs.utf8), Data(rhs.utf8))
    }
}
