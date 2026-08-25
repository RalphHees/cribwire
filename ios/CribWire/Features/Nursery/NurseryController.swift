import CribWireKit
import Foundation

/// The Camera's music and light, and the only thing that acts on a Viewer's
/// commands.
///
/// It sits between three parties that know nothing about each other: the
/// `MusicProvider`s, which know how to play; `CameraCaptureController`, which owns
/// the torch because it owns the capture device; and `StreamingEngine`, which
/// carries sealed commands in and sealed state out. All the sequencing lives here,
/// exactly as it does for negotiation in the engine.
///
/// Two rules shape everything below.
///
/// **The Camera is the authority.** A command is a request. This type clamps it,
/// may refuse it, and then reports what actually happened. The Viewer draws that
/// report and holds no state of its own, so a button never claims something the
/// room did not do.
///
/// **Nothing here may break the monitor.** Music and a night light are comforts;
/// the stream is not. Every music call is best-effort and non-throwing, the torch
/// is best-effort, and a provider that hangs cannot stall the engine because
/// commands are applied off the signaling read loop.
@MainActor
@Observable
final class NurseryController {

    // MARK: - State

    private(set) var state = NurseryState()

    /// Called when the state changes and Viewers should be told. Debounced —
    /// see `publish()`.
    var onStateChange: ((NurseryState) -> Void)?

    /// Called when a Viewer changed the alert settings.
    ///
    /// This type stores them and reports them; it does not run the detectors —
    /// starting and stopping a microphone tap belongs to the engine, which owns
    /// the detection coordinator and the capture pipeline the settings decide the
    /// fate of. Persisting here and applying there is the same split as the
    /// torch: the value is the room's, the hardware is somebody else's.
    var onAlertSettingsChange: ((DetectionSettings) -> Void)?

    /// Set by the engine. The refresh loop only runs while somebody is watching:
    /// polling a music player on a Camera nobody is connected to is battery spent
    /// on an answer no one will read.
    ///
    /// Computed over a backing store rather than carrying a `didSet`: the
    /// `@Observable` macro rewrites stored properties into get/set accessors,
    /// and Swift does not allow a property to have both accessors and observers.
    var hasConnectedViewers: Bool {
        get { storedHasConnectedViewers }
        set {
            guard newValue != storedHasConnectedViewers else { return }
            storedHasConnectedViewers = newValue
            newValue ? startRefreshLoop() : stopRefreshLoop()
        }
    }

    private var storedHasConnectedViewers = false

    // MARK: - Dependencies

    private let capture: CameraCaptureController?
    private let recentsStore: MusicRecentsStore
    private let volume: SystemVolumeController
    private let defaults: UserDefaults
    /// Both settings a Viewer can edit outlive any connection, so both are read
    /// from and written straight back to their stores rather than kept only in
    /// this object: a Camera restarted at midnight comes back tuned the way the
    /// person who was woken by it left it.
    private let sensitivityStore: CameraSensitivityStore
    private let detectionStore: DetectionSettingsStore
    /// Every provider this build knows about, whether or not it is usable here.
    private let allProviders: [any MusicProvider]
    /// The music already playing on this phone, which is usually not ours.
    private let systemRemote: any SystemMusicRemote

    private static let providerKey = "cribwire.musicProvider"
    private static let talkbackVolumeKey = "cribwire.talkbackVolume"

    /// Providers this deployment could offer at all. A service with no
    /// credentials compiled in is not shown even on the Camera's own account
    /// list, rather than shown as something permanently broken.
    private var providers: [any MusicProvider] {
        allProviders.filter { $0.isConfigured }
    }

    /// Providers a parent has actually connected on this phone.
    ///
    /// The list the Viewer is told about, and the only list music is ever played
    /// from. A configured-but-signed-out service is not a service — it is an
    /// invitation to sign in, and that invitation only makes sense on the Camera
    /// where someone can answer it.
    private var connectedProviders: [any MusicProvider] {
        providers.filter { $0.isConnected }
    }

    /// The provider music actually plays through. `nil` until a parent connects
    /// an account, which is the state a freshly set-up Camera is in.
    private var provider: (any MusicProvider)? {
        connectedProviders.first { $0.kind == selectedKind } ?? connectedProviders.first
    }

