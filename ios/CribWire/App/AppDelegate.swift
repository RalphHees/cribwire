import UIKit

/// The one job left to a `UIApplicationDelegate` in a SwiftUI app: APNs
/// registration callbacks, which have no SwiftUI equivalent.
///
/// Everything it learns is handed straight to `PushNotificationCoordinator`.
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
