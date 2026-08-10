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
