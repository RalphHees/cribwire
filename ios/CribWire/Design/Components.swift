import CribWireKit
import SwiftUI

// MARK: - Screen scaffold

/// Every CribWire screen sits on the same night background with the same padding.
///
/// On a wide screen the content is centred inside `Theme.Metrics.readableWidth`
/// rather than stretched edge to edge. A full-width iPad column turns a
/// two-sentence security note into one very long line, which is exactly the text
/// a user most needs to actually read.
struct KCScreen<Content: View>: View {
    var horizontalPadding: CGFloat = Theme.Metrics.screenPadding
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
            content()
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: Theme.Metrics.readableWidth)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Theme.Palette.text)
    }
}

// MARK: - Card

struct KCCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.Metrics.cardRadius
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(Theme.Metrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.Palette.line, lineWidth: 1)
            )
    }
}

// MARK: - Buttons

struct KCPrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.Palette.coral
    var foreground: Color = Theme.Palette.onCoral

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.button)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(foreground)
            .background(tint, in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct KCGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.button)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(Theme.Palette.text)
            .background(
                Theme.Palette.surfaceRaised,
                in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Progress dots

/// The three-step pairing indicator from the mockups.
struct KCStepDots: View {
    let total: Int
    let completed: Int
    var tint: Color = Theme.Palette.coral

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index < completed ? tint : Theme.Palette.surfaceRaised)
                    .frame(width: 26, height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(min(completed, total)) of \(total)")
    }
}

// MARK: - Status pill

struct KCPill: View {
    let title: LocalizedStringKey
    var tint: Color = Theme.Palette.live
    var showsDot = true

    var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Circle().fill(tint).frame(width: 7, height: 7)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(tint)
        .background(tint.opacity(0.15), in: Capsule())
    }
}

// MARK: - Security note

/// The "trust made visible" card: a lock glyph plus a plain-words statement of
/// the security property of the screen it sits on.
struct KCSecurityNote: View {
    let text: LocalizedStringKey
    var symbol = "lock.fill"
    var tint: Color = Theme.Palette.live

    var body: some View {
        KCCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                Text(text)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - SAS digits

/// The 6-digit confirmation code, rendered as two groups of three so the eye can
/// compare the two screens quickly.
struct KCSASDigits: View {
    let code: SASCode
    var tint: Color = Theme.Palette.periwinkle

    var body: some View {
        let groups = code.groupedForDisplay
        return HStack(spacing: 10) {
            digitGroup(groups.leading)
            Spacer().frame(width: 12)
            digitGroup(groups.trailing)
        }
        .accessibilityElement(children: .ignore)
        // Read out digit by digit; "358946" as a number is useless when
        // comparing two screens.
        .accessibilityLabel(
            Text(code.digits.map(String.init).joined(separator: " "))
        )
    }

    private func digitGroup(_ digits: String) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(digits.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .font(Theme.Typography.monospacedDigits(size: 30, weight: .heavy))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 60)
                    .background(
                        Theme.Palette.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Theme.Palette.line, lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Role card

/// The tappable Camera / Viewer card on the first-launch screen.
struct KCRoleCard: View {
    let role: PairingRole
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(Theme.accent(for: role))
                        .frame(width: 58, height: 58)
                        .background(
                            Theme.accent(for: role).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 18)
                        )
                        .padding(.bottom, 6)

                    Text(title)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.text)
                    Text(subtitle)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.Palette.textFaint)
                    .padding(.top, 20)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Theme.Palette.surface,
                in: RoundedRectangle(cornerRadius: Theme.Metrics.largeCardRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.largeCardRadius)
                    .strokeBorder(Theme.Palette.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

// MARK: - Inline error

struct KCInlineError: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.warning)
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.Palette.warning.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }
}

// MARK: - Masking

extension View {
    /// Punches `mask` out of the receiver — the inverse of `.mask`.
    ///
    /// Used to dim everything *outside* the movement watch area, which is the
    /// clearest way to show what is not being watched.
    func reverseMask<Mask: View>(
        alignment: Alignment = .topLeading,
        @ViewBuilder _ mask: () -> Mask
    ) -> some View {
        self.mask(
            ZStack(alignment: alignment) {
                Rectangle()
                mask()
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}
