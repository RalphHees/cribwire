import CoreVideo
import Foundation
import CribWireKit
import WebRTC

/// Taps captured frames on their way into WebRTC and turns them into the tiny
/// greyscale frames the movement detector works on.
///
/// It sits *between* the capturer and the video source rather than alongside
/// them, so detection sees exactly the frames that are encoded — no second
/// capture session, no second camera client, and nothing extra running when
/// movement detection is off.
///
/// The detector wants 160×120 at 2 fps (`MovementDetector`), and the camera
/// delivers up to 1280×720 at 30. Almost all of this file is about throwing that
/// surplus away as cheaply as possible: frames outside the 2 fps budget are
/// dropped before anything is read, and the luma plane is point-sampled rather
/// than filtered, because a detector comparing frame-to-frame deltas gains
/// nothing from a nicer downscale.
final class CapturerFrameTap: NSObject, RTCVideoCapturerDelegate {

    /// The real destination. Every frame reaches it, tap or no tap.
    private let source: RTCVideoSource
    private let onLumaFrame: @Sendable (LumaFrame) -> Void

    private let lock = NSLock()
    private var isExtracting = false
    private var lastSampleNs: Int64 = 0

    /// Nanoseconds between sampled frames.
    private static let interval = Int64(1_000_000_000 / MovementDetector.framesPerSecond)

    init(source: RTCVideoSource, onLumaFrame: @escaping @Sendable (LumaFrame) -> Void) {
        self.source = source
        self.onLumaFrame = onLumaFrame
    }

    /// Turns extraction on and off without disturbing capture. Off is the
    /// default: movement detection ships disabled.
    func setExtracting(_ extracting: Bool) {
        lock.lock()
        isExtracting = extracting
        // Start from a clean slate, or the detector's first comparison is against
        // whatever the room looked like when it was last switched off.
        lastSampleNs = 0
        lock.unlock()
    }

    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        // Forwarded first and unconditionally: detection must never be able to
        // delay or drop a frame that is meant to be streamed.
        source.capturer(capturer, didCapture: frame)

        guard shouldSample(at: frame.timeStampNs) else { return }
        guard let luma = Self.lumaFrame(from: frame) else { return }
        onLumaFrame(luma)
    }

    private func shouldSample(at timeStampNs: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isExtracting else { return false }
        guard timeStampNs - lastSampleNs >= Self.interval else { return false }
        lastSampleNs = timeStampNs
        return true
    }

    // MARK: - Luma extraction

    /// Point-samples the Y plane down to the detector's fixed size.
    ///
    /// Only the bi-planar YUV formats the iOS camera produces are handled; the Y
    /// plane of those *is* the greyscale image, so there is no colour conversion
    /// to do. Anything else returns `nil` rather than a guess — a wrong frame
    /// would show up as phantom movement, which is the one failure a parent
    /// cannot ignore.
    static func lumaFrame(from frame: RTCVideoFrame) -> LumaFrame? {
        guard let buffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else {
            return nil
        }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else {
            return nil
        }

        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let sourceWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let width = MovementDetector.frameWidth
        let height = MovementDetector.frameHeight
        let plane = base.assumingMemoryBound(to: UInt8.self)

        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBufferPointer { output in
            for y in 0..<height {
                let sourceRow = y * sourceHeight / height
                let rowStart = plane + sourceRow * stride
                let outputRow = y * width
                for x in 0..<width {
                    output[outputRow + x] = rowStart[x * sourceWidth / width]
                }
            }
        }
        return LumaFrame(width: width, height: height, pixels: pixels)
    }
}
