import AVFoundation
import AVKit
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import OSLog
import SwiftUI
import UIKit
import WebRTC

/// Picture-in-Picture for the Viewer (`docs/TASKS.md` Phase 4).
///
/// PiP is the feature that makes CribWire usable as an actual baby monitor: the
/// parent keeps the cot in a corner of the screen while reading, messaging, or
/// doing anything else. Without it, watching means giving the phone up entirely.
///
/// WebRTC does not render into anything AVKit understands, so the frames are
/// converted: each `RTCVideoFrame` becomes a `CMSampleBuffer` and is enqueued on
/// an `AVSampleBufferDisplayLayer`, which is one of the two content sources
/// `AVPictureInPictureController` accepts. The alternative — an `AVPlayerLayer` —
/// has no way to accept live frames at all.
///
/// Only the hardware-decoded path is handled, the same choice the snapshot code
/// makes: VideoToolbox produces `CVPixelBuffer`s, and a software-decoded I420
/// frame is dropped rather than converted on the main thread at 30 fps.
@MainActor
final class PictureInPictureController: NSObject, ObservableObject {

    /// Whether the device can do PiP at all. iPhones gained video PiP in iOS 14,
    /// but it is still absent on some hardware, and the button must not be shown
    /// where it cannot work.
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false

    /// Why the last attempt to open the mini window came to nothing.
    ///
    /// AVKit reports a refusal to the delegate and does nothing else, so without
    /// this the button is simply inert — the user taps, the screen does not
    /// change, and there is nowhere to look. The screen drains this into a toast.
    @Published private(set) var lastError: String?

    /// The layer frames are enqueued on. Lives in the view hierarchy at the full
    /// size of the video area — AVKit starts the mini window *from* this layer
    /// and will not do so for one that has no window (see `PiPLayerView`).
    let displayLayer = AVSampleBufferDisplayLayer()

    private static let log = Logger(subsystem: "com.ralphhees.cribwire", category: "pip")

    private var controller: AVPictureInPictureController?
    private var renderer: PictureInPictureRenderer?
    private var possibleObservation: NSKeyValueObservation?
    private var activeObservation: NSKeyValueObservation?

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    /// Builds the controller. Called once the layer is in a window, never before:
    /// AVKit answers "PiP is not possible" for a windowless layer, and the KVO
    /// set up here is the only thing that ever un-greys the button.
    func prepare() {
        guard Self.isSupported, controller == nil else { return }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // The stream is live and cannot be scrubbed, so the transport controls
        // would be inert decoration.
        controller.requiresLinearPlayback = true
        self.controller = controller

        possibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            Task { @MainActor in
                self?.isPossible = controller.isPictureInPicturePossible
            }
        }
        activeObservation = controller.observe(
            \.isPictureInPictureActive,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            Task { @MainActor in
                self?.isActive = controller.isPictureInPictureActive
            }
        }
    }

    /// Points the converter at a track. Passing `nil` detaches it.
    func attach(track: RTCVideoTrack?) {
        if let renderer {
            renderer.detach()
            self.renderer = nil
        }
        guard let track else { return }
        let renderer = PictureInPictureRenderer(layer: displayLayer)
        renderer.attach(to: track)
        self.renderer = renderer
    }

    func start() {
        guard let controller else {
            lastError = String(localized: "Mini view is not ready yet.")
            return
        }
        // `isPictureInPicturePossible` goes false while another app holds the
        // system's one PiP window, among other reasons. Returning quietly here is
        // what made this look broken.
        guard controller.isPictureInPicturePossible else {
            lastError = String(localized: "Mini view is not available right now.")
            return
        }
        lastError = nil
        controller.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    func clearError() {
        lastError = nil
    }

    func teardown() {
        stop()
        renderer?.detach()
        renderer = nil
        possibleObservation = nil
        activeObservation = nil
        controller?.delegate = nil
        controller = nil
    }
}

// MARK: - Lifecycle delegate

/// The half of PiP that reports what AVKit decided.
///
/// Adopting this is not optional in practice: a start can fail for reasons the
/// app cannot see coming, and `restoreUserInterfaceForPictureInPictureStop` is
/// the only thing that makes the mini window's "back to the app" button do
/// anything.
extension PictureInPictureController: AVPictureInPictureControllerDelegate {

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            Self.log.error("PiP failed to start: \(error.localizedDescription, privacy: .public)")
            self.isActive = false
            self.lastError = String(localized: "Mini view could not start.")
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        // The live screen is still mounted behind the mini window — there is
        // nothing to rebuild, only to admit that the restore succeeded.
        completionHandler(true)
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.isActive = controller.isPictureInPictureActive
        }
    }
}

// MARK: - Playback delegate

/// A live stream, expressed in the terms AVKit expects.
///
/// AVKit's model is a player with a timeline; CribWire has neither. The answers
/// below say so as directly as the API allows: an infinite time range, never
/// paused, and a no-op for every transport control.
extension PictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        // A live feed with no beginning and no end.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        // Nothing to skip on a live stream; the callback still has to be made or
        // AVKit waits for ever.
        completionHandler()
    }
}

// MARK: - Frame conversion

/// Converts WebRTC frames into sample buffers for the PiP layer.
///
/// Not an actor and not main-actor bound: `renderFrame` is called from
/// libwebrtc's decoder thread, and hopping to the main actor per frame would put
/// a 30 fps conversion on the same queue as the UI.
final class PictureInPictureRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {

