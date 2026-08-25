import AuthenticationServices
import Foundation
import UIKit

/// Runs an OAuth sheet on the Camera's own screen and hands back the callback URL.
///
/// Extracted because two services now need exactly this and the plumbing is all
/// traps: `ASWebAuthenticationSession` holds its presentation context provider
/// **weakly**, so a locally scoped one is deallocated before iOS asks it for a
/// window and the sheet never appears; `start()` can fail without ever calling
/// the completion handler, so a continuation resumed only from that handler waits
/// for the rest of the night; and resuming a continuation twice is a crash rather
/// than a warning. Each of those is a bug that shows up as "the sign-in button
/// does nothing", which is indistinguishable from the parent's Wi-Fi being down.
///
/// Only ever reached from the Camera's own UI. A login sheet raised by a tap on
/// another phone is a sheet nobody is standing in front of — the rule that also
/// keeps `MusicProvider.requestAuthorization` off every remote command path.
@MainActor
enum WebAuthenticationFlow {

    /// Presents `url` and waits for the redirect back to `callbackScheme`.
    ///
    /// - Returns: the callback URL, or `nil` when the parent dismissed the
    ///   sheet, when it could not be started, or when there is no window to
    ///   present it over. All three are the same answer to the only question the
    ///   caller has — still signed out — and none of them is an error worth
    ///   propagating into a baby monitor.
    static func run(url: URL, callbackScheme: String) async -> URL? {
        // Resolved before the session is built rather than inside the anchor,
        // because "there is no window" and "the sheet failed to start" are the
        // same outcome and this is the only place that can say so without
        // inventing a window to hand back.
        guard let window = presentationWindow() else { return nil }

        return await withCheckedContinuation { continuation in
            let callback = SingleUseCallback(continuation)
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(callbackScheme)
            ) { callbackURL, _ in
                callback.finish(callbackURL)
            }
            let anchor = PresentationAnchor(window: window)
            session.presentationContextProvider = anchor
            // Not ephemeral: a parent signing the nursery phone in should be
            // able to use the session their browser already has, rather than
            // typing a password into a phone in a dark room.
            session.prefersEphemeralWebBrowserSession = false
            // The strong references that keep both alive for the duration of the
            // flow. Cleared when it ends, so a dismissed sheet is not retained
            // until the next sign-in.
            self.session = session
            self.anchor = anchor

            // `start()` failing means the completion handler will never run, so
            // the continuation has to be resumed here or this task waits for the
            // rest of the night. `SingleUseCallback` is what makes doing both
            // safe.
            if !session.start() {
                callback.finish(nil)
            }
        }
    }

    /// Held for the duration of one flow only — see the note above about the
    /// weak `presentationContextProvider`. Two sign-ins cannot overlap: each
    /// service serialises its own, and a second sheet over the first would be a
    /// sheet the parent cannot answer anyway.
    private static var session: ASWebAuthenticationSession?
    private static var anchor: PresentationAnchor?

    /// The window the sheet is presented over: the key window of a foreground
    /// scene, which on a Camera being set up is the only window there is.
    ///
    /// `nil` when the app has no window on screen at all, which means nobody is
    /// looking at the phone this sign-in was supposed to be answered on.
    static func presentationWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

/// Resumes a continuation exactly once, from wherever the answer arrives.
///
/// Resuming twice is a crash rather than a warning, and every SDK callback this
/// project bridges has two ways to produce an answer: the completion handler and
/// a synchronous failure path that means the handler will never run. Dropping
/// the second answer is the whole job.
///
/// The lock is what makes the unchecked conformance true. An earlier version
/// relied on both writers being on the main thread, which held for
/// `ASWebAuthenticationSession` and does not hold for the Spotify SDK, whose
/// completion handlers carry no such promise.
final class SingleUseContinuation<Value: Sendable>: @unchecked Sendable {

    private var continuation: CheckedContinuation<Value, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// The web-sheet flow's continuation: a callback URL, or nothing.
typealias SingleUseCallback = SingleUseContinuation<URL?>

/// The Spotify hand-off's continuation: whether the Spotify app took the
/// request at all.
typealias SingleUseFlag = SingleUseContinuation<Bool>

/// Where an OAuth sheet is presented from.
///
/// It holds the window rather than looking one up, so that the "no window at
/// all" case is decided by `WebAuthenticationFlow.presentationWindow()` before
/// the flow starts — a context provider has no way to say no, and the only
/// alternative would be conjuring a window nothing is attached to.
///
/// A strong reference to the window, deliberately: `ASWebAuthenticationSession`
/// holds this object weakly, so the flow keeps it alive and it in turn keeps the
/// window it was told about.
@MainActor
final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {

    private let window: UIWindow

    init(window: UIWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
