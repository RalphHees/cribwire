import CribWireKit
import SwiftUI

/// The short-authentication-string screen shown on both devices
/// (`security.md` §3.3).
///
/// This is the step that defeats a QR substitution or shoulder-scan attack: the
/// code is derived from `K_sas`, which only the two devices that share the root
/// secret can compute. The user compares the two screens; the Viewer's tap is
/// what activates the pairing.
struct SASConfirmationView: View {

    enum Style {
        /// Viewer: the tap that completes the pairing.
        case viewerConfirmation
        /// Camera: informational — it shows the same digits so the user has
        /// something to compare against.
        case cameraAcknowledgement
    }

    let code: SASCode
    let role: PairingRole
    var style: Style = .viewerConfirmation
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            Image(systemName: "checkmark.circle")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.Palette.live)
                .frame(width: 64, height: 64)
                .background(Theme.Palette.live.opacity(0.14), in: Circle())
                .padding(.bottom, 18)

            Text("Both devices should show\nthe same code:")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)

            KCSASDigits(code: code, tint: Theme.accent(for: role))
                .padding(.vertical, 20)

            Text("If the codes differ, someone may be\ninterfering — cancel and rescan.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textFaint)
                .multilineTextAlignment(.center)

            Spacer(minLength: 24)

            Button(confirmTitle, action: onConfirm)
                .buttonStyle(
                    KCPrimaryButtonStyle(
                        tint: Theme.accent(for: role),
                        foreground: Theme.onAccent(for: role)
                    )
                )
                .padding(.bottom, 12)

            Button(cancelTitle, action: onCancel)
                .buttonStyle(KCGhostButtonStyle())
        }
    }

    private var confirmTitle: String {
        switch style {
        case .viewerConfirmation: return "Codes match — Pair"
        case .cameraAcknowledgement: return "Codes match"
        }
    }

    private var cancelTitle: String {
        switch style {
        case .viewerConfirmation: return "Cancel"
        case .cameraAcknowledgement: return "Stop pairing"
        }
    }
}

#Preview {
    KCScreen {
        SASConfirmationView(
            code: SASCode(digits: "482913"),
            role: .viewer,
            onConfirm: {},
            onCancel: {}
        )
    }
}
