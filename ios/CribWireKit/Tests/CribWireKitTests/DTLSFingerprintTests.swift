import XCTest
@testable import CribWireKit

/// The man-in-the-middle defence, tested without a peer connection
/// (`security.md` §4, `docs/TASKS.md` Phase 2 "DTLS fingerprint binding").
final class DTLSFingerprintTests: XCTestCase {

    private let cameraHex =
        "AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:" +
        "AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89"
    private let attackerHex =
        "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:" +
        "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF"

    // MARK: - Parsing

    func testParsesAnSDPFingerprintValue() throws {
        let fingerprint = try XCTUnwrap(DTLSFingerprint(sdpValue: "sha-256 \(cameraHex)"))
        XCTAssertEqual(fingerprint.algorithm, "sha-256")
        XCTAssertEqual(fingerprint.bytes.count, 32)
        XCTAssertEqual(fingerprint.sdpValue, "sha-256 \(cameraHex)")
        XCTAssertTrue(fingerprint.usesRequiredAlgorithm)
    }

    func testAlgorithmCaseIsNormalisedButBytesAreNot() throws {
        // The shared vector writes it as `SHA-256 AB:CD:EF`; libwebrtc emits
        // lowercase. Both have to compare equal.
        let upper = try XCTUnwrap(DTLSFingerprint(sdpValue: "SHA-256 ab:cd:ef"))
        let lower = try XCTUnwrap(DTLSFingerprint(sdpValue: "sha-256 AB:CD:EF"))
        XCTAssertEqual(upper.algorithm, "sha-256")
        XCTAssertTrue(upper.matches(lower))
    }

    func testRejectsMalformedValues() {
        XCTAssertNil(DTLSFingerprint(sdpValue: "sha-256"))
        XCTAssertNil(DTLSFingerprint(sdpValue: "sha-256 AB:CD:EFG"))
        XCTAssertNil(DTLSFingerprint(sdpValue: "sha-256 ABCD"))
        XCTAssertNil(DTLSFingerprint(sdpValue: "sha-256 AB::CD"))
        XCTAssertNil(DTLSFingerprint(algorithm: "sha-256", hex: ""))
    }

    func testFindsEveryFingerprintLineInAnSDP() {
        let sdp = """
        v=0\r
        o=- 1 2 IN IP4 127.0.0.1\r
        a=fingerprint:sha-256 \(cameraHex)\r
        m=video 9 UDP/TLS/RTP/SAVPF 96\r
        a=fingerprint:sha-256 \(cameraHex)\r
        a=setup:actpass\r
        """
        XCTAssertEqual(DTLSFingerprint.fingerprints(inSDP: sdp).count, 2)
        XCTAssertTrue(DTLSFingerprint.fingerprints(inSDP: "v=0\r\n").isEmpty)
    }

    // MARK: - Verification

    func testMatchingFingerprintIsTrusted() throws {
        let expected = try XCTUnwrap(DTLSFingerprint(sdpValue: "sha-256 \(cameraHex)"))
        let observed = try XCTUnwrap(
            DTLSFingerprint(algorithm: "sha-256", hex: cameraHex.lowercased())
        )
        XCTAssertEqual(DTLSFingerprintVerifier.verify(expected: expected, observed: observed), .match)
        XCTAssertTrue(
            DTLSFingerprintVerifier.verify(expected: expected, observed: observed).isTrusted
        )
    }

    /// The scenario the whole mechanism exists for: the backend rewrites the
    /// SDP to terminate DTLS itself, but cannot forge the sealed `fp`.
    func testSubstitutedCertificateIsRejected() throws {
        let sealed = try XCTUnwrap(DTLSFingerprint(sdpValue: "sha-256 \(cameraHex)"))
        let tamperedSDP = """
        v=0
        a=fingerprint:sha-256 \(attackerHex)
        """
        let verification = DTLSFingerprintVerifier.verify(expected: sealed, remoteSDP: tamperedSDP)
        XCTAssertEqual(verification, .mismatch)
        XCTAssertFalse(verification.isTrusted)
    }

    func testOneMismatchingLineFailsTheWholeSDP() throws {
        let sealed = try XCTUnwrap(DTLSFingerprint(sdpValue: "sha-256 \(cameraHex)"))
        let sdp = """
        a=fingerprint:sha-256 \(cameraHex)
        a=fingerprint:sha-256 \(attackerHex)
        """
        XCTAssertEqual(
            DTLSFingerprintVerifier.verify(expected: sealed, remoteSDP: sdp),
            .mismatch
        )
    }

    func testDowngradedAlgorithmIsRejected() throws {
        let sealed = try XCTUnwrap(DTLSFingerprint(sdpValue: "sha-256 \(cameraHex)"))
        let sha1 = "a=fingerprint:sha-1 AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01"
        XCTAssertEqual(
            DTLSFingerprintVerifier.verify(expected: sealed, remoteSDP: sha1),
            .unsupportedAlgorithm
        )
    }

    func testMissingFingerprintIsNotTrusted() throws {
        let sealed = try XCTUnwrap(DTLSFingerprint(sdpValue: "sha-256 \(cameraHex)"))
        XCTAssertEqual(
            DTLSFingerprintVerifier.verify(expected: sealed, remoteSDP: "v=0\na=setup:active"),
            .unavailable
        )
        XCTAssertEqual(
            DTLSFingerprintVerifier.verify(expected: nil, remoteSDP: "a=fingerprint:sha-256 \(cameraHex)"),
            .unavailable
        )
        XCTAssertEqual(DTLSFingerprintVerifier.verify(expected: sealed, observed: nil), .unavailable)
        XCTAssertFalse(DTLSVerification.unavailable.isTrusted)
    }

    func testASingleFlippedByteFails() throws {
        let sealed = try XCTUnwrap(DTLSFingerprint(sdpValue: "sha-256 \(cameraHex)"))
        var bytes = sealed.bytes
        bytes[31] ^= 0x01
        let observed = DTLSFingerprint(algorithm: "sha-256", bytes: bytes)
        XCTAssertEqual(DTLSFingerprintVerifier.verify(expected: sealed, observed: observed), .mismatch)
    }

    func testTruncatedFingerprintFails() throws {
        let sealed = try XCTUnwrap(DTLSFingerprint(sdpValue: "sha-256 \(cameraHex)"))
        let observed = DTLSFingerprint(algorithm: "sha-256", bytes: Array(sealed.bytes.dropLast()))
        XCTAssertEqual(DTLSFingerprintVerifier.verify(expected: sealed, observed: observed), .mismatch)
    }
}
