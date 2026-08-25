import Foundation

/// What the nursery is currently doing, as the Camera reports it.
///
/// The Viewer renders this and nothing else — it holds no independent idea of
/// whether music is playing or the light is on. That is what stops the two screens
/// disagreeing: a control the Viewer pressed does not light up because it was
/// pressed, it lights up when the Camera says the thing actually happened. On a
/// flaky link that is the difference between a button that lies and one that looks
/// slow.
public struct NurseryState: Codable, Equatable, Sendable {

    public var music: MusicState
    public var light: LightState
    public var talkback: TalkbackState
    /// How much light the Camera is making its picture from.
    public var sensitivity: SensitivityState
    /// What the Camera is set to raise an alert about.
    public var alerts: AlertsState

    public init(
        music: MusicState = .init(),
        light: LightState = .init(),
        talkback: TalkbackState = .init(),
        sensitivity: SensitivityState = .init(),
        alerts: AlertsState = .init()
    ) {
        self.music = music
        self.light = light
        self.talkback = talkback
        self.sensitivity = sensitivity
        self.alerts = alerts
    }

    enum CodingKeys: String, CodingKey {
        case music = "m"
        case light = "l"
        case talkback = "t"
        case sensitivity = "s"
        case alerts = "al"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.music = (try? container.decode(MusicState.self, forKey: .music)) ?? .init()
        self.light = (try? container.decode(LightState.self, forKey: .light)) ?? .init()
        // A Camera too old to send this has a talk-back gain of exactly 1, which
        // is what the default describes — so an older room reads as "unchanged",
        // never as "silent".
        self.talkback = (try? container.decode(TalkbackState.self, forKey: .talkback))
            ?? TalkbackState(volume: TalkbackState.neutralVolume)
        // Both land on `unknown` availability when the Camera did not send them,
        // which is what a build from before these existed looks like. The Viewer
        // shows "this camera is running an older version" rather than controls
        // that would reach nothing.
        self.sensitivity = (try? container.decode(SensitivityState.self, forKey: .sensitivity))
            ?? SensitivityState()
        self.alerts = (try? container.decode(AlertsState.self, forKey: .alerts)) ?? AlertsState()
    }
}

// MARK: - Talk-back

/// How loud the Viewer's voice is made before it reaches the room.
///
/// Deliberately not part of `MusicState`, and deliberately not the device volume
/// that `MusicState.volume` moves. That one is the phone's output: it scales the
/// lullaby and the parent's voice together, so a nursery quiet enough to sleep in
/// is also one where nobody can be heard. This is a gain applied to the incoming
/// voice alone, which is what makes "music soft, voice clear" a thing the two
/// controls can express at once.
public struct TalkbackState: Codable, Equatable, Sendable {

    /// The largest gain offered. Above roughly this, a voice recorded close to a
    /// phone's microphone clips rather than gets louder, so more slider would be
    /// more distortion and not more volume.
    public static let maxGain: Double = 4

    /// The slider position that changes nothing.
    public static var neutralVolume: Double { 1 / maxGain }

    /// Where the slider starts: the midpoint, which is a 2× boost.
    ///
    /// Not neutral, on purpose. The Camera's audio session runs in `.videoChat`
    /// mode, whose voice processing attenuates playback on some devices, and it
    /// competes with music from the same speaker. Neutral is the setting that
    /// made talk-back inaudible; a parent who finds this too loud can see the
    /// slider and move it, which is not true of the volume they never had.
    public static let defaultVolume: Double = 0.5

    /// `0...1`, as the Viewer's slider reads it.
    public var volume: Double

    /// The multiplier the Camera applies to the incoming voice. `1` leaves it
    /// exactly as it arrived.
    public var gain: Double { volume * Self.maxGain }

    public init(volume: Double = TalkbackState.defaultVolume) {
        self.volume = min(max(volume, 0), 1)
    }

    enum CodingKeys: String, CodingKey {
        case volume = "v"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let volume: Double? = try? container.decodeIfPresent(Double.self, forKey: .volume)
        self.init(volume: volume ?? Self.defaultVolume)
    }
}

// MARK: - Music

public struct MusicState: Codable, Equatable, Sendable {

