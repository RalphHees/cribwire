import CribWireKit
import Foundation
import OSLog
import Player

/// TIDAL, driven through TIDAL's own SDK.
///
/// TIDAL does not permit a third-party app to play its catalogue by any route
/// except `github.com/tidal-music/tidal-sdk-ios`, so all four of its modules are
/// here: `Auth` signs the parent in and refreshes the token, `TidalAPI` lists
/// their playlists, `Player` plays them, and `EventProducer` carries the
/// playback reporting the other two require. What that SDK needs in return is a
/// client id issued per application at `developer.tidal.com` — which is why this
/// provider is offered only where one has been configured, either by the backend
/// through `GET /v1/config` or compiled in (see `TidalConfiguration`).
///
/// ## What differs from Apple Music, and why
///
/// **There is no playlist object to hand a player.** MusicKit takes a `Playlist`
/// and owns the queue; TIDAL's `Player` takes one `MediaProduct` at a time and a
/// single `setNext`. So the queue is this type's, built from the playlist's
/// tracks, and every transition is answered by queuing the one after it.
///
/// **It repeats, where Apple Music does not.** `AppleMusicProvider` deliberately
/// leaves the repeat mode to whatever the parent set in the Music app. TIDAL has
/// no such setting to inherit, so the choice has to be made here, and for a
/// nursery it is not a close one: a sleep playlist that runs out at 2 a.m. and
/// leaves a silent room is a worse outcome than one that plays on. The queue
/// wraps.
///
/// **The subscription answer arrives late.** MusicKit answers
/// `MusicSubscription.canPlayCatalogContent` before a note is played. TIDAL says
/// nothing about the account until playback starts and then reports, through
/// `PlaybackContext.previewReason`, that what is playing is a thirty-second
/// preview. So `availability()` reads `.ready` for a signed-in parent until the
/// first track proves otherwise, at which point it becomes `.needsSubscription`
/// and stays there. Reporting `.needsSubscription` up front would be a guess,
/// and it would be wrong for every subscriber.
///
/// Everything else the Viewer sees is identical, because `NurseryController`
/// treats every provider through the same small protocol and knows the name of
/// neither service.
@MainActor
final class TidalMusicProvider: MusicProvider {

    let kind: MusicProviderKind = .tidal

    /// Why a play attempt came to nothing.
    ///
    /// Everything on this path is non-throwing by design — `TidalCatalog` turns
    /// every failure into an empty answer so that a music service can never fail
    /// a baby monitor — and the cost of that is a silence with five possible
    /// causes: no client id, signed out, no player, no tracks, a playlist that is
    /// really gone. None of them is visible from the Viewer, which is a phone in
    /// another room. This log is the only place the difference survives, so it
    /// names the cause rather than reporting that something went wrong.
    static let log = Logger(subsystem: "com.ralphhees.cribwire", category: "tidal")

    /// How many tracks of a playlist are ever queued.
    ///
    /// Twelve hours of music at a generous three minutes a track — longer than
    /// any night — for one bounded walk of the items endpoint. A playlist longer
    /// than this plays its first two hundred and then wraps, which nobody in a
    /// dark room will ever notice, and the alternative is an unbounded number of
    /// requests on a phone that is also carrying a video stream.
    private static let queueLimit = 200

    /// Offered only where a client id has been configured. Unlike Apple Music,
    /// which needs nothing but the entitlement that ships with the build, a
    /// TIDAL build with no id cannot get so far as a login screen — so it is not
    /// shown in the Viewer's switcher at all, rather than shown as permanently
    /// broken.
    var isConfigured: Bool { configuration != nil }

    /// Resolved on each read rather than captured once.
    ///
    /// The id can arrive from the backend after this object exists — a Camera
    /// builds its providers at launch and hears from `/v1/config` moments later
    /// — so a snapshot taken in `init` would mean a newly configured deployment
    /// did nothing until the app was next restarted.
    private let resolve: @MainActor () -> TidalConfiguration?

    private var configuration: TidalConfiguration? { resolve() }

    private let session: TidalSession

    init(
        resolve: @escaping @MainActor () -> TidalConfiguration? = { .current },
        session: TidalSession = .shared
    ) {
        self.resolve = resolve
        self.session = session
    }

