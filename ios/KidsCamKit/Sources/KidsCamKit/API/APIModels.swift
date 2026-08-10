import Foundation

/// Request/response bodies for the Phase 1 REST endpoints.
///
/// ⚠️ **Not yet pinned.** `shared/protocol.md` fixes the auth scheme and the
/// envelope, and the shared vectors fix the *claim* body
/// (`{"apnsToken":…,"apnsEnvironment":…}`) because it appears in a signed
/// example. The remaining bodies below are the conservative reading of
/// `docs/specs/backend.md` §3 and **must be reconciled with the backend
/// implementation before Phase 1 integration** — ideally by adding them to
/// `shared/protocol.md` and the vector file. Everything is confined to this one
/// file so that reconciliation is a single edit.
public enum API {

    // MARK: - POST /v1/pairings

    /// Camera registers a pairing before showing the QR. `K_auth` is uploaded;
    /// `S` never is.
    public struct CreatePairingRequest: Codable, Equatable, Sendable {
        /// Lowercase UUID.
        public let pairingId: String
        /// `K_auth`, base64 (standard alphabet, padded).
        public let kAuth: String
        public let apnsToken: String
        /// `sandbox` | `production`.
        public let apnsEnvironment: String

        public init(pairingId: String, kAuth: String, apnsToken: String, apnsEnvironment: APNSEnvironment) {
            self.pairingId = pairingId
            self.kAuth = kAuth
            self.apnsToken = apnsToken
            self.apnsEnvironment = apnsEnvironment.rawValue
        }
    }

    public struct CreatePairingResponse: Codable, Equatable, Sendable {
        /// Seconds until an unclaimed pairing expires (spec: 600).
        public let expiresInSeconds: Int
        /// The camera's device ID as assigned by the backend.
        public let deviceId: String?

        public init(expiresInSeconds: Int, deviceId: String?) {
            self.expiresInSeconds = expiresInSeconds
            self.deviceId = deviceId
        }
    }

    // MARK: - POST /v1/pairings/{id}/claim

    /// Field names here are fixed by the signed example in
    /// `shared/test-vectors/kidscam-v1.json`.
    public struct ClaimPairingRequest: Codable, Equatable, Sendable {
        public let apnsToken: String
        public let apnsEnvironment: String

        public init(apnsToken: String, apnsEnvironment: APNSEnvironment) {
            self.apnsToken = apnsToken
            self.apnsEnvironment = apnsEnvironment.rawValue
        }
    }

    public struct ClaimPairingResponse: Codable, Equatable, Sendable {
        /// The viewer's device ID, needed later to revoke this viewer
        /// specifically (`DELETE /v1/pairings/{id}/viewers/{deviceId}`).
        public let deviceId: String

        public init(deviceId: String) {
            self.deviceId = deviceId
        }
    }

    // MARK: - PUT /v1/devices/token

    public struct RotateDeviceTokenRequest: Codable, Equatable, Sendable {
        public let pairingId: String
        public let deviceId: String
        public let apnsToken: String
        public let apnsEnvironment: String

        public init(pairingId: String, deviceId: String, apnsToken: String, apnsEnvironment: APNSEnvironment) {
            self.pairingId = pairingId
            self.deviceId = deviceId
            self.apnsToken = apnsToken
            self.apnsEnvironment = apnsEnvironment.rawValue
        }
    }

    // MARK: - Shared

    public enum APNSEnvironment: String, Codable, Sendable {
        case sandbox
        case production
    }

    /// Error body the backend returns on 4xx/5xx. Optional everywhere so a
    /// non-JSON error page cannot take the client down.
    public struct ErrorResponse: Codable, Equatable, Sendable {
        public let error: String?
        public let message: String?
    }
}

/// Failures the API client surfaces. None of these carry key material.
public enum APIError: Error, Equatable, Sendable {
    /// Transport returned something that was not an HTTP response.
    case invalidResponse
    /// Non-2xx status. `message` comes from the backend's error body when it
    /// parsed, and is safe to show to the user.
    case http(statusCode: Int, message: String?)
    /// The response body did not decode.
    case decodingFailed
    /// The pairing already has `PairingTiming.maxViewersPerCamera` viewers.
    case viewerLimitReached
    /// The pairing expired or was revoked (`404`/`410`).
    case pairingNotFound
    /// Could not build a valid URL from the stored API base URL and a path.
    case invalidBaseURL

    /// Text safe to put in front of a user; never includes anything sensitive.
    public var userFacingMessage: String? {
        switch self {
        case .viewerLimitReached:
            return "This camera already has the maximum number of viewers."
        case .pairingNotFound:
            return "This pairing code is no longer valid. Ask for a fresh code."
        case .http(_, let message):
            return message
        case .invalidResponse, .decodingFailed, .invalidBaseURL:
            return nil
        }
    }
}
