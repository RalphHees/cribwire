import AVFoundation
import Foundation
import CribWireKit

/// Feeds the noise detector from the microphone.
///
/// `AWeightingFilter` decides what counts as loud; this only has to deliver an
/// honest A-weighted level to it. The filter runs on the audio thread inside the
/// tap block, where the samples already are — dispatching raw buffers to the main
/// actor would allocate on every 23 ms of audio, and the only value anyone
/// downstream wants is a single number.
///
/// **Not verified on hardware.** `RTCAudioSession` and `AVAudioEngine` are two
/// clients of the same input, and whether both can hold it at once depends on the
/// device and the route. `start()` therefore reports failure rather than
/// pretending, and the Camera surfaces that as "noise alerts unavailable" instead
/// of silently never firing — a detector that is quietly dead is worse than one
/// that says it is off.
@MainActor
final class AudioLevelMonitor {

    /// Level updates, A-weighted dBFS, roughly 40× a second.
    private let onLevel: @MainActor (Double) -> Void

    private let engine = AVAudioEngine()
    private var state: FilterBox?
    private(set) var isRunning = false

    init(onLevel: @escaping @MainActor (Double) -> Void) {
        self.onLevel = onLevel
    }

    /// Asks for the microphone, if it has not been asked before.
    ///
    /// `AVAudioEngine` does not prompt — it simply produces silence when the
    /// permission is missing, which is indistinguishable from a quiet room. The
    /// caller must ask first or the meter lies.
    static func requestMicrophoneAccess() async {
        await MicrophoneAccess.request()
    }

    /// Whether the microphone has actually been granted.
    static var isMicrophoneGranted: Bool {
        MicrophoneAccess.isGranted
    }

    func start() throws {
        guard !isRunning else { return }
        // A denied microphone yields silence rather than an error, so it has to
        // be checked rather than discovered.
        guard Self.isMicrophoneGranted else { throw MonitorError.noInputAvailable }

        // Through `WebRTCStack`, and never `AVAudioSession` directly.
        //
        // This used to set the category and activate the session itself, which
        // is a rule libwebrtc does not tolerate being broken: it tracks the
        // session's state inside `RTCAudioSession` and takes a lock around every
        // change, so a category set behind its back leaves its own idea of the
        // session wrong — and the detector runs *while streaming*, since a Camera
        // alerts on a quiet nursery whether or not anyone is watching. Going
        // through the same call the engine uses means both clients ask for the
        // same configuration, under the lock, and the last one to run cannot
        // silently undo the other.
        WebRTCStack.configureAudioSession(mode: .active, output: .room)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MonitorError.noInputAvailable
        }

        let box = FilterBox(sampleRate: format.sampleRate)
        state = box

        // 1024 frames is ~23 ms at 44.1 kHz: short enough that a cry is caught
        // inside the detector's own 0.5 s window, long enough that the RMS is
        // not dominated by a single transient.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let level = box.level(of: buffer) else { return }
            Task { @MainActor in
                self?.onLevel(level)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            state = nil
            throw MonitorError.engineFailed(error)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state = nil
        isRunning = false
    }

    enum MonitorError: Error {
        case noInputAvailable
        case engineFailed(Error)
    }

    /// Holds the filter for the audio thread.
    ///
    /// `@unchecked Sendable` is sound here for one specific reason: `AVAudioEngine`
    /// serialises tap callbacks on a single thread, so the mutation below never
    /// overlaps with itself, and nothing else ever touches the filter.
    private final class FilterBox: @unchecked Sendable {
        private var filter: AWeightingFilter

        init(sampleRate: Double) {
            self.filter = AWeightingFilter(sampleRate: sampleRate)
        }

        /// A-weighted level of one buffer, or `nil` if it carries no float samples.
        func level(of buffer: AVAudioPCMBuffer) -> Double? {
            guard let channel = buffer.floatChannelData?[0] else { return nil }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return nil }
            let samples = Array(UnsafeBufferPointer(start: channel, count: count))
            return filter.levelDBFS(of: samples)
        }
    }
}
