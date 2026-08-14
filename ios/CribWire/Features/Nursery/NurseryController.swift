import Combine
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
final class NurseryController: ObservableObject {

    // MARK: - State

    @Published private(set) var state = NurseryState()

    /// Called when the state changes and Viewers should be told. Debounced —
    /// see `publish()`.
    var onStateChange: ((NurseryState) -> Void)?

    /// Set by the engine. The refresh loop only runs while somebody is watching:
    /// polling a music player on a Camera nobody is connected to is battery spent
    /// on an answer no one will read.
    var hasConnectedViewers = false {
        didSet {
            guard hasConnectedViewers != oldValue else { return }
            hasConnectedViewers ? startRefreshLoop() : stopRefreshLoop()
        }
    }

    // MARK: - Dependencies

    private let capture: CameraCaptureController?
    private let recentsStore: MusicRecentsStore
    private let volume: SystemVolumeController
    private let defaults: UserDefaults
    /// Every provider this build knows about, whether or not it is usable here.
    private let allProviders: [any MusicProvider]

    private static let providerKey = "cribwire.musicProvider"

    /// Providers that could actually be offered. A service with no credentials
    /// compiled in is not shown at all, rather than shown as permanently broken.
    private var providers: [any MusicProvider] {
        allProviders.filter { $0.isConfigured }
    }

    private var provider: (any MusicProvider)? {
        providers.first { $0.kind == selectedKind } ?? providers.first
    }

    private var selectedKind: MusicProviderKind {
        didSet {
            guard selectedKind != oldValue else { return }
            defaults.set(selectedKind.rawValue, forKey: Self.providerKey)
        }
    }

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
        providers: [any MusicProvider]? = nil
    ) {
        self.capture = capture
        self.recentsStore = recentsStore
        self.volume = volume ?? SystemVolumeController()
        self.defaults = defaults
        self.allProviders = providers ?? [AppleMusicProvider(), TidalMusicProvider()]
        self.selectedKind = defaults.string(forKey: Self.providerKey)
            .flatMap(MusicProviderKind.init(rawValue:))
            ?? .appleMusic
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

        // The light is the capture controller's to switch off — it does so as
        // part of stopping capture, which is the only ordering that can work.
        // Music is this type's, and it is stopped rather than left playing to an
        // empty room after the monitor was shut down.
        let provider = self.provider
        Task { await provider?.stop() }
        state = NurseryState()
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

    private func select(playlistID: String?, provider requested: MusicProviderKind?) async {
        guard let playlistID else { return }

        if let requested, requested != selectedKind, providers.contains(where: { $0.kind == requested }) {
            // Switching services mid-play would otherwise leave the old one
            // playing underneath the new one.
            await provider?.stop()
            selectedKind = requested
        }
        guard let provider else { return }

        guard let name = await provider.play(playlistID: playlistID) else {
            // The playlist is gone — deleted on the account since it was last
            // played. Drop it from the history so it stops being offered, rather
            // than leaving a dead entry at the top of the Viewer's list.
            var recents = recentsStore.load()
            recents.forget(playlistID: playlistID, provider: provider.kind)
            recentsStore.save(recents)
            await reloadPlaylists()
            return
        }

        recentsStore.record(playlistID: playlistID, provider: provider.kind, name: name)
        await reloadPlaylists()
    }

    private func apply(light command: LightCommand) {
        guard let capture else { return }
        state.light = capture.setLight(isOn: command.isOn, level: command.level)
    }

    // MARK: - Camera-side actions

    /// Asks the current provider for whatever authorisation it needs.
    ///
    /// Only ever called from the Camera's own screen. A permission sheet is a
    /// question, and there is nobody in front of a nursery camera to answer one —
    /// which is why no Viewer command reaches this.
    /// - Returns: whether the Camera can play afterwards. `false` after a request
    ///   that changed nothing means the prompt has already been answered once and
    ///   only the Settings app can undo it — iOS asks exactly once.
    @discardableResult
    func requestMusicAuthorization() async -> Bool {
        guard let provider else { return false }
        let availability = await provider.requestAuthorization()
        await reload()
        return availability == .ready
    }

    /// Switches which service the Camera plays from.
    func select(provider kind: MusicProviderKind) async {
        guard kind != selectedKind, providers.contains(where: { $0.kind == kind }) else { return }
        await provider?.stop()
        selectedKind = kind
        await reload()
    }

    // MARK: - Refresh

    /// Full refresh: availability, playlists, transport state, light.
    func reload() async {
        await reloadPlaylists()
        await refreshMusicState()
        refreshLightState()
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
                limitedTo: Set(providers.map { $0.kind })
            ),
            recentlyPlayed: loaded.recentlyPlayed,
            favorites: loaded.favorites
        )
    }

    private func refreshMusicState() async {
        guard let provider else {
            state.music = MusicState(
                provider: selectedKind,
                availability: .notConfigured,
                availableProviders: []
            )
            return
        }
        let availability = await provider.availability()
        let playing = provider.nowPlaying
        state.music = MusicState(
            provider: provider.kind,
            availability: availability,
            isPlaying: provider.isPlaying,
            // Reported only when it can be moved: a slider the Viewer can drag
            // and the Camera cannot honour is worse than no slider.
            volume: volume.canSetVolume ? volume.volume : nil,
            title: playing.title,
            artist: playing.artist,
            playlistID: provider.currentPlaylistID,
            playlists: playlists,
            availableProviders: providers.map { $0.kind }
        )
    }

    private func refreshLightState() {
        state.light = capture?.lightState ?? LightState(availability: .noHardware)
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
