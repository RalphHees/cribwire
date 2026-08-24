import CribWireKit
import SwiftUI

/// The CribWire design language, transcribed from `docs/design/app-screens.html`.
///
/// Night-first: the app is used in dark rooms, so the palette is deep indigo with
/// low-glare surfaces and no pure white. Colour carries meaning — coral is the
/// Camera role and primary actions, periwinkle is the Viewer role, and green is
/// reserved for live/secure states so "encrypted" and "streaming" always read the
/// same way.
enum Theme {

    // MARK: - Palette

    enum Palette {
        /// Page background (`--bg`).
        static let background = Color(hex: 0x0F1220)
        /// Card and control background (`--surface`).
        static let surface = Color(hex: 0x1A1F33)
        /// Raised surface: segmented controls, ghost buttons (`--surface2`).
        static let surfaceRaised = Color(hex: 0x232945)
        /// Hairline borders (`--line`).
        static let line = Color(hex: 0x2E3554)

        static let text = Color(hex: 0xF2F3F8)
        static let textMuted = Color(hex: 0x9AA1B8)
        static let textFaint = Color(hex: 0x6B7290)

        /// Primary actions and the Camera role.
        static let coral = Color(hex: 0xFF9E80)
        /// Text/glyph colour on top of `coral`.
        static let onCoral = Color(hex: 0x3A1408)
        /// The Viewer role and secondary actions.
        static let periwinkle = Color(hex: 0x8E9BFF)
        /// Reserved for live and secure states — never decorative.
        static let live = Color(hex: 0x5AD7A0)
        static let warning = Color(hex: 0xFFD166)
        static let danger = Color(hex: 0xE04444)
    }

    // MARK: - Metrics

    enum Metrics {
        static let screenPadding: CGFloat = 26
        static let cardRadius: CGFloat = 22
        static let largeCardRadius: CGFloat = 26
        static let controlRadius: CGFloat = 16
        static let cardPadding: CGFloat = 20
        static let stackSpacing: CGFloat = 16
        /// Widest a column of text or controls gets, however wide the screen is.
        /// Roughly an iPhone Pro Max's width — the point beyond which lines stop
        /// being comfortable to read (`docs/TASKS.md` Phase 5, iPad).
        static let readableWidth: CGFloat = 560
    }

    // MARK: - Typography

    /// Faces are declared against system **text styles** rather than point sizes,
    /// which is what makes them respond to Dynamic Type.
    ///
    /// A bare `Font.system(size:)` is frozen: it ignores the reader's text-size
    /// setting entirely. That matters more here than in most apps — a parent
    /// checking a monitor at 3 a.m. without their glasses is the normal case, not
    /// an edge case.
    ///
    /// The trade is that the default sizes shift by a point or two from the
    /// original fixed values (`callout` 14.5 → 13, `caption` 13.5 → 12). Scaling
    /// is worth more than matching the mock exactly at one text size.
    ///
    /// **`Font.system(size:)` is for SF Symbols glyphs only.** A glyph sized to
    /// its container is a layout measurement; text sized in points is a text-size
    /// setting quietly ignored. Any `Text` reaching for a point size wants one of
    /// the faces below with a `.weight()` on it instead.
    enum Typography {
        static let display = Font.system(.title, design: .default).weight(.heavy)
        static let title = Font.system(.title2).weight(.bold)
        static let headline = Font.system(.title3).weight(.bold)
        static let body = Font.system(.subheadline)
        static let callout = Font.system(.footnote)
        static let caption = Font.system(.caption)
        static let button = Font.system(.headline).weight(.semibold)

        /// Tabular numerals for countdowns and the SAS, so digits do not jitter.
        /// Kept at a fixed size on purpose: the six SAS digits have to stay on one
        /// line at every text size, and a wrapped confirmation code is unreadable.
        static func monospacedDigits(size: CGFloat, weight: Font.Weight = .bold) -> Font {
            Font.system(size: size, weight: weight).monospacedDigit()
        }
    }
}

// MARK: - Role colours

extension Theme {
    /// The accent a screen uses, given the role it belongs to. Coral for the
    /// Camera, periwinkle for the Viewer — consistently, on every screen.
    static func accent(for role: PairingRole) -> Color {
        switch role {
        case .camera: return Palette.coral
        case .viewer: return Palette.periwinkle
        }
    }

    /// Readable foreground on top of `accent(for:)`.
    static func onAccent(for role: PairingRole) -> Color {
        switch role {
        case .camera: return Palette.onCoral
        case .viewer: return Color(hex: 0x131735)
        }
    }
}

// MARK: - Hex colours

extension Color {
    /// Builds a colour from a `0xRRGGBB` literal, matching the design file's
    /// hex values exactly.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
