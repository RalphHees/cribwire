import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

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

    /// Whether the device and the user's settings allow one at all.
    static var isAvailable: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        #endif
        return false
    }

    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    private var activity: Activity<CribWireActivityAttributes>? {
        get { _activity as? Activity<CribWireActivityAttributes> }
        set { _activity = newValue }
    }
    /// Stored untyped so the property itself needs no availability annotation.
    private var _activity: Any?
    #endif

    /// Throttles updates. ActivityKit budgets them, and the interesting fields
    /// (battery, connection) change far more often than a Lock Screen needs.
    private var lastUpdate = Date.distantPast
    private static let minimumUpdateInterval: TimeInterval = 10

    func start(cameraName: String, state: CribWireActivityAttributes.ContentState) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), Self.isAvailable, activity == nil else { return }
        activity = try? Activity.request(
            attributes: CribWireActivityAttributes(cameraName: cameraName),
            contentState: state,
            pushType: nil
        )
        lastUpdate = Date()
        #endif
    }

    /// - Parameter force: bypass the throttle for changes worth showing at once,
    ///   such as losing the stream.
    func update(_ state: CribWireActivityAttributes.ContentState, force: Bool = false) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdate) >= Self.minimumUpdateInterval else {
            return
        }
        lastUpdate = now
        Task { await activity.update(using: state) }
        #endif
    }

    /// Ends the activity. Dismissed immediately rather than lingering: once the
    /// Viewer has stopped, a Lock Screen card still saying "Watching" is a lie
    /// about whether a child is being monitored.
    func end() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity else { return }
        self.activity = nil
        Task {
            await activity.end(dismissalPolicy: .immediate)
        }
        #endif
    }
}
