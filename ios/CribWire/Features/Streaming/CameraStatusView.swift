import Foundation
import CribWireKit
import SwiftUI
import UIKit

/// The Camera's running screen (`ios-app.md` §3, §5).
///
/// This is the screen that sits face-down on a shelf all night, so almost every
/// decision here is about the device surviving until morning:
///
/// - **Dimming** — a tap blacks the screen out and drops the backlight. The
///   display is the single largest battery draw on a phone that is otherwise
///   just encoding video.
/// - **Idle timer disabled** — iOS must not lock the device, or capture stops.
/// - **Battery warnings** — an unplugged Camera is the most common way a night's
///   monitoring fails, so it is called out early and loudly rather than at 5 %.
/// - **Guided Access** — the instructions are here because a phone left in a
///   nursery gets picked up, and Guided Access is what stops a curious toddler
///   swiping out of the app.
@MainActor
struct CameraStatusView: View {

    @StateObject private var engine: StreamingEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var isDimmed = false
    @State private var isMicrophoneOn = true
    @State private var showGuidedAccessHelp = false
    @State private var batteryLevel = UIDevice.current.batteryLevel
    @State private var batteryState = UIDevice.current.batteryState
    /// Restored when the screen goes away, so dimming never leaks into the rest
    /// of the system.
    @State private var previousBrightness = UIScreen.main.brightness

    private let record: PairingRecord