    private let layer: AVSampleBufferDisplayLayer
    private weak var track: RTCVideoTrack?
    private let rotator = PixelBufferRotator()
    private var formatDescription: CMVideoFormatDescription?
    /// Frame counter used to synthesise presentation timestamps. WebRTC's own
    /// timestamps are relative to an arbitrary epoch and can jump on a
    /// reconnect, which AVKit reads as a broken timeline.
    private var frameIndex: Int64 = 0

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    func attach(to track: RTCVideoTrack) {
        self.track = track
        track.add(self)
    }

    func detach() {
        track?.remove(self)
        track = nil
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let decoded = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else {
            return
        }
        // The rotation tag has to be turned into actual pixels here. AVKit
        // renders these buffers itself in its own window, so neither the tag nor
        // a transform on this layer reaches the mini window — only the buffer
        // does. Skipping this is what put the cot on its side.
        guard let pixelBuffer = rotator.rotate(decoded, by: frame.rotation) else { return }
        guard let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else { return }

        // Enqueued straight from the decoder thread. `AVQueuedSampleBufferRendering`
        // is built to be driven from one serial queue of the caller's choosing,
        // and this renderer is already called serially — bouncing every frame off
        // the main queue only put 30 hops a second in front of the UI.
        //
        // A failed layer stays failed until it is flushed; without this the PiP
        // window freezes on the last good frame and never recovers. Backgrounding
        // the app is one of the things that fails it.
        if layer.status == .failed {
            layer.flush()
        }
        layer.enqueue(sampleBuffer)
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        if formatDescription == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer)
        {
            var created: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &created
            ) == noErr else {
                return nil
            }
            formatDescription = created
        }
        guard let formatDescription else { return nil }

        frameIndex += 1
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 30),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }

        // Live video: show each frame as it arrives rather than scheduling it
        // against a clock the stream does not have.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) as? [CFMutableDictionary], let first = attachments.first {
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}

// MARK: - Rotation

/// Turns decoded frames upright, on the GPU.
///
/// Core Image rather than a hand-written shader or a CPU transpose: the render
/// is a single hardware pass, and the alternative at 720p30 is either a second
/// Metal pipeline to maintain or a frame budget spent on memory traffic.
///
/// Output buffers come from a pool with a hard ceiling. An unbounded pool is a
/// slow leak whenever the display layer holds frames longer than the decoder
/// takes to produce them; a frame dropped at the ceiling costs 33 ms of mini
/// window and nothing else.
final class PixelBufferRotator {

    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolFormat: OSType = 0

    private static let poolCeiling = 8

    /// The frame the right way up, or the frame itself when it already is.
    func rotate(_ buffer: CVPixelBuffer, by rotation: RTCVideoRotation) -> CVPixelBuffer? {
        let orientation = rotation.imageOrientation
        guard orientation != .up else { return buffer }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let outputWidth = rotation.swapsAxes ? height : width
        let outputHeight = rotation.swapsAxes ? width : height

        guard let pool = bufferPool(width: outputWidth, height: outputHeight, format: format),
              let output = Self.buffer(from: pool)
        else {
            return nil
        }

        context.render(CIImage(cvPixelBuffer: buffer).oriented(orientation), to: output)
        return output
    }

    private func bufferPool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        if let pool, poolWidth == width, poolHeight == height, poolFormat == format {
            return pool
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // Without an IOSurface the display layer cannot show the buffer
            // without copying it back through the CPU first.
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &created
        ) == kCVReturnSuccess else {
            return nil
        }
        pool = created
        poolWidth = width
        poolHeight = height
        poolFormat = format
        return created
    }

    private static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        let auxiliary: [String: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey as String: poolCeiling
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            auxiliary as CFDictionary,
            &buffer
        ) == kCVReturnSuccess else {
            // `kCVReturnWouldExceedAllocationThreshold`: the layer is still
            // holding every buffer the pool has. Drop this frame.
            return nil
        }
        return buffer
    }
}

// MARK: - Layer host

/// Puts the PiP layer in the view hierarchy.
///
/// AVKit refuses to start PiP from a layer that is not in a window, and the
/// layer it is handed is the one it sizes and animates the mini window out of —
/// a one-point decoy is not enough. So the layer is laid out at the full size of
/// the video area and sits *behind* the Metal renderer, which is opaque and
/// covers it completely. Compositing the same decoded buffer twice is the price
/// of a mini window that opens at all.
struct PictureInPictureLayerHost: UIViewRepresentable {

    let controller: PictureInPictureController

    func makeUIView(context: Context) -> PiPLayerView {
        PiPLayerView(controller: controller)
    }

    func updateUIView(_ view: PiPLayerView, context: Context) {}
}

final class PiPLayerView: UIView {

    private let controller: PictureInPictureController

    init(controller: PictureInPictureController) {
        self.controller = controller
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .black
        layer.addSublayer(controller.displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this view is only made in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Actions off: a sublayer frame change animates by default, so every
        // rotation and split-view resize would slide the video into place.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        controller.displayLayer.frame = bounds
        CATransaction.commit()
    }

    /// Builds the controller here rather than on `init`. This is the first moment
    /// the layer has a window, and asking AVKit before that gets a permanent "not
    /// possible" — which reached the user as a Mini view button that never
    /// stopped being greyed out.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        controller.prepare()
    }
}
