import XCTest
@testable import CribWireKit

/// The QR payload is the trust anchor of the whole system (`security.md` §2), so
/// both directions are checked against the shared vector and the parser is
/// probed with the malformed inputs an attacker controls.
final class QRPayloadTests: XCTestCase {

    private var vectors: TestVectors!

    override func setUpWithError() throws {
        try super.setUpWithError()
        vectors = try TestVectors.load()
    }

    // MARK: - Encoding

    func testEncodesExactlyTheVectorURL() throws {
        let secretBytes = try XCTUnwrap(Data.kc_fromHex(vectors.hkdf.rootSecretHex))
        let payload = QRPayload(
            pairingID: try XCTUnwrap(UUID(uuidString: "7d9f0d2e-3b8a-4c6e-9f1a-2b3c4d5e6f70")),
            rootSecret: try RootSecret(bytes: secretBytes),
            apiBaseURL: try XCTUnwrap(URL(string: "https://api.cribwire.example"))
        )
        XCTAssertEqual(payload.urlString(), vectors.qrPayload.example)
    }

    func testEncodesRootSecretAsBase64URLWithoutPadding() throws {
        let secretBytes = try XCTUnwrap(Data.kc_fromHex(vectors.hkdf.rootSecretHex))
        let secret = try RootSecret(bytes: secretBytes)
        XCTAssertEqual(secret.base64URLEncoded, vectors.qrPayload.sBase64url)
        XCTAssertFalse(secret.base64URLEncoded.contains("="))
        XCTAssertFalse(secret.base64URLEncoded.contains("+"))
        XCTAssertFalse(secret.base64URLEncoded.contains("/"))
    }

    // MARK: - Parsing

    func testParsesTheVectorURL() throws {
        let parsed = try QRPayload.parse(vectors.qrPayload.example)

        XCTAssertEqual(parsed.pairingID.kc_lowercasedString, "7d9f0d2e-3b8a-4c6e-9f1a-2b3c4d5e6f70")
        XCTAssertEqual(parsed.apiBaseURL.absoluteString, "https://api.cribwire.example")
        XCTAssertEqual(
            parsed.rootSecret.rawBytesForKeychainStorage.kc_hexEncodedString,
            vectors.hkdf.rootSecretHex
        )
    }

    func testRoundTripsThroughEncodeAndParse() throws {
        let original = QRPayload(
            pairingID: UUID(),
            rootSecret: try RootSecret.generate(),
            apiBaseURL: try XCTUnwrap(URL(string: "https://eu.api.cribwire.example"))
        )
        let parsed = try QRPayload.parse(original.urlString())

        XCTAssertEqual(parsed.pairingID, original.pairingID)
        XCTAssertEqual(parsed.apiBaseURL, original.apiBaseURL)
        XCTAssertEqual(
            parsed.rootSecret.rawBytesForKeychainStorage,
            original.rootSecret.rawBytesForKeychainStorage
        )
    }

    func testDerivedKeysSurviveTheRoundTrip() throws {
        // The point of the QR: both devices must land on identical keys.
        let secretBytes = try XCTUnwrap(Data.kc_fromHex(vectors.hkdf.rootSecretHex))
        let camera = QRPayload(
            pairingID: vectors.pairingUUID,
            rootSecret: try RootSecret(bytes: secretBytes),
            apiBaseURL: try XCTUnwrap(URL(string: "https://api.cribwire.example"))
        )
        let viewer = try QRPayload.parse(camera.urlString())

        XCTAssertEqual(
            viewer.rootSecret.deriveKeys().sasCode.digits,
            camera.rootSecret.deriveKeys().sasCode.digits
        )
        XCTAssertEqual(viewer.rootSecret.deriveKeys().sasCode.digits, vectors.sas.code)
    }

    func testIgnoresUnknownQueryParameters() throws {
        let extended = vectors.qrPayload.example + "&future=whatever&x=1"
        let parsed = try QRPayload.parse(extended)
        XCTAssertEqual(parsed.pairingID, vectors.pairingUUID)
    }

    func testRejectsOtherVersions() {
        let v2 = vectors.qrPayload.example.replacingOccurrences(of: "v=1", with: "v=2")
        assertParseError(v2, .unsupportedVersion("2"))

        let missing = vectors.qrPayload.example.replacingOccurrences(of: "v=1&", with: "")
        assertParseError(missing, .unsupportedVersion(nil))
    }

    func testRejectsNonCribWireURLs() {
        assertParseError("https://example.com/pair?v=1", .notAPairingURL)
        assertParseError("cribwire://other?v=1", .notAPairingURL)
        assertParseError("just some scanned text", .notAPairingURL)
    }

    func testRejectsBadPairingID() {
        let broken = vectors.qrPayload.example.replacingOccurrences(
            of: "7d9f0d2e-3b8a-4c6e-9f1a-2b3c4d5e6f70",
            with: "not-a-uuid"
        )
        assertParseError(broken, .invalidPairingID)
    }

    func testRejectsWrongLengthSecret() {
        let short = vectors.qrPayload.example.replacingOccurrences(
            of: "s=\(vectors.qrPayload.sBase64url)",
            with: "s=AAEC"
        )
        assertParseError(short, .invalidRootSecret)
    }

    func testRejectsPaddedOrStandardBase64Secret() {
        // base64url is normative; accepting standard base64 would mean two
        // encodings of the same secret and a needless interop trap.
        let padded = vectors.qrPayload.example.replacingOccurrences(
            of: "s=\(vectors.qrPayload.sBase64url)",
            with: "s=\(vectors.qrPayload.sBase64url)="
        )
        assertParseError(padded, .invalidRootSecret)
    }

    func testRejectsNonHTTPSAPIURL() {
        let insecure = vectors.qrPayload.example.replacingOccurrences(
            of: "https%3A%2F%2F",
            with: "http%3A%2F%2F"
        )
        assertParseError(insecure, .invalidAPIBaseURL)
    }

    func testFirstOccurrenceOfADuplicatedParameterWins() throws {
        // A smuggled second `s=` must not override the first one.
        let attacker = vectors.qrPayload.example + "&s=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHiA"
        let parsed = try QRPayload.parse(attacker)
        XCTAssertEqual(
            parsed.rootSecret.rawBytesForKeychainStorage.kc_hexEncodedString,
            vectors.hkdf.rootSecretHex
        )
    }

    func testDescriptionNeverIncludesTheSecret() throws {
        let payload = try QRPayload.parse(vectors.qrPayload.example)
        XCTAssertFalse(payload.description.contains(vectors.qrPayload.sBase64url))
        XCTAssertTrue(payload.description.contains("redacted"))
    }

    // MARK: - Helper

    private func assertParseError(
        _ string: String,
        _ expected: QRPayload.ParseError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try QRPayload.parse(string), file: file, line: line) { error in
            XCTAssertEqual(error as? QRPayload.ParseError, expected, file: file, line: line)
        }
    }
}
