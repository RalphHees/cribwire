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

    /// Asks for whatever authorisation the service needs.
    ///
    /// Only ever called from the **Camera's own screen**, never from a remote
    /// command: a permission dialog raised by a tap on another device is a dialog
    /// nobody is standing in front of, and iOS would show it over a nursery
    /// camera in the dark.
    @discardableResult
    func requestAuthorization() async -> MusicState.Availability

    /// Playlists worth offering: the user's favourites/library plus whatever the
    /// service considers recently played. Ordering is not this method's problem —
    /// `PlaylistShortlist` decides that.
    func loadPlaylists() async -> (favorites: [PlaylistSummary], recentlyPlayed: [PlaylistSummary])

    /// Loads a playlist and starts it. Returns the playlist's display name so the
    /// Camera's own recents list can record it, or `nil` if it could not be
    /// played.
    @discardableResult
    func play(playlistID: String) async -> String?

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
