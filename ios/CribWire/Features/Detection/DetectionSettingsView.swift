import CribWireKit
import SwiftUI

/// Camera-side alert configuration (`ios-app.md` §2.5, design screenshot 6).
///
/// Noise and movement are separate switches, both **off** until the user turns
/// them on — this screen is the "option to enable" the product requires, so it
/// deliberately has no master toggle that could turn them on together.
struct DetectionSettingsView: View {
    // @Bindable, not a plain `let`: this view writes back through
    // `$model.settings...` in the toggles, sliders and pickers below.
    @Bindable var model: DetectionSettingsViewModel

    /// The screen's own microphone tap.
    ///
    /// The meter exists so a parent can hold the phone in the quiet room and see
    /// whether the current threshold would fire. That needs live audio *here* —
    /// the detector's own tap belongs to `StreamingEngine`, which is not running
    /// while this screen is open, so the meter previously sat at the silence
    /// floor no matter how loud the room was.
    @State private var monitor: AudioLevelMonitor?
    @State private var isMicrophoneUnavailable = false
    /// Live preview behind the watch-area editor. Drawing a box on a grey
    /// rectangle is guesswork; drawing it on the actual room is not.
    @State private var preview = CameraPreviewSession()

    var body: some View {
        KCScreen {
            ScrollView {
                VStack(spacing: Theme.Metrics.stackSpacing) {
                    noiseCard
                    movementCard
                    cooldownCard
                    // One literal, not a concatenation: `"a" + "b"` is a `String`
                    // and would never reach the String Catalog.
                    KCSecurityNote(
                        text: "Alerts are end-to-end encrypted — the server can't see what was detected, or when."
                    )
                }
                .padding(.vertical, 20)
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // The meter needs the microphone whether or not noise alerts are on:
            // the whole point is calibrating the threshold before enabling them.
            await AudioLevelMonitor.requestMicrophoneAccess()
            startMetering()
            if model.settings.movement.isEnabled {
                await preview.start()
            }
        }
        .onDisappear {
            stopMetering()
            preview.stop()
        }
        // Only while the editor is on screen: a camera running behind a settings
        // list is a battery cost with nothing to show for it.
        .onChange(of: model.settings.movement.isEnabled) { _, isEnabled in
            if isEnabled {
                Task { await preview.start() }
            } else {
                preview.stop()
            }
        }
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
                        Text(meterCaption)
                            .font(Theme.Typography.caption.weight(.semibold))
                            .foregroundStyle(meterTint)
                    }
                }
            }
        }
    }

    /// A dead microphone must not read as a quiet room — that is the difference
    /// between "your threshold is fine" and "this will never fire".
    private var meterCaption: String {
        if isMicrophoneUnavailable {
            return String(localized: "Microphone unavailable")
        }
        return model.isAboveThreshold
            ? String(localized: "above threshold")
            : String(localized: "below threshold")
    }

    private var meterTint: Color {
        if isMicrophoneUnavailable { return Theme.Palette.warning }
        return model.isAboveThreshold ? Theme.Palette.warning : Theme.Palette.live
    }

    // MARK: - Metering

    private func startMetering() {
        guard monitor == nil else { return }
        let monitor = AudioLevelMonitor { level in
            model.updateLevel(level)
        }
        do {
            try monitor.start()
            self.monitor = monitor
            isMicrophoneUnavailable = false
        } catch {
            isMicrophoneUnavailable = true
        }
    }

    private func stopMetering() {
        monitor?.stop()
        monitor = nil
        // Leaving the last reading frozen on screen would suggest the room is
        // still being listened to.
        model.updateLevel(AWeightingFilter.silenceFloorDB)
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
                    RegionOfInterestEditor(
                        region: $model.settings.movement.regionOfInterest,
                        preview: preview
                    )
                    // Tall enough to aim with. The old 120 pt strip was barely
                    // deeper than the drag handle it was meant to contain.
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
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
/// Drag to move the watch area, drag its corner to resize it.
///
/// Two things were wrong before, and the second made the first invisible:
///
/// 1. `DragGesture.translation` is measured from where the drag *started*, but
///    it was being added to the region's current position on every update — so
///    each frame re-applied the whole offset to an already-moved box and it shot
///    off to the edge. The origin at drag start is now captured once.
/// 2. There was no way to resize, and the region defaults to the full frame.
///    With width 1 there is nowhere to move to, so dragging did nothing at all
///    and the editor looked broken out of the box.
private struct RegionOfInterestEditor: View {
    @Binding var region: DetectionRegion
    let preview: CameraPreviewSession

    /// The region as it was when the current drag began. `nil` between drags.
    @State private var dragOrigin: DetectionRegion?

    /// Below this the box stops being a region and starts being a rounding
    /// error; the detector measures a changed-pixel *fraction* of it.
    private static let minimumSide: Double = 0.15
    private static let handleSize: CGFloat = 28

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
                // The room itself, where it can be shown.
                if preview.isAvailable {
                    CameraPreviewView(session: preview.session)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0x141A21), Color(hex: 0x1A231F)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                // Dim everything outside the watch area, so what is *not* being
                // watched reads at a glance.
                Color.black.opacity(0.45)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .reverseMask {
                        RoundedRectangle(cornerRadius: 8)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                    .allowsHitTesting(false)

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
                    .overlay(alignment: .bottomTrailing) { resizeHandle(in: frame) }
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(moveGesture(in: frame))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Movement watch area")
        .accessibilityValue(accessibilityValue)
        // VoiceOver cannot drag a box, so the same adjustment is offered as an
        // increment: each step shrinks the area towards the middle of the frame.
        .accessibilityAdjustableAction { direction in
            adjust(shrinking: direction == .decrement)
        }
    }

    /// The corner grip. Sized for a fingertip rather than to match the stroke.
    private func resizeHandle(in frame: CGSize) -> some View {
        Circle()
            .fill(Theme.Palette.periwinkle)
            .frame(width: 14, height: 14)
            .overlay(
                Circle().strokeBorder(Theme.Palette.background, lineWidth: 2)
            )
            .contentShape(Circle().inset(by: -Self.handleSize / 2))
            .offset(x: 7, y: 7)
            .gesture(resizeGesture(in: frame))
    }

    // MARK: - Gestures

    private func moveGesture(in frame: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard frame.width > 0, frame.height > 0 else { return }
                let origin = dragOrigin ?? region
                if dragOrigin == nil { dragOrigin = origin }

                // Translation is relative to the drag's start, so it applies to
                // the region as it was then — never to the region as it is now.
                region = DetectionRegion(
                    x: clamp(
                        origin.x + value.translation.width / frame.width,
                        upper: 1 - origin.width
                    ),
                    y: clamp(
                        origin.y + value.translation.height / frame.height,
                        upper: 1 - origin.height
                    ),
                    width: origin.width,
                    height: origin.height
                )
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func resizeGesture(in frame: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard frame.width > 0, frame.height > 0 else { return }
                let origin = dragOrigin ?? region
                if dragOrigin == nil { dragOrigin = origin }

                // The top-left corner is pinned, so the far edge cannot pass the
                // frame and the box cannot invert.
                let width = origin.width + value.translation.width / frame.width
                let height = origin.height + value.translation.height / frame.height
                region = DetectionRegion(
                    x: origin.x,
                    y: origin.y,
                    width: clamp(width, lower: Self.minimumSide, upper: 1 - origin.x),
                    height: clamp(height, lower: Self.minimumSide, upper: 1 - origin.y)
                )
            }
            .onEnded { _ in dragOrigin = nil }
    }

    /// VoiceOver's substitute for dragging.
    private func adjust(shrinking: Bool) {
        let step = 0.1
        let delta = shrinking ? -step : step
        let width = clamp(region.width + delta, lower: Self.minimumSide, upper: 1)
        let height = clamp(region.height + delta, lower: Self.minimumSide, upper: 1)
        // Kept centred, so repeated steps close in on the middle of the frame
        // rather than crawling towards a corner.
        region = DetectionRegion(
            x: clamp((1 - width) / 2, upper: 1 - width),
            y: clamp((1 - height) / 2, upper: 1 - height),
            width: width,
            height: height
        )
    }

    private var accessibilityValue: String {
        let width = Int((region.width * 100).rounded())
        let height = Int((region.height * 100).rounded())
        return String(localized: "\(width) by \(height) percent of the picture")
    }

    private func clamp(_ value: Double, lower: Double = 0, upper: Double) -> Double {
        min(max(value, lower), max(upper, lower))
    }
}
