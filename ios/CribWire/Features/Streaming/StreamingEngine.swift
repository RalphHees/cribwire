import Combine
import Foundation
import CribWireKit
import SwiftUI
import WebRTC

/// Drives one pairing's live stream, on either side.
///
/// This is the piece that makes everything else meet: `SignalingClient` carries
/// sealed offers, answers and ICE; `PeerSession` owns the peer connection and the
/// fingerprint check; `AdaptiveQualityController` picks the rung;
/// `ReconnectPolicy` and `NetworkPathMonitor` decide when to rebuild. None of
/// those know about each other, and all the sequencing lives here.
///
/// The security-relevant rule it enforces (`security.md` §4) is that a peer's
/// SDP is never applied until the fingerprint sealed under `K_sig` has been
/// checked, and the connection is never treated as usable until the certificate
/// DTLS actually negotiated matches that same value. A mismatch is terminal: it
/// means someone between the two devices is trying to become a DTLS endpoint,
/// and there is no retry that makes that acceptable.
///
/// The Camera is always the offerer (`ios-app.md` §3), which is why a Viewer that
/// connects first simply waits: presence tells the Camera to offer.
@MainActor
final class StreamingEngine: ObservableObject {

    // MARK: - Public state

    enum State: Equatable {
        case idle
        /// Signaling is up; waiting for the peer or for negotiation to finish.
        case connecting
        case connected
        /// Lost the peer or the socket, and working through the backoff ladder.
        case reconnecting
        /// Terminal. `isSecurityFailure` separates "the network gave up" from
        /// "someone is interfering", which must never be retried away.
        case failed(reason: String, isSecurityFailure: Bool)

        var isSecurityFailure: Bool {
            if case .failed(_, let security) = self { return security }
            return false
        }
    }

    /// How good the link looks, for the Viewer's indicator.
    enum LinkQuality: Equatable {
        case unknown
        case poor
        case fair
        case good
    }

    @Published private(set) var state: State = .idle
    /// True once the negotiated certificate has been checked against the sealed
    /// fingerprint. The Viewer refuses to show video until it is.
    @Published private(set) var isVerified = false
    @Published private(set) var quality: VideoQuality = .standard
    @Published private(set) var linkQuality: LinkQuality = .unknown
    /// The Viewer's inbound video track, once it arrives.
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    /// Number of viewers currently negotiated with. Camera-side.
    @Published private(set) var connectedPeerCount = 0
    /// What the engine is currently doing about a problem, for the status line.
    @Published private(set) var statusDetail: String?
    /// Viewer-side: audio muted locally. The Camera keeps sending, so unmuting
    /// is instant.
    @Published private(set) var isMuted = false

    // MARK: - Controls

    /// Viewer-side mute. Applies to every session so it survives a reconnect.
    func setMuted(_ muted: Bool) {
        isMuted = muted
        for session in sessions.values {
            session.setRemoteAudioEnabled(!muted)
        }
    }

    /// Camera-side: stop sending room audio without renegotiating.
    func setMicrophoneEnabled(_ enabled: Bool) {
        capture?.setMicrophoneEnabled(enabled)
    }

    func flipCamera() {
        Task { await capture?.flip() }
    }

    // MARK: - Dependencies

    private let record: PairingRecord
    private let services: AppServices
    private let role: PairingRole

    /// Camera-side only.
    let capture: CameraCaptureController?

    private var client: SignalingClient?
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var qualityTask: Task<Void, Never>?
    private var pathMonitor: NetworkPathMonitor?

    /// One session per peer. The Camera can hold several — a pairing accepts up
    /// to five Viewers — so this is keyed by address rather than being a single
    /// optional.
    private var sessions: [SignalingRecipient: PeerSession] = [:]
    private var qualityController = AdaptiveQualityController()

    private var identity: PairingSecretsStore.DeviceIdentity?
    private var keys: PairingKeys?
    private var turn: API.TurnCredentialsResponse?
    private var isStopping = false

