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
///
/// ## Still an `ObservableObject`
///
/// Deliberately, while everything around it has moved to `@Observable`.
///
/// `@Observable` would mean `@State` in the two views that own an engine, and
/// `State(wrappedValue:)` evaluates its argument on *every* view init — unlike
/// `@StateObject`, which takes an autoclosure and builds the object once. Both
/// engines are constructed inside `NavigationLink` destination closures on the
/// home screens, which re-run whenever a push arrives or the pairing list
/// changes, and a camera-side engine builds a `CameraCaptureController`: a
/// WebRTC video source, an `RTCCameraVideoCapturer` wrapping an
/// `AVCaptureSession`, and two tracks. Rebuilding and discarding that on every
/// redraw is a real cost, not a theoretical one.
///
/// Migrating this class means first making `capture`, `detection` and `nursery`
/// lazy — built on `start()` rather than in `init` — so that constructing an
/// engine is cheap. Worth doing; not worth folding into a toolchain bump.
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

    /// How long a Viewer returning to a paired Camera may wait for video.
    ///
    /// Every timing constant in this file is derived from it rather than picked
    /// independently, so the budget cannot be blown by one of them drifting.
    /// A returning parent staring at a spinner is the failure this bounds.
    static let recoveryBudget: TimeInterval = 10

    /// How long after a session is built a second `peer-online` for the same peer
    /// still counts as a duplicate announcement rather than that peer returning.
    ///
    /// Duplicates come from two devices attaching at once, so they are
    /// milliseconds apart; a returning app needs seconds for a Keychain read, a
    /// TURN fetch and a socket upgrade before it can announce anything.
    static let duplicatePresenceWindow: Duration = .seconds(2)

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
    /// Viewers with a **verified** connection. Drives the LIVE badge, so it must
    /// never count a peer whose certificate has not been checked.
    @Published private(set) var connectedPeerCount = 0
    /// Viewers the Camera is mid-negotiation with — offered to, but not yet
    /// verified.
    ///
    /// Separate from `connectedPeerCount` on purpose. Without it the Camera
    /// reported "Waiting for a viewer" throughout the entire handshake, which is
    /// actively misleading: it is the difference between "nobody has arrived" and
    /// "someone arrived and we cannot finish", and those have completely
    /// different causes.
    @Published private(set) var negotiatingPeerCount = 0
    /// The most recent ICE state seen from any peer.
    ///
    /// Exposed because "connecting" covers three very different situations —
    /// gathering, checking candidate pairs, and having exhausted them — and only
    /// the last is a fault. Without it a stuck Camera and a slow one look
    /// identical on screen.
    @Published private(set) var linkState: PeerLinkState = .new
    /// What the engine is currently doing about a problem, for the status line.
    @Published private(set) var statusDetail: String?
    /// Viewer-side: audio muted locally. The Camera keeps sending, so unmuting
    /// is instant.
    @Published private(set) var isMuted = false
    /// Viewer-side: push-to-talk is live.
    ///
    /// Never latches — releasing the button is what stops it, because a nursery
    /// microphone left open by accident is the one failure this feature must not
    /// have. Two rules enforce that beyond the button itself: it cannot be turned
    /// on at all until `isVerified`, and *any* loss of the peer turns it off, so a
    /// held button never carries a live microphone into the next handshake.
    @Published private(set) var isTalking = false
    /// Viewer-side: the Camera's last reported battery, `0...1`, or `nil` until it
    /// says. Arrives sealed over signaling — the server never sees it.
    @Published private(set) var peerBatteryLevel: Double?
    /// Viewer-side: whether the Camera is charging.
    @Published private(set) var isPeerCharging = false
    /// The music and light in the room.
    ///
    /// On a Viewer this is what the Camera last reported, and it is `nil` until it
    /// reports something — an older Camera never will, and a Viewer that invented
    /// a default would show controls for a room that cannot answer them. The
    /// Viewer renders this and holds no state of its own, so what the controls
    /// show is always what the room is doing rather than what was last tapped.
    ///
    /// On a Camera it mirrors `nursery.state`, which is what lets the Camera's own
    /// screen show the same facts without observing a second object.
    @Published private(set) var nurseryState: NurseryState?

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
        Task {
            await capture?.flip()
            // Only the back camera has a torch, so flipping is the one action
            // that can make the light unavailable — or bring it back. Viewers are
            // told at once rather than finding out on the next poll.
            await nursery?.reload()
        }
    }

    /// Viewer-side push-to-talk. `true` while the button is held.
    ///
    /// Enabling is refused unless the connection is verified. The screen already
    /// disables the button until then, but the rule belongs here rather than in a
    /// view: this is the microphone of the person holding the phone, travelling to
    /// a device whose identity has not been confirmed, and "the UI would not have
    /// called it" is not the same guarantee as "it cannot happen".
    ///
    /// *Stopping* is never refused — see `stopTalking()`.
    func setTalking(_ talking: Bool) {
        guard role == .viewer else { return }
        guard talking else {
            stopTalking()
            return
        }
        guard isVerified else { return }
        isTalking = true
        talkbackTrack?.isEnabled = true
    }

    /// Cuts the microphone, unconditionally.
    ///
    /// Called on every path that loses or invalidates a peer, not only on the
    /// button being released. A held button must not survive a reconnect: the next
    /// session is a fresh, unverified handshake, and re-arming a live microphone
    /// into it — which is exactly what mirroring `isTalking` onto a rebuilt track
    /// used to do — is the open-mic failure this feature is not allowed to have.
    private func stopTalking() {
        isTalking = false
        talkbackTrack?.isEnabled = false
    }

    /// Viewer-side: ask the Camera to change the music or the light.
    ///
    /// Fire-and-forget. Nothing optimistic happens locally — the controls move
    /// when the Camera's next `nursery` message says they moved, which is what
    /// keeps a button from claiming something the room did not do. A command that
    /// fails to send is simply not retried: the Viewer can see it did not take
    /// effect, and a re-sent "next track" arriving late is worse than one lost.
    func send(_ command: NurseryCommand) {
        guard role == .viewer, isVerified, let client else { return }
        Task { _ = try? await client.send(.control(command), to: .camera) }
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
        // **Always disabled here**, never mirrored from `isTalking`. This runs
        // while answering an offer — before the negotiated certificate has been
        // checked — so a track armed at this point would go live the instant DTLS
        // completed, ahead of the verification that is meant to gate it. Only
        // `confirmSecurity` may turn a microphone on, and only a fresh press.
        track.isEnabled = false
        // Fitted to the offer's existing audio transceiver — never added as a new
        // one. See `PeerSession.attachTalkback`.
        session.attachTalkback(track)
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
    /// Camera-side only: the music and the light a Viewer can reach.
    ///
    /// Owned here for the same reason as `detection` — it needs the capture
    /// controller (the torch belongs to the capture device) and it is driven by
    /// messages that arrive on this engine's signaling channel.
    let nursery: NurseryController?

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
    /// The in-flight `connect()`.
    ///
    /// Tracked rather than fire-and-forget because connecting is slow — a
    /// Keychain read and a TURN fetch — and a Viewer can easily navigate away
    /// before it finishes. An untracked one completes *after* `stop()`, assigns
    /// `client`, and then races the next `connect()`: the server allows one socket
    /// per device and closes the older on attach, so a late arrival gets the
    /// *newer* socket closed and the Viewer waits for an offer that can never be
    /// delivered.
    private var connectTask: Task<Void, Never>?
    /// Viewer-side watchdog for "signalling is up but no offer ever came".
    private var offerWatchdog: Task<Void, Never>?
    /// Per-peer deadlines for an ICE restart to actually recover.
    private var iceRecoveryDeadlines: [SignalingRecipient: Task<Void, Never>] = [:]
    /// Whether `start()` has run without a matching `stop()`. Separate from
    /// `state`, which is a description for the UI and can legitimately be any
    /// value while the engine is live.
    private var isRunning = false

    init(record: PairingRecord, services: AppServices) {
        self.record = record
        self.services = services
        self.role = record.localRole

        guard record.localRole == .camera else {
            self.capture = nil
            self.detection = nil
            self.nursery = nil
            return
        }

        // The coordinator has to exist before the capture controller, because the
        // capture controller's frame tap delivers straight into it.
        let detection = DetectionCoordinator(record: record, services: services)
        self.detection = detection
        let capture = CameraCaptureController { frame in
            Task { @MainActor in
                detection.ingest(frame)
            }
        }
        self.capture = capture
        self.nursery = NurseryController(capture: capture)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
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

        nursery?.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.nurseryState = state
                await self?.broadcastNursery(state)
            }
        }
        nursery?.start()

        connectTask = Task { [weak self] in
            guard let self else { return }
            let connected = await self.connect()
            guard !connected, !self.isStopping, !Task.isCancelled else { return }
            self.scheduleReconnect(reason: String(localized: "Could not reach the camera."))
        }
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

    /// Recomputes the peer counts from the session table.
    ///
    /// Called wherever `sessions` changes, so the two can never drift apart —
    /// they did, and the Camera spent every handshake claiming nobody was there.
    private func refreshPeerCounts() {
        negotiatingPeerCount = sessions.count
        connectedPeerCount = sessions.values.filter(\.isVerified).count
        // Music and torch state is polled only while somebody can see it.
        nursery?.hasConnectedViewers = connectedPeerCount > 0
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

    /// Sends the music and light state to every **verified** Viewer.
    ///
    /// Verified and not merely connected, unlike `broadcastStatus`. Battery is a
    /// number; this carries the names of playlists in the family's library, and it
    /// is not sent to a peer whose certificate has not yet been checked against
    /// the sealed fingerprint.
    private func broadcastNursery(_ state: NurseryState) async {
        guard role == .camera, let client else { return }
        let payload = SignalingPayload.nursery(state)
        for target in sessions.filter({ $0.value.isVerified }).map(\.key) {
            _ = try? await client.send(payload, to: target)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        isStopping = true
        connectTask?.cancel(); connectTask = nil
        offerWatchdog?.cancel(); offerWatchdog = nil
        eventTask?.cancel(); eventTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        qualityTask?.cancel(); qualityTask = nil
        pathMonitor?.stop(); pathMonitor = nil
        audioMonitor?.stop(); audioMonitor = nil
        localHost?.stop(); localHost = nil
        localGuest?.stop(); localGuest = nil
        isAudioInterrupted = false
        detection?.stop()
        nursery?.onStateChange = nil
        nursery?.stop()
        nurseryState = nil

        // Captured before teardown: the peers are told before the socket goes,
        // so they stop immediately rather than waiting for ICE to time out.
        let peers = Array(sessions.keys)
        for session in sessions.values {
            session.close()
        }
        sessions.removeAll()
        refreshPeerCounts()
        remoteVideoTrack = nil
        isVerified = false
        peerBatteryLevel = nil
        stopTalking()

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

    /// Brings signalling up.
    ///
    /// - Returns: whether a live signalling client is attached. **Reported rather
    ///   than acted on**: the retry loop is the only thing that decides to try
    ///   again, and it needs a truthful answer. Reading success off `state` is
    ///   what broke this before — `rebuild()` sets `.connecting` before dialling,
    ///   so a failed attempt still *looked* like a connection in progress and the
    ///   loop exited believing it had succeeded, leaving the engine with no
    ///   client and no pending retry.
    @discardableResult
    private func connect() async -> Bool {
        guard let identity = try? await services.secrets.loadDeviceIdentity(for: record.id),
              let keys = try? await services.secrets.loadKeys(for: record.id)
        else {
            fail("This pairing is missing its keys on this device. Pair again.")
            return false
        }
        // Loading the keys awaited the Keychain; the screen may be gone by now.
        guard !isStopping, !Task.isCancelled else { return false }
        self.identity = identity
        self.keys = keys

        // A local-network pairing reaches its peer over Bonjour instead of the
        // server's WebSocket. Everything above the socket — sealing, sequence
        // checks, role AAD, this whole engine — is identical; only the transport
        // differs, which is what `SignalingSocket` exists for.
        guard let apiBaseURL = record.apiBaseURL else {
            return await connectLocally(identity: identity, keys: keys)
        }

        // TURN before signaling: a relay candidate that arrives after the offer
        // is already gathered is a candidate the peer never sees.
        self.turn = await fetchTURNCredentials()

        // The TURN fetch is a network round trip, and the commonest moment to
        // navigate away is while it is outstanding.
        guard !isStopping, !Task.isCancelled else { return false }

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
            self.client = nil
            return false
        }

        // Connected, but possibly to a socket nobody wants any more. Hand it back
        // rather than leaving it attached: the server would otherwise keep it as
        // this device's live connection and close the next one.
        guard !isStopping, !Task.isCancelled else {
            self.client = nil
            await client.disconnect()
            return false
        }

        startEventLoop()

        if role == .camera {
            await capture?.start(quality: quality)
            startQualityLoop()
        }
        return true
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
    ) async -> Bool {
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
            // The Camera is now advertising; a Viewer arriving is what completes
            // it, and that is not something to fail on.
            return true

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
                guard !isStopping, !Task.isCancelled else {
                    await client.disconnect()
                    return false
                }
                self.client = client
                startEventLoop()
                return true
            } catch {
                statusDetail = String(localized: "Could not find the camera on this network.")
                return false
            }
        }
    }

    /// Guards the one state the Viewer cannot escape on its own: **no offer ever
    /// arrived**.
    ///
    /// The Camera is always the offerer, so a Viewer with a healthy socket and no
    /// offer has nothing to do but wait — and if the Camera missed its
    /// `peer-online` it would wait for ever. Re-attaching makes the Camera see a
    /// fresh arrival and offer again.
    ///
    /// It fires **only** when no session exists. An offer that has arrived and is
    /// mid-handshake must be left alone: DTLS retransmits on a schedule of its
    /// own and can easily need longer than this deadline, and tearing the socket
    /// down then does not rescue the connection — it destroys one that was about
    /// to succeed, and the next attempt starts the same race again. That loop is
    /// far worse than the stall this is meant to catch.
    private func startOfferWatchdog() {
        offerWatchdog?.cancel()
        guard role == .viewer else { return }
        // Half the budget: a re-attach plus a fresh offer has to fit in what is
        // left. At the old twelve seconds the watchdog could not save a recovery
        // it was supposed to be the backstop for.
        let deadline = Self.recoveryBudget / 2
        offerWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isRunning, !self.isStopping else { return }
            guard !self.isVerified else { return }
            // A session means an offer arrived and negotiation is under way.
            // Waiting is the correct thing to do; interrupting is not.
            guard self.sessions.isEmpty else { return }
            // Forced: a ladder that has already backed off to tens of seconds
            // would otherwise swallow this and blow the budget entirely.
            self.scheduleReconnect(
                reason: String(localized: "The camera did not answer."),
                restartingLadder: true
            )
        }
    }

    /// Drains the signalling client's events. Shared by both transports.
    private func startEventLoop() {
        eventTask?.cancel()
        startOfferWatchdog()
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

        // Everything below rests on one fact: a peer that announces itself is
        // running a **new** `SignalingClient`. Every path that attaches a socket
        // — `start()` and `rebuild()` alike — builds one, so its sequence
        // numbers restart at 1 and it holds no peer connections.
        await forgetSequenceWatermark(of: peer)
        discardStaleSession(with: peer)

        guard role == .camera else {
            // The Viewer waits to be offered to; announcing itself is all it has
            // to do.
            return
        }
        // Warm the capture pipeline *now*, not after the handshake verifies.
        //
        // With no Viewer the Camera stops capturing to save battery, and
        // restarting an `AVCaptureSession` takes on the order of a second. Doing
        // it after DTLS put that second on the critical path, in series with
        // negotiation, for no reason: a track with no frames yet still negotiates
        // normally, and the frames start flowing into the same source the moment
        // capture is up.
        warmCaptureForReturningViewer()
        await offer(to: peer)
    }

    /// Drops the inbound sequence watermark held for a peer that has just
    /// (re)attached.
    ///
    /// Without this, a Viewer that closes the app and comes back is silently
    /// unable to talk to the Camera at all. The Camera keeps one long-lived
    /// `SignalingClient`, whose ledger still holds that Viewer's last sequence
    /// number — say 37 — while the returning Viewer's brand-new client numbers
    /// its answer 1. Every message of the new session is rejected as
    /// `.outOfOrder`, and rejections are deliberately quiet, so the Camera offers,
    /// hears nothing back, and sits in "1 connecting…" for ever while the Viewer
    /// waits for video that cannot arrive. The same thing happens mirrored, to a
    /// Viewer that stayed up across a Camera reconnect.
    ///
    /// The watermark is dropped on `peer-online` only, never on `peer-offline`.
    /// Presence is the one thing the server can forge — it is not sealed — and
    /// forgetting a *live* peer's watermark is what would reopen the replay
    /// window. Tying it to the event that also means "this peer's counter just
    /// restarted" keeps the reset aligned with a peer that really did restart;
    /// what an injected `peer-online` buys an attacker is the chance to replay
    /// blobs it cannot decrypt into a handshake that pins the DTLS certificate,
    /// which fails — the same denial of service a server that simply drops frames
    /// already has.
    private func forgetSequenceWatermark(of peer: SignalingRecipient) async {
        guard let client else { return }
        switch peer {
        case .viewer(let deviceID):
            await client.forgetSender(deviceID: deviceID)
        case .camera:
            // Only a Viewer hears this, and a Viewer has exactly one peer.
            await client.forgetAllSenders()
        }
    }

    /// Throws away a peer connection belonging to the peer's *previous*
    /// signalling session.
    ///
    /// The session is dead whatever its ICE state says: the peer that owned the
    /// other end has rebuilt. It is not always reported as dead, though — the
    /// server supersedes a device's old socket on re-attach and deliberately
    /// sends no `peer-offline` for it, and a suspended app's socket can stay open
    /// until the heartbeat sweep notices. So a Camera can hold a session that
    /// still looks `.connected` for a Viewer that is already gone, and
    /// `offer(to:)` would decline to disturb it — leaving the returning Viewer
    /// with no offer at all.
    ///
    /// Sessions younger than the duplicate window are left alone: two presence
    /// announcements for the same peer can genuinely race when both devices
    /// attach at once (the broadcast and the directed announce-back), and *that*
    /// is the case `offer(to:)`'s guard exists for. Those arrive within
    /// milliseconds; a peer that has actually restarted takes seconds.
    private func discardStaleSession(with peer: SignalingRecipient) {
        guard let existing = sessions[peer],
              existing.age > Self.duplicatePresenceWindow
        else {
            return
        }
        sessions.removeValue(forKey: peer)?.close()
        refreshPeerCounts()
        guard role == .viewer else { return }
        remoteVideoTrack = nil
        isVerified = false
        stopTalking()
        nurseryState = nil
    }

    /// Starts capture without blocking negotiation on it.
    private func warmCaptureForReturningViewer() {
        guard role == .camera, let capture, !capture.isCapturing else { return }
        Task { await capture.start(quality: quality) }
    }

    private func handlePeerOffline(_ presence: SignalingPresence) {
        guard let peer = address(of: presence) else { return }
        sessions.removeValue(forKey: peer)?.close()
        refreshPeerCounts()
        if role == .viewer {
            remoteVideoTrack = nil
            isVerified = false
            stopTalking()
            // The controls go with the video. Leaving them on screen would offer
            // a light switch for a room this device can no longer reach.
            nurseryState = nil
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

        // A genuine reconnect arrives as peer-offline *then* peer-online, and the
        // offline half already removed the session — so an existing session here
        // means a duplicate presence event, not a new Viewer. Re-offering would
        // discard a peer connection that is mid-DTLS, together with its ICE
        // credentials and certificate, leaving the Viewer handshaking against
        // something that no longer exists.
        if !iceRestart,
           let existing = sessions[peer],
           existing.linkState.isNegotiatingOrUp {
            return
        }

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
            // The moment a session exists the Camera is negotiating, not waiting.
            refreshPeerCounts()
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

        case .nursery:
            guard role == .viewer, let state = payload.nur else { return }
            nurseryState = state

        case .control:
            // The one message that *acts* on this device, so it is the one with a
            // second check. The seal already proves the sender holds the QR
            // secret; requiring a verified session additionally means the sender
            // is a peer this Camera has finished a fingerprint-checked handshake
            // with — not a device replaying a blob at a Camera it never connected
            // to. A Camera is also the only role that may act: a Viewer receiving
            // one would mean something upstream is impersonating a Camera.
            guard role == .camera,
                  let command = payload.ctl,
                  sessions[sender]?.isVerified == true
            else {
                return
            }
            // Off the read loop. A music service that takes a second to answer
            // must not hold up the ICE candidate queued behind it.
            Task { [weak self] in await self?.nursery?.apply(command) }

        case .bye:
            sessions.removeValue(forKey: sender)?.close()
            refreshPeerCounts()
            if role == .viewer {
                remoteVideoTrack = nil
                isVerified = false
                stopTalking()
                nurseryState = nil
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
        linkState = link
        sessions[peer]?.linkState = link
        switch link {
        case .connected:
            iceRecoveryDeadlines.removeValue(forKey: peer)?.cancel()
            await confirmSecurity(of: peer)

        case .failed:
            // ICE gave up entirely: rebuild rather than restart.
            iceRecoveryDeadlines.removeValue(forKey: peer)?.cancel()
            sessions.removeValue(forKey: peer)?.close()
            refreshPeerCounts()
            scheduleReconnect(reason: "The video connection failed.")

        case .disconnected:
            // Usually transient, and an ICE restart is the cheap fix — *provided*
            // the DTLS transport underneath is still alive. It is not always: a
            // peer that tore its own peer connection down closes DTLS, and this
            // side sees only "disconnected". Re-offering on that connection can
            // never succeed, because DTLS will not hand shake a second time; the
            // session sits in have-local-offer for ever while the peer sends
            // ClientHellos nobody will answer.
            //
            // So the restart is attempted, but on a deadline. Nothing is torn
            // down while there is still a chance of recovery.
            if case .connected = state { state = .reconnecting }
            restartICE()
            startICERecoveryDeadline(for: peer)

        case .closed:
            iceRecoveryDeadlines.removeValue(forKey: peer)?.cancel()
            sessions.removeValue(forKey: peer)
            refreshPeerCounts()

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
        offerWatchdog?.cancel(); offerWatchdog = nil
        statusDetail = nil
        state = .connected
        refreshPeerCounts()
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
            // After capture is up, not before: whether the torch can be driven at
            // all depends on there being a running capture session, so a state
            // read a moment earlier would tell this Viewer the light is
            // unavailable and then never correct itself until the next tick.
            //
            // The reload publishes unconditionally, and this peer counts as
            // verified by now, so the broadcast that follows is what tells it —
            // sending to it here as well would only duplicate the message.
            await nursery?.reload()
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
    /// Escalates a stalled ICE restart into a completely fresh session.
    ///
    /// An ICE restart reuses the peer connection, and therefore its certificate
    /// and its DTLS transport. That is the whole point when the transport is
    /// healthy — and exactly why it cannot rescue one the peer has closed. Only a
    /// new peer connection gets a new DTLS handshake.
    ///
    /// The deadline is the full recovery budget rather than half of it: this runs
    /// *after* a restart has already been attempted, so it is the last resort,
    /// not the first response.
    private func startICERecoveryDeadline(for peer: SignalingRecipient) {
        iceRecoveryDeadlines[peer]?.cancel()
        iceRecoveryDeadlines[peer] = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.recoveryBudget * 1_000_000_000)
            )
            guard let self, !Task.isCancelled, self.isRunning, !self.isStopping else { return }
            self.iceRecoveryDeadlines.removeValue(forKey: peer)
            // Recovered on its own, or already replaced: nothing owed.
            guard let session = self.sessions[peer], !session.linkState.isUsable else {
                return
            }
            self.sessions.removeValue(forKey: peer)?.close()
            self.refreshPeerCounts()
            if self.role == .camera {
                // A fresh peer connection, and with it a DTLS handshake that can
                // actually complete.
                Task { await self.offer(to: peer) }
            } else {
                self.remoteVideoTrack = nil
                self.isVerified = false
                self.stopTalking()
                self.scheduleReconnect(
                    reason: String(localized: "The video connection stalled."),
                    restartingLadder: true
                )
            }
        }
    }

    private func restartICE() {
        guard role == .camera, !isStopping else { return }
        Task {
            for peer in sessions.keys {
                await offer(to: peer, iceRestart: true)
            }
        }
    }

    /// - Parameter restartingLadder: drop any in-flight backoff and retry from
    ///   the top. Used when something has *changed* — a Viewer is now waiting —
    ///   so continuing to wait out a long delay would be answering the wrong
    ///   question.
    private func scheduleReconnect(reason: String, restartingLadder: Bool = false) {
        guard !isStopping, !state.isSecurityFailure else { return }
        if restartingLadder {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
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

                // Only a genuine reconnection ends the ladder. Anything else and
                // the loop keeps backing off, which is the difference between a
                // Viewer that recovers and one that says "Connecting" for ever.
                if await self.rebuild() {
                    self.reconnectTask = nil
                    return
                }
            }
        }
    }

    @discardableResult
    private func rebuild() async -> Bool {
        guard isRunning, !isStopping else { return false }
        eventTask?.cancel(); eventTask = nil
        for session in sessions.values { session.close() }
        sessions.removeAll()
        refreshPeerCounts()
        remoteVideoTrack = nil
        isVerified = false
        stopTalking()
        nurseryState = nil

        let previous = client
        client = nil
        await previous?.disconnect()

        state = .connecting
        return await connect()
    }

    private func fail(_ reason: String) {
        state = .failed(reason: reason, isSecurityFailure: false)
    }

    /// The one failure that is never retried.
    private func failSecurity() {
        isVerified = false
        remoteVideoTrack = nil
        stopTalking()
        nurseryState = nil
        for session in sessions.values { session.close() }
        sessions.removeAll()
        refreshPeerCounts()
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
