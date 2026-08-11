import Foundation

/// One rung of the video ladder (`ios-app.md` §3).
///
/// 640×480 @ 15 fps is the default; a good link climbs to 720p30 and a poor one
/// drops to 320×240. WebRTC's own bandwidth estimator does the fine-grained rate
/// control — this picks the capture/encode format it works within, which is what
/// actually saves battery and CPU on the Camera device.
public struct VideoQuality: Equatable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int
    public let fps: Int
    /// Cap handed to the encoder, in kbps.
    public let maxBitrateKbps: Int

    public init(width: Int, height: Int, fps: Int, maxBitrateKbps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.maxBitrateKbps = maxBitrateKbps
    }

    /// Poor links: 320×240 @ 15.
    public static let low = VideoQuality(width: 320, height: 240, fps: 15, maxBitrateKbps: 250)
    /// The default: 640×480 @ 15.
    public static let standard = VideoQuality(width: 640, height: 480, fps: 15, maxBitrateKbps: 600)
    /// Good links: 1280×720 @ 30.
    public static let high = VideoQuality(width: 1280, height: 720, fps: 30, maxBitrateKbps: 1_800)

    /// Worst to best — the ladder the controller walks.
    public static let ladder: [VideoQuality] = [.low, .standard, .high]

    public var description: String { "\(width)x\(height)@\(fps)" }
}

/// Picks a rung from the link's behaviour.
///
/// Deliberately sluggish: quality changes are visible, so it takes several
/// consecutive bad (or good) samples to move, and it never skips a rung. All the
/// state is here rather than in the engine so the hysteresis can be tested with
/// a list of numbers.
public struct AdaptiveQualityController: Equatable, Sendable {

    /// One measurement, taken about once a second from the peer connection's
    /// statistics.
    public struct Sample: Equatable, Sendable {
        /// Sender-side available outgoing bitrate, kbps.
        public let availableBitrateKbps: Int
        /// Fraction of packets lost, `0...1`.
        public let packetLossFraction: Double
        /// Current round-trip time, seconds.
        public let roundTripTime: TimeInterval

        public init(
            availableBitrateKbps: Int,
            packetLossFraction: Double,
            roundTripTime: TimeInterval
        ) {
            self.availableBitrateKbps = availableBitrateKbps
            self.packetLossFraction = packetLossFraction
            self.roundTripTime = roundTripTime
        }
    }

    /// Consecutive samples needed before a change is applied.
    public var samplesBeforeDowngrade: Int
    public var samplesBeforeUpgrade: Int
    /// Loss above this is "bad" regardless of bandwidth.
    public var badLossFraction: Double
    /// RTT above this is "bad" regardless of bandwidth.
    public var badRoundTripTime: TimeInterval
    /// Headroom required before climbing: the link must carry the next rung's
    /// bitrate plus this fraction.
    public var upgradeHeadroom: Double

    public private(set) var current: VideoQuality
    private var badStreak = 0
    private var goodStreak = 0

    public init(
        current: VideoQuality = .standard,
        samplesBeforeDowngrade: Int = 3,
        samplesBeforeUpgrade: Int = 8,
        badLossFraction: Double = 0.05,
        badRoundTripTime: TimeInterval = 0.5,
        upgradeHeadroom: Double = 0.3
    ) {
        self.current = current
        self.samplesBeforeDowngrade = samplesBeforeDowngrade
        self.samplesBeforeUpgrade = samplesBeforeUpgrade
        self.badLossFraction = badLossFraction
        self.badRoundTripTime = badRoundTripTime
        self.upgradeHeadroom = upgradeHeadroom
    }

    /// Feeds one sample in and returns the quality to apply, or `nil` when
    /// nothing should change.
    public mutating func ingest(_ sample: Sample) -> VideoQuality? {
        let index = VideoQuality.ladder.firstIndex(of: current) ?? 1

        if isBad(sample) {
            goodStreak = 0
            badStreak += 1
            guard badStreak >= samplesBeforeDowngrade, index > 0 else { return nil }
            badStreak = 0
            current = VideoQuality.ladder[index - 1]
            return current
        }

        badStreak = 0
        let next = index + 1
        guard next < VideoQuality.ladder.count else {
            goodStreak = 0
            return nil
        }
        let required = Double(VideoQuality.ladder[next].maxBitrateKbps) * (1 + upgradeHeadroom)
        guard Double(sample.availableBitrateKbps) >= required else {
            goodStreak = 0
            return nil
        }
        goodStreak += 1
        guard goodStreak >= samplesBeforeUpgrade else { return nil }
        goodStreak = 0
        current = VideoQuality.ladder[next]
        return current
    }

    private func isBad(_ sample: Sample) -> Bool {
        if sample.packetLossFraction > badLossFraction { return true }
        if sample.roundTripTime > badRoundTripTime { return true }
        return Double(sample.availableBitrateKbps) < Double(current.maxBitrateKbps) * 0.8
    }
}
