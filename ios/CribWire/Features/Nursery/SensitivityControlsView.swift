import CribWireKit
import SwiftUI

/// How much light the Camera makes its picture from.
///
/// The same view on both devices, deliberately. Whoever notices that the room is
/// black is whoever should be able to fix it, and the two ends should not have
/// two different controls with two different ideas of what "brighter" means — so
/// this draws the Camera's reported state and emits a command, and the Camera
/// applies it whether it came from across the room or across the house.
struct SensitivityControlsView: View {

    let state: SensitivityState
    let send: (SensitivityCommand) -> Void
    /// Coral on the Camera, periwinkle on the Viewer — the role colours the rest
    /// of the app already uses.
    var tint: Color = Theme.Palette.periwinkle

    var body: some View {
        KCCard {
            VStack(alignment: .leading, spacing: 12) {
                header

                if let reason = unavailableReason {
                    Text(reason)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    presets
                    ThrottledSlider(
                        value: state.settings.boost,
                        leadingSymbol: "sun.min",
                        trailingSymbol: "sun.max.fill",
                        accessibilityLabel: Text("Picture brightness")
                    ) { boost in
                        send(.setBoost(boost))
                    }

                    if state.supportsLowLightBoost {
                        Toggle(isOn: lowLightBoostBinding) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Night boost")
                                    .font(Theme.Typography.callout.weight(.semibold))
                                Text("Lets the camera brighten the picture itself when the room is dark.")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(tint)
                        .accessibilityIdentifier("night-boost-toggle")
                    }

                    Text(explanation)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    if state.availability == .cameraIdle {
                        // Worth changing anyway — the Camera stores it — but a
                        // slider that visibly does nothing to the picture needs
                        // to say why.
                        Text("The camera is not capturing right now. This is saved and used as soon as it starts.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
            Text("Picture brightness")
                .font(Theme.Typography.callout.weight(.semibold))
                .foregroundStyle(Theme.Palette.text)
            Spacer(minLength: 8)
            Text(levelName)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textFaint)
        }
    }

    private var lowLightBoostBinding: Binding<Bool> {
        Binding(
            get: { state.settings.lowLightBoost },
            set: { send(.setLowLightBoost($0)) }
        )
    }

    // MARK: - Presets

    /// Buttons rather than a `Picker`: the current setting is often *between* the
    /// presets — anything dragged on the slider is — and a segmented control with
    /// no matching segment shows nothing selected, which reads as broken.
    private var presets: some View {
        HStack(spacing: 8) {
            ForEach(Self.presets, id: \.self) { level in
                presetButton(level)
            }
        }
    }

    private static let presets: [CameraSensitivity.Level] = [.standard, .brighter, .night]

    private func presetButton(_ level: CameraSensitivity.Level) -> some View {
        let isSelected = state.settings.level == level
        return Button {
            guard let boost = level.boost else { return }
            send(.setBoost(boost))
        } label: {
            Text(name(for: level))
                .font(Theme.Typography.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    isSelected ? tint.opacity(0.18) : Theme.Palette.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.controlRadius)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? tint : Theme.Palette.text)
        .accessibilityLabel(Text(name(for: level)))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func name(for level: CameraSensitivity.Level) -> String {
        switch level {
        case .standard: return String(localized: "Normal")
        case .brighter: return String(localized: "Brighter")
        case .night: return String(localized: "Dark room")
        case .custom: return String(localized: "Custom")
        }
    }

    private var levelName: String {
        name(for: state.settings.level)
    }

    /// What the setting costs, said plainly, because both costs are visible on
    /// the live view and neither is obviously connected to a brightness slider.
    private var explanation: String {
        if state.settings.frameRateCeiling != nil {
            return String(
                localized: "Brightening a dark room adds grain, and this setting also slows the picture down so the camera can gather more light. The room still needs some light — a phone cannot see in the dark."
            )
        }
        return String(
            localized: "Turn this up if the room looks black. Brightening a dark room adds grain, and the highest settings also slow the picture down to gather more light."
        )
    }

    private var unavailableReason: String? {
        switch state.availability {
        case .ready, .cameraIdle:
            return nil
        case .unsupported:
            return String(localized: "This camera phone does not let its exposure be adjusted.")
        case .unknown:
            return String(localized: "This camera is running an older version of CribWire.")
        }
    }
}
