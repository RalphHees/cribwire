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

    /// A client id is not an implementation.
    ///
    /// Setting `TIDAL_CLIENT_ID` on the backend is a reasonable thing for a
    /// deployment to do, and it must not make every Camera in the fleet advertise
    /// a service with no player behind it — which is what put "TIDAL is not set
    /// up on this camera" in front of someone who had a TIDAL subscription.
    @MainActor
    func testAClientIDAloneDoesNotOfferTidal() async {
        let provider = TidalMusicProvider(
            configuration: TidalConfiguration(clientID: "a-real-looking-client-id")
        )
        XCTAssertFalse(
            provider.isConfigured,
            "offer TIDAL only when this build can actually play it"
        )
        let availability = await provider.availability()
        XCTAssertEqual(availability, .notConfigured)
    }

    /// The switcher is built from the providers a Camera can use, so an
    /// unimplemented service must not reach a Viewer's screen at all.
    @MainActor
    func testTidalIsNotAmongTheProvidersACameraOffers() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "cribwire.tests.tidalOffer"))
        defer { UserDefaults().removePersistentDomain(forName: "cribwire.tests.tidalOffer") }

        let controller = NurseryController(
            capture: nil,
            recentsStore: MusicRecentsStore(defaults: defaults),
            defaults: defaults,
            providers: [
                FakeMusicProvider(availability: .ready, canControlPlayback: true),
                TidalMusicProvider(configuration: TidalConfiguration(clientID: "id"))
            ],
            systemRemote: FakeSystemMusicRemote(isAvailable: false)
        )
        await controller.reload()

        XCTAssertFalse(controller.state.music.availableProviders.contains(.tidal))
    }

    /// The backend's copy wins, which is the point of serving one at all: an id
    /// rotated on the server has to beat the one this build was compiled with.
    func testTheBackendClientIDIsPreferredOverTheBuiltInOne() {
        let remote = RemoteConfiguration(tidalClientID: "from-backend")
        let resolved = TidalConfiguration.make(
            remote: remote,
            bundle: Bundle(for: TidalConfigurationTests.self)
        )
        XCTAssertEqual(resolved?.clientID, "from-backend")
    }

    /// A deployment that serves no id leaves the build's own value in charge,
    /// rather than blanking it — which is what keeps a local-network pairing,
    /// where no server is ever called, working exactly as before.
    func testNoBackendClientIDFallsBackToTheBuild() {
        let resolved = TidalConfiguration.make(
            remote: RemoteConfiguration(),
            bundle: Bundle(for: TidalConfigurationTests.self)
        )
        XCTAssertNil(resolved, "this test bundle carries no built-in id either")
        XCTAssertNil(TidalConfiguration.make(remote: RemoteConfiguration()))
    }

    /// A blank id from the backend is not an id. Same rule as the build's, so a
    /// server that sends `""` cannot switch TIDAL on and then play nothing.
    func testABlankBackendClientIDIsNotConfigured() {
        XCTAssertNil(TidalConfiguration.make(remote: RemoteConfiguration(tidalClientID: "")))
        XCTAssertNil(TidalConfiguration.make(remote: RemoteConfiguration(tidalClientID: "  ")))
    }

    // No test for the provider resolving its id on every read: `isConfigured`
    // short-circuits on `isPlaybackImplemented`, so today the resolver is never
    // consulted at all and there is nothing to observe. It becomes assertable in
    // the commit that implements playback, which is the commit that gives it a
    // reason to exist.
}

/// What the backend is allowed to change between releases, and how long a device
/// keeps believing it.
final class RemoteConfigurationTests: XCTestCase {

    private let suiteName = "cribwire.tests.remoteConfig"

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() throws -> RemoteConfigurationStore {
        RemoteConfigurationStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
    }

    func testAnEmptyStoreIsStaleSoTheFirstLaunchAsks() throws {
        let store = try makeStore()
        XCTAssertTrue(store.load().isStale())
        XCTAssertNil(store.load().tidalClientID)
    }

