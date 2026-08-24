import Auth
import AuthenticationServices
import CribWireKit
import EventProducer
import Foundation
import OSLog
import Player
import TidalAPI
import UIKit

/// What the TIDAL player tells the provider that owns the queue.
///
/// A protocol rather than a closure because three unrelated things arrive on
/// this path — where playback moved to, why it is only playing thirty seconds,
/// and that it failed — and each one changes a different part of what the Viewer
/// is shown.
@MainActor
protocol TidalPlaybackDelegate: AnyObject {

    /// Playback moved to `productID`.
    ///
    /// - Parameter previewReason: the raw `PreviewReason` when TIDAL is playing
    ///   a thirty-second preview instead of the track, `nil` when it is playing
    ///   the real thing. This is the *only* moment TIDAL says anything about the
    ///   account's subscription, which is why it is carried all the way out to
    ///   the provider rather than logged and dropped.
    func tidalPlaybackTransitioned(toProductID productID: String, previewReason: String?)

    /// Playback failed. Best-effort, like everything else here: it downgrades
    /// what the Viewer is told and never propagates.
    func tidalPlaybackFailed()
}

/// The one place the TIDAL SDK is set up, signed in and held.
///
/// A singleton, reluctantly and for a hard reason: `Player.bootstrap` returns
/// `nil` on every call after the first, and `TidalAuth`, `TidalEventSender` and
/// `OpenAPIClientAPI.credentialsProvider` are process-wide singletons of the
/// SDK's own making. There is exactly one TIDAL session per process whether or
/// not this file admits it, so it admits it, and `TidalMusicProvider` stays a
/// plain object that can still be constructed in a test.
///
/// **The audio session is deliberately not touched here.** TIDAL's `Player`
/// plays through `AVPlayer` and — unlike most playback SDKs — never sets the
/// category or activates the session itself; that is left to the app. For
/// CribWire the app's answer is already written down in `WebRTCStack`:
/// `playAndRecord` + `mixWithOthers` + `defaultToSpeaker`, which is what lets
/// the Camera keep recording the room while it plays. Setting `.playback` here
/// — the obvious thing to do for a music player — would take the microphone
/// away and silently turn the monitor into a speaker.
@MainActor
final class TidalSession {

    static let shared = TidalSession()

    static let log = Logger(subsystem: "com.ralphhees.cribwire", category: "tidal")

    private init() {}

    weak var delegate: (any TidalPlaybackDelegate)?

    /// The scopes CribWire asks for, and nothing beyond them.
    ///
    /// Each one buys a specific thing this feature does: `collection.read` and
    /// `playlists.read` are the two routes to the parent's playlists (see
    /// `TidalCatalog.collectionPlaylists`), `playback` is what `Player` needs to
    /// stream a track at all, and `user.read` resolves the account id the
    /// collection is hung off. The internal-tier scopes (`r_usr`, `w_usr`) are
    /// deliberately absent: a third-party client cannot be granted them, and
    /// asking for a scope the registration does not carry fails the whole
    /// authorize request rather than degrading.
    private static let scopes: Set<String> = [
        "collection.read",
        "playlists.read",
        "playback",
        "user.read"
    ]

    /// Where the refresh token is kept. The SDK encrypts it into the Keychain
    /// under this key; nothing about a TIDAL session is ever written to
    /// `UserDefaults`, unlike the client id, which is public by construction.
    private static let credentialsKey = "cribwire.tidal"