    init(record: PairingRecord, services: AppServices) {
        self.record = record
        self.services = services
        self.role = record.localRole
        self.capture = record.localRole == .camera ? CameraCaptureController() : nil
    }

    // MARK: - Lifecycle

    func start() {
        guard case .idle = state else { return }
        isStopping = false
        state = .connecting
        WebRTCStack.configureAudioSession(mode: .active)

        pathMonitor = NetworkPathMonitor { [weak self] _ in
            // A different interface invalidates every gathered candidate. An ICE
            // restart is enough — it keeps the DTLS session, and therefore the
            // fingerprint this pairing already verified.
            self?.restartICE()
        }
        pathMonitor?.start()

        Task { await self.connect() }
    }

    func stop() {
        isStopping = true
        eventTask?.cancel(); eventTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        qualityTask?.cancel(); qualityTask = nil
        pathMonitor?.stop(); pathMonitor = nil

        // Captured before teardown: the peers are told before the socket goes,
        // so they stop immediately rather than waiting for ICE to time out.
        let peers = Array(sessions.keys)
        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()
        connectedPeerCount = 0
        remoteVideoTrack = nil
        isVerified = false

        let client = self.client
        self.client = nil
        Task {
            await client?.send(.bye(), toAll: peers)
            await client?.disconnect()
        }
        Task { await capture?.stop() }
        WebRTCStack.configureAudioSession(mode: .inactive)
        state = .idle
    }

    // MARK: - Connection

    private func connect() async {
        guard let identity = try? await services.secrets.loadDeviceIdentity(for: record.id),
              let keys = try? await services.secrets.loadKeys(for: record.id)
        else {
            fail("This pairing is missing its keys on this device. Pair again.")
            return
        }
        self.identity = identity
        self.keys = keys

        // TURN before signaling: a relay candidate that arrives after the offer
        // is already gathered is a candidate the peer never sees.
        self.turn = await fetchTURNCredentials()

        let client = SignalingClient(
            configuration: .init(
                baseURL: record.apiBaseURL,
                pairingID: record.id,
                role: role,
                deviceID: identity.deviceID
            ),
            signalingKey: keys.signaling,
            deviceKey: identity.deviceKey,
            factory: services.makeSignalingSocketFactory()
        )
        self.client = client

        do {
            try await client.connect()
        } catch {
            scheduleReconnect(reason: "Could not reach the signaling server.")
            return
        }

        eventTask = Task { [weak self] in
            guard let events = await self?.client?.events else { return }
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }

        if role == .camera {
            await capture?.start(quality: quality)
            startQualityLoop()
        }
    }

    private func fetchTURNCredentials() async -> API.TurnCredentialsResponse? {
        guard let client = (try? await services.makeAPIClient(for: record)) ?? nil else {
            return nil
        }
        // A pairing with no reachable TURN still works on a LAN, which is the
        // common case; refusing to start would be worse than a missing relay.
        return try? await client.turnCredentials()
    }

    // MARK: - Signaling events

    private func handle(_ event: SignalingClient.Event) async {
        switch event {
        case .connected:
            if case .reconnecting = state { state = .connecting }

        case .peerOnline(let presence):
            await handlePeerOnline(presence)

        case .peerOffline(let presence):
            handlePeerOffline(presence)

        case .received(let payload):
            await handle(payload)

        case .rejected:
            // Deliberately quiet. A rejected blob is either noise or an attack,
            // and in both cases the right response is to ignore it: surfacing it
            // would teach an attacker which of their guesses parsed.
            break

        case .disconnected(let reason):
            guard !isStopping, reason == .transportFailure else { return }
            scheduleReconnect(reason: "The signaling connection dropped.")
        }
    }

    private func handlePeerOnline(_ presence: SignalingPresence) async {
        guard let peer = address(of: presence) else { return }
        guard role == .camera else {
            // The Viewer waits to be offered to; announcing itself is all it has
            // to do.
            return
        }
        await offer(to: peer)
    }

