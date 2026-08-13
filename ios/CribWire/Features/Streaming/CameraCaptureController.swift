import AVFoundation
import Foundation
import CribWireKit
import WebRTC

/// The Camera's capture pipeline: one video track and one audio track, plus the
/// device configuration that makes a nursery at night actually watchable.
///
/// Owns the `RTCCameraVideoCapturer` rather than a bare `AVCaptureSession`,
/// because libwebrtc needs the frames delivered into its own video source; the
/// capturer wraps a capture session and does exactly that.
///
/// Two things here are about the room rather than the protocol:
///
/// - **Low-light boost** — a nursery is dark. Where the hardware offers it, the
///   low-light boost and a longer maximum exposure are enabled, which is worth
///   far more than any bitrate the ladder can buy.
/// - **Capture-only mode** — with no Viewer connected the camera keeps running
///   only if a detector needs the frames. Otherwise capture stops outright, which
///   is the single biggest thing the Camera can do for its battery.
@MainActor
final class CameraCaptureController {

    /// Which camera the app streams from. Back by default: it has the better
    /// sensor, and a monitor is propped facing the crib rather than held.
    enum Position: Equatable {
        case back
        case front

        var avPosition: AVCaptureDevice.Position {
            self == .back ? .back : .front
        }
    }

    private(set) var videoTrack: RTCVideoTrack?
    private(set) var audioTrack: RTCAudioTrack?
    private(set) var isCapturing = false
    private(set) var quality: VideoQuality = .standard

    /// Set while the local preview needs frames but nothing is being sent.
    private(set) var isCaptureOnly = false

    private let videoSource: RTCVideoSource
    private let capturer: RTCCameraVideoCapturer
    /// Sits between the capturer and the source so movement detection sees the
    /// frames that are actually encoded, without a second camera client.
    private let frameTap: CapturerFrameTap
    private var position: Position = .back

    init(
        factory: RTCPeerConnectionFactory = WebRTCStack.factory,
        onLumaFrame: @escaping @Sendable (LumaFrame) -> Void = { _ in }
    ) {
        let source = factory.videoSource()
        self.videoSource = source
        let tap = CapturerFrameTap(source: source, onLumaFrame: onLumaFrame)
        self.frameTap = tap
        self.capturer = RTCCameraVideoCapturer(delegate: tap)

        self.videoTrack = factory.videoTrack(with: source, trackId: "cribwire-video")
        let audioSource = factory.audioSource(with: WebRTCStack.defaultConstraints())
        self.audioTrack = factory.audioTrack(with: audioSource, trackId: "cribwire-audio")
    }

    /// Turns luma extraction on and off as the movement detector is enabled.
    func setMovementDetectionEnabled(_ enabled: Bool) {
        frameTap.setExtracting(enabled)
    }

    /// The source the local preview renders from.
    var localVideoTrack: RTCVideoTrack? { videoTrack }

    // MARK: - Lifecycle

    /// Starts (or retunes) capture at `quality`.
    ///
    /// Safe to call repeatedly: the adaptive ladder calls it every time it moves
    /// a rung, and `RTCCameraVideoCapturer` handles a restart at a new format
    /// without tearing the track down, so the peer connection never renegotiates.
    func start(quality: VideoQuality, position: Position? = nil) async {
        if let position { self.position = position }
        self.quality = quality

        guard let device = Self.device(at: self.position.avPosition),
              let format = Self.format(for: quality, on: device)
        else {
            return
        }

        configureForLowLight(device)

        let fps = min(quality.fps, Self.maximumFrameRate(of: format))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            capturer.startCapture(with: device, format: format, fps: fps) { _ in
                continuation.resume()
            }
        }
        isCapturing = true
    }

    func stop() async {
        guard isCapturing else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            capturer.stopCapture {
                continuation.resume()
            }
        }
        isCapturing = false
        isCaptureOnly = false
    }

    /// Whether capture should continue with no Viewer connected.
    ///
    /// Detection runs on the Camera itself, so a detector that is enabled needs
    /// frames whether or not anyone is watching. With every detector off and no
    /// Viewer, capture stops.
    func setCaptureOnly(_ enabled: Bool, quality: VideoQuality = .low) async {
        isCaptureOnly = enabled
        if enabled {
            await start(quality: quality)
        } else {
            await stop()
        }
    }

    func flip() async {
        position = position == .back ? .front : .back
        guard isCapturing else { return }
        await start(quality: quality)
    }

    /// Mutes the microphone without renegotiating: the track stays in the SDP and
    /// simply stops producing.
    func setMicrophoneEnabled(_ enabled: Bool) {
        audioTrack?.isEnabled = enabled
    }

    // MARK: - Device selection

    private static func device(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let devices = RTCCameraVideoCapturer.captureDevices()
        return devices.first { $0.position == position } ?? devices.first
    }

    /// Picks the smallest format that covers the requested rung.
    ///
    /// Smallest rather than closest: capturing above what is encoded wastes
    /// exactly the resources this ladder exists to save, and downscaling in the
    /// pipeline costs CPU on the device that can least afford it.
    static func format(for quality: VideoQuality, on device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard !formats.isEmpty else { return nil }

        let suitable = formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return Int(dimensions.width) >= quality.width
                && Int(dimensions.height) >= quality.height
                && maximumFrameRate(of: format) >= quality.fps
        }

        let ranked = (suitable.isEmpty ? formats : suitable).sorted { left, right in
            let leftSize = CMVideoFormatDescriptionGetDimensions(left.formatDescription)
            let rightSize = CMVideoFormatDescriptionGetDimensions(right.formatDescription)
            return Int(leftSize.width) * Int(leftSize.height)
                < Int(rightSize.width) * Int(rightSize.height)
        }
        return ranked.first
    }

    static func maximumFrameRate(of format: AVCaptureDevice.Format) -> Int {
        Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30)
    }

    /// Turns on whatever this device offers for a dark room.
    ///
    /// Every step is individually optional — hardware support varies and a
    /// missing capability must never stop the stream — so each is guarded and the
    /// whole thing is best-effort.
    private func configureForLowLight(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }
}
