import CryptoKit
import Foundation
import CribWireKit

/// Holds one pairing's signaling socket open for the length of the pairing flow
/// and reports the peers the server announces on it.
///
/// This is the channel `security.md` §3.3 step 2 calls for. Nothing is ever sent
/// over it: pairing needs the socket for exactly one fact — the Camera learns a
/// Viewer claimed the pairing when that Viewer connects and the server announces
/// it — and both sides derive the SAS locally from the root secret, so no key
/// material and no six digits ever cross the wire.
///
/// Because it only listens, the connection is idle by definition, and the server
/// closes idle connections after five minutes (`backend.md` §3) while a pairing
/// candidate stays claimable for ten. The reconnect ladder below is therefore
/// load-bearing, not defensive: without it the Camera would go deaf halfway
/// through a candidate's life. A reconnecting socket is told who is already
/// online, so a claim that lands during the gap is not lost.
@MainActor
final class PairingSignalingLink {

    /// Everything one socket needs. Assembled at bootstrap, never persisted here.
    struct Identity {
        let pairingID: UUID
        let apiBaseURL: URL
        let role: PairingRole
        /// This device's backend-assigned id — the signing principal.
        let deviceID: String
        let deviceKey: DeviceKey
        /// `K_sig`. Held so the client can open anything addressed to us; during
        /// pairing nothing is expected, but a socket that cannot decrypt is a
        /// socket that silently drops the first real signaling message.
        let signalingKey: SymmetricKey
    }

    private let identity: Identity
    private let factory: any SignalingSocketFactory
    private let onPeerOnline: (SignalingPresence) -> Void
    private let policy = ReconnectPolicy()

    private var task: Task<Void, Never>?

    init(
        identity: Identity,
        factory: any SignalingSocketFactory,
        onPeerOnline: @escaping (SignalingPresence) -> Void = { _ in }
    ) {
        self.identity = identity
        self.factory = factory
        self.onPeerOnline = onPeerOnline
    }

    /// Connects, and keeps reconnecting until ``stop()``. Calling twice is a
    /// no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Connection loop

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            let established = await runOneConnection()
            guard !Task.isCancelled else { return }

            // A socket that lived and then dropped starts the ladder over: it was
            // almost certainly the five-minute idle close, not a failing server.
            attempt = established ? 1 : attempt + 1
            let delay = policy.delay(
                forAttempt: attempt,
                randomUnit: Double.random(in: 0...1)
            )
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// Runs a single connection to completion.
    ///
    /// - Returns: whether the socket was established before it ended, which is
    ///   what tells the caller's backoff whether this was a drop or a failure.
    private func runOneConnection() async -> Bool {
        let client = SignalingClient(
            configuration: .init(
                baseURL: identity.apiBaseURL,
                pairingID: identity.pairingID,
                role: identity.role,
                deviceID: identity.deviceID
            ),
            signalingKey: identity.signalingKey,
            deviceKey: identity.deviceKey,
            factory: factory
        )

        do {
            try await client.connect()
        } catch {
            // Nothing to surface: a pairing screen that cannot reach the socket
            // still shows a working QR, and the next attempt may succeed.
            return false
        }

        for await event in await client.events {
            switch event {
            case .peerOnline(let presence):
                onPeerOnline(presence)
            case .disconnected:
                await client.disconnect()
                return true
            case .connected, .peerOffline, .received, .rejected:
                break
            }
        }

        await client.disconnect()
        return true
    }
}