    /// Why the Camera can or cannot play right now.
    ///
    /// Separated into named cases rather than a message string because the Viewer
    /// has to *do* something different for each: an unauthorised Camera needs the
    /// parent to walk to the nursery and tap Allow, a Camera with no subscription
    /// needs nothing at all, and both are wrong to present as "loading".
    public enum Availability: String, Codable, Sendable {
        /// Signed in and able to play.
        case ready
        /// The parent has not granted this app access to the music library on the
        /// Camera device. Only fixable on the Camera itself.
        case needsPermission
        /// Authorised, but there is no active subscription to play from.
        case needsSubscription
        /// This build has no credentials for the service, so it cannot be offered.
        case notConfigured
        /// Anything else — signed out, offline, the service refused.
        case unavailable
        /// A state a newer Camera reported that this Viewer has no case for.
        case unknown
    }

    /// The provider the Camera is currently set to.
    public var provider: MusicProviderKind
    public var availability: Availability
    /// Whether transport commands — play, pause, next, previous — actually reach
    /// a player right now.
    ///
    /// A **lower bar than `availability == .ready`**, and deliberately separate
    /// from it. `.ready` answers "can this Camera start a playlist from the
    /// service's catalogue?", which is what a subscription buys. Driving music
    /// that is already going needs no subscription at all: a lapsed account still
    /// plays a downloaded library, and pause still means pause. Folding the two
    /// questions together is what used to take the whole music card away from a
    /// parent who only wanted to turn the lullaby off.
    public var canControlPlayback: Bool
    public var isPlaying: Bool
    /// System output volume on the Camera device, `0...1`. `nil` while unknown.
    public var volume: Double?
    public var title: String?
    public var artist: String?
    /// The playlist currently loaded, so the Viewer can tick it in the picker.
    public var playlistID: String?
    /// Recently played and favourite playlists, already shortlisted by
    /// `PlaylistShortlist`. The Viewer shows exactly this and never asks for more.
    public var playlists: [PlaylistSummary]
    /// The services a parent has **connected on this Camera** — signed in to, or
    /// in Apple Music's case granted access to and left switched on.
    ///
    /// Not the services this build knows how to talk to. A Camera with a TIDAL
    /// client id compiled in but no account signed in to it reports an empty list
    /// here, and the Viewer offers no TIDAL: a switcher entry for a service with
    /// no account behind it is a button whose only outcome is silence, and the
    /// fix for it — a web sheet — can only be answered on the Camera anyway.
    ///
    /// Empty is therefore a normal state with a specific meaning: *nothing is
    /// connected yet, go and connect something on the camera phone*. It is not
    /// the same as the Camera being unable to play, which is what
    /// `canControlPlayback` answers — a parent with no account connected can
    /// still pause whatever is already coming out of that phone.
    public var availableProviders: [MusicProviderKind]

    public init(
        provider: MusicProviderKind = .appleMusic,
        availability: Availability = .unavailable,
        /// `nil` means "work it out from `availability`", which is what a Camera
        /// too old to send the field is effectively saying.
        canControlPlayback: Bool? = nil,
        isPlaying: Bool = false,
        volume: Double? = nil,
        title: String? = nil,
        artist: String? = nil,
        playlistID: String? = nil,
        playlists: [PlaylistSummary] = [],
        availableProviders: [MusicProviderKind] = []
    ) {
        self.provider = provider
        self.availability = availability
        self.canControlPlayback = canControlPlayback ?? (availability == .ready)
        self.isPlaying = isPlaying
        self.volume = volume.map { min(max($0, 0), 1) }
        self.title = title.map { PlaylistSummary.truncate($0, to: PlaylistSummary.maxNameLength) }
        self.artist = artist.map { PlaylistSummary.truncate($0, to: PlaylistSummary.maxNameLength) }
        self.playlistID = playlistID
        self.playlists = Array(playlists.prefix(PlaylistShortlist.limit))
        self.availableProviders = availableProviders
    }

    /// Whether any music account is connected on the Camera.
    ///
    /// What the Viewer branches its explanation on. With nothing connected there
    /// is no service to name, and naming one anyway — the Camera still reports
    /// some `provider`, because something has to be selected — would tell a
    /// parent their Apple Music was broken when the truth is they have never
    /// connected any account at all.
    public var hasConnectedProvider: Bool {
        !availableProviders.isEmpty
    }

    /// Whether the Camera can be asked to start a playlist.
    ///
    /// The one part of the music card a subscription really does gate: choosing
    /// something new to play means reaching the service's catalogue. Everything
    /// else — the transport buttons and the volume — is offered regardless.
    public var canChoosePlaylists: Bool {
        availability == .ready
    }

