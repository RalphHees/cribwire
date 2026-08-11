import XCTest
@testable import CribWireKit

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// All four `CribWire-HMAC` examples from the shared vectors, end to end.
///
/// Revision 1.1 is what these lock down: five canonical lines with the principal
/// in the fourth, `bootstrap` signed with `K_auth`, and every other request
/// signed with the calling device's own key.
final class RequestAuthenticatorTests: XCTestCase {

    private var vectors: TestVectors!

    override func setUpWithError() throws {
        try super.setUpWithError()
        vectors = try TestVectors.load()
    }

    // MARK: - Vector reproduction

    func testReproducesEveryAuthVectorExample() throws {
        XCTAssertEqual(vectors.requestAuth.examples.count, 4, "vector file lost an example")

        for (name, example) in vectors.requestAuth.examples {
            let authenticator = try authenticator(for: example)
            let body = Data(example.bodyUtf8.utf8)

            XCTAssertEqual(
                RequestAuthenticator.canonicalString(
                    method: example.method,
                    path: example.path,
                    timestamp: example.timestamp,
                    principal: RequestPrincipal(stringValue: example.principal),
                    body: body
                ),
                example.canonicalString,
                "canonical string for \(name)"
            )

            XCTAssertEqual(
                authenticator.mac(
                    method: example.method,
                    path: example.path,
                    timestamp: example.timestamp,
                    body: body
                ),
                example.macHex,
                "MAC for \(name)"
            )

            XCTAssertEqual(
                authenticator.authorizationHeaderValue(
                    method: example.method,
                    path: example.path,
                    timestamp: example.timestamp,
                    body: body
                ),
                example.authorizationHeader,
                "header for \(name)"
            )
        }
    }

