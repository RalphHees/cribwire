import XCTest
@testable import CribWireKit

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Records what the client tried to send and replays a canned response.
///
/// An actor so recording is safe no matter which executor the client runs on.
actor MockTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private var responses: [HTTPResponse]

    init(responses: [HTTPResponse] = [HTTPResponse(statusCode: 200, body: Data("{}".utf8))]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return HTTPResponse(statusCode: 200, body: Data("{}".utf8))
        }
        return responses.count == 1 ? responses[0] : responses.removeFirst()
    }

    var lastRequest: HTTPRequest? { requests.last }
}

final class APIClientTests: XCTestCase {

    private var vectors: TestVectors!
    private let baseURL = URL(string: "https://api.cribwire.example")!
    private let fixedDate = Date(timeIntervalSince1970: 1_754_850_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        vectors = try TestVectors.load()
    }

    // MARK: - Signed headers, straight from the vectors

    /// The strongest contract check available offline: a real client call, at
    /// the vector's timestamp, must produce the vector's header byte for byte.
    func testRevokeProducesTheCameraDeviceHeaderFromTheVectors() async throws {
        let example = vectors.authExample("deviceCameraRevoke")
        let transport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
        let client = APIClient(
            configuration: .init(baseURL: baseURL, pairingID: vectors.pairingUUID),
            credentials: .device(
                deviceID: vectors.deviceKeys.cameraDeviceId,
                deviceKey: try cameraDeviceKey()
            ),
            transport: transport,
            now: { [fixedDate] in fixedDate }
        )

        try await client.revokePairing()

        let request = try await lastRequest(from: transport)
        XCTAssertEqual(request.signedPath, example.path)
        XCTAssertEqual(request.method.rawValue, example.method)
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertEqual(
            request.headers[RequestAuthenticator.headerField],
            example.authorizationHeader
        )
    }

    func testTurnCredentialsProducesTheViewerDeviceHeaderFromTheVectors() async throws {
        let example = vectors.authExample("deviceViewerTurnCredentials")
        let body = """
        {"username":"1754853600:\(vectors.requestAuth.pairingId)","credential":"YWJj",\
        "ttlSeconds":3600,"uris":["turn:turn.cribwire.example:3478?transport=udp"]}
        """
        let transport = MockTransport(
            responses: [HTTPResponse(statusCode: 200, body: Data(body.utf8))]
        )
        let client = APIClient(
            configuration: .init(baseURL: baseURL, pairingID: vectors.pairingUUID),
            credentials: .device(
                deviceID: vectors.deviceKeys.viewerDeviceId,
                deviceKey: try viewerDeviceKey()
            ),
            transport: transport,
            now: { [fixedDate] in fixedDate }
        )

        let credentials = try await client.turnCredentials()
        XCTAssertEqual(credentials.ttlSeconds, 3600)
        XCTAssertEqual(credentials.uris.count, 1)
        XCTAssertTrue(credentials.username.hasSuffix(vectors.requestAuth.pairingId))

        let request = try await lastRequest(from: transport)
        XCTAssertEqual(request.signedPath, example.path)
        XCTAssertTrue(request.body.isEmpty, "turn-credentials takes an empty body")
        XCTAssertEqual(
            request.headers[RequestAuthenticator.headerField],
            example.authorizationHeader
        )
    }

    func testWebSocketUpgradeHeaderSignsThePathWithoutQuery() async throws {
        let client = try deviceClient()
        let header = try await client.signalingUpgradeHeader(path: SignalingClient.defaultPath)

        let expected = RequestAuthenticator.device(
            pairingID: vectors.pairingUUID,
            deviceID: vectors.deviceKeys.viewerDeviceId,
            deviceKey: try viewerDeviceKey()
        ).authorizationHeaderValue(
            method: "GET",
            path: "/v1/signal",
            timestamp: "1754850000",
            body: Data()
        )
        XCTAssertEqual(header, expected)
        XCTAssertFalse(header.contains("pairingId="))
    }

    // MARK: - Principal separation

