import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One WebSocket connection, reduced to what signaling needs.
///
/// The protocol exists so the whole sealed-signaling layer — sequence checks,
/// AAD binding, replay rejection — can be tested against a scripted socket with
/// no network at all, and so certificate pinning (`security.md` §7, Phase 4) has
/// exactly one place to land.
public protocol SignalingSocket: Sendable {
    /// Sends one text frame.
    func send(text: String) async throws
    /// Waits for the next frame. Throws when the connection ends.
    func receive() async throws -> String
    /// Closes the connection. Safe to call twice.
    func cancel()
}

/// Opens sockets. Injected into `SignalingClient`.
public protocol SignalingSocketFactory: Sendable {
    func connect(to url: URL, headers: [String: String]) throws -> any SignalingSocket
}

#if canImport(Darwin)
/// `URLSessionWebSocketTask`-backed socket for the app.
///
/// `@unchecked Sendable`: `URLSessionWebSocketTask` is thread-safe by contract
/// but is not declared `Sendable` in every SDK version we build against.
public final class URLSessionSignalingSocket: SignalingSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func send(text: String) async throws {
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        let message = try await task.receive()
        switch message {
        case .string(let text):
            return text
        case .data(let data):
            // The protocol is JSON text; a binary frame carrying valid UTF-8 is
            // accepted rather than dropped, and anything else is a protocol
            // error the caller treats as a disconnect.
            guard let text = String(data: data, encoding: .utf8) else {
                throw URLError(.cannotParseResponse)
            }
            return text
        @unknown default:
            throw URLError(.cannotParseResponse)
        }
    }

    public func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// Builds `URLSessionWebSocketTask`s, carrying the `KidsCam-HMAC` header on the
/// upgrade request.
public struct URLSessionSignalingSocketFactory: SignalingSocketFactory, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(to url: URL, headers: [String: String]) throws -> any SignalingSocket {
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionSignalingSocket(task: task)
    }
}
#endif
