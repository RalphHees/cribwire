import CribWireKit
import SwiftUI

/// The Viewer's music and light controls.
///
/// Designed for one hand in a dark room by someone who is not fully awake, which
/// rules out most of what a music UI normally does. There is no browsing, no
/// search, no artwork and no queue: a short list of playlists that are already in
/// rotation, four transport buttons, two sliders. Everything it shows comes from
/// the Camera's own report — pressing a button changes nothing on screen until the
/// room says it changed — so a control can be slow but never wrong.
struct NurseryControlsView: View {

    let state: NurseryState
    let send: (NurseryCommand) -> Void

    @State private var showPlaylists = false

    var body: some View {
        VStack(spacing: 10) {
            musicCard
            lightCard
        }
        .sheet(isPresented: $showPlaylists) {
            PlaylistPickerView(music: state.music) { playlist in
                send(.music(.selectPlaylist(id: playlist.playlistID, provider: playlist.provider)))
                showPlaylists = false
            }
        }
    }

    // MARK: - Music

    private var musicCard: some View {
        KCCard {
            VStack(alignment: .leading, spacing: 12) {
                header(
                    symbol: state.music.isPlaying ? "music.note.list" : "music.note",
                    title: "Music",
                    // The service is named in the header when there is only one,
                    // and becomes a picker when there is a choice. Showing a
                    // one-option picker would be a control that does nothing.
                    trailing: hasProviderChoice ? nil : state.music.provider.displayName
                )

                if hasProviderChoice { providerPicker }

                if let reason = musicUnavailableReason {
                    Text(reason)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    nowPlayingLine
                    transportRow
                    if state.music.volume != nil { volumeRow }
                    playlistButton
                }
            }
        }
    }

    private var hasProviderChoice: Bool {
        state.music.availableProviders.count > 1
    }

    private var providerPicker: some View {
        Picker(
            "Music service",
            selection: Binding(
                get: { state.music.provider },
                set: { send(.music(.setProvider($0))) }
            )
        ) {
            ForEach(state.music.availableProviders, id: \.self) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(Text("Music service"))
    }

    /// What to say instead of controls, when there is nothing the buttons could do.
    ///
    /// Each case is a different thing for the parent to do, which is exactly why
    /// the Camera sends a case rather than a message: only the Viewer knows how to
    /// phrase it, and only in the reader's own language.
    private var musicUnavailableReason: String? {
        switch state.music.availability {
        case .ready:
            return nil
        case .needsPermission:
            return String(
                localized: "The camera has not been given access to music yet. Open CribWire on the camera phone to allow it."
            )
        case .needsSubscription:
            return String(
                localized: "\(state.music.provider.displayName) needs an active subscription on the camera phone."
            )
        case .notConfigured:
            return String(
                localized: "\(state.music.provider.displayName) is not set up on this camera."
            )
        case .unavailable:
            return String(localized: "The camera cannot reach \(state.music.provider.displayName) right now.")
        case .unknown:
            return String(localized: "This camera is running an older version of CribWire.")
        }
    }

    private var nowPlayingLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.music.title ?? String(localized: "Nothing playing"))
                .font(Theme.Typography.callout.weight(.semibold))
                .foregroundStyle(Theme.Palette.text)
                .lineLimit(1)
            if let artist = state.music.artist {
                Text(artist)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            state.music.nowPlaying.map { Text("Playing \($0)") } ?? Text("Nothing playing")
        )
    }

    private var transportRow: some View {
        HStack(spacing: 10) {
            transportButton(symbol: "backward.fill", label: "Previous") {
                send(.music(.previous))
            }
            transportButton(
                symbol: state.music.isPlaying ? "pause.fill" : "play.fill",
                label: state.music.isPlaying ? "Pause" : "Play",
                isProminent: true
            ) {
                // One command, resolved on the Camera. The Viewer's idea of what
                // is playing is always a round trip old, and two quick taps
                // against a stale picture would otherwise both mean the same
                // thing.
                send(.music(.toggle))
            }
            transportButton(symbol: "forward.fill", label: "Next") {
                send(.music(.next))
            }
        }
    }

    private func transportButton(
        symbol: String,
        label: LocalizedStringKey,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: isProminent ? 22 : 18, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, isProminent ? 14 : 12)
                .background(
                    isProminent ? Theme.Palette.periwinkle.opacity(0.18) : Theme.Palette.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isProminent ? Theme.Palette.periwinkle : Theme.Palette.text)
        .accessibilityLabel(Text(label))
    }

    private var volumeRow: some View {
        // Bound to what the Camera reported, so the hardware buttons on the
        // camera phone move this slider too.
        ThrottledSlider(
            value: state.music.volume ?? 0,
            leadingSymbol: "speaker.fill",
            trailingSymbol: "speaker.wave.3.fill",
            accessibilityLabel: Text("Music volume in the room")
        ) { level in
            send(.music(.setVolume(level)))
        }
    }

    private var playlistButton: some View {
        Button {
            // Asked for as the sheet opens, so a playlist created on the camera
            // phone today is there without restarting anything.
            send(.music(.refreshPlaylists))
            showPlaylists = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet")
                Text(currentPlaylistName ?? String(localized: "Choose a playlist"))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textFaint)
            }
            .font(Theme.Typography.callout)
            .foregroundStyle(Theme.Palette.text)
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(
                Theme.Palette.surfaceRaised,
                in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Choose a playlist"))
        .accessibilityValue(Text(currentPlaylistName ?? String(localized: "None")))
    }

    private var currentPlaylistName: String? {
        guard let id = state.music.playlistID else { return nil }
        return state.music.playlists
            .first { $0.playlistID == id && $0.provider == state.music.provider }?
            .name
    }

    // MARK: - Light

    private var lightCard: some View {
        KCCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    header(
                        symbol: state.light.isOn ? "lightbulb.fill" : "lightbulb",
                        title: "Light",
                        trailing: nil
                    )
                    Spacer(minLength: 8)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { state.light.isOn },
                            set: { send(.light(.setOn($0))) }
                        )
                    )
                    .labelsHidden()
                    .tint(Theme.Palette.periwinkle)
                    .disabled(!state.light.isControllable)
                    .accessibilityLabel(Text("Camera light"))
                }

                if let reason = lightUnavailableReason {
                    Text(reason)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ThrottledSlider(
                        value: state.light.level,
                        leadingSymbol: "sun.min",
                        trailingSymbol: "sun.max.fill",
                        accessibilityLabel: Text("Light brightness")
                    ) { level in
                        send(.light(.setLevel(level)))
                    }
                    .opacity(state.light.isOn ? 1 : 0.45)
                }
            }
        }
    }

    private var lightUnavailableReason: String? {
        switch state.light.availability {
        case .ready:
            return nil
        case .wrongCamera:
            return String(
                localized: "Only the back camera has a light. Flip the camera on the camera phone to use it."
            )
        case .cameraIdle:
            return String(localized: "The light comes on once the camera is streaming.")
        case .noHardware:
            return String(localized: "This camera phone has no light.")
        case .unavailable:
            return String(
                localized: "The camera phone has turned its light off, usually because it is too warm. It will come back on its own."
            )
        case .unknown:
            return String(localized: "This camera is running an older version of CribWire.")
        }
    }

    // MARK: - Shared

    private func header(
        symbol: String,
        title: LocalizedStringKey,
        trailing: String?
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Palette.periwinkle)
            Text(title)
                .font(Theme.Typography.callout.weight(.semibold))
                .foregroundStyle(Theme.Palette.text)
            if let trailing {
                Spacer(minLength: 8)
                Text(trailing)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textFaint)
            }
        }
    }
}

