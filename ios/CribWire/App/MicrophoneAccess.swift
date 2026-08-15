import AVFoundation
import Foundation

/// The microphone permission, in the one place that asks about it.
///
/// Both features that need the microphone fail the same silent way without it:
/// `AVAudioEngine` hands the noise detector a stream of zeroes, and libwebrtc
/// sends a Viewer's talk-back as digital silence. Neither raises an error, so a
/// missing permission is indistinguishable from a quiet room and from a parent
/// who is not speaking — which is exactly the bug this type exists to make
/// impossible to write again.
///
/// `AVAudioApplication` rather than `AVAudioSession`, since the floor is iOS 26;
/// the `AVAudioSession.recordPermission` half was deprecated in 17 and answered
/// the same question a different way.
enum MicrophoneAccess {

    enum Status: Equatable {
        /// Never asked. The prompt is still available, and asking is the only way
        /// to move out of this state.
        case undetermined
        case granted
        /// Refused, or restricted by policy. iOS asks exactly once, so nothing in
        /// the app can change this — only Settings can.
        case denied
    }

    static var current: Status {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .denied
        }
    }

    static var isGranted: Bool { current == .granted }

    /// Shows the system prompt if it has not been shown before.
    ///
    /// - Returns: whether the microphone may be used afterwards. `false` from an
    ///   already-denied state means the prompt did not appear and nothing
    ///   happened: iOS asks once, and only Settings can undo the answer.
    @discardableResult
    static func request() async -> Bool {
        guard current == .undetermined else { return isGranted }
        return await AVAudioApplication.requestRecordPermission()
    }
}