    func testBootstrapClientRefusesDeviceEndpoints() async throws {
        let client = bootstrapClient()
        await assertThrowsWrongCredentials { try await client.revokePairing() }
        await assertThrowsWrongCredentials { try await client.revokeViewer(deviceID: "v") }
        await assertThrowsWrongCredentials { _ = try await client.turnCredentials() }
        await assertThrowsWrongCredentials { try await client.postEvent(ciphertext: "AA==") }
        await assertThrowsWrongCredentials {
            try await client.rotateDeviceToken(apnsToken: "t", apnsEnvironment: .sandbox)
        }
        await assertThrowsWrongCredentials {
            _ = try await client.signalingUpgradeHeader(path: "/v1/signal")
        }
    }

    func testDeviceClientRefusesBootstrapEndpoints() async throws {
        let client = try deviceClient()
        let deviceKey = try DeviceKey.generate()
        await assertThrowsWrongCredentials {
            _ = try await client.createPairing(
                deviceKey: deviceKey,
                apnsToken: "t",
                apnsEnvironment: .sandbox
            )
        }
        await assertThrowsWrongCredentials {
            _ = try await client.claimPairing(
                deviceKey: deviceKey,
                apnsToken: "t",
                apnsEnvironment: .sandbox
            )
        }
    }

    func testDeviceHeaderCarriesTheDeviceIDAndNoRole() async throws {
        let transport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
        let client = try deviceClient(transport: transport)
        try await client.rotateDeviceToken(apnsToken: "t", apnsEnvironment: .sandbox)

        let request = try await lastRequest(from: transport)
        let header = try XCTUnwrap(request.headers[RequestAuthenticator.headerField])
        XCTAssertTrue(
            header.hasPrefix(
                "CribWire-HMAC \(vectors.requestAuth.pairingId):\(vectors.deviceKeys.viewerDeviceId):"
            )
        )
        XCTAssertFalse(header.contains(":viewer:"))
        XCTAssertFalse(header.contains(":camera:"))
    }

    // MARK: - Bodies

    func testCreatePairingBodyMatchesTheProtocolShape() async throws {
        let secret = try RootSecret(
            bytes: try XCTUnwrap(Data.kc_fromHex(vectors.hkdf.rootSecretHex))
        )
        let keys = secret.deriveKeys()
        let deviceKey = try cameraDeviceKey()
        let transport = MockTransport(
            responses: [
                HTTPResponse(
                    statusCode: 201,
                    body: Data(
                        """
                        {"pairingId":"\(vectors.requestAuth.pairingId)",\
                        "deviceId":"\(vectors.deviceKeys.cameraDeviceId)",\
                        "role":"camera","status":"pending","ttlSeconds":600,\
                        "expiresAt":"2026-08-10T20:10:00Z"}
                        """.utf8
                    )
                )
            ]
        )
        let client = APIClient(
            configuration: .init(baseURL: baseURL, pairingID: vectors.pairingUUID),
            keys: keys,
            transport: transport,
            now: { [fixedDate] in fixedDate }
        )

        let response = try await client.createPairing(
            deviceKey: deviceKey,
            apnsToken: "camtoken",
            apnsEnvironment: .production
        )
        XCTAssertEqual(response.ttlSeconds, 600)
        XCTAssertEqual(response.deviceId, vectors.deviceKeys.cameraDeviceId)
        XCTAssertEqual(response.role, "camera")
        XCTAssertEqual(response.status, "pending")

        let request = try await lastRequest(from: transport)
        XCTAssertEqual(request.signedPath, "/v1/pairings")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        XCTAssertEqual(
            Set(json.keys),
            ["pairingId", "kAuth", "deviceKey", "apnsToken", "apnsEnvironment"]
        )
        XCTAssertEqual(json["pairingId"] as? String, vectors.requestAuth.pairingId)
        XCTAssertEqual(
            json["kAuth"] as? String,
            keys.auth.kc_dataRepresentation.base64EncodedString()
        )
        XCTAssertEqual(json["deviceKey"] as? String, vectors.deviceKeys.cameraDeviceKeyBase64)
        XCTAssertEqual(json["apnsEnvironment"] as? String, "production")

        // The root secret must never leave the device — not in any field, not
        // in any encoding.
        let bodyText = String(decoding: request.body, as: UTF8.self)
        XCTAssertFalse(bodyText.contains(secret.base64URLEncoded))
        XCTAssertFalse(bodyText.contains(vectors.hkdf.rootSecretHex))
        XCTAssertFalse(bodyText.contains(secret.rawBytesForKeychainStorage.base64EncodedString()))
    }

