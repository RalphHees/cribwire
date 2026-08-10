import Foundation

/// A DTLS certificate fingerprint, as it appears on an SDP `a=fingerprint` line
/// and in WebRTC's certificate statistics.
///
/// ```
/// a=fingerprint:sha-256 AB:CD:EF:…
/// ```
///
/// This is the value `security.md` §4 binds to the pairing: it travels inside
/// the sealed signaling blob, so a backend that swaps the SDP to insert itself
/// as a DTLS peer cannot also produce a sealed blob announcing its own
/// certificate. Comparing what was negotiated against what the sealed blob
/// promised is the entire man-in-the-middle defence, which is why it is a value
/// type with its own tests rather than a line of string comparison somewhere in
/// the engine.
public struct DTLSFingerprint: Equatable, Sendable {
    /// The only algorithm KidsCam accepts. A peer offering anything else is
    /// refused rather than downgraded.
    public static let requiredAlgorithm = "sha-256"

    /// Lowercased algorithm token, e.g. `sha-256`.
    public let algorithm: String
    /// The fingerprint bytes, parsed from the colon-separated hex.
    public let bytes: [UInt8]

    public init(algorithm: String, bytes: [UInt8]) {
        self.algorithm = algorithm.lowercased()
        self.bytes = bytes
    }

    /// Parses `"<algorithm> <hex>:<hex>:…"`, the form used both in SDP and in
    /// the `fp` field of a sealed signaling payload.
    public init?(sdpValue: String) {
        let trimmed = sdpValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        self.init(algorithm: String(parts[0]), hex: String(parts[1]))
    }

    /// Parses an algorithm and a colon-separated hex string that arrived
    /// separately, which is how WebRTC's certificate statistics report them.
    public init?(algorithm: String, hex: String) {
        var bytes: [UInt8] = []
        let groups = hex.split(separator: ":", omittingEmptySubsequences: false)
        guard !groups.isEmpty else { return nil }
        for group in groups {
            guard group.count == 2, let byte = UInt8(group, radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(algorithm: algorithm, bytes: bytes)
    }

    /// Canonical rendering: lowercase algorithm, uppercase colon-separated hex,
    /// which is what browsers and libwebrtc emit.
    public var sdpValue: String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        return "\(algorithm) \(hex)"
    }

    public var usesRequiredAlgorithm: Bool {
        algorithm == Self.requiredAlgorithm
    }

    /// Constant-time comparison of the fingerprint bytes.
    ///
    /// A fingerprint is public information, so timing does not leak a secret
    /// here — but this is the check that decides whether a stream is trusted,
    /// and `security.md` §7 asks for every such comparison to be constant time
    /// so nobody has to reason about which ones are exceptions.
    public func matches(_ other: DTLSFingerprint) -> Bool {
        guard algorithm == other.algorithm else { return false }
        return ConstantTime.equal(Data(bytes), Data(other.bytes))
    }

    // MARK: - SDP

    /// Every `a=fingerprint` line in an SDP blob, session- and media-level.
    public static func fingerprints(inSDP sdp: String) -> [DTLSFingerprint] {
        var found: [DTLSFingerprint] = []
        for rawLine in sdp.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "a=fingerprint:"
            guard line.hasPrefix(prefix) else { continue }
            if let fingerprint = DTLSFingerprint(sdpValue: String(line.dropFirst(prefix.count))) {
                found.append(fingerprint)
            }
        }
        return found
    }
}

/// The outcome of a fingerprint check.
public enum DTLSVerification: Equatable, Sendable {
    /// Everything the peer presented matches what the sealed blob promised.
    case match
    /// At least one value differs — treat as an active attack and tear the
    /// connection down.
    case mismatch
    /// The peer used an algorithm other than SHA-256.
    case unsupportedAlgorithm
    /// Nothing to compare: no fingerprint in the sealed blob, or none presented.
    /// Also a hard failure — an unverifiable stream is not a trusted stream —
    /// but reported separately because it usually means a bug, not an attacker.
    case unavailable

    public var isTrusted: Bool { self == .match }
}

/// The comparison itself, kept away from WebRTC so the failure paths can be
/// tested without a peer connection (`docs/TASKS.md` Phase 2, "DTLS fingerprint
/// binding").
public enum DTLSFingerprintVerifier {

    /// Compares a single observed fingerprint against the sealed one.
    public static func verify(
        expected: DTLSFingerprint?,
        observed: DTLSFingerprint?
    ) -> DTLSVerification {
        guard let expected, let observed else { return .unavailable }
        guard expected.usesRequiredAlgorithm, observed.usesRequiredAlgorithm else {
            return .unsupportedAlgorithm
        }
        return expected.matches(observed) ? .match : .mismatch
    }

    /// Compares the sealed fingerprint against **every** `a=fingerprint` in the
    /// remote SDP.
    ///
    /// All of them must match: a bundled session shares one certificate, so an
    /// SDP that announces two different fingerprints is either broken or an
    /// attempt to slip a second transport past the check.
    public static func verify(
        expected: DTLSFingerprint?,
        remoteSDP: String
    ) -> DTLSVerification {
        let observed = DTLSFingerprint.fingerprints(inSDP: remoteSDP)
        guard let expected, !observed.isEmpty else { return .unavailable }
        guard expected.usesRequiredAlgorithm,
              observed.allSatisfy({ $0.usesRequiredAlgorithm })
        else {
            return .unsupportedAlgorithm
        }
        return observed.allSatisfy { expected.matches($0) } ? .match : .mismatch
    }
}
