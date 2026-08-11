import Foundation

/// The contents of the pairing QR code — the out-of-band channel the whole trust
/// model rests on (`security.md` §2).
///
/// Normative form (`shared/protocol.md`):
///
/// ```
/// cribwire://pair?v=1&id=<pairingId>&s=<S>&api=<url>
/// ```
///
/// where `id` is the lowercase UUID, `s` is the root secret in base64url without
/// padding, and `api` is the percent-encoded base URL. Unknown query parameters
/// are ignored; a `v` other than `1` is rejected.
///
/// This value never goes to disk, the pasteboard, or a log line — it is built,
/// rendered into a QR image, and dropped.
public struct QRPayload: Sendable {
    /// Only version accepted or emitted by this build.
    public static let version = 1
    public static let scheme = "cribwire"
    public static let host = "pair"

    public let pairingID: UUID
    public let rootSecret: RootSecret
    public let apiBaseURL: URL

    public init(pairingID: UUID, rootSecret: RootSecret, apiBaseURL: URL) {
        self.pairingID = pairingID
        self.rootSecret = rootSecret
        self.apiBaseURL = apiBaseURL
    }

    // MARK: - Errors

    public enum ParseError: Error, Equatable, Sendable {
        /// Not a `cribwire://pair` URL at all — most likely an unrelated QR code.
        case notAPairingURL
        /// `v` was missing, non-numeric, or not `1`.
        case unsupportedVersion(String?)
        /// `id` was missing or not a UUID.
        case invalidPairingID
        /// `s` was missing, not base64url, or not 32 bytes.
        case invalidRootSecret
        /// `api` was missing, unparseable, or not an absolute https URL.
        case invalidAPIBaseURL
    }

    // MARK: - Encoding

    /// Builds the URL string rendered into the QR code.
    ///
    /// The query string is assembled by hand rather than via `URLComponents` so
    /// the parameter order and the percent-encoding are byte-stable and match the
    /// vector in `shared/test-vectors/cribwire-v1.json` exactly.
    public func urlString() -> String {
        let encodedAPI = Self.percentEncoded(apiBaseURL.absoluteString)
        return "\(Self.scheme)://\(Self.host)?v=\(Self.version)"
            + "&id=\(pairingID.kc_lowercasedString)"
            + "&s=\(rootSecret.base64URLEncoded)"
            + "&api=\(encodedAPI)"
    }

    /// Percent-encodes everything outside the RFC 3986 unreserved set
    /// (`ALPHA / DIGIT / "-" / "." / "_" / "~"`), which is what produces
    /// `https%3A%2F%2Fapi.cribwire.example` in the shared vector.
    static func percentEncoded(_ string: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    // MARK: - Parsing

    /// Parses a scanned QR string.
    ///
    /// Deliberately strict about everything the trust model depends on (version,
    /// secret length, URL scheme) and deliberately lenient about everything else
    /// (unknown parameters are ignored, so the format can grow).
    public static func parse(_ string: String) throws -> QRPayload {
        guard let components = URLComponents(string: string),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host
        else {
            throw ParseError.notAPairingURL
        }

        // `URLComponents.queryItems` percent-decodes values for us. Duplicated
        // parameters take their first occurrence; a later one cannot override an
        // earlier one and smuggle in a second secret.
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard parameters[item.name] == nil else { continue }
            parameters[item.name] = item.value ?? ""
        }

        let rawVersion = parameters["v"]
        guard let rawVersion, Int(rawVersion) == version else {
            throw ParseError.unsupportedVersion(rawVersion)
        }

        guard let rawID = parameters["id"], let pairingID = UUID(uuidString: rawID) else {
            throw ParseError.invalidPairingID
        }

        guard let rawSecret = parameters["s"],
              let secretBytes = Data.kc_fromBase64URL(rawSecret),
              let rootSecret = try? RootSecret(bytes: secretBytes)
        else {
            throw ParseError.invalidRootSecret
        }

        guard let rawAPI = parameters["api"],
              let apiURL = URL(string: rawAPI),
              apiURL.scheme?.lowercased() == "https",
              let apiHost = apiURL.host, !apiHost.isEmpty
        else {
            throw ParseError.invalidAPIBaseURL
        }

        return QRPayload(pairingID: pairingID, rootSecret: rootSecret, apiBaseURL: apiURL)
    }
}

extension QRPayload: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never renders the secret — this type is one `print` away from leaking the
    /// whole pairing.
    public var description: String {
        "QRPayload(pairingID: \(pairingID.kc_lowercasedString), api: \(apiBaseURL.absoluteString), s: <redacted>)"
    }

    public var debugDescription: String { description }
}