    func testClaimBodyMatchesTheProtocolShape() async throws {
        let transport = MockTransport(
            responses: [
                HTTPResponse(
                    statusCode: 201,
                    body: Data(
                        """
                        {"pairingId":"\(vectors.requestAuth.pairingId)",\
                        "deviceId":"\(vectors.deviceKeys.viewerDeviceId)",\
                        "role":"viewer","status":"active","claimedAt":"2026-08-10T20:01:00Z"}
                        """.utf8
                    )
                )
            ]
        )
        let client = bootstrapClient(transport: transport)

        let response = try await client.claimPairing(
            deviceKey: try viewerDeviceKey(),
            apnsToken: "abc123",
            apnsEnvironment: .sandbox
        )
        XCTAssertEqual(response.deviceId, vectors.deviceKeys.viewerDeviceId)
        XCTAssertEqual(response.role, "viewer")

        let request = try await lastRequest(from: transport)
        XCTAssertEqual(
            request.signedPath,
            "/v1/pairings/\(vectors.requestAuth.pairingId)/claim"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["deviceKey", "apnsToken", "apnsEnvironment"])
        XCTAssertEqual(json["deviceKey"] as? String, vectors.deviceKeys.viewerDeviceKeyBase64)
        XCTAssertEqual(json["apnsToken"] as? String, "abc123")
    }

