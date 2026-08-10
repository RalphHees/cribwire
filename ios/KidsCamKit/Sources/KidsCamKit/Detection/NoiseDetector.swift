import Foundation

/// The trigger logic for noise detection (`ios-app.md` §2.5).
///
/// The audio tap hands it one A-weighted level per 500 ms window; it decides
/// when that becomes an event. Everything that decides *whether a parent's phone
/// buzzes* lives here, in a value type with no audio session attached, so the
/// rules — a full second above threshold, then three minutes of quiet — are
/// tested with a list of numbers rather than by clapping at a device.
public struct NoiseDetector: Equatable, Sendable {

    /// Analysis window length (`ios-app.md` §2.5: 500 ms).
    public static let windowDuration: TimeInterval = 0.5
    /// How long the level has to stay up before it counts (§2.5: ≥ 1 s).
    public static let sustainDuration: TimeInterval = 1.0

    public var settings: NoiseDetectionSettings
    /// Quiet period after an event.
    public var cooldown: TimeInterval

    private let requiredWindows: Int
    private var consecutiveWindows = 0
    private var lastEventAt: Date?

    public init(
        settings: NoiseDetectionSettings = NoiseDetectionSettings(),
        cooldown: TimeInterval = DetectionSettings.defaultCooldown,
        windowDuration: TimeInterval = NoiseDetector.windowDuration,
        sustainDuration: TimeInterval = NoiseDetector.sustainDuration
    ) {
        self.settings = settings
        self.cooldown = cooldown
        self.requiredWindows = max(1, Int((sustainDuration / max(windowDuration, 0.001)).rounded(.up)))
    }

    /// The level of the most recent window, for the live meter on the settings
    /// screen.
    public private(set) var lastLevelDBFS: Double = AWeightingFilter.silenceFloorDB

    /// When the cooldown ends, if one is running.
    public func cooldownEnds(after now: Date) -> Date? {
        guard let lastEventAt else { return nil }
        let ends = lastEventAt.addingTimeInterval(cooldown)
        return ends > now ? ends : nil
    }

    /// Feeds one window's level in.
    ///
    /// - Returns: `.triggered` exactly once per sustained burst of noise, and
    ///   never while the cooldown is running.
    @discardableResult
    public mutating func ingest(levelDBFS: Double, at time: Date) -> DetectionOutcome {
        lastLevelDBFS = levelDBFS

        guard settings.isEnabled else {
            consecutiveWindows = 0
            return .idle
        }

        guard levelDBFS >= settings.thresholdDBFS else {
            consecutiveWindows = 0
            return .idle
        }

        consecutiveWindows += 1
        guard consecutiveWindows >= requiredWindows else { return .rising }

        // A sustained burst has been observed; whether it becomes an event
        // depends only on the cooldown. Reset either way, so one long noisy
        // stretch produces one event per cooldown rather than one per window.
        consecutiveWindows = 0

        if let lastEventAt, time.timeIntervalSince(lastEventAt) < cooldown {
            return .suppressed
        }

        lastEventAt = time
        return .triggered
    }

    /// Drops the sustained-window count without touching the cooldown — used
    /// when capture restarts after an interruption.
    public mutating func resetWindowState() {
        consecutiveWindows = 0
    }
}
