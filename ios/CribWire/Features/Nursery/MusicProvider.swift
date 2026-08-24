import CribWireKit
import Foundation

/// One music service, as the Camera drives it.
///
/// The protocol exists so that `NurseryController` — the thing the Viewer actually
/// talks to — never mentions Apple Music or TIDAL. That matters for more than
/// tidiness: the two services differ enormously in what they let an app do, and
/// the only way the Viewer's four buttons can mean the same thing on both is if
/// each service is made to answer the same small set of questions.
///
/// Everything here is best-effort and non-throwing by design. A music service that
/// is signed out, rate-limited or simply slow must degrade to "not right now" on
/// the Viewer's screen; it must never be able to fail a baby monitor.
@MainActor
protocol MusicProvider: AnyObject {

    var kind: MusicProviderKind { get }

    /// Whether this provider can be used at all on this build and this device.
    /// Checked before the provider is offered, so a service with no credentials
    /// compiled in never appears in the Viewer's switcher.
    var isConfigured: Bool { get }

    /// Current availability, without prompting for anything.
    func availability() async -> MusicState.Availability

    /// Whether play, pause, next and previous reach a player right now.
    ///
    /// Separate from `availability` because the two questions have different
    /// answers, and the difference is a parent's whole experience of this
    /// feature: playing something *new* from a catalogue is what a subscription
    /// buys, while pausing what is already going needs nothing but permission to
    /// talk to the player. Answering both with `availability == .ready` took the
    /// pause button away from exactly the people most likely to want it.
    ///
    /// Synchronous and cheap: it is read on every refresh tick.
    var canControlPlayback: Bool { get }

    /// Asks for whatever authorisation the service needs.
    ///
    /// Only ever called from the **Camera's own screen**, never from a remote
    /// command: a permission dialog raised by a tap on another device is a dialog
    /// nobody is standing in front of, and iOS would show it over a nursery
    /// camera in the dark.
    @discardableResult
    func requestAuthorization() async -> MusicState.Availability

    /// Playlists and albums worth offering: the user's favourites/library plus
    /// whatever the service considers recently played. Ordering is not this
    /// method's problem — `PlaylistShortlist` decides that.
    func loadPlaylists() async -> (favorites: [PlaylistSummary], recentlyPlayed: [PlaylistSummary])

    /// Loads a playlist and starts it.
    ///
    /// Three answers rather than an optional name, because the caller acts on the
    /// difference: `NurseryController` deletes the parent's history entry for a
    /// playlist that is `.gone`, and a failure that merely *might* be permanent
    /// must never trigger that. See `PlaylistPlaybackOutcome`.
    @discardableResult
    func play(playlistID: String) async -> PlaylistPlaybackOutcome

    func play() async
    func pause() async
    func next() async
    func previous() async
    /// Stops and releases the queue.
    func stop() async

    /// What is playing right now, if anything.
    var nowPlaying: (title: String?, artist: String?) { get }
    var isPlaying: Bool { get }
    /// The playlist currently loaded, if it was loaded through CribWire.
    var currentPlaylistID: String? { get }
}

/// How a request to play a playlist turned out.
///
/// The distinction that matters is between the last two, and it is not a nicety:
/// a Camera on a nursery shelf loses its network, its token expires overnight, and
/// its music service rate-limits it — none of which mean the parent's playlist
/// stopped existing. Collapsing all of that into one "nil" is what let a Wi-Fi
/// blip delete a playlist from the history it had been played from every night.
enum PlaylistPlaybackOutcome {

    /// Playing, with the display name and the kind to record in the Camera's
    /// recents — the kind because the id in that history is handed back to
    /// `play(playlistID:)` on some later night, when the listing that knew an
    /// album from a playlist is long gone.
    case playing(name: String, kind: MusicItemKind = .playlist)

    /// The service answered, and the playlist is not there — deleted on the
    /// account, or emptied. The only outcome that may drop a history entry.
    case gone

    /// It could not be played right now. Might be the network, the token, the
    /// subscription or the service; the one thing it is not is proof that the
    /// playlist is gone, so the history entry stays.
    case unavailable
}