    func testAResponseIsStoredAndReadBack() throws {
        let store = try makeStore()
        let now = Date()
        store.record(
            API.AppConfigurationResponse(
                ttlSeconds: 3600,
                tidal: .init(clientID: "server-id")
            ),
            at: now
        )

        let loaded = store.load()
        XCTAssertEqual(loaded.tidalClientID, "server-id")
        XCTAssertFalse(loaded.isStale(at: now.addingTimeInterval(3599)))
        XCTAssertTrue(loaded.isStale(at: now.addingTimeInterval(3601)))
    }

    /// A deployment that dropped TIDAL has to be able to say so. Recording the
    /// absence — rather than leaving the last id in place — is what lets a
    /// service be withdrawn as well as rotated.
    func testAResponseWithoutTidalClearsTheStoredID() throws {
        let store = try makeStore()
        store.record(.init(ttlSeconds: 60, tidal: .init(clientID: "server-id")))
        store.record(.init(ttlSeconds: 60, tidal: nil))

        XCTAssertNil(store.load().tidalClientID)
    }

    /// A phone whose clock jumped backwards must not be pinned to a retired id
    /// for as long as the clock is wrong.
    func testAClockThatWentBackwardsCountsAsStale() {
        let configuration = RemoteConfiguration(
            tidalClientID: "server-id",
            fetchedAt: Date(),
            ttlSeconds: 3600
        )
        XCTAssertTrue(configuration.isStale(at: Date().addingTimeInterval(-60)))
    }

    func testAResponseWithNoTTLFallsBackToADay() {
        let now = Date()
        let configuration = RemoteConfiguration(tidalClientID: "id", fetchedAt: now)
        XCTAssertFalse(configuration.isStale(at: now.addingTimeInterval(3600)))
        XCTAssertTrue(
            configuration.isStale(at: now.addingTimeInterval(RemoteConfiguration.defaultTTL + 1))
        )
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

/// The talk-back gain is the Camera's, not a session's: it has to outlive the
/// Viewer that set it, and every Viewer has to read the same value.
@MainActor
final class TalkbackVolumeTests: XCTestCase {

    private let suiteName = "cribwire.tests.talkbackVolume"

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(defaults: UserDefaults) -> NurseryController {
        NurseryController(
            capture: nil,
            recentsStore: MusicRecentsStore(defaults: defaults),
            defaults: defaults,
            providers: [FakeMusicProvider(availability: .ready, canControlPlayback: true)],
            systemRemote: FakeSystemMusicRemote(isAvailable: false)
        )
    }

    func testTheVolumeIsRecordedClampedAndReported() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let controller = makeController(defaults: defaults)

        controller.setTalkbackVolume(0.75)
        XCTAssertEqual(controller.state.talkback.volume, 0.75)
        XCTAssertEqual(controller.state.talkback.gain, 3, accuracy: 0.0001)

        controller.setTalkbackVolume(4)
        XCTAssertEqual(controller.state.talkback.volume, 1)
    }

    /// It is a property of the room, so a Camera restarting has to come back to
    /// the same setting rather than to the default.
    func testTheVolumeSurvivesARestart() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        makeController(defaults: defaults).setTalkbackVolume(0.9)

        XCTAssertEqual(makeController(defaults: defaults).state.talkback.volume, 0.9)
    }

    /// `stop()` resets the room's state, and used to take this with it — which
    /// would silently drop a Viewer's setting every time the monitor was stopped.
    func testStoppingTheMonitorDoesNotResetTheVolume() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let controller = makeController(defaults: defaults)
        controller.start()
        controller.setTalkbackVolume(0.9)
        controller.stop()

        XCTAssertEqual(controller.state.talkback.volume, 0.9)
    }

    /// The value a Camera comes up with when nobody has ever set one. Zero is
    /// what `UserDefaults.double(forKey:)` would have answered, and zero is
    /// silence.
    func testAnUnsetVolumeDefaultsToTheBoostRatherThanToSilence() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let controller = makeController(defaults: defaults)

        XCTAssertEqual(controller.state.talkback.volume, TalkbackState.defaultVolume)
        XCTAssertGreaterThan(controller.state.talkback.gain, 1)
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

