import KidsCamKit
import SwiftUI

/// First launch: pick Camera or Viewer. No account, no sign-up — identity comes
/// entirely from the QR pairing (`ios-app.md` §2.1).
struct RoleSelectionView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        KCScreen {
            VStack(spacing: 0) {
                header
                Spacer(minLength: 24)
                Text("USE THIS DEVICE AS")
                    .font(.system(size: 14, weight: .semibold))
                    .kerning(1)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .padding(.bottom, 14)

                KCRoleCard(
                    role: .camera,
                    title: "Camera",
                    subtitle: "Place in the child's room. Streams video & audio and detects noise or movement.",
                    symbol: "video.fill"
                ) {
                    services.role = .camera
                }
                .padding(.bottom, 16)

                KCRoleCard(
                    role: .viewer,
                    title: "Viewer",
                    subtitle: "Keep with you. Watch the live stream and receive alerts on your lock screen.",
                    symbol: "eye.fill"
                ) {
                    services.role = .viewer
                }

                Spacer(minLength: 24)

                Text("You can switch roles later in Settings.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.textFaint)
                    .padding(.bottom, 8)
            }
            .padding(.vertical, 24)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "video.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        LinearGradient(
                            colors: [Theme.Palette.coral, Color(hex: 0xE0639A)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                Text("KidsCam")
                    .font(Theme.Typography.display)
            }
            .padding(.top, 26)

            Text("A private baby monitor from two iPhones.\nEnd-to-end encrypted, no account needed.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    RoleSelectionView().environmentObject(AppServices())
}
