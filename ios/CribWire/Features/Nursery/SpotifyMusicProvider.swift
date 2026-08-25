import CribWireKit
import Foundation

/// Spotify, driven through the Spotify app on the same phone.
///
/// ## What differs from the other two, and why
///
/// **CribWire does not play the audio.** Spotify permits no third-party app to
/// play its catalogue; App Remote drives the Spotify app, which plays it. So this
/// provider is a remote control, and the three consequences are visible
/// throughout the file: the Spotify app must be installed, Premium is required
/// (App Remote refuses to play for a free account), and `stop()` can only mean
/// pause — ending someone else's playback session is not ours to do.
///
/// **The subscription answer arrives early**, which is the opposite of TIDAL.
/// `GET /me` reports `product` before a note is played, so a parent with a free
/// account is told they need Premium instead of finding out from a room that
/// stayed silent.
///
/// **Now-playing is pushed, not polled.** The Spotify app reports every track
/// change over the App Remote subscription (`SpotifySession.playerState`), so
/// unlike the other two this provider never has to ask what is playing — it only
/// has to read what it was last told.
@MainActor
final class SpotifyMusicProvider: MusicProvider, SpotifyPlaybackDelegate {

    let kind: MusicProviderKind = .spotify

    /// Offered only where a client id has been configured, exactly like TIDAL: a
    /// build with no id could not get as far as a login screen, so it does not
    /// appear on the Camera's account list at all rather than appearing as
    /// something permanently broken.
    var isConfigured: Bool { configuration != nil }

    /// Resolved on each read rather than captured once — the id can arrive from
    /// `GET /v1/config` after this object exists.
    private let resolve: @MainActor () -> SpotifyConfiguration?

    private var configuration: SpotifyConfiguration? { resolve() }

    private let session: SpotifySession

    init(
        resolve: @escaping @MainActor () -> SpotifyConfiguration? = { .current },
        session: SpotifySession = .shared
    ) {
        self.resolve = resolve
        self.session = session
        session.delegate = self
    }

    /// A fixed configuration, for tests and previews.
    convenience init(configuration: SpotifyConfiguration?) {
        self.init(resolve: { configuration })
    }

    // MARK: - State

    /// The last playlist a Viewer started through CribWire.
    ///
    /// Kept as well as read from the Spotify app's own context because the two
    /// answer different questions at different times: the app's context is the
    /// truth once it is playing, and this is what was asked for in the seconds
    /// before Spotify has said anything back.
    private var startedPlaylistID: String?

    /// Sticky, like TIDAL's `hasFailed`: set when the Spotify app refuses the
    /// connection, cleared the moment one is established. Without it a Camera
    /// whose parent has deleted the Spotify app would report itself ready
    /// forever, since nothing else on this path ever fails out loud.
    private var hasFailedToConnect = false

    /// Whether the account can play at all, once asked. `nil` until the first
    /// answer, so "we have not checked" is never mistaken for "not Premium".
    private var isPremium: Bool?

    // MARK: - Connection

    var isConnected: Bool {
        guard let configuration else { return false }
        session.configure(configuration)
        return session.isSignedIn
    }

    func availability() async -> MusicState.Availability {
        guard let configuration else { return .notConfigured }
        session.configure(configuration)

        guard session.isSignedIn else {
            // The same answer as an unauthorised Apple Music and a signed-out
            // TIDAL, and for the same reason: the fix is a person standing at
            // the Camera. Which service it is decides only what the Camera's own
            // screen offers, and that is decided there.
            return .needsPermission
        }
        // A signed-in account with no Spotify app to drive is the one failure
        // here that is neither a permission nor a subscription. It reads as
        // "cannot reach Spotify right now" on the Viewer, which is exactly true,
        // and the Camera's account list is where it is named properly.
        guard session.isSpotifyAppInstalled else { return .unavailable }

        guard let token = await session.accessToken(configuration: configuration) else {
            // Signed in, but the token could not be refreshed: offline, or a
            // grant the parent revoked from Spotify's website. Temporary as far
            // as this Camera can tell, so it is not reported as a sign-out that
            // would take the account off the Viewer's switcher.
            return .unavailable
        }

        // Asked once and remembered. `product` changes when somebody buys or
        // cancels a subscription, which is not a thing to spend a request on
        // every five seconds — and a re-connect re-asks it anyway.
        if isPremium == nil {
            isPremium = await SpotifyCatalog.isPremium(token: token)
        }
        if isPremium == false { return .needsSubscription }

        // Reconnect attempts live here rather than on a timer of their own: this
        // runs on the Camera's refresh tick, which only ticks while a Viewer is
        // actually watching. A Camera nobody is connected to does not spend
        // battery poking at another app.
        session.connectIfPossible()

        if hasFailedToConnect && !session.isConnected { return .unavailable }
        return .ready
    }

