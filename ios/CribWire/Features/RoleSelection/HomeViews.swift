import CribWireKit
import SwiftUI
import UIKit

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

/// Viewer home: watch a paired Camera, and act on the alerts it sends.
struct ViewerHomeView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var notifications: PushNotificationCoordinator

    var body: some View {
        NavigationStack {
            KCScreen {
                VStack(spacing: Theme.Metrics.stackSpacing) {
                    header

                    if notificationsAreBlocked {
                        notificationsBlockedCard
                    }

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
            // A tapped alert should land on the Camera that raised it, not on a
            // list. The coordinator resolves the push to a pairing id; this turns
            // that into the live view, and clears it so the same tap cannot
            // re-navigate later.
            .navigationDestination(isPresented: alertDestination) {
                if let record = alertedCamera {
                    ViewerLiveView(record: record, services: services)
                } else {
                    unknownPairingView
                }
            }
        }
    }

    /// Presented while a tapped alert is waiting to be opened. Setting it back to
    /// `false` — swiping back, or dismissing — clears the pending id, so the same
    /// tap cannot re-navigate later.
    ///
    /// `navigationDestination(item:)` would say this more directly but is iOS 17,
    /// and CribWire targets 16.
    private var alertDestination: Binding<Bool> {
        Binding(
            get: { notifications.pendingPairingID != nil },
            set: { isPresented in
                if !isPresented { notifications.pendingPairingID = nil }
            }
        )
    }

    private var alertedCamera: PairingRecord? {
        guard let pairingID = notifications.pendingPairingID else { return nil }
        return services.pairings.first {
            $0.id == pairingID && $0.localRole == .viewer
        }
    }

    /// The alert named a pairing this device no longer holds — revoked here, or
    /// wiped and not re-paired. Better than a blank screen or a silent no-op.
    private var unknownPairingView: some View {
        KCScreen {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.Palette.textFaint)
                Text("That camera is not paired")
                    .font(Theme.Typography.title)
                Text("The alert came from a pairing this device no longer has. Scan the Camera again to watch it.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }

    // MARK: - Notification permission

    /// iOS shows the permission prompt once. After a denial the only route back
    /// is Settings, so the Viewer has to be told — a baby monitor whose alerts are
    /// silently switched off is the worst failure this app has.
    private var notificationsAreBlocked: Bool {
        notifications.authorizationStatus == .denied
    }

    private var notificationsBlockedCard: some View {
        KCCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "bell.slash.fill")
                        .foregroundStyle(Theme.Palette.warning)
                    Text("Alerts are turned off")
                        .font(Theme.Typography.callout.weight(.semibold))
                        .foregroundStyle(Theme.Palette.text)
                }
                Text("This device will not tell you when the Camera hears or sees something. You can still watch the live view.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn alerts on in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(Theme.Typography.callout.weight(.semibold))
                .foregroundStyle(Theme.Palette.periwinkle)
            }
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