    /// A fixed configuration, for tests and previews.
    convenience init(configuration: TidalConfiguration?) {
        self.init(resolve: { configuration })
    }

    // MARK: - Queue

    /// The playlist a Viewer chose, flattened into the only thing `Player` will
    /// accept: one track after another.
    private var queue: [TidalTrack] = []
    private var index = 0
    private(set) var currentPlaylistID: String?

    /// Track titles and artist names, filled in one track at a time as playback
    /// reaches them — see `TidalCatalog.metadata(forTrack:)` for why they are not
    /// fetched with the queue. Cleared with the queue, so they never outgrow it.
    ///
    /// Titles are in here as well as on `TidalTrack` because the playlist's own
    /// items response may arrive without them: the ids are promised, the
    /// sideloaded attributes are not. A queue is built from what is promised and
    /// the titles catch up.
    private var artists: [String: String] = [:]
    private var titles: [String: String] = [:]

    /// Playlist names seen while listing, bounded by the shortlist that produced
    /// them. Only ever read as a fallback in `play(playlistID:)`.
    private var names: [String: String] = [:]

    /// Sticky once seen, because it is a fact about the account rather than
    /// about the track: TIDAL only ever mentions it while something is playing,
    /// and forgetting it on pause would make the Viewer's answer flicker.
    private var isPreviewOnly = false

    /// Set when `Player` reports a failure, cleared by the next track that
    /// actually starts. This is the only way a session revoked on another device
    /// becomes visible without asking the network on every refresh tick.
    private var hasFailed = false

    // MARK: - Authorisation

    func availability() async -> MusicState.Availability {
        guard let configuration else { return .notConfigured }
        session.configure(configuration)

        guard session.isSignedIn else {
            // The same answer as an unauthorised Apple Music, and for the same
            // reason: the fix is a person standing at the Camera, not anything
            // the Viewer can do. Which of the two services it is decides only
            // what the Camera's own screen offers, and that is decided there.
            return .needsPermission
        }
        if isPreviewOnly { return .needsSubscription }
        if hasFailed { return .unavailable }
        return .ready
    }

    @discardableResult
    func requestAuthorization() async -> MusicState.Availability {
        guard let configuration else { return .notConfigured }
        session.configure(configuration)

        guard !session.isSignedIn else { return await availability() }
        _ = await session.signIn(redirectURI: configuration.redirectURI)
        return await availability()
    }

    // MARK: - Playlists

    func loadPlaylists() async -> (
        favorites: [PlaylistSummary],
        recentlyPlayed: [PlaylistSummary]
    ) {
        guard let configuration else { return ([], []) }
        session.configure(configuration)
        guard let userID = await session.userID() else { return ([], []) }

        // Asked for a little wider than the shortlist so that after merging and
        // deduplicating against the Camera's own recents there is still
        // something to fill it.
        async let playlists = TidalCatalog.collectionPlaylists(
            userID: userID,
            limit: PlaylistShortlist.limit * 2
        )
        async let albums = TidalCatalog.collectionAlbums(
            userID: userID,
            limit: PlaylistShortlist.limit * 2
        )
        let favorites = await interleaved(playlists, albums)
        // Kept so that a playlist can be named even when the name request in
        // `play(playlistID:)` is the one call that fails — see there for why
        // returning no name at all would quietly delete the parent's history
        // entry for it.
        for playlist in favorites {
            names[playlist.playlistID] = playlist.name
        }

        // No recently played. TIDAL's Open API exposes no play history at the
        // access tier a third-party client holds, and inventing one from this
        // Camera's own history would duplicate what `MusicRecentsStore` already
        // contributes to the shortlist — which is the better record anyway,
        // being what was played *in this room* rather than on the account.
        return (favorites, [])
    }

    /// Playlists and albums, alternating.
    ///
    /// Neither kind may crowd the other out of a shortlist that is a fraction of
    /// a real collection: a parent with sixty saved albums would otherwise never
    /// see a playlist, and one with sixty playlists would never see the album
    /// they put on last week. The Camera's own history is merged in above this
    /// and is unaffected by the order chosen here.
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

    // MARK: - Transport

    var isPlaying: Bool {
        session.existingPlayer?.getState() == .PLAYING
    }

