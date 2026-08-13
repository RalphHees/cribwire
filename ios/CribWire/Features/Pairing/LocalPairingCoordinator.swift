import CryptoKit
import Foundation
import CribWireKit

/// Pairing with no backend at all (`docs/TASKS.md` Phase 5).
///
/// The server path exists to do two things that are awkward without it: issue
/// device identities, and tell the Camera that a Viewer claimed the pairing.
/// Offline, both are replaced rather than emulated —
///
/// - **identities**: each device mints its own UUID. Nothing checks them against
///   a registry, and nothing needs to: an id here is an address, not a
///   credential. The credential is the sealed envelope.
/// - **the claim**: a Viewer connecting *is* the claim. `LocalPeerAdvertiser`
///   hands the Camera an accepted socket, and the first sealed `hello` on it
///   carries the Viewer's id.
///
/// The security story is unchanged and, if anything, tighter. There is no
/// `CribWire-HMAC` because there is no server to authenticate to; every message
/// is sealed under `K_sig`, derived from the QR secret, so a device on the same
/// Wi-Fi that never scanned the code cannot produce a single readable message.
/// Bonjour finds an address and confers no trust whatsoever.
@MainActor
enum LocalPairingCoordinator {

    /// Wraps an already-connected socket so `SignalingClient` can be built on it.
    ///
    /// `SignalingClient` dials outward through a factory, but the Camera's socket
    /// arrives *inbound* from the listener. This adapter hands that one socket
    /// over and ignores the URL, which lets both directions share the same
    /// sealed-signalling stack instead of growing a second one.
    struct AcceptedSocketFactory: SignalingSocketFactory {
        let socket: any SignalingSocket

        func connect(to url: URL, headers: [String: String]) throws -> any SignalingSocket {
            socket
        }
    }

    /// The base URL `SignalingClient` is configured with offline.
    ///
    /// Never dialled — `AcceptedSocketFactory` and the local socket factory both
    /// ignore it — but the type requires one. A `.invalid` scheme makes it obvious
    /// in a debugger that nothing is meant to resolve this.
    static let placeholderURL = URL(string: "cribwire-local://peer")!

    /// Builds a sealed signalling client over an already-connected local socket.
    static func makeClient(
        socket: any SignalingSocket,
        pairingID: UUID,
        role: PairingRole,
        deviceID: String,
        keys: PairingKeys,
        deviceKey: DeviceKey
    ) -> SignalingClient {
        SignalingClient(
            configuration: .init(
                baseURL: placeholderURL,
                pairingID: pairingID,
                role: role,
                deviceID: deviceID
            ),
            signalingKey: keys.signaling,
            deviceKey: deviceKey,
            factory: AcceptedSocketFactory(socket: socket)
        )
    }

    /// Waits for the peer's `hello` and returns the device id inside it.
    ///
    /// `from` is read from the *opened* payload, never from the envelope: the
    /// outer routing fields are the part an attacker on the path could rewrite,
    /// and the sealed copy is the part they cannot.
    ///
    /// - Returns: the peer's device id, or `nil` if the link died first.
    static func awaitHello(on client: SignalingClient, timeout: TimeInterval = 20) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        for await event in await client.events {
            if Date() >= deadline { return nil }
            switch event {
            case .received(let payload) where payload.t == .hello:
                return payload.from
            case .disconnected:
                return nil
            default:
                continue
            }
        }
        return nil
    }
}

/// Camera half: advertise, accept one Viewer, learn its id.
@MainActor
final class LocalPairingHost {

    /// A Viewer that connected and introduced itself.
    struct Claim {
        let viewerDeviceID: String
        let client: SignalingClient
    }

    private let pairingID: UUID
    private let keys: PairingKeys
    private let deviceID: String
    private let deviceKey: DeviceKey
    private let onClaim: (Claim) -> Void

    private var advertiser: LocalPeerAdvertiser?

    init(
        pairingID: UUID,
        keys: PairingKeys,
        deviceID: String,
        deviceKey: DeviceKey,
        onClaim: @escaping (Claim) -> Void
    ) {
        self.pairingID = pairingID
        self.keys = keys
        self.deviceID = deviceID
        self.deviceKey = deviceKey
        self.onClaim = onClaim
    }

    func start() {
        guard advertiser == nil else { return }
        let advertiser = LocalPeerAdvertiser(pairingID: pairingID) { [weak self] socket in
            self?.accept(socket)
        }
        advertiser.start()
        self.advertiser = advertiser
    }

    func stop() {
        advertiser?.stop()
        advertiser = nil
    }

    private func accept(_ socket: LocalPeerSocket) {
        let client = LocalPairingCoordinator.makeClient(
            socket: socket,
            pairingID: pairingID,
            role: .camera,
            deviceID: deviceID,
            keys: keys,
            deviceKey: deviceKey
        )

        Task { [weak self] in
            guard let self else { return }
            try? await client.connect()
            guard let viewerDeviceID = await LocalPairingCoordinator.awaitHello(on: client) else {
                await client.disconnect()
                return
            }
            // Introduce ourselves back, so the Viewer can address this Camera.
            _ = try? await client.send(.hello(), to: .viewer(deviceID: viewerDeviceID))
            self.onClaim(Claim(viewerDeviceID: viewerDeviceID, client: client))
        }
    }
}

/// Viewer half: find the Camera named by the scanned code, connect, introduce.
@MainActor
final class LocalPairingGuest {

    enum GuestError: Error {
        case notFound
        case handshakeFailed
    }

    private var browser: LocalPeerBrowser?

    /// Finds the Camera advertising `pairingID` and completes the handshake.
    ///
    /// - Returns: the Camera's device id and the live signalling client.
    func claim(
        pairingID: UUID,
        keys: PairingKeys,
        deviceID: String,
        deviceKey: DeviceKey,
        timeout: TimeInterval = 20
    ) async throws -> (cameraDeviceID: String, client: SignalingClient) {
        let discovered = try await discover(pairingID: pairingID, timeout: timeout)
        let socket = LocalPeerBrowser.connect(to: discovered)

        let client = LocalPairingCoordinator.makeClient(
            socket: socket,
            pairingID: pairingID,
            role: .viewer,
            deviceID: deviceID,
            keys: keys,
            deviceKey: deviceKey
        )
        try await client.connect()

        // The Viewer speaks first: on this path, connecting and introducing
        // itself is what the REST claim used to be.
        _ = try? await client.send(.hello(), to: .camera)

        guard let cameraDeviceID = await LocalPairingCoordinator.awaitHello(on: client) else {
            await client.disconnect()
            throw GuestError.handshakeFailed
        }
        return (cameraDeviceID, client)
    }

    /// Browses until a Camera advertises the pairing id from the scanned code.
    ///
    /// Matching on the pairing id matters: a household can have several Cameras
    /// advertising at once, and the user scanned exactly one of them.
    private func discover(
        pairingID: UUID,
        timeout: TimeInterval
    ) async throws -> LocalPeerBrowser.Discovered {
        try await withCheckedThrowingContinuation { continuation in
            var settled = false

            let browser = LocalPeerBrowser { results in
                guard !settled, let match = results.first(where: { $0.id == pairingID }) else {
                    return
                }
                settled = true
                continuation.resume(returning: match)
            }
            self.browser = browser
            browser.start()

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !settled else { return }
                settled = true
                self?.stop()
                continuation.resume(throwing: GuestError.notFound)
            }
        }
    }

    func stop() {
        browser?.stop()
        browser = nil
    }
}
