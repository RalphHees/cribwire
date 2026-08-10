import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Async client for the `/v1` REST surface (`docs/specs/backend.md` §3, bodies
/// pinned in `shared/protocol.md`).
///
/// Every request is signed with `KidsCam-HMAC` over the *exact* bytes that go on
/// the wire, so bodies are encoded once and then both hashed and sent. Bodies use
/// `.sortedKeys` so a request is byte-identical run to run, which makes the
/// signature reproducible in tests.
///
/// A client is built for one set of credentials and refuses to mix them: the
/// bootstrap client can only create and claim pairings, the device client can do
/// everything else. That is not a stylistic split — it is the protocol's
/// escalation fix expressed in the type system (`shared/protocol.md`, "Why
/// per-device keys").
///
/// An actor because it owns the authenticator and is called from view models on
/// the main actor.
public actor APIClient {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let baseURL: URL
        public let pairingID: UUID

        public init(baseURL: URL, pairingID: UUID) {
            self.baseURL = baseURL
            self.pairingID = pairingID
        }
    }

    /// Which key signs this client's requests.
    /// `@unchecked Sendable`: `SymmetricKey`/`DeviceKey` are immutable value
    /// types not declared `Sendable` in every SDK version we build against.
    public enum Credentials: @unchecked Sendable {
        /// `K_auth`. Valid for `POST /v1/pairings` and `.../claim` only.
        case bootstrap(authKey: SymmetricKey)
        /// This device's registered key, for everything afterwards.
        case device(deviceID: String, deviceKey: DeviceKey)
    }

    private let configuration: Configuration
    private let credentials: Credentials
    private let authenticator: RequestAuthenticator
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
        credentials: Credentials,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.credentials = credentials
        switch credentials {
        case .bootstrap(let authKey):
            self.authenticator = .bootstrap(pairingID: configuration.pairingID, authKey: authKey)
        case .device(let deviceID, let deviceKey):
            self.authenticator = .device(
                pairingID: configuration.pairingID,
                deviceID: deviceID,
                deviceKey: deviceKey
            )
        }
        self.transport = transport
        self.now = now
    }

    /// Bootstrap client for a pairing whose keys have just been derived.
    public init(
        configuration: Configuration,
        keys: PairingKeys,
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            configuration: configuration,
            credentials: .bootstrap(authKey: keys.auth),
            transport: transport,
            now: now
        )
    }

    // MARK: - Bootstrap endpoints

    /// `POST /v1/pairings` — camera registers a pairing before rendering the QR.
    ///
    /// The request is signed with the very key it registers: the backend learns
    /// `K_auth` from the body and verifies the signature against it, which proves
    /// the caller holds the key it claims. `deviceKey` is this camera's own,
    /// freshly generated key — the caller must persist it together with the
    /// returned `deviceId`, because every later request is signed with it.
    public func createPairing(
        deviceKey: DeviceKey,
        apnsToken: String,
        apnsEnvironment: API.APNSEnvironment
    ) async throws -> API.CreatePairingResponse {
        guard case .bootstrap(let authKey) = credentials else {
            throw APIError.wrongCredentials
        }
        let body = API.CreatePairingRequest(
            pairingId: configuration.pairingID.kc_lowercasedString,
            kAuth: authKey.kc_dataRepresentation.base64EncodedString(),
            deviceKey: deviceKey.base64EncodedForUpload,
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

    /// `POST /v1/pairings/{id}/claim` — viewer proves possession of `K_auth`,
    /// registers its own key and its APNs token.
    public func claimPairing(
        deviceKey: DeviceKey,
        apnsToken: String,
        apnsEnvironment: API.APNSEnvironment
    ) async throws -> API.ClaimPairingResponse {
        guard case .bootstrap = credentials else {
            throw APIError.wrongCredentials
        }
        let body = API.ClaimPairingRequest(
            deviceKey: deviceKey.base64EncodedForUpload,
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

    // MARK: - Device endpoints

    /// `DELETE /v1/pairings/{id}` — revoke the whole pairing.
    ///
    /// Server-side revocation is only half of it: the caller must also wipe the
    /// local Keychain items (`security.md` §6), because the peer still holds its
    /// copy of the keys.
    public func revokePairing() async throws {
        try requireDeviceCredentials()
        try await sendIgnoringBody(
            method: .delete,
            path: "/v1/pairings/\(configuration.pairingID.kc_lowercasedString)",
            body: Data()
        )
    }

    /// `DELETE /v1/pairings/{id}/viewers/{deviceId}` — evict one viewer.
    /// The server allows this only if the *calling* device's row says `camera`.
    public func revokeViewer(deviceID: String) async throws {
        try requireDeviceCredentials()
        let escapedDeviceID = QRPayload.percentEncoded(deviceID)
        try await sendIgnoringBody(
            method: .delete,
            path: "/v1/pairings/\(configuration.pairingID.kc_lowercasedString)/viewers/\(escapedDeviceID)",
            body: Data()
        )
    }

    /// `PUT /v1/devices/token` — rotate this device's APNs token. Which device
    /// is identified by the signature, so the body names no one.
    public func rotateDeviceToken(
        apnsToken: String,
        apnsEnvironment: API.APNSEnvironment
    ) async throws {
        try requireDeviceCredentials()
        let body = API.RotateDeviceTokenRequest(
            apnsToken: apnsToken,
            apnsEnvironment: apnsEnvironment
        )
        try await sendIgnoringBody(
            method: .put,
            path: "/v1/devices/token",
            body: try encoder.encode(body)
        )
    }

    /// `POST /v1/pairings/{id}/turn-credentials` — ephemeral relay credentials.
    /// Empty request body; either role may ask.
    public func turnCredentials() async throws -> API.TurnCredentialsResponse {
        try requireDeviceCredentials()
        return try await send(
            method: .post,
            path: "/v1/pairings/\(configuration.pairingID.kc_lowercasedString)/turn-credentials",
            body: Data(),
            decoding: API.TurnCredentialsResponse.self
        )
    }

    /// `POST /v1/events` — camera posts a sealed detection event.
    ///
    /// The argument is already a `SealedEnvelope` under `K_evt`; this client
    /// never sees the plaintext type or timestamp, and neither does the server.
    public func postEvent(ciphertext: String) async throws {
        try requireDeviceCredentials()
        let body = API.PostEventRequest(ciphertext: ciphertext)
        try await sendIgnoringBody(
            method: .post,
            path: "/v1/events",
            body: try encoder.encode(body)
        )
    }

    // MARK: - Signaling

    /// The `Authorization` header for the WebSocket upgrade
    /// (`GET /v1/signal`). The path is signed without its query string, exactly
    /// like a REST path.
    public func signalingUpgradeHeader(path: String) throws -> String {
        try requireDeviceCredentials()
        return authenticator.authorizationHeaderValue(
            method: HTTPRequest.Method.get.rawValue,
            path: path,
            body: Data(),
            date: now()
        )
    }

    // MARK: - Plumbing

    private func requireDeviceCredentials() throws {
        guard case .device = credentials else {
            throw APIError.wrongCredentials
        }
    }

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
        let decoded = try? decoder.decode(API.ErrorResponse.self, from: response.body)

        switch response.statusCode {
        case 404, 410:
            return .pairingNotFound
        case 409:
            // `shared/protocol.md` gives 409 three meanings — viewer limit,
            // duplicate pairing id, revoked — but does not pin the `error`
            // strings that tell them apart, so this cannot branch on the code
            // without inventing one. The viewer limit is the only 409 a user can
            // do anything about and the only one reachable in practice (a
            // duplicate UUIDv4 is not a real scenario), so it stays the mapping.
            return .viewerLimitReached
        default:
            return .http(
                statusCode: response.statusCode,
                code: decoded?.error,
                message: decoded?.message
            )
        }
    }
}