    private func handlePeerOffline(_ presence: SignalingPresence) {
        guard let peer = address(of: presence) else { return }
        sessions.removeValue(forKey: peer)?.close()
        connectedPeerCount = sessions.count
        if role == .viewer {
            remoteVideoTrack = nil
            isVerified = false
            state = .reconnecting
        } else if sessions.isEmpty {
            state = .connecting
            Task { await self.updateCaptureForViewerCount() }
        }
    }

    /// Maps a presence event onto the address this device would send to.
    private func address(of presence: SignalingPresence) -> SignalingRecipient? {
        switch presence.role {
        case .viewer:
            guard let deviceID = presence.deviceID else { return nil }
            return .viewer(deviceID: deviceID)
        case .camera:
            return .camera
        case nil:
            return nil
        }
    }

    // MARK: - Negotiation

    /// Camera side: build a session for `peer` and send the offer.
    private func offer(to peer: SignalingRecipient, iceRestart: Bool = false) async {
        guard let client else { return }

        let session: PeerSession
        if iceRestart, let existing = sessions[peer] {
            session = existing
        } else {
            sessions[peer]?.close()
            guard let fresh = makeSession(for: peer) else {
                fail("Could not create a peer connection.")
                return
            }
            if let track = capture?.videoTrack {
                fresh.addTrack(track, streamID: WebRTCStack.streamID)
            }
            if let track = capture?.audioTrack {
                fresh.addTrack(track, streamID: WebRTCStack.streamID)
            }
            sessions[peer] = fresh
            session = fresh
        }

        do {
            let sdp = try await session.makeOffer(iceRestart: iceRestart)
            let fingerprint = try session.localFingerprint()
            try await client.send(
                .offer(sdp: sdp, fingerprint: fingerprint.sdpValue),
                to: peer
            )
        } catch {
            scheduleReconnect(reason: "Could not start the video connection.")
        }
    }

    private func handle(_ payload: SignalingPayload) async {
        guard let client, let sender = sender(of: payload) else { return }

        switch payload.t {
        case .offer:
            await handleOffer(payload, from: sender, client: client)

        case .answer:
            guard let session = sessions[sender], let sdp = payload.sdp else { return }
            await apply(
                sdp: sdp,
                type: .answer,
                fingerprint: payload.fp,
                to: session
            )

        case .ice:
            guard let session = sessions[sender], let candidate = payload.cand else { return }
            session.add(
                candidate: candidate,
                mid: payload.mid,
                mLineIndex: Int32(payload.mline ?? 0)
            )

        case .bye:
            sessions.removeValue(forKey: sender)?.close()
            connectedPeerCount = sessions.count
            if role == .viewer {
                remoteVideoTrack = nil
                isVerified = false
                state = .connecting
            }
        }
    }

    /// Viewer side: accept the Camera's offer and answer it.
    private func handleOffer(
        _ payload: SignalingPayload,
        from sender: SignalingRecipient,
        client: SignalingClient
    ) async {
        guard role == .viewer, let sdp = payload.sdp else { return }

        // A re-offer on an existing session is a renegotiation, not a new peer.
        let session: PeerSession
        if let existing = sessions[sender] {
            session = existing
        } else {
            guard let fresh = makeSession(for: sender) else {
                fail("Could not create a peer connection.")
                return
            }
            sessions[sender] = fresh
            session = fresh
        }

        await apply(sdp: sdp, type: .offer, fingerprint: payload.fp, to: session)
        guard !state.isSecurityFailure else { return }

        do {
            let answer = try await session.makeAnswer()
            let fingerprint = try session.localFingerprint()
            try await client.send(
                .answer(sdp: answer, fingerprint: fingerprint.sdpValue),
                to: sender
            )
        } catch {
            scheduleReconnect(reason: "Could not answer the camera.")
        }
    }

