import AVFoundation
import CribWireKit
import XCTest
@testable import CribWire

/// The app-target half of the nursery controls: the pieces that touch iOS types
/// and therefore cannot live in `CribWireKit`, but that are still decisions rather
/// than hardware.
///
/// What is *not* here, deliberately: that the torch actually lights, that MusicKit
/// actually plays, and how loud a phone on a shelf really is through a
/// voice-processed audio session. None of those can be asserted on a build machine
/// — they need two physical devices and a dark room — and faking them here would
/// only make the suite lie about coverage.
final class NurseryLightLevelTests: XCTestCase {

    typealias Levels = CameraCaptureController.LightLevels

    /// The safety property of the whole light feature: a Viewer cannot drive the
    /// torch to full power, whatever it asks for.
    func testTheSliderNeverReachesFullTorchPower() {
        XCTAssertEqual(Levels.hardwareLevel(for: 1), Levels.maximum, accuracy: 0.0001)
        XCTAssertLessThan(
            Levels.maximum,
            AVCaptureDevice.maxAvailableTorchLevel,
            "full power is both painful in a cot and thermally unsustainable"
        )
    }

    func testLevelsOutsideTheSliderAreClampedRatherThanRejected() {
        XCTAssertEqual(Levels.hardwareLevel(for: -5), Levels.minimum, accuracy: 0.0001)
        XCTAssertEqual(Levels.hardwareLevel(for: 42), Levels.maximum, accuracy: 0.0001)
    }

    /// `setTorchModeOn(level:)` throws on a level of zero, so the bottom of the
    /// slider has to still be a lit torch.
    func testTheBottomOfTheSliderIsStillAValidTorchLevel() {
        XCTAssertGreaterThan(Levels.hardwareLevel(for: 0), 0)
        XCTAssertEqual(Levels.hardwareLevel(for: 0), Levels.minimum, accuracy: 0.0001)
    }

    func testTheMappingIsMonotonic() {
        var previous = Levels.hardwareLevel(for: 0)
        for step in 1...20 {
            let next = Levels.hardwareLevel(for: Double(step) / 20)
            XCTAssertGreaterThan(next, previous)
            previous = next
        }
    }

    func testTheDefaultLevelSitsInsideTheSliderRange() {
        XCTAssertTrue((0...1).contains(Levels.default))
    }
}

/// TIDAL is offered only when the build actually carries credentials for it.
/// Getting this wrong in either direction is user-visible: too strict and a
/// properly configured build hides the service, too loose and a parent is offered
/// a service that can never play a note.
final class TidalConfigurationTests: XCTestCase {

    func testAMissingClientIDIsNotConfigured() {
        XCTAssertNil(TidalConfiguration.make(rawClientID: nil))
    }

    func testABlankClientIDIsNotConfigured() {
        XCTAssertNil(TidalConfiguration.make(rawClientID: ""))
        XCTAssertNil(TidalConfiguration.make(rawClientID: "   \n "))
    }

    /// XcodeGen leaves the literal placeholder in Info.plist when the build
    /// setting is undefined, which is exactly what a default build has.
    func testAnUnsubstitutedBuildSettingIsNotConfigured() {
        XCTAssertNil(TidalConfiguration.make(rawClientID: "$(CRIBWIRE_TIDAL_CLIENT_ID)"))
    }

    func testARealClientIDIsConfiguredAndTrimmed() {
        let configuration = TidalConfiguration.make(rawClientID: "  abc123\n")
        XCTAssertEqual(configuration?.clientID, "abc123")
    }

    @MainActor
    func testAnUnconfiguredTidalProviderIsNeverOffered() async {
        let provider = TidalMusicProvider(configuration: nil)
        XCTAssertFalse(provider.isConfigured)
        let availability = await provider.availability()
        XCTAssertEqual(availability, .notConfigured)
        XCTAssertFalse(availability == .ready, "a service that cannot play is never ready")
    }
}

/// What a parent can still do when the music service says no.
///
/// The rule this pins down: a subscription buys the *catalogue*, and nothing else
/// in this feature. Pausing the lullaby that is already playing, skipping it, and
/// turning the room down are all things the Camera can do regardless — and the
/// Camera has to say so, or the Viewer draws a card with nothing in it.
@MainActor
final class NurseryTransportAvailabilityTests: XCTestCase {

    private let suiteName = "cribwire.tests.nursery"

