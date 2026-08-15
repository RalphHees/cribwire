import Foundation

/// What a detector did with the latest input.
public enum DetectionOutcome: Equatable, Sendable {
    /// Below threshold.
    case idle
    /// Above threshold, but not for long enough yet.
    case rising
    /// Fire an event now.
    case triggered
    /// Would have fired, but the cooldown from the last event is still running.
    case suppressed
}

/// Noise-detector configuration (`ios-app.md` §2.5).
public struct NoiseDetectionSettings: Codable, Equatable, Sendable {

    /// The presets on the settings screen. Custom keeps whatever the slider was
    /// left at.
    public enum Sensitivity: String, Codable, CaseIterable, Sendable {
        case low
        case medium
        case high
        case custom

        /// Threshold in dBFS. "Low" sensitivity needs a loud room; "high" fires
        /// on quiet sounds.
        public var thresholdDBFS: Double? {
            switch self {
            case .low: return -20
            case .medium: return -30
            case .high: return -40
            case .custom: return nil
            }
        }

        public static func matching(thresholdDBFS: Double) -> Sensitivity {
            for preset in [Sensitivity.low, .medium, .high]
            where preset.thresholdDBFS == thresholdDBFS {
                return preset
            }
            return .custom
        }
    }

    /// **Off until the user turns it on** (`ios-app.md` §2.5).
    public var isEnabled: Bool
    /// dBFS, full-scale-sine referenced (see `AWeightingFilter.levelDBFS`).
    public var thresholdDBFS: Double

    /// Range of the custom slider.
    public static let thresholdRange: ClosedRange<Double> = -60 ... -10

    public init(isEnabled: Bool = false, thresholdDBFS: Double = -30) {
        self.isEnabled = isEnabled
        self.thresholdDBFS = thresholdDBFS
    }

    public var sensitivity: Sensitivity {
        Sensitivity.matching(thresholdDBFS: thresholdDBFS)
    }

    /// The threshold expressed as a *sensitivity*, `0...1`, where 1 fires on the
    /// quietest room.
    ///
    /// Sliders bind to this rather than to `thresholdDBFS`, because the stored
    /// value runs the other way: −60 dBFS is the most sensitive setting this
    /// detector offers and −10 dBFS the least. A slider bound straight to the
    /// threshold moves left for *more* sensitivity, which is why the Low / Medium
    /// / High labels under it used to sit under the wrong ends.
    public var sensitivityFraction: Double {
        get {
            let least = Self.thresholdRange.upperBound
            let most = Self.thresholdRange.lowerBound
            return min(max((least - thresholdDBFS) / (least - most), 0), 1)
        }
        set {
            let least = Self.thresholdRange.upperBound
            let most = Self.thresholdRange.lowerBound
            thresholdDBFS = least - min(max(newValue, 0), 1) * (least - most)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Everything is optional on the way in so a settings file written by an
        // older build keeps working — and so a corrupt field can never leave a
        // detector *enabled* by accident.
        let enabled: Bool? = try? container.decode(Bool.self, forKey: .isEnabled)
        let threshold: Double? = try? container.decode(Double.self, forKey: .thresholdDBFS)
        self.isEnabled = enabled ?? false
        self.thresholdDBFS = threshold ?? -30
    }
}

/// The part of the picture movement detection looks at, in normalised
/// coordinates with the origin at the top-left of the frame.
public struct DetectionRegion: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let full = DetectionRegion(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.width = min(max(width, 0), 1 - self.x)
        self.height = min(max(height, 0), 1 - self.y)
    }

    public var isFullFrame: Bool { self == .full }

    /// Pixel bounds inside a frame of the given size. Always at least one pixel
    /// wide and tall, so a degenerate rectangle cannot divide by zero.
    public func pixelBounds(width frameWidth: Int, height frameHeight: Int) -> (
        xRange: Range<Int>, yRange: Range<Int>
    ) {
        let x0 = min(Int((x * Double(frameWidth)).rounded(.down)), max(frameWidth - 1, 0))
        let y0 = min(Int((y * Double(frameHeight)).rounded(.down)), max(frameHeight - 1, 0))
        let x1 = max(min(Int(((x + width) * Double(frameWidth)).rounded(.up)), frameWidth), x0 + 1)
        let y1 = max(min(Int(((y + height) * Double(frameHeight)).rounded(.up)), frameHeight), y0 + 1)
        return (x0..<x1, y0..<y1)
    }
}

