import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The sealed signaling channel (`security.md` §4, `backend.md` §WebSocket).
///
/// Everything this client puts on the socket is sealed with `K_sig` before it
/// leaves, and everything it takes off the socket is opened before anyone else
/// sees it — the server only ever handles `{to, seq, blob}` where `blob` is
/// ciphertext bound to the pairing and the sender's role.
///
/// On top of the seal it enforces the ordering rules:
///
/// - outbound sequence numbers are monotonic from 1;
/// - inbound ones are checked per authenticated sender, so replays and rewinds
///   are dropped;
/// - the sealed copy of the sequence number must match the envelope's, which
///   catches a server that rewrites the outer value it can see.
///
/// An actor: it owns the socket, both sequence counters and the signaling key,
/// and is driven from the main actor by the streaming engine.
public actor SignalingClient {

    // MARK: - Types

    public static let defaultPath = "/v1/signal"

    public struct Configuration: Sendable {
        public var baseURL: URL
        public var pairingID: UUID
        /// This device's role. Decides the AAD used to seal (own role) and to
        /// open (peer role), and which envelope addresses are ours.
        public var role: PairingRole
        /// This device's backend-assigned id — the signing principal, the
        /// address other devices send to, and the sealed `from` field.
        public var deviceID: String
        public var path: String

        public init(
            baseURL: URL,
            pairingID: UUID,
            role: PairingRole,
            deviceID: String,
            path: String = SignalingClient.defaultPath
        ) {
            self.baseURL = baseURL
            self.pairingID = pairingID
            self.role = role
            self.deviceID = deviceID
            self.path = path
        }
    }

    /// Why an inbound message was dropped. Surfaced so the UI/log can say "the
    /// server is misbehaving" without ever saying what the message contained.
    public enum RejectionReason: Equatable, Sendable {
        /// Addressed to some other device.
        case notForThisDevice
        /// Same sequence number twice.
        case replay
        /// Sequence number went backwards.
        case outOfOrder
        /// Sequence number was not a positive integer.
        case malformedSequence
        /// Wrong key, wrong pairing, wrong sender role, or tampered bytes —
        /// indistinguishable by design.
        case sealFailed
        /// Opened, but the plaintext was not a signaling payload.
        case malformedPayload
        /// The sealed sequence number disagreed with the envelope's: someone
        /// between the peers rewrote the part they could see.
        case sequenceMismatch
        /// Larger than the 16 KiB frame cap.
        case oversized
    }

    public enum DisconnectReason: Equatable, Sendable {
        case closedLocally
        case transportFailure
    }

    public enum Event: Equatable, Sendable {
        case connected
        /// A peer joined. For the Camera this is the trigger to offer — and the
        /// first moment it learns a Viewer claimed the pairing.
        case peerOnline(SignalingPresence)
        case peerOffline(SignalingPresence)
        /// A payload that opened, passed the ordering checks, and was addressed
        /// to this device.
        case received(SignalingPayload)
        case rejected(RejectionReason)
        case disconnected(DisconnectReason)
    }

    public enum SignalingError: Error, Equatable, Sendable {
        case notConnected
        case invalidURL
        case messageTooLarge
        case encodingFailed
    }

    // MARK: - State

    private let configuration: Configuration
    private let signalingKey: SymmetricKey
    private let authenticator: RequestAuthenticator
    private let factory: any SignalingSocketFactory
    private let now: @Sendable () -> Date

    private var socket: (any SignalingSocket)?
    private var receiveTask: Task<Void, Never>?
    private var outboundSeq = 0
    /// Keeps every upgrade this client signs on a distinct second. Without it a
    /// reconnect landing in the same second as the attempt before it is refused
    /// as a replay — see `RequestTimestampSequencer`.
    private var timestamps = RequestTimestampSequencer()
    private var inbound = SequenceLedger()

    private let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private let decoder = JSONDecoder()

    public init(
        configuration: Configuration,
        signalingKey: SymmetricKey,
        deviceKey: DeviceKey,
        factory: any SignalingSocketFactory,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.signalingKey = signalingKey
        self.authenticator = .device(
            pairingID: configuration.pairingID,
            deviceID: configuration.deviceID,
            deviceKey: deviceKey
        )
        self.factory = factory
        self.now = now

        var capturedContinuation: AsyncStream<Event>.Continuation!
        let stream = AsyncStream<Event> { capturedContinuation = $0 }
        self.stream = stream
        self.continuation = capturedContinuation
    }

    /// The event feed. One consumer — the streaming engine — drains it:
    /// `for await event in await client.events { … }`.
    public var events: AsyncStream<Event> { stream }

    // MARK: - Connection

    /// Opens the socket and starts reading.
    ///
    /// The upgrade carries the same `CribWire-HMAC` header as a REST call, signed
    /// with this device's own key over the path *without* its query string
    /// (`shared/protocol.md`).
    public func connect() throws {
        guard socket == nil else { return }

        guard var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: true
        ) else {
            throw SignalingError.invalidURL
        }
        switch components.scheme?.lowercased() {
        case "https", "wss":
            components.scheme = "wss"
        case "http", "ws":
            components.scheme = "ws"
        default:
            throw SignalingError.invalidURL
        }
        components.path = configuration.path
        components.queryItems = [
            URLQueryItem(name: "pairingId", value: configuration.pairingID.kc_lowercasedString)
        ]

        guard let url = components.url else { throw SignalingError.invalidURL }

        let header = authenticator.authorizationHeaderValue(
            method: "GET",
            path: configuration.path,
            body: Data(),
            date: timestamps.next(after: now())
        )

        let socket = try factory.connect(
            to: url,
            headers: [RequestAuthenticator.headerField: header]
        )
        self.socket = socket
        continuation.yield(.connected)

        receiveTask = Task { [weak self] in
            await self?.readLoop(socket: socket)
        }
    }

    /// Closes the socket. The event stream stays open so a reconnect can reuse
    /// the same client.
    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel()
        socket = nil
        continuation.yield(.disconnected(.closedLocally))
    }

    /// Clears both sequence watermarks. Called on reconnect, when the peer
    /// legitimately restarts its numbering.
    public func resetSequenceState() {
        outboundSeq = 0
        inbound.reset()
    }

    /// Forgets one sender's watermark — used when presence says that peer
    /// (re)attached, so its next session may start at 1 again.
    public func forgetSender(deviceID: String?) {
        inbound.forget(sender: deviceID)
    }

    /// Forgets every inbound watermark, without touching the outbound counter.
    ///
    /// For a peer that announces itself without a device id: a Camera address is
    /// just `camera`, because a pairing has exactly one. Only a Viewer hears
    /// that, and a Viewer has exactly one peer, so this is no broader than
    /// `forgetSender` — it simply has no name to pass.
    ///
    /// Deliberately *not* `resetSequenceState()`, which also rewinds
    /// `outboundSeq`. The server rejects a `seq` that does not increase strictly
    /// per connection, so rewinding the outbound counter on a live socket would
    /// get everything this client says next dropped as a regression.
    public func forgetAllSenders() {
        inbound.reset()
    }

    // MARK: - Sending

    /// Seals `payload` and sends it. Returns the sequence number used.
    @discardableResult
    public func send(
        _ payload: SignalingPayload,
        to recipient: SignalingRecipient
    ) async throws -> Int {
        guard let socket else { throw SignalingError.notConnected }

        outboundSeq += 1
        let seq = outboundSeq
        let stamped = payload.stamped(seq: seq, from: configuration.deviceID)

        guard let plaintext = try? encoder.encode(stamped) else {
            throw SignalingError.encodingFailed
        }

        let blob = try SealedEnvelope.seal(
            plaintext,
            using: signalingKey,
            associatedData: .signaling(
                pairingID: configuration.pairingID,
                senderRole: configuration.role
            )
        )

        let envelope = SignalingEnvelope(to: recipient, seq: seq, blob: blob)
        guard let frame = try? encoder.encode(envelope),
              let text = String(data: frame, encoding: .utf8)
        else {
            throw SignalingError.encodingFailed
        }
        guard text.utf8.count <= SignalingEnvelope.maxMessageBytes else {
            throw SignalingError.messageTooLarge
        }

        try await socket.send(text: text)
        return seq
    }

    // MARK: - Receiving

    private func readLoop(socket: any SignalingSocket) async {
        while !Task.isCancelled {
            do {
                let text = try await socket.receive()
                handle(text)
            } catch {
                guard !Task.isCancelled else { return }
                continuation.yield(.disconnected(.transportFailure))
                self.socket = nil
                return
            }
        }
    }

    /// Visible for tests: the whole inbound pipeline for one frame.
    func handle(_ text: String) {
        guard text.utf8.count <= SignalingEnvelope.maxMessageBytes else {
            continuation.yield(.rejected(.oversized))
            return
        }
        guard let message = SignalingInboundMessage.parse(text) else {
            continuation.yield(.rejected(.malformedPayload))
            return
        }

        switch message {
        case .peerOnline(let presence):
            continuation.yield(.peerOnline(presence))
        case .peerOffline(let presence):
            continuation.yield(.peerOffline(presence))
        case .unknown:
            // Heartbeats and anything the server grows later. Ignored on
            // purpose: an unknown frame must not kill a working stream.
            break
        case .envelope(let envelope):
            handle(envelope)
        }
    }

    private func handle(_ envelope: SignalingEnvelope) {
        guard isAddressedToThisDevice(envelope) else {
            continuation.yield(.rejected(.notForThisDevice))
            return
        }

        // Open first, then trust: the sequence checks below run on the sealed
        // copy of the values, never on the ones the server can edit.
        let plaintext: Data
        do {
            plaintext = try SealedEnvelope.open(
                envelope.blob,
                using: signalingKey,
                associatedData: .signaling(
                    pairingID: configuration.pairingID,
                    senderRole: configuration.role.peer
                )
            )
        } catch {
            continuation.yield(.rejected(.sealFailed))
            return
        }

        guard let payload = try? decoder.decode(SignalingPayload.self, from: plaintext) else {
            continuation.yield(.rejected(.malformedPayload))
            return
        }

        if let sealedSeq = payload.seq, sealedSeq != envelope.seq {
            continuation.yield(.rejected(.sequenceMismatch))
            return
        }

        switch inbound.admit(payload.seq ?? envelope.seq, from: payload.from) {
        case .accept:
            continuation.yield(.received(payload))
        case .replay:
            continuation.yield(.rejected(.replay))
        case .outOfOrder:
            continuation.yield(.rejected(.outOfOrder))
        case .malformed:
            continuation.yield(.rejected(.malformedSequence))
        }
    }

    private func isAddressedToThisDevice(_ envelope: SignalingEnvelope) -> Bool {
        switch envelope.recipient {
        case .camera:
            return configuration.role == .camera
        case .viewer(let deviceID):
            return configuration.role == .viewer && deviceID == configuration.deviceID
        case nil:
            return false
        }
    }
}
