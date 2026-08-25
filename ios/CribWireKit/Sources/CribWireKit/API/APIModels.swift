import Foundation

/// Request and response bodies for the `/v1` REST surface.
///
/// These shapes are **normative**: `shared/protocol.md` revision 1.1 pins every
/// field name under "REST bodies", and the backend is cross-implemented against
/// the same section. Revision 1.0 left them to prose and the two sides diverged
/// (the server returns `ttlSeconds`, this client used to expect
/// `expiresInSeconds` — a mismatch that would only have surfaced at runtime), so
/// changing anything here means changing `shared/protocol.md` and the backend in
/// the same change set.
///
/// Conventions from that section:
///
/// - binary values are standard base64 with padding;
/// - unknown *response* fields are ignored (which `JSONDecoder` does for us), so
///   the server can add fields without breaking shipped clients;
/// - unknown *request* fields are rejected by the server, so nothing extra may
///   ever be added to a request struct "just in case";
/// - timestamps are RFC 3339 UTC strings, kept as `String` because nothing in
///   the client does arithmetic on them.
public enum API {

    // MARK: - POST /v1/pairings  (principal `bootstrap`, signed with K_auth)

    /// Camera registers a pairing before showing the QR.
    ///
    /// Self-authenticating: the body carries the very `kAuth` the request is
    /// signed with, and the header's `pairingId` must equal this body's. `S` is
    /// never uploaded — only the key derived from it.
    public struct CreatePairingRequest: Codable, Equatable, Sendable {
        /// Lowercase UUID.
        public let pairingId: String
        /// `K_auth`, base64.
        public let kAuth: String
        /// The camera's own 32-byte authentication key, base64. Registered here
        /// once and used to sign everything after this call.
        public let deviceKey: String
        /// APNs device token, hex.
        public let apnsToken: String
        /// `sandbox` | `production`.
        public let apnsEnvironment: String

        public init(
            pairingId: String,
            kAuth: String,
            deviceKey: String,
            apnsToken: String,
            apnsEnvironment: APNSEnvironment
        ) {
            self.pairingId = pairingId
            self.kAuth = kAuth
            self.deviceKey = deviceKey
            self.apnsToken = apnsToken
            self.apnsEnvironment = apnsEnvironment.rawValue
        }
    }

    /// `201`. `deviceId` is this camera's identity from now on: it is the
    /// principal in every later `CribWire-HMAC` header.
    ///
    /// `role`, `status` and `expiresAt` are optional in the *decoder* only —
    /// they are pinned in the protocol, but nothing in the client depends on
    /// them, and a client that hard-fails on a field it does not use turns a
    /// harmless server change into an outage.
    public struct CreatePairingResponse: Codable, Equatable, Sendable {
        public let pairingId: String
        public let deviceId: String
        /// Seconds until an unclaimed pairing expires (protocol: 600).
        public let ttlSeconds: Int
        public let role: String?
        public let status: String?
        public let expiresAt: String?

        public init(
            pairingId: String,
            deviceId: String,
            ttlSeconds: Int,
            role: String? = nil,
            status: String? = nil,
            expiresAt: String? = nil
        ) {
            self.pairingId = pairingId
            self.deviceId = deviceId
            self.ttlSeconds = ttlSeconds
            self.role = role
            self.status = status
            self.expiresAt = expiresAt
        }
    }

    // MARK: - POST /v1/pairings/{id}/claim  (principal `bootstrap`)

    /// Viewer claims a pairing it has just scanned, registering its own key and
    /// its APNs token. The pairing id travels in the path, not the body.
    public struct ClaimPairingRequest: Codable, Equatable, Sendable {
        /// The viewer's own 32-byte authentication key, base64.
        public let deviceKey: String
        public let apnsToken: String
        public let apnsEnvironment: String

        public init(deviceKey: String, apnsToken: String, apnsEnvironment: APNSEnvironment) {
            self.deviceKey = deviceKey
            self.apnsToken = apnsToken
            self.apnsEnvironment = apnsEnvironment.rawValue
        }
    }

    /// `201`. `deviceId` is the viewer's identity: its principal from now on,
    /// and the id the camera uses to evict this viewer specifically.
    public struct ClaimPairingResponse: Codable, Equatable, Sendable {
        public let pairingId: String
        public let deviceId: String
        public let role: String?
        public let status: String?
        public let claimedAt: String?

        public init(
            pairingId: String,
            deviceId: String,
            role: String? = nil,
            status: String? = nil,
            claimedAt: String? = nil
        ) {
            self.pairingId = pairingId
            self.deviceId = deviceId
            self.role = role
            self.status = status
            self.claimedAt = claimedAt
        }
    }

    // MARK: - PUT /v1/devices/token

    /// Rotates *this* device's APNs token. The device is identified by the
    /// principal in the signature, so revision 1.1 removed `deviceId` from the
    /// body — a device can no longer even name another device here.
    public struct RotateDeviceTokenRequest: Codable, Equatable, Sendable {
        public let apnsToken: String
        public let apnsEnvironment: String

        public init(apnsToken: String, apnsEnvironment: APNSEnvironment) {
            self.apnsToken = apnsToken
            self.apnsEnvironment = apnsEnvironment.rawValue
        }
    }

    // MARK: - POST /v1/pairings/{id}/turn-credentials

