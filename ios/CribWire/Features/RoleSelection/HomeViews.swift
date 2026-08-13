import CribWireKit
import SwiftUI

/// Camera home: start streaming, pair a Viewer, manage pairings and alerts.
///
/// "Start the camera" is the primary action but only appears once a Viewer has
/// been paired — a Camera with nobody to stream to has nothing to start.
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

                    if let record = services.pairings.first(where: { $0.localRole == .camera }) {
                        NavigationLink {
                            CameraStatusView(record: record, services: services)
                        } label: {
                            Text("Start the camera")
                        }
                        .buttonStyle(KCPrimaryButtonStyle())

                        NavigationLink {
                            CameraPairingView(services: services)
                        } label: {
                            Text("Pair another Viewer")
                        }
                        .buttonStyle(KCGhostButtonStyle())
                    } else {
                        NavigationLink {
                            CameraPairingView(services: services)
                        } label: {
                            Text("Pair a Viewer")
                        }
                        .buttonStyle(KCPrimaryButtonStyle())
                    }

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
    @EnvironmentObject private var notifications: PushNotificationCoordinator

    var body: some View {
        NavigationStack {
            KCScreen {
                VStack(spacing: Theme.Metrics.stackSpacing) {
                    header

                    if let latest = notifications.latestEvent {
                        latestAlert(latest)
                    }

                    if let record = services.pairings.first(where: { $0.localRole == .viewer }) {
                        NavigationLink {
                            ViewerLiveView(record: record, services: services)
                        } label: {
                            Text("Watch \(record.displayName)")
                        }
                        .buttonStyle(
                            KCPrimaryButtonStyle(
                                tint: Theme.Palette.periwinkle,
                                foreground: Theme.onAccent(for: .viewer)
                            )
                        )

                        NavigationLink {
                            ViewerScanView(services: services)
                        } label: {
                            Text("Scan another Camera")
                        }
                        .buttonStyle(KCGhostButtonStyle())
                    } else {
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
                    }

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

    /// The last alert this device was able to open.
    ///
    /// A push that arrives while the app is closed is displayed by iOS with the
    /// server's generic text, because the server cannot read the event either.
    /// This row is the decrypted version, available from the moment the app is
    /// open (`PushNotificationCoordinator`).
    private func latestAlert(_ decoded: DecodedEvent) -> some View {
        KCCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Palette.periwinkle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(EventAlert.body(for: decoded.event))
                        .font(Theme.Typography.body)
                    Text(decoded.event.date.formatted(date: .omitted, time: .shortened))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                }
            }
        }
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