    /// Applies a peer's SDP, refusing it outright if the sealed fingerprint does
    /// not match what the SDP announces.
    private func apply(
        sdp: String,
        type: RTCSdpType,
        fingerprint: String?,
        to session: PeerSession
    ) async {
        let sealed = fingerprint.flatMap(DTLSFingerprint.init(sdpValue:))
        do {
            try await session.setRemote(sdp: sdp, type: type, sealedFingerprint: sealed)
        } catch PeerSession.SessionError.fingerprintMismatch {
            failSecurity()
        } catch {
            scheduleReconnect(reason: "The camera's video connection was refused.")
        }
    }

    /// The address a payload came from. `from` is sealed, so it cannot be forged
    /// by the server — which is exactly why it is preferred over any routing
    /// field.
    private func sender(of payload: SignalingPayload) -> SignalingRecipient? {
        guard role == .camera else { return .camera }
        guard let deviceID = payload.from else { return nil }
        return .viewer(deviceID: deviceID)
    }

    private func makeSession(for peer: SignalingRecipient) -> PeerSession? {
        let observer = PeerConnectionObserver { [weak self] event in
            Task { @MainActor in
                await self?.handle(event, from: peer)
            }
        }
        guard let connection = WebRTCStack.factory.peerConnection(
            with: WebRTCStack.configuration(turn: turn),
            constraints: WebRTCStack.defaultConstraints(),
            delegate: observer
        ) else {
            return nil
        }
        return PeerSession(peer: peer, connection: connection, observer: observer)
    }

    // MARK: - Peer connection events

    private func handle(_ event: PeerSessionEvent, from peer: SignalingRecipient) async {
        switch event {
        case .iceCandidate(let sdp, let mid, let mLineIndex):
            try? await client?.send(
                .ice(candidate: sdp, mid: mid, mLineIndex: Int(mLineIndex)),
                to: peer
            )

        case .link(let link):
            await handleLink(link, from: peer)

        case .remoteTrackAdded:
            attachRemoteTrack(from: peer)

        case .renegotiationNeeded:
            // Only the Camera offers, and only after it already has a session.
            guard role == .camera, sessions[peer] != nil, case .connected = state else { return }
            await offer(to: peer)
        }
    }

    private func handleLink(_ link: PeerLinkState, from peer: SignalingRecipient) async {
        switch link {
        case .connected:
            await confirmSecurity(of: peer)

        case .failed:
            // ICE gave up entirely: rebuild rather than restart.
            sessions.removeValue(forKey: peer)?.close()
            connectedPeerCount = sessions.count
            scheduleReconnect(reason: "The video connection failed.")

        case .disconnected:
            // Usually transient. An ICE restart is the cheap fix and keeps the
            // verified DTLS session.
            if case .connected = state { state = .reconnecting }
            restartICE()

        case .closed:
            sessions.removeValue(forKey: peer)
            connectedPeerCount = sessions.count

        case .new, .checking:
            break
        }
    }

    /// The post-handshake half of the fingerprint binding. Until this passes, the
    /// connection carries no trusted media.
    private func confirmSecurity(of peer: SignalingRecipient) async {
        guard let session = sessions[peer] else { return }
        let verification = await session.verifyNegotiatedCertificate()
        guard verification.isTrusted else {
            failSecurity()
            return
        }

        isVerified = true
        statusDetail = nil
        state = .connected
        connectedPeerCount = sessions.count
        attachRemoteTrack(from: peer)
        // A reconnect builds a fresh track, so mute has to be re-applied or it
        // silently lapses.
        session.setRemoteAudioEnabled(!isMuted)
        if role == .camera {
            await updateCaptureForViewerCount()
        }
    }

    /// Viewer side: find the inbound video track once the connection has one.
    private func attachRemoteTrack(from peer: SignalingRecipient) {
        guard role == .viewer, let session = sessions[peer] else { return }
        remoteVideoTrack = session.remoteVideoTrack()
    }

