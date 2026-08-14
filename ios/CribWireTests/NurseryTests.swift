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