    /// Distinguishes this installation from the same account signed in
    /// elsewhere, so revoking the Camera does not sign the parent out of their
    /// phone. `identifierForVendor` is stable for as long as the app is
    /// installed, which is exactly the lifetime of the stored credentials.
    private static var clientUniqueKey: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "cribwire"
    }

    /// The event queue is capped hard. It exists because `Player` requires an
    /// `EventSender` — playback reporting is not optional in the SDK — and the
    /// two opt-out categories are blocked, so what is left is the necessary
    /// minimum TIDAL needs to account for a stream.
    private static let maxEventDiskUsageBytes = 200_000

    private var configuredClientID: String?
    private var bootstrappedPlayer: Player?
    private let listener = PlayerListenerBridge()

    /// The player, if one has been built. Reading it never builds one: the
    /// refresh loop asks what is playing every five seconds and must not be the
    /// thing that stands up a database and an offline store on a Camera nobody
    /// has asked to play anything.
    var existingPlayer: Player? { bootstrappedPlayer }

    // MARK: - Configuration

    /// Points the SDK at this deployment's client id. Idempotent, and cheap
    /// enough to call from `availability()` on every refresh tick.
    ///
    /// Re-configuring on a *changed* id is intentional rather than incidental:
    /// the id can arrive from `GET /v1/config` after this object exists, and a
    /// Camera that had already configured itself from the built-in fallback has
    /// to pick the new one up without being restarted.
    func configure(_ configuration: TidalConfiguration) {
        guard configuredClientID != configuration.clientID else { return }

        TidalAuth.shared.config(
            config: AuthConfig(
                clientId: configuration.clientID,
                clientUniqueKey: Self.clientUniqueKey,
                credentialsKey: Self.credentialsKey,
                scopes: Self.scopes
            )
        )
        TidalEventSender.shared.config(
            EventConfig(
                credentialsProvider: TidalAuth.shared,
                maxDiskUsageBytes: Self.maxEventDiskUsageBytes,
                // Everything a user is allowed to opt out of, opted out of. A
                // baby monitor has no business contributing to advertising or
                // product analytics on the parent's music account.
                blockedConsentCategories: [.targeting, .performance]
            )
        )
        OpenAPIClientAPI.credentialsProvider = TidalAuth.shared
        configuredClientID = configuration.clientID
    }

    /// Whether a parent has signed this Camera in. A Keychain read, not a
    /// network call — which is what makes it safe on the refresh path.
    var isSignedIn: Bool {
        guard configuredClientID != nil else { return false }
        return TidalAuth.shared.isUserLoggedIn
    }

    /// The signed-in account's id, which is also the id of their collection.
    ///
    /// From the stored credentials rather than from `/users/me`, so the common
    /// case costs nothing. `nil` when signed out, or when the token could not be
    /// refreshed — which is the same answer as "no playlists", and is treated as
    /// such by every caller.
    func userID() async -> String? {
        guard isSignedIn else { return nil }
        return try? await TidalAuth.shared.getCredentials().userId
    }

    // MARK: - Player

    /// The player, building it on first use.
    ///
    /// Deferred to the first actual play for weight, not tidiness:
    /// `Player.bootstrap` opens a GRDB store and an offline cache, and a Camera
    /// whose parent uses Apple Music must not pay for that because TIDAL happens
    /// to be configured on the deployment.
    func player() -> Player? {
        if let bootstrappedPlayer { return bootstrappedPlayer }
        guard configuredClientID != nil else { return nil }

        bootstrappedPlayer = Player.bootstrap(
            playerListener: listener,
            credentialsProvider: TidalAuth.shared,
            eventSender: TidalEventSender.shared,
            // The SDK's own trace log, debug builds only. Everything between
            // "the track was queued" and "the room is silent" happens inside
            // `Player` — token refreshes, stream privileges, the offline store,
            // the AVPlayer underneath — and none of it surfaces through
            // `PlayerListener`, which reports a `failed` with no detail. This is
            // the only way to see which of them it was. Off in release: it is
            // chatty, and it is TIDAL's logger rather than one this app can
            // promise anything about the contents of.
            shouldAddLogging: Self.isDebugBuild
        )
        if bootstrappedPlayer == nil {
            Self.log.error("Player.bootstrap returned nil — TIDAL cannot play on this camera")
        }
        return bootstrappedPlayer
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: - Sign-in

    private var signInTask: Task<Bool, Never>?
    /// Held for the duration of the flow only. `ASWebAuthenticationSession`
    /// holds its presentation context provider *weakly*, so a locally scoped one
    /// is deallocated before iOS asks it for a window and the sheet never
    /// appears.
    private var webSession: ASWebAuthenticationSession?
    private var anchor: PresentationAnchor?

    /// Signs a parent in, on the Camera's own screen.
    ///
    /// The authorization-code flow, not device login: device login is documented
    /// by TIDAL as available to their own applications only, so a third-party
    /// client that reached for it would get an error instead of a code. The web
    /// sheet is fine here precisely because this is only ever called from the
    /// Camera's own UI — a login sheet raised by a tap on another phone is a
    /// sheet nobody is standing in front of.
    ///
    /// - Returns: whether the Camera is signed in afterwards.
    func signIn(redirectURI: String) async -> Bool {
        // A second tap while the sheet is already up joins the flow in progress
        // rather than starting a competing one — `start()` on a second session
        // would simply fail, and the parent would be left looking at a button
        // that did nothing.
        if let signInTask { return await signInTask.value }

        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            defer {
                self.webSession = nil
                self.anchor = nil
            }

            guard let url = TidalAuth.shared.initializeLogin(
                redirectUri: redirectURI,
                loginConfig: LoginConfig()
            ), let scheme = URL(string: redirectURI)?.scheme else { return false }

            guard let callback = await self.authenticate(with: url, scheme: scheme) else {
                return false
            }
            // A cancelled sheet and a refused sign-in land here identically, and
            // both mean the same thing to the Camera: still signed out.
            guard (try? await TidalAuth.shared.finalizeLogin(
                loginResponseUri: callback.absoluteString
            )) != nil else { return false }

            return TidalAuth.shared.isUserLoggedIn
        }

        signInTask = task
        let result = await task.value
        signInTask = nil
        return result
    }

    /// Forgets the account on this device. Not reachable from a Viewer, for the
    /// same reason signing in is not.
    func signOut() {
        try? TidalAuth.shared.logout()
        bootstrappedPlayer?.reset()
    }

    private func authenticate(with url: URL, scheme: String) async -> URL? {
        // Resolved before the session is built rather than inside the anchor,
        // because "there is no window" and "the sheet failed to start" are the
        // same outcome and this is the only place that can say so without
        // inventing a window to hand back.
        guard let window = Self.presentationWindow() else { return nil }

        return await withCheckedContinuation { continuation in
            let callback = LoginCallback(continuation)
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(scheme)
            ) { callbackURL, _ in
                callback.finish(callbackURL)
            }
            let anchor = PresentationAnchor(window: window)
            session.presentationContextProvider = anchor
            session.prefersEphemeralWebBrowserSession = false
            self.anchor = anchor
            self.webSession = session

            // `start()` failing means the completion handler will never run, so
            // the continuation has to be resumed here or this task waits for the
            // rest of the night. `LoginCallback` is what makes doing both safe.
            if !session.start() {
                callback.finish(nil)
            }
        }
    }

    /// The window the sheet is presented over: the key window of a foreground
    /// scene, which on a Camera being set up is the only window there is.
    ///
    /// `nil` when the app has no window on screen at all, which means nobody is
    /// looking at the phone this sign-in was supposed to be answered on.
    private static func presentationWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

