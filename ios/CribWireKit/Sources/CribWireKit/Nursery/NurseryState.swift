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

    public init(music: MusicState = .init(), light: LightState = .init()) {
        self.music = music
        self.light = light
    }

    enum CodingKeys: String, CodingKey {
        case music = "m"
        case light = "l"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.music = (try? container.decode(MusicState.self, forKey: .music)) ?? .init()
        self.light = (try? container.decode(LightState.self, forKey: .light)) ?? .init()
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
    /// Services this Camera could switch to. Usually one; the Viewer only shows a
    /// service switcher when there is more than one.
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
