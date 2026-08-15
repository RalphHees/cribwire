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
    @EnvironmentObject private var services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var isDimmed = false
    @State private var isMicrophoneOn = true
    @State private var showGuidedAccessHelp = false
    /// Set once asking for music access has been tried and left nothing changed.
    @State private var musicPermissionNeedsSettings = false
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
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the background: re-assert the idle timer, which
            // iOS resets, and re-read the battery.
            if phase == .active {
                UIApplication.shared.isIdleTimerDisabled = true
                refreshBattery()
                // An interruption that ended while the app was in the background
                // never delivered its resume notification.
                engine.recoverFromInterruptionIfNeeded()
                // The alerts screen may have been visited since this one started,
                // so the detectors are re-synced rather than left as they were.
                engine.applyDetectionSettings(services.detectionSettings)
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
                nurseryCard
                controls
                guidedAccessCard
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)
            .padding(.vertical, 20)
            .frame(maxWidth: Theme.Metrics.readableWidth)
            .frame(maxWidth: .infinity)
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
                // Show what the movement detector is actually watching. A region
                // set on the alerts screen is invisible here otherwise, and a
                // camera that has been nudged since is watching the wrong corner
                // with nothing to say about it.
                if movementRegion != nil {
                    WatchAreaOverlay(region: movementRegion ?? .full)
                }
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
                    value: viewersSummary,
                    tint: engine.negotiatingPeerCount > engine.connectedPeerCount
                        ? Theme.Palette.warning
                        : nil
                )
                row(label: "Quality", value: engine.quality.description)
                if engine.negotiatingPeerCount > 0, !engine.isVerified {
                    // Only while a handshake is in flight: once video is running
                    // this is noise, but until then it is the whole diagnosis.
                    row(label: "Connection", value: linkStateText, tint: linkStateTint)
                }
                row(label: "Alerts", value: alertsSummary, tint: alertsTint)
                if engine.connectedPeerCount > 0 {
                    row(
                        label: "Encryption",
                        value: engine.isVerified
                            ? String(localized: "Verified end-to-end")
                            : String(localized: "Verifying…"),
                        tint: engine.isVerified ? Theme.Palette.live : Theme.Palette.warning
                    )
                }
            }
        }
    }

    private func row(label: LocalizedStringKey, value: String, tint: Color? = nil) -> some View {
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
        case .idle: return String(localized: "Stopped")
        case .connecting:
            // A Viewer that has arrived but not finished is the interesting case,
            // and it used to be indistinguishable from an empty room.
            return engine.negotiatingPeerCount > 0
                ? String(localized: "Connecting to a viewer…")
                : String(localized: "Waiting for a viewer")
        case .connected: return String(localized: "Streaming")
        case .reconnecting: return String(localized: "Reconnecting")
        case .failed(let reason, _): return reason
        }
    }

    /// The movement watch area, when movement detection is on and it is not the
    /// whole frame (in which case there is nothing to point out).
    private var movementRegion: DetectionRegion? {
        let movement = services.detectionSettings.movement
        guard movement.isEnabled, !movement.regionOfInterest.isFullFrame else { return nil }
        return movement.regionOfInterest
    }

    /// Where the handshake has got to.
    private var linkStateText: String {
        switch engine.linkState {
        case .new: return String(localized: "Finding a route…")
        case .checking: return String(localized: "Testing the route…")
        case .connected: return String(localized: "Route found")
        case .disconnected: return String(localized: "Route lost")
        case .failed: return String(localized: "No route to the viewer")
        case .closed: return String(localized: "Closed")
        }
    }

    private var linkStateTint: Color? {
        switch engine.linkState {
        case .failed, .disconnected: return Theme.Palette.danger
        case .connected: return Theme.Palette.live
        default: return Theme.Palette.warning
        }
    }

    /// Viewers, distinguishing watching from still-connecting.
    ///
    /// A Camera stuck with one connecting viewer and none watching is the
    /// signature of a handshake that cannot complete — usually a network that
    /// will not let the two devices reach each other — and it should look
    /// different from an idle Camera.
    private var viewersSummary: String {
        let connecting = engine.negotiatingPeerCount - engine.connectedPeerCount
        if engine.connectedPeerCount > 0 {
            return String(localized: "\(engine.connectedPeerCount) watching")
        }
        if connecting > 0 {
            return String(localized: "\(connecting) connecting…")
        }
        return String(localized: "None watching")
    }

    /// What the two detectors are doing, in one line.
    ///
    /// A microphone that could not be opened is called out here rather than left
    /// to look like silence: "noise alerts on" and "noise alerts on but deaf" must
    /// never read the same.
    private var alertsSummary: String {
        if engine.detection?.isNoiseDetectionUnavailable == true {
            return String(localized: "Microphone unavailable")
        }
        let settings = services.detectionSettings
        switch (settings.noise.isEnabled, settings.movement.isEnabled) {
        case (true, true): return String(localized: "Noise and movement")
        case (true, false): return String(localized: "Noise")
        case (false, true): return String(localized: "Movement")
        case (false, false): return String(localized: "Off")
        }
    }

    private var alertsTint: Color? {
        engine.detection?.isNoiseDetectionUnavailable == true ? Theme.Palette.warning : nil
    }

    // MARK: - Battery

    /// Why an unplugged Camera is about to become a problem, if it is.
    private var batteryWarning: String? {
        guard batteryState != .charging, batteryState != .full else { return nil }
        guard batteryLevel >= 0 else { return nil }
        let percent = Int(batteryLevel * 100)
        if percent <= 20 {
            return String(localized: "Battery is at \(percent)%. Plug the Camera in now — it will stop streaming when it dies.")
        }
        if percent <= 50 {
            return String(localized: "Battery is at \(percent)% and not charging. A night of streaming needs mains power.")
        }
        return String(localized: "This Camera is not charging. Streaming all night will drain the battery.")
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
        // Viewers are told at 15 %, once per discharge — `LowBatteryMonitor`
        // owns that rule, so every reading is simply handed to it.
        engine.ingest(
            batteryLevel: Double(batteryLevel),
            isCharging: batteryState == .charging || batteryState == .full
        )
    }

    // MARK: - Music and light

    /// What a Viewer can reach in this room, and the one thing only this phone can
    /// do about it.
    ///
    /// Music permission is the reason this card exists. `MusicAuthorization` is a
    /// system prompt, and a prompt raised by a tap on another device is a prompt
    /// nobody is standing in front of — so no Viewer command can trigger it and it
    /// has to be offered here, on the phone somebody is holding while they set the
    /// camera up.
    @ViewBuilder
    private var nurseryCard: some View {
        if let nursery = engine.nursery, let state = engine.nurseryState {
            KCCard {
                VStack(alignment: .leading, spacing: 12) {
                    row(label: "Music", value: musicSummary(state.music))
                    row(label: "Light", value: lightSummary(state.light))

                    if state.music.availability == .needsPermission {
                        // iOS shows the music permission prompt exactly once. A
                        // second tap on "Allow" after it has been refused does
                        // nothing at all, so once asking has visibly failed the
                        // button becomes the only thing that can still work.
                        if musicPermissionNeedsSettings {
                            Button {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            } label: {
                                Label("Allow music in Settings", systemImage: "gear")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(KCGhostButtonStyle())
                        } else {
                            Button {
                                Task {
                                    let allowed = await nursery.requestMusicAuthorization()
                                    musicPermissionNeedsSettings = !allowed
                                }
                            } label: {
                                Label("Allow music access", systemImage: "music.note")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(KCGhostButtonStyle())
                        }
                    }

                    Text("Whoever is watching can play music here and turn this phone's light on. Only your paired devices can — the controls travel encrypted, like the video.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func musicSummary(_ music: MusicState) -> String {
        switch music.availability {
        case .ready:
            if music.isPlaying {
                return music.nowPlaying ?? String(localized: "Playing")
            }
            return String(localized: "Ready")
        case .needsPermission: return String(localized: "Not allowed yet")
        case .needsSubscription: return String(localized: "No subscription")
        case .notConfigured: return String(localized: "Not set up")
        case .unavailable: return String(localized: "Unavailable")
        case .unknown: return String(localized: "Unknown")
        }
    }

    private func lightSummary(_ light: LightState) -> String {
        switch light.availability {
        case .ready:
            return light.isOn
                ? String(localized: "On at \(Int((light.level * 100).rounded()))%")
                : String(localized: "Off")
        case .cameraIdle: return String(localized: "Available while streaming")
        case .wrongCamera: return String(localized: "Back camera only")
        case .noHardware: return String(localized: "No light on this phone")
        case .unavailable: return String(localized: "Too warm to use")
        case .unknown: return String(localized: "Unknown")
        }
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
