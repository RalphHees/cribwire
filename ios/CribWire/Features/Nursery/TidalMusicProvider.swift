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
/// 1. Register the app at `developer.tidal.com`, then set the client id either
///    on the backend as `TIDAL_CLIENT_ID` — served to Cameras by `GET /v1/config`
///    and rotatable without a release — or in `ios/project.yml` under
///    `CribWireTidalClientID` as the built-in fallback (see
///    `TidalConfiguration`). The client *secret*, if the backend ever needs one,
///    stays there as `TIDAL_CLIENT_SECRET` and is never served to a device.
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

    /// Only offered when a client id is available. A CribWire with none — which
    /// is every build until someone completes the steps above — does not show
    /// TIDAL in the Viewer's switcher at all, rather than showing a service that
    /// can never work.
    var isConfigured: Bool { configuration != nil }

    /// Resolved on each read rather than captured once.
    ///
    /// The id can now arrive from the backend after this object exists — a
    /// Camera builds its providers at launch and hears from `/v1/config`
    /// moments later — so a snapshot taken in `init` would mean a newly
    /// configured deployment did nothing until the app was next restarted.
    private let resolve: @MainActor () -> TidalConfiguration?

    private var configuration: TidalConfiguration? { resolve() }

    init(resolve: @escaping @MainActor () -> TidalConfiguration? = { .current }) {
        self.resolve = resolve
    }

    /// A fixed configuration, for tests and previews.
    init(configuration: TidalConfiguration?) {
        self.resolve = { configuration }
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

    /// False until the `Player` adapter exists. Unlike a lapsed Apple Music
    /// subscription — which still has a player to pause — there is nothing here
    /// for a transport button to reach, and offering one would be the four dead
    /// buttons this file is written to avoid. It becomes
    /// "signed in to TIDAL" when step 3 above is done.
    var canControlPlayback: Bool { false }

    @discardableResult
    func play(playlistID: String) async -> String? { nil }
    func play() async {}
    func pause() async {}
    func next() async {}
    func previous() async {}
    func stop() async {}
}

/// TIDAL credentials — id only, and only ever the id.
///
/// **There is no client secret here, and there must never be one.** A secret
/// belongs to the confidential-client flows a *server* performs; the flows a
/// phone uses to sign a parent in (device login, authorization code + PKCE) are
/// public-client flows that have no secret in them. And an app cannot keep one
/// anyway: an IPA is a zip, `Info.plist` inside it is plain text, and a constant
/// in the binary falls out under `strings`. If TIDAL ever demands a secret for
/// something CribWire needs, that call belongs on the backend, which is where
/// `TIDAL_CLIENT_SECRET` already lives.
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

    let clientID: String

    /// `nil` when neither source has one, which is what makes an unconfigured
    /// deployment hide TIDAL rather than offer it.
    static var current: TidalConfiguration? {
        make(remote: RemoteConfigurationStore().load()) ?? make(bundle: .main)
    }

    static func make(remote: RemoteConfiguration) -> TidalConfiguration? {
        make(rawClientID: remote.tidalClientID)
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
