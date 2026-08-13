import XCTest
@testable import CribWireKit

/// Scenario tests for the false positives `docs/TASKS.md` names by hand: crying,
/// silence, pets and curtain movement.
///
/// The sibling suite in `DetectionTests` covers the *mechanisms* — a sustain
/// window, a cooldown, three consecutive frames. This one covers the *situations*
/// a nursery actually produces, driving the detectors with the shape of signal
/// each one makes and asserting what a parent would expect.
///
/// **These are synthesised, not recorded.** They pin the decision boundaries
/// against realistic signal shapes, which is what makes a regression here
/// visible. They cannot establish a real false-positive rate: that needs actual
/// clips of a real baby, a real cat and a real curtain, and it remains open in
/// `docs/TASKS.md`.
final class NoiseScenarioTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_754_850_000)
    /// The 500 ms analysis window the detector works in.
    private let window = NoiseDetector.windowDuration

    private func detector(threshold: Double = -30) -> NoiseDetector {
        NoiseDetector(
            settings: NoiseDetectionSettings(isEnabled: true, thresholdDBFS: threshold),
            cooldown: 180
        )
    }

    /// Feeds a level sequence and returns every outcome.
    private func run(
        _ detector: inout NoiseDetector,
        levels: [Double],
        from offset: TimeInterval = 0
    ) -> [DetectionOutcome] {
        levels.enumerated().map { index, level in
            detector.ingest(
                levelDBFS: level,
                at: start + offset + Double(index) * window
            )
        }
    }

    /// A quiet room for two minutes. The one case that must never produce an
    /// alert, because a monitor that cries wolf at 3 a.m. gets switched off.
    func testAnHourOfSilenceNeverFires() {
        var detector = self.detector()
        let outcomes = run(&detector, levels: Array(repeating: -70, count: 240))
        XCTAssertTrue(outcomes.allSatisfy { $0 == .idle })
    }

    /// Sustained crying: loud, and it stays loud. Fires once, then the cooldown
    /// holds until it expires — a baby crying for ten minutes is one alert, not
    /// twenty.
    func testSustainedCryingFiresOnceThenRespectsTheCooldown() {
        var detector = self.detector()
        let outcomes = run(&detector, levels: Array(repeating: -18, count: 120))

        XCTAssertEqual(outcomes.filter { $0 == .triggered }.count, 1)
        XCTAssertEqual(outcomes.firstIndex(of: .triggered), 1)
        // Sixty seconds of continuous crying, one alert. After the trigger the
        // sustain window starts over, so the tail alternates `rising` (first
        // window of a fresh second) and `suppressed` (the second window, which
        // would have fired had the cooldown not been running) — and never fires.
        let tail = outcomes.dropFirst(2)
        XCTAssertTrue(tail.contains(.suppressed))
        XCTAssertTrue(tail.allSatisfy { $0 == .rising || $0 == .suppressed })
    }

    /// A door click, a cot creak, a dropped toy: loud for well under a second.
    /// The 1 s sustain window exists exactly to swallow these.
    func testSingleTransientDoesNotFire() {
        var detector = self.detector()
        let outcomes = run(&detector, levels: [-70, -70, -8, -70, -70, -70])
        XCTAssertFalse(outcomes.contains(.triggered))
    }

    /// A dog barking in another room, or a cat knocking something over:
    /// intermittent bursts with quiet between them. Each burst is shorter than
    /// the sustain window, and the gaps reset it.
    func testIntermittentPetNoiseDoesNotFire() {
        var detector = self.detector()
        // One loud window, one quiet, repeated — never two loud in a row.
        let levels = (0..<60).map { $0.isMultiple(of: 2) ? -12.0 : -70.0 }
        let outcomes = run(&detector, levels: levels)
        XCTAssertFalse(outcomes.contains(.triggered))
    }

    /// Traffic, a fan, a humidifier: continuously present but below the
    /// threshold. Must not fire, and must not creep up on it either.
    func testSteadyBackgroundHumBelowThresholdNeverFires() {
        var detector = self.detector(threshold: -30)
        let outcomes = run(&detector, levels: Array(repeating: -34, count: 240))
        XCTAssertTrue(outcomes.allSatisfy { $0 == .idle })
    }

    /// Crying that starts quiet and builds. It should fire when it crosses, not
    /// before — and the ramp below the threshold must not bank progress.
    func testARampFiresOnlyOnceItIsGenuinelyLoud() {
        var detector = self.detector(threshold: -30)
        let ramp = stride(from: -60.0, through: -10.0, by: 5).map { $0 }
        let outcomes = run(&detector, levels: ramp)

        let triggerIndex = try? XCTUnwrap(outcomes.firstIndex(of: .triggered))
        XCTAssertNotNil(triggerIndex)
        // -30 is the first level at or above the threshold, at index 6; a full
        // second means the trigger lands one window later.
        XCTAssertEqual(triggerIndex, 7)
    }
}

