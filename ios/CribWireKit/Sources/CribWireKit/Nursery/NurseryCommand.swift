import Foundation

/// What a Viewer asks the Camera to do to the room: the music, or the light.
///
/// This is the one place in CribWire where a Viewer *actuates* the Camera rather
/// than observing it, so two rules apply to everything in this file:
///
/// - **It travels sealed, like everything else on the signaling channel.** The
///   server routes ciphertext and never learns that a light was switched on, let
///   alone which playlist someone chose.
/// - **Every field is advisory.** The Camera owns the hardware and the music
///   session; a command is a request it validates, clamps and may refuse. A
///   Viewer cannot, for example, drive the torch past the level the Camera
///   considers safe to run for hours.
///
/// Both halves are optional so one message can carry either or both, and a build
/// that has never heard of one of them simply finds `nil`.
public struct NurseryCommand: Codable, Equatable, Sendable {

    public var music: MusicCommand?
    public var light: LightCommand?

    public init(music: MusicCommand? = nil, light: LightCommand? = nil) {
        self.music = music
        self.light = light
    }

    /// Nothing to do. A command that decodes to this is dropped rather than
    /// acted on — it is what an older build produces when a newer one sends a
    /// command it has no field for.
    public var isEmpty: Bool {
        music == nil && light == nil
    }

    public static func music(_ command: MusicCommand) -> NurseryCommand {
        NurseryCommand(music: command)
    }

    public static func light(_ command: LightCommand) -> NurseryCommand {
        NurseryCommand(light: command)
    }

    enum CodingKeys: String, CodingKey {
        case music = "m"
        case light = "l"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Each half is decoded independently and forgivingly: a malformed light
        // command must not throw away a perfectly good music command sent in the
        // same message, and neither must reject the whole signaling payload —
        // that would be scored as a protocol violation by `SignalingClient`.
        self.music = try? container.decodeIfPresent(MusicCommand.self, forKey: .music)
        self.light = try? container.decodeIfPresent(LightCommand.self, forKey: .light)
    }
}

// MARK: - Music

/// One music instruction from the Viewer.
///
/// Flat rather than an enum with associated values on purpose. Swift's synthesised
/// `Codable` for such an enum emits compiler-generated keys (`_0`), which is not
/// something two independently-updated app installs should have to agree on — and
/// a Camera and a Viewer are routinely on different builds.
public struct MusicCommand: Codable, Equatable, Sendable {

    public enum Action: String, Codable, Sendable {
        case play
        case pause
        /// Play if paused, pause if playing. The Viewer shows one button, and
        /// letting the Camera resolve it removes a race where the Viewer's idea
        /// of the current state is one message out of date.
        case toggle
        case next
        case previous
        /// `volume` carries the new level.
        case setVolume
        /// `playlistID` and `provider` carry what to play.
        case selectPlaylist
        /// `provider` carries the service to switch to, without choosing a
        /// playlist yet. Separate from `selectPlaylist` because the Viewer offers
        /// the two as separate choices, and because switching service has to stop
        /// whatever the old one was playing whether or not a new playlist follows.
        case setProvider
        /// Stop and give up the audio session.
        case stop
        /// Re-read the playlist shortlist and report it. Sent when the Viewer
        /// opens the picker, so a playlist added on the Camera today shows up
        /// without restarting the stream.
        case refreshPlaylists
        /// A command from a newer build. Decoded so the rest of the message
        /// survives, then ignored.
        case unknown
    }

    public var action: Action
    /// `0...1`, for `setVolume`.
    public var volume: Double?
    /// Provider-scoped playlist identifier, for `selectPlaylist`.
    public var playlistID: String?
    /// Which service `playlistID` belongs to, and — for `selectPlaylist` — which
    /// service the Camera should switch to.
    public var provider: MusicProviderKind?

    public init(
        action: Action,
        volume: Double? = nil,
        playlistID: String? = nil,
        provider: MusicProviderKind? = nil
    ) {
        self.action = action
        self.volume = volume.map { min(max($0, 0), 1) }
        self.playlistID = playlistID
        self.provider = provider
    }

    // MARK: Factories

    public static let play = MusicCommand(action: .play)
    public static let pause = MusicCommand(action: .pause)
    public static let toggle = MusicCommand(action: .toggle)
    public static let next = MusicCommand(action: .next)
    public static let previous = MusicCommand(action: .previous)
    public static let stop = MusicCommand(action: .stop)
    public static let refreshPlaylists = MusicCommand(action: .refreshPlaylists)

    /// - Parameter level: clamped to `0...1`. A Viewer with a slider that has
    ///   drifted out of range cannot ask for anything the Camera has to reject.
    public static func setVolume(_ level: Double) -> MusicCommand {
        MusicCommand(action: .setVolume, volume: level)
    }

    public static func selectPlaylist(
        id: String,
        provider: MusicProviderKind
    ) -> MusicCommand {
        MusicCommand(action: .selectPlaylist, playlistID: id, provider: provider)
    }

    public static func setProvider(_ provider: MusicProviderKind) -> MusicCommand {
        MusicCommand(action: .setProvider, provider: provider)
    }

    enum CodingKeys: String, CodingKey {
        case action = "a"
        case volume = "v"
        case playlistID = "pl"
        case provider = "pv"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The action string is mapped rather than decoded as the enum: an
        // unrecognised action from a newer Viewer becomes `.unknown` instead of
        // throwing, which is the difference between "ignore one button" and
        // "this Camera cannot talk to this Viewer".
        let raw = try container.decode(String.self, forKey: .action)
        self.action = Action(rawValue: raw) ?? .unknown
        let volume = try? container.decodeIfPresent(Double.self, forKey: .volume)
        self.volume = volume.map { min(max($0, 0), 1) }
        self.playlistID = try? container.decodeIfPresent(String.self, forKey: .playlistID)
        self.provider = try? container.decodeIfPresent(MusicProviderKind.self, forKey: .provider)
    }
}

// MARK: - Light

/// A change to the Camera's light.
///
/// Both fields are optional and either may be sent alone:
///
/// - `isOn` alone is the toggle — "turn the light on at whatever level it is
///   already set to".
/// - `level` alone is the brightness slider. Sending it while the light is off
///   turns it on, because dragging a brightness slider is not a plausible way to
///   ask for darkness; `isOn: false` is.
public struct LightCommand: Codable, Equatable, Sendable {

    public var isOn: Bool?
    /// `0...1`. What the Camera does with it is its own business: it maps the
    /// range onto the torch levels the hardware will actually sustain.
    public var level: Double?

    public init(isOn: Bool? = nil, level: Double? = nil) {
        self.isOn = isOn
        self.level = level.map { min(max($0, 0), 1) }
    }

    public static func setOn(_ isOn: Bool) -> LightCommand {
        LightCommand(isOn: isOn)
    }

    public static func setLevel(_ level: Double) -> LightCommand {
        LightCommand(level: level)
    }

    /// Carries no instruction — what an older build decodes from a command whose
    /// every field is new.
    public var isEmpty: Bool {
        isOn == nil && level == nil
    }

    enum CodingKeys: String, CodingKey {
        case isOn = "on"
        case level = "lv"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isOn = try? container.decodeIfPresent(Bool.self, forKey: .isOn)
        let level = try? container.decodeIfPresent(Double.self, forKey: .level)
        self.level = level.map { min(max($0, 0), 1) }
    }
}