// MARK: - Callback plumbing

/// Resumes the sign-in continuation exactly once.
///
/// Both writers — `ASWebAuthenticationSession`'s completion handler and the
/// `start()` failure path — run on the main thread, which is what makes the
/// unchecked conformance true rather than merely convenient. Resuming a
/// continuation twice is a crash, and this is the one place two callers could.
private final class LoginCallback: @unchecked Sendable {

    private var continuation: CheckedContinuation<URL?, Never>?

    init(_ continuation: CheckedContinuation<URL?, Never>) {
        self.continuation = continuation
    }

    func finish(_ url: URL?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: url)
    }
}

/// Where the TIDAL sheet is presented from.
///
/// It holds the window rather than looking one up, so that the "no window at
/// all" case is decided by `TidalSession.presentationWindow()` before the flow
/// starts — a context provider has no way to say no, and the only alternative
/// would be conjuring a window nothing is attached to.
///
/// A strong reference, deliberately: `ASWebAuthenticationSession` holds its
/// context provider *weakly*, so `TidalSession` keeps this object alive for the
/// duration of the flow and it in turn keeps the window it was told about.
@MainActor
private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {

    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}

/// Turns `Player`'s delegate callbacks into main-actor work.
///
/// `PlayerListener` is a plain `AnyObject` protocol the SDK calls on its
/// `listenerQueue` — main, by default — and the objects it hands over
/// (`MediaProduct`, `PlaybackContext`) are neither `Sendable` nor useful to keep.
/// So nothing is kept: each callback is reduced to strings here and the strings
/// are what cross onto the actor.
private final class PlayerListenerBridge: NSObject, PlayerListener, @unchecked Sendable {

    func stateChanged(to state: State) {
        // Polled instead. `NurseryController` re-reads `isPlaying` on its own
        // tick, and pushing every STALLED/PLAYING flip through the actor would
        // publish a sealed state message for each one.
    }

    func ended(_ mediaProduct: MediaProduct) {
        // The next track is already queued with `setNext`, so the end of one is
        // not a moment anything has to act on; `mediaTransitioned` is where the
        // queue actually moves.
    }

    func mediaTransitioned(to mediaProduct: MediaProduct, with playbackContext: PlaybackContext) {
        let productID = mediaProduct.productId
        let previewReason = playbackContext.previewReason?.rawValue
        Task { @MainActor in
            TidalSession.shared.delegate?.tidalPlaybackTransitioned(
                toProductID: productID,
                previewReason: previewReason
            )
        }
    }

    func failed(with error: PlayerError) {
        // Logged here and not carried onward. `PlayerError` is not `Sendable`
        // and there is nothing the Viewer could be shown that a parent could act
        // on from another room — but "TIDAL stopped and nobody knows why" is not
        // something to leave undiagnosable on a device meant to run all night.
        // `errorId` is the useful half: it separates the four causes that look
        // identical from the outside — `PEContentNotAvailableForSubscription`,
        // `PEMonthlyStreamQuotaExceeded`, `PEContentNotAvailableInLocation` and
        // `PENetwork` all reach a parent as a room that stayed silent.
        let id = error.errorId.rawValue
        let code = error.errorCode
        TidalSession.log.error(
            "TIDAL playback failed: \(id, privacy: .public) (\(code, privacy: .public))"
        )
        Task { @MainActor in
            TidalSession.shared.delegate?.tidalPlaybackFailed()
        }
    }

    func mediaServicesWereReset() {
        // The audio session is `WebRTCStack`'s, and it rebuilds it from its own
        // `AVAudioSession.mediaServicesWereResetNotification` observer
        // (`AudioInterruptionMonitor`). Configuring it here as TIDAL's sample
        // code does would set `.playback` over the top of the Camera's
        // `playAndRecord` and take the microphone away.
    }
}
