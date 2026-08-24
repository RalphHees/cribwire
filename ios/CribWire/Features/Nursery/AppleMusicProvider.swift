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
    /// The same, for an album. Two properties rather than one existential
    /// because `player.queue` takes a concrete `PlayableMusicItem`, and exactly
    /// one of the two is ever set — `play(playlistID:)` clears the other.
    private var loadedAlbum: Album?

    var isPlaying: Bool {
        player.state.playbackStatus == .playing
    }

    /// Permission, and nothing else.
    ///
    /// Not the subscription: `ApplicationMusicPlayer` plays a downloaded or
    /// matched library without one, and even where it plays nothing, pausing and
    /// skipping a queue this app owns still works. The subscription decides what
    /// can be *started* from the catalogue, which is `availability`'s business.
    var canControlPlayback: Bool {
        MusicAuthorization.currentStatus == .authorized
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
        // Sequential rather than concurrent: they all hop to the main actor
        // anyway, so `async let` would buy nothing and cost the Sendable dance.
        let favorites = interleaved(await libraryPlaylists(), await libraryAlbums())
        let recent = await recentlyPlayed()
        return (favorites, recent)
    }

    /// Playlists and albums, alternating, so that neither kind crowds the other
    /// out of a shortlist that is a fraction of a real library.
    private func interleaved(
        _ playlists: [PlaylistSummary],
        _ albums: [PlaylistSummary]
    ) -> [PlaylistSummary] {
        var mixed: [PlaylistSummary] = []
        for index in 0 ..< max(playlists.count, albums.count) {
            if index < playlists.count { mixed.append(playlists[index]) }
            if index < albums.count { mixed.append(albums[index]) }
        }
        return mixed
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

    /// Albums in the user's library, the counterpart of `libraryPlaylists`.
    private func libraryAlbums() async -> [PlaylistSummary] {
        var request = MusicLibraryRequest<Album>()
        request.limit = PlaylistShortlist.limit * 2
        guard let response = try? await request.response() else { return [] }
        return response.items.map { summary(for: $0, isFavorite: true) }
    }

    /// Apple Music's own recently played — the playlists and the albums.
    ///
    /// The container request rather than `MusicRecentlyPlayedRequest<Playlist>`:
    /// `Playlist` is not `MusicRecentlyPlayedRequestable`, so the only route to a
    /// recently played playlist is the mixed container feed, sifted here. Albums
    /// arrive in the same feed and were being thrown away, which is why an album
    /// the parent had just been listening to on their own phone was nowhere on
    /// the Viewer's list. Stations still go: they are not playable through the
    /// same id, and half a feature in that list is worse than none.
    private func recentlyPlayed() async -> [PlaylistSummary] {
        var request = MusicRecentlyPlayedContainerRequest()
        // Asked for wider than the shortlist because stations share this feed,
        // and after sifting them out fewer entries are left than were asked for.
        request.limit = PlaylistShortlist.limit * 2
        guard let response = try? await request.response() else { return [] }
        return response.items.compactMap { item in
            switch item {
            case .playlist(let playlist): return summary(for: playlist, isFavorite: false)
            case .album(let album): return summary(for: album, isFavorite: false)
            default: return nil
            }
        }
    }

    private func summary(for playlist: Playlist, isFavorite: Bool) -> PlaylistSummary {
        PlaylistSummary(
            playlistID: playlist.id.rawValue,
            provider: .appleMusic,
            kind: .playlist,
            name: playlist.name,
            detail: playlist.curatorName,
            isFavorite: isFavorite
        )
    }

    private func summary(for album: Album, isFavorite: Bool) -> PlaylistSummary {
        PlaylistSummary(
            // Prefixed, so `play(playlistID:)` knows which catalogue to resolve
            // it in when the id comes back — from a Viewer, or out of the
            // Camera's own history long after this listing is gone.
            playlistID: MusicItemKind.album.wireID(for: album.id.rawValue),
            provider: .appleMusic,
            kind: .album,
            name: album.title,
            detail: album.artistName,
            isFavorite: isFavorite
        )
    }

    // MARK: - Transport

    @discardableResult
    func play(playlistID: String) async -> PlaylistPlaybackOutcome {
        let (kind, id) = MusicItemKind.read(playlistID)
        if kind == .album { return await playAlbum(id: id, wireID: playlistID) }

        // Neither request found it, in the library or the catalog. For a
        // MusicKit id that is as close to "deleted" as the framework says — and
        // unlike the TIDAL path, a request that merely failed throws rather than
        // answering empty, so this really is an absence.
        guard let playlist = await playlist(id: id) else { return .gone }

        loadedPlaylist = playlist
        loadedAlbum = nil
        currentPlaylistID = playlistID
        player.queue = [playlist]
        // Left in the parent's hands rather than forced: repeat-all is what a
        // sleep playlist usually wants, but overriding a mode the user set in the
        // Music app is not this app's business.
        guard (try? await player.play()) != nil else {
            // The playlist exists — it was just resolved — so a refusal here is
            // the account, the network or the subscription. Not grounds for
            // deleting the parent's history entry.
            currentPlaylistID = nil
            return .unavailable
        }
        return .playing(name: playlist.name, kind: .playlist)
    }

    /// The album path, which differs from the playlist one only in what it
    /// resolves and queues — and is kept separate for that reason: the two
    /// lookups have nothing in common but their shape.
    private func playAlbum(id: String, wireID: String) async -> PlaylistPlaybackOutcome {
        guard let album = await album(id: id) else { return .gone }

        loadedAlbum = album
        loadedPlaylist = nil
        currentPlaylistID = wireID
        player.queue = [album]
        guard (try? await player.play()) != nil else {
            currentPlaylistID = nil
            return .unavailable
        }
        return .playing(name: album.title, kind: .album)
    }

    /// Resolves an id to an album, library copy first — same reasoning as
    /// `playlist(id:)`, and the same two requests.
    private func album(id: String) async -> Album? {
        if let cached = loadedAlbum, cached.id.rawValue == id { return cached }

        let libraryRequest = MusicLibraryRequest<Album>()
        if let response = try? await libraryRequest.response(),
           let found = response.items.first(where: { $0.id.rawValue == id }) {
            return found
        }

        let catalogRequest = MusicCatalogResourceRequest<Album>(
            matching: \.id,
            equalTo: MusicItemID(id)
        )
        return try? await catalogRequest.response().items.first
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
        // Re-queuing whatever was last loaded is the only sensible reading of it.
        if player.queue.currentEntry == nil {
            if let playlist = loadedPlaylist {
                player.queue = [playlist]
            } else if let album = loadedAlbum {
                player.queue = [album]
            }
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
    var canControlPlayback: Bool { false }

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
    func play(playlistID: String) async -> PlaylistPlaybackOutcome { .unavailable }
    func play() async {}
    func pause() async {}
    func next() async {}
    func previous() async {}
    func stop() async {}

    #endif
}
