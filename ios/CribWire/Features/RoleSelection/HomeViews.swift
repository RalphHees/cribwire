import CribWireKit
import SwiftUI

/// Camera home. Phase 1 covers pairing and the paired-device list; the live
/// status view with the pulse, dimming and battery warnings is Phase 2
/// (`docs/TASKS.md` → "Camera status screen").
struct CameraHomeView: View {
    @EnvironmentObject private var services: AppServices
    /// Owned here so the detectors' settings survive navigation in and out of
    /// the alerts screen.
    @StateObject private var detectionSettings = DetectionSettingsViewModel()

    var body: some View {
        NavigationStack {
            KCScreen {
                VStack(spacing: Theme.Metrics.stackSpacing) {
                    header

                    NavigationLink {
                        CameraPairingView(services: services)
                    } label: {
                        Text("Pair a Viewer")
                    }
                    .buttonStyle(KCPrimaryButtonStyle())

                    NavigationLink {
                        PairedDevicesView()
                    } label: {
                        Text(pairedDevicesTitle)
                    }
                    .buttonStyle(KCGhostButtonStyle())

                    NavigationLink {
                        DetectionSettingsView(model: detectionSettings)
                    } label: {
                        Text("Alerts")
                    }
                    .buttonStyle(KCGhostButtonStyle())

                    KCSecurityNote(
                        text: "Video, audio and alerts are encrypted on this device and can only be opened by the Viewers you paired in person."
                    )

                    Spacer()

                    switchRoleButton
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.Palette.coral)
                .frame(width: 84, height: 84)
                .background(Theme.Palette.coral.opacity(0.15), in: Circle())

            Text(services.pairings.isEmpty ? "Not paired yet" : "Ready")
                .font(Theme.Typography.title)
            Text(
                services.pairings.isEmpty
                    ? "Pair a Viewer to start monitoring."
                    : "\(services.pairings.count) paired viewer\(services.pairings.count == 1 ? "" : "s"). Live streaming arrives in the next release."
            )
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
    }

    private var pairedDevicesTitle: String {
        services.pairings.isEmpty
            ? "Paired viewers"
            : "Paired viewers (\(services.pairings.count))"
    }

    private var switchRoleButton: some View {
        Button("Use this device as a Viewer instead") {
            services.role = .viewer
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Palette.textFaint)
    }
}

/// Viewer home. The live view, audio-only mode and PiP are Phase 2.
struct ViewerHomeView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        NavigationStack {
            KCScreen {
                VStack(spacing: Theme.Metrics.stackSpacing) {
                    header

                    NavigationLink {
                        ViewerScanView(services: services)
                    } label: {
                        Text("Scan a Camera")
                    }
                    .buttonStyle(
                        KCPrimaryButtonStyle(
                            tint: Theme.Palette.periwinkle,
                            foreground: Theme.onAccent(for: .viewer)
                        )
                    )

                    NavigationLink {
                        PairedDevicesView()
                    } label: {
                        Text(pairedCamerasTitle)
                    }
                    .buttonStyle(KCGhostButtonStyle())

                    KCSecurityNote(
                        text: "Alerts are end-to-end encrypted. Only this device can read what the Camera sends.",
                        symbol: "bell.badge.fill",
                        tint: Theme.Palette.live
                    )

                    Spacer()

                    switchRoleButton
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("Viewer")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.Palette.periwinkle)
                .frame(width: 84, height: 84)
                .background(Theme.Palette.periwinkle.opacity(0.15), in: Circle())

            Text(services.pairings.isEmpty ? "No cameras yet" : "Ready")
                .font(Theme.Typography.title)
            Text(
                services.pairings.isEmpty
                    ? "Scan the code shown on the Camera device to pair."
                    : "\(services.pairings.count) paired camera\(services.pairings.count == 1 ? "" : "s"). Live viewing arrives in the next release."
            )
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.textMuted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
    }

    private var pairedCamerasTitle: String {
        services.pairings.isEmpty
            ? "Paired cameras"
            : "Paired cameras (\(services.pairings.count))"
    }

    private var switchRoleButton: some View {
        Button("Use this device as a Camera instead") {
            services.role = .camera
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Palette.textFaint)
    }
}
