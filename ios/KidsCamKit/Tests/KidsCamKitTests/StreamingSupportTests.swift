import XCTest
@testable import KidsCamKit

/// Reconnect backoff and the adaptive-quality ladder — the two pieces of the
/// streaming engine that are pure decisions rather than WebRTC calls.
final class StreamingSupportTests: XCTestCase {

    // MARK: - Backoff

    func testBackoffDoublesFromOneSecondAndCapsAtThirty() {
        let policy = ReconnectPolicy()
        let delays = (1...8).map { policy.delay(forAttempt: $0, randomUnit: 0.5) }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testJitterStaysWithinItsFraction() {
        let policy = ReconnectPolicy(jitterFraction: 0.2)
        XCTAssertEqual(policy.delay(forAttempt: 3, randomUnit: 0), 3.2, accuracy: 0.0001)
        XCTAssertEqual(policy.delay(forAttempt: 3, randomUnit: 1), 4.8, accuracy: 0.0001)
        // Out-of-range randomness is clamped rather than trusted.
        XCTAssertEqual(policy.delay(forAttempt: 3, randomUnit: 9), 4.8, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(policy.delay(forAttempt: 1, randomUnit: 0), 0)
    }

    func testAttemptZeroIsImmediate() {
        XCTAssertEqual(ReconnectPolicy().delay(forAttempt: 0), 0)
    }

    func testICERestartIsPreferredExceptWhenSignalingIsDown() {
        XCTAssertTrue(ReconnectTrigger.networkPathChanged.prefersICERestart)
        XCTAssertTrue(ReconnectTrigger.iceFailure.prefersICERestart)
        XCTAssertFalse(ReconnectTrigger.signalingClosed.prefersICERestart)
    }

    // MARK: - Quality ladder

    func testDefaultQualityIsTheSpecifiedSixFortyByFourEighty() {
        XCTAssertEqual(VideoQuality.standard.width, 640)
        XCTAssertEqual(VideoQuality.standard.height, 480)
        XCTAssertEqual(VideoQuality.standard.fps, 15)
        XCTAssertEqual(VideoQuality.high.width, 1280)
        XCTAssertEqual(VideoQuality.high.fps, 30)
        XCTAssertEqual(VideoQuality.low.width, 320)
        XCTAssertEqual(AdaptiveQualityController().current, .standard)
    }

    func testThreeBadSamplesDropOneRung() {
        var controller = AdaptiveQualityController()
        let bad = AdaptiveQualityController.Sample(
            availableBitrateKbps: 120,
            packetLossFraction: 0.12,
            roundTripTime: 0.4
        )
        XCTAssertNil(controller.ingest(bad))
        XCTAssertNil(controller.ingest(bad))
        XCTAssertEqual(controller.ingest(bad), .low)
        // Already at the bottom: nothing left to drop to.
        XCTAssertNil(controller.ingest(bad))
        XCTAssertNil(controller.ingest(bad))
        XCTAssertNil(controller.ingest(bad))
        XCTAssertEqual(controller.current, .low)
    }

    func testOneBadSampleDoesNotChangeQuality() {
        var controller = AdaptiveQualityController()
        let bad = AdaptiveQualityController.Sample(
            availableBitrateKbps: 100,
            packetLossFraction: 0.2,
            roundTripTime: 1.0
        )
        let good = AdaptiveQualityController.Sample(
            availableBitrateKbps: 900,
            packetLossFraction: 0,
            roundTripTime: 0.05
        )
        XCTAssertNil(controller.ingest(bad))
        XCTAssertNil(controller.ingest(good))
        XCTAssertNil(controller.ingest(bad))
        XCTAssertNil(controller.ingest(bad))
        XCTAssertEqual(controller.current, .standard, "a bad sample streak must be consecutive")
    }

    func testClimbingNeedsSustainedHeadroom() {
        var controller = AdaptiveQualityController()
        // Enough for 720p (1800 kbps) plus 30 % headroom.
        let plenty = AdaptiveQualityController.Sample(
            availableBitrateKbps: 3_000,
            packetLossFraction: 0,
            roundTripTime: 0.03
        )
        for _ in 0..<7 {
            XCTAssertNil(controller.ingest(plenty))
        }
        XCTAssertEqual(controller.ingest(plenty), .high)
        // And it never skips a rung on the way up.
        XCTAssertEqual(controller.current, .high)
    }

    func testGoodButNarrowLinkStaysPut() {
        var controller = AdaptiveQualityController()
        // Comfortable for 480p, nowhere near 720p.
        let modest = AdaptiveQualityController.Sample(
            availableBitrateKbps: 700,
            packetLossFraction: 0,
            roundTripTime: 0.05
        )
        for _ in 0..<20 {
            XCTAssertNil(controller.ingest(modest))
        }
        XCTAssertEqual(controller.current, .standard)
    }

    func testLatencyAloneCanForceADowngrade() {
        var controller = AdaptiveQualityController()
        // Plenty of bandwidth, but a second of round-trip: the parent would be
        // watching the past, so drop the rung.
        let laggy = AdaptiveQualityController.Sample(
            availableBitrateKbps: 5_000,
            packetLossFraction: 0,
            roundTripTime: 1.2
        )
        _ = controller.ingest(laggy)
        _ = controller.ingest(laggy)
        XCTAssertEqual(controller.ingest(laggy), .low)
    }
}
