import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// The shape of CribWire's Live Activity.
///
/// Shared by the app (which starts and updates it) and the widget extension
/// (which draws it), so it lives in the app target's sources and is referenced
/// by the extension rather than duplicated — two copies of an `ActivityAttributes`
/// that drift apart fail at runtime with no compiler warning.
///
/// **Nothing here is secret.** A Live Activity is rendered by the system and is
/// visible on a locked screen, so the content is limited to what a passer-by may
/// safely see: that monitoring is running, roughly how the link looks, and the
/// Camera's battery. No detection detail, no snapshot, no pairing identifier.
/// "Noise detected at 03:14" on a lock screen is a statement about someone's
/// child, and it does not belong here.
struct CribWireActivityAttributes: Codable, Hashable {

    /// Set once when the activity starts.
    ///
    /// The Camera's display name is user-chosen and could be anything, so it is
    /// carried but the widget truncates it rather than letting it push the rest
    /// of the layout around.
    let cameraName: String

    /// The parts that change while it runs.
    struct ContentState: Codable, Hashable {
        /// Whether the Viewer currently has a verified, connected stream.
        var connection: Connection
        /// Camera battery `0...1`, or `nil` if it has not reported one.
        var batteryLevel: Double?
        var isCharging: Bool
        /// When the last detection alert arrived, if any. Only the time is
        /// carried — never what was detected.
        var lastAlertAt: Date?

        enum Connection: String, Codable, Hashable {
            case connecting
            case watching
            case reconnecting
            case stopped

            var label: String {
                switch self {
                case .connecting: return String(localized: "Connecting")
                case .watching: return String(localized: "Watching")
                case .reconnecting: return String(localized: "Reconnecting")
                case .stopped: return String(localized: "Stopped")
                }
            }

            /// Whether this state should read as "everything is fine".
            var isHealthy: Bool { self == .watching }
        }
    }
}

#if canImport(ActivityKit)
extension CribWireActivityAttributes: ActivityAttributes {}
#endif
