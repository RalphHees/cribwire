import Foundation
import CribWireKit
import Network

/// Local-network-only signalling: Bonjour discovery plus a direct connection
/// between the two devices, with no backend involved at all
/// (`docs/TASKS.md` Phase 5).
///
/// This is the strongest form of the product's privacy claim. On one Wi-Fi, with
/// the internet unplugged, the Camera advertises, the Viewer finds it, and the
/// same sealed envelopes flow over a direct TCP connection instead of the
/// server's WebSocket.
///
/// **What makes this safe is that nothing above it changes.** `SignalingSocket`
/// is the seam: `SignalingClient` still seals every message under `K_sig`, still
/// checks sequence numbers, still binds the sender's role into the AAD. A
/// discovered peer on the LAN is exactly as untrusted as the server is — it has
/// to produce a blob that opens under a key only the QR scan could have shared.
/// Bonjour is a way to find an address, never a reason to believe anyone.
///
/// The one thing that genuinely differs: there is no `CribWire-HMAC` header,
/// because there is no server to authenticate to. Per-message authentication
/// comes entirely from the seal, which is strictly stronger than the transport
/// auth it replaces.
enum LocalPeerTransport {

    /// Bonjour service type. The `_cribwire` name is not registered with IANA;
    /// it is scoped to the local link and collides with nothing else in practice.
    static let serviceType = "_cribwire._tcp"

    /// Advertised alongside the service so a Viewer can tell one Camera from
    /// another before connecting — the pairing id is public (it is in the QR),
    /// and knowing it grants nothing without the root secret.
    static let pairingIDKey = "pid"
}

// MARK: - Camera side

/// Advertises this Camera on the local network and accepts one Viewer at a time.
@MainActor
final class LocalPeerAdvertiser {

    private let pairingID: UUID
    private let onSocket: (LocalPeerSocket) -> Void
    private var listener: NWListener?

    init(pairingID: UUID, onSocket: @escaping (LocalPeerSocket) -> Void) {
        self.pairingID = pairingID
        self.onSocket = onSocket
    }

    func start() {
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        // Peer-to-peer so it works on a network with no DHCP/router services —
        // an "offline" mode that needed a working router would miss the point.
        parameters.includePeerToPeer = true

        guard let listener = try? NWListener(using: parameters) else { return }
        listener.service = NWListener.Service(
            type: LocalPeerTransport.serviceType,
            txtRecord: NWTXTRecord([
                LocalPeerTransport.pairingIDKey: pairingID.uuidString.lowercased()
            ])
        )

        listener.newConnectionHandler = { [weak self] connection in
            let socket = LocalPeerSocket(connection: connection)
            socket.start()
            Task { @MainActor in
                self?.onSocket(socket)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

// MARK: - Viewer side

/// Finds Cameras advertising on the local network.
@MainActor
final class LocalPeerBrowser {

    /// One discovered Camera.
    struct Discovered: Identifiable, Equatable {
        let id: UUID
        let endpoint: NWEndpoint
        let name: String

        static func == (lhs: Discovered, rhs: Discovered) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name
        }
    }

    private let onResults: ([Discovered]) -> Void
    private var browser: NWBrowser?

    init(onResults: @escaping ([Discovered]) -> Void) {
        self.onResults = onResults
    }

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: LocalPeerTransport.serviceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let discovered = results.compactMap(Self.discovered(from:))
            Task { @MainActor in
                self?.onResults(discovered)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Reads the pairing id out of a result's TXT record.
    ///
    /// A result without a well-formed pairing id is dropped rather than shown:
    /// it is either not CribWire or is advertising something this build cannot
    /// interpret, and in both cases there is nothing useful to offer the user.
    nonisolated static func discovered(from result: NWBrowser.Result) -> Discovered? {
        guard case .bonjour(let txt) = result.metadata,
              let raw = txt[LocalPeerTransport.pairingIDKey],
              let pairingID = UUID(uuidString: raw)
        else {
            return nil
        }
        let name: String
        if case .service(let serviceName, _, _, _) = result.endpoint {
            name = serviceName
        } else {
            name = String(localized: "Camera")
        }
        return Discovered(id: pairingID, endpoint: result.endpoint, name: name)
    }

    /// Opens a connection to a discovered Camera.
    static func connect(to discovered: Discovered) -> LocalPeerSocket {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let socket = LocalPeerSocket(
            connection: NWConnection(to: discovered.endpoint, using: parameters)
        )
        socket.start()
        return socket
    }
}

// MARK: - Socket

/// A `SignalingSocket` over a direct `NWConnection`.
///
/// Implementing the same protocol the WebSocket does is what lets the entire
/// sealed-signalling stack — and therefore `StreamingEngine` — run unchanged over
/// a local link.
///
/// `@unchecked Sendable`: the mutable state below is confined to `queue`, which
/// is also the connection's own queue, so every access is already serialised.
final class LocalPeerSocket: SignalingSocket, @unchecked Sendable {

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.ralphhees.cribwire.localpeer")

    private var decoder = LocalFraming.Decoder()
    /// Messages decoded before anyone asked for one.
    private var inbox: [String] = []
    /// A `receive()` waiting for the next message.
    private var waiter: CheckedContinuation<String, Error>?
    private var failure: Error?
    private var isCancelled = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.finish(with: error)
            case .cancelled:
                self?.finish(with: SocketError.cancelled)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNext()
    }

    // MARK: - SignalingSocket

    func send(text: String) async throws {
        guard let framed = LocalFraming.encode(text) else {
            throw SocketError.messageTooLarge
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: framed,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if !inbox.isEmpty {
                    continuation.resume(returning: inbox.removeFirst())
                    return
                }
                if let failure {
                    continuation.resume(throwing: failure)
                    return
                }
                // One consumer only — the client's read loop — so an existing
                // waiter would be a programming error rather than contention.
                waiter = continuation
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            guard !isCancelled else { return }
            isCancelled = true
            connection.cancel()
        }
    }

    enum SocketError: Error {
        case messageTooLarge
        case cancelled
    }

    // MARK: - Reading

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                do {
                    for message in try self.decoder.append(data) {
                        self.deliver(message)
                    }
                } catch {
                    // The stream is no longer aligned to a frame boundary, so
                    // there is nothing to resynchronise to.
                    self.finish(with: error)
                    return
                }
            }
            if let error {
                self.finish(with: error)
                return
            }
            if isComplete {
                self.finish(with: SocketError.cancelled)
                return
            }
            self.receiveNext()
        }
    }

    /// Called on `queue`.
    private func deliver(_ message: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            inbox.append(message)
        }
    }

    private func finish(with error: Error) {
        queue.async { [self] in
            guard failure == nil else { return }
            failure = error
            if let waiter {
                self.waiter = nil
                waiter.resume(throwing: error)
            }
        }
    }
}
