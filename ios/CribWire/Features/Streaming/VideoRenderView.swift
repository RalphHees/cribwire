import AVFoundation
import CoreImage
import Foundation
import SwiftUI
import UIKit
import WebRTC

/// Keeps the most recent frame so the Viewer can save a still.
///
/// A Metal-backed view cannot be snapshotted with the usual `UIView` calls — the
/// content lives on the GPU and `drawHierarchy` comes back blank — so the frames
/// are tapped on their way to the renderer instead. Only the latest one is kept;
/// this is a snapshot button, not a recording.
final class VideoFrameGrabber: NSObject, RTCVideoRenderer, @unchecked Sendable {

    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let buffer = (frame?.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return }
        lock.lock()
        latest = buffer
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
        lock.unlock()
        guard let buffer else { return nil }

        let image = CIImage(cvPixelBuffer: buffer)
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
