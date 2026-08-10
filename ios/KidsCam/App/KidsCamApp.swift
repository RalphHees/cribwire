import SwiftUI

@main
struct KidsCamApp: App {
    @StateObject private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                .preferredColorScheme(.dark)
                .task { await services.performLaunchTasks() }
        }
    }
}

/// Chooses the first screen: role selection until a role is picked, then the
/// home screen for that role.
struct RootView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        Group {
            switch services.role {
            case .none:
                RoleSelectionView()
            case .camera:
                CameraHomeView()
            case .viewer:
                ViewerHomeView()
            }
        }
        .tint(Theme.Palette.coral)
    }
}
