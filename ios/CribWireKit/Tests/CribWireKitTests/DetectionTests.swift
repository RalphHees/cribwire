import XCTest
@testable import CribWireKit

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Detection logic, driven by synthetic buffers only — no microphone, no camera
/// (`docs/TASKS.md` Phase 3).
final class DetectionTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_754_850_000)

    // MARK: - Defaults

    func testBothDetectorsShipDisabledAndAreIndependent() {
        let settings = DetectionSettings.default
        XCTAssertFalse(settings.noise.isEnabled)
        XCTAssertFalse(settings.movement.isEnabled)
        XCTAssertFalse(settings.requiresCapturePipeline)

        var onlyNoise = DetectionSettings.default
        onlyNoise.noise.isEnabled = true
        XCTAssertTrue(onlyNoise.requiresCapturePipeline)
        XCTAssertFalse(onlyNoise.movement.isEnabled, "toggles must not be coupled")

        var onlyMovement = DetectionSettings.default
        onlyMovement.movement.isEnabled = true
        XCTAssertTrue(onlyMovement.requiresCapturePipeline)
        XCTAssertFalse(onlyMovement.noise.isEnabled)
    }

    func testDefaultCooldownIsThreeMinutesAndClampsToOneThroughTen() {
        XCTAssertEqual(DetectionSettings.default.cooldown, 180)
        XCTAssertEqual(DetectionSettings(cooldown: 10).cooldown, 60)
        XCTAssertEqual(DetectionSettings(cooldown: 99_999).cooldown, 600)
        XCTAssertEqual(DetectionSettings.cooldownRange, 60...600)
    }

    func testSensitivityPresetsMatchTheSpecifiedThresholds() {
        XCTAssertEqual(NoiseDetectionSettings.Sensitivity.low.thresholdDBFS, -20)
        XCTAssertEqual(NoiseDetectionSettings.Sensitivity.medium.thresholdDBFS, -30)
        XCTAssertEqual(NoiseDetectionSettings.Sensitivity.high.thresholdDBFS, -40)
        XCTAssertEqual(NoiseDetectionSettings(thresholdDBFS: -40).sensitivity, .high)
        XCTAssertEqual(NoiseDetectionSettings(thresholdDBFS: -33).sensitivity, .custom)
    }

    func testSettingsSurviveAMissingFieldAndNeverDecodeToEnabled() throws {
        // An older or truncated settings file must not silently switch a
        // detector on.
        let json = Data(#"{"cooldown":240}"#.utf8)
        let settings = try JSONDecoder().decode(DetectionSettings.self, from: json)
        XCTAssertEqual(settings.cooldown, 240)
        XCTAssertFalse(settings.noise.isEnabled)
        XCTAssertFalse(settings.movement.isEnabled)
        XCTAssertEqual(settings.movement.regionOfInterest, .full)
    }

    func testSettingsRoundTrip() throws {
        var settings = DetectionSettings.default
        settings.noise = NoiseDetectionSettings(isEnabled: true, thresholdDBFS: -35)
        settings.movement = MovementDetectionSettings(
            isEnabled: true,
            changedPixelFraction: 0.05,
            regionOfInterest: DetectionRegion(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        )
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(DetectionSettings.self, from: data), settings)
    }

    // MARK: - A-weighting

    /// Checked against the published A-weighting table. The values on the right
    /// are what an independent implementation of this same bilinear design
    /// produces at 48 kHz.
    func testWeightingCurveMatchesTheStandardTable() {
        let filter = AWeightingFilter(sampleRate: 48_000)
        XCTAssertEqual(filter.responseDB(atFrequency: 1_000), 0, accuracy: 0.01)
        XCTAssertEqual(filter.responseDB(atFrequency: 100), -19.15, accuracy: 0.1)
        XCTAssertEqual(filter.responseDB(atFrequency: 63), -26.22, accuracy: 0.1)
        XCTAssertEqual(filter.responseDB(atFrequency: 200), -10.85, accuracy: 0.1)
        XCTAssertEqual(filter.responseDB(atFrequency: 2_000), 1.20, accuracy: 0.1)
        XCTAssertEqual(filter.responseDB(atFrequency: 4_000), 0.93, accuracy: 0.1)
    }

    func testLowFrequencyRumbleIsSuppressedRelativeToSpeech() {
        // The reason for weighting at all: a fan at 100 Hz and a cry at 1 kHz at
        // the same acoustic level must not read the same.
        var filter = AWeightingFilter(sampleRate: 48_000)
        let rumble = filter.levelDBFS(of: sine(frequency: 100, sampleRate: 48_000, seconds: 1))
        filter.reset()
        let cry = filter.levelDBFS(of: sine(frequency: 1_000, sampleRate: 48_000, seconds: 1))
        XCTAssertGreaterThan(cry - rumble, 15)
    }

    func testFullScaleSineReadsZeroDBFSAndSilenceReadsTheFloor() {
        var filter = AWeightingFilter(sampleRate: 48_000)
        // 0.2 s of settling is dropped by feeding a full second and letting the
        // filter reach steady state.
        let level = filter.levelDBFS(of: sine(frequency: 1_000, sampleRate: 48_000, seconds: 2))
        XCTAssertEqual(level, 0, accuracy: 0.5)

        filter.reset()
        XCTAssertEqual(
            filter.levelDBFS(of: [Float](repeating: 0, count: 24_000)),
            AWeightingFilter.silenceFloorDB,
            accuracy: 0.001
        )
        XCTAssertEqual(filter.levelDBFS(of: []), AWeightingFilter.silenceFloorDB)
    }

    func testHalfAmplitudeSineIsSixDecibelsQuieter() {
        var filter = AWeightingFilter(sampleRate: 48_000)
        let loud = filter.levelDBFS(of: sine(frequency: 1_000, sampleRate: 48_000, seconds: 2))
        filter.reset()
        let quiet = filter.levelDBFS(
            of: sine(frequency: 1_000, sampleRate: 48_000, seconds: 2, amplitude: 0.5)
        )
        XCTAssertEqual(loud - quiet, 6.02, accuracy: 0.2)
    }

    // MARK: - Noise trigger logic

    func testNoiseNeedsAFullSecondAboveThreshold() {
        var detector = NoiseDetector(
            settings: NoiseDetectionSettings(isEnabled: true, thresholdDBFS: -30)
        )
        // One 500 ms window is not enough.
        XCTAssertEqual(detector.ingest(levelDBFS: -20, at: start), .rising)
        XCTAssertEqual(detector.ingest(levelDBFS: -20, at: start + 0.5), .triggered)
    }

    func testAGapResetsTheSustainedWindowCount() {
        var detector = NoiseDetector(
            settings: NoiseDetectionSettings(isEnabled: true, thresholdDBFS: -30)
        )
        XCTAssertEqual(detector.ingest(levelDBFS: -20, at: start), .rising)
        XCTAssertEqual(detector.ingest(levelDBFS: -45, at: start + 0.5), .idle)
        XCTAssertEqual(detector.ingest(levelDBFS: -20, at: start + 1.0), .rising)
        XCTAssertEqual(detector.ingest(levelDBFS: -20, at: start + 1.5), .triggered)
    }

    func testDisabledDetectorNeverFires() {
        var detector = NoiseDetector(settings: NoiseDetectionSettings(isEnabled: false))
        for step in 0..<20 {
            XCTAssertEqual(
                detector.ingest(levelDBFS: 0, at: start + Double(step) * 0.5),
                .idle
            )
        }
        // …but it still reports the level, so the settings screen's meter works
        // before the toggle is switched on.
        XCTAssertEqual(detector.lastLevelDBFS, 0)
    }

    func testCooldownSuppressesTheSecondEventAndExpires() {
        var detector = NoiseDetector(
            settings: NoiseDetectionSettings(isEnabled: true, thresholdDBFS: -30),
            cooldown: 180
        )
        XCTAssertEqual(detector.ingest(levelDBFS: -10, at: start), .rising)
        XCTAssertEqual(detector.ingest(levelDBFS: -10, at: start + 0.5), .triggered)

        XCTAssertEqual(detector.ingest(levelDBFS: -10, at: start + 60), .rising)
        XCTAssertEqual(detector.ingest(levelDBFS: -10, at: start + 60.5), .suppressed)
        XCTAssertNotNil(detector.cooldownEnds(after: start + 61))

        XCTAssertEqual(detector.ingest(levelDBFS: -10, at: start + 181), .rising)
        XCTAssertEqual(detector.ingest(levelDBFS: -10, at: start + 181.5), .triggered)
        XCTAssertNil(detector.cooldownEnds(after: start + 400))
    }

    func testThresholdIsInclusiveAndSensitivityOrdersAsExpected() {
        var high = NoiseDetector(
            settings: NoiseDetectionSettings(isEnabled: true, thresholdDBFS: -40)
        )
        var low = NoiseDetector(
            settings: NoiseDetectionSettings(isEnabled: true, thresholdDBFS: -20)
        )
        // A −35 dBFS sound: loud enough for "high" sensitivity, not for "low".
        _ = high.ingest(levelDBFS: -35, at: start)
        XCTAssertEqual(high.ingest(levelDBFS: -35, at: start + 0.5), .triggered)
        _ = low.ingest(levelDBFS: -35, at: start)
        XCTAssertEqual(low.ingest(levelDBFS: -35, at: start + 0.5), .idle)

        var exact = NoiseDetector(
            settings: NoiseDetectionSettings(isEnabled: true, thresholdDBFS: -30)
        )
        _ = exact.ingest(levelDBFS: -30, at: start)
        XCTAssertEqual(exact.ingest(levelDBFS: -30, at: start + 0.5), .triggered)
    }

    // MARK: - Movement

    func testMovementNeedsThreeConsecutiveChangedFrames() {
        var detector = MovementDetector(
            settings: MovementDetectionSettings(isEnabled: true, changedPixelFraction: 0.02)
        )
        let still = LumaFrame.filled(value: 40)
        let moved = still.drawing(value: 200, x: 20, y: 20, width: 40, height: 40)

        // The first frame only establishes a reference.
        XCTAssertEqual(detector.ingest(still, at: start), .idle)
        XCTAssertEqual(detector.ingest(moved, at: start + 0.5), .rising)
        XCTAssertEqual(detector.ingest(still, at: start + 1.0), .rising)
        XCTAssertEqual(detector.ingest(moved, at: start + 1.5), .triggered)
    }

    func testStillPictureNeverFires() {
        var detector = MovementDetector(
            settings: MovementDetectionSettings(isEnabled: true, changedPixelFraction: 0.02)
        )
        let still = LumaFrame.filled(value: 128)
        for step in 0..<10 {
            XCTAssertEqual(detector.ingest(still, at: start + Double(step) * 0.5), .idle)
        }
        XCTAssertEqual(detector.lastChangedFraction, 0)
    }

    func testSensorNoiseBelowThePixelDeltaIsIgnored() {
        var detector = MovementDetector(
            settings: MovementDetectionSettings(isEnabled: true, changedPixelFraction: 0.001)
        )
        let base = LumaFrame.filled(value: 100)
        // Every pixel moves, but only by less than the per-pixel delta.
        let dithered = LumaFrame.filled(value: 110)
        XCTAssertEqual(detector.ingest(base, at: start), .idle)
        XCTAssertEqual(detector.ingest(dithered, at: start + 0.5), .idle)
        XCTAssertEqual(detector.lastChangedFraction, 0)
    }

    func testRegionOfInterestIgnoresMovementOutsideIt() {
        // The curtain case from ios-app.md §2.5: movement in the right half is
        // ignored when the watch area is the left half.
        let region = DetectionRegion(x: 0, y: 0, width: 0.5, height: 1)
        var detector = MovementDetector(
            settings: MovementDetectionSettings(
                isEnabled: true,
                changedPixelFraction: 0.02,
                regionOfInterest: region
            )
        )
        let still = LumaFrame.filled(value: 40)
        let curtain = still.drawing(value: 220, x: 120, y: 0, width: 40, height: 120)
        let cot = still.drawing(value: 220, x: 10, y: 10, width: 60, height: 60)

        XCTAssertEqual(detector.ingest(still, at: start), .idle)
        XCTAssertEqual(detector.ingest(curtain, at: start + 0.5), .idle)
        XCTAssertEqual(detector.ingest(still, at: start + 1.0), .idle)
        XCTAssertEqual(detector.ingest(cot, at: start + 1.5), .rising)
    }

    func testChangedFractionIsRelativeToTheRegionNotTheFrame() {
        let still = LumaFrame.filled(value: 0)
        // A quarter of the left half changes.
        let moved = still.drawing(value: 255, x: 0, y: 0, width: 40, height: 60)
        let full = MovementDetector.changedFraction(previous: still, current: moved, region: .full)
        let leftHalf = MovementDetector.changedFraction(
            previous: still,
            current: moved,
            region: DetectionRegion(x: 0, y: 0, width: 0.5, height: 1)
        )
        XCTAssertEqual(full, 0.125, accuracy: 0.001)
        XCTAssertEqual(leftHalf, 0.25, accuracy: 0.001)
    }

    func testMovementCooldownIsRespected() {
        var detector = MovementDetector(
            settings: MovementDetectionSettings(isEnabled: true, changedPixelFraction: 0.02),
            cooldown: 180
        )
        let still = LumaFrame.filled(value: 40)
        let moved = still.drawing(value: 200, x: 0, y: 0, width: 80, height: 60)

        _ = detector.ingest(still, at: start)
        _ = detector.ingest(moved, at: start + 0.5)
        _ = detector.ingest(still, at: start + 1.0)
        XCTAssertEqual(detector.ingest(moved, at: start + 1.5), .triggered)

        _ = detector.ingest(still, at: start + 2.0)
        _ = detector.ingest(moved, at: start + 2.5)
        XCTAssertEqual(detector.ingest(still, at: start + 3.0), .suppressed)
    }

    func testResettingFrameStateDropsTheReferenceFrame() {
        var detector = MovementDetector(
            settings: MovementDetectionSettings(isEnabled: true, changedPixelFraction: 0.02)
        )
        let still = LumaFrame.filled(value: 40)
        let moved = still.drawing(value: 200, x: 0, y: 0, width: 80, height: 60)
        _ = detector.ingest(still, at: start)
        detector.resetFrameState()
        // Without a reference the jump cannot be read as movement.
        XCTAssertEqual(detector.ingest(moved, at: start + 0.5), .idle)
    }

    func testFrameSizeIsTheSpecifiedAnalysisResolution() {
        XCTAssertEqual(MovementDetector.frameWidth, 160)
        XCTAssertEqual(MovementDetector.frameHeight, 120)
        XCTAssertEqual(MovementDetector.framesPerSecond, 2)
        XCTAssertNil(LumaFrame(width: 4, height: 4, pixels: [0, 1, 2]))
    }

    // MARK: - Events

    func testEventSealsAndOpensUnderKevt() throws {
        let vectors = try TestVectors.load()
        let key = SymmetricKey(
            data: try XCTUnwrap(Data.kc_fromHex(vectors.key("k_evt").keyHex))
        )
        let pairingID = vectors.pairingUUID
        let event = DetectionEvent(type: .noise, ts: 1_754_850_000)

        let sealed = try event.sealed(using: key, pairingID: pairingID)
        XCTAssertNotNil(Data(base64Encoded: sealed))
        XCTAssertEqual(
            try DetectionEvent.open(sealed: sealed, using: key, pairingID: pairingID),
            event
        )
    }

    func testEventPlaintextMatchesTheSharedVector() throws {
        let vectors = try TestVectors.load()
        let key = SymmetricKey(
            data: try XCTUnwrap(Data.kc_fromHex(vectors.key("k_evt").keyHex))
        )
        // The vector's ciphertext must open to exactly the event this type
        // models — `{type, ts}` and nothing else.
        let event = try DetectionEvent.open(
            sealed: vectors.sealedEnvelope.event.sealedBase64,
            using: key,
            pairingID: vectors.pairingUUID
        )
        XCTAssertEqual(event.type, .noise)
        XCTAssertEqual(event.ts, 1_754_850_000)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(event)
            ) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["type", "ts"])
    }

    func testEventKindsUseTheSpecifiedWireNames() throws {
        XCTAssertEqual(DetectionEvent.Kind.noise.rawValue, "noise")
        XCTAssertEqual(DetectionEvent.Kind.motion.rawValue, "motion")
        XCTAssertEqual(DetectionEvent.Kind.lowBattery.rawValue, "low_battery")
    }

    func testEventFromAnotherPairingDoesNotOpen() throws {
        let vectors = try TestVectors.load()
        let key = SymmetricKey(
            data: try XCTUnwrap(Data.kc_fromHex(vectors.key("k_evt").keyHex))
        )
        XCTAssertThrowsError(
            try DetectionEvent.open(
                sealed: vectors.sealedEnvelope.event.sealedBase64,
                using: key,
                pairingID: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    // MARK: - Low battery

    func testLowBatteryFiresOnceAtFifteenPercent() {
        var monitor = LowBatteryMonitor()
        XCTAssertFalse(monitor.ingest(level: 0.30, isCharging: false))
        XCTAssertFalse(monitor.ingest(level: 0.18, isCharging: false))
        XCTAssertTrue(monitor.ingest(level: 0.15, isCharging: false))
        XCTAssertFalse(monitor.ingest(level: 0.14, isCharging: false), "one event per discharge")
        XCTAssertFalse(monitor.ingest(level: 0.10, isCharging: false))

        // Charging re-arms it.
        XCTAssertFalse(monitor.ingest(level: 0.16, isCharging: true))
        XCTAssertFalse(monitor.ingest(level: 0.50, isCharging: false))
        XCTAssertTrue(monitor.ingest(level: 0.12, isCharging: false))
    }

    func testUnknownBatteryLevelIsIgnored() {
        var monitor = LowBatteryMonitor()
        XCTAssertFalse(monitor.ingest(level: -1, isCharging: false))
    }

    func testWarningAppearsAtTwentyPercentAndNotWhileCharging() {
        XCTAssertTrue(LowBatteryMonitor.showsWarning(level: 0.20, isCharging: false))
        XCTAssertFalse(LowBatteryMonitor.showsWarning(level: 0.21, isCharging: false))
        XCTAssertFalse(LowBatteryMonitor.showsWarning(level: 0.10, isCharging: true))
        XCTAssertFalse(LowBatteryMonitor.showsWarning(level: -1, isCharging: false))
    }

    // MARK: - Helpers

    private func sine(
        frequency: Double,
        sampleRate: Double,
        seconds: Double,
        amplitude: Double = 1
    ) -> [Float] {
        let count = Int(sampleRate * seconds)
        var samples = [Float]()
        samples.reserveCapacity(count)
        for index in 0..<count {
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            samples.append(Float(amplitude * sin(phase)))
        }
        return samples
    }
}
