import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A single outbound HTTP request, in a form that is trivially `Sendable` and
/// trivially assertable in tests.
///
/// `APIClient` builds these; the transport turns them into whatever the platform
/// uses. Keeping `URLRequest` out of the client means the client's own tests need
/// no networking stack at all.
public struct HTTPRequest: Equatable, Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    public var method: Method
    /// Absolute URL the request goes to.
    public var url: URL
    /// The path component that was signed. Kept alongside the URL so tests can
    /// assert the signed path matches what the backend will canonicalise.
    public var signedPath: String
    public var headers: [String: String]
    public var body: Data

    public init(
        method: Method,
        url: URL,
        signedPath: String,
        headers: [String: String],
        body: Data
    ) {
        self.method = method
        self.url = url
        self.signedPath = signedPath
        self.headers = headers
        self.body = body
    }
}

/// A response, reduced to what the client actually needs.
public struct HTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// The seam tests inject through.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

#if canImport(Darwin)
/// `URLSession`-backed transport for the app.
///
/// Certificate pinning was built here and then removed on purpose — it coupled
/// every installed app to the backend's CA (`security.md` §7). The transport
/// boundary stays, so reinstating it would touch nothing else.
/// `@unchecked Sendable`: `URLSession` is thread-safe by contract but is not
/// declared `Sendable` in every SDK version we build against.
public struct URLSessionTransport: @unchecked Sendable, HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        if !request.body.isEmpty {
            urlRequest.httpBody = request.body
        }
        // No caching: every authenticated request carries a fresh timestamp and
        // MAC, and responses are never worth reusing.
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return HTTPResponse(statusCode: httpResponse.statusCode, body: data)
    }
}
#endif