    var nowPlaying: (title: String?, artist: String?) {
        guard queue.indices.contains(index) else { return (nil, nil) }
        let track = queue[index]
        // The playlist's own title where it arrived with one, otherwise whatever
        // the per-track fetch has since resolved. Both may be missing for the
        // first moment of a track, which the Viewer renders as "Nothing playing"
        // — a beat of that is better than showing a raw TIDAL id.
        return (track.title ?? titles[track.id], artists[track.id])
    }

    /// Whether the transport buttons reach a player.
    ///
    /// True only once something of ours is queued, and deliberately so. This
    /// provider's player holds nothing but what CribWire put in it — there is no
    /// equivalent of a lapsed Apple Music account still playing a downloaded
    /// library — so before a playlist is chosen there is genuinely nothing for a
    /// pause to reach. Reporting that honestly is what lets `NurseryController`
    /// send the buttons to the Music app instead, which on a Camera playing
    /// something the parent started themselves is what the tap meant.
    var canControlPlayback: Bool {
        session.existingPlayer != nil && !queue.isEmpty
    }

    @discardableResult
    func play(playlistID: String) async -> PlaylistPlaybackOutcome {
        guard let configuration else {
            Self.log.error("play refused: no TIDAL client id is configured")
            return .unavailable
        }
        session.configure(configuration)
        guard session.isSignedIn else {
            Self.log.error("play refused: this camera is not signed in to TIDAL")
            return .unavailable
        }
        guard let player = session.player() else {
            // `Player.bootstrap` answers nil when it has already been called or
            // when its offline store would not open. Neither is recoverable by
            // retrying, and neither says anything about the playlist.
            Self.log.error("play refused: the TIDAL player could not be built")
            return .unavailable
        }

        // What the id refers to, and the service's own id inside it. A Viewer
        // sends back whatever the shortlist gave it, and so does the Camera's
        // own history months later — so this is the only place that knows
        // whether the next two requests are about an album or a playlist.
        let (kind, id) = MusicItemKind.read(playlistID)

        // Both round trips at once: the tracks are what is played and the name
        // is what the Camera's recents record, and neither needs the other.
        async let tracks = TidalCatalog.tracks(in: kind, id: id, limit: Self.queueLimit)
        async let name = kind == .album
            ? TidalCatalog.albumName(id: id)
            : TidalCatalog.playlistName(id: id)

        guard let loaded = await tracks else {
            // The request itself failed. Nothing has been established about the
            // playlist, so the parent's history entry stays.
            Self.log.error(
                "play failed: could not read \(playlistID, privacy: .public)"
            )
            return .unavailable
        }
        guard !loaded.isEmpty else {
            // The service answered, and the answer was "no items". That is a
            // playlist emptied or deleted, and the only case that may drop the
            // history entry.
            Self.log.error(
                "play failed: \(playlistID, privacy: .public) has no playable tracks"
            )
            return .gone
        }

        // Claimed only now that there is something to play, so a failed load
        // leaves whatever was playing before it alone.
        session.delegate = self
        queue = loaded
        artists = [:]
        titles = [:]
        index = 0
        currentPlaylistID = playlistID
        hasFailed = false

        load(at: 0, on: player)
        player.play()

        Self.log.info(
            "playing \(loaded.count, privacy: .public) tracks from \(playlistID, privacy: .public)"
        )

        // The tracks loaded and the player was told to play, so this is
        // `.playing` whatever the name request did. A name that merely timed out
        // falls back to the shortlist's copy, and the id stands in for that —
        // ugly, but only reachable when a playlist plays without ever having been
        // listed.
        if let fetched = await name {
            names[playlistID] = fetched
            return .playing(name: fetched, kind: kind)
        }
        return .playing(name: names[playlistID] ?? playlistID, kind: kind)
    }

    func play() async {
        // The existing player, never a new one: choosing a playlist is the only
        // act that is allowed to stand up a database and an offline store, and a
        // bare play with nothing queued has nothing to play anyway.
        guard let player = session.existingPlayer else { return }
        // Nothing loaded — a Viewer pressing play after the player was reset
        // under it. Re-queuing what we still have is the only sensible reading
        // of it.
        if player.getActiveMediaProduct() == nil, !queue.isEmpty {
            load(at: index, on: player)
        }
        player.play()
    }

    func pause() async {
        session.existingPlayer?.pause()
    }

    func next() async {
        advance(by: 1)
    }