    /// Ephemeral coturn credentials (`backend.md` §4). The request body is
    /// empty; both roles may ask.
    public struct TurnCredentialsResponse: Codable, Equatable, Sendable {
        /// `<expiry-unix>:<pairingId>`.
        public let username: String
        /// base64 HMAC, used as the TURN password.
        public let credential: String
        /// Lifetime of these credentials (protocol: 3600).
        public let ttlSeconds: Int
        /// `turn:` / `turns:` URIs, in the order the server prefers them.
        public let uris: [String]

        public init(username: String, credential: String, ttlSeconds: Int, uris: [String]) {
            self.username = username
            self.credential = credential
            self.ttlSeconds = ttlSeconds
            self.uris = uris
        }
    }

    // MARK: - GET /v1/config

    /// Deployment configuration a build cannot carry, because it changes faster
    /// than releases ship (`backend.md` §4).
    ///
    /// Nothing here is a secret, and nothing here may become one. The server
    /// serves only values that are public by construction — a client id travels
    /// in the clear in every OAuth exchange — because whatever this decodes is
    /// on a phone, and a value on a phone is a published value.
    ///
    /// Absent sections mean this deployment has no such service, which is the
    /// client's cue to fall back to what it was built with rather than to a
    /// blank id.
    public struct AppConfigurationResponse: Codable, Equatable, Sendable {

        public struct Tidal: Codable, Equatable, Sendable {
            public let clientID: String

            public init(clientID: String) {
                self.clientID = clientID
            }

            enum CodingKeys: String, CodingKey {
                case clientID = "clientId"
            }
        }

        /// Spotify's client id, on exactly the same terms as TIDAL's: public by
        /// construction, and absent rather than blank when a deployment has
        /// registered no Spotify application.
        public struct Spotify: Codable, Equatable, Sendable {
            public let clientID: String

            public init(clientID: String) {
                self.clientID = clientID
            }

            enum CodingKeys: String, CodingKey {
                case clientID = "clientId"
            }
        }

        /// How long this may be cached before asking again.
        public let ttlSeconds: Int
        public let tidal: Tidal?
        public let spotify: Spotify?

        public init(ttlSeconds: Int, tidal: Tidal? = nil, spotify: Spotify? = nil) {
            self.ttlSeconds = ttlSeconds
            self.tidal = tidal
            self.spotify = spotify
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.ttlSeconds = try container.decode(Int.self, forKey: .ttlSeconds)
            // Each service decoded independently and forgivingly. A malformed
            // Spotify section must not cost a Camera the TIDAL id it has been
            // playing from for months — and a deployment older than this field
            // simply has none, which is the same as having no Spotify.
            self.tidal = try? container.decodeIfPresent(Tidal.self, forKey: .tidal)
            self.spotify = try? container.decodeIfPresent(Spotify.self, forKey: .spotify)
        }
    }

    // MARK: - POST /v1/events

    /// A sealed detection event. The server fans the ciphertext out to the
    /// viewers' APNs tokens and never learns what happened, or when.
    public struct PostEventRequest: Codable, Equatable, Sendable {
        /// A `SealedEnvelope` under `K_evt`, base64.
        public let ciphertext: String

        public init(ciphertext: String) {
            self.ciphertext = ciphertext
        }
    }

    // MARK: - Shared

    public enum APNSEnvironment: String, Codable, Sendable {
        case sandbox
        case production
    }

    /// `{error, message}` on every 4xx/5xx (`shared/protocol.md`, "Errors").
    /// Both fields are optional here so a proxy's HTML error page cannot take
    /// the client down.
    public struct ErrorResponse: Codable, Equatable, Sendable {
        /// Stable machine-readable code, e.g. `rate_limited`.
        public let error: String?
        /// Human-readable text, safe to show to the user.
        public let message: String?

        public init(error: String?, message: String?) {
            self.error = error
            self.message = message
        }
    }
}

/// Failures the API client surfaces. None of these carry key material.
public enum APIError: Error, Equatable, Sendable {
    /// Transport returned something that was not an HTTP response.
    case invalidResponse
    /// Non-2xx status. `code` is the backend's stable error code and `message`
    /// its human-readable text, when the body parsed.
    case http(statusCode: Int, code: String?, message: String?)
    /// The response body did not decode.
    case decodingFailed
    /// The pairing already has `PairingTiming.maxViewersPerCamera` viewers.
    case viewerLimitReached
    /// The pairing expired or was revoked (`404`/`410`).
    case pairingNotFound
    /// Could not build a valid URL from the stored API base URL and a path.
    case invalidBaseURL
    /// A bootstrap-only endpoint was called with device credentials, or the
    /// reverse. A programming error, not a server response — the two principals
    /// are not interchangeable (`shared/protocol.md`, "Why per-device keys").
    case wrongCredentials

    /// Text safe to put in front of a user; never includes anything sensitive.
    public var userFacingMessage: String? {
        switch self {
        case .viewerLimitReached:
            return "This camera already has the maximum number of viewers."
        case .pairingNotFound:
            return "This pairing code is no longer valid. Ask for a fresh code."
        case .http(_, _, let message):
            return message
        case .invalidResponse, .decodingFailed, .invalidBaseURL, .wrongCredentials:
            return nil
        }
    }
}
