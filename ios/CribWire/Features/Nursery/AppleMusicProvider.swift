import CribWireKit
import Foundation

#if canImport(MusicKit)
import MusicKit
#endif

/// Apple Music, driven through MusicKit's `ApplicationMusicPlayer`.
///
/// `ApplicationMusicPlayer` rather than `SystemMusicPlayer` on purpose. The system
/// player *is* the Music app: taking it over would stop whatever the parent was
/// listening to elsewhere, and — worse for a monitor — a Viewer pressing pause
/// would pause the Music app on the Camera's own account, which the parent would
/// then find still paused in the morning. The application player keeps a queue
/// that belongs to CribWire and dies with it.
///
/// **What this provider cannot do, and why it does not pretend to:** MusicKit
/// exposes no per-app volume. Volume in this feature therefore means the Camera
/// device's *output* volume, which is handled outside this type by
/// `SystemVolumeController`. For a phone on a shelf playing lullabies into a room,
/// that is the volume anyone actually means.
@MainActor
final class AppleMusicProvider: MusicProvider {

    let kind: MusicProviderKind = .appleMusic

    /// MusicKit needs no credentials of its own — only the MusicKit service
    /// enabled on the App ID and `NSAppleMusicUsageDescription` in Info.plist,
    /// both of which ship with the build.
    var isConfigured: Bool {
        #if canImport(MusicKit)
        return true
        #else
        return false
        #endif
    }

    private(set) var currentPlaylistID: String?

    #if canImport(MusicKit)

    private var player: ApplicationMusicPlayer { .shared }
    /// Cached so a playlist can be re-queued (previous/next past the ends, a
    /// restart after `stop`) without another network round trip.
    private var loadedPlaylist: Playlist?

    var isPlaying: Bool {
        player.state.playbackStatus == .playing
    }

    var nowPlaying: (title: String?, artist: String?) {
        guard let entry = player.queue.currentEntry else { return (nil, nil) }
        return (entry.title, entry.subtitle)
    }

    // MARK: - Authorisation

