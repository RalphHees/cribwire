import Foundation
import UIKit

/// Keeps the Camera running when its screen goes off.
///
/// Pressing the power button on the Camera phone backgrounds the app, and iOS
/// then does two separate things that this type exists to separate as well:
///
/// - **It interrupts the capture session.** Video is gone for the duration, and
///   nothing here or anywhere else can change that — there is no background mode
///   or entitlement on iPhone that lets a backgrounded app hold the camera. That
///   half is handled by `CameraCaptureController`, which reports the interruption
///   so Viewers are told the picture and the light are unavailable rather than
///   being left with a frozen frame and controls that silently do nothing.
///
/// - **It suspends the process**, unless something is keeping it awake. This is
///   the half that used to take *everything* down with it: the signalling socket,
///   every Viewer command, and the detectors. The app declares the `audio`
///   background mode, but that only sustains an app that is genuinely doing audio
///   I/O — and a Camera with nobody watching and noise alerts off is doing none,
///   so iOS suspended it within seconds of the screen going dark.
///
/// So the strategy is two-layered, because neither layer covers the whole gap:
///
/// 1. A **background task assertion**, taken the instant the app backgrounds. It
///    buys the app the better part of a minute unconditionally, which covers the
///    moment when the capture session is being torn down and the audio route is
///    being reconfigured — exactly when audio I/O can briefly stop and the app
///    would otherwise be suspended before the keep-alive is running.
/// 2. The **audio keep-alive** the owner starts in `onEnterBackground`, which is
///    what carries the app for the rest of the night. The assertion is deliberately
///    not renewed: iOS will not extend it indefinitely and pretending otherwise
///    would hide a keep-alive that failed to start behind a timer that expires
///    quietly an hour later.
@MainActor
final class CameraBackgroundSession {

    /// True while the screen is off or the app is otherwise not frontmost.
    private(set) var isBackgrounded = false

    private let onEnterBackground: () -> Void
    private let onEnterForeground: () -> Void

    private var observers: [NSObjectProtocol] = []
    private var assertion: UIBackgroundTaskIdentifier = .invalid

    init(
        onEnterBackground: @escaping () -> Void,
        onEnterForeground: @escaping () -> Void
    ) {
        self.onEnterBackground = onEnterBackground
        self.onEnterForeground = onEnterForeground
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleBackground() }
            }
        )

        observers.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleForeground() }
            }
        )

        // The screen can already be off by the time the Camera starts — a phone
        // that was locked while the app was launching by a push, say — and there
        // is no notification for a state the app is already in.
        if UIApplication.shared.applicationState == .background {
            handleBackground()
        }
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        endAssertion()
        isBackgrounded = false
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        // The assertion cannot be ended from here — `endBackgroundTask` is main
        // actor work and `deinit` is not — but `stop()` is called from the
        // engine's own teardown on every path that releases this object.
    }

    // MARK: - Transitions

    private func handleBackground() {
        guard !isBackgrounded else { return }
        isBackgrounded = true
        beginAssertion()
        onEnterBackground()
    }

    private func handleForeground() {
        guard isBackgrounded else { return }
        isBackgrounded = false
        onEnterForeground()
        // After the callback, not before: the owner re-starts capture and
        // re-asserts the audio session in there, and the assertion is what
        // guarantees it gets to finish.
        endAssertion()
    }

    // MARK: - Assertion

    private func beginAssertion() {
        guard assertion == .invalid else { return }
        assertion = UIApplication.shared.beginBackgroundTask(withName: "CribWire.Camera") { [weak self] in
            // Expiry means the audio keep-alive did not take over, and the
            // process is suspended the moment this returns. Ending the assertion
            // is not optional — iOS terminates an app that ignores the handler.
            //
            // Weakly, deliberately: this closure outlives the assertion it ends,
            // and holding the session strongly would keep the whole engine alive
            // behind it. Nothing is leaked by the nil case, because every path
            // that releases this object goes through `stop()` first.
            MainActor.assumeIsolated { self?.endAssertion() }
        }
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }
}