    /// True whenever there is an account and an app to drive with it.
    ///
    /// Deliberately not `session.isConnected`. The App Remote link is dropped
    /// whenever the Spotify app is killed or backgrounded long enough, and it is
    /// re-established by the very next command — so gating the transport row on
    /// a live socket would take the pause button away from a parent at exactly
    /// the moment the room is playing something they want stopped.
    var canControlPlayback: Bool {
        guard let configuration else { return false }
        session.configure(configuration)
        return session.isSignedIn && session.isSpotifyAppInstalled
    }

    @discardableResult
    func requestAuthorization() async -> MusicState.Availability {
        guard let configuration else { return .notConfigured }
        session.configure(configuration)

        guard !session.isSignedIn else { return await availability() }
        _ = await session.signIn(configuration: configuration)
        // Facts about whoever was signed in before, cleared for whoever just
        // signed in. Signing in again is what a parent reaches for when Spotify
        // has gone wrong on this Camera, and it has to be able to actually fix
        // it rather than inheriting the last account's verdict.
        isPremium = nil
        hasFailedToConnect = false
        return await availability()
    }

    func signOut() async {
        await stop()
        await session.signOut()
        startedPlaylistID = nil
        isPremium = nil
        hasFailedToConnect = false
    }

    // MARK: - Playlists

    func loadPlaylists() async -> (
        favorites: [PlaylistSummary],
        recentlyPlayed: [PlaylistSummary]
    ) {
        guard let configuration else { return ([], []) }
        session.configure(configuration)
        guard let token = await session.accessToken(configuration: configuration) else {
            return ([], [])
        }

        // Asked for a little wider than the shortlist so that after merging and
        // deduplicating against the Camera's own recents there is still
        // something to fill it.
        async let playlists = SpotifyCatalog.playlists(
            token: token,
            limit: PlaylistShortlist.limit * 2
        )
        async let albums = SpotifyCatalog.albums(
            token: token,
            limit: PlaylistShortlist.limit * 2
        )
        let favorites = Self.interleaved(await playlists, await albums)

        // No recently played, for the same reason as TIDAL: Spotify's history
        // endpoint reports *tracks*, not the playlist they came from, and
        // inventing a history from it would duplicate what `MusicRecentsStore`
        // already contributes — which is the better record anyway, being what
        // was played in this room rather than on the account.
        return (favorites, [])
    }

    /// Playlists and albums, alternating.
    ///
    /// The same rule as `TidalMusicProvider`: a parent with forty saved albums
    /// and three playlists should still see their three playlists, which
    /// concatenation would push off the end of a shortlist.
    private static func interleaved(
        _ playlists: [PlaylistSummary],
        _ albums: [PlaylistSummary]
    ) -> [PlaylistSummary] {
        var merged: [PlaylistSummary] = []
        merged.reserveCapacity(playlists.count + albums.count)
        for index in 0..<max(playlists.count, albums.count) {
            if index < playlists.count { merged.append(playlists[index]) }
            if index < albums.count { merged.append(albums[index]) }
        }
        return merged
    }

    // MARK: - Playback

