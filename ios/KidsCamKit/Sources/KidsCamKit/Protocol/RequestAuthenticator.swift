import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Builds the `KidsCam-HMAC` Authorization header (`shared/protocol.md`).
///
/// ```
/// canonical = METHOD + "\n" + PATH + "\n" + TIMESTAMP + "\n" + lowercase-hex(SHA-256(body))
/// mac       = lowercase-hex(HMAC-SHA256(K_auth, canonical))
/// header    = Authorization: KidsCam-HMAC <pairingId>:<role>:<timestamp>:<mac>
/// ```
///
/// The MAC proves membership of the pairing; it decrypts nothing, which is why
/// `K_auth` is the only key the backend ever holds.
public struct RequestAuthenticator: @unchecked Sendable {
    /// Header field name and scheme token.
    public static let headerField = "Authorization"
    public static let scheme = "KidsCam-HMAC"

    public let pairingID: UUID
    public let role: PairingRole
    private let authKey: SymmetricKey

    public init(pairingID: UUID, role: PairingRole, authKey: SymmetricKey) {
        self.pairingID = pairingID
        self.role = role
        self.authKey = authKey
    }

    public init(pairingID: UUID, role: PairingRole, keys: PairingKeys) {
        self.init(pairingID: pairingID, role: role, authKey: keys.auth)
    }

    // MARK: - Canonicalisation

    /// The exact string that gets MAC'd.
    ///
    /// - Parameters:
    ///   - method: uppercased by this function.
    ///   - path: path only, no scheme/host/query. Authenticated v1 endpoints do
    ///     not use query strings; a WebSocket upgrade signs the WS path without
    ///     its query.
    ///   - timestamp: Unix seconds as a decimal string.
    ///   - body: request body; an absent or empty body hashes the empty string,
    ///     which `SHA256.hash(data:)` already does.
    public static func canonicalString(
        method: String,
        path: String,
        timestamp: String,
        body: Data
    ) -> String {
        let bodyHash = Data(SHA256.hash(data: body)).kc_hexEncodedString
        return "\(method.uppercased())\n\(path)\n\(timestamp)\n\(bodyHash)"
    }

    // MARK: - Header

    /// Computes the lowercase-hex MAC for a request.
    public func mac(method: String, path: String, timestamp: String, body: Data) -> String {
        let canonical = Self.canonicalString(
            method: method,
            path: path,
            timestamp: timestamp,
            body: body
        )
        let code = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: authKey)
        return Data(code).kc_hexEncodedString
    }

    /// The full `Authorization` header value.
    public func authorizationHeaderValue(
        method: String,
        path: String,
        timestamp: String,
        body: Data
    ) -> String {
        let mac = mac(method: method, path: path, timestamp: timestamp, body: body)
        return "\(Self.scheme) \(pairingID.kc_lowercasedString):\(role.rawValue):\(timestamp):\(mac)"
    }

    /// Convenience taking a `Date`; the backend rejects anything more than 60 s
    /// from its own clock, so the caller should pass the actual send time.
    public func authorizationHeaderValue(
        method: String,
        path: String,
        body: Data,
        date: Date
    ) -> String {
        authorizationHeaderValue(
            method: method,
            path: path,
            timestamp: Self.timestamp(for: date),
            body: body
        )
    }

    /// Unix time in whole seconds, as a decimal string.
    public static func timestamp(for date: Date) -> String {
        String(Int64(date.timeIntervalSince1970.rounded(.down)))
    }
}