    /// The one-line "now playing", or `nil` when nothing is loaded.
    public var nowPlaying: String? {
        switch (title, artist) {
        case (let title?, let artist?): return "\(title) — \(artist)"
        case (let title?, nil): return title
        default: return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case provider = "p"
        case availability = "av"
        case canControlPlayback = "ctl"
        case isPlaying = "pl"
        case volume = "v"
        case title = "ti"
        case artist = "ar"
        case playlistID = "pid"
        case playlists = "ls"
        case availableProviders = "ps"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Every field is read forgivingly. A `nursery` message is the Camera
        // describing itself, and one field the Camera has grown since this build
        // shipped must not cost the Viewer the whole description.
        let provider: MusicProviderKind? = try? container.decodeIfPresent(
            MusicProviderKind.self,
            forKey: .provider
        )
        let availabilityRaw: String? = try? container.decodeIfPresent(
            String.self,
            forKey: .availability
        )
        // Absent from a Camera that predates the split between "can play a
        // playlist" and "can be told to pause". `nil` is passed through so the
        // initialiser derives it from availability, exactly as that Camera meant.
        let canControlPlayback: Bool? = try? container.decodeIfPresent(
            Bool.self,
            forKey: .canControlPlayback
        )
        let isPlaying: Bool? = try? container.decodeIfPresent(Bool.self, forKey: .isPlaying)
        let volume: Double? = try? container.decodeIfPresent(Double.self, forKey: .volume)
        let title: String? = try? container.decodeIfPresent(String.self, forKey: .title)
        let artist: String? = try? container.decodeIfPresent(String.self, forKey: .artist)
        let playlistID: String? = try? container.decodeIfPresent(String.self, forKey: .playlistID)
        let playlists: [PlaylistSummary]? = try? container.decodeIfPresent(
            [PlaylistSummary].self,
            forKey: .playlists
        )
        let providers: [MusicProviderKind]? = try? container.decodeIfPresent(
            [MusicProviderKind].self,
            forKey: .availableProviders
        )

        self.init(
            provider: provider ?? .appleMusic,
            // An availability this build has never heard of is shown as unknown,
            // not as ready: the safe reading of "I do not understand the state of
            // your music session" is never "go ahead and press play".
            availability: availabilityRaw.map { Availability(rawValue: $0) ?? .unknown } ?? .unknown,
            canControlPlayback: canControlPlayback,
            isPlaying: isPlaying ?? false,
            volume: volume,
            title: title,
            artist: artist,
            playlistID: playlistID,
            playlists: playlists ?? [],
            availableProviders: providers ?? []
        )
    }
}

// MARK: - Light

/// The Camera's light — the torch on the back of the phone, run at a low level as
/// a night light rather than as a flashlight.
public struct LightState: Codable, Equatable, Sendable {

    public enum Availability: String, Codable, Sendable {
        case ready
        /// The Camera is streaming from the front camera. Only the back one has a
        /// torch, so the fix is to flip the camera — which the parent can see and
        /// understand, unlike a greyed-out switch with no explanation.
        case wrongCamera
        /// Capture is stopped, so there is no device session to drive the torch
        /// from. Resolves itself the moment a Viewer connects.
        case cameraIdle
        /// This device has no torch at all.
        case noHardware
        /// iOS refused the torch, which in practice means the phone is too warm.
        /// Retrying immediately will not help.
        case unavailable
        case unknown
    }

    public var availability: Availability
    public var isOn: Bool
    /// Brightness `0...1` as the Viewer's slider sees it. The Camera maps this
    /// onto the hardware range it is willing to sustain — see
    /// `CameraLightController`.
    public var level: Double

    public init(
        availability: Availability = .unknown,
        isOn: Bool = false,
        level: Double = 0
    ) {
        self.availability = availability
        self.isOn = isOn
        self.level = min(max(level, 0), 1)
    }

    public var isControllable: Bool {
        availability == .ready
    }

    enum CodingKeys: String, CodingKey {
        case availability = "av"
        case isOn = "on"
        case level = "lv"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let availabilityRaw: String? = try? container.decodeIfPresent(
            String.self,
            forKey: .availability
        )
        let isOn: Bool? = try? container.decodeIfPresent(Bool.self, forKey: .isOn)
        let level: Double? = try? container.decodeIfPresent(Double.self, forKey: .level)
        self.init(
            availability: availabilityRaw.map { Availability(rawValue: $0) ?? .unknown } ?? .unknown,
            isOn: isOn ?? false,
            level: level ?? 0
        )
    }
}