    func testRotateTokenBodyNoLongerNamesTheDevice() async throws {
        let transport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
        try await deviceClient(transport: transport)
            .rotateDeviceToken(apnsToken: "newtoken", apnsEnvironment: .sandbox)

        let request = try await lastRequest(from: transport)
        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.signedPath, "/v1/devices/token")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["apnsToken", "apnsEnvironment"])
        XCTAssertNil(json["deviceId"])
        XCTAssertNil(json["pairingId"])
    }

    func testEventBodyIsCiphertextOnly() async throws {
        let transport = MockTransport(responses: [HTTPResponse(statusCode: 202, body: Data())])
        let sealed = vectors.sealedEnvelope.event.sealedBase64
        try await deviceClient(transport: transport).postEvent(ciphertext: sealed)

        let request = try await lastRequest(from: transport)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.signedPath, "/v1/events")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["ciphertext"])
        XCTAssertEqual(json["ciphertext"] as? String, sealed)
        // Nothing about the event itself may appear in the clear.
        let bodyText = String(decoding: request.body, as: UTF8.self)
        XCTAssertFalse(bodyText.contains("noise"))
        XCTAssertFalse(bodyText.contains("\"ts\""))
    }

    func testBodyEncodingIsDeterministic() async throws {
        // The MAC covers the exact bytes sent, so the encoder must not reorder
        // keys between runs.
        var bodies: [Data] = []
        for _ in 0..<5 {
            let transport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
            try await deviceClient(transport: transport)
                .rotateDeviceToken(apnsToken: "t", apnsEnvironment: .sandbox)
            bodies.append(try await lastRequest(from: transport).body)
        }
        XCTAssertEqual(Set(bodies).count, 1)
    }

    // MARK: - URLs and headers

    func testViewerEvictionPercentEncodesTheDeviceID() async throws {
        let transport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
        try await deviceClient(transport: transport)
            .revokeViewer(deviceID: "weird/id with space")
        let request = try await lastRequest(from: transport)
        XCTAssertEqual(
            request.signedPath,
            "/v1/pairings/\(vectors.requestAuth.pairingId)/viewers/weird%2Fid%20with%20space"
        )
    }

    func testSignedPathNeverIncludesSchemeOrHost() async throws {
        let transport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
        try await deviceClient(transport: transport).revokePairing()
        let request = try await lastRequest(from: transport)
        XCTAssertEqual(
            request.url.absoluteString,
            "https://api.cribwire.example/v1/pairings/\(vectors.requestAuth.pairingId)"
        )
        XCTAssertTrue(request.signedPath.hasPrefix("/v1/"))
        XCTAssertFalse(request.signedPath.contains("https"))
    }

    func testContentTypeIsSetOnlyForRequestsWithABody() async throws {
        let postTransport = MockTransport(
            responses: [
                HTTPResponse(
                    statusCode: 201,
                    body: Data(#"{"pairingId":"p","deviceId":"v"}"#.utf8)
                )
            ]
        )
        _ = try await bootstrapClient(transport: postTransport)
            .claimPairing(deviceKey: try viewerDeviceKey(), apnsToken: "t", apnsEnvironment: .sandbox)
        var request = try await lastRequest(from: postTransport)
        XCTAssertEqual(request.headers["Content-Type"], "application/json")

        let deleteTransport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
        try await deviceClient(transport: deleteTransport).revokePairing()
        request = try await lastRequest(from: deleteTransport)
        XCTAssertNil(request.headers["Content-Type"])
    }

    // MARK: - Error mapping

    func testMapsNotFoundAndGoneToPairingNotFound() async throws {
        for status in [404, 410] {
            let transport = MockTransport(
                responses: [
                    HTTPResponse(
                        statusCode: status,
                        body: Data(#"{"error":"unknown_pairing","message":"gone"}"#.utf8)
                    )
                ]
            )
            do {
                _ = try await bootstrapClient(transport: transport).claimPairing(
                    deviceKey: try viewerDeviceKey(),
                    apnsToken: "t",
                    apnsEnvironment: .sandbox
                )
                XCTFail("expected a failure for status \(status)")
            } catch {
                XCTAssertEqual(error as? APIError, .pairingNotFound)
            }
        }
    }

    func testMapsConflictToViewerLimitReached() async throws {
        let transport = MockTransport(responses: [HTTPResponse(statusCode: 409, body: Data())])
        do {
            _ = try await bootstrapClient(transport: transport).claimPairing(
                deviceKey: try viewerDeviceKey(),
                apnsToken: "t",
                apnsEnvironment: .sandbox
            )
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? APIError, .viewerLimitReached)
            XCTAssertNotNil((error as? APIError)?.userFacingMessage)
        }
    }

    func testSurfacesTheBackendErrorCodeAndMessage() async throws {
        let transport = MockTransport(
            responses: [
                HTTPResponse(
                    statusCode: 429,
                    body: Data(#"{"error":"rate_limited","message":"Too many pairings"}"#.utf8)
                )
            ]
        )
        do {
            _ = try await bootstrapClient(transport: transport).createPairing(
                deviceKey: try cameraDeviceKey(),
                apnsToken: "t",
                apnsEnvironment: .sandbox
            )
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(
                error as? APIError,
                .http(statusCode: 429, code: "rate_limited", message: "Too many pairings")
            )
            XCTAssertEqual((error as? APIError)?.userFacingMessage, "Too many pairings")
        }
    }

    func testUndecodableSuccessBodyIsAnError() async throws {
        let transport = MockTransport(
            responses: [HTTPResponse(statusCode: 200, body: Data("<html>nope</html>".utf8))]
        )
        do {
            _ = try await bootstrapClient(transport: transport).claimPairing(
                deviceKey: try viewerDeviceKey(),
                apnsToken: "t",
                apnsEnvironment: .sandbox
            )
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? APIError, .decodingFailed)
        }
    }

    // MARK: - Helpers

    private func assertThrowsWrongCredentials(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected APIError.wrongCredentials", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? APIError, .wrongCredentials, file: file, line: line)
        }
    }

    /// Actor state has to be read with `await` before `XCTUnwrap` sees it —
    /// `XCTUnwrap`'s autoclosure is not async.
    private func lastRequest(
        from transport: MockTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> HTTPRequest {
        let requests = await transport.requests
        return try XCTUnwrap(requests.last, "no request was sent", file: file, line: line)
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

    private func bootstrapClient(
        transport: MockTransport = MockTransport()
    ) -> APIClient {
        APIClient(
            configuration: .init(baseURL: baseURL, pairingID: vectors.pairingUUID),
            credentials: .bootstrap(authKey: (try? authKey()) ?? SymmetricKey(size: .bits256)),
            transport: transport,
            now: { [fixedDate] in fixedDate }
        )
    }

    private func deviceClient(
        transport: MockTransport = MockTransport()
    ) throws -> APIClient {
        APIClient(
            configuration: .init(baseURL: baseURL, pairingID: vectors.pairingUUID),
            credentials: .device(
                deviceID: vectors.deviceKeys.viewerDeviceId,
                deviceKey: try viewerDeviceKey()
            ),
            transport: transport,
            now: { [fixedDate] in fixedDate }
        )
    }
}