    private func makeController(
        provider: FakeMusicProvider,
        systemRemote: FakeSystemMusicRemote = FakeSystemMusicRemote(isAvailable: false)
    ) throws -> NurseryController {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return NurseryController(
            capture: nil,
            recentsStore: MusicRecentsStore(defaults: defaults),
            defaults: defaults,
            providers: [provider],
            systemRemote: systemRemote
        )
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testALapsedSubscriptionKeepsThePlayerControllable() async throws {
        let provider = FakeMusicProvider(
            availability: .needsSubscription,
            canControlPlayback: true
        )
        let controller = try makeController(provider: provider)
        await controller.reload()

        XCTAssertEqual(controller.state.music.availability, .needsSubscription)
        XCTAssertTrue(
            controller.state.music.canControlPlayback,
            "pause is not something a subscription pays for"
        )
        XCTAssertFalse(controller.state.music.canChoosePlaylists)
    }

    /// The half that would be invisible in the view: the command has to reach the
    /// player too, not merely survive being drawn.
    func testTransportCommandsReachTheProviderWithoutASubscription() async throws {
        let provider = FakeMusicProvider(
            availability: .needsSubscription,
            canControlPlayback: true,
            isPlaying: true
        )
        let controller = try makeController(provider: provider)

        await controller.apply(.music(.toggle))
        await controller.apply(.music(.next))

        XCTAssertEqual(provider.calls, ["pause", "next"])
    }

    /// With nothing to fall back to either, the transport row is still allowed to
    /// disappear: there is genuinely nothing for a button to reach.
    func testAServiceWithNoPlayerAndNoSystemMusicReportsNoTransport() async throws {
        let provider = FakeMusicProvider(
            availability: .notConfigured,
            canControlPlayback: false
        )
        let controller = try makeController(provider: provider)
        await controller.reload()

        XCTAssertFalse(controller.state.music.canControlPlayback)
        XCTAssertFalse(controller.state.music.canChoosePlaylists)
    }

    // MARK: - Music the Camera did not start

    /// The common case this exists for: the parent put something on themselves, so
    /// CribWire's own player has nothing loaded and knows nothing — but the phone
    /// is making noise and a Viewer wants it stopped.
    func testMusicStartedOutsideCribWireIsReportedAndControllable() async throws {
        let provider = FakeMusicProvider(availability: .needsSubscription, canControlPlayback: true)
        let remote = FakeSystemMusicRemote(
            isAvailable: true,
            isPlaying: true,
            title: "Slaapliedje",
            artist: "Iemand"
        )
        let controller = try makeController(provider: provider, systemRemote: remote)
        await controller.reload()

        XCTAssertTrue(controller.state.music.canControlPlayback)
        XCTAssertTrue(controller.state.music.isPlaying)
        XCTAssertEqual(controller.state.music.title, "Slaapliedje")
        XCTAssertEqual(controller.state.music.artist, "Iemand")

        await controller.apply(.music(.toggle))
        await controller.apply(.music(.next))

        XCTAssertEqual(remote.calls, ["pause", "next"])
        XCTAssertEqual(provider.calls, [], "the Camera's own player has nothing to pause")
    }

    /// A service that can play nothing at all still gets a transport row, because
    /// the buttons reach the phone's own player rather than the service.
    func testTransportSurvivesAProviderThatCanPlayNothing() async throws {
        let provider = FakeMusicProvider(availability: .notConfigured, canControlPlayback: false)
        let remote = FakeSystemMusicRemote(isAvailable: true, isPlaying: true, title: "Rain")
        let controller = try makeController(provider: provider, systemRemote: remote)
        await controller.reload()

        XCTAssertTrue(controller.state.music.canControlPlayback)
        XCTAssertEqual(controller.state.music.title, "Rain")

        await controller.apply(.music(.previous))
        XCTAssertEqual(remote.calls, ["previous"])
    }

    /// The other direction, and the one that would be a real bug: a playlist a
    /// Viewer chose must not have its buttons quietly rerouted to the Music app.
    func testAPlaylistStartedByAViewerKeepsTheButtons() async throws {
        let provider = FakeMusicProvider(
            availability: .ready,
            canControlPlayback: true,
            isPlaying: true,
            currentPlaylistID: "sleep"
        )
        let remote = FakeSystemMusicRemote(isAvailable: true, isPlaying: true, title: "Something else")
        let controller = try makeController(provider: provider, systemRemote: remote)
        await controller.reload()

        XCTAssertEqual(
            controller.state.music.title,
            nil,
            "the Camera reports its own player, which this fake leaves unnamed"
        )

        await controller.apply(.music(.toggle))
        XCTAssertEqual(provider.calls, ["pause"])
        XCTAssertEqual(remote.calls, [])
    }
}

@MainActor
final class FakeSystemMusicRemote: SystemMusicRemote {

    let isAvailable: Bool
    private(set) var isPlaying: Bool
    private let title: String?
    private let artist: String?
    private(set) var calls: [String] = []

    init(
        isAvailable: Bool,
        isPlaying: Bool = false,
        title: String? = nil,
        artist: String? = nil
    ) {
        self.isAvailable = isAvailable
        self.isPlaying = isPlaying
        self.title = title
        self.artist = artist
    }

    var nowPlaying: (title: String?, artist: String?) { (title, artist) }

    func start() {}
    func stop() {}

    func play() {
        calls.append("play")
        isPlaying = true
    }

    func pause() {
        calls.append("pause")
        isPlaying = false
    }

    func next() { calls.append("next") }
    func previous() { calls.append("previous") }
}

@MainActor
final class FakeMusicProvider: MusicProvider {