    init(record: PairingRecord, services: AppServices) {
        self.record = record
        _engine = StateObject(wrappedValue: StreamingEngine(record: record, services: services))
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
            content
            if isDimmed { dimOverlay }
        }
        .navigationTitle("Camera")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarHidden(isDimmed)
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.isBatteryMonitoringEnabled = true
            refreshBattery()
            engine.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            UIScreen.main.brightness = previousBrightness
            engine.stop()
        }
        .onChange(of: scenePhase) { phase in
            // Coming back from the background: re-assert the idle timer, which
            // iOS resets, and re-read the battery.
            if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = true
                refreshBattery()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIDevice.batteryLevelDidChangeNotification
            )
        ) { _ in refreshBattery() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIDevice.batteryStateDidChangeNotification
            )
        ) { _ in refreshBattery() }
        .sheet(isPresented: $showGuidedAccessHelp) { guidedAccessSheet }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(spacing: Theme.Metrics.stackSpacing) {
                preview
                statusCard
                if let warning = batteryWarning { batteryCard(warning) }
                controls
                guidedAccessCard
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.vertical, 20)
        }
    }

    private var preview: some View {
        ZStack {
            Color.black
            if engine.capture?.isCapturing == true {
                VideoRenderView(
                    track: engine.capture?.localVideoTrack,
                    contentMode: .scaleAspectFill
                )
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.Palette.textFaint)
                    Text("Camera idle")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                }
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.largeCardRadius))
        .overlay(alignment: .topLeading) {
            if engine.connectedPeerCount > 0 {
                KCPill(title: "LIVE", tint: Theme.Palette.live)
                    .padding(12)
            }
        }
        .accessibilityLabel("Camera preview")
    }

    private var statusCard: some View {
        KCCard {
            VStack(alignment: .leading, spacing: 12) {
                row(
                    label: "Status",
                    value: statusText,
                    tint: engine.state == .connected ? Theme.Palette.live : Theme.Palette.warning
                )
                row(
                    label: "Viewers",
                    value: engine.connectedPeerCount == 0
                        ? "None watching"
                        : "\(engine.connectedPeerCount) watching"
                )
                row(label: "Quality", value: engine.quality.description)
                if engine.connectedPeerCount > 0 {
                    row(
                        label: "Encryption",
                        value: engine.isVerified ? "Verified end-to-end" : "Verifying…",
                        tint: engine.isVerified ? Theme.Palette.live : Theme.Palette.warning
                    )
                }
            }
        }
    }

    private func row(label: String, value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textMuted)
            Spacer()
            Text(value)
                .font(Theme.Typography.callout.weight(.semibold))
                .foregroundStyle(tint ?? Theme.Palette.text)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch engine.state {
        case .idle: return "Stopped"
        case .connecting: return engine.connectedPeerCount > 0 ? "Connecting" : "Waiting for a viewer"
        case .connected: return "Streaming"
        case .reconnecting: return "Reconnecting"
        case .failed(let reason, _): return reason
        }
    }

    // MARK: - Battery

    /// Why an unplugged Camera is about to become a problem, if it is.
    private var batteryWarning: String? {
        guard batteryState != .charging, batteryState != .full else { return nil }
        guard batteryLevel >= 0 else { return nil }
        let percent = Int(batteryLevel * 100)
        if percent <= 20 {
            return "Battery is at \(percent)%. Plug the Camera in now — it will stop streaming when it dies."
        }
        if percent <= 50 {
            return "Battery is at \(percent)% and not charging. A night of streaming needs mains power."
        }
        return "This Camera is not charging. Streaming all night will drain the battery."
    }

    private func batteryCard(_ message: String) -> some View {
        KCCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "battery.25")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.Palette.warning)
                Text(message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refreshBattery() {
        batteryLevel = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    isMicrophoneOn.toggle()
                    engine.setMicrophoneEnabled(isMicrophoneOn)
                } label: {
                    Label(
                        isMicrophoneOn ? "Mic on" : "Mic off",
                        systemImage: isMicrophoneOn ? "mic.fill" : "mic.slash.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(KCGhostButtonStyle())

                Button {
                    engine.flipCamera()
                } label: {
                    Label("Flip", systemImage: "arrow.triangle.2.circlepath.camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KCGhostButtonStyle())
            }

            Button {
                dim()
            } label: {
                Label("Dim the screen", systemImage: "moon.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KCPrimaryButtonStyle())
        }
    }

    // MARK: - Dimming

    private func dim() {
        previousBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        withAnimation { isDimmed = true }
    }

    private func undim() {
        UIScreen.main.brightness = previousBrightness
        withAnimation { isDimmed = false }
    }

    /// Full-screen black with one hint. Streaming continues underneath: only the
    /// display is off, which is the point.
    private var dimOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                VStack(spacing: 6) {
                    Text(engine.connectedPeerCount > 0 ? "Streaming" : "Camera on")
                        .font(Theme.Typography.caption)
                    Text("Tap to wake the screen")
                        .font(Theme.Typography.caption)
                }
                .foregroundStyle(Theme.Palette.textFaint)
                .padding(.bottom, 40)
            }
            .contentShape(Rectangle())
            .onTapGesture { undim() }
            .accessibilityLabel("Screen dimmed. Double tap to wake.")
    }

    // MARK: - Guided Access

    private var guidedAccessCard: some View {
        Button {
            showGuidedAccessHelp = true
        } label: {
            KCCard {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.Palette.periwinkle)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Lock this phone to CribWire")
                            .font(Theme.Typography.callout.weight(.semibold))
                            .foregroundStyle(Theme.Palette.text)
                        Text("Set up Guided Access so the app cannot be closed by accident.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textFaint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var guidedAccessSheet: some View {
        NavigationStack {
            KCScreen {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Guided Access keeps this phone on CribWire until you enter a passcode — useful when the Camera is left in a room with a child.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(guidedAccessSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(Theme.Typography.callout.weight(.bold))
                                .foregroundStyle(Theme.Palette.onCoral)
                                .frame(width: 26, height: 26)
                                .background(Theme.Palette.coral, in: Circle())
                            Text(step)
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Palette.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer()

                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(KCPrimaryButtonStyle())
                }
                .padding(.vertical, 20)
            }
            .navigationTitle("Guided Access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showGuidedAccessHelp = false }
                }
            }
        }
    }

    private var guidedAccessSteps: [String] {
        [
            "Open Settings → Accessibility → Guided Access and turn it on.",
            "Set a Guided Access passcode you will remember.",
            "Come back to CribWire and triple-click the side button.",
            "Tap Start. Triple-click again and enter the passcode to leave.",
        ]
    }
}
