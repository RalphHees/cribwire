import CribWireKit
import SwiftUI
import UIKit

/// Camera side of pairing: shows the QR, counts down to the next code, and moves
/// to SAS confirmation when a Viewer claims the pairing (`ios-app.md` §2.2).
@MainActor
struct CameraPairingView: View {
    @StateObject private var captureMonitor = ScreenCaptureMonitor()
    @StateObject private var model: CameraPairingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
        _model = StateObject(wrappedValue: CameraPairingViewModel(services: services))
    }

    var body: some View {
        KCScreen {
            VStack(spacing: 0) {
                KCStepDots(total: 3, completed: stepsCompleted)
                    .padding(.bottom, 16)

                switch model.state {
                case .claimed(let claimed):
                    SASConfirmationView(
                        code: claimed.sasCode,
                        role: .camera,
                        style: .cameraAcknowledgement,
                        onConfirm: { model.confirmSAS() },
                        onCancel: { model.stop(); dismiss() }
                    )

                case .active:
                    pairedConfirmation

                case .failed(let failure):
                    failureView(failure)

                default:
                    qrSection
                }
            }
            .padding(.vertical, 20)
        }
        .navigationTitle("Pair a Viewer")
        .navigationBarTitleDisplayMode(.inline)
        // Pairing is where this device registers its APNs token, so it is also
        // where asking for notification permission makes sense — a Camera needs
        // it for its own low-battery alerts.
        .task {
            await services.notifications.requestAuthorization()
            model.start()
        }
        .onDisappear { model.stop() }
    }

    private var stepsCompleted: Int {
        switch model.state {
        case .idle, .generating: return 1
        case .displaying: return 2
        case .claimed, .active, .failed: return 3
        }
    }

    // MARK: - QR

    private var qrSection: some View {
        VStack(spacing: 0) {
            Text("Open CribWire on the other iPhone, choose **Viewer**, and scan this code.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)

            qrCard
                .padding(.bottom, 14)

            countdown

            localOnlyToggle
                .padding(.top, 18)

            if let errorMessage = model.errorMessage {
                KCInlineError(message: errorMessage)
                    .padding(.top, 16)
            }

            Spacer(minLength: 20)

            KCSecurityNote(
                text: "This code contains your encryption key. Anyone who scans it can watch the stream — only show it to people in the room with you."
            )
        }
    }

    /// Offered before a code is claimed, and only then: the choice changes what
    /// the QR contains, so switching afterwards would invalidate it.
    @ViewBuilder
    private var localOnlyToggle: some View {
        if model.isDisplayingQRCode {
            KCCard {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: localOnlyBinding) {
                        Text("Local network only")
                            .font(Theme.Typography.callout.weight(.semibold))
                    }
                    .tint(Theme.Palette.coral)

                    Text("Pair and stream over Wi-Fi with no server at all. Nothing leaves your home — but alerts cannot reach a Viewer that is out of the house.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Flipping the switch restarts pairing, because the mode is baked into the
    /// code on screen.
    private var localOnlyBinding: Binding<Bool> {
        Binding(
            get: { model.isLocalOnly },
            set: { newValue in
                guard newValue != model.isLocalOnly else { return }
                model.stop()
                model.isLocalOnly = newValue
                model.start()
            }
        )
    }

    @ViewBuilder
    private var qrCard: some View {
        if captureMonitor.isCaptured {
            // Screen recording / mirroring is active: the code would be captured
            // along with the key it carries.
            VStack(spacing: 12) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.Palette.warning)
                Text("Screen recording is on")
                    .font(Theme.Typography.title)
                Text("The pairing code is hidden while the screen is being recorded or mirrored. Stop the recording to continue.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(width: 282, height: 282)
            .background(
                Theme.Palette.surface,
                in: RoundedRectangle(cornerRadius: Theme.Metrics.largeCardRadius)
            )
            .accessibilityElement(children: .combine)
        } else if let urlString = model.qrURLString {
            SecureCaptureContainer {
                qrImage(for: urlString)
            }
            .frame(width: 282, height: 282)
            .accessibilityLabel("Pairing QR code")
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.Palette.coral)
                .frame(width: 282, height: 282)
                .background(
                    Theme.Palette.surface,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.largeCardRadius)
                )
        }
    }

    @ViewBuilder
    private func qrImage(for urlString: String) -> some View {
        if let image = QRCodeRenderer.makeImage(
            from: urlString,
            pointSize: 238,
            displayScale: displayScale
        ) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 238, height: 238)
                .padding(22)
                .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.Metrics.largeCardRadius))
        } else {
            KCInlineError(message: String(localized: "Could not draw the pairing code."))
        }
    }

    private var countdown: some View {
        Group {
            if model.isDisplayingQRCode {
                HStack(spacing: 4) {
                    Text("New code in")
                    Text(formattedCountdown)
                        .font(Theme.Typography.monospacedDigits(size: 14, weight: .bold))
                        .foregroundStyle(Theme.Palette.text)
                }
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textMuted)
            }
        }
        .accessibilityLabel("New code in \(model.secondsUntilRegeneration) seconds")
    }

    private var formattedCountdown: String {
        let seconds = model.secondsUntilRegeneration
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Terminal states

    private var pairedConfirmation: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(Theme.Palette.live)
            Text("Viewer paired")
                .font(Theme.Typography.title)
            Text("This Viewer can now watch the stream and receive alerts.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(KCPrimaryButtonStyle())
        }
    }

    private func failureView(_ failure: PairingFailure) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.Palette.warning)
            Text(title(for: failure))
                .font(Theme.Typography.title)
                .multilineTextAlignment(.center)
            Text(explanation(for: failure))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Show a new code") { model.start() }
                .buttonStyle(KCPrimaryButtonStyle())
            Button("Back") { dismiss() }
                .buttonStyle(KCGhostButtonStyle())
        }
    }

    private func title(for failure: PairingFailure) -> String {
        switch failure {
        case .expired: return String(localized: "The code expired")
        case .cancelled: return String(localized: "Pairing cancelled")
        case .viewerLimitReached: return String(localized: "Viewer limit reached")
        case .sasMismatch: return String(localized: "Codes did not match")
        case .invalidQRCode: return String(localized: "That code was not a CribWire code")
        case .backend: return String(localized: "Could not reach the server")
        }
    }

    private func explanation(for failure: PairingFailure) -> String {
        switch failure {
        case .expired:
            return String(localized: "Pairing codes are only valid for ten minutes. Show a new one and scan it with the Viewer.")
        case .cancelled:
            return String(localized: "Nothing was saved.")
        case .viewerLimitReached:
            return String(localized: "A Camera can have at most five Viewers. Revoke one first.")
        case .sasMismatch:
            return String(localized: "Someone may be interfering with the pairing. Start again with a fresh code.")
        case .invalidQRCode:
            return String(localized: "Show a new code and try again.")
        case .backend(let message):
            return message
        }
    }
}