    func availability() async -> MusicState.Availability {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            return await subscriptionAvailability()
        case .notDetermined, .denied, .restricted:
            // One answer for all three, because from the Viewer's side they are
            // one situation: the fix is on the Camera phone, not here. Which of
            // them it is decides only whether the Camera's own screen offers a
            // prompt or the Settings app, and that is decided there.
            return .needsPermission
        @unknown default:
            return .unknown
        }
    }

    @discardableResult
    func requestAuthorization() async -> MusicState.Availability {
        guard MusicAuthorization.currentStatus == .notDetermined else {
            return await availability()
        }
        _ = await MusicAuthorization.request()
        return await availability()
    }

    /// Authorised is not the same as able to play: a lapsed subscription
    /// authorises fine and then plays nothing.
    private func subscriptionAvailability() async -> MusicState.Availability {
        do {
            let subscription = try await MusicSubscription.current
            return subscription.canPlayCatalogContent ? .ready : .needsSubscription
        } catch {
            // Offline, most likely. The library may still be playable, so this is
            // reported as a temporary "not now" rather than as a missing
            // subscription the parent would go and try to buy.
            return .unavailable
        }
    }

    // MARK: - Playlists

    func loadPlaylists() async -> (
        favorites: [PlaylistSummary],
        recentlyPlayed: [PlaylistSummary]
    ) {
        // Sequential rather than concurrent: both hop to the main actor anyway,
        // so `async let` would buy nothing and cost the Sendable dance.
        let favorites = await libraryPlaylists()
        let recent = await recentlyPlayedPlaylists()
        return (favorites, recent)
    }

    /// Playlists in the user's library — the practical meaning of "favourites"
    /// for Apple Music, which has no separate starred list for playlists.
    private func libraryPlaylists() async -> [PlaylistSummary] {
        var request = MusicLibraryRequest<Playlist>()
        // Asked for a little wider than the shortlist so that after merging and
        // deduplicating against the recents there is still something to fill it.
        request.limit = PlaylistShortlist.limit * 2
        guard let response = try? await request.response() else { return [] }
        return response.items.map { summary(for: $0, isFavorite: true) }
    }

    /// Apple Music's own recently played, filtered to playlists.
    ///
    /// The container request rather than `MusicRecentlyPlayedRequest<Playlist>`:
    /// `Playlist` is not `MusicRecentlyPlayedRequestable`, so the only route to a
    /// recently played playlist is the mixed container feed, sifted here.
    private func recentlyPlayedPlaylists() async -> [PlaylistSummary] {
        var request = MusicRecentlyPlayedContainerRequest()
        // Asked for wider than the shortlist because albums and stations share
        // this feed, and after sifting them out only a handful may be playlists.
        request.limit = PlaylistShortlist.limit * 2
        guard let response = try? await request.response() else { return [] }
        return response.items.compactMap { item in
            guard case .playlist(let playlist) = item else { return nil }
            return summary(for: playlist, isFavorite: false)
        }
    }

    private func summary(for playlist: Playlist, isFavorite: Bool) -> PlaylistSummary {
        PlaylistSummary(
            playlistID: playlist.id.rawValue,
            provider: .appleMusic,
            name: playlist.name,
            detail: playlist.curatorName,
            isFavorite: isFavorite
        )
    }

    // MARK: - Transport

    @discardableResult
    func play(playlistID: String) async -> String? {
        guard let playlist = await playlist(id: playlistID) else { return nil }

        loadedPlaylist = playlist
        currentPlaylistID = playlistID
        player.queue = [playlist]
        // Left in the parent's hands rather than forced: repeat-all is what a
        // sleep playlist usually wants, but overriding a mode the user set in the
        // Music app is not this app's business.
        guard (try? await player.play()) != nil else {
            currentPlaylistID = nil
            return nil
        }
        return playlist.name
    }

    /// Resolves an id to a playlist, preferring the library copy.
    ///
    /// A library playlist and its catalog original have different ids, and only
    /// the library one can be played when the account is offline, so the library
    /// is asked first and the catalog is the fallback.
    private func playlist(id: String) async -> Playlist? {
        if let cached = loadedPlaylist, cached.id.rawValue == id { return cached }

        // Matched in memory rather than with a library filter predicate. A
        // library holds tens of playlists, not thousands, and the shortlist this
        // id came from was built from the same request a moment ago.
        let libraryRequest = MusicLibraryRequest<Playlist>()
        if let response = try? await libraryRequest.response(),
           let found = response.items.first(where: { $0.id.rawValue == id }) {
            return found
        }

        let catalogRequest = MusicCatalogResourceRequest<Playlist>(
            matching: \.id,
            equalTo: MusicItemID(id)
        )
        return try? await catalogRequest.response().items.first
    }

    func play() async {
        // Nothing queued yet — a Viewer pressing play before choosing anything.
        // Re-queuing the last playlist is the only sensible reading of it.
        if player.queue.currentEntry == nil, let playlist = loadedPlaylist {
            player.queue = [playlist]
        }
        try? await player.play()
    }

    func pause() async {
        player.pause()
    }

    func next() async {
        try? await player.skipToNextEntry()
    }

    func previous() async {
        // MusicKit's own behaviour: past the first entry this rewinds rather than
        // failing, which matches what the button means.
        try? await player.skipToPreviousEntry()
    }

    func stop() async {
        player.stop()
        currentPlaylistID = nil
    }

    #else

    // MusicKit is unavailable in this SDK. The provider still exists so the rest
    // of the app compiles and reports honestly, rather than being conditionally
    // absent and taking every call site with it.

    var isPlaying: Bool { false }
    var nowPlaying: (title: String?, artist: String?) { (nil, nil) }

    func availability() async -> MusicState.Availability { .notConfigured }

    @discardableResult
    func requestAuthorization() async -> MusicState.Availability { .notConfigured }

    func loadPlaylists() async -> (
        favorites: [PlaylistSummary],
        recentlyPlayed: [PlaylistSummary]
    ) {
        ([], [])
    }

    @discardableResult
    func play(playlistID: String) async -> String? { nil }
    func play() async {}
    func pause() async {}
    func next() async {}
    func previous() async {}
    func stop() async {}

    #endif
}
