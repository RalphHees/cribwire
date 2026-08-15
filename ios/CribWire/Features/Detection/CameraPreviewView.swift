import AVFoundation
import Foundation
import CribWireKit
import SwiftUI
import UIKit

/// A plain camera preview, for choosing the movement watch area.
///
/// Deliberately **not** the streaming pipeline. `CameraCaptureController` belongs
/// to `StreamingEngine`, which is not running while the alerts screen is open, and
/// starting it would drag in encoders, a peer connection and a detector for a
/// picture nobody is watching. This is an `AVCaptureSession` with a preview layer
/// and no outputs at all — the cheapest way to answer "what is the camera looking
/// at", which is the only question the region editor needs answered.
///
/// It uses the same camera the Camera role streams from, so the framing a user
/// draws a box on is the framing the detector will see.
@MainActor
@Observable
final class CameraPreviewSession {

    /// Whether a preview is actually available. False in the simulator, and on a
    /// device where camera access was refused — in both cases the editor falls
    /// back to a plain backdrop rather than pretending.
    private(set) var isAvailable = false

    let session = AVCaptureSession()
    private var isConfigured = false

    /// Requests access and starts the preview.
    func start() async {
        guard await Self.requestAccess() else {
            isAvailable = false
            return
        }
        configureIfNeeded()
        guard isConfigured else {
            isAvailable = false
            return
        }
        // `startRunning` blocks; keeping it off the main actor is what stops the
        // settings screen hitching as it appears.
        let session = self.session
        await Task.detached(priority: .userInitiated) {
            if !session.isRunning { session.startRunning() }
        }.value
        isAvailable = true
    }

    func stop() {
        let session = self.session
        Task.detached(priority: .utility) {
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }

        session.beginConfiguration()
        // Low: this is a thumbnail behind a drag handle, not a stream. It keeps
        // the preview off the thermal budget of a phone that is about to spend
        // the night encoding video.
        session.sessionPreset = .low

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        session.commitConfiguration()
        isConfigured = true
    }

    private static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }
}

/// Hosts the preview layer.
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        // Fill, matching how the detector sees the frame: it compares whole
        // frames, so a letterboxed preview would show bars that are not there.
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
    }

    /// A view whose backing layer *is* the preview layer, so it resizes with the
    /// view instead of needing manual frame bookkeeping.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // Safe by construction: `layerClass` above guarantees the type.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}


/// Draws the movement watch area over a live picture.
///
/// Read-only — this is the Camera confirming what it is watching, not a place to
/// change it. Editing lives on the alerts screen, over its own preview.
struct WatchAreaOverlay: View {

    let region: DetectionRegion
    var tint: Color = Theme.Palette.periwinkle

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.size
            let rect = CGRect(
                x: region.x * frame.width,
                y: region.y * frame.height,
                width: region.width * frame.width,
                height: region.height * frame.height
            )

            ZStack(alignment: .topLeading) {
                // Everything outside the area is dimmed rather than the area
                // being highlighted: it reads as "this part is not watched",
                // which is the thing a parent needs to notice.
                Color.black.opacity(0.35)
                    .reverseMask {
                        Rectangle()
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }

                Rectangle()
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
