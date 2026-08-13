import AVFoundation
import CoreVideo
import CribWireKit
import WebRTC
import XCTest
@testable import CribWire

/// Streaming-layer tests that need no camera, no network and no second device.
///
/// The parts of Phase 2 that *can* be asserted on a build machine are the pure
/// decisions: how a statistics sample maps onto the indicator a parent reads, how
/// settings survive a round trip, and whether a frame tap produces an image.
/// Everything else about streaming — that video actually flows, that a
/// Wi-Fi→cellular switch recovers — needs two physical devices and is called out
/// as unverified in `docs/TASKS.md` rather than faked here.
final class LinkQualityTests: XCTestCase {

    private func sample(
        bitrate: Int = 2_000,
        loss: Double = 0,
        rtt: TimeInterval = 0.05
    ) -> AdaptiveQualityController.Sample {
        AdaptiveQualityController.Sample(
            availableBitrateKbps: bitrate,
            packetLossFraction: loss,
            roundTripTime: rtt
        )
    }

    func testCleanLinkReadsGood() {
        XCTAssertEqual(StreamingEngine.linkQuality(for: sample()), .good)
    }

    func testModerateLossOrLatencyReadsFair() {
        XCTAssertEqual(StreamingEngine.linkQuality(for: sample(loss: 0.03)), .fair)
        XCTAssertEqual(StreamingEngine.linkQuality(for: sample(rtt: 0.3)), .fair)
    }

    func testHeavyLossOrLatencyReadsPoor() {
        XCTAssertEqual(StreamingEngine.linkQuality(for: sample(loss: 0.2)), .poor)
        XCTAssertEqual(StreamingEngine.linkQuality(for: sample(rtt: 1.0)), .poor)
    }

    /// Loss and latency outrank bandwidth: a link with plenty of headroom that is
    /// dropping packets is a bad link, and the indicator must not call it good.
    func testLossOutranksAmpleBandwidth() {
        XCTAssertEqual(
            StreamingEngine.linkQuality(for: sample(bitrate: 50_000, loss: 0.2)),
            .poor
        )
    }
}

/// Both detectors default to off, and must stay off through anything unreadable
/// — a settings file that fails to decode may never silently enable a detector
/// the user did not ask for.
final class DetectionSettingsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "cribwire.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsWhenNothingIsStored() {
        let settings = DetectionSettingsStore(defaults: defaults).load()
        XCTAssertFalse(settings.noise.isEnabled)
        XCTAssertFalse(settings.movement.isEnabled)
        XCTAssertFalse(settings.requiresCapturePipeline)
    }

    func testRoundTripsThroughDefaults() {
        let store = DetectionSettingsStore(defaults: defaults)
        var settings = DetectionSettings.default
        settings.noise.isEnabled = true
        settings.cooldown = 300
        store.save(settings)

        let loaded = DetectionSettingsStore(defaults: defaults).load()
        XCTAssertTrue(loaded.noise.isEnabled)
        XCTAssertEqual(loaded.cooldown, 300)
        XCTAssertTrue(loaded.requiresCapturePipeline)
    }

    func testUnreadableDataFallsBackToDetectorsOff() {
        defaults.set(Data("not json".utf8), forKey: DetectionSettingsStore.key)
        let settings = DetectionSettingsStore(defaults: defaults).load()
        XCTAssertFalse(settings.requiresCapturePipeline)
    }
}

/// The Viewer's snapshot path. A Metal view cannot be snapshotted with UIKit, so
/// the frames are tapped on the way to the renderer — this is that tap.
final class VideoFrameGrabberTests: XCTestCase {

    func testProducesNoImageBeforeAnyFrameArrives() {
        XCTAssertNil(VideoFrameGrabber().snapshot())
    }

    func testProducesAnImageMatchingTheFrameItReceived() throws {
        let grabber = VideoFrameGrabber()
        let buffer = try makePixelBuffer(width: 64, height: 48)
        grabber.renderFrame(
            RTCVideoFrame(
                buffer: RTCCVPixelBuffer(pixelBuffer: buffer),
                rotation: ._0,
                timeStampNs: 0
            )
        )

        let image = try XCTUnwrap(grabber.snapshot())
        XCTAssertEqual(image.size.width, 64)
        XCTAssertEqual(image.size.height, 48)
    }

    /// A nil frame must not clear a good one: the snapshot button should still
    /// work after a hiccup in the decoder.
    func testNilFrameLeavesTheLastImageIntact() throws {
        let grabber = VideoFrameGrabber()
        grabber.renderFrame(
            RTCVideoFrame(
                buffer: RTCCVPixelBuffer(pixelBuffer: try makePixelBuffer(width: 32, height: 32)),
                rotation: ._0,
                timeStampNs: 0
            )
        )
        grabber.renderFrame(nil)
        XCTAssertNotNil(grabber.snapshot())
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}

/// The bridge between what the camera captures and what the movement detector
/// compares. A wrong frame here shows up as phantom movement, so the failure
/// modes matter as much as the happy path.
final class LumaFrameExtractionTests: XCTestCase {

    func testExtractsTheDetectorsFixedSizeFromALargerFrame() throws {
        let frame = try makeFrame(width: 1280, height: 720, luma: 200)
        let luma = try XCTUnwrap(CapturerFrameTap.lumaFrame(from: frame))

        XCTAssertEqual(luma.width, MovementDetector.frameWidth)
        XCTAssertEqual(luma.height, MovementDetector.frameHeight)
        XCTAssertEqual(luma.pixels.count, MovementDetector.frameWidth * MovementDetector.frameHeight)
        // A uniformly bright plane must survive downsampling unchanged; anything
        // else means the stride or plane arithmetic is off.
        XCTAssertTrue(luma.pixels.allSatisfy { $0 == 200 })
    }

    /// Point-sampling must read the Y plane, not the chroma plane that follows
    /// it, and must respect the row stride rather than assuming width == stride.
    func testReadsTheLumaPlaneAtTheCorrectStride() throws {
        let frame = try makeFrame(width: 640, height: 480, luma: 17)
        let luma = try XCTUnwrap(CapturerFrameTap.lumaFrame(from: frame))
        XCTAssertTrue(luma.pixels.allSatisfy { $0 == 17 })
    }

    /// An unexpected pixel format yields nothing rather than a misread buffer.
    func testRefusesANonPlanarFormat() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer),
            kCVReturnSuccess
        )
        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(buffer)),
            rotation: ._0,
            timeStampNs: 0
        )
        XCTAssertNil(CapturerFrameTap.lumaFrame(from: frame))
    }

    /// A bi-planar YUV frame with the Y plane filled to `luma`.
    private func makeFrame(width: Int, height: Int, luma: UInt8) throws -> RTCVideoFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let plane = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) {
            memset(plane + row * stride, Int32(luma), CVPixelBufferGetWidthOfPlane(pixelBuffer, 0))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        return RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: ._0,
            timeStampNs: 0
        )
    }
}
