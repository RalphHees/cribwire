import AVFoundation
import AVKit
import Combine
import Foundation
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

    /// The layer frames are enqueued on. Lives in the view hierarchy — AVKit
    /// requires it to be in a window, even though the on-screen copy is hidden
    /// behind the Metal renderer.
    let displayLayer = AVSampleBufferDisplayLayer()

    private var controller: AVPictureInPictureController?
    private var renderer: PictureInPictureRenderer?
    private var possibleObservation: NSKeyValueObservation?
    private var activeObservation: NSKeyValueObservation?

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
    }

    /// Builds the controller once the layer is in a window.
    func prepare() {
        guard Self.isSupported, controller == nil else { return }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
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
        guard let controller, controller.isPictureInPicturePossible else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    func teardown() {
        stop()
        renderer?.detach()
        renderer = nil
        possibleObservation = nil
        activeObservation = nil
        controller = nil
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
        guard let pixelBuffer = (frame?.buffer as? RTCCVPixelBuffer)?.pixelBuffer else {
            return
        }
        guard let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else { return }

        DispatchQueue.main.async { [layer] in
            // A failed layer stays failed until it is flushed; without this the
            // PiP window freezes on the last good frame and never recovers.
            if layer.status == .failed {
                layer.flush()
            }
            layer.enqueue(sampleBuffer)
        }
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

// MARK: - Layer host

/// Puts the PiP layer in the view hierarchy.
///
/// AVKit refuses to start PiP from a layer that is not in a window, so it has to
/// be present even though nothing looks at it — the visible video is the Metal
/// renderer next to it. One point square and effectively invisible, rather than
/// hidden: a layer with `isHidden` set is also refused.
struct PictureInPictureLayerHost: UIViewRepresentable {

    let controller: PictureInPictureController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.layer.addSublayer(controller.displayLayer)
        controller.displayLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        controller.prepare()
    }
}
