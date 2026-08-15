import XCTest
@testable import CribWireKit

/// The two settings a Viewer can reach that are not actuators: how much light the
/// Camera makes its picture from, and what it raises an alert about.
///
/// Both are settings a Camera and a Viewer on *different builds* have to agree
/// about, so the wire encoding gets the same treatment as the rest of the nursery
/// vocabulary: a field one side has never heard of costs that field and nothing
/// else, and an unrecognised state is never read as "ready".
final class CameraSensitivityTests: XCTestCase {

    // MARK: - What the boost buys

    func testThePresetsSitOnTheirOwnBoostValues() {
        XCTAssertEqual(CameraSensitivity(boost: 0).level, .standard)
        XCTAssertEqual(CameraSensitivity(boost: 0.5).level, .brighter)
        XCTAssertEqual(CameraSensitivity(boost: 1).level, .night)
        XCTAssertEqual(
            CameraSensitivity(boost: 0.35).level,
            .custom,
            "anything dragged between the presets is custom, not the nearest one"
        )
    }

    func testTheBoostIsClampedOnConstructionAndOnTheWire() throws {
        XCTAssertEqual(CameraSensitivity(boost: 4).boost, 1)
        XCTAssertEqual(CameraSensitivity(boost: -2).boost, 0)

        let decoded = try JSONDecoder().decode(
            CameraSensitivity.self,
            from: Data(#"{"b":9,"llb":false}"#.utf8)
        )
        XCTAssertEqual(decoded.boost, 1, "a Viewer cannot ask for more than the top of the slider")
        XCTAssertFalse(decoded.lowLightBoost)
    }

    func testExposureCompensationRunsFromNoneToTwoStops() {
        XCTAssertEqual(CameraSensitivity(boost: 0).exposureBiasEV, 0, accuracy: 0.0001)
        XCTAssertEqual(CameraSensitivity(boost: 0.5).exposureBiasEV, 1, accuracy: 0.0001)
        XCTAssertEqual(
            CameraSensitivity(boost: 1).exposureBiasEV,
            CameraSensitivity.maximumExposureBiasEV,
            accuracy: 0.0001
        )
    }

    /// Frame rate is the only lever that lets more light onto the sensor rather
    /// than amplifying what is already there, and it is the only one with a cost
    /// a parent will see on the live view — so only the top half of the slider is
    /// allowed to spend it.
    func testOnlyTheTopHalfOfTheSliderTradesFrameRateForLight() {
        XCTAssertNil(CameraSensitivity(boost: 0).frameRateCeiling)
        XCTAssertNil(CameraSensitivity(boost: 0.49).frameRateCeiling)
        XCTAssertEqual(CameraSensitivity(boost: 0.5).frameRateCeiling, 20)
        XCTAssertEqual(CameraSensitivity(boost: 0.79).frameRateCeiling, 20)
        XCTAssertEqual(CameraSensitivity(boost: 0.8).frameRateCeiling, 15)
        XCTAssertEqual(CameraSensitivity(boost: 1).frameRateCeiling, 15)
    }

    func testTheDefaultIsWhatThePhoneWouldDoOnItsOwn() {
        XCTAssertEqual(CameraSensitivity.default.boost, 0)
        XCTAssertNil(CameraSensitivity.default.frameRateCeiling)
        XCTAssertTrue(
            CameraSensitivity.default.lowLightBoost,
            "the hardware boost was unconditional before this setting existed"
        )
    }

    // MARK: - Commands

    /// A command is a change, not a replacement: a Viewer that moved only the
    /// slider must not also flip the hardware boost back to whatever its own
    /// screen happened to be drawing.
    func testACommandChangesOnlyTheFieldItCarries() {
        let current = CameraSensitivity(boost: 0.2, lowLightBoost: false)

        let brightened = SensitivityCommand.setBoost(0.9).applied(to: current)
        XCTAssertEqual(brightened.boost, 0.9)
        XCTAssertFalse(brightened.lowLightBoost)

        let boosted = SensitivityCommand.setLowLightBoost(true).applied(to: current)
        XCTAssertEqual(boosted.boost, 0.2)
        XCTAssertTrue(boosted.lowLightBoost)
    }

    func testAnEmptySensitivityCommandCarriesNoInstruction() throws {
        XCTAssertTrue(SensitivityCommand().isEmpty)
        XCTAssertFalse(SensitivityCommand.setBoost(0.5).isEmpty)

        // What an older build decodes from a command whose every field is new.
        let decoded = try JSONDecoder().decode(
            SensitivityCommand.self,
            from: Data(#"{"infrared":true}"#.utf8)
        )
        XCTAssertTrue(decoded.isEmpty)
    }

    func testSensitivityAndAlertsRideTheSameCommandAsTheMusic() throws {
        let settings = DetectionSettings(
            noise: NoiseDetectionSettings(isEnabled: true, thresholdDBFS: -40),
            movement: MovementDetectionSettings(
                isEnabled: true,
                changedPixelFraction: 0.05,
                regionOfInterest: DetectionRegion(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
            ),
            cooldown: 300
        )
        let command = NurseryCommand(
            music: .pause,
            sensitivity: .setBoost(0.75),
            alerts: .set(settings)
        )

        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(NurseryCommand.self, from: data)

        XCTAssertEqual(decoded, command)
        XCTAssertEqual(decoded.sensitivity?.boost, 0.75)
        XCTAssertEqual(
            decoded.alerts?.settings?.movement.regionOfInterest,
            settings.movement.regionOfInterest,
            "the watch area is drawn on the Camera and must survive a Viewer's edit"
        )
    }

    func testAnAlertsCommandFromANewerBuildIsDroppedRatherThanGuessedAt() throws {
        let json = Data(#"{"al":{"schedule":"nights"}}"#.utf8)
        let decoded = try JSONDecoder().decode(NurseryCommand.self, from: json)

        XCTAssertNil(decoded.alerts?.settings)
        XCTAssertTrue(decoded.alerts?.isEmpty ?? true)
    }

    // MARK: - State

    func testStateCarriesTheSensitivityAndTheAlertsBack() throws {
        let state = NurseryState(
            sensitivity: SensitivityState(
                availability: .ready,
                settings: CameraSensitivity(boost: 0.5, lowLightBoost: false),
                supportsLowLightBoost: true,
                exposureBiasEV: 0.75
            ),
            alerts: AlertsState(
                availability: .ready,
                settings: DetectionSettings(
                    noise: NoiseDetectionSettings(isEnabled: true, thresholdDBFS: -35)
                ),
                isMicrophoneUnavailable: true
            )
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(NurseryState.self, from: data)

        XCTAssertEqual(decoded, state)
        XCTAssertTrue(decoded.sensitivity.isControllable)
        XCTAssertTrue(decoded.alerts.isEditable)
        XCTAssertTrue(
            decoded.alerts.isMicrophoneUnavailable,
            "listening and deaf-but-switched-on must never look the same"
        )
    }

    /// A Camera on a build from before either setting existed. The Viewer has to
    /// be able to tell that from a Camera reporting "off", or it would offer
    /// switches that reach nothing.
    func testACameraThatReportsNeitherSettingReadsAsUnknownRatherThanOff() throws {
        let json = Data(#"{"m":{"av":"ready"},"l":{"av":"ready"}}"#.utf8)
        let decoded = try JSONDecoder().decode(NurseryState.self, from: json)

        XCTAssertEqual(decoded.sensitivity.availability, .unknown)
        XCTAssertFalse(decoded.sensitivity.isControllable)
        XCTAssertEqual(decoded.alerts.availability, .unknown)
        XCTAssertFalse(decoded.alerts.isEditable)
        XCTAssertEqual(decoded.alerts.settings, .default)
    }

    func testAnUnknownSensitivityAvailabilityIsNotTreatedAsReady() throws {
        let json = Data(#"{"s":{"av":"infrared","s":{"b":1}}}"#.utf8)
        let decoded = try JSONDecoder().decode(NurseryState.self, from: json)

        XCTAssertEqual(decoded.sensitivity.availability, .unknown)
        XCTAssertFalse(decoded.sensitivity.isControllable)
        XCTAssertEqual(decoded.sensitivity.settings.boost, 1, "the value it did send still arrives")
    }

    /// An idle Camera is not an uncontrollable one: the setting is stored and
    /// applied at the next start, which is exactly what makes it worth changing
    /// from a Viewer before anyone has started streaming.
    func testAnIdleCameraStillOffersTheBrightnessControl() {
        let state = SensitivityState(availability: .cameraIdle, settings: .default)
        XCTAssertTrue(state.isControllable)
    }

    // MARK: - Sensitivity, the way a slider reads it

    func testNoiseSensitivityRunsTheOppositeWayFromItsThreshold() {
        var noise = NoiseDetectionSettings(thresholdDBFS: -30)
        XCTAssertEqual(noise.sensitivityFraction, 0.4, accuracy: 0.0001)

        noise.thresholdDBFS = NoiseDetectionSettings.thresholdRange.lowerBound
        XCTAssertEqual(
            noise.sensitivityFraction,
            1,
            accuracy: 0.0001,
            "the quietest threshold is the *most* sensitive setting"
        )
        noise.thresholdDBFS = NoiseDetectionSettings.thresholdRange.upperBound
        XCTAssertEqual(noise.sensitivityFraction, 0, accuracy: 0.0001)
    }

    func testSettingTheNoiseSensitivityLandsOnThePresetThresholds() {
        var noise = NoiseDetectionSettings()

        noise.sensitivityFraction = 0.6
        XCTAssertEqual(noise.thresholdDBFS, -40, accuracy: 0.0001)
        XCTAssertEqual(noise.sensitivity, .high)

        noise.sensitivityFraction = 0.2
        XCTAssertEqual(noise.thresholdDBFS, -20, accuracy: 0.0001)
        XCTAssertEqual(noise.sensitivity, .low)

        noise.sensitivityFraction = 12
        XCTAssertEqual(
            noise.thresholdDBFS,
            NoiseDetectionSettings.thresholdRange.lowerBound,
            accuracy: 0.0001,
            "a slider that has drifted out of range cannot push the threshold out of it"
        )
    }

    func testMovementSensitivityRunsTheOppositeWayFromItsChangedPixelFraction() {
        var movement = MovementDetectionSettings()

        movement.sensitivityFraction = 1
        XCTAssertEqual(
            movement.changedPixelFraction,
            MovementDetectionSettings.changedPixelFractionRange.lowerBound,
            accuracy: 0.0001,
            "the smallest change is the most sensitive setting"
        )

        movement.sensitivityFraction = 0
        XCTAssertEqual(
            movement.changedPixelFraction,
            MovementDetectionSettings.changedPixelFractionRange.upperBound,
            accuracy: 0.0001
        )
    }
}