    /// The provider the state *describes* when none is connected.
    ///
    /// Something has to be named — `MusicState.provider` is not optional, and
    /// making it so would ripple onto every Viewer build already shipped — so
    /// the selection is reported even while it cannot play. What stops that
    /// being misleading is `MusicState.hasConnectedProvider`: an empty
    /// `availableProviders` tells the Viewer to explain that nothing is
    /// connected rather than to name this one as broken.
    private var reportingProvider: (any MusicProvider)? {
        provider ?? providers.first { $0.kind == selectedKind } ?? providers.first
    }

    /// Same shape as `hasConnectedViewers`, and for the same reason.
    private var selectedKind: MusicProviderKind {
        get { storedSelectedKind }
        set {
            guard newValue != storedSelectedKind else { return }
            storedSelectedKind = newValue
            defaults.set(newValue.rawValue, forKey: Self.providerKey)
        }
    }

    private var storedSelectedKind: MusicProviderKind

    private var playlists: [PlaylistSummary] = []
    /// The last state Viewers were actually told about. See `deliver(force:)`.
    private var lastDelivered: NurseryState?
    private var refreshTask: Task<Void, Never>?
    private var broadcastTask: Task<Void, Never>?
    private var isRunning = false

    /// How often the Camera re-reads what the music player and the torch are
    /// actually doing. Polled rather than observed on purpose: the two music SDKs
    /// publish changes in different, service-specific ways, and a single cheap
    /// tick gives the Viewer one consistent picture of both the player *and* the
    /// hardware — including a torch iOS switched off thermally, which publishes
    /// nothing at all.
    private static let refreshInterval: TimeInterval = 5

    /// How long changes are gathered before Viewers are told. A slider drag
    /// produces a command every few milliseconds, and each one moves the state;
    /// without this the Camera would answer every one of them with a sealed
    /// message of its own.
    private static let broadcastDebounce: TimeInterval = 0.15