    func testCanonicalStringHasFiveLinesWithThePrincipalFourth() throws {
        let example = vectors.authExample("deviceCameraRevoke")
        let lines = example.canonicalString.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines[0], "DELETE")
        XCTAssertEqual(lines[3], example.principal)
        XCTAssertEqual(lines[4], example.bodySha256Hex)
    }

    func testBootstrapExamplesUseTheLiteralPrincipal() {
        XCTAssertEqual(vectors.authExample("bootstrapCreate").principal, "bootstrap")
        XCTAssertEqual(vectors.authExample("bootstrapClaim").principal, "bootstrap")
        XCTAssertEqual(RequestPrincipal.bootstrap.stringValue, "bootstrap")
        XCTAssertTrue(RequestPrincipal(stringValue: "bootstrap").isBootstrap)
        XCTAssertFalse(RequestPrincipal(stringValue: "bootstrapped").isBootstrap)
    }

    func testDeviceExamplesUseTheDeviceUUIDAsPrincipal() {
        XCTAssertEqual(
            vectors.authExample("deviceCameraRevoke").principal,
            vectors.deviceKeys.cameraDeviceId
        )
        XCTAssertEqual(
            vectors.authExample("deviceViewerTurnCredentials").principal,
            vectors.deviceKeys.viewerDeviceId
        )
    }

    func testAuthKeyIsDerivedFromTheVectorRootSecret() throws {
        // The whole chain: S → K_auth → header, without hard-coding K_auth.
        let secret = try RootSecret(
            bytes: try XCTUnwrap(Data.kc_fromHex(vectors.hkdf.rootSecretHex))
        )
        let example = vectors.authExample("bootstrapCreate")
        let authenticator = RequestAuthenticator.bootstrap(
            pairingID: vectors.pairingUUID,
            keys: secret.deriveKeys()
        )

        XCTAssertEqual(
            authenticator.authorizationHeaderValue(
                method: example.method,
                path: example.path,
                timestamp: example.timestamp,
                body: Data(example.bodyUtf8.utf8)
            ),
            example.authorizationHeader
        )
    }

    // MARK: - The escalation fix itself

    func testTheSameRequestSignedByAnotherPrincipalProducesAnotherMAC() throws {
        // A viewer holds K_auth too, so what stops it revoking the pairing is
        // not secrecy of the key — it is that the server checks the *principal*
        // and the device key behind it.
        let example = vectors.authExample("deviceCameraRevoke")
        let body = Data(example.bodyUtf8.utf8)

        let viewerImpersonatingCamera = RequestAuthenticator.device(
            pairingID: vectors.pairingUUID,
            deviceID: vectors.deviceKeys.cameraDeviceId,
            deviceKey: try viewerDeviceKey()
        )
        XCTAssertNotEqual(
            viewerImpersonatingCamera.mac(
                method: example.method,
                path: example.path,
                timestamp: example.timestamp,
                body: body
            ),
            example.macHex,
            "the camera's device id signed with the viewer's key must not verify"
        )

        let bootstrapSigner = RequestAuthenticator.bootstrap(
            pairingID: vectors.pairingUUID,
            authKey: try authKey()
        )
        XCTAssertNotEqual(
            bootstrapSigner.mac(
                method: example.method,
                path: example.path,
                timestamp: example.timestamp,
                body: body
            ),
            example.macHex,
            "K_auth must not be able to sign a device-principal request"
        )
    }

    func testHeaderCarriesNoRole() throws {
        for (_, example) in vectors.requestAuth.examples {
            let fields = example.authorizationHeader
                .replacingOccurrences(of: "CribWire-HMAC ", with: "")
                .components(separatedBy: ":")
            XCTAssertEqual(fields.count, 4)
            XCTAssertFalse(fields.contains("camera"))
            XCTAssertFalse(fields.contains("viewer"))
        }
    }

    // MARK: - Canonicalisation rules

    func testEmptyBodyHashesTheEmptyString() {
        let canonical = RequestAuthenticator.canonicalString(
            method: "GET",
            path: "/v1/anything",
            timestamp: "1754850000",
            principal: .bootstrap,
            body: Data()
        )
        XCTAssertTrue(
            canonical.hasSuffix(
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            )
        )
    }

    func testMethodIsUppercased() {
        let lower = RequestAuthenticator.canonicalString(
            method: "post",
            path: "/v1/x",
            timestamp: "1",
            principal: .device("d"),
            body: Data()
        )
        let upper = RequestAuthenticator.canonicalString(
            method: "POST",
            path: "/v1/x",
            timestamp: "1",
            principal: .device("d"),
            body: Data()
        )
        XCTAssertEqual(lower, upper)
    }

    func testAnyChangedFieldChangesTheMAC() throws {
        let authenticator = RequestAuthenticator.device(
            pairingID: vectors.pairingUUID,
            deviceID: vectors.deviceKeys.viewerDeviceId,
            deviceKey: try viewerDeviceKey()
        )
        let base = authenticator.mac(
            method: "POST",
            path: "/v1/pairings",
            timestamp: "1754850000",
            body: Data("{}".utf8)
        )

        XCTAssertNotEqual(
            base,
            authenticator.mac(method: "PUT", path: "/v1/pairings", timestamp: "1754850000", body: Data("{}".utf8))
        )
        XCTAssertNotEqual(
            base,
            authenticator.mac(method: "POST", path: "/v1/pairings/x", timestamp: "1754850000", body: Data("{}".utf8))
        )
        XCTAssertNotEqual(
            base,
            authenticator.mac(method: "POST", path: "/v1/pairings", timestamp: "1754850001", body: Data("{}".utf8))
        )
        XCTAssertNotEqual(
            base,
            authenticator.mac(method: "POST", path: "/v1/pairings", timestamp: "1754850000", body: Data("{ }".utf8))
        )

        let otherPrincipal = RequestAuthenticator.device(
            pairingID: vectors.pairingUUID,
            deviceID: vectors.deviceKeys.cameraDeviceId,
            deviceKey: try viewerDeviceKey()
        )
        XCTAssertNotEqual(
            base,
            otherPrincipal.mac(
                method: "POST",
                path: "/v1/pairings",
                timestamp: "1754850000",
                body: Data("{}".utf8)
            ),
            "the principal is inside the signature"
        )
    }

    func testTimestampIsWholeUnixSeconds() {
        let date = Date(timeIntervalSince1970: 1_754_850_000.987)
        XCTAssertEqual(RequestAuthenticator.timestamp(for: date), "1754850000")
    }

    func testHeaderCarriesTheLowercasePairingID() throws {
        let uppercasedID = try XCTUnwrap(
            UUID(uuidString: "7D9F0D2E-3B8A-4C6E-9F1A-2B3C4D5E6F70")
        )
        let authenticator = RequestAuthenticator.bootstrap(
            pairingID: uppercasedID,
            authKey: SymmetricKey(size: .bits256)
        )
        let header = authenticator.authorizationHeaderValue(
            method: "GET",
            path: "/v1/x",
            timestamp: "1",
            body: Data()
        )
        XCTAssertTrue(
            header.hasPrefix("CribWire-HMAC 7d9f0d2e-3b8a-4c6e-9f1a-2b3c4d5e6f70:bootstrap:1:")
        )
    }

    func testDeviceKeysInTheVectorsAreThirtyTwoBytes() throws {
        XCTAssertEqual(try cameraDeviceKey().rawBytesForKeychainStorage.count, 32)
        XCTAssertEqual(try viewerDeviceKey().rawBytesForKeychainStorage.count, 32)
    }

    func testGeneratedDeviceKeysAreFreshAndTheRightLength() throws {
        let first = try DeviceKey.generate()
        let second = try DeviceKey.generate()
        XCTAssertEqual(first.rawBytesForKeychainStorage.count, DeviceKey.byteCount)
        XCTAssertNotEqual(
            first.rawBytesForKeychainStorage,
            second.rawBytesForKeychainStorage
        )
        XCTAssertEqual(
            Data(base64Encoded: first.base64EncodedForUpload),
            first.rawBytesForKeychainStorage
        )
    }

    func testDeviceKeyRejectsTheWrongLength() {
        XCTAssertThrowsError(try DeviceKey(bytes: Data(repeating: 7, count: 31))) { error in
            XCTAssertEqual(
                error as? CryptoError,
                .invalidDeviceKeyLength(expected: 32, actual: 31)
            )
        }
    }

    func testKeyMaterialIsNeverDescribed() throws {
        XCTAssertEqual("\(try cameraDeviceKey())", "DeviceKey(<redacted 32 bytes>)")
    }

    // MARK: - Helpers

    private func authenticator(for example: TestVectors.AuthExample) throws -> RequestAuthenticator {
        switch example.principal {
        case "bootstrap":
            return .bootstrap(pairingID: vectors.pairingUUID, authKey: try authKey())
        case vectors.deviceKeys.cameraDeviceId:
            return .device(
                pairingID: vectors.pairingUUID,
                deviceID: vectors.deviceKeys.cameraDeviceId,
                deviceKey: try cameraDeviceKey()
            )
        case vectors.deviceKeys.viewerDeviceId:
            return .device(
                pairingID: vectors.pairingUUID,
                deviceID: vectors.deviceKeys.viewerDeviceId,
                deviceKey: try viewerDeviceKey()
            )
        default:
            XCTFail("unknown principal \(example.principal) in the vector file")
            throw CocoaError(.coderInvalidValue)
        }
    }

    private func authKey() throws -> SymmetricKey {
        SymmetricKey(data: try XCTUnwrap(Data.kc_fromHex(vectors.key("k_auth").keyHex)))
    }

    private func cameraDeviceKey() throws -> DeviceKey {
        try DeviceKey(
            bytes: try XCTUnwrap(Data(base64Encoded: vectors.deviceKeys.cameraDeviceKeyBase64))
        )
    }

    private func viewerDeviceKey() throws -> DeviceKey {
        try DeviceKey(
            bytes: try XCTUnwrap(Data(base64Encoded: vectors.deviceKeys.viewerDeviceKeyBase64))
        )
    }
}
