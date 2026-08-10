import AVFoundation
import KidsCamKit
import SwiftUI
import UIKit

/// Viewer side of pairing: scan the Camera's QR, claim the pairing, compare the
/// SAS, and only then store the keys.
@MainActor
struct ViewerScanView: View {
    @StateObject private var model: ViewerPairingViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)

    init(services: AppServices) {
        _model = StateObject(wrappedValue: ViewerPairingViewModel(services: services))
    }

    var body: some View {
        KCScreen {
            VStack(spacing: 0) {
                KCStepDots(total: 3, completed: stepsCompleted, tint: Theme.Palette.periwinkle)
                    .padding(.bottom, 16)

                switch model.state {
                case .confirmingSAS(let confirming):
                    SASConfirmationView(
                        code: confirming.sasCode,
                        role: .viewer,
                        onConfirm: { model.confirmSAS() },
                        onCancel: { model.rejectSAS() }
                    )

                case .claiming:
                    claimingView

                case .active:
                    pairedConfirmation

                case .failed(let failure):
                    failureView(failure)

                default:
                    scannerSection
                }
            }
            .padding(.vertical, 20)
        }
        .navigationTitle("Scan the Camera")
        .navigationBarTitleDisplayMode(.inline)
        .task { await requestCameraAccessIfNeeded() }
        .onDisappear { model.cancel() }
    }

    private var stepsCompleted: Int {
        switch model.state {
        case .idle, .scanning: return 1
        case .claiming: return 2
        case .confirmingSAS, .active, .failed: return 3
        }
    }

    // MARK: - Scanner

    @ViewBuilder
    private var scannerSection: some View {
        VStack(spacing: 0) {
            Text("Point this iPhone at the QR code shown on the Camera device.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)

            viewfinder
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.largeCardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metrics.largeCardRadius)
                        .strokeBorder(Theme.Palette.line, lineWidth: 1)
                )

            if let hint = model.scanHint {
                KCInlineError(message: hint)
                    .padding(.top, 16)
            }

            Spacer(minLength: 20)

            KCSecurityNote(
                text: "Scanning the code is what makes this device trusted. The key never travels through our servers — only through your camera.",
                symbol: "qrcode.viewfinder",
                tint: Theme.Palette.periwinkle
            )
        }
    }

    @ViewBuilder
    private var viewfinder: some View {
        switch cameraAuthorization {
        case .authorized:
            QRScannerView { payload in
                model.handleScannedString(payload)
            }
        case .notDetermined:
            placeholder(
                symbol: "camera.fill",
                title: "Camera access needed",
                message: "KidsCam needs the camera to scan the pairing code."
            )
        default:
            VStack(spacing: 12) {
                placeholder(
                    symbol: "camera.fill",
                    title: "Camera access is off",
                    message: "Turn on camera access for KidsCam in Settings to scan the pairing code."
                )
                Button("Open Settings") { openSettings() }
                    .buttonStyle(
                        KCPrimaryButtonStyle(
                            tint: Theme.Palette.periwinkle,
                            foreground: Theme.onAccent(for: .viewer)
                        )
                    )
                    .padding(.horizontal, 24)
            }
        }
    }

    private func placeholder(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(Theme.Palette.periwinkle)
            Text(title).font(Theme.Typography.title)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.surface)
    }

    // MARK: - Other states

    private var claimingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(Theme.Palette.periwinkle)
            Text("Pairing…")
                .font(Theme.Typography.title)
            Text("Checking with the Camera. This takes a moment.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var pairedConfirmation: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(Theme.Palette.live)
            Text("Paired")
                .font(Theme.Typography.title)
            Text("You can now watch this Camera and receive its alerts.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(
                    KCPrimaryButtonStyle(
                        tint: Theme.Palette.periwinkle,
                        foreground: Theme.onAccent(for: .viewer)
                    )
                )
        }
    }

    private func failureView(_ failure: PairingFailure) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: failure == .sasMismatch ? "hand.raised.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(failure == .sasMismatch ? Theme.Palette.danger : Theme.Palette.warning)
            Text(title(for: failure))
                .font(Theme.Typography.title)
                .multilineTextAlignment(.center)
            Text(explanation(for: failure))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Scan again") { model.start() }
                .buttonStyle(
                    KCPrimaryButtonStyle(
                        tint: Theme.Palette.periwinkle,
                        foreground: Theme.onAccent(for: .viewer)
                    )
                )
                .padding(.bottom, 12)
            Button("Back") { dismiss() }
                .buttonStyle(KCGhostButtonStyle())
        }
    }

    private func title(for failure: PairingFailure) -> String {
        switch failure {
        case .expired: return "That code is no longer valid"
        case .cancelled: return "Pairing cancelled"
        case .viewerLimitReached: return "This Camera is full"
        case .sasMismatch: return "Codes did not match"
        case .invalidQRCode: return "Not a KidsCam code"
        case .backend: return "Could not reach the server"
        }
    }

    private func explanation(for failure: PairingFailure) -> String {
        switch failure {
        case .expired:
            return "Pairing codes expire after ten minutes. Ask the Camera to show a fresh one."
        case .cancelled:
            return "Nothing was saved on this device."
        case .viewerLimitReached:
            return "A Camera can have at most five Viewers. Remove one on the Camera first."
        case .sasMismatch:
            return "Nothing was saved. Different codes can mean someone is interfering with the pairing — start again with a fresh code, in the same room."
        case .invalidQRCode:
            return "Scan the code shown by KidsCam on the Camera device."
        case .backend(let message):
            return message
        }
    }

    // MARK: - Permissions

    private func requestCameraAccessIfNeeded() async {
        if cameraAuthorization == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        }
        if cameraAuthorization == .authorized {
            model.start()
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
