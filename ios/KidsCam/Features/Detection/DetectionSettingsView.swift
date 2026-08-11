import KidsCamKit
import SwiftUI

/// Camera-side alert configuration (`ios-app.md` §2.5, design screenshot 6).
///
/// Noise and movement are separate switches, both **off** until the user turns
/// them on — this screen is the "option to enable" the product requires, so it
/// deliberately has no master toggle that could turn them on together.
struct DetectionSettingsView: View {
    @ObservedObject var model: DetectionSettingsViewModel

    var body: some View {
        KCScreen {
            ScrollView {
                VStack(spacing: Theme.Metrics.stackSpacing) {
                    noiseCard
                    movementCard
                    cooldownCard
                    KCSecurityNote(
                        text: "Alerts are end-to-end encrypted — the server can't see "
                            + "what was detected, or when."
                    )
                }
                .padding(.vertical, 20)
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Noise

    private var noiseCard: some View {
        KCCard {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $model.settings.noise.isEnabled) {
                    detectorLabel(
                        symbol: "speaker.wave.2.fill",
                        tint: Theme.Palette.coral,
                        title: "Noise",
                        subtitle: "Alert when the room gets loud"
                    )
                }
                .tint(Theme.Palette.live)
                .accessibilityIdentifier("noise-toggle")

                if model.settings.noise.isEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Slider(
                            value: $model.settings.noise.thresholdDBFS,
                            in: NoiseDetectionSettings.thresholdRange
                        )
                        .tint(Theme.Palette.coral)
                        .accessibilityLabel("Noise sensitivity")

                        HStack {
                            Text("Low")
                            Spacer()
                            Text("Medium")
                            Spacer()
                            Text("High")
                        }
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textFaint)
                    }

                    Divider().overlay(Theme.Palette.line)

                    // Live calibration meter: the parent holds the phone in the
                    // quiet room and sees whether the current level would fire.
                    HStack(spacing: 10) {
                        Text("Room now")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textMuted)
                        LevelMeter(
                            level: model.currentLevel,
                            threshold: model.settings.noise.thresholdDBFS
                        )
                        Text(model.isAboveThreshold ? "above threshold" : "below threshold")
                            .font(Theme.Typography.caption.weight(.semibold))
                            .foregroundStyle(
                                model.isAboveThreshold ? Theme.Palette.warning : Theme.Palette.live
                            )
                    }
                }
            }
        }
    }

    // MARK: - Movement

    private var movementCard: some View {
        KCCard {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $model.settings.movement.isEnabled) {
                    detectorLabel(
                        symbol: "bolt.fill",
                        tint: Theme.Palette.periwinkle,
                        title: "Movement",
                        subtitle: "Watch a part of the picture"
                    )
                }
                .tint(Theme.Palette.live)
                .accessibilityIdentifier("movement-toggle")

                if model.settings.movement.isEnabled {
                    RegionOfInterestEditor(region: $model.settings.movement.regionOfInterest)
                        .frame(height: 120)
                }
            }
        }
    }

    // MARK: - Cooldown

    private var cooldownCard: some View {
        KCCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quiet period after an alert")
                    .font(.system(size: 16, weight: .semibold))

                // Debounce, so one long cry is one notification and not thirty.
                Picker("Quiet period", selection: $model.settings.cooldown) {
                    ForEach(DetectionSettings.cooldownChoices, id: \.self) { choice in
                        Text("\(Int(choice / 60)) min").tag(choice)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func detectorLabel(
        symbol: String,
        tint: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textMuted)
            }
        }
    }
}

// MARK: - Level meter

/// Bar meter showing the current room level against the firing threshold.
private struct LevelMeter: View {
    let level: Double
    let threshold: Double

    private static let barCount = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< Self.barCount, id: \.self) { index in
                let filled = Double(index) / Double(Self.barCount) <= normalised
                Capsule()
                    .fill(filled ? Theme.Palette.live : Theme.Palette.line)
                    .frame(width: 3, height: 4 + CGFloat(index % 4) * 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Current room level")
        .accessibilityValue(level > threshold ? "above threshold" : "below threshold")
    }

    /// Maps the dBFS range onto `0...1` for display.
    private var normalised: Double {
        let lower = NoiseDetectionSettings.thresholdRange.lowerBound
        let upper = NoiseDetectionSettings.thresholdRange.upperBound
        return min(max((level - lower) / (upper - lower), 0), 1)
    }
}

// MARK: - Region of interest

/// Draggable rectangle marking the part of the frame movement detection watches,
/// so a moving curtain outside it never fires an alert.
private struct RegionOfInterestEditor: View {
    @Binding var region: DetectionRegion

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.size
            let rect = CGRect(
                x: region.x * frame.width,
                y: region.y * frame.height,
                width: region.width * frame.width,
                height: region.height * frame.height
            )

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0x141A21), Color(hex: 0x1A231F)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        Theme.Palette.periwinkle,
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.Palette.periwinkle.opacity(0.08))
                    )
                    .frame(width: rect.width, height: rect.height)
                    .overlay(alignment: .topLeading) {
                        Text("Watch area")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.periwinkle)
                            .padding(6)
                    }
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(dragGesture(in: frame))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Movement watch area")
    }

    private func dragGesture(in frame: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard frame.width > 0, frame.height > 0 else { return }
                let dx = value.translation.width / frame.width
                let dy = value.translation.height / frame.height
                region = DetectionRegion(
                    x: clamp(region.x + dx, upper: 1 - region.width),
                    y: clamp(region.y + dy, upper: 1 - region.height),
                    width: region.width,
                    height: region.height
                )
            }
    }

    private func clamp(_ value: Double, upper: Double) -> Double {
        min(max(value, 0), max(upper, 0))
    }
}
