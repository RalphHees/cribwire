import AVFoundation
import CoreImage
import Foundation
import ImageIO
import SwiftUI
import UIKit
import WebRTC

/// How a decoded frame has to be turned before it is the right way up.
///
/// The Camera does **not** rotate pixels before encoding: `RTCCameraVideoCapturer`
/// sends the sensor's landscape buffer and tags the frame with the turn the
/// receiver should apply, which costs the Camera nothing and is what WebRTC's
/// orientation extension is for. `RTCMTLVideoView` applies that tag when it
/// draws — so anything else that consumes these frames has to apply it too, or
/// it shows a phone-in-portrait nursery lying on its side.
extension RTCVideoRotation {

    var imageOrientation: CGImagePropertyOrientation {
        switch self {
        case ._0: return .up
        case ._90: return .right
        case ._180: return .down
        case ._270: return .left
        @unknown default: return .up
        }
    }

    /// Whether the turn swaps width and height.
    var swapsAxes: Bool {
        self == ._90 || self == ._270
    }
}

/// Keeps the most recent frame so the Viewer can save a still.
///
/// A Metal-backed view cannot be snapshotted with the usual `UIView` calls — the
/// content lives on the GPU and `drawHierarchy` comes back blank — so the frames
/// are tapped on their way to the renderer instead. Only the latest one is kept;
/// this is a snapshot button, not a recording.
final class VideoFrameGrabber: NSObject, RTCVideoRenderer, @unchecked Sendable {

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    /// Stored alongside the buffer: the pixels are landscape whatever way the
    /// Camera is held, and the rotation is the only thing that says so.
    private var latestRotation: RTCVideoRotation = ._0

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let buffer = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else {
            return
        }
        lock.lock()
        latest = buffer
        latestRotation = frame.rotation
        lock.unlock()
    }

    /// The latest frame as an image, or `nil` if nothing has arrived yet.
    ///
    /// Only the VideoToolbox path (a `CVPixelBuffer`) is handled: that is what
    /// hardware H.264 decoding produces on every device CribWire supports. A
    /// software-decoded I420 frame yields no snapshot rather than a wrong one.
    func snapshot() -> UIImage? {
        lock.lock()
        let buffer = latest
        let rotation = latestRotation
        lock.unlock()
        guard let buffer else { return nil }

        let image = CIImage(cvPixelBuffer: buffer).oriented(rotation.imageOrientation)
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

/// SwiftUI wrapper around `RTCMTLVideoView`.
///
/// `RTCMTLVideoView` renders on the GPU, which is the only way a phone sustains
/// 720p30 without cooking its battery. The track is attached and detached in
/// `updateUIView` so a reconnect — which produces a brand-new track object —
/// re-binds without rebuilding the view.
struct VideoRenderView: UIViewRepresentable {

    let track: RTCVideoTrack?
    /// Optional frame tap for the snapshot button.
    var grabber: VideoFrameGrabber?
    /// `.scaleAspectFit` letterboxes; `.scaleAspectFill` crops. A nursery view
    /// wants the whole frame.
    var contentMode: UIView.ContentMode = .scaleAspectFit

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = contentMode
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        let previous = context.coordinator.track
        guard previous !== track else { return }

        if let previous {
            previous.remove(view)
            if let grabber { previous.remove(grabber) }
        }
        if let track {
            track.add(view)
            if let grabber { track.add(grabber) }
        }
        context.coordinator.track = track
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
        coordinator.track = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Holds the currently attached track so `updateUIView` can tell a genuine
    /// change from SwiftUI simply re-running the body.
    final class Coordinator {
        var track: RTCVideoTrack?
    }
}