    func previous() async {
        // Straight to the previous track rather than to the start of this one.
        // MusicKit rewinds first because that is what its own button does inside
        // the Music app; TIDAL's player has no such convention to match, and a
        // parent pressing back in the dark means the track before this one.
        advance(by: -1)
    }

    func stop() async {
        session.existingPlayer?.reset()
        if session.delegate === self { session.delegate = nil }
        queue = []
        artists = [:]
        titles = [:]
        index = 0
        currentPlaylistID = nil
    }

    /// Moves the queue and restarts playback there.
    ///
    /// Explicit rather than `Player.skipToNext()`, which only moves if the next
    /// item has already been prepared and does nothing at all at the end of a
    /// queue. Gapless playback is unaffected — it comes from the `setNext` below
    /// and applies where it matters, when a track ends on its own — and what is
    /// bought is a skip button that behaves the same on the first press as on
    /// the two hundredth.
    private func advance(by offset: Int) {
        guard !queue.isEmpty, let player = session.existingPlayer else { return }
        let count = queue.count
        // Wraps in both directions: `%` alone answers negatively for a backwards
        // step off the front, and the track before the first is the last.
        load(at: ((index + offset) % count + count) % count, on: player)
        player.play()
    }

    /// Loads one track and queues the one after it.
    ///
    /// The `setNext` is what makes a playlist a playlist here: it is the SDK's
    /// only queue, so it has to be re-armed on every move, and re-arming it to
    /// `queue[0]` at the end is the whole of the repeat behaviour.
    private func load(at position: Int, on player: Player) {
        guard queue.indices.contains(position) else { return }
        index = position
        player.load(product(at: position))
        player.setNext(product(at: (position + 1) % queue.count))
        resolveMetadata(for: queue[position])
    }

    private func product(at position: Int) -> MediaProduct {
        MediaProduct(productType: .TRACK, productId: queue[position].id)
    }

    /// Fills in what the Viewer's "now playing" line needs for one track.
    ///
    /// Asked for whenever either half is still missing. The title is usually
    /// already there from the playlist page; when the server declined to sideload
    /// it, this is what supplies it, and it costs nothing extra because the
    /// artist needed the same request anyway.
    private func resolveMetadata(for track: TidalTrack) {
        let needsTitle = track.title == nil && titles[track.id] == nil
        guard needsTitle || artists[track.id] == nil else { return }
        Task { [weak self] in
            let metadata = await TidalCatalog.metadata(forTrack: track.id)
            guard let self else { return }
            if let title = metadata.title { self.titles[track.id] = title }
            if let artist = metadata.artist { self.artists[track.id] = artist }
        }
    }
}

// MARK: - Playback reports

extension TidalMusicProvider: TidalPlaybackDelegate {

    func tidalPlaybackTransitioned(toProductID productID: String, previewReason: String?) {
        // Something started, so whatever failed before it has recovered.
        hasFailed = false
        if previewReason == PreviewReason.FULL_REQUIRES_SUBSCRIPTION.rawValue {
            isPreviewOnly = true
        }

        guard let position = position(of: productID) else { return }
        index = position
        // Re-armed here as well as in `load` because a track that ended on its
        // own consumed the queued next without anything else being called.
        session.existingPlayer?.setNext(product(at: (position + 1) % queue.count))
        resolveMetadata(for: queue[position])
    }

    func tidalPlaybackFailed() {
        hasFailed = true
    }

    /// Where in the queue a product id landed.
    ///
    /// The obvious `firstIndex(where:)` is wrong for the playlist a nursery is
    /// most likely to hold: one where the same lullaby appears twice. Searching
    /// from the front would send the queue back to the first copy every time the
    /// second one started, and the night would loop over the same few tracks. So
    /// the two positions the player is actually likely to be reporting are
    /// checked first, and the search is only the last resort — a skip somewhere
    /// else in the queue, or a track TIDAL substituted for one that left the
    /// catalogue.
    private func position(of productID: String) -> Int? {
        guard !queue.isEmpty else { return nil }

        let expected = (index + 1) % queue.count
        if queue[expected].id == productID { return expected }
        if queue.indices.contains(index), queue[index].id == productID { return index }
        return queue.firstIndex { $0.id == productID }
    }
}

