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

    @State private var grabber = VideoFrameGrabber()
    @State private var isAudioOnly = false
    @State private var toast: String?

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
                statusPill
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
        .task { engine.start() }
        .onDisappear { engine.stop() }
        .onChange(of: scenePhase) { phase in
            // Backgrounding tears the stream down rather than holding a camera
            // and a relay open behind a locked screen. Alerts still arrive by
            // push, which is the point of the Camera doing detection itself.
            if phase == .background { engine.stop() }
        }
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
            return engine.statusDetail ?? "Reconnecting…"
        case .connected:
            // Connected but not yet verified: the fingerprint check is the last
            // step before any pixel is shown.
            return "Verifying the connection is private…"
        default:
            return "Connecting to \(record.displayName)…"
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

            controlButton(
                systemName: "camera.fill",
                label: "Snapshot",
                isActive: false,
                isEnabled: engine.isVerified && !isAudioOnly
            ) {
                saveSnapshot()
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .padding(.vertical, 18)
        .background(Theme.Palette.background)
    }

    private func controlButton(
        systemName: String,
        label: String,
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
        .accessibilityLabel(label)
    }

    // MARK: - Status

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
            case .good: return "Good"
            case .fair: return "Fair"
            case .poor: return "Poor"
            case .unknown: return "Live"
            }
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .failed: return "Offline"
        case .idle: return "Idle"
        }
    }

    // MARK: - Snapshot

    /// Saves the current frame to the photo library.
    ///
    /// Add-only authorisation: CribWire writes one image and never reads the
    /// library, so it asks for `.addOnly` rather than full access.
    private func saveSnapshot() {
        guard let image = grabber.snapshot() else {
            show("No frame to save yet.")
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            Task { @MainActor in
                guard status == .authorized || status == .limited else {
                    show("CribWire needs permission to save photos.")
                    return
                }
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                show("Saved to Photos")
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
