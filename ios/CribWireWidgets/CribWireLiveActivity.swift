import ActivityKit
import SwiftUI
import WidgetKit

/// The Lock Screen and Dynamic Island presentation of CribWire's Live Activity.
///
/// Deliberately sparse. This is drawn on a locked screen where anyone in the room
/// can see it, so it says that monitoring is running and how the link looks — and
/// never what was detected. `CribWireActivityAttributes` explains why the payload
/// carries no detection detail; this file must not start inferring any.
struct CribWireLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CribWireActivityAttributes.self) { context in
            lockScreen(context)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.cameraName, systemImage: "video.fill")
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let battery = context.state.batteryLevel {
                        Label(
                            "\(Int((battery * 100).rounded()))%",
                            systemImage: context.state.isCharging ? "battery.100.bolt" : "battery.50"
                        )
                        .font(.caption)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        statusDot(context.state.connection)
                        Text(context.state.connection.label)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        if let alert = context.state.lastAlertAt {
                            Text("Alert \(alert, style: .relative) ago")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                statusDot(context.state.connection)
            } compactTrailing: {
                if let battery = context.state.batteryLevel {
                    Text("\(Int((battery * 100).rounded()))%")
                        .font(.caption2)
                }
            } minimal: {
                statusDot(context.state.connection)
            }
        }
    }

    @ViewBuilder
    private func lockScreen(
        _ context: ActivityViewContext<CribWireActivityAttributes>
    ) -> some View {
        HStack(spacing: 12) {
            statusDot(context.state.connection)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.cameraName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(context.state.connection.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let battery = context.state.batteryLevel {
                VStack(alignment: .trailing, spacing: 2) {
                    Label(
                        "\(Int((battery * 100).rounded()))%",
                        systemImage: context.state.isCharging ? "battery.100.bolt" : batterySymbol(battery)
                    )
                    .font(.caption.weight(.medium))
                    // Only an uncharging, nearly-flat Camera is worth alarming
                    // anyone on a lock screen.
                    .foregroundStyle(
                        !context.state.isCharging && battery < 0.15 ? .red : .primary
                    )
                    if let alert = context.state.lastAlertAt {
                        Text(alert, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func batterySymbol(_ level: Double) -> String {
        switch level {
        case ..<0.15: return "battery.0"
        case ..<0.40: return "battery.25"
        case ..<0.80: return "battery.75"
        default: return "battery.100"
        }
    }

    private func statusDot(
        _ connection: CribWireActivityAttributes.ContentState.Connection
    ) -> some View {
        Circle()
            .fill(colour(for: connection))
            .frame(width: 10, height: 10)
    }

    private func colour(
        for connection: CribWireActivityAttributes.ContentState.Connection
    ) -> Color {
        switch connection {
        case .watching: return .green
        case .connecting, .reconnecting: return .yellow
        case .stopped: return .gray
        }
    }
}

/// The extension's entry point.
///
/// `CribWireLiveActivity` is listed unconditionally, and it must stay that way.
/// An `if #available` here compiles perfectly and then registers an *empty*
/// bundle on any OS below the check — WidgetKit reports that as "failed to get
/// descriptors for extensionBundleID", which reads like a signing or
/// provisioning fault rather than a widget that was never registered. At the
/// project's iOS 26 floor no such check can be justified anyway.
@main
struct CribWireWidgetBundle: WidgetBundle {
    var body: some Widget {
        CribWireLiveActivity()
    }
}
