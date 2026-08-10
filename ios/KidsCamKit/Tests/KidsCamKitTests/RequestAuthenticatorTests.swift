import XCTest
@testable import KidsCamKit

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Both `KidsCam-HMAC` examples from the shared vectors, end to end.
final class RequestAuthenticatorTests: XCTestCase {

    private var vectors: TestVectors!

    override func setUpWithError() throws {
        try super.setUpWithError()
        vectors = try TestVectors.load()
    }

    func testReproducesEveryAuthVectorExample() throws {
        let authKey = SymmetricKey(
            data: try XCTUnwrap(Data.kc_fromHex(vectors.key("k_auth").keyHex))
        )

        for example in vectors.requestAuth.examples {
            let role = try XCTUnwrap(PairingRole(rawValue: example.role))
            let body = Data(example.bodyUtf8.utf8)

            let canonical = RequestAuthenticator.canonicalString(
                method: example.method,
                path: example.path,
                timestamp: example.timestamp,
                body: body
            )
            XCTAssertEqual(canonical, example.canonicalString, "canonical string for \(example.role)")

            let authenticator = RequestAuthenticator(
                pairingID: vectors.pairingUUID,
                role: role,
                authKey: authKey
            )

            XCTAssertEqual(
                authenticator.mac(
                    method: example.method,
                    path: example.path,
                    timestamp: example.timestamp,
                    body: body
                ),
                example.macHex,
                "MAC for \(example.role)"
            )

            XCTAssertEqual(
                authenticator.authorizationHeaderValue(
                    method: example.method,
                    path: example.path,
                    timestamp: example.timestamp,
                    body: body
                ),
                example.authorizationHeader,
                "header for \(example.role)"
            )
        }
    }

    func testAuthKeyIsDerivedFromTheVectorRootSecret() throws {
        // The whole chain: S → K_auth → header, without hard-coding K_auth.
        let secret = try RootSecret(
            bytes: try XCTUnwrap(Data.kc_fromHex(vectors.hkdf.rootSecretHex))
        )
        let example = try XCTUnwrap(vectors.requestAuth.examples.first)
        let authenticator = RequestAuthenticator(
            pairingID: vectors.pairingUUID,
            role: try XCTUnwrap(PairingRole(rawValue: example.role)),
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

    func testEmptyBodyHashesTheEmptyString() {
        let canonical = RequestAuthenticator.canonicalString(
            method: "GET",
            path: "/v1/anything",
            timestamp: "1754850000",
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
            body: Data()
        )
        let upper = RequestAuthenticator.canonicalString(
            method: "POST",
            path: "/v1/x",
            timestamp: "1",
            body: Data()
        )
        XCTAssertEqual(lower, upper)
    }

    func testAnyChangedFieldChangesTheMAC() throws {
        let authenticator = RequestAuthenticator(
            pairingID: vectors.pairingUUID,
            role: .viewer,
            authKey: SymmetricKey(
                data: try XCTUnwrap(Data.kc_fromHex(vectors.key("k_auth").keyHex))
            )
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
    }

    func testTimestampIsWholeUnixSeconds() {
        let date = Date(timeIntervalSince1970: 1_754_850_000.987)
        XCTAssertEqual(RequestAuthenticator.timestamp(for: date), "1754850000")
    }

    func testHeaderCarriesLowercasePairingIDAndRole() throws {
        let uppercasedID = try XCTUnwrap(
            UUID(uuidString: "7D9F0D2E-3B8A-4C6E-9F1A-2B3C4D5E6F70")
        )
        let authenticator = RequestAuthenticator(
            pairingID: uppercasedID,
            role: .camera,
            authKey: SymmetricKey(size: .bits256)
        )
        let header = authenticator.authorizationHeaderValue(
            method: "GET",
            path: "/v1/x",
            timestamp: "1",
            body: Data()
        )
        XCTAssertTrue(
            header.hasPrefix("KidsCam-HMAC 7d9f0d2e-3b8a-4c6e-9f1a-2b3c4d5e6f70:camera:1:")
        )
    }
}