    @discardableResult
    func play(playlistID: String) async -> PlaylistPlaybackOutcome {
        guard let configuration else { return .unavailable }
        session.configure(configuration)
        guard session.isSignedIn, session.isSpotifyAppInstalled else { return .unavailable }

        let (kind, id) = MusicItemKind.read(playlistID)

        // The name is resolved *before* playing, because it is the only step
        // that can tell a deleted playlist from an unreachable one — and the
        // difference decides whether `NurseryController` drops this entry from
        // the parent's history. Playing first would mean answering `.gone` for a
        // playlist that is merely behind a dead Wi-Fi link.
        let lookup: SpotifyCatalog.NameLookup
        if let token = await session.accessToken(configuration: configuration) {
            lookup = await SpotifyCatalog.name(for: id, kind: kind, token: token)
        } else {
            lookup = .unknown
        }
        if lookup == .gone { return .gone }

        guard await session.play(uri: Self.uri(for: id, kind: kind)) else {
            // The Spotify app is not installed — the only thing
            // `authorizeAndPlayURI` reports, and not evidence about the playlist.
            return .unavailable
        }
        startedPlaylistID = playlistID

        switch lookup {
        case .named(let name):
            return .playing(name: name, kind: kind)
        case .unknown:
            // Playing something that could not be named. The history entry has
            // to be recorded under *some* name or it cannot be offered again, so
            // it falls back to what the Viewer already had on screen when it
            // tapped — which is the name this id was listed under.
            return .playing(name: String(localized: "Spotify"), kind: kind)
        case .gone:
            return .gone
        }
    }

    private static func uri(for id: String, kind: MusicItemKind) -> String {
        switch kind {
        case .playlist: return "spotify:playlist:\(id)"
        case .album: return "spotify:album:\(id)"
        }
    }

    func play() async {
        session.connectIfPossible()
        session.resume()
    }

    func pause() async {
        session.connectIfPossible()
        session.pause()
    }

    func next() async {
        session.connectIfPossible()
        session.next()
    }

    func previous() async {
        session.connectIfPossible()
        session.previous()
    }

    /// Pauses, and forgets what CribWire started.
    ///
    /// Not a stop: the queue belongs to the Spotify app and outlives this
    /// connection by design. Tearing it down would also end whatever the parent
    /// was playing on that phone before CribWire ever ran, which is precisely
    /// the mistake `AppleMusicProvider` avoids by refusing to use the system
    /// player.
    func stop() async {
        session.pause()
        session.disconnect()
        startedPlaylistID = nil
    }

    // MARK: - Now playing

    var isPlaying: Bool { session.playerState?.isPlaying ?? false }

    var nowPlaying: (title: String?, artist: String?) {
        guard let state = session.playerState else { return (nil, nil) }
        return (state.title, state.artist)
    }

    /// What the Viewer ticks in the picker.
    ///
    /// The Spotify app's own context wins when it has one: a parent who changed
    /// the playlist in Spotify itself should see *that* ticked, not the one
    /// CribWire last started. What we started is the fallback for the seconds
    /// before the app has reported anything back.
    var currentPlaylistID: String? {
        if let context = session.playerState?.contextURI,
           let id = Self.wireID(fromURI: context) {
            return id
        }
        return startedPlaylistID
    }

    /// `spotify:playlist:37i9…` back into the id CribWire puts on the wire.
    ///
    /// Anything that is neither a playlist nor an album — a track a parent
    /// started by hand, an artist radio — answers `nil`, which ticks nothing.
    /// That is the honest answer: none of the rows in the picker is what is
    /// playing.
    /// `nonisolated` because it is pure string work that touches nothing on this
    /// object — which is also what makes it assertable without a Spotify app.
    nonisolated static func wireID(fromURI uri: String) -> String? {
        let parts = uri.split(separator: ":").map(String.init)
        guard parts.count >= 3, parts[0] == "spotify" else { return nil }
        switch parts[1] {
        case "playlist": return MusicItemKind.playlist.wireID(for: parts[2])
        case "album": return MusicItemKind.album.wireID(for: parts[2])
        default: return nil
        }
    }

    // MARK: - SpotifyPlaybackDelegate

    func spotifyConnectionChanged(isConnected: Bool) {
        hasFailedToConnect = !isConnected
    }

    func spotifyPlayerStateChanged(_ state: SpotifyPlayerState) {
        // The state itself lives on the session — this provider reads it there
        // rather than keeping a second copy that could disagree. What a report
        // proves is that the link is alive, which is worth recording because it
        // is the only positive signal on this path.
        hasFailedToConnect = false
    }
}