/// The two settings a Viewer can change on the Camera: how bright the picture is,
/// and what raises an alert.
///
/// Both are *settings*, not actuators, and that is the whole of what these tests
/// pin down: a change arriving from the other room has to be stored — so the
/// Camera comes back tuned after a restart — and an alert change has to reach
/// whoever runs the detectors, because this type deliberately does not.
@MainActor
final class NurseryRemoteSettingsTests: XCTestCase {

    private let suiteName = "cribwire.tests.remoteSettings"

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(defaults: UserDefaults) -> NurseryController {
        NurseryController(
            capture: nil,
            recentsStore: MusicRecentsStore(defaults: defaults),
            defaults: defaults,
            providers: [FakeMusicProvider(availability: .ready, canControlPlayback: true)],
            systemRemote: FakeSystemMusicRemote(isAvailable: false)
        )
    }

    func testABrightnessChangeIsStoredSoTheCameraComesBackTuned() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let controller = makeController(defaults: defaults)

        await controller.apply(.sensitivity(.setBoost(0.8)))

        XCTAssertEqual(controller.state.sensitivity.settings.boost, 0.8)
        XCTAssertEqual(
            CameraSensitivityStore(defaults: defaults).load().boost,
            0.8,
            "a Camera restarted at midnight has to come back as bright as it was left"
        )
    }

    func testABrightnessCommandChangesOnlyWhatItCarries() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        CameraSensitivityStore(defaults: defaults).save(
            CameraSensitivity(boost: 0.2, lowLightBoost: false)
        )
        let controller = makeController(defaults: defaults)

        await controller.apply(.sensitivity(.setBoost(0.9)))

        XCTAssertEqual(controller.state.sensitivity.settings.boost, 0.9)
        XCTAssertFalse(
            controller.state.sensitivity.settings.lowLightBoost,
            "moving the slider must not also flip a switch the Viewer never touched"
        )
    }

    func testAnIdleCameraStillReportsTheBrightnessAsChangeable() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let controller = makeController(defaults: defaults)

        await controller.reload()

        XCTAssertEqual(controller.state.sensitivity.availability, .cameraIdle)
        XCTAssertTrue(controller.state.sensitivity.isControllable)
    }

    func testAnAlertChangeIsStoredAndHandedToWhoeverRunsTheDetectors() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let controller = makeController(defaults: defaults)

        var applied: [DetectionSettings] = []
        controller.onAlertSettingsChange = { applied.append($0) }

        let settings = DetectionSettings(
            noise: NoiseDetectionSettings(isEnabled: true, thresholdDBFS: -45),
            cooldown: 300
        )
        await controller.apply(.alerts(settings))

        XCTAssertEqual(applied, [settings], "storing them is not the same as running them")
        XCTAssertEqual(DetectionSettingsStore(defaults: defaults).load(), settings)
        XCTAssertEqual(controller.state.alerts.settings, settings)
        XCTAssertTrue(controller.state.alerts.isEditable)
    }

    /// The report coming back is not a new instruction. Feeding it round again
    /// would have the engine re-applying its own settings on every refresh tick.
    func testReportingAlertsBackDoesNotAskForThemToBeAppliedAgain() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let controller = makeController(defaults: defaults)

        var applied: [DetectionSettings] = []
        controller.onAlertSettingsChange = { applied.append($0) }

        controller.reportAlerts(
            DetectionSettings(movement: MovementDetectionSettings(isEnabled: true)),
            isMicrophoneUnavailable: true
        )

        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(controller.state.alerts.isMicrophoneUnavailable)
        XCTAssertTrue(controller.state.alerts.settings.movement.isEnabled)
    }

    /// A Camera whose alerts have never been touched still has to say what they
    /// are: a Viewer that cannot tell "off" from "not reported" cannot offer to
    /// turn them on.
    func testAlertsAreReportedFromTheFirstMessageRatherThanAfterTheFirstChange() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        DetectionSettingsStore(defaults: defaults).save(
            DetectionSettings(noise: NoiseDetectionSettings(isEnabled: true))
        )

        let controller = makeController(defaults: defaults)

        XCTAssertEqual(controller.state.alerts.availability, .ready)
        XCTAssertTrue(controller.state.alerts.settings.noise.isEnabled)
    }
}
