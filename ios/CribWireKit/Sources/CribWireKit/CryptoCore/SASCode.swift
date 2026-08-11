import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The 6-digit short authentication string both devices display during pairing
/// (`security.md` §3.3).
///
/// Derivation (normative, `shared/protocol.md`): the first 4 bytes of `K_sas`
/// read as a big-endian `UInt32`, `mod 1_000_000`, left-padded with zeros to
/// 6 digits.
///
/// `Equatable` exists for tests and SwiftUI diffing and is *not* constant time —
/// security-relevant comparisons must go through ``matches(_:)``.
public struct SASCode: Equatable, Sendable {
    /// Exactly six ASCII digits.
    public let digits: String

    init(derivedFrom sasKey: SymmetricKey) {
        let bytes = sasKey.withUnsafeBytes { Array($0.prefix(4)) }
        // K_sas is always 32 bytes, but be explicit rather than trapping on a
        // short buffer if that ever changes.
        var value: UInt32 = 0
        for byte in bytes {
            value = (value << 8) | UInt32(byte)
        }
        self.digits = String(format: "%06d", Int(value % 1_000_000))
    }

    /// For rendering fixtures and tests; production codes always come from a key.
    public init(digits: String) {
        self.digits = digits
    }

    /// Digits split into two groups of three, matching how both screens render it.
    public var groupedForDisplay: (leading: String, trailing: String) {
        guard digits.count == 6 else { return (digits, "") }
        let middle = digits.index(digits.startIndex, offsetBy: 3)
        return (String(digits[digits.startIndex..<middle]), String(digits[middle...]))
    }

    /// Constant-time comparison, as required by `security.md` §7.
    ///
    /// The SAS is compared by a human on screen, but the app also compares the
    /// locally derived code against any code it is told about, and that check
    /// must not leak a prefix through timing.
    public func matches(_ other: SASCode) -> Bool {
        ConstantTime.equal(digits, other.digits)
    }
}

extension SASCode: CustomStringConvertible {
    public var description: String { digits }
}