/// Spotify credentials — id only, and only ever the id.
///
/// The whole argument on `TidalConfiguration` applies here word for word: there
/// is no client secret in this app and there must never be one. The flow
/// `SpotifySession.signIn` runs is authorization code + PKCE, a public-client
/// flow with no secret in it, which is exactly what Spotify documents for a
/// mobile app.
///
/// The id comes from two places, in order:
///
/// 1. **The backend**, via `GET /v1/config`, cached in `RemoteConfigurationStore`
///    — which makes rotating one a configuration change rather than a release.
/// 2. **Info.plist**, set per configuration in `project.yml`. The floor: what a
///    build works with before it has ever reached a backend, and what a
///    local-network-only pairing uses, since that path never calls a server.
struct SpotifyConfiguration: Equatable {

    static let clientIDKey = "CribWireSpotifyClientID"
    static let redirectURIKey = "CribWireSpotifyRedirectURI"

    /// The redirect a build has unless it says otherwise, matching the URL
    /// scheme `project.yml` registers.
    ///
    /// It has to be listed on the application at `developer.spotify.com` as
    /// well — Spotify rejects an authorize request whose redirect it does not
    /// recognise — which is why it is overridable: a deployment that registered
    /// something else sets `CribWireSpotifyRedirectURI` and adds its scheme
    /// alongside this one.
    ///
    /// Note that this redirect does double duty, which TIDAL's does not: it is
    /// both the OAuth callback and the URL the *Spotify app* returns the App
    /// Remote hand-off on. The second one is a real app-open, which is why
    /// `AppDelegate` forwards it — see `SpotifySession.handleCallback`.
    static let defaultRedirectURI = "cribwire://spotify-auth"

    let clientID: String
    var redirectURI: String = defaultRedirectURI

    /// `nil` when neither source has an id, which is what makes an unconfigured
    /// deployment hide Spotify rather than offer it.
    static var current: SpotifyConfiguration? {
        make(remote: RemoteConfigurationStore().load(), bundle: .main)
    }

    /// The precedence rule itself, split out so it can be asserted without
    /// standing up a bundle or writing to the shared defaults.
    ///
    /// Only the *id* has two sources. The redirect is a property of the build —
    /// its URL scheme has to be in the shipped Info.plist for iOS to route the
    /// callback at all — so it is read from the bundle whichever source the id
    /// came from.
    static func make(remote: RemoteConfiguration, bundle: Bundle) -> SpotifyConfiguration? {
        guard var resolved = make(remote: remote) ?? make(rawClientID: clientID(in: bundle))
        else { return nil }
        resolved.redirectURI = redirectURI(in: bundle)
        return resolved
    }

    static func make(remote: RemoteConfiguration) -> SpotifyConfiguration? {
        make(rawClientID: remote.spotifyClientID)
    }

    static func make(bundle: Bundle) -> SpotifyConfiguration? {
        guard var resolved = make(rawClientID: clientID(in: bundle)) else { return nil }
        resolved.redirectURI = redirectURI(in: bundle)
        return resolved
    }

    static func make(rawClientID raw: String?) -> SpotifyConfiguration? {
        guard let clientID = configured(raw) else { return nil }
        return SpotifyConfiguration(clientID: clientID)
    }

    private static func clientID(in bundle: Bundle) -> String? {
        bundle.object(forInfoDictionaryKey: clientIDKey) as? String
    }

    /// A redirect the build cannot actually receive is worse than the default,
    /// so an unset, blank or scheme-less value falls back rather than being
    /// passed to Spotify to be rejected.
    static func redirectURI(in bundle: Bundle) -> String {
        guard let raw = configured(bundle.object(forInfoDictionaryKey: redirectURIKey) as? String),
              URL(string: raw)?.scheme?.isEmpty == false
        else { return defaultRedirectURI }
        return raw
    }

    /// Trimmed, and `nil` where the value says nothing. XcodeGen leaves the
    /// literal `$(CRIBWIRE_SPOTIFY_CLIENT_ID)` in place when the build setting is
    /// undefined, so an unsubstituted placeholder counts as "not configured" too.
    private static func configured(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
