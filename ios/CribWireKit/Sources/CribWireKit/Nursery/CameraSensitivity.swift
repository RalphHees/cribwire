import Foundation

/// How much light the Camera's picture is made from.
///
/// A nursery at night is close to black, and the phone's own automatic exposure
/// is tuned for photographs of rooms people are awake in: it settles on an
/// exposure that is technically correct and visually empty. This is the knob that
/// overrides it, and it is deliberately one knob rather than three — a parent is
/// not going to reason about ISO, shutter and gain at 3 a.m.
///
/// The value is a single `boost`, `0...1`, which the Camera turns into the three
/// things a phone can actually trade for light:
///
/// - **Exposure bias**, in EV — the sensor is told to aim brighter than it thinks
///   is right. Cheap, immediate, and it costs image noise.
/// - **Frame rate**, at the top of the range — fewer frames per second means each
///   one is exposed for longer, which is the only thing that adds real light
///   rather than amplifying what is already there. It costs smoothness, which in
///   a room where the subject is asleep is close to free.
/// - **Low-light boost**, where the hardware has it, as its own switch. Separate
///   because it is the one setting that can change the *look* of the picture
///   rather than only its brightness, and some parents dislike it.
///
/// None of this is a night-vision mode: the phone has no infrared illuminator, so
/// a room with no light in it at all stays black whatever this is set to. The
/// Camera's own light (`LightState`) is the answer to that one.
public struct CameraSensitivity: Codable, Equatable, Sendable {

    /// The presets the settings screens offer. `custom` is whatever the slider
    /// was left at, exactly as in `NoiseDetectionSettings.Sensitivity`.
    public enum Level: String, Codable, CaseIterable, Sendable {
        /// What the phone would do on its own.
        case standard
        /// A lift that a dim but not dark room needs.
        case brighter
        /// Everything the Camera is willing to trade, frame rate included.
        case night
        case custom

        public var boost: Double? {
            switch self {
            case .standard: return 0
            case .brighter: return 0.5
            case .night: return 1
            case .custom: return nil
            }
        }

        public static func matching(boost: Double) -> Level {
            for preset in [Level.standard, .brighter, .night] where preset.boost == boost {
                return preset
            }
            return .custom
        }
    }

    /// `0...1`. Zero is the phone's own judgement, one is as much light as the
    /// Camera will buy.
    public var boost: Double
    /// Whether the hardware's low-light boost may switch itself on. On by
    /// default: it was already unconditional before this type existed, and a
    /// Camera that quietly got darker after an update would be a regression.
    public var lowLightBoost: Bool

    public static let boostRange: ClosedRange<Double> = 0 ... 1

    /// Exactly what the Camera did before there was anything to set: automatic
    /// exposure, low-light boost where the phone has it.
    public static let `default` = CameraSensitivity()

    public init(boost: Double = 0, lowLightBoost: Bool = true) {
        self.boost = min(max(boost, 0), 1)
        self.lowLightBoost = lowLightBoost
    }

    public var level: Level {
        Level.matching(boost: boost)
    }

    // MARK: - What the boost buys

    /// The most exposure compensation the slider will ask for.
    ///
    /// Two stops. Beyond that a phone sensor in a dark room is amplifying noise
    /// rather than finding light, and the picture gets brighter *and* worse —
    /// which is not a trade a parent watching for movement should be offered.
    public static let maximumExposureBiasEV: Double = 2

    /// Exposure compensation in EV. Clamped again by the device, which has its
    /// own supported range and is the authority on it.
    public var exposureBiasEV: Double {
        boost * Self.maximumExposureBiasEV
    }

    /// The frame rate this setting is willing to give up to expose for longer,
    /// or `nil` to leave the ladder's own rate alone.
    ///
    /// Only the top half of the slider trades anything: below that the bias and
    /// the hardware boost are doing the work, and a monitor that quietly got
    /// choppy because someone nudged a brightness slider would be a bad bargain.
    /// The two rungs are deliberately coarse — a continuously variable frame rate
    /// would restart the capture session on every step of a drag.
    public var frameRateCeiling: Int? {
        if boost < 0.5 { return nil }
        if boost < 0.8 { return 20 }
        return 15
    }

    enum CodingKeys: String, CodingKey {
        case boost = "b"
        case lowLightBoost = "llb"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Forgiving, like every other value on this channel: a field a newer
        // build writes and this one cannot read leaves the Camera on its
        // defaults rather than refusing the whole message.
        let boost: Double? = try? container.decodeIfPresent(Double.self, forKey: .boost)
        let lowLightBoost: Bool? = try? container.decodeIfPresent(
            Bool.self,
            forKey: .lowLightBoost
        )
        self.init(boost: boost ?? 0, lowLightBoost: lowLightBoost ?? true)
    }
}

// MARK: - Command

