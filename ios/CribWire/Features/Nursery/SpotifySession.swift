import CribWireKit
import CryptoKit
import Foundation
import OSLog
import UIKit

#if canImport(SpotifyiOS)
import SpotifyiOS
#endif

/// The one place a Spotify account is signed in, held and handed to the Spotify
/// app on this phone.
///
/// A singleton for the same reason `TidalSession` is one, plus a second reason of
/// its own. The first: `SPTAppRemote` owns a socket to another application and
/// two of those competing would be worse than one. The second: **the App Remote
/// hand-off comes back through `application(_:open:options:)`**, an app-wide
/// callback with exactly one plausible destination. `AppDelegate` forwards it
/// here.
///
/// ## Why Spotify does not play in this process
///
/// Apple Music and TIDAL both hand CribWire audio to play. Spotify permits no
/// such thing to a third-party app: its catalogue may only be played by the
/// Spotify app itself, and App Remote is the supported way to drive that app. So
/// on a Camera set to Spotify the sound comes out of Spotify, not out of
/// CribWire, and three things follow that are true of no other provider here:
///
/// - **The Spotify app must be installed on the Camera phone**, and Premium is
///   required — App Remote refuses to play for a free account.
/// - **The room can be playing when CribWire is not.** That is not a bug to fix:
///   a monitor whose music survives its own restart is the better behaviour for
///   a phone on a shelf. `stop()` therefore means "pause Spotify", because
///   nothing else is ours to end.
/// - **The audio session stays `WebRTCStack`'s.** CribWire never plays a sample
///   for Spotify, so there is nothing here to configure — and the Camera's
///   `playAndRecord` + `mixWithOthers` session is what lets the microphone keep
///   hearing the room while another app plays into it.
@MainActor
final class SpotifySession {

    static let shared = SpotifySession()

    /// `nonisolated` so the App Remote bridge can log from whatever thread the
    /// SDK calls it on. `Logger` is `Sendable`, so this costs nothing and
    /// removes a data-race warning that becomes an error under Swift 6.
    nonisolated static let log = Logger(
        subsystem: "com.ralphhees.cribwire",
        category: "spotify"
    )

    private init() {}

    /// Told when the Spotify app reports what it is doing. Weak, like TIDAL's:
    /// the provider owns this relationship and this object outlives it.
    weak var delegate: (any SpotifyPlaybackDelegate)?

    /// The scopes CribWire asks for, and nothing beyond them.
    ///
    /// `app-remote-control` and `streaming` are what App Remote refuses to
    /// connect without. `playlist-read-private` and `playlist-read-collaborative`
    /// are the parent's own playlists — the public ones need no scope, but a
    /// nursery playlist is exactly the kind nobody publishes.
    /// `user-library-read` is their saved albums, and `user-read-private` is the
    /// one call that answers whether this account is Premium, which is the
    /// difference between "ready" and a silent room.
    private static let scopes = [
        "app-remote-control",
        "streaming",
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-library-read",
        "user-read-private"
    ]

    /// Where the refresh token lives.
    ///
    /// The Keychain, not `UserDefaults`: unlike the client id — public by
    /// construction in every OAuth exchange — a refresh token is a bearer
    /// credential for the parent's music account, and `security.md` §3.2 is what
    /// `KeychainStore` already enforces for everything of that shape (unlocked
    /// this device only, never synced, never in a backup).
    private static let credentialsAccount = "cribwire.spotify.credentials"

    private let keychain = KeychainStore()

    /// Cached so the refresh tick — which asks `isSignedIn` every five seconds —
    /// never touches the Keychain, and so `accessToken()` can answer without a
    /// round trip while the token is still good.
    private var credentials: SpotifyCredentials?
    private var hasLoadedCredentials = false

    private var configuredClientID: String?

    // MARK: - Configuration

