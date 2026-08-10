import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Async client for the Phase 1 REST surface (`docs/specs/backend.md` §3).
///
/// Every request is signed with `KidsCam-HMAC` over the *exact* bytes that go on
/// the wire, so bodies are encoded once and then both hashed and sent. Bodies use
/// `.sortedKeys` so a request is byte-identical run to run, which makes the
/// signature reproducible in tests.
///
/// An actor because it owns the per-pairing authenticator and is called from the
/// pairing view models on the main actor.
public actor APIClient {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let baseURL: URL
        public let pairingID: UUID
        public let role: PairingRole

        public init(baseURL: URL, pairingID: UUID, role: PairingRole) {
            self.baseURL = baseURL
            self.pairingID = pairingID
            self.role = role
        }
    }

    private let configuration: Configuration
    private let authenticator: RequestAuthenticator
    /// `K_auth`. Held so `createPairing` can upload it; it is the only key the
    /// backend is ever allowed to see.
    private let authKey: SymmetricKey
    private let transport: any HTTPTransport
    /// Injectable so tests can pin the timestamp that goes into the MAC.
    private let now: @Sendable () -> Date

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private let decoder = JSONDecoder()

    public init(
        configuration: Configuration,
        authKey: SymmetricKey,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.authKey = authKey
        self.authenticator = RequestAuthenticator(
            pairingID: configuration.pairingID,
            role: configuration.role,
            authKey: authKey
        )
        self.transport = transport
        self.now = now
    }

    public init(
        configuration: Configuration,
        keys: PairingKeys,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            configuration: configuration,
            authKey: keys.auth,
            transport: transport,
            now: now
        )
    }

    // MARK: - Endpoints

    /// `POST /v1/pairings` — camera registers a pairing before rendering the QR.
    ///
    /// The request is signed with the very key it registers: the backend learns
    /// `K_auth` from the body and can verify the signature against it, which
    /// proves the caller actually holds the key it claims.
    @discardableResult
    public func createPairing(
        apnsToken: String,
        apnsEnvironment: API.APNSEnvironment
    ) async throws -> API.CreatePairingResponse {
        let body = API.CreatePairingRequest(
            pairingId: configuration.pairingID.kc_lowercasedString,
            kAuth: authKey.kc_dataRepresentation.base64EncodedString(),
            apnsToken: apnsToken,
            apnsEnvironment: apnsEnvironment
        )
        return try await send(
            method: .post,
            path: "/v1/pairings",
            body: try encoder.encode(body),
            decoding: API.CreatePairingResponse.self
        )
    }

    /// `POST /v1/pairings/{id}/claim` — viewer proves possession of `K_auth` and
    /// registers for pushes.
    public func claimPairing(
        apnsToken: String,
        apnsEnvironment: API.APNSEnvironment
    ) async throws -> API.ClaimPairingResponse {
        let body = API.ClaimPairingRequest(
            apnsToken: apnsToken,
            apnsEnvironment: apnsEnvironment
        )
        return try await send(
            method: .post,
            path: "/v1/pairings/\(configuration.pairingID.kc_lowercasedString)/claim",
            body: try encoder.encode(body),
            decoding: API.ClaimPairingResponse.self
        )
    }

    /// `DELETE /v1/pairings/{id}` — revoke the whole pairing.
    ///
    /// Server-side revocation is only half of it: the caller must also wipe the
    /// local Keychain items (`security.md` §6), because the peer still holds its
    /// copy of the keys.
    public func revokePairing() async throws {
        try await sendIgnoringBody(
            method: .delete,
            path: "/v1/pairings/\(configuration.pairingID.kc_lowercasedString)",
            body: Data()
        )
    }

    /// `DELETE /v1/pairings/{id}/viewers/{deviceId}` — revoke one viewer.
    public func revokeViewer(deviceID: String) async throws {
        let escapedDeviceID = QRPayload.percentEncoded(deviceID)
        try await sendIgnoringBody(
            method: .delete,
            path: "/v1/pairings/\(configuration.pairingID.kc_lowercasedString)/viewers/\(escapedDeviceID)",
            body: Data()
        )
    }

    /// `PUT /v1/devices/token` — rotate this device's APNs token.
    public func rotateDeviceToken(
        deviceID: String,
        apnsToken: String,
        apnsEnvironment: API.APNSEnvironment
    ) async throws {
        let body = API.RotateDeviceTokenRequest(
            pairingId: configuration.pairingID.kc_lowercasedString,
            deviceId: deviceID,
            apnsToken: apnsToken,
            apnsEnvironment: apnsEnvironment
        )
        try await sendIgnoringBody(
            method: .put,
            path: "/v1/devices/token",
            body: try encoder.encode(body)
        )
    }

    // MARK: - Plumbing

    func buildRequest(
        method: HTTPRequest.Method,
        path: String,
        body: Data
    ) throws -> HTTPRequest {
        guard let url = URL(string: path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw APIError.invalidBaseURL
        }

        var headers = [
            RequestAuthenticator.headerField: authenticator.authorizationHeaderValue(
                method: method.rawValue,
                path: path,
                body: body,
                date: now()
            )
        ]
        if !body.isEmpty {
            headers["Content-Type"] = "application/json"
        }
        headers["Accept"] = "application/json"

        return HTTPRequest(
            method: method,
            url: url,
            signedPath: path,
            headers: headers,
            body: body
        )
    }

    private func send<Response: Decodable>(
        method: HTTPRequest.Method,
        path: String,
        body: Data,
        decoding: Response.Type
    ) async throws -> Response {
        let response = try await perform(method: method, path: path, body: body)
        guard let decoded = try? decoder.decode(Response.self, from: response.body) else {
            throw APIError.decodingFailed
        }
        return decoded
    }

    private func sendIgnoringBody(
        method: HTTPRequest.Method,
        path: String,
        body: Data
    ) async throws {
        _ = try await perform(method: method, path: path, body: body)
    }

    private func perform(
        method: HTTPRequest.Method,
        path: String,
        body: Data
    ) async throws -> HTTPResponse {
        let request = try buildRequest(method: method, path: path, body: body)
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw mapFailure(response)
        }
        return response
    }

    private func mapFailure(_ response: HTTPResponse) -> APIError {
        let decodedMessage = (try? decoder.decode(API.ErrorResponse.self, from: response.body))
            .flatMap { $0.message ?? $0.error }

        switch response.statusCode {
        case 404, 410:
            return .pairingNotFound
        case 409:
            return .viewerLimitReached
        default:
            return .http(statusCode: response.statusCode, message: decodedMessage)
        }
    }
}