// MARK: - Throttled slider

/// A slider that reports while it is being dragged, but not on every frame.
///
/// Each report becomes a sealed message to the Camera, and a drag produces them
/// faster than any link should have to carry — so intermediate values are sent at
/// a fixed rate and the final value is always sent on release, which is the one
/// that has to be exact.
///
/// It is deliberately **not** bound to the Camera's value while dragging. A slider
/// that snapped back to the last reported state under the finger would be
/// unusable on any real link; it follows the finger, then follows the room again
/// as soon as the finger lifts.
struct ThrottledSlider: View {

    /// The value the Camera last reported.
    let value: Double
    let leadingSymbol: String
    let trailingSymbol: String
    let accessibilityLabel: Text
    let onChange: (Double) -> Void

    /// Roughly six updates a second: fast enough to feel continuous, slow enough
    /// that a drag costs a handful of messages rather than a hundred.
    private static let interval: TimeInterval = 0.16

    @State private var dragged: Double?
    @State private var lastSent = Date.distantPast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: leadingSymbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textFaint)
            Slider(
                value: Binding(
                    get: { dragged ?? value },
                    set: { newValue in
                        dragged = newValue
                        let now = Date()
                        guard now.timeIntervalSince(lastSent) >= Self.interval else { return }
                        lastSent = now
                        onChange(newValue)
                    }
                ),
                in: 0...1
            ) { isEditing in
                guard !isEditing else { return }
                // The value that matters. Sent unthrottled, then the slider is
                // handed back to the Camera's reports.
                if let dragged { onChange(dragged) }
                dragged = nil
            }
            .tint(Theme.Palette.periwinkle)
            Image(systemName: trailingSymbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.textFaint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Text("\(Int(((dragged ?? value) * 100).rounded())) percent"))
    }
}

// MARK: - Playlist picker

/// The playlist sheet: recently played on this camera, then favourites.
///
/// The Camera has already shortlisted these — see `PlaylistShortlist` — so this
/// view sorts nothing and filters nothing. What arrives is what is offered.
struct PlaylistPickerView: View {

    let music: MusicState
    let onSelect: (PlaylistSummary) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            KCScreen {
                ScrollView {
                    VStack(spacing: 8) {
                        if music.playlists.isEmpty {
                            emptyState
                        } else {
                            ForEach(music.playlists) { playlist in
                                row(for: playlist)
                            }
                        }
                    }
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 32))
                .foregroundStyle(Theme.Palette.textFaint)
            Text("No playlists yet")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Palette.text)
            Text("CribWire shows playlists you have played here, and the ones in your library on the camera phone.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 40)
    }

    private func row(for playlist: PlaylistSummary) -> some View {
        let isCurrent = playlist.playlistID == music.playlistID
            && playlist.provider == music.provider
        return Button {
            onSelect(playlist)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: playlist.isFavorite ? "heart.fill" : "clock")
                    .font(.system(size: 14))
                    .foregroundStyle(
                        playlist.isFavorite ? Theme.Palette.coral : Theme.Palette.textFaint
                    )
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(Theme.Typography.callout.weight(.semibold))
                        .foregroundStyle(Theme.Palette.text)
                        .lineLimit(1)
                    if let detail = subtitle(for: playlist) {
                        Text(detail)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.live)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Theme.Palette.surface,
                in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(playlist.name))
        .accessibilityHint(isCurrent ? Text("Currently playing") : Text("Play this playlist"))
    }

    /// "Played last night" beats a curator's name for something you are choosing
    /// in the dark, so the history wins where both exist.
    private func subtitle(for playlist: PlaylistSummary) -> String? {
        if let playedAt = playlist.lastPlayedAt {
            return String(
                localized: "Played \(playedAt.formatted(.relative(presentation: .named)))"
            )
        }
        return playlist.detail
    }
}
