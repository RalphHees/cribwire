import Foundation
import CribWireKit
import Photos
import SwiftUI
import UIKit

/// The Viewer's live screen (`ios-app.md` §3).
///
/// One rule shapes the whole layout: **video is shown only once the connection
/// has been cryptographically verified.** Until `isVerified` is true the frame
/// stays covered, because an unverified stream is exactly what a
/// man-in-the-middle would be able to produce, and a parent glancing at a phone
/// cannot be expected to check a badge before believing what they see.
@MainActor
struct ViewerLiveView: View {

    @StateObject private var engine: StreamingEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var notifications: PushNotificationCoordinator

    @State private var grabber = VideoFrameGrabber()
    @StateObject private var pip = PictureInPictureController()
    @State private var isAudioOnly = false
    @State private var toast: String?
    @State private var liveActivity = LiveActivityController()
    @State private var showRoomControls = false

    private let record: PairingRecord

    init(record: PairingRecord, services: AppServices) {
        self.record = record
        _engine = StateObject(wrappedValue: StreamingEngine(record: record, services: services))
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                videoArea
                controls
            }
        }
        .navigationTitle(record.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    cameraBatteryPill
                    statusPill
                }
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Theme.Palette.surfaceRaised,
                        in: Capsule()
                    )
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showRoomControls) { roomControlsSheet }
        .task {
            engine.start()
            liveActivity.start(cameraName: record.displayName, state: activityState)
        }
        .onDisappear {
            liveActivity.end()
            pip.teardown()
            engine.stop()
        }
        // Connection changes are worth showing at once; the throttle inside the
        // controller keeps the routine battery ticks from burning the budget.
        .onChange(of: engine.state) { _ in
            liveActivity.update(activityState, force: true)
        }
        .onChange(of: engine.peerBatteryLevel) { _ in
            liveActivity.update(activityState)
        }
        .onChange(of: notifications.latestEvent?.event.ts) { _ in
            liveActivity.update(activityState, force: true)
        }
        // The PiP converter has to follow the track across reconnects, which
        // produce a brand-new track object.
        .onChange(of: engine.remoteVideoTrack) { track in
            pip.attach(track: track)
        }
        .onChange(of: scenePhase) { phase in
            // Backgrounding tears the stream down rather than holding a camera
            // and a relay open behind a locked screen — unless PiP is running,
            // which is precisely a request to keep watching while doing something
            // else. Alerts still arrive by push either way, which is the point of
            // the Camera doing detection itself.
            if phase == .background && !pip.isActive { engine.stop() }
            // A call that ended while the app was away never delivered its
            // resume notification, so the audio would stay silent.
            if phase == .active { engine.recoverFromInterruptionIfNeeded() }
        }
    }

    /// The Lock Screen's view of what this screen is doing.
    private var activityState: CribWireActivityAttributes.ContentState {
        let connection: CribWireActivityAttributes.ContentState.Connection
        switch engine.state {
        // "Watching" means verified, not merely connected: an unverified stream
        // is not something to reassure anyone about.
        case .connected: connection = engine.isVerified ? .watching : .connecting
        case .connecting: connection = .connecting
        case .reconnecting: connection = .reconnecting
        case .idle, .failed: connection = .stopped
        }
        return .init(
            connection: connection,
            batteryLevel: engine.peerBatteryLevel,
            isCharging: engine.isPeerCharging,
            lastAlertAt: notifications.latestEvent?.event.date
        )
    }

    // MARK: - Video

    @ViewBuilder
    private var videoArea: some View {
        ZStack {
            Color.black

            if case .failed(let reason, let isSecurity) = engine.state {
                failure(reason: reason, isSecurity: isSecurity)
            } else if engine.isVerified && !isAudioOnly {
                VideoRenderView(track: engine.remoteVideoTrack, grabber: grabber)
                // Required by AVKit: PiP cannot start from a layer that is not in
                // the hierarchy. Invisible, and never what the user is looking at.
                PictureInPictureLayerHost(controller: pip)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            } else if engine.isVerified && isAudioOnly {
                audioOnlyPlaceholder
            } else {
                connecting
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var connecting: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.Palette.periwinkle)
            Text(connectingCaption)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var connectingCaption: String {
        switch engine.state {
        case .reconnecting:
            return engine.statusDetail ?? String(localized: "Reconnecting…")
        case .connected:
            // Connected but not yet verified: the fingerprint check is the last
            // step before any pixel is shown.
            return String(localized: "Verifying the connection is private…")
        default:
            return String(localized: "Connecting to \(record.displayName)…")
        }
    }

    private var audioOnlyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 44))
                .foregroundStyle(Theme.Palette.periwinkle)
            Text("Audio only")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.text)
            Text("Video is paused to save data and battery.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textMuted)
        }
    }

    private func failure(reason: String, isSecurity: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: isSecurity ? "exclamationmark.shield.fill" : "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(isSecurity ? Theme.Palette.danger : Theme.Palette.warning)
            Text(isSecurity ? "Connection not private" : "Could not connect")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.text)
            Text(reason)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
            if !isSecurity {
                Button("Try again") {
                    engine.stop()
                    engine.start()
                }
                .buttonStyle(KCPrimaryButtonStyle())
                .padding(.horizontal, 32)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            talkButton
            controlRow
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.vertical, 18)
        // Video fills the screen on an iPad; the controls do not need to be a
        // metre apart to be reachable.
        .frame(maxWidth: Theme.Metrics.readableWidth)
        .frame(maxWidth: .infinity)
        .background(Theme.Palette.background)
    }

    /// Push-to-talk. Held, never toggled — see `StreamingEngine.isTalking`.
    private var talkButton: some View {
        let isEnabled = engine.isVerified
        return Text(engine.isTalking ? "Release to stop" : "Hold to talk")
            .font(Theme.Typography.button)
            .foregroundStyle(engine.isTalking ? Theme.Palette.onCoral : Theme.Palette.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                engine.isTalking ? Theme.Palette.coral : Theme.Palette.surface,
                in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius)
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.5)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, !engine.isTalking else { return }
                        engine.setTalking(true)
                    }
                    .onEnded { _ in engine.setTalking(false) }
            )
            .disabled(!isEnabled)
            .accessibilityLabel(Text("Hold to talk to the camera"))
            .accessibilityAddTraits(.isButton)
    }

    /// Two rows rather than one. Five buttons across an iPhone leaves labels like
    /// "Audio only" at two words a line, which is unreadable at the moment this
    /// screen is actually used.
    private var controlRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                controlButton(
                    systemName: engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    label: engine.isMuted ? "Unmute" : "Mute",
                    isActive: engine.isMuted
                ) {
                    engine.setMuted(!engine.isMuted)
                }

                controlButton(
                    systemName: isAudioOnly ? "video.slash.fill" : "video.fill",
                    label: isAudioOnly ? "Show video" : "Audio only",
                    isActive: isAudioOnly
                ) {
                    isAudioOnly.toggle()
                }

                // Music and light live behind one button rather than on this
                // screen. Four more controls under a video feed is a busier
                // screen than anyone wants at 3 a.m., and this is the one thing
                // here that is reached for deliberately rather than glanced at.
                controlButton(
                    systemName: roomSymbol,
                    label: "Room",
                    isActive: isRoomActive,
                    isEnabled: engine.nurseryState != nil
                ) {
                    showRoomControls = true
                }
            }
            secondaryControlRow
        }
    }

    private var secondaryControlRow: some View {
        HStack(spacing: 12) {
            controlButton(
                systemName: "camera.fill",
                label: "Snapshot",
                isActive: false,
                isEnabled: engine.isVerified && !isAudioOnly
            ) {
                saveSnapshot()
            }

            if PictureInPictureController.isSupported {
                controlButton(
                    systemName: "pip.enter",
                    label: "Mini view",
                    isActive: pip.isActive,
                    isEnabled: pip.isPossible && engine.isVerified && !isAudioOnly
                ) {
                    pip.isActive ? pip.stop() : pip.start()
                }
            } else {
                // Keeps Snapshot the width it is in the row above rather than
                // letting it stretch across the screen on its own.
                Color.clear.frame(maxWidth: .infinity)
            }
        }
    }

    /// The button reflects the room: playing music, or a light left on.
    private var roomSymbol: String {
        guard let state = engine.nurseryState else { return "music.note.house" }
        if state.light.isOn { return "lightbulb.fill" }
        return state.music.isPlaying ? "music.note.list" : "music.note.house"
    }

    private var isRoomActive: Bool {
        guard let state = engine.nurseryState else { return false }
        return state.music.isPlaying || state.light.isOn
    }

    private var roomControlsSheet: some View {
        NavigationStack {
            KCScreen {
                ScrollView {
                    Group {
                        if let state = engine.nurseryState {
                            NurseryControlsView(state: state) { command in
                                engine.send(command)
                            }
                        } else {
                            // Only reachable if the Camera stops reporting while
                            // the sheet is open — a reconnect, usually.
                            Text("Waiting for the camera…")
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Palette.textMuted)
                                .padding(.top, 40)
                        }
                    }
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle(record.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showRoomControls = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func controlButton(
        systemName: String,
        label: LocalizedStringKey,
        isActive: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .medium))
                Text(label)
                    .font(Theme.Typography.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                isActive ? Theme.Palette.surfaceRaised : Theme.Palette.surface,
                in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Theme.Palette.text : Theme.Palette.textFaint)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(label))
    }

    // MARK: - Status

    /// The Camera's battery, once it has reported one.
    ///
    /// Hidden entirely rather than shown as "unknown" while nothing has arrived:
    /// an empty gauge on a baby monitor reads as bad news, and silence here means
    /// "not told yet", not "flat".
    @ViewBuilder
    private var cameraBatteryPill: some View {
        if let level = engine.peerBatteryLevel {
            let percent = Int((level * 100).rounded())
            HStack(spacing: 4) {
                Image(systemName: batterySymbol(for: level))
                    .font(.system(size: 12, weight: .medium))
                Text("\(percent)%")
                    .font(Theme.Typography.caption)
            }
            .foregroundStyle(batteryTint(for: level))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                engine.isPeerCharging
                    ? Text("Camera battery \(percent) percent, charging")
                    : Text("Camera battery \(percent) percent")
            )
        }
    }

    private func batterySymbol(for level: Double) -> String {
        if engine.isPeerCharging { return "battery.100.bolt" }
        switch level {
        case ..<0.15: return "battery.0"
        case ..<0.40: return "battery.25"
        case ..<0.80: return "battery.75"
        default: return "battery.100"
        }
    }

    /// Only an uncharging Camera is worth colouring: plugged in at 8 % is fine,
    /// unplugged at 8 % is the night about to end.
    private func batteryTint(for level: Double) -> Color {
        guard !engine.isPeerCharging else { return Theme.Palette.live }
        switch level {
        case ..<0.15: return Theme.Palette.danger
        case ..<0.30: return Theme.Palette.warning
        default: return Theme.Palette.textMuted
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColour)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection \(statusText)")
    }

    private var statusColour: Color {
        switch engine.state {
        case .connected:
            switch engine.linkQuality {
            case .good, .unknown: return Theme.Palette.live
            case .fair: return Theme.Palette.warning
            case .poor: return Theme.Palette.danger
            }
        case .reconnecting, .connecting: return Theme.Palette.warning
        case .failed: return Theme.Palette.danger
        case .idle: return Theme.Palette.textFaint
        }
    }

    private var statusText: String {
        switch engine.state {
        case .connected:
            switch engine.linkQuality {
            case .good: return String(localized: "Good")
            case .fair: return String(localized: "Fair")
            case .poor: return String(localized: "Poor")
            case .unknown: return String(localized: "Live")
            }
        case .connecting: return String(localized: "Connecting")
        case .reconnecting: return String(localized: "Reconnecting")
        case .failed: return String(localized: "Offline")
        case .idle: return String(localized: "Idle")
        }
    }

    // MARK: - Snapshot

    /// Saves the current frame to the photo library.
    ///
    /// Add-only authorisation: CribWire writes one image and never reads the
    /// library, so it asks for `.addOnly` rather than full access.
    private func saveSnapshot() {
        guard let image = grabber.snapshot() else {
            show(String(localized: "No frame to save yet."))
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            Task { @MainActor in
                guard status == .authorized || status == .limited else {
                    show(String(localized: "CribWire needs permission to save photos."))
                    return
                }
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                show(String(localized: "Saved to Photos"))
            }
        }
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }
}