/// Movement scenarios: a curtain at the edge of frame, a pet crossing, the room
/// slowly getting lighter, and the camera's own exposure hunting.
final class MovementScenarioTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_754_850_000)
    private let width = MovementDetector.frameWidth
    private let height = MovementDetector.frameHeight
    /// The detector's own 2 fps cadence.
    private let step = 1.0 / Double(MovementDetector.framesPerSecond)

    private func detector(
        fraction: Double = 0.02,
        region: DetectionRegion = .full
    ) -> MovementDetector {
        MovementDetector(
            settings: MovementDetectionSettings(
                isEnabled: true,
                changedPixelFraction: fraction,
                regionOfInterest: region
            ),
            cooldown: 180
        )
    }

    private func frame(_ base: UInt8) -> LumaFrame {
        LumaFrame.filled(width: width, height: height, value: base)
    }

    /// A frame with a fractional rectangle painted a different brightness.
    /// Fractions rather than pixels so the scenarios read as "a strip down the
    /// left edge" rather than as arithmetic.
    private func frame(
        _ base: UInt8,
        patch: (x: Double, y: Double, width: Double, height: Double),
        value: UInt8
    ) -> LumaFrame {
        frame(base).drawing(
            value: value,
            x: Int(patch.x * Double(width)),
            y: Int(patch.y * Double(height)),
            width: Int(patch.width * Double(width)),
            height: Int(patch.height * Double(height))
        )
    }

    private func run(
        _ detector: inout MovementDetector,
        frames: [LumaFrame]
    ) -> [DetectionOutcome] {
        frames.enumerated().map { index, frame in
            detector.ingest(frame, at: start + Double(index) * step)
        }
    }

    /// An empty, still room. No alert, ever.
    func testAStillRoomNeverFires() {
        var detector = self.detector()
        let outcomes = run(&detector, frames: Array(repeating: frame(120), count: 60))
        XCTAssertFalse(outcomes.contains(.triggered))
    }

    /// Dawn: the whole frame brightens, but slowly. Each 500 ms step is far below
    /// the per-pixel delta, so nothing counts as changed however long it runs.
    func testGradualDawnLightNeverFires() {
        var detector = self.detector()
        // +2 luma per frame, well under the delta of 24, for two minutes.
        let frames = (0..<120).map { frame(UInt8(60 + $0)) }
        let outcomes = run(&detector, frames: frames)
        XCTAssertFalse(outcomes.contains(.triggered))
    }

    /// The camera's auto-exposure snapping: one frame jumps, then it settles.
    /// Three consecutive changed frames are required, so a single jump is not
    /// enough.
    func testSingleExposureJumpDoesNotFire() {
        var detector = self.detector()
        let outcomes = run(
            &detector,
            frames: [frame(100), frame(100), frame(180), frame(180), frame(180)]
        )
        // Frames 3 and 4 are identical to their predecessor, so the streak dies
        // after the single jump.
        XCTAssertFalse(outcomes.contains(.triggered))
    }

    /// A curtain moving at the edge of frame, with the region of interest drawn
    /// around the cot in the middle. The whole point of the ROI editor.
    func testCurtainOutsideTheRegionOfInterestDoesNotFire() {
        var detector = self.detector(
            region: DetectionRegion(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        )
        let curtain = (x: 0.0, y: 0.0, width: 0.15, height: 1.0)
        let frames = (0..<10).map { index in
            index.isMultiple(of: 2)
                ? frame(100)
                : frame(100, patch: curtain, value: 220)
        }
        let outcomes = run(&detector, frames: frames)
        XCTAssertFalse(outcomes.contains(.triggered))
    }

    /// The same curtain with no region set. It *should* fire — this is what the
    /// ROI is for, and the test pins that the region is the thing making the
    /// difference rather than the movement being too small to see.
    func testTheSameCurtainFiresWithNoRegionSet() {
        var detector = self.detector(region: .full)
        let curtain = (x: 0.0, y: 0.0, width: 0.15, height: 1.0)
        let frames = (0..<10).map { index in
            index.isMultiple(of: 2)
                ? frame(100)
                : frame(100, patch: curtain, value: 220)
        }
        XCTAssertTrue(run(&detector, frames: frames).contains(.triggered))
    }

    /// A cat crossing the corner of the room: a small area, below the fraction
    /// the user set. Movement, but not enough of it to be the baby.
    func testSmallPetSizedMovementStaysBelowTheAreaThreshold() {
        var detector = self.detector(fraction: 0.10)
        // ~2 % of the frame, well under the 10 % the user asked for.
        let pet = (x: 0.02, y: 0.80, width: 0.15, height: 0.15)
        let frames = (0..<12).map { index in
            index.isMultiple(of: 2) ? frame(100) : frame(100, patch: pet, value: 200)
        }
        XCTAssertFalse(run(&detector, frames: frames).contains(.triggered))
    }

    /// A baby sitting up in the cot: a large, sustained change in the middle of
    /// the region. This has to fire, or the feature does nothing.
    func testChildMovingInTheCotFires() {
        var detector = self.detector(fraction: 0.02, region: .full)
        let child = (x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        var frames = [frame(100)]
        // Three consecutive frames that each differ from the last by more than
        // the per-pixel delta of 24 — a smaller step would be read as sensor
        // noise, which is the behaviour the sibling test pins.
        for index in 0..<4 {
            frames.append(
                frame(100, patch: child, value: UInt8(180 + index * 25))
            )
        }
        XCTAssertTrue(run(&detector, frames: frames).contains(.triggered))
    }
}