/// TIDAL credentials — id only, and only ever the id.
///
/// **There is no client secret here, and there must never be one.** A secret
/// belongs to the confidential-client flows a *server* performs; the flow a phone
/// uses to sign a parent in (authorization code + PKCE, which is what
/// `TidalSession.signIn` runs) is a public-client flow that has no secret in it.
/// And an app cannot keep one anyway: an IPA is a zip, `Info.plist` inside it is
/// plain text, and a constant in the binary falls out under `strings`. If TIDAL
/// ever demands a secret for something CribWire needs, that call belongs on the
/// backend, which is where `TIDAL_CLIENT_SECRET` already lives.
///
/// The id comes from two places, in order:
///
/// 1. **The backend**, via `GET /v1/config`, cached in `RemoteConfigurationStore`.
///    This is what makes rotating — or issuing one for the first time — a
///    configuration change rather than an App Store release.
/// 2. **Info.plist**, set per configuration in `project.yml` exactly like
///    `CribWireAPIBaseURL`. The floor: what a build works with before it has
///    ever reached a backend, and what a local-network-only pairing uses, since
///    that path never calls a server at all.
struct TidalConfiguration: Equatable {

    static let clientIDKey = "CribWireTidalClientID"
    static let redirectURIKey = "CribWireTidalRedirectURI"

    /// The redirect a build has unless it says otherwise, matching the URL
    /// scheme `project.yml` registers. It has to be listed on the application at
    /// `developer.tidal.com` as well — TIDAL rejects an authorize request whose
    /// redirect it does not recognise — which is why it is overridable at all:
    /// a deployment that registered something else sets `CribWireTidalRedirectURI`
    /// and adds its scheme alongside this one.
    static let defaultRedirectURI = "cribwire://tidal-auth"

    let clientID: String
    var redirectURI: String = defaultRedirectURI

    /// `nil` when neither source has an id, which is what makes an unconfigured
    /// deployment hide TIDAL rather than offer it.
    static var current: TidalConfiguration? {
        make(remote: RemoteConfigurationStore().load(), bundle: .main)
    }

    /// The precedence rule itself, split out so it can be asserted without
    /// standing up a bundle or writing to the shared defaults.
    ///
    /// Note that only the *id* has two sources. The redirect is a property of
    /// the build — its URL scheme has to be in the shipped Info.plist for iOS to
    /// route the callback at all — so it is read from the bundle whichever
    /// source the id came from.
    static func make(
        remote: RemoteConfiguration,
        bundle: Bundle
    ) -> TidalConfiguration? {
        guard var resolved = make(remote: remote) ?? make(rawClientID: clientID(in: bundle))
        else { return nil }
        resolved.redirectURI = redirectURI(in: bundle)
        return resolved
    }

    static func make(remote: RemoteConfiguration) -> TidalConfiguration? {
        make(rawClientID: remote.tidalClientID)
    }

    static func make(bundle: Bundle) -> TidalConfiguration? {
        guard var resolved = make(rawClientID: clientID(in: bundle)) else { return nil }
        resolved.redirectURI = redirectURI(in: bundle)
        return resolved
    }

    /// Split from `make(bundle:)` so the rule below can be asserted without
    /// building a bundle: what counts as "not configured" is the whole of this
    /// type's behaviour, and it is exactly the part that is easy to get wrong.
    static func make(rawClientID raw: String?) -> TidalConfiguration? {
        guard let clientID = configured(raw) else { return nil }
        return TidalConfiguration(clientID: clientID)
    }

    private static func clientID(in bundle: Bundle) -> String? {
        bundle.object(forInfoDictionaryKey: clientIDKey) as? String
    }

    /// A redirect the build cannot actually receive is worse than the default,
    /// so an unset, blank or scheme-less value falls back rather than being
    /// passed to TIDAL to be rejected.
    static func redirectURI(in bundle: Bundle) -> String {
        guard let raw = configured(bundle.object(forInfoDictionaryKey: redirectURIKey) as? String),
              URL(string: raw)?.scheme?.isEmpty == false
        else { return defaultRedirectURI }
        return raw
    }

    /// Trimmed, and `nil` where the value says nothing.
    ///
    /// XcodeGen leaves the literal `$(CRIBWIRE_TIDAL_CLIENT_ID)` in place when
    /// the build setting is undefined, so an unsubstituted placeholder has to
    /// count as "not configured" too.
    private static func configured(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}