    // MARK: - Quality

    private func startQualityLoop() {
        qualityTask?.cancel()
        qualityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.sampleQuality()
            }
        }
    }

    private func sampleQuality() async {
        guard let session = sessions.values.first,
              let sample = await session.qualitySample()
        else {
            return
        }
        linkQuality = Self.linkQuality(for: sample)

        guard let next = qualityController.ingest(sample) else { return }
        quality = next
        // Both halves matter: the encoder cap stops WebRTC overshooting the rung,
        // and the capture format is what actually saves the Camera's battery.
        for session in sessions.values {
            session.applyBitrateCap(kbps: next.maxBitrateKbps)
        }
        await capture?.start(quality: next)
    }

    /// Pure mapping from a statistics sample to the indicator a parent reads, so
    /// it is deliberately free of the engine's isolation and can be asserted
    /// directly.
    nonisolated static func linkQuality(
        for sample: AdaptiveQualityController.Sample
    ) -> LinkQuality {
        if sample.packetLossFraction > 0.05 || sample.roundTripTime > 0.5 { return .poor }
        if sample.packetLossFraction > 0.02 || sample.roundTripTime > 0.25 { return .fair }
        return .good
    }

    /// Capture-only mode: with no Viewer, frames are worth capturing only if a
    /// detector is consuming them.
    private func updateCaptureForViewerCount() async {
        guard let capture else { return }
        if sessions.isEmpty {
            await capture.setCaptureOnly(services.detectionSettings.requiresCapturePipeline)
        } else if !capture.isCapturing {
            await capture.start(quality: quality)
        }
    }

    // MARK: - Recovery

    /// Asks every session to re-gather. Cheaper than a rebuild, and it preserves
    /// the DTLS session whose certificate this pairing already verified.
    private func restartICE() {
        guard role == .camera, !isStopping else { return }
        Task {
            for peer in sessions.keys {
                await offer(to: peer, iceRestart: true)
            }
        }
    }

    private func scheduleReconnect(reason: String) {
        guard !isStopping, !state.isSecurityFailure else { return }
        guard reconnectTask == nil else { return }
        statusDetail = reason
        state = .reconnecting

        let policy = ReconnectPolicy()
        reconnectTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                attempt += 1
                let delay = policy.delay(
                    forAttempt: attempt,
                    randomUnit: Double.random(in: 0...1)
                )
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled, !self.isStopping else { return }
                guard !self.state.isSecurityFailure else { return }

                await self.rebuild()
                if case .connecting = self.state {
                    self.reconnectTask = nil
                    return
                }
            }
        }
    }

    private func rebuild() async {
        eventTask?.cancel(); eventTask = nil
        for session in sessions.values { session.close() }
        sessions.removeAll()
        connectedPeerCount = 0
        remoteVideoTrack = nil
        isVerified = false

        let previous = client
        client = nil
        await previous?.disconnect()

        state = .connecting
        await connect()
    }

    private func fail(_ reason: String) {
        state = .failed(reason: reason, isSecurityFailure: false)
    }

    /// The one failure that is never retried.
    private func failSecurity() {
        isVerified = false
        remoteVideoTrack = nil
        for session in sessions.values { session.close() }
        sessions.removeAll()
        connectedPeerCount = 0
        state = .failed(
            reason: "CribWire could not verify it is talking to your paired device. "
                + "Someone may be interfering with the connection. Pair again.",
            isSecurityFailure: true
        )
        Task { await capture?.stop() }
    }
}

// MARK: - Convenience

private extension SignalingClient {
    /// Best-effort teardown notice. Failures are ignored: the socket is about to
    /// close either way.
    func send(_ payload: SignalingPayload, toAll peers: [SignalingRecipient]) async {
        for peer in peers {
            _ = try? await send(payload, to: peer)
        }
    }
}