/// Movement-detector configuration (`ios-app.md` §2.5).
public struct MovementDetectionSettings: Codable, Equatable, Sendable {

    /// **Off until the user turns it on**, and independent of noise detection.
    public var isEnabled: Bool
    /// Fraction of pixels in the region that must change, `0...1`.
    public var changedPixelFraction: Double
    /// The region to watch — a rectangle around the cot, so moving curtains at
    /// the edge of frame do not fire it.
    public var regionOfInterest: DetectionRegion

    public static let changedPixelFractionRange: ClosedRange<Double> = 0.005 ... 0.25

    /// The threshold expressed as a *sensitivity*, `0...1`, where 1 fires on the
    /// smallest movement.
    ///
    /// Same reason as `NoiseDetectionSettings.sensitivityFraction`: the stored
    /// value is how much of the watch area has to change, so it runs the opposite
    /// way from the slider a parent is reading.
    public var sensitivityFraction: Double {
        get {
            let least = Self.changedPixelFractionRange.upperBound
            let most = Self.changedPixelFractionRange.lowerBound
            return min(max((least - changedPixelFraction) / (least - most), 0), 1)
        }
        set {
            let least = Self.changedPixelFractionRange.upperBound
            let most = Self.changedPixelFractionRange.lowerBound
            changedPixelFraction = least - min(max(newValue, 0), 1) * (least - most)
        }
    }

    public init(
        isEnabled: Bool = false,
        changedPixelFraction: Double = 0.02,
        regionOfInterest: DetectionRegion = .full
    ) {
        self.isEnabled = isEnabled
        self.changedPixelFraction = changedPixelFraction
        self.regionOfInterest = regionOfInterest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabled: Bool? = try? container.decode(Bool.self, forKey: .isEnabled)
        let fraction: Double? = try? container.decode(Double.self, forKey: .changedPixelFraction)
        let region: DetectionRegion? = try? container.decode(
            DetectionRegion.self,
            forKey: .regionOfInterest
        )
        self.isEnabled = enabled ?? false
        self.changedPixelFraction = fraction ?? 0.02
        self.regionOfInterest = region ?? .full
    }
}

/// Everything the detection settings screen edits.
///
/// Both detectors default to **off** and are toggled independently — that is the
/// "option to enable" `ios-app.md` §2.5 requires, and it is why this type has no
/// single "detection on" switch.
public struct DetectionSettings: Codable, Equatable, Sendable {
    public var noise: NoiseDetectionSettings
    public var movement: MovementDetectionSettings
    /// Quiet period after an event, per detector (default 3 min, 1–10 min).
    public var cooldown: TimeInterval

    public static let cooldownRange: ClosedRange<TimeInterval> = 60 ... 600
    public static let defaultCooldown: TimeInterval = 180
    /// The four values the settings screen offers as chips.
    public static let cooldownChoices: [TimeInterval] = [60, 180, 300, 600]

    public static let `default` = DetectionSettings()

    public init(
        noise: NoiseDetectionSettings = NoiseDetectionSettings(),
        movement: MovementDetectionSettings = MovementDetectionSettings(),
        cooldown: TimeInterval = DetectionSettings.defaultCooldown
    ) {
        self.noise = noise
        self.movement = movement
        self.cooldown = min(max(cooldown, DetectionSettings.cooldownRange.lowerBound),
                            DetectionSettings.cooldownRange.upperBound)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let noise: NoiseDetectionSettings? = try? container.decode(
            NoiseDetectionSettings.self,
            forKey: .noise
        )
        let movement: MovementDetectionSettings? = try? container.decode(
            MovementDetectionSettings.self,
            forKey: .movement
        )
        let cooldown: TimeInterval? = try? container.decode(TimeInterval.self, forKey: .cooldown)
        self.init(
            noise: noise ?? NoiseDetectionSettings(),
            movement: movement ?? MovementDetectionSettings(),
            cooldown: cooldown ?? DetectionSettings.defaultCooldown
        )
    }

    /// True when the capture pipeline has to keep running with no viewer
    /// attached (`ios-app.md` §5: it stops entirely when neither is on).
    public var requiresCapturePipeline: Bool {
        noise.isEnabled || movement.isEnabled
    }
}
