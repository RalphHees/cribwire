import Foundation

/// One downscaled luma frame (`ios-app.md` §2.5: 160×120, 2 fps).
///
/// Plain bytes, so a test can build a frame with a rectangle drawn in it and the
/// detector never needs a camera.
public struct LumaFrame: Equatable, Sendable {
    public let width: Int
    public let height: Int
    /// `width * height` luma samples, row-major, 0 = black.
    public let pixels: [UInt8]

    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A frame filled with one value — the base a test draws onto.
    public static func filled(
        width: Int = MovementDetector.frameWidth,
        height: Int = MovementDetector.frameHeight,
        value: UInt8
    ) -> LumaFrame {
        // Force-unwrap is safe: the sizes are validated positive and the buffer
        // is built to match.
        LumaFrame(
            width: max(width, 1),
            height: max(height, 1),
            pixels: [UInt8](repeating: value, count: max(width, 1) * max(height, 1))
        )!
    }

    /// Returns a copy with `value` written into a rectangle of pixels.
    public func drawing(
        value: UInt8,
        x: Int,
        y: Int,
        width rectWidth: Int,
        height rectHeight: Int
    ) -> LumaFrame {
        var pixels = self.pixels
        for row in max(0, y)..<min(height, y + rectHeight) {
            for column in max(0, x)..<min(width, x + rectWidth) {
                pixels[row * width + column] = value
            }
        }
        return LumaFrame(width: width, height: height, pixels: pixels) ?? self
    }
}

/// Frame-differencing movement detection (`ios-app.md` §2.5).
///
/// Compares each 160×120 luma frame with the previous one inside the
/// region of interest, and fires when the changed-pixel ratio stays over the
/// threshold for three consecutive frames. Three frames at 2 fps is a second and
/// a half of continuous change, which is a child moving rather than the
/// auto-exposure adjusting.
public struct MovementDetector: Equatable, Sendable {

    /// Analysis resolution.
    public static let frameWidth = 160
    public static let frameHeight = 120
    /// Analysis frame rate.
    public static let framesPerSecond = 2
    /// Consecutive frames over threshold before an event (§2.5: ≥ 3).
    public static let requiredConsecutiveFrames = 3
    /// How far a pixel's luma must move to count as changed. Below this is
    /// sensor noise and exposure drift, not movement.
    public static let defaultPixelDelta = 24

    public var settings: MovementDetectionSettings
    public var cooldown: TimeInterval
    public var pixelDelta: Int

    private let requiredFrames: Int
    private var previous: LumaFrame?
    private var consecutiveFrames = 0
    private var lastEventAt: Date?

    /// Changed-pixel ratio of the last comparison, for the settings screen.
    public private(set) var lastChangedFraction: Double = 0

    public init(
        settings: MovementDetectionSettings = MovementDetectionSettings(),
        cooldown: TimeInterval = DetectionSettings.defaultCooldown,
        pixelDelta: Int = MovementDetector.defaultPixelDelta,
        requiredConsecutiveFrames: Int = MovementDetector.requiredConsecutiveFrames
    ) {
        self.settings = settings
        self.cooldown = cooldown
        self.pixelDelta = pixelDelta
        self.requiredFrames = max(1, requiredConsecutiveFrames)
    }

    /// Feeds one frame in.
    ///
    /// The first frame after a start or a reset can only establish a reference —
    /// there is nothing to difference it against — so it always returns `.idle`.
    @discardableResult
    public mutating func ingest(_ frame: LumaFrame, at time: Date) -> DetectionOutcome {
        defer { previous = frame }

        guard settings.isEnabled else {
            consecutiveFrames = 0
            lastChangedFraction = 0
            return .idle
        }

        guard let reference = previous,
              reference.width == frame.width,
              reference.height == frame.height
        else {
            consecutiveFrames = 0
            return .idle
        }

        let fraction = Self.changedFraction(
            previous: reference,
            current: frame,
            region: settings.regionOfInterest,
            pixelDelta: pixelDelta
        )
        lastChangedFraction = fraction

        guard fraction > settings.changedPixelFraction else {
            consecutiveFrames = 0
            return .idle
        }

        consecutiveFrames += 1
        guard consecutiveFrames >= requiredFrames else { return .rising }
        consecutiveFrames = 0

        if let lastEventAt, time.timeIntervalSince(lastEventAt) < cooldown {
            return .suppressed
        }

        lastEventAt = time
        return .triggered
    }

    /// Forgets the reference frame and the streak — used when capture restarts,
    /// so the jump between two unrelated frames is not read as movement.
    public mutating func resetFrameState() {
        previous = nil
        consecutiveFrames = 0
        lastChangedFraction = 0
    }

    public func cooldownEnds(after now: Date) -> Date? {
        guard let lastEventAt else { return nil }
        let ends = lastEventAt.addingTimeInterval(cooldown)
        return ends > now ? ends : nil
    }

    // MARK: - Differencing

    /// Fraction of pixels inside `region` that moved by more than `pixelDelta`.
    ///
    /// `static` and side-effect free: the settings screen previews it live while
    /// the user drags the region, without touching detector state.
    public static func changedFraction(
        previous: LumaFrame,
        current: LumaFrame,
        region: DetectionRegion,
        pixelDelta: Int = MovementDetector.defaultPixelDelta
    ) -> Double {
        guard previous.width == current.width, previous.height == current.height else { return 0 }

        let bounds = region.pixelBounds(width: current.width, height: current.height)
        let threshold = max(0, pixelDelta)
        var changed = 0
        var total = 0

        for row in bounds.yRange {
            let rowOffset = row * current.width
            for column in bounds.xRange {
                let index = rowOffset + column
                let delta = Int(current.pixels[index]) - Int(previous.pixels[index])
                if abs(delta) > threshold { changed += 1 }
                total += 1
            }
        }

        guard total > 0 else { return 0 }
        return Double(changed) / Double(total)
    }
}