    let kind: MusicProviderKind = .appleMusic
    let isConfigured = true

    private let reportedAvailability: MusicState.Availability
    let canControlPlayback: Bool
    private(set) var isPlaying: Bool
    private(set) var calls: [String] = []

    init(
        availability: MusicState.Availability,
        canControlPlayback: Bool,
        isPlaying: Bool = false,
        currentPlaylistID: String? = nil
    ) {
        self.reportedAvailability = availability
        self.canControlPlayback = canControlPlayback
        self.isPlaying = isPlaying
        self.currentPlaylistID = currentPlaylistID
    }

    func availability() async -> MusicState.Availability { reportedAvailability }

    @discardableResult
    func requestAuthorization() async -> MusicState.Availability { reportedAvailability }

    func loadPlaylists() async -> (
        favorites: [PlaylistSummary],
        recentlyPlayed: [PlaylistSummary]
    ) {
        ([], [])
    }

    var nowPlaying: (title: String?, artist: String?) { (nil, nil) }
    private(set) var currentPlaylistID: String?

    @discardableResult
    func play(playlistID: String) async -> String? {
        calls.append("play(\(playlistID))")
        return nil
    }

    func play() async {
        calls.append("play")
        isPlaying = true
    }

    func pause() async {
        calls.append("pause")
        isPlaying = false
    }

    func next() async { calls.append("next") }
    func previous() async { calls.append("previous") }
    func stop() async { calls.append("stop") }
}

/// Talk-back is the Viewer's live microphone travelling into a child's room, so
/// what gates it is worth asserting rather than trusting to a disabled button.
///
/// The audio itself is SRTP under a DTLS session bound to the sealed fingerprint —
/// libwebrtc offers no unencrypted path, so there is nothing to test there. What
/// *is* testable, and what actually went wrong, is **when** the microphone is
/// allowed to be live.
@MainActor
final class TalkbackGatingTests: XCTestCase {

    private let suiteName = "cribwire.tests.talkback"

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeEngine(role: PairingRole) throws -> StreamingEngine {
        let services = AppServices(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
            registry: PairingRegistry(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cribwire-talkback-\(UUID().uuidString).json")
            )
        )
        let record = PairingRecord(
            id: UUID(),
            localRole: role,
            apiBaseURL: try XCTUnwrap(URL(string: "https://api.cribwire.example"))
        )
        return StreamingEngine(record: record, services: services)
    }

    /// The rule: no microphone to a peer whose certificate has not been checked.
    /// A fresh engine has verified nothing, so pressing talk must do nothing.
    func testTalkbackCannotBeArmedBeforeTheConnectionIsVerified() throws {
        let engine = try makeEngine(role: .viewer)
        XCTAssertFalse(engine.isVerified)

        engine.setTalking(true)

        XCTAssertFalse(
            engine.isTalking,
            "an unverified peer must never be sent the microphone, whatever the UI allows"
        )
    }

    func testReleasingIsHonouredEvenWhenArmingWouldBeRefused() throws {
        let engine = try makeEngine(role: .viewer)
        engine.setTalking(true)
        engine.setTalking(false)
        XCTAssertFalse(engine.isTalking, "stopping is never refused")
    }

    /// Talk-back is a Viewer control. A Camera acting on it would mean this device
    /// is streaming its own microphone back at itself.
    func testACameraIgnoresTalkbackEntirely() throws {
        let engine = try makeEngine(role: .camera)
        engine.setTalking(true)
        XCTAssertFalse(engine.isTalking)
    }

    /// Nursery commands ride the same rule: the Viewer will not send one until the
    /// connection it would travel over has been verified.
    func testNurseryCommandsAreNotSentBeforeVerification() throws {
        let engine = try makeEngine(role: .viewer)
        XCTAssertFalse(engine.isVerified)
        // No client and not verified: the call must be a no-op rather than a
        // crash or a queued send.
        engine.send(.light(.setOn(true)))
        engine.send(.music(.play))
    }
}

/// The Camera's recents survive a round trip through `UserDefaults`, and an
/// unreadable blob costs the shortlist rather than the music.
final class MusicRecentsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "cribwire.tests.nursery"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAnEmptyStoreHasNoHistory() {
        XCTAssertTrue(MusicRecentsStore(defaults: defaults).load().entries.isEmpty)
    }

    func testRecordingPersistsAcrossStoreInstances() {
        let store = MusicRecentsStore(defaults: defaults)
        store.record(playlistID: "sleep", provider: .appleMusic, name: "Sleep tight")

        let reloaded = MusicRecentsStore(defaults: defaults).load()
        XCTAssertEqual(reloaded.entries.map(\.playlistID), ["sleep"])
        XCTAssertEqual(reloaded.entries.first?.name, "Sleep tight")
    }

    func testCorruptStoredDataYieldsAnEmptyHistoryRatherThanCrashing() {
        defaults.set(Data("not json".utf8), forKey: MusicRecentsStore.key)
        XCTAssertTrue(MusicRecentsStore(defaults: defaults).load().entries.isEmpty)
    }
}
