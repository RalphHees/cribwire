import Foundation

/// The Camera's alert settings, as a Viewer changes them.
///
/// Detection itself never moves: it runs on the Camera, on the Camera's own
/// microphone and frames, and nothing here changes that. What travels is the
/// *configuration* — because the person who discovers that the threshold is wrong
/// is the one being woken by it at 2 a.m., and they are holding the Viewer, in a
/// different room, in the dark.
///
/// The whole `DetectionSettings` value is carried rather than a delta. A Viewer
/// edits the settings the Camera last reported, so what it sends is a complete
/// picture that the Camera clamps and validates on arrival — and two Viewers
/// editing at once end with whichever arrived last, in full, rather than with a
/// half-applied mixture of both.
public struct AlertsCommand: Codable, Equatable, Sendable {

    /// `nil` when the Camera could not read what was sent, which is how an older
    /// build sees a command written by a newer one.
    public var settings: DetectionSettings?

    public init(settings: DetectionSettings?) {
        self.settings = settings
    }

    public static func set(_ settings: DetectionSettings) -> AlertsCommand {
        AlertsCommand(settings: settings)
    }

    public var isEmpty: Bool { settings == nil }

    enum CodingKeys: String, CodingKey {
        case settings = "s"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.settings = try? container.decodeIfPresent(DetectionSettings.self, forKey: .settings)
    }
}

/// What the Camera's alerts are set to, as it reports them.
///
/// The Viewer draws this and holds nothing of its own, exactly as it does for the
/// music and the light: a switch that appears to have been flipped always has
/// been, on the device that will actually do the detecting.
public struct AlertsState: Codable, Equatable, Sendable {

    public enum Availability: String, Codable, Sendable {
        case ready
        /// A Camera that never reported its alerts — one running a build from
        /// before they could be changed from here. The Viewer says so rather than
        /// showing switches that reach nothing.
        case unknown
    }

    public var availability: Availability
    public var settings: DetectionSettings
    /// The Camera has noise alerts on and could not open its microphone.
    ///
    /// Carried because "listening" and "deaf but switched on" must never look the
    /// same on the Viewer — that is precisely the failure a parent would not find
    /// out about until a night went unreported.
    public var isMicrophoneUnavailable: Bool

    public init(
        availability: Availability = .unknown,
        settings: DetectionSettings = .default,
        isMicrophoneUnavailable: Bool = false
    ) {
        self.availability = availability
        self.settings = settings
        self.isMicrophoneUnavailable = isMicrophoneUnavailable
    }

    public var isEditable: Bool { availability == .ready }

    enum CodingKeys: String, CodingKey {
        case availability = "av"
        case settings = "s"
        case isMicrophoneUnavailable = "mic"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let availabilityRaw: String? = try? container.decodeIfPresent(
            String.self,
            forKey: .availability
        )
        let settings: DetectionSettings? = try? container.decodeIfPresent(
            DetectionSettings.self,
            forKey: .settings
        )
        let microphone: Bool? = try? container.decodeIfPresent(
            Bool.self,
            forKey: .isMicrophoneUnavailable
        )
        self.init(
            availability: availabilityRaw.map { Availability(rawValue: $0) ?? .unknown } ?? .unknown,
            settings: settings ?? .default,
            isMicrophoneUnavailable: microphone ?? false
        )
    }
}
