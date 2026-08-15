import SwiftUI

@main
struct CribWireApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                .environmentObject(services.notifications)
                .preferredColorScheme(.dark)
                .task {
                    // Set before anything can register for remote
                    // notifications, so the token callback has somewhere to go.
                    AppDelegate.notifications = services.notifications
                    await services.performLaunchTasks()
                    await services.notifications.prepare()
                    // Cold launch: whatever was delivered while the app was not
                    // running still says "Activity detected".
                    await services.notifications.upgradeDeliveredNotifications()
                }
                // Same again on every return to the foreground — `onChange` does
                // not fire for the launch transition (see
                // `PushNotificationCoordinator`).
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await services.notifications.upgradeDeliveredNotifications()
                        // The user may have just come back from Settings having
                        // turned alerts on, which is the only way out of a denial.
                        await services.notifications.refreshAuthorizationStatus()
                    }
                }
        }
    }
}

/// Chooses the first screen: role selection until a role is picked, then the
/// home screen for that role.
struct RootView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        Group {
            if let role = services.role {
                switch role {
                case .camera: CameraHomeView()
                case .viewer: ViewerHomeView()
                }
            } else {
                RoleSelectionView()
            }
        }
        .tint(Theme.Palette.coral)
    }
}
