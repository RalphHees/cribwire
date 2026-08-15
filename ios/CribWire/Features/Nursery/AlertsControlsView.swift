import CribWireKit
import SwiftUI

/// The Camera's alert settings, edited from the Viewer.
///
/// Detection has not moved anywhere: it still runs on the Camera, on the Camera's
/// own microphone and frames. What this changes is the configuration, and it is
/// here because the person who finds out that the threshold is wrong is the one
/// being woken by it — in another room, at night, holding this device rather than
/// the one on the shelf.
///
/// Two rules, both the same ones the music and light controls follow:
///
/// - **The Camera is the authority.** A change is a request; the Camera clamps it,
///   stores it and reports back what it is now running.
/// - **The whole settings value travels.** Editing starts from what the Camera
///   last reported, so a Viewer never sends a half-picture — and the watch area,
///   which can only be drawn on the Camera, is carried through untouched rather
///   than reset by a Viewer that has no way to draw one.
struct AlertsControlsView: View {

    let state: AlertsState
    let send: (DetectionSettings) -> Void

    /// What this Viewer has asked for and the Camera has not yet confirmed.
    ///
    /// The controls follow the room everywhere else in this sheet, but a switch
    /// that springs back under the finger for the length of a round trip is not
    /// something anyone would call working. So an edit is held here until the
    /// Camera's report agrees with it, and then let go — after which the room is
    /// in charge again.
    @State private var draft: DetectionSettings?

    private var settings: DetectionSettings { draft ?? state.settings }

    var body: some View {
        KCCard {
            VStack(alignment: .leading, spacing: 14) {
                header

                if let reason = unavailableReason {
                    Text(reason)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if state.isMicrophoneUnavailable, settings.noise.isEnabled {
                        microphoneWarning
                    }
                    noiseSection
                    Divider().overlay(Theme.Palette.line)
                    movementSection
                    Divider().overlay(Theme.Palette.line)
                    cooldownSection

                    Text("Alerts are still detected on the camera phone and sent to you encrypted — changing them here only tells it what to listen and watch for.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: state.settings) { _, reported in
            // The room has caught up with what was asked for; hand the controls
            // back to it.
            if reported == draft { draft = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Palette.periwinkle)
            Text("Alerts")
                .font(Theme.Typography.callout.weight(.semibold))
                .foregroundStyle(Theme.Palette.text)
            Spacer(minLength: 8)
            Text(summary)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textFaint)
        }
    }

    private var summary: String {
        switch (settings.noise.isEnabled, settings.movement.isEnabled) {
        case (true, true): return String(localized: "Noise and movement")
        case (true, false): return String(localized: "Noise")
        case (false, true): return String(localized: "Movement")
        case (false, false): return String(localized: "Off")
        }
    }

    /// "On but deaf" must never look like "on". The Camera reports this
    /// separately from the settings for exactly that reason.
    private var microphoneWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.warning)
            Text("The camera phone cannot open its microphone, so noise alerts will not fire. Open CribWire on that phone to fix it.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Noise

    private var noiseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: binding(for: \.noise.isEnabled)) {
                label(
                    symbol: "speaker.wave.2.fill",
                    tint: Theme.Palette.coral,
                    title: "Noise",
                    subtitle: "Alert when the room gets loud"
                )
            }
            .tint(Theme.Palette.live)
            .accessibilityIdentifier("viewer-noise-toggle")

            if settings.noise.isEnabled {
                // Bound to the sensitivity, not to the dBFS threshold: the two
                // run in opposite directions, and this is the one a parent is
                // reading.
                ThrottledSlider(
                    value: settings.noise.sensitivityFraction,
                    leadingSymbol: "speaker.wave.1",
                    trailingSymbol: "speaker.wave.3.fill",
                    accessibilityLabel: Text("Noise sensitivity")
                ) { fraction in
                    update { $0.noise.sensitivityFraction = fraction }
                }
                scaleLabels
            }
        }
    }

    // MARK: - Movement

    private var movementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: binding(for: \.movement.isEnabled)) {
                label(
                    symbol: "bolt.fill",
                    tint: Theme.Palette.periwinkle,
                    title: "Movement",
                    subtitle: "Alert when the picture changes"
                )
            }
            .tint(Theme.Palette.live)
            .accessibilityIdentifier("viewer-movement-toggle")

            if settings.movement.isEnabled {
                ThrottledSlider(
                    value: settings.movement.sensitivityFraction,
                    leadingSymbol: "figure.stand",
                    trailingSymbol: "figure.walk.motion",
                    accessibilityLabel: Text("Movement sensitivity")
                ) { fraction in
                    update { $0.movement.sensitivityFraction = fraction }
                }
                scaleLabels

                if !settings.movement.regionOfInterest.isFullFrame {
                    // The rectangle is drawn on the Camera, over its own preview.
                    // Saying so is better than a control that is quietly missing:
                    // a Viewer whose movement alerts ignore half the room should
                    // know that is deliberate.
                    Text("The camera is watching part of the picture. Change the area on the camera phone.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var scaleLabels: some View {
        HStack {
            Text("Less sensitive")
            Spacer()
            Text("More sensitive")
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Palette.textFaint)
    }

    // MARK: - Cooldown

    private var cooldownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quiet period after an alert")
                .font(Theme.Typography.callout.weight(.semibold))
                .foregroundStyle(Theme.Palette.text)

            Picker("Quiet period", selection: binding(for: \.cooldown)) {
                ForEach(DetectionSettings.cooldownChoices, id: \.self) { choice in
                    Text("\(Int(choice / 60)) min").tag(choice)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Editing

    private func binding<Value: Equatable>(
        for keyPath: WritableKeyPath<DetectionSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in update { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Every edit goes out as the complete settings, built from what is on screen
    /// — which is the Camera's own report unless this Viewer is mid-change.
    private func update(_ transform: (inout DetectionSettings) -> Void) {
        var next = settings
        transform(&next)
        guard next != settings else { return }
        draft = next
        send(next)
    }

    private func label(
        symbol: String,
        tint: Color,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typography.callout.weight(.semibold))
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
            }
        }
    }

    private var unavailableReason: String? {
        switch state.availability {
        case .ready:
            return nil
        case .unknown:
            return String(
                localized: "This camera is running an older version of CribWire, so its alerts can only be changed on the camera phone."
            )
        }
    }
}
