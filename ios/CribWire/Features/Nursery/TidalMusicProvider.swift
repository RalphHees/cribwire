import CribWireKit
import Foundation

/// TIDAL.
///
/// **Status: the control plane is complete, the playback engine is not.** Every
/// other part of this feature — the sealed command protocol, the Viewer's
/// controls, the shortlist, the recents on the Camera — is provider-agnostic and
/// already works for TIDAL. What is missing is the one thing that cannot be
/// written without a TIDAL partner account:
///
/// TIDAL does not permit third-party apps to play its catalogue by any route
/// except its own SDK (`github.com/tidal-music/tidal-sdk-ios`, modules `Player`,
/// `Auth`, `EventProducer`). That SDK requires a client id issued per application
/// at `developer.tidal.com`, and full-length playback additionally requires the
/// user to be signed in as a subscriber through Device Login or the authorization
/// code flow. There is no public catalogue-playback path that works without those
/// credentials, and shipping a provider that pretends otherwise would put a
/// service in front of a parent that silently plays nothing.
///
/// So this provider is honest instead: it is offered only when a client id has
/// been configured into the build, and until the SDK adapter exists it reports
/// `notConfigured`, which the Viewer renders as "TIDAL is not set up on this
/// camera" rather than as four dead buttons.
///
/// ## Finishing it
///
/// 1. Register the app at `developer.tidal.com` and put the client id in
///    `ios/project.yml` under `CribWireTidalClientID` (see `TidalConfiguration`).
/// 2. Add `https://github.com/tidal-music/tidal-sdk-ios` to `packages:` in
///    `ios/project.yml` and the `Player`, `Auth` and `EventProducer` products to
///    the `CribWire` target.
/// 3. Implement the bodies below against `Auth` (login and token refresh),
///    `TidalAPI` (the user's playlists and recently played) and `Player`
///    (transport). Nothing outside this file has to change: `NurseryController`
///    already treats every provider identically.
///
/// The one thing to keep when doing so is the sign-in rule shared with
/// `AppleMusicProvider`: authorisation is requested from the Camera's own screen
/// and never from a remote command, because a login sheet raised by a tap on
/// another phone is a sheet nobody is standing in front of.
@MainActor
final class TidalMusicProvider: MusicProvider {

    let kind: MusicProviderKind = .tidal

    /// Only offered when the build carries a client id. A CribWire built without
    /// one — which is every build until someone completes the steps above — does
    /// not show TIDAL in the Viewer's switcher at all, rather than showing a
    /// service that can never work.
    var isConfigured: Bool { configuration != nil }

    private let configuration: TidalConfiguration?

    init(configuration: TidalConfiguration? = .current) {
        self.configuration = configuration
    }

    // MARK: - Authorisation

    func availability() async -> MusicState.Availability {
        // Configured but unimplemented. `notConfigured` is the accurate answer to
        // the Viewer's question — "can this Camera play TIDAL?" — and it is the
        // one availability the Viewer does not offer a retry for, which is right:
        // no amount of tapping completes an integration.
        .notConfigured
    }

    @discardableResult
    func requestAuthorization() async -> MusicState.Availability {
        .notConfigured
    }

    // MARK: - Playlists

    func loadPlaylists() async -> (
        favorites: [PlaylistSummary],
        recentlyPlayed: [PlaylistSummary]
    ) {
        ([], [])
    }

    // MARK: - Transport

    var currentPlaylistID: String? { nil }
    var isPlaying: Bool { false }
    var nowPlaying: (title: String?, artist: String?) { (nil, nil) }

    @discardableResult
    func play(playlistID: String) async -> String? { nil }
    func play() async {}
    func pause() async {}
    func next() async {}
    func previous() async {}
    func stop() async {}
}

/// Build-time TIDAL credentials.
///
/// Read from Info.plist rather than compiled into a constant so the id can be set
/// per configuration in `project.yml`, exactly like `CribWireAPIBaseURL`. A client
/// id is not a secret — it is public in every OAuth flow — but it is still
/// deployment configuration and does not belong in source.
struct TidalConfiguration: Equatable {

    static let clientIDKey = "CribWireTidalClientID"

    let clientID: String

    /// `nil` when the key is absent or blank, which is what makes an
    /// unconfigured build hide TIDAL rather than offer it.
    static var current: TidalConfiguration? {
        make(bundle: .main)
    }

    static func make(bundle: Bundle) -> TidalConfiguration? {
        make(rawClientID: bundle.object(forInfoDictionaryKey: clientIDKey) as? String)
    }

    /// Split from `make(bundle:)` so the rule below can be asserted without
    /// building a bundle: what counts as "not configured" is the whole of this
    /// type's behaviour, and it is exactly the part that is easy to get wrong.
    static func make(rawClientID raw: String?) -> TidalConfiguration? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // XcodeGen leaves the literal `$(CRIBWIRE_TIDAL_CLIENT_ID)` in place when
        // the build setting is undefined, so an unsubstituted placeholder has to
        // count as "not configured" too.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return TidalConfiguration(clientID: trimmed)
    }
}