    /// Points this session at the deployment's client id. Idempotent and cheap,
    /// like `TidalSession.configure`, and re-run on a *changed* id for the same
    /// reason: `GET /v1/config` can deliver one after this object exists.
    func configure(_ configuration: SpotifyConfiguration) {
        loadCredentialsIfNeeded()
        guard configuredClientID != configuration.clientID else { return }
        configuredClientID = configuration.clientID
        #if canImport(SpotifyiOS)
        // Rebuilt rather than reconfigured: `SPTAppRemote` takes its
        // configuration at init and a stale one would authorize against the
        // wrong application.
        appRemote?.disconnect()
        appRemote = makeAppRemote(configuration)
        #endif
    }

    /// Whether a parent has connected an account to this Camera.
    ///
    /// True while a refresh token is held, *not* while the access token is
    /// fresh. Access tokens last an hour and a Camera runs all night, so the
    /// stricter reading would sign the nursery out somewhere around midnight and
    /// take Spotify off the Viewer's switcher until somebody walked in and
    /// tapped it again.
    var isSignedIn: Bool {
        loadCredentialsIfNeeded()
        return credentials?.refreshToken != nil
    }

    // MARK: - Sign-in

    private var signInTask: Task<Bool, Never>?

    /// Signs a parent in on the Camera's own screen, with authorization code +
    /// PKCE.
    ///
    /// PKCE rather than the implicit grant, and rather than anything involving a
    /// secret: this is a public client, an IPA is a zip, and a constant in the
    /// binary falls out under `strings` (the same argument written out at length
    /// on `TidalConfiguration`). PKCE is also what buys a refresh token, which is
    /// what lets a nursery phone keep playing at 4 a.m. without a parent
    /// re-authorising it.
    ///
    /// - Returns: whether the Camera is signed in afterwards.
    func signIn(configuration: SpotifyConfiguration) async -> Bool {
        // A second tap while the sheet is up joins the flow in progress, rather
        // than racing a second sheet that iOS would refuse to present.
        if let signInTask { return await signInTask.value }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.performSignIn(configuration: configuration)
        }
        signInTask = task
        let result = await task.value
        signInTask = nil
        return result
    }

    private func performSignIn(configuration: SpotifyConfiguration) async -> Bool {
        guard let redirect = URL(string: configuration.redirectURI),
              let scheme = redirect.scheme
        else { return false }

        let verifier = Self.makeCodeVerifier()
        // Not a security boundary on its own — the redirect is a scheme only
        // this app claims — but a mismatched `state` is the one cheap signal
        // that the callback belongs to a different attempt than the one waiting
        // on it, which is exactly what a re-login after a dismissed sheet can
        // produce.
        let state = Self.makeCodeVerifier()

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components?.url else { return false }

        guard let callback = await WebAuthenticationFlow.run(url: url, callbackScheme: scheme)
        else { return false }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value
        else {
            // A callback carrying `error=access_denied` lands here too, and it
            // means what a dismissed sheet means: still signed out. There is
            // nothing to tell a parent that the account list does not already
            // show them.
            return false
        }

        guard let credentials = await exchange(
            code: code,
            verifier: verifier,
            configuration: configuration
        ) else { return false }

        await store(credentials)
        #if canImport(SpotifyiOS)
        appRemote?.connectionParameters.accessToken = credentials.accessToken
        #endif
        return true
    }

    /// Forgets the account on this device.
    ///
    /// The token is dropped locally rather than revoked: Spotify exposes no
    /// revocation endpoint to a public client. What that means in practice is
    /// worth being honest about — the parent's *other* Spotify sessions are
    /// untouched, which is what anyone signing a nursery camera out actually
    /// wants, and this device keeps nothing it could reconnect with.
    func signOut() async {
        #if canImport(SpotifyiOS)
        appRemote?.disconnect()
        appRemote?.connectionParameters.accessToken = nil
        #endif
        credentials = nil
        hasLoadedCredentials = true
        playerState = nil
        try? await keychain.remove(account: Self.credentialsAccount)
    }

    // MARK: - Tokens

    /// A usable access token, refreshing it when it has expired.
    ///
    /// Every failure answers `nil` rather than throwing. A Camera that cannot
    /// refresh right now is a Camera whose music is unavailable for a while,
    /// which is a line on the Viewer's screen — never an error that reaches the
    /// stream.
    func accessToken(configuration: SpotifyConfiguration) async -> String? {
        loadCredentialsIfNeeded()
        guard let current = credentials else { return nil }
        // A minute of headroom, so a token that expires between this check and
        // the request it is used for does not produce a 401 the caller reads as
        // "signed out".
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }

        guard let refreshed = await refresh(current, configuration: configuration) else {
            return nil
        }
        await store(refreshed)
        return refreshed.accessToken
    }

    private func exchange(
        code: String,
        verifier: String,
        configuration: SpotifyConfiguration
    ) async -> SpotifyCredentials? {
        await token(
            form: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": configuration.redirectURI,
                "client_id": configuration.clientID,
                "code_verifier": verifier
            ],
            existingRefreshToken: nil
        )
    }

    private func refresh(
        _ credentials: SpotifyCredentials,
        configuration: SpotifyConfiguration
    ) async -> SpotifyCredentials? {
        guard let refreshToken = credentials.refreshToken else { return nil }
        return await token(
            form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": configuration.clientID
            ],
            // Spotify may or may not rotate the refresh token on a refresh. When
            // it does not, the response carries none and dropping it would sign
            // the nursery out an hour later — so the one we already hold is
            // carried forward.
            existingRefreshToken: refreshToken
        )
    }

    private func token(
        form: [String: String],
        existingRefreshToken: String?
    ) async -> SpotifyCredentials? {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(form).data(using: .utf8)
        // A nursery phone that has lost its uplink should find that out in
        // seconds, not hang a refresh tick behind the default 60.
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else {
            // Not logged with the body: a token response contains the tokens.
            Self.log.error("Spotify token request failed")
            return nil
        }

        return SpotifyCredentials(
            accessToken: payload.access_token,
            refreshToken: payload.refresh_token ?? existingRefreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(payload.expires_in))
        )
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private func store(_ credentials: SpotifyCredentials) async {
        self.credentials = credentials
        hasLoadedCredentials = true
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        try? await keychain.set(data, account: Self.credentialsAccount)
    }

    /// Reads the Keychain once per launch.
    ///
    /// Synchronous, against an `actor`, which is why it is done this way:
    /// `isSignedIn` is read from `availability()` on every refresh tick and from
    /// SwiftUI body evaluation, neither of which can await. So the blocking read
    /// happens once and the answer is kept — a single `SecItemCopyMatching` on a
    /// local keychain, at launch, on the main thread, in exchange for never
    /// doing it again.
    private func loadCredentialsIfNeeded() {
        guard !hasLoadedCredentials else { return }
        hasLoadedCredentials = true
        credentials = KeychainStore.readSynchronously(account: Self.credentialsAccount)
            .flatMap { try? JSONDecoder().decode(SpotifyCredentials.self, from: $0) }
    }

    // MARK: - PKCE

    /// 64 bytes of randomness, base64url-encoded — comfortably inside Spotify's
    /// 43–128 character window and generated by the system CSPRNG rather than by
    /// anything this file invents.
    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }
        .joined(separator: "&")
    }

    // MARK: - The Spotify app

    /// Whether the Spotify app is on this phone at all.
    ///
    /// Needs `spotify` in `LSApplicationQueriesSchemes` — without it iOS answers
    /// `false` for an installed app and the Camera would report Spotify as
    /// permanently unavailable on a phone that has it.
    var isSpotifyAppInstalled: Bool {
        guard let url = URL(string: "spotify:") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// What the Spotify app last said it was doing. `nil` before the first
    /// report, which is not the same as "not playing" and is why the provider
    /// treats it as unknown rather than as stopped.
    private(set) var playerState: SpotifyPlayerState?

    #if canImport(SpotifyiOS)

    private var appRemote: SPTAppRemote?
    private let bridge = AppRemoteBridge()

    private func makeAppRemote(_ configuration: SpotifyConfiguration) -> SPTAppRemote? {
        guard let redirect = URL(string: configuration.redirectURI) else { return nil }
        let remote = SPTAppRemote(
            configuration: SPTConfiguration(
                clientID: configuration.clientID,
                redirectURL: redirect
            ),
            // The SDK's own trace log, debug builds only — the same bargain as
            // TIDAL's `shouldAddLogging`. Everything between "play was called"
            // and "the room is silent" happens inside another application.
            logLevel: Self.isDebugBuild ? .debug : .none
        )
        remote.delegate = bridge
        remote.connectionParameters.accessToken = credentials?.accessToken
        return remote
    }

    var isConnected: Bool { appRemote?.isConnected ?? false }

    /// Connects to the Spotify app if it is running.
    ///
    /// Deliberately does *not* wake it. `connect()` on a Spotify app that is not
    /// running fails, and that failure is fine: it is called from the refresh
    /// tick, and a Camera nobody has asked to play anything has no business
    /// launching another application on the parent's phone in the middle of the
    /// night. Waking is `play(uri:)`'s job, where a parent actually asked.
    func connectIfPossible() {
        guard let appRemote, !appRemote.isConnected, isSignedIn else { return }
        appRemote.connectionParameters.accessToken = credentials?.accessToken
        appRemote.connect()
    }

    func disconnect() {
        appRemote?.disconnect()
    }

    /// Starts a playlist or album, waking the Spotify app when it has to.
    ///
    /// - Returns: whether Spotify was asked. `false` means the app is not
    ///   installed, which is the one failure here a parent can actually do
    ///   something about — and the Camera's account list says so in as many
    ///   words. It is deliberately *not* a report that the music started: only
    ///   the player-state subscription can say that, and it arrives later.
    @discardableResult
    func play(uri: String) async -> Bool {
        guard let appRemote else { return false }
        if appRemote.isConnected {
            appRemote.playerAPI?.play(uri, callback: nil)
            return true
        }
        // Not connected: this both launches Spotify and starts the URI, and
        // brings the parent back here through `application(_:open:)`. It is the
        // only path that works from a cold Spotify app, which on a nursery phone
        // is the usual state of it.
        return await withCheckedContinuation { continuation in
            let callback = SingleUseFlag(continuation)
            appRemote.authorizeAndPlayURI(uri) { success in
                callback.finish(success)
            }
        }
    }

    /// Transport, best-effort and fire-and-forget.
    ///
    /// Nothing waits for the callback: what actually happened arrives on the
    /// player-state subscription a moment later, and that — not our own optimism
    /// — is what the Viewer is shown.
    func resume() { appRemote?.playerAPI?.resume(nil) }
    func pause() { appRemote?.playerAPI?.pause(nil) }
    func next() { appRemote?.playerAPI?.skip(toNext: nil) }
    func previous() { appRemote?.playerAPI?.skip(toPrevious: nil) }

    /// The hand-off back from the Spotify app after `authorizeAndPlayURI`.
    ///
    /// Called by `AppDelegate` for every URL the app is opened with; URLs that
    /// are not Spotify's produce no parameters and are ignored here rather than
    /// filtered by the caller.
    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard let appRemote,
              let parameters = appRemote.authorizationParameters(from: url)
        else { return false }

        if let token = parameters[SPTAppRemoteAccessTokenKey] {
            // A *different* token from the OAuth one above: this is the App
            // Remote's own, issued by the Spotify app for the socket between the
            // two processes. It is not a Web API credential and is deliberately
            // not stored — it belongs to this connection and dies with it.
            appRemote.connectionParameters.accessToken = token
            appRemote.connect()
            return true
        }
        if let message = parameters[SPTAppRemoteErrorDescriptionKey] {
            Self.log.error("Spotify app refused the connection: \(message, privacy: .public)")
        }
        return false
    }

    /// Called by the bridge, on the main actor.
    fileprivate func appRemoteDidConnect() {
        appRemote?.playerAPI?.delegate = bridge
        appRemote?.playerAPI?.subscribe(toPlayerState: nil)
        delegate?.spotifyConnectionChanged(isConnected: true)
    }

    fileprivate func appRemoteDidDisconnect() {
        playerState = nil
        delegate?.spotifyConnectionChanged(isConnected: false)
    }

    fileprivate func appRemoteDidReport(_ state: SpotifyPlayerState) {
        playerState = state
        delegate?.spotifyPlayerStateChanged(state)
    }

    #else

    // Builds without the SDK — the Linux/CI paths that compile the app's models
    // but not its dependencies. Everything answers "no", which is exactly what
    // an unconfigured provider reports anyway.
    var isConnected: Bool { false }
    func connectIfPossible() {}
    func disconnect() {}
    @discardableResult func play(uri: String) async -> Bool { false }
    func resume() {}
    func pause() {}
    func next() {}
    func previous() {}
    @discardableResult func handleCallback(_ url: URL) -> Bool { false }

    #endif

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

