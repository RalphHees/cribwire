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
    /// Viewer-side: push-to-talk is live. Never latches — releasing the button is
    /// what stops it, because a nursery microphone left open by accident is the
    /// one failure this feature must not have.
    @Published private(set) var isTalking = false
    /// Viewer-side: the Camera's last reported battery, `0...1`, or `nil` until it
    /// says. Arrives sealed over signaling — the server never sees it.
    @Published private(set) var peerBatteryLevel: Double?
    /// Viewer-side: whether the Camera is charging.
    @Published private(set) var isPeerCharging = false

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

    /// Viewer-side push-to-talk. `true` while the button is held.
    func setTalking(_ talking: Bool) {
        guard role == .viewer else { return }
        isTalking = talking
        talkbackTrack?.isEnabled = talking
    }

    /// Builds the talk-back track on first use and hands it to `session`.
    private func attachTalkbackTrack(to session: PeerSession) {
        let track: RTCAudioTrack
        if let existing = talkbackTrack {
            track = existing
        } else {
            let source = WebRTCStack.factory.audioSource(with: WebRTCStack.defaultConstraints())
            track = WebRTCStack.factory.audioTrack(with: source, trackId: "cribwire-talkback")
            talkbackTrack = track
        }
        // Disabled until the button is pressed. A reconnect rebuilds the session,
        // so this is re-asserted rather than assumed.
        track.isEnabled = isTalking
        session.addTrack(track, streamID: WebRTCStack.streamID)
    }

    // MARK: - Dependencies

    private let record: PairingRecord
    private let services: AppServices
    private let role: PairingRole

    /// Camera-side only.
    let capture: CameraCaptureController?
    /// Camera-side only. Owned here because it consumes the capture feed: the
    /// frames it needs are the ones this engine is already encoding.
    let detection: DetectionCoordinator?

    private var client: SignalingClient?
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var qualityTask: Task<Void, Never>?
    private var pathMonitor: NetworkPathMonitor?
    private var audioMonitor: AudioInterruptionMonitor?
    /// Local-network transport, one side or the other. Nil on the server path.
    private var localHost: LocalPairingHost?
    private var localGuest: LocalPairingGuest?
    /// Set while a call or Siri holds the audio session, so the recovery path
    /// knows it is resuming rather than starting.
    private var isAudioInterrupted = false
    /// Viewer-side push-to-talk track. Built once and kept **disabled**: the
    /// track stays in the SDP so pressing the button is instant and needs no
    /// renegotiation, but it produces nothing until it is explicitly enabled.
    private var talkbackTrack: RTCAudioTrack?

    /// Camera-side: the last battery reading, resent to every viewer that joins.
    /// Without it a Viewer shows "unknown" until the level next changes, which on
    /// a charging Camera can be hours.
    private var lastBattery: (level: Double, isCharging: Bool)?

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

        guard record.localRole == .camera else {
            self.capture = nil
            self.detection = nil
            return
        }

        // The coordinator has to exist before the capture controller, because the
        // capture controller's frame tap delivers straight into it.
        let detection = DetectionCoordinator(record: record, services: services)
        self.detection = detection
        self.capture = CameraCaptureController { frame in
            Task { @MainActor in
                detection.ingest(frame)
            }
        }
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

        audioMonitor = AudioInterruptionMonitor { [weak self] event in
            self?.handle(audio: event)
        }
        audioMonitor?.start()

        // Detection is independent of whether anyone is watching: the Camera
        // alerts on a quiet nursery with no Viewer connected, which is the whole
        // point of it running detection itself.
        applyDetectionSettings(services.detectionSettings)

        Task { await self.connect() }
    }

    /// Starts or stops each detector to match the alerts screen, and tells the
    /// capture tap whether to extract luma.
    func applyDetectionSettings(_ settings: DetectionSettings) {
        detection?.apply(settings)
        capture?.setMovementDetectionEnabled(settings.movement.isEnabled)
        Task { await self.updateCaptureForViewerCount() }
    }

    /// Battery readings from the Camera screen.
    ///
    /// Two consumers, deliberately separate: the detector decides whether this is
    /// worth a push (`LowBatteryMonitor`, once per discharge), while every reading
    /// is mirrored to connected Viewers so their gauge is live.
    func ingest(batteryLevel: Double, isCharging: Bool) {
        detection?.ingest(batteryLevel: batteryLevel, isCharging: isCharging)

        guard role == .camera else { return }
        lastBattery = (batteryLevel, isCharging)
        Task { await self.broadcastStatus() }
    }

    /// Sends the last battery reading to every connected Viewer.
    private func broadcastStatus(to peer: SignalingRecipient? = nil) async {
        guard let client, let battery = lastBattery else { return }
        let payload = SignalingPayload.status(
            batteryLevel: battery.level,
            isCharging: battery.isCharging
        )
        for target in peer.map({ [$0] }) ?? Array(sessions.keys) {
            _ = try? await client.send(payload, to: target)
        }
    }

    func stop() {
        isStopping = true
        eventTask?.cancel(); eventTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        qualityTask?.cancel(); qualityTask = nil
        pathMonitor?.stop(); pathMonitor = nil
        audioMonitor?.stop(); audioMonitor = nil
        localHost?.stop(); localHost = nil
        localGuest?.stop(); localGuest = nil
        isAudioInterrupted = false
        detection?.stop()

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
        peerBatteryLevel = nil
        isTalking = false
        talkbackTrack?.isEnabled = false

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

        // A local-network pairing reaches its peer over Bonjour instead of the
        // server's WebSocket. Everything above the socket — sealing, sequence
        // checks, role AAD, this whole engine — is identical; only the transport
        // differs, which is what `SignalingSocket` exists for.
        guard let apiBaseURL = record.apiBaseURL else {
            await connectLocally(identity: identity, keys: keys)
            return
        }

        // TURN before signaling: a relay candidate that arrives after the offer
        // is already gathered is a candidate the peer never sees.
        self.turn = await fetchTURNCredentials()

        let client = SignalingClient(
            configuration: .init(
                baseURL: apiBaseURL,
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

        startEventLoop()

        if role == .camera {
            await capture?.start(quality: quality)
            startQualityLoop()
        }
    }

    /// Connects over the local network: the Camera advertises and waits, the
    /// Viewer browses and dials.
    ///
    /// No TURN and no STUN are fetched. Both exist to traverse the internet, and
    /// there is no internet on this path — the peers are on one link, so the host
    /// candidates ICE gathers locally are all it needs.
    private func connectLocally(
        identity: PairingSecretsStore.DeviceIdentity,
        keys: PairingKeys
    ) async {
        switch role {
        case .camera:
            let host = LocalPairingHost(
                pairingID: record.id,
                keys: keys,
                deviceID: identity.deviceID,
                deviceKey: identity.deviceKey
            ) { [weak self] claim in
                guard let self else { return }
                self.client = claim.client
                self.startEventLoop()
                // A Viewer that connects locally has, by connecting, announced
                // itself — there is no presence event to wait for.
                Task { await self.offer(to: .viewer(deviceID: claim.viewerDeviceID)) }
            }
            localHost = host
            host.start()
            await capture?.start(quality: quality)
            startQualityLoop()

        case .viewer:
            let guest = LocalPairingGuest()
            localGuest = guest
            do {
                let (_, client) = try await guest.claim(
                    pairingID: record.id,
                    keys: keys,
                    deviceID: identity.deviceID,
                    deviceKey: identity.deviceKey
                )
                self.client = client
                startEventLoop()
            } catch {
                scheduleReconnect(reason: String(localized: "Could not find the camera on this network."))
            }
        }
    }

    /// Drains the signalling client's events. Shared by both transports.
    private func startEventLoop() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let events = await self?.client?.events else { return }
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
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

        case .hello:
            // The introduction already did its job during pairing; a repeat on an
            // established link is harmless and carries nothing to act on.
            break

        case .status:
            // Camera-sent, Viewer-consumed. A Camera receiving one would mean a
            // Viewer is impersonating a Camera, so it is ignored rather than
            // trusted.
            guard role == .viewer else { return }
            peerBatteryLevel = payload.batt
            isPeerCharging = payload.chg ?? false

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

        // Added after the remote offer is applied and before the answer is built.
        // In Unified Plan this reuses the receive-only audio transceiver the offer
        // created rather than adding a second m-line, so the answer comes back
        // `sendrecv` and talk-back needs no follow-up renegotiation.
        attachTalkbackTrack(to: session)

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
        // Tell the new peer the battery now, rather than leaving its gauge blank
        // until the level happens to change.
        if role == .camera {
            await broadcastStatus(to: peer)
        }
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

    // MARK: - Audio interruptions

    /// A call, Siri, an alarm, a headphone unplugged, or the audio stack dying.
    ///
    /// The Camera has more to do than the Viewer here: it loses the microphone
    /// feeding both the stream and the noise detector, so both have to be put
    /// back. Video is untouched by all of this — a peer connection survives an
    /// audio interruption — which is why none of these paths tear the session
    /// down.
    private func handle(audio event: AudioInterruptionMonitor.Event) {
        switch event {
        case .interrupted:
            isAudioInterrupted = true
            statusDetail = String(localized: "Paused for a call")
            // The mic is gone, so the detector would read silence and could
            // never fire. Stopping it is honest; leaving it running is not.
            detection?.stop()

        case .resumable:
            isAudioInterrupted = false
            statusDetail = nil
            WebRTCStack.configureAudioSession(mode: .active)
            applyDetectionSettings(services.detectionSettings)

        case .endedWithoutResume:
            // Something else still owns the audio session. Reactivating now
            // would fail, so the state is left set for the next `.resumable` or
            // for the scene becoming active again.
            statusDetail = String(localized: "Waiting for the call to end")

        case .routeChanged(let deviceDisconnected):
            // The session is intact; only where the sound goes has changed. The
            // category is re-asserted because a disconnect can drop the app back
            // to the receiver, which on a Camera on a shelf is inaudible.
            if deviceDisconnected {
                WebRTCStack.configureAudioSession(mode: .active)
            }

        case .mediaServicesWereReset:
            // Every audio object in the process is now invalid, including the
            // ones inside WebRTC. A full rebuild is the only recovery.
            statusDetail = String(localized: "Restarting audio")
            WebRTCStack.configureAudioSession(mode: .active)
            detection?.stop()
            applyDetectionSettings(services.detectionSettings)
            scheduleReconnect(reason: "The audio system restarted.")
        }
    }

    /// Called when the scene comes back to the foreground: an interruption that
    /// ended while the app was away never delivered its `.resumable`.
    func recoverFromInterruptionIfNeeded() {
        guard isAudioInterrupted else { return }
        handle(audio: .resumable)
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