/// A change to how much light the Camera makes its picture from.
///
/// Both fields are optional and either may be sent alone, so the preset buttons,
/// the slider and the low-light switch are three controls over one setting rather
/// than three settings that can disagree.
public struct SensitivityCommand: Codable, Equatable, Sendable {

    /// `0...1`, as the Viewer's slider reads it.
    public var boost: Double?
    public var lowLightBoost: Bool?

    public init(boost: Double? = nil, lowLightBoost: Bool? = nil) {
        self.boost = boost.map { min(max($0, 0), 1) }
        self.lowLightBoost = lowLightBoost
    }

    public static func setBoost(_ boost: Double) -> SensitivityCommand {
        SensitivityCommand(boost: boost)
    }

    public static func setLowLightBoost(_ enabled: Bool) -> SensitivityCommand {
        SensitivityCommand(lowLightBoost: enabled)
    }

    /// Carries no instruction — what an older build decodes from a command whose
    /// every field is new.
    public var isEmpty: Bool {
        boost == nil && lowLightBoost == nil
    }

    /// Folds this command onto the settings the Camera is currently running.
    ///
    /// A command is a change, not a replacement: a Viewer that only moved the
    /// slider must not silently switch the hardware boost back to whatever its
    /// own screen happened to be showing.
    public func applied(to settings: CameraSensitivity) -> CameraSensitivity {
        CameraSensitivity(
            boost: boost ?? settings.boost,
            lowLightBoost: lowLightBoost ?? settings.lowLightBoost
        )
    }

    enum CodingKeys: String, CodingKey {
        case boost = "b"
        case lowLightBoost = "llb"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let boost = try? container.decodeIfPresent(Double.self, forKey: .boost)
        self.boost = boost.map { min(max($0, 0), 1) }
        self.lowLightBoost = try? container.decodeIfPresent(Bool.self, forKey: .lowLightBoost)
    }
}

// MARK: - State

/// What the Camera's exposure is actually set to, as it reports it.
public struct SensitivityState: Codable, Equatable, Sendable {

    public enum Availability: String, Codable, Sendable {
        case ready
        /// Capture is stopped, so nothing is being exposed right now. The setting
        /// is still worth changing — it is stored and applied the moment capture
        /// starts — which is why this is not treated as "unavailable".
        case cameraIdle
        /// The device offers no exposure control at all. Vanishingly rare, and
        /// still worth saying rather than showing a slider that does nothing.
        case unsupported
        /// A state a newer Camera reported, or a Camera too old to report one.
        case unknown
    }

    public var availability: Availability
    public var settings: CameraSensitivity
    /// Whether this phone has hardware low-light boost. The switch is hidden
    /// rather than disabled where it does not.
    public var supportsLowLightBoost: Bool
    /// The compensation the device actually accepted, in EV — it clamps to its
    /// own supported range, which is narrower than the slider on some hardware.
    /// `nil` while capture is stopped and there is nothing to read.
    public var exposureBiasEV: Double?

    public init(
        availability: Availability = .unknown,
        settings: CameraSensitivity = .default,
        supportsLowLightBoost: Bool = false,
        exposureBiasEV: Double? = nil
    ) {
        self.availability = availability
        self.settings = settings
        self.supportsLowLightBoost = supportsLowLightBoost
        self.exposureBiasEV = exposureBiasEV
    }

    /// Whether it is worth offering the controls at all.
    ///
    /// True while the camera is idle, unlike the light: brightness is a setting
    /// the Camera remembers and applies at the next start, not an actuator that
    /// needs a live capture session to reach.
    public var isControllable: Bool {
        availability == .ready || availability == .cameraIdle
    }

    enum CodingKeys: String, CodingKey {
        case availability = "av"
        case settings = "s"
        case supportsLowLightBoost = "llb"
        case exposureBiasEV = "ev"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let availabilityRaw: String? = try? container.decodeIfPresent(
            String.self,
            forKey: .availability
        )
        let settings: CameraSensitivity? = try? container.decodeIfPresent(
            CameraSensitivity.self,
            forKey: .settings
        )
        let supportsLowLightBoost: Bool? = try? container.decodeIfPresent(
            Bool.self,
            forKey: .supportsLowLightBoost
        )
        let exposureBiasEV: Double? = try? container.decodeIfPresent(
            Double.self,
            forKey: .exposureBiasEV
        )
        self.init(
            // An availability this build has no case for is `unknown`, never
            // `ready`: the safe reading of a state we cannot interpret is not
            // "go ahead and drive it".
            availability: availabilityRaw.map { Availability(rawValue: $0) ?? .unknown } ?? .unknown,
            settings: settings ?? .default,
            supportsLowLightBoost: supportsLowLightBoost ?? false,
            exposureBiasEV: exposureBiasEV
        )
    }
}
