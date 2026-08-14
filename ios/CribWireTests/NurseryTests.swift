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
