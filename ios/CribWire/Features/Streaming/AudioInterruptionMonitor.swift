import AVFoundation
import Foundation

/// Watches the audio session for the things that interrupt a night's monitoring
/// (`ios-app.md` §4, `docs/TASKS.md` Phase 4: "interruption recovery").
///
/// Three separate events, deliberately not collapsed into one, because the
/// correct response to each is different:
///
/// - **Interruption** — a phone call, Siri, an alarm. iOS deactivates the audio
///   session out from under the app and hands it back afterwards, but only if the
///   `.shouldResume` option says so. Reactivating the session is not optional:
///   without it the Camera keeps streaming video with silent audio, which looks
///   like a working monitor and is not one.
/// - **Route change** — headphones unplugged, a Bluetooth speaker leaving range,
///   the receiver switching to the speaker. The session survives, but the output
///   may now be somewhere the user cannot hear.
/// - **Media services reset** — rare, and brutal: every audio object the process
///   holds becomes invalid. Nothing short of rebuilding the audio stack recovers,
///   which is why it gets its own callback rather than being folded into the
///   others.
@MainActor
final class AudioInterruptionMonitor {

    enum Event: Equatable {
        /// The session was taken away. Capture and playback are stopped.
        case interrupted
        /// The interruption ended and iOS says the app may resume.
        case resumable
        /// The interruption ended but iOS does not want the app to resume — a
        /// call that is still going, typically. Waiting is the correct response.
        case endedWithoutResume
        /// Output or input moved. Carries whether the previous device went away.
        case routeChanged(deviceDisconnected: Bool)
        /// The audio stack died and has to be rebuilt from nothing.
        case mediaServicesWereReset
    }

    private let onEvent: (Event) -> Void
    private var observers: [NSObjectProtocol] = []

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleInterruption(notification)
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleRouteChange(notification)
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onEvent(.mediaServicesWereReset)
                }
            }
        )
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Decoding

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else {
            return
        }

        switch type {
        case .began:
            onEvent(.interrupted)
        case .ended:
            onEvent(Self.endEvent(from: notification.userInfo))
        @unknown default:
            break
        }
    }

    /// Whether iOS is inviting the app to resume, or merely telling it the
    /// interruption is over. Resuming uninvited fails, and on repeat can get the
    /// app's audio session deprioritised.
    nonisolated static func endEvent(from userInfo: [AnyHashable: Any]?) -> Event {
        let raw = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: raw)
        return options.contains(.shouldResume) ? .resumable : .endedWithoutResume
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else {
            return
        }
        guard let event = Self.routeEvent(for: reason) else { return }
        onEvent(event)
    }

    /// Only the reasons that change what the user can hear are reported. A
    /// category change is the app's own doing, and reacting to it would mean
    /// reacting to itself.
    nonisolated static func routeEvent(for reason: AVAudioSession.RouteChangeReason) -> Event? {
        switch reason {
        case .oldDeviceUnavailable:
            return .routeChanged(deviceDisconnected: true)
        case .newDeviceAvailable, .override, .routeConfigurationChange:
            return .routeChanged(deviceDisconnected: false)
        case .categoryChange, .unknown, .wakeFromSleep, .noSuitableRouteForCategory:
            return nil
        @unknown default:
            return nil
        }
    }
}
