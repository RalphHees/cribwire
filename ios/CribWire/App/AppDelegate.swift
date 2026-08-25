import UIKit

/// The two jobs left to a `UIApplicationDelegate` in a SwiftUI app: APNs
/// registration callbacks, which have no SwiftUI equivalent, and the URL the
/// Spotify app opens this one with.
///
/// Neither is decided here. The APNs token goes straight to
/// `PushNotificationCoordinator`, and the URL to `SpotifySession`.
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// Wired by `CribWireApp` at launch. The delegate adaptor builds this object
    /// before the service graph exists, so the connection is a seam rather than
    /// an initialiser parameter; `weak` keeps it from outliving the app scene.
    @MainActor static weak var notifications: PushNotificationCoordinator?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            Self.notifications?.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    /// The Spotify app handing back an App Remote token.
    ///
    /// A real app-open, unlike either music sign-in: those run in an
    /// `ASWebAuthenticationSession`, which intercepts its own callback and never
    /// reaches this method. This one is `SPTAppRemote.authorizeAndPlayURI`
    /// returning — the Spotify app launching CribWire on the `cribwire` scheme
    /// with the token for the socket between the two processes.
    ///
    /// Handed on unfiltered: `SpotifySession` answers `false` for a URL that is
    /// not Spotify's, which is a cheaper way to be right than teaching this
    /// method to recognise one.
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        MainActor.assumeIsolated {
            SpotifySession.shared.handleCallback(url)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // The error text can name the device and the environment, so it is not
        // logged; "no token" is the only fact any call site needs.
        Task { @MainActor in
            Self.notifications?.didFailToRegisterForRemoteNotifications()
        }
    }
}
