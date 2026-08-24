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
/// - **Light sensitivity** — a nursery is dark, and a phone's automatic exposure
///   settles on a picture that is correct and black. `CameraSensitivity` is the
///   override: exposure compensation, the hardware low-light boost, and — at the
///   top of the range — a lower frame rate so each frame is exposed for longer.
///   It is worth far more than any bitrate the ladder can buy.
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
    /// Whether the app *wants* capture running. Not the same as whether frames
    /// are actually arriving — see `isInterrupted`.
    private(set) var isCapturing = false
    private(set) var quality: VideoQuality = .standard

    /// Set while iOS has taken the capture session away.
    ///
    /// The overwhelmingly common cause on a Camera is the power button: a
    /// backgrounded iPhone app may not hold the camera, so locking the screen
    /// interrupts the session with `.videoDeviceNotAvailableInBackground` and
    /// there is no background mode that changes that. A call using the camera and
    /// a Split View sibling on iPad do the same thing.
    ///
    /// Tracked rather than ignored because two things hang off the capture
    /// session that a Viewer can reach: the torch, which cannot be lit without
    /// one, and the exposure, which is a property of a device configuration the
    /// interruption resets. Without this the Camera answered a Viewer's night
    /// light with silence and then never turned it on, and reported an exposure
    /// it was not running.
    private(set) var isInterrupted = false

    /// Called when `isInterrupted` changes, so the engine can tell Viewers that
    /// the picture, the light and the exposure have come or gone.
    var onInterruptionChange: (() -> Void)?

    /// Set while the local preview needs frames but nothing is being sent.
    private(set) var isCaptureOnly = false

    /// The device capture is currently running on. Held because the torch belongs
    /// to it: driving the light means locking the same `AVCaptureDevice` the
    /// capture session already owns, not a second handle to the same hardware.
    private var activeDevice: AVCaptureDevice?

    /// What the light *should* be doing, on the Viewer's `0...1` scale.
    ///
    /// Kept separately from the hardware because the hardware forgets. Every rung
    /// of the adaptive quality ladder calls `start(quality:)` again, and restarting
    /// a capture session drops the torch — so the intent has to live somewhere
    /// that survives the restart and be re-asserted afterwards. Without this the
    /// night light switched itself off the first time the bitrate moved.
    private var desiredLight: (isOn: Bool, level: Double) = (false, LightLevels.default)

    /// How much light the picture should be made from. Held here for the same
    /// reason as `desiredLight`: a capture restart re-reads it, because every
    /// exposure setting is a property of a session that the ladder throws away
    /// each time it moves a rung.
    private(set) var sensitivity: CameraSensitivity

    private let videoSource: RTCVideoSource
    private let capturer: RTCCameraVideoCapturer
    /// Sits between the capturer and the source so movement detection sees the
    /// frames that are actually encoded, without a second camera client.
    private let frameTap: CapturerFrameTap
    private var position: Position = .back
    private var interruptionObservers: [NSObjectProtocol] = []

    init(
        factory: RTCPeerConnectionFactory = WebRTCStack.factory,
        sensitivity: CameraSensitivity = .default,
        onLumaFrame: @escaping @Sendable (LumaFrame) -> Void = { _ in }
    ) {
        self.sensitivity = sensitivity
        let source = factory.videoSource()
        self.videoSource = source
        let tap = CapturerFrameTap(source: source, onLumaFrame: onLumaFrame)
        self.frameTap = tap
        self.capturer = RTCCameraVideoCapturer(delegate: tap)

        self.videoTrack = factory.videoTrack(with: source, trackId: "cribwire-video")
        let audioSource = factory.audioSource(with: WebRTCStack.defaultConstraints())
        self.audioTrack = factory.audioTrack(with: audioSource, trackId: "cribwire-audio")

        observeInterruptions()
    }

    deinit {
        for observer in interruptionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Interruptions

    /// Watches the one capture session this controller owns.
    ///
    /// `RTCCameraVideoCapturer` posts nothing of its own for this — libwebrtc
    /// logs the interruption and moves on — so the notifications are taken
    /// straight from the `AVCaptureSession` it wraps.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        let session = capturer.captureSession

        interruptionObservers.append(
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleInterruptionBegan() }
            }
        )

        interruptionObservers.append(
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleInterruptionEnded() }
            }
        )
    }

    private func handleInterruptionBegan() {
        guard !isInterrupted else { return }
        isInterrupted = true
        // `desiredLight` is deliberately **not** cleared, unlike in `stop()`. A
        // Viewer's night light is a standing request that this phone is
        // temporarily unable to honour, not one that was withdrawn — the torch
        // has already gone out with the session, and it goes back on when the
        // session comes back.
        onInterruptionChange?()
    }

    private func handleInterruptionEnded() {
        guard isInterrupted else { return }
        isInterrupted = false
        guard isCapturing else {
            onInterruptionChange?()
            return
        }
        Task { await restoreAfterInterruption() }
    }

    /// Puts back everything the interruption took with it.
    ///
    /// Straight through `start` rather than a lighter-weight repair, even though
    /// iOS usually resumes the session itself. `start` is the one path that gets
    /// the whole set right — the format for the rung the ladder has since moved
    /// to, the frame-rate ceiling a Viewer may have changed while the screen was
    /// off, the exposure bias the format reset, and the torch — and the adaptive
    /// ladder already restarts capture routinely, so this is a well-trodden call
    /// rather than a special case invented for the lock screen.
    private func restoreAfterInterruption() async {
        await start(quality: quality)
        onInterruptionChange?()
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

        // Nothing to start while iOS holds the session — most often because the
        // screen is off. The rung is recorded above rather than below, so the
        // adaptive ladder keeps moving against a Camera it cannot see and the
        // session comes back at the rung the link actually justifies.
        // `restoreAfterInterruption` is what starts it.
        guard !isInterrupted else {
            isCapturing = true
            return
        }

        guard let device = Self.device(at: self.position.avPosition),
              let format = Self.format(for: quality, on: device)
        else {
            return
        }

        // The sensitivity ceiling is applied to the *ladder's* rate rather than
        // replacing it: a poor link that has dropped to 15 fps is not asked to
        // climb back up because someone brightened the picture.
        let fps = min(
            min(quality.fps, sensitivity.frameRateCeiling ?? quality.fps),
            Self.maximumFrameRate(of: format)
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            capturer.startCapture(with: device, format: format, fps: fps) { _ in
                continuation.resume()
            }
        }
        isCapturing = true
        activeDevice = device
        // **After** the capturer has started, not before. Starting it sets the
        // device's active format, and a format change resets the exposure
        // configuration that hangs off it — so a bias applied first would be
        // silently thrown away, and the dark room this setting exists for would
        // come back exactly as dark.
        applySensitivity(to: device)
        // Restarting the session cleared the torch. Put it back, or a Viewer's
        // night light goes out every time the quality ladder moves a rung.
        applyDesiredLight()
    }

    func stop() async {
        guard isCapturing else { return }
        // Before the session goes, not after: the torch cannot be switched off
        // through a device whose session has already been torn down, and a phone
        // left glowing in a nursery after the Camera stopped is the worst way this
        // feature could fail. The intent is cleared with it, so the light cannot
        // come back on by itself hours later when a Viewer happens to reconnect.
        desiredLight.isOn = false
        setTorch(on: false, level: desiredLight.level)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            capturer.stopCapture {
                continuation.resume()
            }
        }
        isCapturing = false
        isCaptureOnly = false
        activeDevice = nil
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

    // MARK: - Light

    /// How the Viewer's `0...1` slider maps onto the torch.
    ///
    /// The top of the slider is **half** hardware power, not full. Two reasons,
    /// and both are about the room rather than the API: a phone torch at full
    /// power pointed into a cot is painful to a child who has just woken, and a
    /// torch held at full power draws enough current that iOS shuts it off
    /// thermally within minutes — which on a night light reads as the app being
    /// broken. Half power runs indefinitely and is still far brighter than any
    /// nursery needs.
    enum LightLevels {
        /// Hardware level at the bottom of the slider. Not zero: `setTorchModeOn`
        /// rejects a level of zero, and "on but invisible" is not a state worth
        /// offering anyway.
        static let minimum: Float = 0.02
        /// Hardware level at the top of the slider.
        static let maximum: Float = 0.5
        /// Where the slider starts — a low glow, enough to see a face by.
        static let `default`: Double = 0.35

        /// Maps the Viewer's scale onto the hardware's.
        static func hardwareLevel(for level: Double) -> Float {
            let clamped = Float(min(max(level, 0), 1))
            return minimum + clamped * (maximum - minimum)
        }
    }

    /// Applies a light change and reports what the light is actually doing.
    ///
    /// - Parameters:
    ///   - isOn: `nil` leaves the on/off state alone.
    ///   - level: `nil` leaves the brightness alone. Setting a brightness while
    ///     the light is off turns it on — dragging a brightness slider is not a
    ///     plausible way to ask for darkness.
    @discardableResult
    func setLight(isOn: Bool?, level: Double?) -> LightState {
        if let level {
            desiredLight.level = min(max(level, 0), 1)
            if isOn == nil { desiredLight.isOn = true }
        }
        if let isOn { desiredLight.isOn = isOn }
        applyDesiredLight()
        return lightState
    }

    /// What the light is doing, read from the hardware rather than from intent.
    ///
    /// `isTorchActive` and not `desiredLight.isOn`, because iOS switches the torch
    /// off on its own when the phone gets warm. A Viewer looking at a switch that
    /// says "on" over a dark room has been told something false, and the whole
    /// point of reporting state back is that it is the room's state.
    var lightState: LightState {
        LightState(
            availability: lightAvailability,
            isOn: activeDevice?.isTorchActive ?? false,
            level: desiredLight.level
        )
    }

    private var lightAvailability: LightState.Availability {
        // `isInterrupted` reads as idle, which is exactly what it is from the
        // Viewer's side: the switch is worth showing and worth setting — the
        // request is remembered — but the room will not light up until this phone
        // has its camera back.
        guard isCapturing, !isInterrupted, let device = activeDevice else { return .cameraIdle }
        guard device.hasTorch else {
            // A back camera with no torch is hardware that will never have one;
            // the front camera is one flip away from working, and the Viewer is
            // told which of those it is looking at.
            return position == .front ? .wrongCamera : .noHardware
        }
        // False while the torch is too warm to light, which is the one failure a
        // parent will otherwise interpret as the app being broken.
        return device.isTorchAvailable ? .ready : .unavailable
    }

    private func applyDesiredLight() {
        setTorch(on: desiredLight.isOn, level: desiredLight.level)
    }

    /// Best-effort throughout: a torch that refuses is a night light that did not
    /// come on, never a stream that stopped.
    private func setTorch(on: Bool, level: Double) {
        guard let device = activeDevice, device.hasTorch else { return }
        // Turning it *off* is attempted unconditionally. `isTorchAvailable` goes
        // false when the phone is too warm, and refusing to act on that would
        // leave a light nobody can switch off in a room with a sleeping child.
        guard on else {
            withLock(device) { $0.torchMode = .off }
            return
        }
        guard device.isTorchAvailable else { return }
        withLock(device) { device in
            // `setTorchModeOn` throws rather than clamping, so the level is
            // bounded by what this device reports as its maximum first.
            let requested = min(
                LightLevels.hardwareLevel(for: level),
                AVCaptureDevice.maxAvailableTorchLevel
            )
            try? device.setTorchModeOn(level: max(requested, LightLevels.minimum))
        }
    }

    private func withLock(_ device: AVCaptureDevice, _ body: (AVCaptureDevice) -> Void) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        body(device)
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

    // MARK: - Light sensitivity

    /// Changes how much light the picture is made from.
    ///
    /// Asynchronous because the top of the range costs a capture restart: the
    /// frame rate is part of the format the session was started with, and it is
    /// the one lever here that genuinely lets more light onto the sensor rather
    /// than amplifying what already reached it. Exposure compensation and the
    /// hardware boost apply to the running session with no restart at all, which
    /// is what keeps a slider drag from stuttering the stream.
    @discardableResult
    func setSensitivity(_ settings: CameraSensitivity) async -> SensitivityState {
        let previousCeiling = sensitivity.frameRateCeiling
        sensitivity = settings

        if isCapturing, previousCeiling != settings.frameRateCeiling {
            // Re-enters `start`, which re-reads the sensitivity for both the
            // frame rate and the device configuration — and puts the torch back.
            await start(quality: quality)
        } else if let device = activeDevice {
            applySensitivity(to: device)
        }
        return sensitivityState
    }

    /// What the exposure is actually set to, read from the device.
    var sensitivityState: SensitivityState {
        guard isCapturing, !isInterrupted, let device = activeDevice else {
            // Idle is not "unavailable": the value is stored and applied at the
            // next start, so it is still worth changing from a Viewer.
            return SensitivityState(
                availability: .cameraIdle,
                settings: sensitivity,
                supportsLowLightBoost: false,
                exposureBiasEV: nil
            )
        }
        let supportsBias = device.minExposureTargetBias < device.maxExposureTargetBias
        return SensitivityState(
            availability: supportsBias ? .ready : .unsupported,
            settings: sensitivity,
            supportsLowLightBoost: device.isLowLightBoostSupported,
            // Read back rather than computed: the device clamps to its own
            // supported range, which on some hardware is narrower than the
            // slider, and a Viewer should see what it got and not what it asked
            // for.
            exposureBiasEV: Double(device.exposureTargetBias)
        )
    }

    /// Turns on whatever this device offers for a dark room, at the level the
    /// current sensitivity asks for.
    ///
    /// Every step is individually optional — hardware support varies and a
    /// missing capability must never stop the stream — so each is guarded and the
    /// whole thing is best-effort.
    private func applySensitivity(to device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = sensitivity.lowLightBoost
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        // Compensation, not a fixed exposure: the room changes when a light is
        // switched on in the hallway, and a Camera pinned to one exposure would
        // then be as unwatchable in the other direction. This tells the automatic
        // exposure to aim brighter than it thinks is right, and lets it keep
        // doing its job around that.
        //
        // Clamped to what this device supports before it is set: the setter traps
        // on an out-of-range value rather than clamping it itself.
        let requestedBias = Float(sensitivity.exposureBiasEV)
        let bias = min(max(requestedBias, device.minExposureTargetBias), device.maxExposureTargetBias)
        device.setExposureTargetBias(bias, completionHandler: nil)

        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }
}
