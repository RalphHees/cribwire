import ActivityKit
import Foundation
import UIKit

/// Starts, updates and ends the Viewer's Live Activity.
///
/// The question a Live Activity answers here is "is it still watching?" — which
/// today needs the app opened, and which is the one thing a parent checks
/// repeatedly. Answering it from the Lock Screen is the whole feature.
///
/// Everything is best-effort. ActivityKit refuses for reasons outside the app's
/// control (the user disabled Live Activities, the system budget is exhausted, the
/// app is in the background at start time), and none of them are worth an error in
/// front of someone watching their child. A missing Live Activity degrades to the
/// app working exactly as before.
@MainActor
final class LiveActivityController {

    /// Whether the user's settings allow one at all.
    ///
    /// Only a settings question now that the floor is iOS 26 — every supported
    /// device has ActivityKit.
    static var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Stored with its real type. It used to be held as `Any` and cast on every
    /// access, purely so the property needed no `@available` annotation on a
    /// 16.0 floor. Nothing about that is needed at 26.
    private var activity: Activity<CribWireActivityAttributes>?

    /// Throttles updates. ActivityKit budgets them, and the interesting fields
    /// (battery, connection) change far more often than a Lock Screen needs.
    private var lastUpdate = Date.distantPast
    private static let minimumUpdateInterval: TimeInterval = 10

    /// `nonisolated(unsafe)` so `deinit` — which is not actor-isolated — can
    /// still unregister it. Safe by construction rather than by the compiler's
    /// reasoning: it is written once in `init` and read once in `deinit`, and
    /// there is no third moment for the two to race in.
    private nonisolated(unsafe) var terminationObserver: (any NSObjectProtocol)?

    /// Watches for the app being closed.
    ///
    /// Termination is the one way out of this screen that runs none of the
    /// app's own teardown — no `onDisappear`, no scene phase change — so the
    /// activity has to be ended from here or it is not ended at all. Delivery
    /// is not guaranteed (a suspended app swiped out of the switcher is killed
    /// silently), which is why `endStale()` exists as the backstop.
    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    /// Wraps a state in the `ActivityContent` the modern ActivityKit API takes.
    ///
    /// `staleDate` is left `nil`, which keeps today's behaviour: the card never
    /// dims itself. Giving it one is worth considering separately — a Lock Screen
    /// still reading "Watching" after updates stopped is the same lie `end()`
    /// guards against, arrived at by a different route — but it is a product
    /// decision about what a parent should see, not part of a toolchain bump.
    private func content(
        _ state: CribWireActivityAttributes.ContentState
    ) -> ActivityContent<CribWireActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: nil)
    }

    func start(cameraName: String, state: CribWireActivityAttributes.ContentState) {
        guard Self.isAvailable, activity == nil else { return }
        activity = try? Activity.request(
            attributes: CribWireActivityAttributes(cameraName: cameraName),
            content: content(state),
            pushType: nil
        )
        lastUpdate = Date()
    }

    /// - Parameter force: bypass the throttle for changes worth showing at once,
    ///   such as losing the stream.
    func update(_ state: CribWireActivityAttributes.ContentState, force: Bool = false) {
        guard let activity else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdate) >= Self.minimumUpdateInterval else {
            return
        }
        lastUpdate = now
        let next = content(state)
        Task { await activity.update(next) }
    }

    /// Ends the activity. Dismissed immediately rather than lingering: once the
    /// Viewer has stopped, a Lock Screen card still saying "Watching" is a lie
    /// about whether a child is being monitored.
    func end() {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Clears a card left behind by a previous run of the app.
    ///
    /// ActivityKit deliberately outlives the process that requested it, so a
    /// force-quit — the ordinary way people close an app — leaves "Watching" on
    /// the Lock Screen of a phone that is watching nothing. Nothing in the app
    /// runs at that moment to say otherwise, so the next launch does it: any
    /// activity found before this process has started one belongs to a Viewer
    /// that no longer exists.
    ///
    /// `.immediate` for the same reason `end()` uses it: the card has to leave
    /// the Lock Screen list itself, not settle into the dismissed-but-still-
    /// there state that a default policy leaves behind for hours.
    @MainActor
    static func endStale() async {
        for activity in Activity<CribWireActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
