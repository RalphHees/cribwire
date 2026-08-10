import XCTest
@testable import KidsCamKit

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
    private let baseURL = URL(string: "https://api.kidscam.example")!
    private let fixedDate = Date(timeIntervalSince1970: 1_754_850_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        vectors = try TestVectors.load()
    }

    // MARK: - URLs and paths

    func testClaimHitsTheSpecifiedURLAndSignsThePathOnly() async throws {
        let transport = MockTransport(
            responses: [HTTPResponse(statusCode: 200, body: Data(#"{"deviceId":"v-1"}"#.utf8))]
        )
        let client = makeClient(role: .viewer, transport: transport)

        let response = try await client.claimPairing(
            apnsToken: String(repeating: "a", count: 64),
            apnsEnvironment: .sandbox
        )
        XCTAssertEqual(response.deviceId, "v-1")

        let request = try await lastRequest(from: transport)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(
            request.url.absoluteString,
            "https://api.kidscam.example/v1/pairings/\(vectors.requestAuth.pairingId)/claim"
        )
        XCTAssertEqual(
            request.signedPath,
            "/v1/pairings/\(vectors.requestAuth.pairingId)/claim"
        )
        XCTAssertFalse(request.signedPath.contains("https"), "PATH must not include scheme/host")
    }

    func testEveryPhase1EndpointUsesTheSpecifiedMethodAndPath() async throws {
        let pairingPath = "/v1/pairings/\(vectors.requestAuth.pairingId)"

        let createTransport = MockTransport(
            responses: [HTTPResponse(statusCode: 201, body: Data(#"{"expiresInSeconds":600,"deviceId":"c-1"}"#.utf8))]
        )
        let create = try await makeClient(role: .camera, transport: createTransport)
            .createPairing(apnsToken: "token", apnsEnvironment: .production)
        XCTAssertEqual(create.expiresInSeconds, 600)
        var request = try await lastRequest(from: createTransport)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.signedPath, "/v1/pairings")

        let revokeTransport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
        try await makeClient(role: .camera, transport: revokeTransport).revokePairing()
        request = try await lastRequest(from: revokeTransport)
        XCTAssertEqual(request.method, .delete)
        XCTAssertEqual(request.signedPath, pairingPath)
        XCTAssertTrue(request.body.isEmpty)

        let viewerTransport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
        try await makeClient(role: .camera, transport: viewerTransport)
            .revokeViewer(deviceID: "viewer-42")
        request = try await lastRequest(from: viewerTransport)
        XCTAssertEqual(request.method, .delete)
        XCTAssertEqual(request.signedPath, "\(pairingPath)/viewers/viewer-42")

        let rotateTransport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
        try await makeClient(role: .viewer, transport: rotateTransport)
            .rotateDeviceToken(deviceID: "v-1", apnsToken: "newtoken", apnsEnvironment: .sandbox)
        request = try await lastRequest(from: rotateTransport)
        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.signedPath, "/v1/devices/token")
    }

    func testDeviceIDIsPercentEncodedInThePath() async throws {
        let transport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
        try await makeClient(role: .camera, transport: transport)
            .revokeViewer(deviceID: "weird/id with space")
        let request = try await lastRequest(from: transport)
        XCTAssertEqual(
            request.signedPath,
            "/v1/pairings/\(vectors.requestAuth.pairingId)/viewers/weird%2Fid%20with%20space"
        )
    }

    // MARK: - Headers

    func testAuthorizationHeaderMatchesTheSignedRequestBytes() async throws {
        let transport = MockTransport(
            responses: [HTTPResponse(statusCode: 200, body: Data(#"{"deviceId":"v-1"}"#.utf8))]
        )
        let client = makeClient(role: .viewer, transport: transport)
        _ = try await client.claimPairing(apnsToken: "t", apnsEnvironment: .sandbox)

        let request = try await lastRequest(from: transport)
        let header = try XCTUnwrap(request.headers[RequestAuthenticator.headerField])

        // Recompute independently from the bytes that actually went out.
        let expected = RequestAuthenticator(
            pairingID: vectors.pairingUUID,
            role: .viewer,
            authKey: try authKey()
        ).authorizationHeaderValue(
            method: "POST",
            path: request.signedPath,
            timestamp: "1754850000",
            body: request.body
        )
        XCTAssertEqual(header, expected)
        XCTAssertTrue(
            header.hasPrefix("KidsCam-HMAC \(vectors.requestAuth.pairingId):viewer:1754850000:")
        )
    }

    func testHeaderCarriesTheCallersRole() async throws {
        let transport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
        try await makeClient(role: .camera, transport: transport).revokePairing()
        let request = try await lastRequest(from: transport)
        let header = try XCTUnwrap(request.headers[RequestAuthenticator.headerField])
        XCTAssertTrue(header.contains(":camera:"))
    }

    func testContentTypeIsSetOnlyForRequestsWithABody() async throws {
        let postTransport = MockTransport(
            responses: [HTTPResponse(statusCode: 200, body: Data(#"{"deviceId":"v"}"#.utf8))]
        )
        _ = try await makeClient(role: .viewer, transport: postTransport)
            .claimPairing(apnsToken: "t", apnsEnvironment: .sandbox)
        var request = try await lastRequest(from: postTransport)
        XCTAssertEqual(request.headers["Content-Type"], "application/json")

        let deleteTransport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
        try await makeClient(role: .camera, transport: deleteTransport).revokePairing()
        request = try await lastRequest(from: deleteTransport)
        XCTAssertNil(request.headers["Content-Type"])
    }

    // MARK: - Bodies

    func testClaimBodyUsesTheFieldNamesFromTheSharedVector() async throws {
        let transport = MockTransport(
            responses: [HTTPResponse(statusCode: 200, body: Data(#"{"deviceId":"v"}"#.utf8))]
        )
        _ = try await makeClient(role: .viewer, transport: transport)
            .claimPairing(apnsToken: "abc123", apnsEnvironment: .sandbox)

        let body = try await lastRequest(from: transport).body
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(decoded?["apnsToken"], "abc123")
        XCTAssertEqual(decoded?["apnsEnvironment"], "sandbox")
        XCTAssertEqual(decoded?.count, 2, "no extra fields on the wire")
    }

    func testCreatePairingUploadsKAuthAndNeverTheRootSecret() async throws {
        let secret = try RootSecret(
            bytes: try XCTUnwrap(Data.kc_fromHex(vectors.hkdf.rootSecretHex))
        )
        let keys = secret.deriveKeys()
        let transport = MockTransport(
            responses: [HTTPResponse(statusCode: 201, body: Data(#"{"expiresInSeconds":600,"deviceId":"c"}"#.utf8))]
        )
        let client = APIClient(
            configuration: .init(baseURL: baseURL, pairingID: vectors.pairingUUID, role: .camera),
            keys: keys,
            transport: transport,
            now: { [fixedDate] in fixedDate }
        )
        try await client.createPairing(apnsToken: "camtoken", apnsEnvironment: .production)

        let body = try await lastRequest(from: transport).body
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(
            json["kAuth"] as? String,
            keys.auth.kc_dataRepresentation.base64EncodedString()
        )
        // The root secret must never leave the device — not in any field, not
        // in any encoding.
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(bodyText.contains(secret.base64URLEncoded))
        XCTAssertFalse(bodyText.contains(vectors.hkdf.rootSecretHex))
        XCTAssertFalse(bodyText.contains(secret.rawBytesForKeychainStorage.base64EncodedString()))
    }

    func testBodyEncodingIsDeterministic() async throws {
        // The MAC covers the exact bytes sent, so the encoder must not reorder
        // keys between runs.
        var bodies: [Data] = []
        for _ in 0..<5 {
            let transport = MockTransport(responses: [HTTPResponse(statusCode: 204, body: Data())])
            try await makeClient(role: .viewer, transport: transport)
                .rotateDeviceToken(deviceID: "d", apnsToken: "t", apnsEnvironment: .sandbox)
            bodies.append(try await lastRequest(from: transport).body)
        }
        XCTAssertEqual(Set(bodies).count, 1)
    }

    // MARK: - Error mapping

    func testMapsNotFoundAndGoneToPairingNotFound() async throws {
        for status in [404, 410] {
            let transport = MockTransport(responses: [HTTPResponse(statusCode: status, body: Data())])
            let client = makeClient(role: .viewer, transport: transport)
            do {
                _ = try await client.claimPairing(apnsToken: "t", apnsEnvironment: .sandbox)
                XCTFail("expected a failure for status \(status)")
            } catch {
                XCTAssertEqual(error as? APIError, .pairingNotFound)
            }
        }
    }

    func testMapsConflictToViewerLimitReached() async {
        let transport = MockTransport(responses: [HTTPResponse(statusCode: 409, body: Data())])
        let client = makeClient(role: .viewer, transport: transport)
        do {
            _ = try await client.claimPairing(apnsToken: "t", apnsEnvironment: .sandbox)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? APIError, .viewerLimitReached)
            XCTAssertNotNil((error as? APIError)?.userFacingMessage)
        }
    }

    func testSurfacesTheBackendMessageOnOtherErrors() async {
        let transport = MockTransport(
            responses: [
                HTTPResponse(
                    statusCode: 429,
                    body: Data(#"{"error":"rate_limited","message":"Too many pairings"}"#.utf8)
                )
            ]
        )
        let client = makeClient(role: .camera, transport: transport)
        do {
            _ = try await client.createPairing(apnsToken: "t", apnsEnvironment: .sandbox)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(
                error as? APIError,
                .http(statusCode: 429, message: "Too many pairings")
            )
        }
    }

    func testUndecodableSuccessBodyIsAnError() async {
        let transport = MockTransport(
            responses: [HTTPResponse(statusCode: 200, body: Data("<html>nope</html>".utf8))]
        )
        let client = makeClient(role: .viewer, transport: transport)
        do {
            _ = try await client.claimPairing(apnsToken: "t", apnsEnvironment: .sandbox)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? APIError, .decodingFailed)
        }
    }

    // MARK: - Helpers

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

    private func makeClient(role: PairingRole, transport: MockTransport) -> APIClient {
        APIClient(
            configuration: .init(baseURL: baseURL, pairingID: vectors.pairingUUID, role: role),
            authKey: (try? authKey()) ?? SymmetricKey(size: .bits256),
            transport: transport,
            now: { [fixedDate] in fixedDate }
        )
    }
}