    init(
        capture: CameraCaptureController?,
        recentsStore: MusicRecentsStore = MusicRecentsStore(),
        volume: SystemVolumeController? = nil,
        defaults: UserDefaults = .standard,
        providers: [any MusicProvider]? = nil,
        systemRemote: (any SystemMusicRemote)? = nil
    ) {
        self.capture = capture
        self.recentsStore = recentsStore
        self.volume = volume ?? SystemVolumeController()
        self.defaults = defaults
        self.sensitivityStore = CameraSensitivityStore(defaults: defaults)
        self.detectionStore = DetectionSettingsStore(defaults: defaults)
        self.allProviders = providers
            ?? [AppleMusicProvider(), TidalMusicProvider(), SpotifyMusicProvider()]
        self.systemRemote = systemRemote ?? MediaPlayerMusicRemote()
        // Straight to the backing store: going through `selectedKind` would
        // write the value it was just read from back into UserDefaults.
        self.storedSelectedKind = defaults.string(forKey: Self.providerKey)
            .flatMap(MusicProviderKind.init(rawValue:))
            ?? .appleMusic

        // `object(forKey:)` rather than `double(forKey:)`: the latter answers 0
        // for a key that was never set, and 0 is silence — the one value a
        // talk-back gain must not be defaulted to.
        if let stored = defaults.object(forKey: Self.talkbackVolumeKey) as? Double {
            self.state.talkback = TalkbackState(volume: stored)
        }

        // Reported from the first message onwards, rather than after the first
        // change: a Viewer that connects to a Camera whose alerts are off has to
        // be able to see that, and turn them on.
        self.state.alerts = AlertsState(
            availability: .ready,
            settings: self.detectionStore.load()
        )
        self.state.sensitivity = capture?.sensitivityState
            ?? SensitivityState(availability: .cameraIdle, settings: self.sensitivityStore.load())
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        volume.onChange = { [weak self] level in
            // A hardware button pressed on the Camera itself has to reach the
            // Viewer's slider, or the two disagree until something else happens.
            guard let self else { return }
            self.state.music.volume = level
            self.publish()
        }
        volume.start()
        systemRemote.start()

        Task { await self.reload() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopRefreshLoop()
        broadcastTask?.cancel()
        broadcastTask = nil
        volume.onChange = nil
        volume.stop()
        // Only the notifications are ended. The Music app is left exactly as it
        // was found: whatever the parent had playing before CribWire started is
        // not something a monitor shutting down gets to stop.
        systemRemote.stop()

        // The light is the capture controller's to switch off — it does so as
        // part of stopping capture, which is the only ordering that can work.
        // Music is this type's, and it is stopped rather than left playing to an
        // empty room after the monitor was shut down.
        let provider = self.provider
        Task { await provider?.stop() }
        // The talk-back gain is carried across: it is what this Camera is set to,
        // and a monitor being stopped is not somebody changing it. The exposure
        // and the alert settings are carried for the same reason — they are
        // stored settings of this room, not facts about a connection, and
        // resetting them here would report a Camera that had forgotten them.
        state = NurseryState(
            talkback: state.talkback,
            sensitivity: SensitivityState(
                availability: .cameraIdle,
                settings: state.sensitivity.settings,
                supportsLowLightBoost: state.sensitivity.supportsLowLightBoost
            ),
            alerts: state.alerts
        )
        lastDelivered = nil
    }

    // MARK: - Commands

    /// Applies a Viewer's command.
    ///
    /// The engine has already established that this came from a Viewer with a
    /// verified session; what is left to check here is only that the command says
    /// something, and that the Camera can do it.
    func apply(_ command: NurseryCommand) async {
        guard !command.isEmpty else { return }
        if let music = command.music {
            await apply(music: music)
        }
        if let light = command.light, !light.isEmpty {
            apply(light: light)
        }
        if let sensitivity = command.sensitivity, !sensitivity.isEmpty {
            await apply(sensitivity: sensitivity)
        }
        if let alerts = command.alerts, let settings = alerts.settings {
            apply(alerts: settings)
        }
        publish()
    }

    private func apply(music command: MusicCommand) async {
        // Volume is the exception: it is the device's, not the player's, so it
        // works even when no music service is usable — which is what makes the
        // slider worth showing on a Camera whose subscription has lapsed.
        if command.action == .setVolume, let level = command.volume {
            volume.set(volume: level)
            state.music.volume = volume.volume
            return
        }

        // Transport goes to whichever player is actually making the sound — see
        // `transportTarget`. Everything below it is CribWire's own player by
        // definition: only it has a catalogue to choose from.
        if command.action.isTransport, case .system = transportTarget {
            apply(transport: command.action)
            await refreshMusicState()
            return
        }

        guard let provider else { return }

        switch command.action {
        case .play:
            await provider.play()
        case .pause:
            await provider.pause()
        case .toggle:
            // Resolved against the Camera's own reading rather than the Viewer's.
            // The Viewer's picture is always at least one round trip old, and on a
            // slow link two taps would otherwise both mean "pause".
            if provider.isPlaying {
                await provider.pause()
            } else {
                await provider.play()
            }
        case .next:
            await provider.next()
        case .previous:
            await provider.previous()
        case .stop:
            await provider.stop()
        case .selectPlaylist:
            await select(playlistID: command.playlistID, provider: command.provider)
        case .setProvider:
            if let kind = command.provider { await select(provider: kind) }
        case .refreshPlaylists:
            await reloadPlaylists()
        case .setVolume, .unknown:
            // `setVolume` was handled above; `unknown` is a command from a newer
            // Viewer and is deliberately dropped rather than guessed at.
            break
        }

        await refreshMusicState()
    }

    /// Which player a transport command should reach.
    ///
    /// The Camera can be making sound two ways at once — a playlist a Viewer
    /// started through CribWire, and whatever the parent left playing in the
    /// Music app — and only one of them is the one a pause is meant for.
    private enum TransportTarget {
        /// CribWire's own queue.
        case provider
        /// The Music app.
        case system
    }

    private var transportTarget: TransportTarget {
        guard let provider, provider.canControlPlayback else { return .system }
        // Ours wins whenever we have something: a Viewer that chose this playlist
        // means this playlist, and CribWire's player is the only one that can
        // resume it after a pause.
        if provider.isPlaying || provider.currentPlaylistID != nil { return .provider }
        // Nothing of ours is loaded, so anything the room can hear belongs to
        // somebody else's player. Reaching for it is the only reading of the
        // button that does what the parent meant.
        return systemRemote.isAvailable ? .system : .provider
    }

    private func apply(transport action: MusicCommand.Action) {
        switch action {
        case .play:
            systemRemote.play()
        case .pause:
            systemRemote.pause()
        case .toggle:
            // Against the Camera's own reading, for the same reason as the
            // provider path: the Viewer's picture is a round trip old.
            systemRemote.isPlaying ? systemRemote.pause() : systemRemote.play()
        case .next:
            systemRemote.next()
        case .previous:
            systemRemote.previous()
        case .stop:
            // There is no "stop" on a player this app does not own, and pausing
            // is what a parent means by it anyway.
            systemRemote.pause()
        case .selectPlaylist, .setProvider, .refreshPlaylists, .setVolume, .unknown:
            break
        }
    }

    private func select(playlistID: String?, provider requested: MusicProviderKind?) async {
        guard let playlistID else { return }

        if let requested,
           requested != selectedKind,
           connectedProviders.contains(where: { $0.kind == requested }) {
            // Switching services mid-play would otherwise leave the old one
            // playing underneath the new one.
            await provider?.stop()
            selectedKind = requested
        }
        guard let provider else { return }

        switch await provider.play(playlistID: playlistID) {
        case .playing(let name, let kind):
            recentsStore.record(
                playlistID: playlistID,
                provider: provider.kind,
                kind: kind,
                name: name
            )
        case .gone:
            // Deleted on the account since it was last played. Drop it from the
            // history so it stops being offered, rather than leaving a dead entry
            // at the top of the Viewer's list.
            var recents = recentsStore.load()
            recents.forget(playlistID: playlistID, provider: provider.kind)
            recentsStore.save(recents)
        case .unavailable:
            // Deliberately nothing. The history is the parent's record of what
            // they play in this room, and a failure that may be a lost network or
            // an expired token is not permission to edit it.
            break
        }
        await reloadPlaylists()
    }

    /// Records how loud a Viewer's voice should be played into the room.
    ///
    /// Only the value: turning it into a gain on a live peer connection is
    /// `StreamingEngine`'s job, since it is the one that holds the sessions. Kept
    /// here anyway because it belongs to the room rather than to a connection —
    /// it has to survive the Viewer going away and coming back, and it has to be
    /// readable by every Viewer rather than only the one that set it.
    func setTalkbackVolume(_ level: Double) {
        let clamped = min(max(level, 0), 1)
        guard clamped != state.talkback.volume else { return }
        state.talkback = TalkbackState(volume: clamped)
        defaults.set(clamped, forKey: Self.talkbackVolumeKey)
        publish()
    }

    private func apply(light command: LightCommand) {
        guard let capture else { return }
        state.light = capture.setLight(isOn: command.isOn, level: command.level)
    }

    /// Changes how much light the Camera makes its picture from.
    ///
    /// Folded onto what the Camera is currently running rather than taken whole,
    /// so a Viewer that moved only the slider cannot also flip the hardware boost
    /// back to whatever its own screen last drew.
    private func apply(sensitivity command: SensitivityCommand) async {
        let merged = command.applied(to: sensitivitySettings)
        guard merged != sensitivitySettings else { return }
        sensitivityStore.save(merged)
        if let capture {
            state.sensitivity = await capture.setSensitivity(merged)
        } else {
            state.sensitivity = SensitivityState(availability: .cameraIdle, settings: merged)
        }
    }

    /// The settings the Camera is running, whether or not capture is up. The
    /// capture controller is the authority while it exists — it is what actually
    /// holds the device — and the store answers for a Camera that is idle.
    private var sensitivitySettings: CameraSensitivity {
        capture?.sensitivity ?? sensitivityStore.load()
    }

    /// Applies a Viewer's alert settings.
    ///
    /// Stored here and handed on: the detectors themselves are started and
    /// stopped by whoever owns them. Reported straight back rather than after the
    /// engine has acted, because the settings *are* what was asked for — the
    /// engine can only fail to open a microphone, and that arrives separately as
    /// `isMicrophoneUnavailable`.
    private func apply(alerts settings: DetectionSettings) {
        detectionStore.save(settings)
        state.alerts = AlertsState(
            availability: .ready,
            settings: settings,
            isMicrophoneUnavailable: state.alerts.isMicrophoneUnavailable
        )
        onAlertSettingsChange?(settings)
    }

    /// Camera-side: the alert settings changed on this phone, or a detector
    /// reported whether it could open the microphone.
    ///
    /// Deliberately does not call `onAlertSettingsChange` — this is the report
    /// coming back, not a new instruction, and feeding it round again would have
    /// the engine re-applying its own settings on every tick.
    func reportAlerts(_ settings: DetectionSettings, isMicrophoneUnavailable: Bool) {
        let updated = AlertsState(
            availability: .ready,
            settings: settings,
            isMicrophoneUnavailable: isMicrophoneUnavailable
        )
        guard updated != state.alerts else { return }
        state.alerts = updated
        publish()
    }

    // MARK: - Camera-side actions

    /// Switches which service the Camera plays from.
    ///
    /// Only ever onto a connected one. A Viewer can only have been offered
    /// connected services, so a command naming anything else is either a stale
    /// screen — the account was signed out on the Camera a moment ago — or a
    /// Viewer newer than this Camera. Both are refused rather than acted on,
    /// which leaves the room playing what it was playing.
    func select(provider kind: MusicProviderKind) async {
        guard kind != selectedKind,
              connectedProviders.contains(where: { $0.kind == kind })
        else { return }
        await provider?.stop()
        selectedKind = kind
        await reload()
    }

    // MARK: - Accounts

    /// Connects a music account, on the Camera's own screen.
    ///
    /// Camera-side only, for the reason written on `MusicProviderKind`: every
    /// service here authenticates through a web sheet or a system prompt, and
    /// one raised by a tap in another room is a question nobody is standing in
    /// front of.
    ///
    /// - Returns: whether the service can play afterwards. `false` for Apple
    ///   Music after a prompt that changed nothing means iOS has already been
    ///   asked once and refused — only the Settings app can undo that, which is
    ///   what the Camera's screen offers next.
    @discardableResult
    func connect(_ kind: MusicProviderKind) async -> Bool {
        guard let target = providers.first(where: { $0.kind == kind }) else { return false }
        let availability = await target.requestAuthorization()

        // A parent who has just connected an account meant to use it. Selecting
        // it saves them a second trip to the Viewer to say so — and if it was
        // the only one, this is what the Camera was going to pick anyway.
        if target.isConnected { selectedKind = kind }
        await reload()
        return availability == .ready
    }

    /// Signs a music account out of this Camera.
    ///
    /// The music stops with it. `MusicProvider.signOut` is what actually ends
    /// playback — it has to, because only it knows what a stop means for its own
    /// service — and what is left here is the selection: a Camera whose selected
    /// service has just been signed out has to fall back to one that can still
    /// play, or the next Viewer to press play would reach nothing.
    func disconnect(_ kind: MusicProviderKind) async {
        guard let target = providers.first(where: { $0.kind == kind }) else { return }
        await target.signOut()

        if selectedKind == kind, let fallback = connectedProviders.first {
            selectedKind = fallback.kind
        }
        await reload()
    }

    /// Every service this build could offer, and where each one stands.
    ///
    /// Ordered by `MusicProviderKind.allCases` rather than by connection state,
    /// so a list a parent has learned the shape of does not rearrange itself
    /// under their thumb every time they sign something in.
    var accounts: [MusicAccount] {
        MusicProviderKind.allCases.compactMap { kind in
            guard let provider = providers.first(where: { $0.kind == kind }) else { return nil }
            return MusicAccount(
                kind: kind,
                isConnected: provider.isConnected,
                // What "playing from" means when nothing is connected is
                // nothing, so an unconnected service is never marked active
                // however the stored selection reads.
                isActive: provider.isConnected && self.provider?.kind == kind
            )
        }
    }

    // MARK: - Refresh

    /// Full refresh: availability, playlists, transport state, light.
    func reload() async {
        await reloadPlaylists()
        await refreshMusicState()
        refreshLightState()
        refreshSensitivityState()
        publish(immediately: true)
    }

    private func reloadPlaylists() async {
        guard let provider else {
            playlists = []
            return
        }
        let loaded = await provider.loadPlaylists()
        // The Camera's own history first, then the service's — see
        // `PlaylistShortlist` for why that order and not the other one.
        playlists = PlaylistShortlist.build(
            cameraRecents: recentsStore.load().summaries(
                // Connected services only. A playlist last played from an
                // account that has since been signed out is not something the
                // Camera could start tonight, and offering it would produce a
                // row whose only outcome is silence.
                limitedTo: Set(connectedProviders.map { $0.kind })
            ),
            recentlyPlayed: loaded.recentlyPlayed,
            favorites: loaded.favorites
        )
    }

    private func refreshMusicState() async {
        // What is playing, and whether it can be driven, are read from whichever
        // player the buttons would actually reach — so the line under the header
        // is the track those buttons would pause.
        let target = transportTarget
        let isSystem = target == .system
        // Annotated: the ternary otherwise erases the labels off the tuple.
        let playing: (title: String?, artist: String?) = isSystem
            ? systemRemote.nowPlaying
            : provider?.nowPlaying ?? (nil, nil)
        let isPlaying = isSystem ? systemRemote.isPlaying : provider?.isPlaying ?? false
        let canControlPlayback = isSystem
            ? systemRemote.isAvailable
            : provider?.canControlPlayback ?? false

        // Nothing this build could offer at all — no service compiled in, no
        // credentials for any of them. Deliberately distinct from "nothing
        // connected yet", which names a service a parent *could* connect and
        // reports an empty `availableProviders` beside it.
        guard let reporting = reportingProvider else {
            state.music = MusicState(
                provider: selectedKind,
                availability: .notConfigured,
                canControlPlayback: canControlPlayback,
                isPlaying: isPlaying,
                // Still reported with no music service at all: this is the
                // *device's* output volume, so it turns down whatever is making
                // sound in the nursery — including an app CribWire knows nothing
                // about.
                volume: volume.canSetVolume ? volume.volume : nil,
                title: playing.title,
                artist: playing.artist,
                availableProviders: []
            )
            return
        }
        let availability = await reporting.availability()
        state.music = MusicState(
            provider: reporting.kind,
            availability: availability,
            canControlPlayback: canControlPlayback,
            isPlaying: isPlaying,
            // Reported only when it can be moved: a slider the Viewer can drag
            // and the Camera cannot honour is worse than no slider.
            volume: volume.canSetVolume ? volume.volume : nil,
            title: playing.title,
            artist: playing.artist,
            // From the provider that can actually play, which is not always the
            // one being described: a Camera with nothing connected has nothing
            // loaded, whatever service it names.
            playlistID: provider?.currentPlaylistID,
            playlists: playlists,
            // The heart of what a Viewer is offered: the accounts a parent has
            // connected on this phone, and nothing else.
            availableProviders: connectedProviders.map { $0.kind }
        )
    }

    private func refreshLightState() {
        state.light = capture?.lightState ?? LightState(availability: .noHardware)
    }

    /// Re-read rather than remembered, for the same reason as the torch: whether
    /// exposure can be driven at all depends on there being a capture session,
    /// and a Viewer that connected while the Camera was idle would otherwise be
    /// told "idle" for the rest of the night.
    private func refreshSensitivityState() {
        state.sensitivity = capture?.sensitivityState
            ?? SensitivityState(availability: .cameraIdle, settings: sensitivityStore.load())
    }

    private func startRefreshLoop() {
        stopRefreshLoop()
        guard isRunning else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000)
                )
                guard let self, !Task.isCancelled, self.isRunning else { return }
                await self.refreshMusicState()
                self.refreshLightState()
                self.refreshSensitivityState()
                self.publish()
            }
        }
    }

    private func stopRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Publishing

    /// Tells Viewers, at most once per debounce window and only when something
    /// actually moved.
    ///
    /// - Parameter immediately: skip the window *and* the equality check. Used
    ///   where the send is owed to a particular Viewer rather than caused by a
    ///   change — one that has just verified needs the current state even though,
    ///   from the Camera's side, nothing happened.
    private func publish(immediately: Bool = false) {
        broadcastTask?.cancel()
        guard !immediately else {
            broadcastTask = nil
            deliver(force: true)
            return
        }
        broadcastTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.broadcastDebounce * 1_000_000_000)
            )
            guard let self, !Task.isCancelled else { return }
            self.broadcastTask = nil
            self.deliver(force: false)
        }
    }

    /// The refresh loop runs whether or not anything changed, so without this
    /// every watching Viewer would receive a sealed message every five seconds
    /// all night saying exactly what the last one said.
    private func deliver(force: Bool) {
        guard force || state != lastDelivered else { return }
        lastDelivered = state
        onStateChange?(state)
    }
}