// MARK: - What the Spotify app reports

/// What the Spotify app is doing, reduced to the three facts CribWire shows.
///
/// A value type rather than the SDK's `SPTAppRemotePlayerState`, for the same
/// reason `PlayerListenerBridge` reduces TIDAL's callbacks to strings: the SDK
/// object is neither `Sendable` nor useful to keep, and everything past this
/// point is a Viewer drawing one line of text.
struct SpotifyPlayerState: Equatable, Sendable {
    var isPlaying: Bool
    var title: String?
    var artist: String?
    /// The playlist or album this track is playing from, as a Spotify URI.
    /// `nil` when Spotify is playing something that has no context — a single
    /// track a parent started in the Spotify app themselves.
    var contextURI: String?
}

/// What the Spotify app tells the provider that asked for it.
@MainActor
protocol SpotifyPlaybackDelegate: AnyObject {
    func spotifyConnectionChanged(isConnected: Bool)
    func spotifyPlayerStateChanged(_ state: SpotifyPlayerState)
}

#if canImport(SpotifyiOS)

/// Turns App Remote's delegate callbacks into main-actor work.
///
/// The same shape as TIDAL's `PlayerListenerBridge` and for the same reasons:
/// the SDK's protocols are plain `AnyObject`, the objects they hand over are not
/// `Sendable`, and the useful part of each callback is a handful of strings. So
/// the strings are what cross onto the actor and the SDK objects stay here.
private final class AppRemoteBridge: NSObject, SPTAppRemoteDelegate,
    SPTAppRemotePlayerStateDelegate, @unchecked Sendable {

    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in SpotifySession.shared.appRemoteDidConnect() }
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        // Expected, routinely: this is what a Spotify app that is not running
        // answers, and the refresh tick asks every five seconds. Logged at debug
        // so it does not fill a night's log with something normal.
        SpotifySession.log.debug("Spotify app remote connection attempt failed")
        Task { @MainActor in SpotifySession.shared.appRemoteDidDisconnect() }
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        Task { @MainActor in SpotifySession.shared.appRemoteDidDisconnect() }
    }

    func playerStateDidChange(_ playerState: any SPTAppRemotePlayerState) {
        let state = SpotifyPlayerState(
            isPlaying: !playerState.isPaused,
            title: playerState.track.name,
            artist: playerState.track.artist.name,
            contextURI: playerState.contextURI.absoluteString
        )
        Task { @MainActor in SpotifySession.shared.appRemoteDidReport(state) }
    }
}

#endif

// MARK: - Stored credentials

/// The Spotify tokens, as they sit in the Keychain.
///
/// `Codable` into one item rather than three, so the three can never disagree —
/// a refresh token without its expiry is a session that looks valid forever.
struct SpotifyCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    /// `nil` only in the degenerate case of a grant that returned none, which
    /// PKCE does not produce. Kept optional so a malformed stored blob degrades
    /// to "signed out" rather than failing to decode at all.
    var refreshToken: String?
    var expiresAt: Date
}
