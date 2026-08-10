import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Builds the `KidsCam-HMAC` Authorization header (`shared/protocol.md`
/// revision 1.1).
///
/// ```
/// canonical = METHOD + "\n" + PATH + "\n" + TIMESTAMP + "\n" + PRINCIPAL + "\n"
///           + lowercase-hex(SHA-256(body))
/// mac       = lowercase-hex(HMAC-SHA256(key, canonical))
/// header    = Authorization: KidsCam-HMAC <pairingId>:<principal>:<timestamp>:<mac>
/// ```
///
/// Two kinds of authenticator exist and they are not interchangeable:
///
/// - ``bootstrap(pairingID:authKey:)`` signs with `K_auth` and may only be used
///   for `POST /v1/pairings` and `POST /v1/pairings/{id}/claim`. `K_auth` proves
///   pairing membership, nothing more.
/// - ``device(pairingID:deviceID:deviceKey:)`` signs with the key this device
///   generated at bootstrap and registered in that body. Everything else — REST
///   and the WebSocket upgrade — uses it.
///
/// Neither key decrypts anything; the backend holds both and still sees only
/// ciphertext.
public struct RequestAuthenticator: @unchecked Sendable {
    /// Header field name and scheme token.
    public static let headerField = "Authorization"
    public static let scheme = "KidsCam-HMAC"

    public let pairingID: UUID
    public let principal: RequestPrincipal
    private let signingKey: SymmetricKey

    public init(pairingID: UUID, principal: RequestPrincipal, signingKey: SymmetricKey) {
        self.pairingID = pairingID
        self.principal = principal
        self.signingKey = signingKey
    }

    // MARK: - Factories

    /// Signs the two bootstrap calls with `K_auth`.
    public static func bootstrap(pairingID: UUID, authKey: SymmetricKey) -> RequestAuthenticator {
        RequestAuthenticator(pairingID: pairingID, principal: .bootstrap, signingKey: authKey)
    }

    /// Signs the two bootstrap calls with the `K_auth` of a derived key set.
    public static func bootstrap(pairingID: UUID, keys: PairingKeys) -> RequestAuthenticator {
        bootstrap(pairingID: pairingID, authKey: keys.auth)
    }

    /// Signs every post-bootstrap request as this device.
    public static func device(
        pairingID: UUID,
        deviceID: String,
        deviceKey: DeviceKey
    ) -> RequestAuthenticator {
        RequestAuthenticator(
            pairingID: pairingID,
            principal: .device(deviceID),
            signingKey: deviceKey.key
        )
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
    ///   - principal: `bootstrap`, or this device's id.
    ///   - body: request body; an absent or empty body hashes the empty string,
    ///     which `SHA256.hash(data:)` already does.
    public static func canonicalString(
        method: String,
        path: String,
        timestamp: String,
        principal: RequestPrincipal,
        body: Data
    ) -> String {
        let bodyHash = Data(SHA256.hash(data: body)).kc_hexEncodedString
        return "\(method.uppercased())\n\(path)\n\(timestamp)\n\(principal.stringValue)\n\(bodyHash)"
    }

    // MARK: - Header

    /// Computes the lowercase-hex MAC for a request.
    public func mac(method: String, path: String, timestamp: String, body: Data) -> String {
        let canonical = Self.canonicalString(
            method: method,
            path: path,
            timestamp: timestamp,
            principal: principal,
            body: body
        )
        let code = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: signingKey)
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
        return "\(Self.scheme) \(pairingID.kc_lowercasedString)"
            + ":\(principal.stringValue):\(timestamp):\(mac)"
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
